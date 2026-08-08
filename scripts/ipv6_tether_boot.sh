#!/system/bin/sh
# ipv6_tether_boot.sh - Magisk service.d 开机自启脚本
# 位置: /data/adb/service.d/ipv6_tether_boot.sh

SCRIPT="/data/local/tmp/ipv6_tether.sh"

echo "[ipv6_tether] waiting for IPv6 connectivity..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ip -6 addr show rmnet_data0 2>/dev/null | busybox grep -q 'scope global'; then
        echo "[ipv6_tether] IPv6 ready after ${i}0s"
        break
    fi
    sleep 10
done

if ! ip -6 addr show rmnet_data0 2>/dev/null | busybox grep -q 'scope global'; then
    echo "[ipv6_tether] ERROR: no global IPv6, abort"
    exit 1
fi

sh "$SCRIPT" start

PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
echo "[ipv6_tether] monitor started, initial prefix: ${PREV_PREFIX}::"

while true; do
    sleep 30
    CUR_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
    if [ -z "$CUR_PREFIX" ]; then
        continue
    fi
    if [ "$CUR_PREFIX" != "$PREV_PREFIX" ]; then
        echo "[ipv6_tether] prefix changed: ${PREV_PREFIX} -> ${CUR_PREFIX}, restarting..."
        sh "$SCRIPT" restart
        PREV_PREFIX="$CUR_PREFIX"
        continue
    fi
    if [ ! -f /data/local/tmp/ipv6_ra.pid ] || ! kill -0 $(cat /data/local/tmp/ipv6_ra.pid 2>/dev/null) 2>/dev/null; then
        echo "[ipv6_tether] RA died, restarting..."
        sh "$SCRIPT" restart
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        continue
    fi
    if [ ! -f /data/local/tmp/ipv6_dhcp6.pid ] || ! kill -0 $(cat /data/local/tmp/ipv6_dhcp6.pid 2>/dev/null) 2>/dev/null; then
        echo "[ipv6_tether] DHCPv6 died, restarting..."
        sh "$SCRIPT" restart
        PREV_PREFIX=$(sh "$SCRIPT" _getprefix 2>/dev/null)
        continue
    fi
done
