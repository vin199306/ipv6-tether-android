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
    echo "ERROR: root required. Run via: su -c 'sh /data/local/tmp/deploy.sh'"
    exit 1
fi

# Check busybox
if ! command -v busybox >/dev/null 2>&1; then
    echo "ERROR: busybox not found. Install Magisk or busybox first."
    exit 1
fi

# Check files
for f in send_ra dhcp6_server ipv6_tether.sh ipv6_tether_boot.sh config.conf; do
    if [ ! -f "$TMP/$f" ]; then
        echo "ERROR: missing $TMP/$f"
        exit 1
    fi
done

echo "[1/5] Setting file permissions..."
chmod 755 "$TMP/send_ra" "$TMP/dhcp6_server" "$TMP/ipv6_tether.sh" "$TMP/ipv6_tether_boot.sh"

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
        echo "  WARNING: $MAGISK_SVC not found (Magisk not installed or too old)"
        echo "  Skipped autostart. Manual: /data/adb/post-fs-data.d/"
    fi
else
    echo "  BOOT_AUTOSTART=0, skipped autostart"
fi

echo "[4/5] Stopping old service (if any)..."
sh "$TMP/ipv6_tether.sh" stop 2>/dev/null || true

echo "[5/5] Starting IPv6 tethering service..."
sh "$TMP/ipv6_tether.sh" start

echo ""
echo "=========================================="
echo "  Deploy finished!"
echo "=========================================="
echo ""
echo "Verify:"
echo "  su -c 'sh /data/local/tmp/ipv6_tether.sh status'"
echo ""
echo "Client test:"
echo "  ping -6 2400:3200::1"
echo "  open https://test-ipv6.com/"
echo ""
echo "Restart after config change:"
echo "  su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"
