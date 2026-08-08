@echo off
setlocal enableextensions

echo ==========================================
echo   IPv6 Tethering Uninstall
echo ==========================================
echo.

where adb >nul 2>&1
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [FAILED] adb not found             ##
    echo ##                                      ##
    echo ##########################################
    echo.
    pause
    exit /b 1
)

echo [1/3] Stopping service...
adb shell su -c sh /data/local/tmp/ipv6_tether.sh stop 2>nul

echo [2/3] Cleaning post_boot.sh injection...
adb shell "su -c 'mount -o rw,remount /system 2>/dev/null; busybox awk -v m=\"# IPv6 tether autostart (added by ipv6-tether-android)\" '\''index($0,m) { exit } { print }'\'' /system/etc/init.qcom.post_boot.sh > /data/local/tmp/post_boot.clean 2>/dev/null; if [ -s /data/local/tmp/post_boot.clean ]; then cat /data/local/tmp/post_boot.clean > /system/etc/init.qcom.post_boot.sh; fi; rm -f /data/local/tmp/post_boot.clean; mount -o ro,remount /system 2>/dev/null'"

echo [3/3] Removing files...
adb shell "su -c 'rm -f /data/local/tmp/send_ra /data/local/tmp/dhcp6_server /data/local/tmp/ipv6_tether.sh /data/local/tmp/ipv6_tether_boot.sh /data/local/tmp/ipv6_config.conf /data/local/tmp/config.conf /data/local/tmp/deploy.sh /data/local/tmp/ipv6_ra.pid /data/local/tmp/ipv6_ndp.pid /data/local/tmp/ipv6_dhcp6.pid /data/local/tmp/ipv6_watch.pid /data/local/tmp/ipv6_state /data/local/tmp/ipv6_boot.lock /data/local/tmp/ipv6_boot.log'"
adb shell "su -c 'rm -f /data/adb/service.d/ipv6_tether_boot.sh /data/adb/post-fs-data.d/ipv6_tether_boot.sh'"

echo.
echo ##########################################
echo ##                                      ##
echo ##   [SUCCESS] Uninstall completed      ##
echo ##                                      ##
echo ##   All files and services removed     ##
echo ##                                      ##
echo ##########################################
echo.
pause
