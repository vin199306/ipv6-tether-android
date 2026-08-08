#!/system/bin/sh
# ipv6_tether_boot.sh - Magisk boot script (works in both service.d and post-fs-data.d)
#
# Waits for: 1) IPv6 on any WAN interface  2) bridge1 (USB tether/hotspot) to appear
# Then starts ipv6_tether.sh and monitors it forever.
#
# Handles Android 4.4 quirks:
# - No 'seq' command (use busybox seq)
# - Magisk service.d may not execute on Android 4.4 (install to post-fs-data.d too)

SCRIPT="/data/local/tmp/ipv6_tether.sh"
CONF="/data/local/tmp/ipv6_config.conf"
LOCKFILE="/data/local/tmp/ipv6_boot.lock"
LOG="/data/local/tmp/ipv6_boot.log"

# Load config for interface names
[ -f "$CONF" ] && . "$CONF"
IFACE_WAN="${IFACE_WAN:-rmnet_data0 wlan0}"
IFACE_UP="${IFACE_UP:-bridge1}"

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Single instance check - prevent duplicate when both post-fs-data.d and service.d run
# Verify the PID is actually a running ipv6_tether_boot process (kill -0 alone is
# unreliable on Android 4.4: stale lockfiles or recycled PIDs cause false positives).
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(busybox cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        OLD_CMD=$(busybox cat "/proc/$OLD_PID/cmdline" 2>/dev/null | busybox tr '\0' ' ')
        case "$OLD_CMD" in
            *ipv6_tether_boot*)
                echo "[$(date '+%m-%d %H:%M:%S')] already running (PID $OLD_PID), exit" >> "$LOG"
                exit 0
                ;;
        esac
        echo "[$(date '+%m-%d %H:%M:%S')] stale lockfile (PID $OLD_PID not boot script: '$OLD_CMD'), reclaiming" >> "$LOG"
    else
        echo "[$(date '+%m-%d %H:%M:%S')] stale lockfile (PID $OLD_PID gone), reclaiming" >> "$LOG"
    fi
fi
echo $$ > "$LOCKFILE"

log "=== ipv6_tether boot script started (PID $$) ==="
log "WAN candidates: $IFACE_WAN  LAN: $IFACE_UP"

# Step 1: Wait for IPv6 on any WAN interface
log "waiting for IPv6 on any WAN interface ($IFACE_WAN)..."
WAIT_COUNT=0
for i in $(busybox seq 1 90); do
    for iface in $IFACE_WAN; do
        if ip -6 addr show "$iface" 2>/dev/null | busybox grep -q 'scope global'; then
            log "IPv6 ready on $iface (after ${WAIT_COUNT}s)"
            break 2
        fi
    done
    WAIT_COUNT=$((WAIT_COUNT + 10))
    sleep 10
done

# Final check
WAN_FOUND=""
for iface in $IFACE_WAN; do
    if ip -6 addr show "$iface" 2>/dev/null | busybox grep -q 'scope global'; then
        WAN_FOUND="$iface"
        break
    fi
done
if [ -z "$WAN_FOUND" ]; then
    log "ERROR: no global IPv6 on any WAN interface after ${WAIT_COUNT}s, abort"
    rm -f "$LOCKFILE"
    exit 1
fi

# Step 2: Wait for bridge1 to appear (USB tether or hotspot enabled by user)
log "waiting for $IFACE_UP to appear (enable USB tether or hotspot)..."
for i in $(busybox seq 1 120); do
    if ip link show "$IFACE_UP" >/dev/null 2>&1; then
        log "$IFACE_UP appeared (after ${i}0s)"
        break
    fi
    sleep 10
done

if ! ip link show "$IFACE_UP" >/dev/null 2>&1; then
    log "WARNING: $IFACE_UP not found after 1200s, will keep waiting in monitor loop"
fi

# Step 3: Start service
log "starting ipv6_tether service..."
sh "$SCRIPT" start >> "$LOG" 2>&1
log "service start attempted"

# Step 4: Monitor loop — 仅负责进程存活检查和 bridge1 存在性
# WAN 切换由 ipv6_tether.sh 内的 _watch 循环负责，避免双重 restart 竞态
SERVICE_RUNNING=1
while true; do
    sleep 15

    # Check if bridge1 still exists
    if ! ip link show "$IFACE_UP" >/dev/null 2>&1; then
        if [ "$SERVICE_RUNNING" = "1" ]; then
            log "$IFACE_UP disappeared, stopping service..."
            sh "$SCRIPT" stop >> "$LOG" 2>&1
            SERVICE_RUNNING=0
        fi
        log "waiting for $IFACE_UP to reappear..."
        continue
    fi

    # bridge1 exists again
    if [ "$SERVICE_RUNNING" = "0" ]; then
        log "$IFACE_UP reappeared, starting service..."
        sleep 2
        sh "$SCRIPT" start >> "$LOG" 2>&1
        SERVICE_RUNNING=1
        continue
    fi

    # Check if daemons died (WAN 切换由 _watch 负责，此处只处理进程崩溃)
    RA_PID=$(cat /data/local/tmp/ipv6_ra.pid 2>/dev/null)
    DHCP6_PID=$(cat /data/local/tmp/ipv6_dhcp6.pid 2>/dev/null)
    NDP_PID=$(cat /data/local/tmp/ipv6_ndp.pid 2>/dev/null)
    NEED_RESTART=0

    if [ -z "$RA_PID" ] || ! kill -0 "$RA_PID" 2>/dev/null; then
        log "RA sender died, restarting..."
        NEED_RESTART=1
    elif [ -z "$DHCP6_PID" ] || ! kill -0 "$DHCP6_PID" 2>/dev/null; then
        log "DHCPv6 died, restarting..."
        NEED_RESTART=1
    elif [ -z "$NDP_PID" ] || ! kill -0 "$NDP_PID" 2>/dev/null; then
        log "NDP loop died, restarting..."
        NEED_RESTART=1
    fi

    if [ "$NEED_RESTART" = "1" ]; then
        sh "$SCRIPT" restart >> "$LOG" 2>&1
        # 验证 restart 后进程确实启动
        sleep 2
        RA_PID=$(cat /data/local/tmp/ipv6_ra.pid 2>/dev/null)
        if [ -z "$RA_PID" ] || ! kill -0 "$RA_PID" 2>/dev/null; then
            log "WARNING: RA sender still not running after restart"
        fi
    fi
done
