#!/system/bin/sh
# ipv6_tether.sh - IPv6 tethering for Android 4.4 (NDP proxy + RA + DHCPv6)
# 用法: su -c 'sh /data/local/tmp/ipv6_tether.sh start|stop|status|restart'
# 配置: /data/local/tmp/ipv6_config.conf

CONF="/data/local/tmp/ipv6_config.conf"
RA_BIN="/data/local/tmp/send_ra"
DHCP6_BIN="/data/local/tmp/dhcp6_server"
PIDFILE="/data/local/tmp/ipv6_ra.pid"
NDPIDFILE="/data/local/tmp/ipv6_ndp.pid"
DHCP6PIDFILE="/data/local/tmp/ipv6_dhcp6.pid"
WATCHPIDFILE="/data/local/tmp/ipv6_watch.pid"
STATEFILE="/data/local/tmp/ipv6_state"

# 默认值（config 不存在时使用）
IFACE_UP="bridge1"
# IFACE_WAN 支持多个接口（空格分隔），按优先级自动检测哪个有 IPv6
IFACE_WAN="rmnet_data0 wlan0"
RA_INTERVAL="3"
RA_MTU="1280"
DNS_SERVERS="2400:3200::1,2400:3200:baba::1"
DHCP6_ENABLE="1"
NDP_INTERVAL="5"
WATCH_INTERVAL="10"

# 加载配置
[ -f "$CONF" ] && . "$CONF"

# WAN_ACTIVE / PREFIX: detect_wan 找到 IPv6 后自动设置
WAN_ACTIVE=""
PREFIX=""

# _extract_prefix: 从接口的 global IPv6 地址中提取 /64 前缀（前4段）
_extract_prefix() {
    ip -6 addr show "$1" 2>/dev/null \
        | busybox grep 'scope global' \
        | busybox grep -v 'temporary' \
        | busybox awk '{print $2}' \
        | busybox cut -d/ -f1 \
        | busybox cut -d: -f1-4 \
        | busybox head -1
}

# detect_wan: 优先使用默认路由接口，其次遍历候选 WAN 接口
# 注意：排除 IFACE_UP（bridge1），防止误选下行接口
detect_wan() {
    WAN_ACTIVE=""
    PREFIX=""
    # 1. 优先检查 IPv6 默认路由所在的接口（反映系统实际选择的 WAN）
    DEFAULT_IFACE=$(ip -6 route show default 2>/dev/null | busybox awk '{print $5}' | busybox head -1)
    if [ -n "$DEFAULT_IFACE" ] && [ "$DEFAULT_IFACE" != "$IFACE_UP" ]; then
        PREF=$(_extract_prefix "$DEFAULT_IFACE")
        if [ -n "$PREF" ]; then
            WAN_ACTIVE="$DEFAULT_IFACE"
            PREFIX="$PREF"
            return 0
        fi
    fi
    # 2. 回退到候选接口列表
    for iface in $IFACE_WAN; do
        PREF=$(_extract_prefix "$iface")
        if [ -n "$PREF" ]; then
            WAN_ACTIVE="$iface"
            PREFIX="$PREF"
            return 0
        fi
    done
    return 1
}

# get_prefix: 输出 prefix（供 _getprefix 子命令和命令替换使用）
get_prefix() {
    detect_wan
    [ -n "$PREFIX" ] && echo "$PREFIX"
}

