@echo off
chcp 65001 >nul
setlocal

echo ==========================================
echo   IPv6 Tethering 一键部署 (Android 4.4)
echo ==========================================
echo.

REM 检查 adb
where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未找到 adb，请先安装 Android Platform Tools
    echo         下载: https://developer.android.com/studio/releases/platform-tools
    echo         并将 adb.exe 所在目录加入 PATH
    pause
    exit /b 1
)

REM 检查设备连接
echo [1/4] 检查设备连接...
adb get-state >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未检测到设备，请确认:
    echo         1. USB 已连接
    echo         2. 已开启 USB 调试
    echo         3. 已在手机上授权此电脑
    pause
    exit /b 1
)
echo       设备已连接: 
adb get-serialno
echo.

REM 获取脚本所在目录
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

REM 推送文件
echo [2/4] 推送文件到设备...
adb push "%SCRIPT_DIR%\send_ra" /data/local/tmp/send_ra
adb push "%SCRIPT_DIR%\dhcp6_server" /data/local/tmp/dhcp6_server
adb push "%SCRIPT_DIR%\ipv6_tether.sh" /data/local/tmp/ipv6_tether.sh
adb push "%SCRIPT_DIR%\ipv6_tether_boot.sh" /data/local/tmp/ipv6_tether_boot.sh
adb push "%SCRIPT_DIR%\config.conf" /data/local/tmp/config.conf
adb push "%SCRIPT_DIR%\deploy.sh" /data/local/tmp/deploy.sh
echo       推送完成
echo.

REM 执行部署（需 root）
echo [3/4] 执行部署脚本（设备需已 root + 安装 Magisk）...
echo       请在手机上授权 root 权限（如弹出请求框）...
adb shell "su -c 'sh /data/local/tmp/deploy.sh'"
if errorlevel 1 (
    echo.
    echo [ERROR] 部署失败，可能原因:
    echo         1. 设备未 root
    echo         2. 未安装 Magisk（缺少 busybox）
    echo         3. 手机上未授权 root
    echo.
    echo 可手动排查: adb shell "su -c 'sh /data/local/tmp/deploy.sh'"
    pause
    exit /b 1
)
echo.

echo [4/4] 部署流程结束
echo.
echo ==========================================
echo   后续操作
echo ==========================================
echo 查看状态: adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh status'"
echo 重启服务: adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"
echo 停止服务: adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh stop'"
echo.
echo 客户端测试: 打开浏览器访问 https://test-ipv6.com/
echo.
pause
