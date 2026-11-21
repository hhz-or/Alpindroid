#!/bin/sh
# ============================================================================
# Alpindroid 一键构建脚本
#
# 用法（需 root）：
#   sudo sh build-alpindroid.sh <版本号> [模块目录]
#   例：sudo sh build-alpindroid.sh v0.16
#       sudo sh build-alpindroid.sh v0.16 /tmp/newmods/lib/modules/6.1.31+
#
# 本脚本固化了 v0.14/v0.15 排查中发现的全部修复，避免重蹈覆辙：
#   ① /lib/modules/<uname -r>/ 版本目录层级（曾导致所有模块加载失败）
#   ② config.txt 的 overlays 必须含 pmic-axp313a（否则 PMIC 识别成 AXP806）
#   ③ config.txt 的 console_uart / printk_level（否则串口静默）
#   ④ 移除 panfrost 黑名单
#
# 依赖：build-image.sh、replace-modules.sh 与本脚本同目录
# ============================================================================
set -e

VERSION="${1:?用法: $0 <版本号> [模块目录]}"
NEWMODS="${2:-/tmp/newmods14/lib/modules/6.1.31+}"

# sudo 下 $HOME 会变成 /root，需还原为调用者的 home
if [ -n "$SUDO_USER" ]; then
    HOMEDIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOMEDIR="$HOME"
fi
[ -d "$HOMEDIR/alpindroid" ] || { echo "找不到 $HOMEDIR/alpindroid" >&2; exit 1; }

BASE="$HOMEDIR/alpindroid"
BOARD="$BASE/images/2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img"
ROOTFS="$BASE/work/rootfs"
KERNEL="$BASE/work/linux-6.1.31"
DTBO="$BASE/patches/pmic-axp313a.dtbo"
[ -f "$DTBO" ] || DTBO="$BASE/patches/dts/pmic-axp313a.dtbo"
OUTPUT="$BASE/output/Alpindroid-ZeroW-${VERSION}.img"
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)

KVER=$(basename "$NEWMODS")
BOOTMNTP=/mnt/alp-boot
ROOTMNTP=/mnt/alp-root

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查
say "前置检查"
for f in "$BOARD" "$ROOTFS" "$KERNEL/arch/arm64/boot/Image" \
         "$KERNEL/arch/arm64/boot/dts/allwinner/sun50i-h616-walnutpi-1b.dtb" \
         "$DTBO" "$NEWMODS/kernel"; do
    [ -e "$f" ] || die "缺少文件: $f"
done
echo "  底板    : $BOARD"
echo "  rootfs  : $ROOTFS"
echo "  内核    : $KERNEL"
echo "  dtbo    : $DTBO"
echo "  模块    : $NEWMODS (版本 $KVER)"
echo "  输出    : $OUTPUT"

if [ -e "$OUTPUT" ]; then
    say "删除已存在的输出"
    rm -f "$OUTPUT"
fi

# ---------------------------------------------------------------- 1. 基础构建
say "[1/6] 基础镜像构建（底板 → Alpine rootfs）"
sh "$SCRIPTDIR/build-image.sh" "$BOARD" "$ROOTFS" "$OUTPUT" || die "build-image.sh 失败"

# ---------------------------------------------------------------- 2. 挂载
say "[2/6] 挂载分区"
LOOP=$(losetup --find --partscan --show "$OUTPUT")
echo "  loop: $LOOP"
mkdir -p "$BOOTMNTP" "$ROOTMNTP"
mount "${LOOP}p1" "$BOOTMNTP"
mount "${LOOP}p2" "$ROOTMNTP"