start() {
    detect_wan
    if [ -z "$PREFIX" ] || [ -z "$WAN_ACTIVE" ]; then
        echo "ERROR: no global IPv6 on any of: $IFACE_WAN"
        exit 1
    fi
    echo "[*] WAN iface: $WAN_ACTIVE"
    echo "[*] WAN prefix: ${PREFIX}::/64"

    # Clean up stale state from a previous WAN/prefix (handles WAN switch)
    OLD_PREFIX_FOR_RA=""
    SAVED_WAN=""; SAVED_PREFIX=""
    [ -f "$STATEFILE" ] && . "$STATEFILE"
    if [ -n "$SAVED_PREFIX" ] && [ "$SAVED_PREFIX" != "$PREFIX" ]; then
        echo "[*] WAN switched: cleaning old prefix ${SAVED_PREFIX}::/64"
        OLD_PREFIX_FOR_RA="$SAVED_PREFIX"
        # 删除 bridge1 上所有旧前缀地址（::1 网关 + 内核自动分配的 SLAAC 地址）
        ip -6 addr show "$IFACE_UP" 2>/dev/null \
            | busybox grep 'scope global' \
            | busybox awk '{print $2}' \
            | busybox cut -d/ -f1 \
            | while read addr; do
                case "$addr" in
                    "${SAVED_PREFIX}:"*) ip -6 addr del "$addr/64" dev "$IFACE_UP" 2>/dev/null ;;
                esac
            done
        # 删除旧前缀的 unreachable 路由（内核残留）
        ip -6 route del unreachable "${SAVED_PREFIX}::/64" 2>/dev/null
        # 删除旧前缀的低 metric 路由（防止旧前缀流量仍走 bridge1）
        ip -6 route del "${SAVED_PREFIX}::/64" dev "$IFACE_UP" metric 100 2>/dev/null
        # Clean NDP proxy on ALL candidate WAN interfaces (old WAN may differ)
        for w in $IFACE_WAN; do
            ip -6 neigh show proxy dev "$w" 2>/dev/null \
                | busybox awk '{print $1}' \
                | while read a; do
                    ip -6 neigh del proxy "$a" dev "$w" 2>/dev/null
                done
        done
        # Kill old RA sender so it restarts with deprecation prefix
        if [ -f "$PIDFILE" ]; then
            kill $(cat "$PIDFILE") 2>/dev/null
            rm -f "$PIDFILE"
            echo "[*] Old RA sender killed (will restart with prefix deprecation)"
        fi
    fi

    ip -6 addr add "${PREFIX}::1/64" dev "$IFACE_UP" 2>/dev/null
    echo "[*] $IFACE_UP IPv6: ${PREFIX}::1/64"

    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/$IFACE_UP/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/$WAN_ACTIVE/proxy_ndp
    echo 1 > /proc/sys/net/ipv6/conf/all/proxy_ndp

    # 关闭 bridge multicast snooping（防止组播RA被过滤）
    echo 0 > /sys/devices/virtual/net/$IFACE_UP/bridge/multicast_snooping 2>/dev/null

    # 关闭 bridge-nf-call-ip6tables（防止 IPv6 转发被 ip6tables 拦截）
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null

    # 删除 WAN 上的 /64 on-link 路由，避免与桥接接口路由冲突
    ip -6 route del "${PREFIX}::/64" dev "$WAN_ACTIVE" 2>/dev/null
    # 添加 bridge1 前缀路由（低 metric 100，回程流量优先走 bridge1）
    # 配合 _ndp 循环的持续添加，抵御 netd 周期性删除。
    # 注意：不能用 "ip -6 route del unreachable" 清理 unreachable，
    # 该命令会误删同前缀的 metric 100 路由（Android 4.4 ip 命令行为）。
    ip -6 route add "${PREFIX}::/64" dev "$IFACE_UP" metric 100 2>/dev/null

    ip -6 neigh add proxy "${PREFIX}::1" dev "$WAN_ACTIVE" 2>/dev/null

    # Kill ALL existing send_ra processes before starting new one
    # (prevents multiple RA senders from conflicting)
    ps | busybox grep send_ra | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    rm -f "$PIDFILE"
    # 旧前缀参数：补全为完整 IPv6 地址格式（PREFIX 是 4 段，需加 ::）
    OLD_PREFIX_ARG=""
    if [ -n "$OLD_PREFIX_FOR_RA" ]; then
        OLD_PREFIX_ARG="${OLD_PREFIX_FOR_RA}::"
    fi
    # 参数顺序: iface prefix interval dns mtu old_prefix
    busybox setsid "$RA_BIN" "$IFACE_UP" "${PREFIX}::" "$RA_INTERVAL" "$DNS_SERVERS" "$RA_MTU" "$OLD_PREFIX_ARG" 0<&- >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "[*] RA sender started (PID $(cat $PIDFILE))"
    if [ -n "$OLD_PREFIX_FOR_RA" ]; then
        echo "[*] Deprecating old prefix: ${OLD_PREFIX_FOR_RA}::/64 (lifetime=0)"
    fi

    if [ "$DHCP6_ENABLE" = "1" ]; then
        # Kill ALL existing dhcp6_server processes before starting new one
        ps | busybox grep dhcp6_server | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
            kill "$pid" 2>/dev/null
        done
        rm -f "$DHCP6PIDFILE"
        busybox setsid "$DHCP6_BIN" "$IFACE_UP" "${PREFIX}::" "$DNS_SERVERS" 0<&- >/dev/null 2>&1 &
        echo $! > "$DHCP6PIDFILE"
        echo "[*] DHCPv6 server started (PID $(cat $DHCP6PIDFILE))"
    fi

    # Kill ALL existing _ndp processes before starting new one
    ps | busybox grep "$0 _ndp" | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    rm -f "$NDPIDFILE"
    NDP_INTERVAL_ARG="$NDP_INTERVAL" busybox setsid sh "$0" _ndp 0<&- >/dev/null 2>&1 &
    echo $! > "$NDPIDFILE"
    echo "[*] NDP proxy loop started (PID $(cat $NDPIDFILE))"
    # WAN 切换监控（检测到 WAN 接口/前缀变化时自动 restart）
    if [ -f "$WATCHPIDFILE" ] && kill -0 $(cat "$WATCHPIDFILE") 2>/dev/null; then
        echo "[*] Watch loop already running (PID $(cat $WATCHPIDFILE))"
    else
        WATCH_INTERVAL="$WATCH_INTERVAL" busybox setsid sh "$0" _watch 0<&- >/dev/null 2>&1 &
        echo $! > "$WATCHPIDFILE"
        echo "[*] Watch loop started (PID $(cat $WATCHPIDFILE))"
    fi
    echo "SAVED_WAN=$WAN_ACTIVE" > "$STATEFILE"
    echo "SAVED_PREFIX=$PREFIX" >> "$STATEFILE"
    echo "[*] IPv6 tethering is ACTIVE"
}

