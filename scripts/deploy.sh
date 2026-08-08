#!/system/bin/sh
# deploy.sh - 设备端部署脚本（需 root 执行）
# 由 install.bat 推送到 /data/local/tmp/ 后执行
# 用法: su -c 'sh /data/local/tmp/deploy.sh'

set -e
TMP="/data/local/tmp"
MAGISK_SVC="/data/adb/service.d"

echo "=========================================="
echo "  IPv6 Tethering 部署脚本 (Android 4.4)"
echo "=========================================="

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: 需要 root 权限，请用 'su -c' 执行"
    exit 1
fi

# 检查 busybox
if ! command -v busybox >/dev/null 2>&1; then
    echo "ERROR: 未找到 busybox，请先安装 Magisk 或 busybox"
    exit 1
fi

# 检查文件
for f in send_ra dhcp6_server ipv6_tether.sh ipv6_tether_boot.sh config.conf; do
    if [ ! -f "$TMP/$f" ]; then
        echo "ERROR: 缺少 $TMP/$f"
        exit 1
    fi
done

echo "[1/5] 设置文件权限..."
chmod 755 "$TMP/send_ra" "$TMP/dhcp6_server" "$TMP/ipv6_tether.sh" "$TMP/ipv6_tether_boot.sh"

echo "[2/5] 重命名 config.conf -> ipv6_config.conf..."
cp "$TMP/config.conf" "$TMP/ipv6_config.conf"

# 加载配置判断是否安装自启
. "$TMP/ipv6_config.conf"

echo "[3/5] 安装 Magisk 开机自启..."
if [ "$BOOT_AUTOSTART" = "1" ]; then
    if [ -d "$MAGISK_SVC" ]; then
        cp "$TMP/ipv6_tether_boot.sh" "$MAGISK_SVC/ipv6_tether_boot.sh"
        chmod 755 "$MAGISK_SVC/ipv6_tether_boot.sh"
        echo "  已安装到 $MAGISK_SVC/ipv6_tether_boot.sh"
    else
        echo "  WARNING: $MAGISK_SVC 不存在，Magisk 未安装或版本过低"
        echo "  跳过开机自启安装。可手动添加到 /data/adb/post-fs-data.d/"
    fi
else
    echo "  BOOT_AUTOSTART=0，跳过开机自启"
fi

echo "[4/5] 停止旧服务（如有）..."
sh "$TMP/ipv6_tether.sh" stop 2>/dev/null || true

echo "[5/5] 启动 IPv6 共享服务..."
sh "$TMP/ipv6_tether.sh" start

echo ""
echo "=========================================="
echo "  部署完成！"
echo "=========================================="
echo ""
echo "验证:"
echo "  su -c 'sh /data/local/tmp/ipv6_tether.sh status'"
echo ""
echo "客户端测试:"
echo "  ping -6 2400:3200::1"
echo "  浏览器访问 https://test-ipv6.com/"
echo ""
echo "修改配置后重启服务:"
echo "  su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"
