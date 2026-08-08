@echo off
setlocal enableextensions

echo ==========================================
echo   IPv6 Tethering Deploy (Android 4.4)
echo ==========================================
echo.

REM Check adb
where adb >nul 2>&1
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [FAILED] adb not found             ##
    echo ##                                      ##
    echo ##   Install Android Platform Tools:    ##
    echo ##   https://developer.android.com/     ##
    echo ##   studio/releases/platform-tools     ##
    echo ##   Add adb.exe folder to PATH         ##
    echo ##                                      ##
    echo ##########################################
    echo.
    pause
    exit /b 1
)

REM Check device
echo [1/4] Checking device connection...
adb get-state >nul 2>&1
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [FAILED] No device detected        ##
    echo ##                                      ##
    echo ##   Check:                             ##
    echo ##   1. USB connected                   ##
    echo ##   2. USB debugging enabled           ##
    echo ##   3. Authorized this PC on phone     ##
    echo ##                                      ##
    echo ##########################################
    echo.
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
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [FAILED] Push files failed         ##
    echo ##                                      ##
    echo ##########################################
    echo.
    pause
    exit /b 1
)
echo       Push done.
echo.

REM Deploy (needs root)
echo [3/4] Running deploy script (device must be rooted + Magisk installed)...
echo       Please grant root on phone if prompted...
adb shell su -c sh /data/local/tmp/deploy.sh
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [FAILED] Deploy failed             ##
    echo ##                                      ##
    echo ##   Possible reasons:                  ##
    echo ##   1. Device not rooted               ##
    echo ##   2. Magisk not installed            ##
    echo ##   3. Root not granted on phone       ##
    echo ##                                      ##
    echo ##   Manual check:                      ##
    echo ##   adb shell su -c sh /data/local/    ##
    echo ##   tmp/deploy.sh                      ##
    echo ##                                      ##
    echo ##########################################
    echo.
    pause
    exit /b 1
)
echo.

REM Verify service is running
echo [4/4] Verifying service...
adb shell su -c sh /data/local/tmp/ipv6_tether.sh status > "%TEMP%\ipv6_status.txt" 2>&1
findstr /C:"ACTIVE" "%TEMP%\ipv6_status.txt" >nul 2>&1
if errorlevel 1 (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [WARNING] Service may not running  ##
    echo ##                                      ##
    echo ##   Check status manually:             ##
    echo ##   adb shell su -c sh /data/local/    ##
    echo ##   tmp/ipv6_tether.sh status          ##
    echo ##                                      ##
    echo ##########################################
    echo.
) else (
    echo.
    echo ##########################################
    echo ##                                      ##
    echo ##   [SUCCESS] Deploy completed!        ##
    echo ##                                      ##
    echo ##   IPv6 tethering is ACTIVE           ##
    echo ##                                      ##
    echo ##   Client test:                       ##
    echo ##   open https://test-ipv6.com/        ##
    echo ##   Expected score: 10/10              ##
    echo ##                                      ##
    echo ##########################################
    echo.
)

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
