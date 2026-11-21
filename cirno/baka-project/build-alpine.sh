#!/bin/sh
# 在 Alpine Linux H618 上编译：sh build-alpine.sh
set -eu
cd "$(dirname "$0")"
if [ ! -f assets.h ]; then
    printf '错误：找不到 assets.h。请先在 Windows 执行 build-windows.ps1 生成它。\n' >&2
    exit 1
fi
# Alpine 使用 musl；静态编译后程序本身无需再依赖外部共享库。
cc -Os -std=c99 -Wall -Wextra -static -s -o baka baka.c -lm
printf '编译完成：%s/baka\n' "$(pwd)"
printf '测试：./baka 和 ./baka baka，以及 ./baka --list\n'
