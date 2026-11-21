#!/bin/sh
# ============================================================================
# setup-kernel.sh — 准备可直接编译的内核源码树
#
# 从厂商上游克隆 Linux 6.1.31，然后打上 Alpindroid 的全部修改。
#
# 用法：
#   sh scripts/setup-kernel.sh [目标目录]
#   默认目标目录：./build/linux-6.1.31
#
# 完成后可直接编译：
#   cd build/linux-6.1.31
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
#
# 依赖：git、aarch64-linux-gnu-gcc（Debian/Ubuntu: gcc-aarch64-linux-gnu）
# ============================================================================
set -e

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-"$REPO_DIR/build/linux-6.1.31"}
UPSTREAM=${UPSTREAM:-https://github.com/walnutpi/linux.git}
BRANCH=${BRANCH:-6.1.31}

PATCH_FILE="$REPO_DIR/patches/kernel/alpindroid-kernel.patch"
CONFIG_FILE="$REPO_DIR/kernel/config/config-6.1.31-plus"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "检查依赖"
command -v git >/dev/null 2>&1 || die "缺少 git"
[ -f "$PATCH_FILE" ]  || die "缺少 $PATCH_FILE"
[ -f "$CONFIG_FILE" ] || die "缺少 $CONFIG_FILE"
echo "  git      : $(git --version)"
echo "  patch    : $PATCH_FILE ($(wc -c < "$PATCH_FILE") bytes)"
echo "  config   : $CONFIG_FILE"
echo "  upstream : $UPSTREAM (branch $BRANCH)"
echo "  target   : $TARGET"

if [ -e "$TARGET" ]; then
    say "目标目录已存在"
    if [ -d "$TARGET/.git" ]; then
        echo "  复用现有源码树，仅重置并重新打补丁"
        cd "$TARGET"
        git checkout -- . 2>/dev/null || true
        git clean -fd drivers/soc/sunxi 2>/dev/null || true
    else
        die "$TARGET 存在但不是 git 仓库，请手动移除"
    fi
else
    say "克隆上游源码（shallow clone，约 200 MB）"
    mkdir -p "$(dirname "$TARGET")"
    git clone --depth 1 -b "$BRANCH" "$UPSTREAM" "$TARGET"
    cd "$TARGET"
fi

say "应用 Alpindroid 补丁"
cd "$TARGET"
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    echo "  已应用 $(grep -c '^diff --git' "$PATCH_FILE") 个文件的改动"
else
    echo "  git apply 失败，改用 patch -p1"
    patch -p1 --forward < "$PATCH_FILE" || die "补丁应用失败，请检查源码版本是否为 $BRANCH"
fi

say "写入内核配置"
cp "$CONFIG_FILE" .config
echo "  已写入 .config ($(wc -c < .config) bytes)"

say "校验关键改动"
fail=0
check() {
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  OK   $desc"
    else
        echo "  FAIL $desc"
        fail=1
    fi
}
check "PPU 驱动源码存在"        test -f drivers/soc/sunxi/sun50i-h6-prcm-ppu.c
check "PPU 已接入 Kconfig"      grep -q SUN50I_H6_PRCM_PPU drivers/soc/sunxi/Kconfig
check "PPU 已接入 Makefile"     grep -q sun50i-h6-prcm-ppu drivers/soc/sunxi/Makefile
check ".config 启用 PPU"        grep -q '^CONFIG_SUN50I_H6_PRCM_PPU=y' .config
check "DTS 含 prcm_ppu 节点"    grep -q 'sun50i-h616-prcm-ppu' arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi
check "GPU 有 power-domains"    grep -q 'power-domains = <&prcm_ppu 2>' arch/arm64/boot/dts/allwinner/sun50i-h616-walnutpi-1b.dts
check "panfrost resume 已修复"  grep -q 'clk_prepare_enable(pfdev->clock)' drivers/gpu/drm/panfrost/panfrost_device.c

[ "$fail" -eq 0 ] || die "校验未全部通过"

say "完成"
cat <<EOF
源码树已就绪：$TARGET

编译命令：

  cd "$TARGET"
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$(nproc) Image modules dtbs

产物位置：
  arch/arm64/boot/Image
  arch/arm64/boot/dts/allwinner/sun50i-h616-walnutpi-1b.dtb
  drivers/gpu/drm/panfrost/panfrost.ko
  drivers/soc/sunxi/sun50i-h6-prcm-ppu.ko

安装模块后即可用 scripts/build-alpindroid.sh 打镜像：

  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=/tmp/newmods modules_install
  sudo sh scripts/build-alpindroid.sh v0.19 /tmp/newmods/lib/modules/6.1.31+
EOF