_ndp() {
    NDP_INTERVAL="${NDP_INTERVAL:-5}"
    while true; do
        detect_wan
        [ -z "$WAN_ACTIVE" ] && { sleep "$NDP_INTERVAL"; continue; }
        # 持续添加 bridge1 前缀路由（低 metric 100，优先于内核 unreachable 路由）。
        # netd 会周期性删除静态路由，因此每轮重新添加，保证回程流量始终走 bridge1。
        # 注意：不能用 "ip -6 route del unreachable" 清理，该命令会误删同前缀的所有路由。
        ip -6 route add "${PREFIX}::/64" dev "$IFACE_UP" metric 100 2>/dev/null
        ip -6 neigh show dev "$IFACE_UP" 2>/dev/null \
            | busybox grep -v '^fe80' \
            | busybox grep -v FAILED \
            | busybox awk '{print $1}' \
            | while read addr; do
                # 跳过网关自身地址
                case "$addr" in
                    "${PREFIX}::1") continue ;;
                esac
                case "$addr" in
                    "${PREFIX}:"*)
                        # 当前前缀的地址：直接代理
                        if ! ip -6 neigh show proxy dev "$WAN_ACTIVE" 2>/dev/null | busybox grep -qw "$addr"; then
                            ip -6 neigh add proxy "$addr" dev "$WAN_ACTIVE" 2>/dev/null
                            echo "[ndp] +proxy $addr"
                        fi
                        ;;
                    *)
                        # 旧前缀的地址：提取主机标识符，推算当前前缀的地址并代理
                        # 先用 sed 将 :: 展开为完整 8 段地址，再用 awk 提取后4段
                        FULL_ADDR=$(echo "$addr" | busybox sed 's/::/:0000:0000:0000:0000:0000:0000:0000:0000/' | busybox awk -F: '{n=split($0,a,":"); if(n>=8) print a[5]":"a[6]":"a[7]":"a[8]; else print ""}')
                        if [ -n "$FULL_ADDR" ]; then
                            HOST_ID=$(echo "$FULL_ADDR" | busybox awk -F: '{print $1":"$2":"$3":"$4}')
                            # 验证主机标识符非全 0（避免 ::1 这种特殊地址）
                            case "$HOST_ID" in
                                0000:0000:0000:*) continue ;;
                                0000:0000:*) continue ;;
                            esac
                            NEW_ADDR="${PREFIX}:${HOST_ID}"
                            case "$NEW_ADDR" in
                                "${PREFIX}::1") continue ;;
                            esac
                            if ! ip -6 neigh show proxy dev "$WAN_ACTIVE" 2>/dev/null | busybox grep -qw "$NEW_ADDR"; then
                                ip -6 neigh add proxy "$NEW_ADDR" dev "$WAN_ACTIVE" 2>/dev/null
                                echo "[ndp] +proxy $NEW_ADDR (derived from $addr)"
                            fi
                        fi
                        ;;
                esac
            done
        sleep "$NDP_INTERVAL"
    done
}

