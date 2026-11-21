#!/bin/sh
# 在 Alpine aarch64 rootfs 内执行命令（服务器侧使用）。
#
# 执行方式自动选择（EXEC_MODE 可强制）：
#   qemu   —— rootfs 内有 usr/bin/qemu-aarch64-static 时，显式用它（不依赖宿主 binfmt）
#   binfmt —— 宿主已注册 binfmt_misc/qemu-aarch64 时，直接 chroot，由内核拉起模拟器
#
# 同时自动注入 HTTP/HTTPS 代理（默认 127.0.0.1:7897），供 apk 走加速器。
#
# 用法:
#   ./alpine-run.sh apk --version
#   echo '<passwd>' | ./alpine-run.sh apk update      # 无 tty：sudo -S 从 stdin 读密码
#   ./alpine-run.sh sh -c 'cat /etc/alpine-release'
#   PROXY_PORT=1080 ./alpine-run.sh apk update        # 换代理端口
#   ROOTFS=/path/to/rootfs ./alpine-run.sh uname -m   # 换 rootfs
#   EXEC_MODE=binfmt ./alpine-run.sh uname -m         # 强制走 binfmt
#
set -e

R="${ROOTFS:-$HOME/alpindroid/work/rootfs}"
# 注意用 ${PROXY_PORT-...}（单个 -）：显式传空串表示不走代理
PROXY_PORT="${PROXY_PORT-7897}"
Q=/usr/bin/qemu-aarch64-static
BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64

binfmt_ready() {
    [ -f "$BINFMT" ] && grep -qs '^enabled' "$BINFMT"
}

MODE="${EXEC_MODE:-auto}"
if [ "$MODE" = auto ]; then
    if [ -x "$R$Q" ]; then
        MODE=qemu
    elif binfmt_ready; then
        MODE=binfmt
    else
        MODE=none
    fi
fi

case "$MODE" in
    qemu)
        [ -x "$R$Q" ] || { echo "错误: $R$Q 不存在" >&2; exit 1; }
        ;;
    binfmt)
        binfmt_ready || {
            echo "错误: 宿主未注册 binfmt qemu-aarch64: $BINFMT" >&2
            echo "  修复: sudo update-binfmts --enable qemu-aarch64" >&2
            exit 1
        }
        ;;
    *)
        echo "错误: 既没有 $R$Q，宿主也没注册 binfmt qemu-aarch64" >&2
        echo "  修复(二选一):" >&2
        echo "    sudo install -m 755 /usr/bin/qemu-aarch64-static $R/usr/bin/qemu-aarch64-static" >&2
        echo "    sudo update-binfmts --enable qemu-aarch64" >&2
        exit 1
        ;;
esac

if [ $# -eq 0 ]; then
    set -- /bin/sh
fi

# guest 内执行的包装脚本：注入代理后 exec 实际命令
# PROXY_PORT 为空串时表示不走代理（例如加速器未启动、或改用国内镜像）
INNER='
if [ -n "'"$PROXY_PORT"'" ]; then
    export http_proxy="http://127.0.0.1:'"$PROXY_PORT"'"
    export https_proxy="$http_proxy"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$http_proxy"
fi
exec "$@"
'

# 四种组合显式展开：不能把 sudo 参数拼成字符串（空参数 "${x}" 展开时会被吞掉）
if [ "$MODE" = qemu ]; then
    if [ -t 0 ]; then
        exec sudo chroot  "$R" "$Q" /bin/sh -c "$INNER" sh "$@"
    else
        exec sudo -S -p '' chroot "$R" "$Q" /bin/sh -c "$INNER" sh "$@"
    fi
else
    if [ -t 0 ]; then
        exec sudo chroot  "$R" /bin/sh -c "$INNER" sh "$@"
    else
        exec sudo -S -p '' chroot "$R" /bin/sh -c "$INNER" sh "$@"
    fi
fi
