#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把静态 UTF-8 字符画和 Windows 预烘焙 .cirno 动画直接嵌入 assets.h。

无需第三方 Python 库。 --allow-missing 仅供开发/测试，正式编译请勿启用。
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODES = ['mono', 'braille-mono', 'ascii', 'braille', 'normal']
TEXT = ['emoji', 'cirno1', 'cirno2', 'cirno3']


def as_c_string(data):
    # 每个字节都是固定宽度的十六进制转义，避免多字节 UTF-8、反斜杠和引号带来的 C 源码歧义。
    if not data:
        return '    ""'
    return '\n'.join('    "' + ''.join('\\x%02x' % x for x in data[i:i+32]) + '"'
                     for i in range(0, len(data), 32))


def verify_cirno(data, where):
    import struct
    if len(data) < 20 or data[:8] != b'CIRNOA1\0':
        raise ValueError(f'{where}: 非法 .cirno 文件头')
    count, width, height = struct.unpack_from('<III', data, 8)
    if not (0 < count <= 100000 and 0 < width <= 240 and 0 < height <= 120):
        raise ValueError(f'{where}: 动画帧数或尺寸超出范围')
    offset = 20
    for i in range(count):
        if offset + 8 > len(data):
            raise ValueError(f'{where}: 第 {i+1} 帧缺少帧头')
        ms, size = struct.unpack_from('<II', data, offset)
        offset += 8
        if not (0 < ms <= 60000 and 0 < size <= 32*1024*1024):
            raise ValueError(f'{where}: 第 {i+1} 帧参数异常')
        offset += size
        if offset > len(data):
            raise ValueError(f'{where}: 第 {i+1} 帧不完整')
    if offset != len(data):
        raise ValueError(f'{where}: 末尾存在多余数据')
    return count, width, height


def main():
    p = argparse.ArgumentParser(description='生成编译进 baka 的 assets.h（无运行时外部资源）')
    p.add_argument('--size', default='40x20', help='使用 baked/ 下对应尺寸文件，默认 40x20')
    p.add_argument('--allow-missing', action='store_true', help='开发用途：容许缺失动画文件')
    a = p.parse_args()
    if not a.size.replace('x', '').isdigit() or 'x' not in a.size:
        p.error('--size 格式应为 40x20')
    pairs = []
    for key in TEXT:
        path = ROOT / 'assets' / (key + '.txt')
        try:
            # 换行标准化，末尾补换行；不改变中间的 Unicode 空白、点阵或布局。
            data = path.read_bytes().decode('utf-8-sig').replace('\r\n', '\n').replace('\r', '\n').encode('utf-8')
            if not data.endswith(b'\n'):
                data += b'\n'
        except (OSError, UnicodeError) as exc:
            p.error(f'读取 {path} 失败: {exc}')
        pairs.append((key, data))

    for mode in MODES:
        path = ROOT / 'baked' / f'{mode}-{a.size}.cirno'
        if not path.is_file():
            if not a.allow_missing:
                p.error(f'找不到 {path}；先运行 py bake_cirno.py --size {a.size} --fps 10')
            print(f'注意：动画缺失 {path.name}（仅静态内容可用）')
            data = b''
        else:
            data = path.read_bytes()
            count, w, h = verify_cirno(data, path)
            print(f'嵌入：{path.name}，{count} 帧 {w}x{h}，{len(data)//1024} KiB')
        pairs.append(('anim_' + mode.replace('-', '_'), data))

    src = ['/* 自动生成：请勿手动编辑。 */', '#ifndef BAKA_ASSETS_H', '#define BAKA_ASSETS_H',
           '#include <stddef.h>', 'struct baka_asset { const char *name; const unsigned char *data; size_t len; };']
    for key, data in pairs:
        src.append(f'static const unsigned char baked_{key}[] =\n{as_c_string(data)};')
    src.append('static const struct baka_asset baked_assets[] = {')
    for key, _ in pairs:
        src.append(f'    {{"{key}", baked_{key}, sizeof(baked_{key}) - 1}},')
    src += ['};', '#endif', '']
    target = ROOT / 'assets.h'
    target.write_text('\n'.join(src), encoding='utf-8', newline='\n')
    print(f'生成 {target.name}，{target.stat().st_size//1024} KiB 源代码。')
    print('资源已生成。Windows：运行 build-windows.ps1；Alpine：cc -Os -static -s -o baka baka.c -lm')


if __name__ == '__main__':
    try:
        main()
    except ValueError as exc:
        print('错误：' + str(exc), file=sys.stderr)
        sys.exit(2)
