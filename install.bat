@echo off
setlocal enableextensions

echo ==========================================
echo   IPv6 Tethering Deploy (Android 4.4)
echo ==========================================
echo.

REM Check adb
where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb not found. Install Android Platform Tools first.
    echo         https://developer.android.com/studio/releases/platform-tools
    echo         Add adb.exe folder to PATH.
    pause
    exit /b 1
)

REM Check device
echo [1/4] Checking device connection...
adb get-state >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No device detected. Check:
    echo         1. USB connected
    echo         2. USB debugging enabled
    echo         3. Authorized this PC on phone
    pause
    exit /b 1
)
echo       Device connected:
adb get-serialno
echo.

REM Script dir
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

REM Push files
echo [2/4] Pushing files to device...
adb push "%SCRIPT_DIR%\send_ra" /data/local/tmp/send_ra
adb push "%SCRIPT_DIR%\dhcp6_server" /data/local/tmp/dhcp6_server
adb push "%SCRIPT_DIR%\ipv6_tether.sh" /data/local/tmp/ipv6_tether.sh
adb push "%SCRIPT_DIR%\ipv6_tether_boot.sh" /data/local/tmp/ipv6_tether_boot.sh
adb push "%SCRIPT_DIR%\config.conf" /data/local/tmp/config.conf
adb push "%SCRIPT_DIR%\deploy.sh" /data/local/tmp/deploy.sh
echo       Push done.
echo.

REM Deploy (needs root)
echo [3/4] Running deploy script (device must be rooted + Magisk installed)...
echo       Please grant root on phone if prompted...
adb shell su -c sh /data/local/tmp/deploy.sh
if errorlevel 1 (
    echo.
    echo [ERROR] Deploy failed. Possible reasons:
    echo         1. Device not rooted
    echo         2. Magisk not installed (no busybox)
    echo         3. Root not granted on phone
    echo.
    echo Manual check: adb shell su -c sh /data/local/tmp/deploy.sh
    pause
    exit /b 1
)
echo.

echo [4/4] Deploy finished.
echo.
echo ==========================================
echo   Commands
echo ==========================================
echo Status:  adb shell su -c sh /data/local/tmp/ipv6_tether.sh status
echo Restart: adb shell su -c sh /data/local/tmp/ipv6_tether.sh restart
echo Stop:    adb shell su -c sh /data/local/tmp/ipv6_tether.sh stop
echo.
echo Client test: open https://test-ipv6.com/
echo.
pause
