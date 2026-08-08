#!/system/bin/sh
# deploy.sh - device-side deploy script (needs root)
# Pushed to /data/local/tmp/ by install.bat
# Usage: su -c 'sh /data/local/tmp/deploy.sh'

TMP="/data/local/tmp"
MAGISK_SVC="/data/adb/service.d"
MAGISK_PFD="/data/adb/post-fs-data.d"
POST_BOOT="/system/etc/init.qcom.post_boot.sh"
AUTOSTART_MARKER="# IPv6 tether autostart (added by ipv6-tether-android)"

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

echo "[3/5] Installing autostart..."
if [ "$BOOT_AUTOSTART" = "1" ]; then
    # Primary: inject into /system/etc/init.qcom.post_boot.sh (most reliable on Android 4.4)
    # This script is executed by init.qcom.rc service qcom-post-boot on boot.
    # Magisk service.d/post-fs-data.d are unreliable on Android 4.4 (may not trigger).
    POST_BOOT_OK=0
    if [ -f "$POST_BOOT" ]; then
        # Remount /system rw if needed
        mount -o rw,remount /system 2>/dev/null
        # Backup original if not already backed up
        if [ ! -f "${POST_BOOT}.bak" ]; then
            cp "$POST_BOOT" "${POST_BOOT}.bak"
        fi
        # Remove ALL old injections (handles duplicates from previous deploys)
        # Use index() for literal string match (regex treats () as groups)
        busybox awk -v m="$AUTOSTART_MARKER" '
            index($0,m) { skip=2; next }
            skip>0 { skip--; next }
            { print }
        ' "$POST_BOOT" > "${POST_BOOT}.new" 2>/dev/null
        if [ -s "${POST_BOOT}.new" ]; then
            cat "${POST_BOOT}.new" > "$POST_BOOT"
        fi
        rm -f "${POST_BOOT}.new"
        # Append autostart lines (single injection)
        echo "" >> "$POST_BOOT"
        echo "$AUTOSTART_MARKER" >> "$POST_BOOT"
        echo "sh /data/local/tmp/ipv6_tether_boot.sh > /dev/null 2>&1 &" >> "$POST_BOOT"
        if busybox grep -q "$AUTOSTART_MARKER" "$POST_BOOT" 2>/dev/null; then
            echo "  Injected autostart into $POST_BOOT"
            POST_BOOT_OK=1
        else
            echo "  WARNING: failed to inject into $POST_BOOT"
        fi
    else
        echo "  WARNING: $POST_BOOT not found"
    fi

    # Fallback: also install to Magisk service.d and post-fs-data.d (in case post_boot.sh absent)
    if [ -d "$MAGISK_SVC" ]; then
        cp "$TMP/ipv6_tether_boot.sh" "$MAGISK_SVC/ipv6_tether_boot.sh"
        chmod 755 "$MAGISK_SVC/ipv6_tether_boot.sh"
        echo "  Also installed to $MAGISK_SVC/ipv6_tether_boot.sh (fallback)"
    fi
    if [ -d "$MAGISK_PFD" ]; then
        cp "$TMP/ipv6_tether_boot.sh" "$MAGISK_PFD/ipv6_tether_boot.sh"
        chmod 755 "$MAGISK_PFD/ipv6_tether_boot.sh"
        echo "  Also installed to $MAGISK_PFD/ipv6_tether_boot.sh (fallback)"
    fi

    if [ "$POST_BOOT_OK" != "1" ] && [ ! -d "$MAGISK_SVC" ] && [ ! -d "$MAGISK_PFD" ]; then
        echo ""
        echo "##########################################"
        echo "##                                      ##"
        echo "##   [WARNING] No autostart installed   ##"
        echo "##                                      ##"
        echo "##   Neither post_boot.sh nor Magisk    ##"
        echo "##   dirs available. Manual start only. ##"
        echo "##                                      ##"
        echo "##########################################"
    fi
    # Clean up old lockfile so boot script can start fresh after reboot
    rm -f "$TMP/ipv6_boot.lock"
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
