#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 Windows/其他桌面系统上预烘焙 cirno.gif，H618 只需播放成品。需要 Pillow。"""
import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print('缺少 Pillow，请运行: py -m pip install Pillow', file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent
MODE_SIZES = {
    'normal': (50, 25),
    'ascii': (60, 30),
    'mono': (60, 30),
    'braille': (80, 40),
    'braille-mono': (80, 40),
}
SHADE = ' .,:;irsXA253hMHGS#9B&@'
BAYER4 = (0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5)
BRAILLE_DOTS = ((0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (0, 3, 0x40),
                (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20), (1, 3, 0x80))
MAGIC = b'CIRNOA1\x00'


def parse_size(s):
    try:
        w, h = map(int, s.lower().split('x'))
    except (ValueError, AttributeError):
        raise argparse.ArgumentTypeError('尺寸格式必须是 宽x高，例如 40x20')
    if not (1 <= w <= 240 and 1 <= h <= 120):
        raise argparse.ArgumentTypeError('宽度需 1~240，高度需 1~120')
    return w, h


def palette256(rgb):
    r, g, b = rgb
    return 16 + 36 * ((r * 5 + 127) // 255) + 6 * ((g * 5 + 127) // 255) + (b * 5 + 127) // 255


def ansi_fg(rgb, truecolor):
    if truecolor:
        return f'\x1b[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m'
    return f'\x1b[38;5;{palette256(rgb)}m'


def ansi_pair(top, bottom, truecolor):
    if truecolor:
        vals = []
        if top is not None:
            vals.extend(('38', '2', str(top[0]), str(top[1]), str(top[2])))
        if bottom is not None:
            vals.extend(('48', '2', str(bottom[0]), str(bottom[1]), str(bottom[2])))
    else:
        vals = []
        if top is not None:
            vals.extend(('38', '5', str(palette256(top))))
        if bottom is not None:
            vals.extend(('48', '5', str(palette256(bottom))))
    return '\x1b[' + ';'.join(vals) + 'm' if vals else '\x1b[0m'


def scale_to_canvas(frame, w, h):
    """保持人物宽高比，透明区域用于居中填充，避免旋转时跳动。"""
    fw, fh = frame.size
    s = min(w / fw, h / fh)
    tw, th = max(1, round(fw * s)), max(1, round(fh * s))
    scaled = frame.resize((tw, th), Image.Resampling.LANCZOS)
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    out.paste(scaled, ((w - tw) // 2, (h - th) // 2))
    return out


def write_lines(lines):
    """采用绝对行定位，避免终端自动换行导致的滚屏和闪烁。"""
    return ''.join(f'\x1b[{i};1H{line}\x1b[0m\x1b[K' for i, line in enumerate(lines, 1)).encode('utf-8')


def frame_ascii(frame, cols, rows, color, truecolor):
    # 终端字符的物理高度通常约是宽度的 2 倍。
    canvas = scale_to_canvas(frame, cols, rows * 2)
    img = canvas.resize((cols, rows), Image.Resampling.LANCZOS)
    pix = img.load()
    lines = []
    for y in range(rows):
        parts = []
        last = None
        for x in range(cols):
            r, g, b, a = pix[x, y]
            if a < 32:
                if last is not None:
                    parts.append('\x1b[0m')
                    last = None
                parts.append(' ')
                continue
            # 非透明像素尽量保持可见，同时用字符密度描绘明暗层次。
            brightness = (299*r + 587*g + 114*b) / 255000
            shade_index = min(len(SHADE) - 1, round((0.18 + 0.82*brightness) * (len(SHADE)-1)))
            c = SHADE[max(1, shade_index)]
            if color:
                rgb = (r, g, b)
                key = rgb if truecolor else palette256(rgb)
                if key != last:
                    parts.append(ansi_fg(rgb, truecolor))
                    last = key
            parts.append(c)
        lines.append(''.join(parts))
    return write_lines(lines)


def frame_braille(frame, cols, rows, color, truecolor):
    img = scale_to_canvas(frame, cols * 2, rows * 4)
    pix = img.load()
    lines = []
    for y in range(rows):
        parts = []
        last = None
        for x in range(cols):
            value = 0
            sr = sg = sb = hits = 0
            for dx, dy, bit in BRAILLE_DOTS:
                px, py = 2*x+dx, 4*y+dy
                r, g, b, a = pix[px, py]
                luma = (299*r + 587*g + 114*b) / 1000
                coverage = a * (0.48 + 0.52 * luma / 255)
                threshold = (BAYER4[(py % 4) * 4 + px % 4] + 0.5) * 255 / 16
                if a >= 32 and coverage >= threshold:
                    value |= bit
                    sr += r
                    sg += g
                    sb += b
                    hits += 1
            if not value:
                if last is not None:
                    parts.append('\x1b[0m')
                    last = None
                parts.append(' ')
                continue
            if color:
                rgb = (sr//hits, sg//hits, sb//hits)
                key = rgb if truecolor else palette256(rgb)
                if key != last:
                    parts.append(ansi_fg(rgb, truecolor))
                    last = key
            parts.append(chr(0x2800 + value))
        lines.append(''.join(parts))
    return write_lines(lines)


def frame_normal(frame, cols, rows, truecolor):
    img = scale_to_canvas(frame, cols, rows * 2)
    pix = img.load()
    lines = []
    for y in range(rows):
        parts = []
        last = None
        for x in range(cols):
            r1, g1, b1, a1 = pix[x, 2*y]
            r2, g2, b2, a2 = pix[x, 2*y + 1]
            top = (r1, g1, b1) if a1 >= 32 else None
            bot = (r2, g2, b2) if a2 >= 32 else None
            if top and bot:
                glyph = '▀'
            elif top:
                glyph = '▀'
            elif bot:
                glyph = '▄'
            else:
                glyph = ' '
            key = (top, bot) if truecolor else (palette256(top) if top else None, palette256(bot) if bot else None)
            if key != last:
                # 颜色转换始终先复位，确保透明背景不留上一个字符的底色。
                parts.append('\x1b[0m')
                if top or bot:
                    fg = bot if top is None else top
                    bg = bot if top and bot else None
                    parts.append(ansi_pair(fg, bg, truecolor))
                last = key
            parts.append(glyph)
        lines.append(''.join(parts))
    return write_lines(lines)


def pick_frames(gif, max_fps):
    """限帧但不改变动画总时长：跳过的时间合并给上一保留帧。"""
    count = getattr(gif, 'n_frames', 1)
    selected = []
    total_ms = 0
    next_select_ms = 0.0
    minimum_interval = 1000.0 / max_fps
    for i in range(count):
        gif.seek(i)
        raw_dur = gif.info.get('duration', 100)
        ms = max(20, min(20000, int(raw_dur or 100)))
        if i == 0 or total_ms >= next_select_ms - 0.001:
            if selected:
                selected[-1][2] = total_ms - selected[-1][1]
            selected.append([i, total_ms, None])
            next_select_ms = total_ms + minimum_interval
        total_ms += ms
    if selected:
        selected[-1][2] = total_ms - selected[-1][1]
    return [(i, dur) for i, _, dur in selected], total_ms


def union_alpha_bbox(gif, indices):
    """所有所选帧计算统一裁剪区域，保证人物转动时不会出现视角抖动。"""
    bbox = None
    for i, _ in indices:
        gif.seek(i)
        frame = gif.convert('RGBA')
        b = frame.getchannel('A').getbbox()
        if b is not None:
            if bbox is None:
                bbox = list(b)
            else:
                bbox[0] = min(bbox[0], b[0])
                bbox[1] = min(bbox[1], b[1])
                bbox[2] = max(bbox[2], b[2])
                bbox[3] = max(bbox[3], b[3])
    if bbox is None:
        return (0, 0, *gif.size)
    pad = max(2, int(max(bbox[2]-bbox[0], bbox[3]-bbox[1]) * 0.04))
    return (max(0, bbox[0]-pad), max(0, bbox[1]-pad),
            min(gif.width, bbox[2]+pad), min(gif.height, bbox[3]+pad))


def bake(gif, frames, crop, mode, size, out, truecolor):
    w, h = size
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open('wb') as fo:
        fo.write(struct.pack('<8sIII', MAGIC, len(frames), w, h))
        for index, (fi, duration) in enumerate(frames, 1):
            gif.seek(fi)
            frame = gif.convert('RGBA').crop(crop)
            if mode == 'normal':
                payload = frame_normal(frame, w, h, truecolor)
            elif mode in ('ascii', 'mono'):
                payload = frame_ascii(frame, w, h, mode == 'ascii', truecolor)
            else:
                payload = frame_braille(frame, w, h, mode == 'braille', truecolor)
            fo.write(struct.pack('<II', duration, len(payload)))
            fo.write(payload)
            if index % 50 == 0:
                print(f'  {mode}: {index}/{len(frames)} 帧', flush=True)
    print(f'  OK {out.name}: {len(frames)} 帧，{w}x{h}，{out.stat().st_size / 1024:.1f} KiB')


def main():
    p = argparse.ArgumentParser(description='在 Windows 将 cirno.gif 预烘焙为 H618 可直接播放的字符动画文件。')
    p.add_argument('--input', default=str(ROOT/'cirno.gif'), help='输入 GIF（默认脚本同目录 cirno.gif）')
    p.add_argument('--mode', choices=['all', *MODE_SIZES], default='all', help='要烘焙的模式（默认 all）')
    p.add_argument('--size', type=parse_size, help='烘焙尺寸，如 40x20（可与不同尺寸版本共存）')
    p.add_argument('--fps', type=float, default=12, help='最高帧率；跳过帧仍保持原 GIF 的总时长（默认 12）')
    p.add_argument('--truecolor', action='store_true', help='彩色模式使用 24-bit 真彩色（默认更省流量的 256 色）')
    p.add_argument('--no-crop', action='store_true', help='保留 GIF 原始画布，不自动裁去透明边框')
    args = p.parse_args()
    if not 0.5 <= args.fps <= 60:
        p.error('--fps 必须在 0.5 至 60 之间')
    source = Path(args.input).expanduser().resolve()
    if not source.is_file():
        p.error(f'找不到文件：{source}')
    out_dir = ROOT / 'baked'
    with Image.open(source) as gif:
        frames, duration = pick_frames(gif, args.fps)
        crop = (0, 0, *gif.size) if args.no_crop else union_alpha_bbox(gif, frames)
        print(f'输入：{source.name}，原始帧 {getattr(gif, "n_frames", 1)}，预烘焙帧 {len(frames)}，总时长 {duration/1000:.2f}s')
        print(f'统一裁剪区域：{crop}，输出目录：{out_dir}')
        modes = list(MODE_SIZES) if args.mode == 'all' else [args.mode]
        for mode in modes:
            size = args.size if args.size else MODE_SIZES[mode]
            name = f'{mode}-{size[0]}x{size[1]}.cirno'
            bake(gif, frames, crop, mode, size, out_dir / name, args.truecolor)
    print('全部完成。将 baked 文件夹、cirno.sh 和 cirno_player.c 复制到 Alpine Linux。')


if __name__ == '__main__':
    main()
