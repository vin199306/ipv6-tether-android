#!/system/bin/sh
# deploy.sh - device-side deploy script (needs root)
# Pushed to /data/local/tmp/ by install.bat
# Usage: su -c 'sh /data/local/tmp/deploy.sh'

TMP="/data/local/tmp"
MAGISK_SVC="/data/adb/service.d"

echo "=========================================="
echo "  IPv6 Tethering Deploy (Android 4.4)"
echo "=========================================="

# Check root: must be able to write /data/adb
if [ ! -w /data/adb ] && [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo ""
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [FAILED] root required             ##"
    echo "##                                      ##"
    echo "##   Run via:                           ##"
    echo "##   su -c 'sh /data/local/tmp/deploy.sh'"
    echo "##                                      ##"
    echo "##########################################"
    exit 1
fi

# Check busybox
if ! command -v busybox >/dev/null 2>&1; then
    echo ""
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [FAILED] busybox not found         ##"
    echo "##                                      ##"
    echo "##   Install Magisk or busybox first    ##"
    echo "##                                      ##"
    echo "##########################################"
    exit 1
fi

# Check files
for f in send_ra dhcp6_server ipv6_tether.sh ipv6_tether_boot.sh config.conf; do
    if [ ! -f "$TMP/$f" ]; then
        echo ""
        echo "##########################################"
        echo "##                                      ##"
        echo "##   [FAILED] missing $TMP/$f"
        echo "##                                      ##"
        echo "##########################################"
        exit 1
    fi
done

echo "[1/5] Setting file permissions..."
chmod 755 "$TMP/send_ra" "$TMP/dhcp6_server" "$TMP/ipv6_tether.sh" "$TMP/ipv6_tether_boot.sh"
if [ $? -ne 0 ]; then
    echo ""
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [FAILED] chmod failed              ##"
    echo "##                                      ##"
    echo "##########################################"
    exit 1
fi

echo "[2/5] Copying config.conf -> ipv6_config.conf..."
cp "$TMP/config.conf" "$TMP/ipv6_config.conf"

# Load config
. "$TMP/ipv6_config.conf"

echo "[3/5] Installing Magisk autostart..."
if [ "$BOOT_AUTOSTART" = "1" ]; then
    if [ -d "$MAGISK_SVC" ]; then
        cp "$TMP/ipv6_tether_boot.sh" "$MAGISK_SVC/ipv6_tether_boot.sh"
        chmod 755 "$MAGISK_SVC/ipv6_tether_boot.sh"
        echo "  Installed to $MAGISK_SVC/ipv6_tether_boot.sh"
    else
        echo ""
        echo "##########################################"
        echo "##                                      ##"
        echo "##   [WARNING] Magisk service.d absent  ##"
        echo "##                                      ##"
        echo "##   $MAGISK_SVC not found"
        echo "##   Magisk not installed or too old    ##"
        echo "##   Skipped autostart                  ##"
        echo "##                                      ##"
        echo "##########################################"
    fi
else
    echo "  BOOT_AUTOSTART=0, skipped autostart"
fi

echo "[4/5] Stopping old service (if any)..."
sh "$TMP/ipv6_tether.sh" stop 2>/dev/null || true

echo "[5/5] Starting IPv6 tethering service..."
sh "$TMP/ipv6_tether.sh" start
if [ $? -ne 0 ]; then
    echo ""
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [FAILED] start service failed      ##"
    echo "##                                      ##"
    echo "##   Check:                             ##"
    echo "##   - WAN interface has IPv6 address   ##"
    echo "##   - bridge1 exists                   ##"
    echo "##                                      ##"
    echo "##########################################"
    exit 1
fi

# Verify all daemons are running
RA_PID=$(cat "$TMP/ipv6_ra.pid" 2>/dev/null)
DHCP6_PID=$(cat "$TMP/ipv6_dhcp6.pid" 2>/dev/null)
NDP_PID=$(cat "$TMP/ipv6_ndp.pid" 2>/dev/null)
FAIL=0

if [ -z "$RA_PID" ] || ! kill -0 "$RA_PID" 2>/dev/null; then
    FAIL=1
fi
if [ "$DHCP6_ENABLE" = "1" ]; then
    if [ -z "$DHCP6_PID" ] || ! kill -0 "$DHCP6_PID" 2>/dev/null; then
        FAIL=1
    fi
fi
if [ -z "$NDP_PID" ] || ! kill -0 "$NDP_PID" 2>/dev/null; then
    FAIL=1
fi

echo ""
if [ "$FAIL" = "1" ]; then
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [FAILED] some daemons not running  ##"
    echo "##                                      ##"
    echo "##   Check status:                      ##"
    echo "##   sh /data/local/tmp/ipv6_tether.sh  ##"
    echo "##   status                              ##"
    echo "##                                      ##"
    echo "##########################################"
    exit 1
else
    echo "##########################################"
    echo "##                                      ##"
    echo "##   [SUCCESS] Deploy completed!        ##"
    echo "##                                      ##"
    echo "##   RA sender   PID $RA_PID  running   ##"
    echo "##   DHCPv6      PID $DHCP6_PID running  ##"
    echo "##   NDP proxy   PID $NDP_PID  running   ##"
    echo "##                                      ##"
    echo "##   Client test:                       ##"
    echo "##   open https://test-ipv6.com/        ##"
    echo "##   Expected score: 10/10              ##"
    echo "##                                      ##"
    echo "##########################################"
fi

echo ""
echo "=========================================="
echo "  Commands"
echo "=========================================="
echo "Status:  su -c 'sh /data/local/tmp/ipv6_tether.sh status'"
echo "Restart: su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"
echo "Stop:    su -c 'sh /data/local/tmp/ipv6_tether.sh stop'"
echo ""
echo "Client test:"
echo "  ping -6 2400:3200::1"
echo "  open https://test-ipv6.com/"