# _watch: 持续监控 WAN 接口/前缀变化，检测到变化时异步触发 restart
_watch() {
    WATCH_INTERVAL="${WATCH_INTERVAL:-10}"
    while true; do
        sleep "$WATCH_INTERVAL"
        # 读取上次保存的状态
        SAVED_WAN=""; SAVED_PREFIX=""
        [ -f "$STATEFILE" ] && . "$STATEFILE"
        [ -z "$SAVED_WAN" ] && continue
        # 检测当前 WAN
        detect_wan
        [ -z "$WAN_ACTIVE" ] && continue
        # WAN 接口或前缀发生变化 → 异步触发 restart（避免自杀问题）
        if [ "$WAN_ACTIVE" != "$SAVED_WAN" ] || [ "$PREFIX" != "$SAVED_PREFIX" ]; then
            echo "[watch] WAN changed: $SAVED_WAN/$SAVED_PREFIX -> $WAN_ACTIVE/$PREFIX, restarting..." > /dev/kmsg 2>/dev/null
            # 异步执行 restart，本进程立即退出（restart 的 stop 会杀掉 _watch）
            busybox setsid sh "$0" restart 0<&- >/dev/null 2>&1 &
            exit 0
        fi
    done
}

stop() {
    # 先杀 _watch 进程，防止 stop 期间 _watch 触发 restart 导致竞态
    if [ -f "$WATCHPIDFILE" ]; then
        kill $(cat "$WATCHPIDFILE") 2>/dev/null
        rm -f "$WATCHPIDFILE"
    fi
    ps | busybox grep "$0 _watch" | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    # Kill RA sender by PIDFILE, then sweep ALL remaining send_ra processes
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
    fi
    ps | busybox grep send_ra | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    echo "[*] RA sender stopped"
    if [ -f "$DHCP6PIDFILE" ]; then
        kill $(cat "$DHCP6PIDFILE") 2>/dev/null
        rm -f "$DHCP6PIDFILE"
    fi
    # Kill ALL dhcp6_server processes
    ps | busybox grep dhcp6_server | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    echo "[*] DHCPv6 server stopped"
    if [ -f "$NDPIDFILE" ]; then
        kill $(cat "$NDPIDFILE") 2>/dev/null
        rm -f "$NDPIDFILE"
    fi
    # Kill ALL _ndp processes
    ps | busybox grep "$0 _ndp" | busybox grep -v grep | busybox awk '{print $2}' | while read pid; do
        kill "$pid" 2>/dev/null
    done
    echo "[*] NDP loop stopped"
    echo "[*] Watch loop stopped"
    # Read saved state (may differ from current detect_wan if WAN switched)
    SAVED_WAN=""; SAVED_PREFIX=""
    [ -f "$STATEFILE" ] && . "$STATEFILE"
    # Clean NDP proxy on ALL candidate WAN interfaces
    for w in $IFACE_WAN; do
        ip -6 neigh show proxy dev "$w" 2>/dev/null \
            | busybox awk '{print $1}' \
            | while read addr; do
                ip -6 neigh del proxy "$addr" dev "$w" 2>/dev/null
            done
    done
    echo "[*] NDP proxy entries cleaned"
    # 删除 bridge1 上所有 SAVED_PREFIX 和当前 PREFIX 的 global 地址
    for pfx in "$SAVED_PREFIX" "$PREFIX"; do
        [ -z "$pfx" ] && continue
        ip -6 addr show "$IFACE_UP" 2>/dev/null \
            | busybox grep 'scope global' \
            | busybox awk '{print $2}' \
            | busybox cut -d/ -f1 \
            | while read addr; do
                case "$addr" in
                    "${pfx}:"*) ip -6 addr del "$addr/64" dev "$IFACE_UP" 2>/dev/null ;;
                esac
            done
        # 删除对应前缀的 unreachable 路由和低 metric 路由
        ip -6 route del unreachable "${pfx}::/64" 2>/dev/null
        ip -6 route del "${pfx}::/64" dev "$IFACE_UP" metric 100 2>/dev/null
    done
    # 注意：restart 时保留 STATEFILE，让 start 能获取旧前缀并发送弃用 RA
    if [ "$1" != "--keep-state" ]; then
        rm -f "$STATEFILE"
    fi
    echo "[*] IPv6 tethering STOPPED"
}

