#!/system/bin/sh
# ipv6_tether_boot.sh - Magisk service.d boot script
# Location: /data/adb/service.d/ipv6_tether_boot.sh
#
# Waits for: 1) IPv6 on WAN  2) bridge1 (USB tether/hotspot) to appear
# Then starts ipv6_tether.sh and monitors it forever.

SCRIPT="/data/local/tmp/ipv6_tether.sh"
CONF="/data/local/tmp/ipv6_config.conf"

# Load config for interface names
[ -f "$CONF" ] && . "$CONF"
IFACE_WAN="${IFACE_WAN:-rmnet_data0}"
IFACE_UP="${IFACE_UP:-bridge1}"

LOG="/data/local/tmp/ipv6_boot.log"

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
    echo "[$(date '+%m-%d %H:%M:%S')] $*"
}

log "=== ipv6_tether boot script started ==="
log "WAN=$IFACE_WAN  LAN=$IFACE_UP"

# Step 1: Wait for IPv6 on WAN interface
log "waiting for IPv6 on $IFACE_WAN..."
for i in $(seq 1 60); do
    if ip -6 addr show "$IFACE_WAN" 2>/dev/null | busybox grep -q 'scope global'; then
        log "IPv6 ready on $IFACE_WAN (after ${i}0s)"
        break
    fi
    sleep 10
done

if ! ip -6 addr show "$IFACE_WAN" 2>/dev/null | busybox grep -q 'scope global'; then
    log "ERROR: no global IPv6 on $IFACE_WAN after 600s, abort"
    exit 1
fi

# Step 2: Wait for bridge1 to appear (USB tether or hotspot enabled by user)
log "waiting for $IFACE_UP to appear (enable USB tether or hotspot)..."
for i in $(seq 1 120); do
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

PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
log "monitor started, initial prefix: ${PREV_PREFIX}::"

# Step 4: Monitor loop
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
        # Wait for bridge1 to reappear
        log "waiting for $IFACE_UP to reappear..."
        continue
    fi

    # bridge1 exists again
    if [ "$SERVICE_RUNNING" = "0" ]; then
        log "$IFACE_UP reappeared, starting service..."
        sleep 2  # give bridge a moment to settle
        sh "$SCRIPT" start >> "$LOG" 2>&1
        SERVICE_RUNNING=1
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        log "service restarted, prefix: ${PREV_PREFIX}::"
        continue
    fi

    # Check prefix change
    CUR_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
    if [ -n "$CUR_PREFIX" ] && [ "$CUR_PREFIX" != "$PREV_PREFIX" ]; then
        log "prefix changed: ${PREV_PREFIX} -> ${CUR_PREFIX}, restarting..."
        sh "$SCRIPT" restart >> "$LOG" 2>&1
        PREV_PREFIX="$CUR_PREFIX"
        continue
    fi

    # Check if daemons died
    if [ ! -f /data/local/tmp/ipv6_ra.pid ] || ! kill -0 $(cat /data/local/tmp/ipv6_ra.pid 2>/dev/null) 2>/dev/null; then
        log "RA sender died, restarting..."
        sh "$SCRIPT" restart >> "$LOG" 2>&1
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        continue
    fi
    if [ ! -f /data/local/tmp/ipv6_dhcp6.pid ] || ! kill -0 $(cat /data/local/tmp/ipv6_dhcp6.pid 2>/dev/null) 2>/dev/null; then
        log "DHCPv6 died, restarting..."
        sh "$SCRIPT" restart >> "$LOG" 2>&1
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        continue
    fi
    if [ ! -f /data/local/tmp/ipv6_ndp.pid ] || ! kill -0 $(cat /data/local/tmp/ipv6_ndp.pid 2>/dev/null) 2>/dev/null; then
        log "NDP loop died, restarting..."
        sh "$SCRIPT" restart >> "$LOG" 2>&1
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        continue
    fi
done
