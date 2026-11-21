#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -ne 3 ]; then
    echo "用法: sudo bash $0 <Debian原始.img> <Alpine-rootfs目录> <输出.img>"
    exit 1
fi

BASE=$(realpath "$1")
ROOTFS=$(realpath "$2")
OUTPUT="$3"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 sudo 运行"
    exit 1
fi

if [ ! -f "$BASE" ] || [ ! -d "$ROOTFS" ]; then
    echo "原始镜像或 rootfs 不存在"
    exit 1
fi

if [ -e "$OUTPUT" ]; then
    echo "输出文件已存在，拒绝覆盖: $OUTPUT"
    exit 1
fi

if [ ! -f "$ROOTFS/etc/alpine-release" ]; then
    echo "目标目录不是 Alpine rootfs"
    exit 1
fi

for cmd in losetup sfdisk mount umount rsync blkid od; do
    command -v "$cmd" >/dev/null || {
        echo "缺少命令: $cmd"
        exit 1
    }
done

TMP=$(mktemp -d)
SRC="$TMP/source"
DST="$TMP/target"
BOOT="$TMP/boot"

mkdir -p "$SRC" "$DST" "$BOOT"

SRCLOOP=""
DSTLOOP=""

cleanup() {
    set +e
    mountpoint -q "$BOOT" && umount "$BOOT"
    mountpoint -q "$DST" && umount "$DST"
    mountpoint -q "$SRC" && umount "$SRC"
    [ -n "$DSTLOOP" ] && losetup -d "$DSTLOOP"
    [ -n "$SRCLOOP" ] && losetup -d "$SRCLOOP"
    rm -rf -- "$TMP"
}

trap cleanup EXIT

echo "[1/7] 复制官方镜像"
mkdir -p "$(dirname "$OUTPUT")"
cp --sparse=always -- "$BASE" "$OUTPUT"

echo "[2/7] 生成独立的 MBR Disk ID"
DISK_ID=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')
sfdisk --disk-id "$OUTPUT" "0x${DISK_ID}"

echo "新分区 ID: ${DISK_ID}-01 / ${DISK_ID}-02"

echo "[3/7] 挂载镜像"
SRCLOOP=$(losetup --find --partscan --read-only --show "$BASE")
DSTLOOP=$(losetup --find --partscan --show "$OUTPUT")

mount -o ro "${SRCLOOP}p2" "$SRC"
mount "${DSTLOOP}p2" "$DST"

if [ ! -d "$SRC/lib/modules/6.1.31" ] && [ ! -d "$SRC/lib/modules/6.1.31+" ]; then
    echo "原始镜像未找到 6.1.31 内核模块（6.1.31 或 6.1.31+）"
    exit 1
fi

echo "[4/7] 替换 Debian 用户空间为 Alpine"
rsync -aHAX --numeric-ids --delete --one-file-system \
    --filter='P /lost+found' \
    "$ROOTFS/" "$DST/"

echo "[5/7] 迁移核桃派内核模块与固件"
mkdir -p "$DST/lib/modules" "$DST/lib/firmware"

rsync -aHAX --numeric-ids \
    "$SRC/lib/modules/" "$DST/lib/modules/"

if [ -d "$SRC/lib/firmware" ]; then
    rsync -aHAX --numeric-ids \
        "$SRC/lib/firmware/" "$DST/lib/firmware/"
fi

# QEMU 仅在 x86 服务器的构建环境中使用
rm -f "$DST/usr/bin/qemu-aarch64-static"

echo "[6/7] 配置 Alpine 文件系统"
mkdir -p "$DST/boot"

cat > "$DST/etc/fstab" <<EOF
PARTUUID=${DISK_ID}-02 / ext4 defaults,noatime 0 1
PARTUUID=${DISK_ID}-01 /boot vfat defaults 0 0
EOF

mount "${DSTLOOP}p1" "$BOOT"

CONFIG="$BOOT/config.txt"

if ! grep -Eq '^rootdev=PARTUUID=[[:xdigit:]]{8}-02' "$CONFIG"; then
    echo "config.txt 中未找到预期的 rootdev，停止"
    exit 1
fi

sed -i -E \
    "s|^rootdev=PARTUUID=[[:xdigit:]]{8}-02|rootdev=PARTUUID=${DISK_ID}-02|" \
    "$CONFIG"

echo "[7/7] 验证生成的镜像"
echo "Alpine 版本:"
cat "$DST/etc/alpine-release"

echo "启动参数:"
grep -E '^(rootdev|rootfstype)=' "$CONFIG"

echo "内核模块:"
ls "$DST/lib/modules"

echo "分区标识:"
blkid "${DSTLOOP}p1" "${DSTLOOP}p2"

sync

echo
echo "构建完成: $OUTPUT"
echo "实际挂载和 loop 设备将在脚本退出时自动释放"
