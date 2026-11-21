#!/bin/sh
# 在 chroot 内执行：安装 GPU 软件栈（mesa + 测试工具）
# 由 build-alpindroid.sh 调用，需 root 且已挂载 /proc /sys /dev
set -e

echo "  → 切换阿里云镜像源（官方源国内极慢）"
cat > /etc/apk/repositories <<'EOF'
https://mirrors.aliyun.com/alpine/v3.23/main
https://mirrors.aliyun.com/alpine/v3.23/community
EOF

echo "  → apk update"
apk update >/dev/null 2>&1 || { echo "    apk update 失败"; exit 1; }

echo "  → 安装 mesa 栈"
apk add --no-cache \
    mesa \
    mesa-dri-gallium \
    mesa-gbm \
    mesa-egl \
    mesa-gles \
    mesa-gl \
    mesa-utils \
    libdrm-tests \
    >/dev/null 2>&1 || { echo "    mesa 安装失败"; exit 1; }

echo "  → 验证 DRI 驱动"
for d in panfrost_dri.so kms_swrast_dri.so swrast_dri.so; do
    if [ -f "/usr/lib/dri/$d" ]; then
        echo "    OK   $d"
    else
        echo "    FAIL $d 缺失"
        exit 1
    fi
done

echo "  → 验证 eglinfo"
if command -v eglinfo >/dev/null 2>&1; then
    echo "    OK   eglinfo"
else
    echo "    FAIL eglinfo 未安装"
    exit 1
fi

echo "  → 清理缓存"
rm -rf /var/cache/apk/*

echo "  → GPU 栈完成"
apk info -v mesa 2>/dev/null | head -1 | sed 's/^/    版本: /'