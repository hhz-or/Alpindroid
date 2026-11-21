#!/bin/sh
# 琪露诺终端动画播放器（兼容 Alpine Linux / BusyBox ash）
# 依赖：apk add chafa
# GIF 文件必须与本脚本放在同一个文件夹中，文件名为 cirno.gif。
#
# 用法示例：
#   ./cirno.sh                 # 默认彩色 Unicode 字符画
#   ./cirno.sh ascii           # 彩色 ASCII 字符画
#   ./cirno.sh mono            # 黑白 ASCII 字符画
#   ./cirno.sh braille         # 彩色 Braille 点阵字符画
#   ./cirno.sh braille-mono    # 黑白 Braille 点阵字符画
#   ./cirno.sh -m ascii -s 80x40 -r 1.5  # 调整类型、尺寸和速度
#   ./cirno.sh -h              # 显示帮助

set -eu

show_help() {
    cat <<'HELP'
琪露诺终端动画播放器

用法：
  cirno.sh [模式] [选项]
  cirno.sh -m 模式 [选项]

显示模式：
  normal        彩色 Unicode 字符画（默认，50x25）
  ascii         彩色 ASCII 字符画（60x30）
  mono          黑白 ASCII 字符画（60x30）
  braille       彩色 Braille 点阵字符画（80x40）
  braille-mono  黑白 Braille 点阵字符画（80x40）

选项：
  -m, --mode 模式      指定显示模式
  -s, --size 宽x高     指定最大显示尺寸，如 80x40
  -r, --speed 倍速     播放速度，如 0.5、1、1.5、2
  -d, --duration 秒数  播放时长，默认 inf（无限循环）
  -h, --help           显示本帮助

示例：
  ./cirno.sh
  ./cirno.sh ascii
  ./cirno.sh -m braille -s 80x40 -r 2
  ./cirno.sh mono -d 10

按 Ctrl+C 停止播放。
HELP
}

# 默认参数。SIZE 留空，以便各显示模式采用自己的推荐尺寸。
MODE=normal
SIZE=
SPEED=1
DURATION=inf

# 解析命令行参数：既支持直接传模式，也支持 -m / --mode。
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -m|--mode|-s|--size|-r|--speed|-d|--duration)
            option=$1
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                printf '错误：%s 需要一个参数。\n' "$option" >&2
                exit 2
            fi
            case "$option" in
                -m|--mode) MODE=$2 ;;
                -s|--size) SIZE=$2 ;;
                -r|--speed) SPEED=$2 ;;
                -d|--duration) DURATION=$2 ;;
            esac
            shift 2
            ;;
        normal|ascii|mono|braille|braille-mono)
            MODE=$1
            shift
            ;;
        *)
            printf '错误：未知参数或模式：%s\n' "$1" >&2
            printf '运行 ./cirno.sh --help 查看用法。\n' >&2
            exit 2
            ;;
    esac
done

# 根据模式选择 Chafa 的符号集合和颜色模式。
# 注意：--format symbols 明确使用字符画，而非终端图片协议。
case "$MODE" in
    normal)
        SYMBOLS=block+border+space-wide-inverted
        COLORS=full
        DEFAULT_SIZE=50x25
        ;;
    ascii)
        SYMBOLS=ascii
        COLORS=full
        DEFAULT_SIZE=60x30
        ;;
    mono)
        SYMBOLS=ascii
        COLORS=none
        DEFAULT_SIZE=60x30
        ;;
    braille)
        SYMBOLS=braille
        COLORS=full
        DEFAULT_SIZE=80x40
        ;;
    braille-mono)
        SYMBOLS=braille
        COLORS=none
        DEFAULT_SIZE=80x40
        ;;
    *)
        printf '错误：不支持的显示模式：%s\n' "$MODE" >&2
        exit 2
        ;;
esac

# 如果未指定 --size，就采用当前模式的推荐尺寸。
if [ -z "$SIZE" ]; then
    SIZE=$DEFAULT_SIZE
fi

# 使用脚本自身的目录，而不是执行命令时所在的工作目录。
# 因此在其他目录执行 /path/to/cirno.sh 也能找到 cirno.gif。
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || exit 1
GIF="$SCRIPT_DIR/cirno.gif"

if [ ! -f "$GIF" ]; then
    printf '错误：找不到 GIF 文件：%s\n' "$GIF" >&2
    exit 1
fi

if ! command -v chafa >/dev/null 2>&1; then
    printf '错误：未安装 chafa；Alpine Linux 请执行：apk add chafa\n' >&2
    exit 1
fi

# exec 直接用 Chafa 替换脚本进程：Ctrl+C 可直接终止动画。
# --clear 清屏刷新，--align center,center 使动画在显示区域水平、垂直居中。
exec chafa "$GIF" \
    --format symbols \
    --symbols "$SYMBOLS" \
    --colors "$COLORS" \
    --size "$SIZE" \
    --speed "$SPEED" \
    --duration "$DURATION" \
    --align center,center \
    --clear
