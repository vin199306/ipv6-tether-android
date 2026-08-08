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

# 默认值（config 不存在时使用）
IFACE_UP="bridge1"
IFACE_WAN="rmnet_data0"
RA_INTERVAL="3"
DNS_SERVERS="2400:3200::1,2400:3200:baba::1"
DHCP6_ENABLE="1"
NDP_INTERVAL="5"

# 加载配置
[ -f "$CONF" ] && . "$CONF"

get_prefix() {
    ip -6 addr show "$IFACE_WAN" 2>/dev/null \
        | busybox grep 'scope global' \
        | busybox awk '{print $2}' \
        | busybox cut -d/ -f1 \
        | busybox cut -d: -f1-4 \
        | busybox head -1
}

start() {
    PREFIX=$(get_prefix)
    if [ -z "$PREFIX" ]; then
        echo "ERROR: no global IPv6 on $IFACE_WAN"
        exit 1
    fi
    echo "[*] WAN prefix: ${PREFIX}::/64"

    ip -6 addr add "${PREFIX}::1/64" dev "$IFACE_UP" 2>/dev/null
    echo "[*] $IFACE_UP IPv6: ${PREFIX}::1/64"

    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/$IFACE_UP/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/$IFACE_WAN/proxy_ndp
    echo 1 > /proc/sys/net/ipv6/conf/all/proxy_ndp

    # 关闭 bridge multicast snooping（防止组播RA被过滤）
    echo 0 > /sys/devices/virtual/net/$IFACE_UP/bridge/multicast_snooping 2>/dev/null

    # 关闭 bridge-nf-call-ip6tables（防止 IPv6 转发被 ip6tables 拦截）
    echo 0 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null

    # 删除 WAN 上的 /64 on-link 路由，避免与桥接接口路由冲突
    ip -6 route del "${PREFIX}::/64" dev "$IFACE_WAN" 2>/dev/null

    ip -6 neigh add proxy "${PREFIX}::1" dev "$IFACE_WAN" 2>/dev/null

    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "[*] RA already running (PID $(cat $PIDFILE))"
    else
        busybox setsid "$RA_BIN" "$IFACE_UP" "${PREFIX}::" "$RA_INTERVAL" "$DNS_SERVERS" 0<&- &
        echo $! > "$PIDFILE"
        echo "[*] RA sender started (PID $(cat $PIDFILE))"
    fi

    if [ "$DHCP6_ENABLE" = "1" ]; then
        if [ -f "$DHCP6PIDFILE" ] && kill -0 $(cat "$DHCP6PIDFILE") 2>/dev/null; then
            echo "[*] DHCPv6 already running (PID $(cat $DHCP6PIDFILE))"
        else
            busybox setsid "$DHCP6_BIN" "$IFACE_UP" "${PREFIX}::" "$DNS_SERVERS" 0<&- &
            echo $! > "$DHCP6PIDFILE"
            echo "[*] DHCPv6 server started (PID $(cat $DHCP6PIDFILE))"
        fi
    fi

    if [ -f "$NDPIDFILE" ] && kill -0 $(cat "$NDPIDFILE") 2>/dev/null; then
        echo "[*] NDP loop already running (PID $(cat $NDPIDFILE))"
    else
        NDP_INTERVAL_ARG="$NDP_INTERVAL" busybox setsid sh "$0" _ndp 0<&- &
        echo $! > "$NDPIDFILE"
        echo "[*] NDP proxy loop started (PID $(cat $NDPIDFILE))"
    fi
    echo "[*] IPv6 tethering is ACTIVE"
}

_ndp() {
    NDP_INTERVAL="${NDP_INTERVAL:-5}"
    while true; do
        PREFIX=$(get_prefix)
        ip -6 neigh show dev "$IFACE_UP" 2>/dev/null \
            | busybox grep -v '^fe80' \
            | busybox grep -v FAILED \
            | busybox awk '{print $1}' \
            | while read addr; do
                case "$addr" in
                    "${PREFIX}::1") continue ;;
                esac
                if ! ip -6 neigh show proxy dev "$IFACE_WAN" 2>/dev/null | busybox grep -qw "$addr"; then
                    ip -6 neigh add proxy "$addr" dev "$IFACE_WAN" 2>/dev/null
                    echo "[ndp] +proxy $addr"
                fi
            done
        sleep "$NDP_INTERVAL"
    done
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
        echo "[*] RA sender stopped"
    fi
    if [ -f "$DHCP6PIDFILE" ]; then
        kill $(cat "$DHCP6PIDFILE") 2>/dev/null
        rm -f "$DHCP6PIDFILE"
        echo "[*] DHCPv6 server stopped"
    fi
    if [ -f "$NDPIDFILE" ]; then
        kill $(cat "$NDPIDFILE") 2>/dev/null
        rm -f "$NDPIDFILE"
        echo "[*] NDP loop stopped"
    fi
    ip -6 neigh show proxy dev "$IFACE_WAN" 2>/dev/null \
        | busybox awk '{print $1}' \
        | while read addr; do
            ip -6 neigh del proxy "$addr" dev "$IFACE_WAN" 2>/dev/null
        done
    echo "[*] NDP proxy entries cleaned"
    PREFIX=$(get_prefix)
    [ -n "$PREFIX" ] && ip -6 addr del "${PREFIX}::1/64" dev "$IFACE_UP" 2>/dev/null
    echo "[*] IPv6 tethering STOPPED"
}

status() {
    echo "=== Config ==="
    echo "  IFACE_UP=$IFACE_UP  IFACE_WAN=$IFACE_WAN"
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
    echo "=== $IFACE_UP IPv6 ==="
    ip -6 addr show "$IFACE_UP" 2>/dev/null | busybox grep inet6
    echo "=== NDP proxy entries ==="
    ip -6 neigh show proxy dev "$IFACE_WAN" 2>/dev/null
    echo "=== $IFACE_UP neighbors ==="
    ip -6 neigh show dev "$IFACE_UP" 2>/dev/null
    echo "=== forwarding ==="
    echo "  all: $(busybox cat /proc/sys/net/ipv6/conf/all/forwarding)"
    echo "  proxy_ndp($IFACE_WAN): $(busybox cat /proc/sys/net/ipv6/conf/$IFACE_WAN/proxy_ndp)"
    echo "  mcast_snoop: $(busybox cat /sys/devices/virtual/net/$IFACE_UP/bridge/multicast_snooping 2>/dev/null)"
}

case "$1" in
    start)  start ;;
    stop)   stop ;;
    restart) stop; sleep 1; start ;;
    status) status ;;
    _ndp)   _ndp ;;
    _getprefix) get_prefix ;;
    *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
