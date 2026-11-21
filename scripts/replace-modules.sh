#!/bin/sh
# 用自编内核的模块替换镜像里的 /lib/modules —— 安全版
#
# 背景坑：`rm -rf $ROOT/lib/modules && cp -a $NEWMODS/6.1.31+ $ROOT/lib/modules/`
# 当 $ROOT/lib/modules 已被删除时，GNU cp 会把目标本身创建为源的副本，
# 于是 /lib/modules/6.1.31+/ 这一层被吃掉，变成 /lib/modules/kernel/ …，
# 结果内核（uname -r = 6.1.31+）找不到任何模块，所有模块加载全部失败
# （WiFi/蓝牙/GPU 全挂，但系统仍能启动，因为核心驱动都 built-in）。
#
# 用法：
#   sh replace-modules.sh <已挂载的 rootfs 路径> <新模块目录>
#   例：sh replace-modules.sh /mnt/r15 /tmp/newmods14/lib/modules/6.1.31+

set -e

ROOT="$1"
SRCMOD="$2"

if [ -z "$ROOT" ] || [ -z "$SRCMOD" ]; then
    echo "用法: $0 <rootfs挂载点> <新模块目录，例如 /tmp/newmods/lib/modules/6.1.31+>"
    exit 1
fi

KVER=$(basename "$SRCMOD")
if [ ! -d "$SRCMOD/kernel" ]; then
    echo "错误: $SRCMOD 下没有 kernel/ 目录，确认传入的是 /lib/modules/<版本> 路径"
    exit 1
fi

echo "  目标 rootfs : $ROOT"
echo "  源模块版本  : $KVER"

echo "  [1] 清理旧的 /lib/modules"
rm -rf "$ROOT/lib/modules"

echo "  [2] 创建 $ROOT/lib/modules/$KVER"
mkdir -p "$ROOT/lib/modules/$KVER"

echo "  [3] 复制（用 /./ 保证复制内容而非目录本身）"
cp -a "$SRCMOD/." "$ROOT/lib/modules/$KVER/"

echo "  [4] 校验"
if [ ! -d "$ROOT/lib/modules/$KVER/kernel" ]; then
    echo "  ✗ 失败：$ROOT/lib/modules/$KVER/kernel 不存在"
    exit 1
fi

NKOS=$(find "$ROOT/lib/modules/$KVER" -name '*.ko' 2>/dev/null | wc -l)
echo "    .ko 数量: $NKOS"
if [ "$NKOS" -lt 100 ]; then
    echo "  ✗ 失败：模块数量异常（$NKOS < 100）"
    exit 1
fi

if [ -f "$ROOT/lib/modules/$KVER/modules.dep" ]; then
    echo "    modules.dep: 存在"
else
    echo "  ✗ 失败：modules.dep 缺失"
    exit 1
fi

# 抽查关键模块
for m in sprdwl_ng uwe5622_bsp_sdio panfrost; do
    F=$(find "$ROOT/lib/modules/$KVER" -name "${m}.ko" 2>/dev/null | head -1)
    if [ -n "$F" ]; then
        echo "    ✓ $m"
    else
        echo "    ⚠ $m 未找到（若该驱动本应存在，请检查内核配置）"
    fi
done

echo "  [5] 完成：/lib/modules/$KVER 就绪"