status() {
    echo "=== Config ==="
    echo "  IFACE_UP=$IFACE_UP  IFACE_WAN(candidates)=$IFACE_WAN"
    detect_wan
    echo "  WAN_ACTIVE=$WAN_ACTIVE  PREFIX=${PREFIX}::"
    echo "  RA_INTERVAL=$RA_INTERVAL  DHCP6_ENABLE=$DHCP6_ENABLE"
    echo "  DNS=$DNS_SERVERS"
    echo "=== RA sender ==="
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "  Running (PID $(cat $PIDFILE))"
    else
        echo "  Not running"
    fi
    echo "=== DHCPv6 server ==="
    if [ -f "$DHCP6PIDFILE" ] && kill -0 $(cat "$DHCP6PIDFILE") 2>/dev/null; then
        echo "  Running (PID $(cat $DHCP6PIDFILE))"
    else
        echo "  Not running"
    fi
    echo "=== NDP loop ==="
    if [ -f "$NDPIDFILE" ] && kill -0 $(cat "$NDPIDFILE") 2>/dev/null; then
        echo "  Running (PID $(cat $NDPIDFILE))"
    else
        echo "  Not running"
    fi
    echo "=== Watch loop ==="
    if [ -f "$WATCHPIDFILE" ] && kill -0 $(cat "$WATCHPIDFILE") 2>/dev/null; then
        echo "  Running (PID $(cat $WATCHPIDFILE))"
    else
        echo "  Not running"
    fi
    echo "=== $IFACE_UP IPv6 ==="
    ip -6 addr show "$IFACE_UP" 2>/dev/null | busybox grep inet6
    if [ -n "$WAN_ACTIVE" ]; then
        echo "=== NDP proxy entries (dev $WAN_ACTIVE) ==="
        ip -6 neigh show proxy dev "$WAN_ACTIVE" 2>/dev/null
    else
        echo "=== NDP proxy entries (no WAN active) ==="
    fi
    echo "=== $IFACE_UP neighbors ==="
    ip -6 neigh show dev "$IFACE_UP" 2>/dev/null
    echo "=== forwarding ==="
    echo "  all: $(busybox cat /proc/sys/net/ipv6/conf/all/forwarding)"
    if [ -n "$WAN_ACTIVE" ]; then
        echo "  proxy_ndp($WAN_ACTIVE): $(busybox cat /proc/sys/net/ipv6/conf/$WAN_ACTIVE/proxy_ndp)"
    fi
    echo "  mcast_snoop: $(busybox cat /sys/devices/virtual/net/$IFACE_UP/bridge/multicast_snooping 2>/dev/null)"
}

case "$1" in
    start)  start ;;
    stop)   stop ;;
    restart) stop --keep-state; sleep 1; start ;;
    status) status ;;
    _ndp)   _ndp ;;
    _watch) _watch ;;
    _getprefix) get_prefix ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