cleanup() {
    sync || true
    umount "$BOOTMNTP" 2>/dev/null || true
    umount "$ROOTMNTP" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- 3. boot 分区
say "[3/6] 安装内核 / DTB / overlay"
cp "$KERNEL/arch/arm64/boot/Image" "$BOOTMNTP/Image"
cp "$KERNEL/arch/arm64/boot/dts/allwinner/sun50i-h616-walnutpi-1b.dtb" \
   "$BOOTMNTP/sun50i-h616-walnutpi-1b.dtb"
cp "$DTBO" "$BOOTMNTP/overlays/sun50i-h616-pmic-axp313a.dtbo"
echo "  Image : $(stat -c%s "$BOOTMNTP/Image") 字节"
echo "  DTB   : $(stat -c%s "$BOOTMNTP/sun50i-h616-walnutpi-1b.dtb") 字节"
echo "  dtbo  : $(stat -c%s "$BOOTMNTP/overlays/sun50i-h616-pmic-axp313a.dtbo") 字节"

say "[3b] 修正 config.txt（曾经漏掉的致命步骤）"
CFG="$BOOTMNTP/config.txt"
echo "  修改前:"
grep -E '^(overlays|console_uart|printk_level)=' "$CFG" | sed 's/^/    /'

sed -i 's/^console_uart=.*/console_uart=uart2/' "$CFG"
sed -i 's/^printk_level=.*/printk_level=7/'   "$CFG"
if grep -q 'pmic-axp313a' "$CFG"; then
    echo "  overlays 已含 pmic-axp313a"
else
    sed -i 's/^overlays=\(.*\)/overlays=\1 pmic-axp313a/' "$CFG"
fi

echo "  修改后:"
grep -E '^(overlays|console_uart|printk_level)=' "$CFG" | sed 's/^/    /'
grep -q 'pmic-axp313a' "$CFG" || die "config.txt 的 overlays 仍缺 pmic-axp313a"

# ---------------------------------------------------------------- 4. 模块
say "[4/6] 安装内核模块（版本目录层级是关键）"
sh "$SCRIPTDIR/replace-modules.sh" "$ROOTMNTP" "$NEWMODS" || die "replace-modules.sh 失败"

# ---------------------------------------------------------------- 5. 用户空间调整
say "[5/6] 用户空间调整"
rm -f "$ROOTMNTP/etc/modprobe.d/blacklist-panfrost.conf"
echo "  已移除 panfrost 黑名单"

mkdir -p "$ROOTMNTP/etc/sysctl.d"
echo 'kernel.printk = 8 4 1 7' > "$ROOTMNTP/etc/sysctl.d/99-printk.conf"
echo "  已写入 printk=8"

# 安全兜底：确保 /etc/modules 会加载 WiFi 驱动
MODFILE="$ROOTMNTP/etc/modules"
touch "$MODFILE"
for m in sprdwl_ng sprdbt_tty; do
    grep -qx "$m" "$MODFILE" || echo "$m" >> "$MODFILE"
done
echo "  /etc/modules:"
sed 's/^/    /' "$MODFILE"

# --- sysctl 服务：否则 /etc/sysctl.d/*.conf 不生效（printk 仍是 1） ---
if [ -f "$ROOTMNTP/etc/init.d/sysctl" ]; then
    mkdir -p "$ROOTMNTP/etc/runlevels/boot"
    ln -sf /etc/init.d/sysctl "$ROOTMNTP/etc/runlevels/boot/sysctl" 2>/dev/null || true
    echo "  sysctl 服务已加入 boot runlevel"
fi

# --- BinderFS：Waydroid 需要 ---
if ! grep -q 'binderfs' "$ROOTMNTP/etc/fstab" 2>/dev/null; then
    echo 'binder /dev/binderfs binder defaults 0 0' >> "$ROOTMNTP/etc/fstab"
    echo "  BinderFS 已写入 /etc/fstab"
fi
mkdir -p "$ROOTMNTP/dev/binderfs"

# --- chrony：默认配置里的 ntp.aliyun.com 域名不存在（NXDOMAIN），换 ntp1 ---
CY="$ROOTMNTP/etc/chrony/chrony.conf"
if [ -f "$CY" ]; then
    sed -i 's/^pool ntp\.aliyun\.com.*/pool ntp1.aliyun.com iburst/' "$CY"
    sed -i 's/^initstepslew.*/initstepslew 10 ntp1.aliyun.com/'      "$CY"
    grep -q 'pool ntp1.aliyun.com' "$CY" || echo 'pool ntp1.aliyun.com iburst' >> "$CY"
    echo "  chrony 已改用 ntp1.aliyun.com（原 ntp.aliyun.com 不存在）"
fi

# ---------------------------------------------------------------- 6. 校验
# ---------------------------------------------------------------- 5b. GPU stack
say "[5b] 安装 GPU 软件栈（mesa，chroot + QEMU）"
if [ -x /usr/bin/qemu-aarch64-static ]; then
    cp /usr/bin/qemu-aarch64-static "$ROOTMNTP/usr/bin/" 2>/dev/null
    mount -t proc proc "$ROOTMNTP/proc" 2>/dev/null
    mount -t sysfs sys "$ROOTMNTP/sys" 2>/dev/null
    mount -t devtmpfs dev "$ROOTMNTP/dev" 2>/dev/null
    cp "$SCRIPTDIR/install-gpu-stack.sh" "$ROOTMNTP/tmp/"
    chmod +x "$ROOTMNTP/tmp/install-gpu-stack.sh"
    if chroot "$ROOTMNTP" /bin/sh /tmp/install-gpu-stack.sh; then
        echo "  OK   GPU 栈安装成功"
    else
        echo "  WARN GPU 栈安装失败（可启动后手动 apk add）"
    fi
    rm -f "$ROOTMNTP/tmp/install-gpu-stack.sh"
    umount "$ROOTMNTP/dev"  2>/dev/null
    umount "$ROOTMNTP/sys"  2>/dev/null
    umount "$ROOTMNTP/proc" 2>/dev/null
    rm -f "$ROOTMNTP/usr/bin/qemu-aarch64-static"
else
    echo "  WARN 缺少 qemu-aarch64-static，跳过 GPU 栈"
fi
mkdir -p "$ROOTMNTP/usr/local/src" "$ROOTMNTP/usr/local/bin"
if [ -f "$SCRIPTDIR/gpu_render_test.c" ]; then
    cp "$SCRIPTDIR/gpu_render_test.c" "$ROOTMNTP/usr/local/src/"
    echo "  gpu_render_test.c -> /usr/local/src/"
fi
if [ -f "$SCRIPTDIR/gpu_render_test" ]; then
    cp "$SCRIPTDIR/gpu_render_test" "$ROOTMNTP/usr/local/bin/"
    chmod +x "$ROOTMNTP/usr/local/bin/gpu_render_test"
    echo "  gpu_render_test -> /usr/local/bin/"
fi
if grep -q cgroup2 "$ROOTMNTP/etc/fstab" 2>/dev/null; then
    echo "  cgroup2 已在 fstab"
else
    echo "none /sys/fs/cgroup cgroup2 defaults 0 0" >> "$ROOTMNTP/etc/fstab"
    echo "  cgroup2 -> /etc/fstab"
fi

say "[6/6] 最终校验"

fail=0
chk() {  # chk <描述> <命令...>
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✅ $desc"
    else
        echo "  ❌ $desc"
        fail=1
    fi
}

# 内核模块层级
chk "/lib/modules/$KVER 存在"            test -d "$ROOTMNTP/lib/modules/$KVER"
chk "/lib/modules/$KVER/kernel 存在"     test -d "$ROOTMNTP/lib/modules/$KVER/kernel"
chk "modules.dep 在版本目录内"           test -f "$ROOTMNTP/lib/modules/$KVER/modules.dep"
chk "sprdwl_ng.ko 存在"                  test -n "$(find "$ROOTMNTP/lib/modules/$KVER" -name sprdwl_ng.ko -print -quit)"
chk "uwe5622_bsp_sdio.ko 存在"           test -n "$(find "$ROOTMNTP/lib/modules/$KVER" -name uwe5622_bsp_sdio.ko -print -quit)"
chk "panfrost.ko 存在"                   test -n "$(find "$ROOTMNTP/lib/modules/$KVER" -name panfrost.ko -print -quit)"

# DTB 内容
chk "DTB 含 prcm_ppu"                    grep -q "h616-prcm-ppu" "$BOOTMNTP/sun50i-h616-walnutpi-1b.dtb"
chk "DTB 含 gpu-opp-fixed"               grep -q "gpu-opp-fixed" "$BOOTMNTP/sun50i-h616-walnutpi-1b.dtb"

# dtbo 不含硬编码 phandle 引用（mali/hvcc 相关已移入板级 dts）
if strings "$BOOTMNTP/overlays/sun50i-h616-pmic-axp313a.dtbo" | grep -qE '^(mali|hvcc)'; then
    echo "  ⚠ dtbo 仍含 mali/hvcc 字样（请确认是否误留 fragment）"
fi

# 固件
chk "/lib/firmware 非空"                 test -n "$(ls -A "$ROOTMNTP/lib/firmware" 2>/dev/null)"

# config.txt
chk "config.txt console_uart=uart2"      grep -q '^console_uart=uart2' "$CFG"
chk "config.txt overlays 含 pmic-axp313a" grep -q 'pmic-axp313a' "$CFG"

# 模块数量
chk "panfrost_dri.so 存在" test -f "$ROOTMNTP/usr/lib/dri/panfrost_dri.so"
chk "eglinfo 存在" test -x "$ROOTMNTP/usr/bin/eglinfo"
chk "cgroup2 已写入 fstab" grep -q cgroup2 "$ROOTMNTP/etc/fstab"

NKOS=$(find "$ROOTMNTP/lib/modules/$KVER" -name '*.ko' | wc -l)
echo "  ℹ .ko 总数: $NKOS"
[ "$NKOS" -gt 2000 ] || { echo "  ❌ .ko 数量异常"; fail=1; }

# ---------------------------------------------------------------- 收尾
say "卸载并计算校验和"
cleanup
trap - EXIT

ls -lh "$OUTPUT"
sha256sum "$OUTPUT"

if [ "$fail" -ne 0 ]; then
    die "校验未全部通过，请检查上面的 ❌ 项"
fi

say "构建完成: $OUTPUT"
