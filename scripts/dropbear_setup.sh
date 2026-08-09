#!/system/bin/sh
# dropbear_setup.sh - 在 Android 4.4 上配置 dropbear SSH (root 密钥 + 密码登录)
# 用法: su -c 'sh /data/local/tmp/dropbear_setup.sh start|stop|status'
# 依赖: dropbear (静态 musl multi-call) 已推送至 /data/local/tmp/dropbear
DB="/data/local/tmp/dropbear"
KEY="/data/local/tmp/dropbear_rsa_host_key"
AUTH="/root/.ssh/authorized_keys"
PORT="22"

# _ensure_deps: 创建 dropbear 运行所需的系统文件（幂等）
_ensure_deps() {
    mount -o remount,rw / 2>/dev/null
    # 1. /etc/passwd（dropbear 需 getpwnam 获取家目录）
    if [ ! -f /etc/passwd ]; then
        echo 'root:x:0:0:root:/root:/system/bin/sh' > /etc/passwd
        chmod 644 /etc/passwd
        echo "[*] created /etc/passwd"
    fi
    # 2. /etc/shells（dropbear 校验用户 shell 必须在此列表中）
    if [ ! -f /etc/shells ]; then
        printf '/system/bin/sh\n/bin/sh\n' > /etc/shells
        chmod 644 /etc/shells
        echo "[*] created /etc/shells"
    fi
    # 3. /etc/dropbear（dropbear -R 自动生成 ed25519/ecdsa hostkey）
    mkdir -p /etc/dropbear
    chmod 700 /etc/dropbear
    # 4. root 家目录 + authorized_keys
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # 5. scp 符号链接：dropbearmulti 以 "scp" 名调用时提供 SCP 传输功能
    [ -e /data/local/tmp/scp ] || ln -s "$DB" /data/local/tmp/scp
}

# _is_running: 是否有 dropbear 进程在运行
_is_running() {
    ps | busybox grep "dropbear" | busybox grep -v grep | busybox grep -qv "$DB_ME" && echo yes || echo no
}
DB_ME="$$"

case "$1" in
    start)
        _ensure_deps
        # 导出完整 Android 环境，避免登录 shell 缺 PATH / mkshrc 里 getprop not found
        export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin:/data/local/tmp
        export HOME=/root
        export HOSTNAME=android
        export USER=root
        # 存在 authorized_keys 则启用密钥登录；不存在时仅密码登录
        if [ -f "$AUTH" ]; then
            chmod 600 "$AUTH"
        else
            echo "[*] warning: $AUTH missing, password-only auth"
        fi
        # 杀掉所有旧 dropbear 进程
        ps | busybox grep "dropbear" | busybox grep -v grep | busybox awk '{print $2}' | while read p; do
            [ "$p" != "$DB_ME" ] && kill "$p" 2>/dev/null
        done
        sleep 1
        # -R 自动生成缺失 hostkey, -E 日志到 stderr（去掉 -s 启用密码登录）
        busybox setsid "$DB" -p "$PORT" -r "$KEY" -R -E 0<&- >/dev/null 2>&1 &
        sleep 1
        if [ "$(_is_running)" = "yes" ]; then
            echo "[*] dropbear running on port $PORT"
        else
            echo "ERROR: dropbear failed to start"
            "$DB" -p "$PORT" -r "$KEY" -R -E
        fi
        ;;
    stop)
        ps | busybox grep "dropbear" | busybox grep -v grep | busybox awk '{print $2}' | while read p; do
            [ "$p" != "$DB_ME" ] && { kill "$p" 2>/dev/null; echo "[*] killed $p"; }
        done
        echo "[*] dropbear stopped"
        ;;
    status)
        if [ "$(_is_running)" = "yes" ]; then
            echo "dropbear running on port $PORT"
        else
            echo "dropbear not running"
        fi
        ls -la "$KEY" "$AUTH" 2>/dev/null
        ;;
    *) echo "Usage: $0 {start|stop|status}" ;;
esac
