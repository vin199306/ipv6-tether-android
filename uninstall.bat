@echo off
chcp 65001 >nul
setlocal

echo ==========================================
echo   IPv6 Tethering 卸载
echo ==========================================
echo.

where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未找到 adb
    pause
    exit /b 1
)

echo [1/2] 停止服务...
adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh stop'" 2>nul

echo [2/2] 删除文件...
adb shell "su -c 'rm -f /data/local/tmp/send_ra /data/local/tmp/dhcp6_server /data/local/tmp/ipv6_tether.sh /data/local/tmp/ipv6_tether_boot.sh /data/local/tmp/ipv6_config.conf /data/local/tmp/config.conf /data/local/tmp/deploy.sh /data/local/tmp/ipv6_ra.pid /data/local/tmp/ipv6_ndp.pid /data/local/tmp/ipv6_dhcp6.pid'"
adb shell "su -c 'rm -f /data/adb/service.d/ipv6_tether_boot.sh'"

echo.
echo 卸载完成
pause
