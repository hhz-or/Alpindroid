/*
 * baka: Windows / Linux 通用的单文件终端彩蛋，无 Chafa 运行时依赖。
 *
 * 每出现一个字面量为 "baka" 的命令行词语，就让选择计数 +1。
 * 可执行程序名 baka 本身计作第一个，具体内容详见 print_list()。
 *
 * 动画和 UTF-8 字符画编译时全部存入只读数据区：
 *   Python build_assets.py -> assets.h -> C 编译器 -> baka.exe / baka
 *
 * 动画帧是之前 bake_cirno.py 烘焙的 .cirno 格式；运行时仅输出预生成的字节，
 * 不会执行 GIF 解码、ASCII 转换、缩放或字体渲染。字体由终端负责。
 */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <limits.h>
#else
#include <unistd.h>
#endif
#include "assets.h"

#define MAX_BAKA 9
static volatile sig_atomic_t stopping = 0;
#ifndef _WIN32
static void stop_handler(int sig) { (void)sig; stopping = 1; }
#else
/* Windows Ctrl+C、Ctrl+Break 事件由控制台处理函数接管，以便恢复光标。 */
static BOOL WINAPI win_console_handler(DWORD event) {
    if (event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT) {
        stopping = 1;
        return TRUE;
    }
    return FALSE;
}

/* 只有真正连接到控制台时才启用虚拟终端控制码与 UTF-8 输出。 */
static int setup_windows_console(void) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    /* 禁用 CRT 的 LF->CRLF 翻译，保证预烘焙帧的 ANSI 数据原样输出。 */
    _setmode(_fileno(stdout), _O_BINARY);
    if (out == INVALID_HANDLE_VALUE || !GetConsoleMode(out, &mode)) return 0;
    SetConsoleOutputCP(CP_UTF8);
    if (!(mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
        if (!SetConsoleMode(out, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
            /* 老旧控制台可能不支持 ANSI。静态字符仍可打印。 */
            return 0;
        }
    }
    return 1;
}
#endif

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int write_all(const unsigned char *p, size_t bytes) {
    while (bytes) {
#ifdef _WIN32
        /* _write 长度为 int；大型动画可能超过 INT_MAX，分块输出。 */
        unsigned chunk = (bytes > (size_t)INT_MAX) ? (unsigned)INT_MAX : (unsigned)bytes;
        int sent = _write(_fileno(stdout), p, chunk);
#else
        ssize_t sent = write(STDOUT_FILENO, p, bytes);
#endif
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        p += (size_t)sent;
        bytes -= (size_t)sent;
    }
    return 0;
}

static double monotonic_now(void) {
#ifdef _WIN32
    /* 高精度单调时钟：不受系统时间被修改的影响。 */
    LARGE_INTEGER ticks, frequency;
    QueryPerformanceCounter(&ticks);
    QueryPerformanceFrequency(&frequency);
    return (double)ticks.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#endif
}

static void sleep_until(double target) {
    while (!stopping) {
        double d = target - monotonic_now();
        if (d <= 0) return;
#ifdef _WIN32
        /* 不忙等，允许大约 1~16ms 的 Windows 调度误差。 */
        DWORD ms = (DWORD)ceil(d * 1000.0);
        Sleep(ms > 0 ? ms : 1);
#else
        struct timespec ts;
        ts.tv_sec = (time_t)d;
        ts.tv_nsec = (long)((d - ts.tv_sec) * 1e9);
        if (ts.tv_nsec < 0) ts.tv_nsec = 0;
        if (nanosleep(&ts, NULL) == 0) return;
        if (errno != EINTR) return;
#endif
    }
}

static int number(const char *s, double *out, double minimum, double maximum) {
    char *end = NULL;
    errno = 0;
    double v = strtod(s, &end);
    if (errno || end == s || *end != '\0' || !isfinite(v) || v < minimum || v > maximum) return 0;
    *out = v;
    return 1;
}

static void print_list(void) {
    puts("baka 命令彩蛋（输入的 baka 越多，Baka越丰富）：\n"
         "  baka                                 ᗜˬᗜ\n"
         "  baka baka                            cirno1 字符画\n"
         "  baka baka baka                       cirno2 字符画\n"
         "  baka baka baka baka                  cirno3 字符画\n"
         "  5 个 baka                             黑白 ASCII 动画\n"
         "  6 个 baka                             黑白 Braille 点阵动画\n"
         "  7 个 baka                             彩色 ASCII 动画\n"
         "  8 个 baka                             彩色 Braille 点阵动画\n"
         "  9 个 baka                             彩色 Unicode 半块动画\n");
}

static void print_help(void) {
    puts("用法：baka [baka ...] [选项]\n"
         "每多一个 baka 就选择下一档；第一个 baka 是命令名称本身。\n"
         "选项：\n"
         "  --list              查看九档对应内容\n"
         "  --once              动画只播放一轮然后退出\n"
         "  --speed 倍数        播放倍速：0.1 至 100，默认 1\n"
         "  --duration 秒数     动画最长播放时长（非负数），默认无限\n"
         "  -h, --help          查看帮助\n"
         "动画模式按 Ctrl+C 退出；文本模式打印后立即退出。\n"
         "仅支持最多 9 个 baka，参数顺序可以混合。\n");
}

/* 返回实际播放状态；备用屏幕在每条退出路径均恢复。 */
static int play_animation(const struct baka_asset *a, double speed, double limit, int once) {
    if (a->len == 0) {
        fprintf(stderr, "错误：此模式尚未烘焙进可执行文件，请在 Windows 生成动画后重新编译。\n");
        return 1;
    }
    const unsigned char *buf = a->data;
    if (a->len < 20 || memcmp(buf, "CIRNOA1\0", 8) != 0) {
        fputs("错误：内置动画格式错误。\n", stderr);
        return 1;
    }
    uint32_t frames = le32(buf + 8), width = le32(buf + 12), height = le32(buf + 16);
    if (frames == 0 || frames > 100000 || width == 0 || width > 240 || height == 0 || height > 120) {
        fputs("错误：内置动画头参数错误。\n", stderr);
        return 1;
    }
#ifdef _WIN32
    const int tty = setup_windows_console();
    if (!SetConsoleCtrlHandler(win_console_handler, TRUE)) {
        fputs("警告：无法安装 Windows Ctrl+C 处理函数。\n", stderr);
    }
#else
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = stop_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    const int tty = isatty(STDOUT_FILENO);
#endif
    const unsigned char enter[] = "\033[?1049h\033[?25l\033[2J";
    const unsigned char home[] = "\033[H";
    const unsigned char leave[] = "\033[0m\033[?25h\033[?1049l";
    int status = 0;
    if (tty && write_all(enter, sizeof(enter)-1) != 0) return 1;
    const double start = monotonic_now();
    double next_frame = start;
    do {
        size_t at = 20;
        for (uint32_t i = 0; i < frames && !stopping; i++) {
            if (at + 8 > a->len) { status = 1; stopping = 1; break; }
            uint32_t ms = le32(buf + at), n = le32(buf + at + 4);
            at += 8;
            if (ms == 0 || n == 0 || n > a->len - at) { status = 1; stopping = 1; break; }
            if (limit >= 0 && monotonic_now() - start >= limit) { stopping = 1; break; }
            if (tty && write_all(home, sizeof(home)-1) != 0) { status = 1; stopping = 1; break; }
            if (write_all(buf + at, n) != 0) { status = 1; stopping = 1; break; }
            at += n;
            next_frame += (double)ms / (1000.0 * speed);
            if (limit >= 0 && next_frame > start + limit) next_frame = start + limit;
            sleep_until(next_frame);
            /* 渲染较慢时避免无休止赶帧；此时播放可能变慢。 */
            if (next_frame < monotonic_now()) next_frame = monotonic_now();
            if (limit >= 0 && monotonic_now() - start >= limit) { stopping = 1; break; }
        }
    } while (!stopping && !once);
    if (tty && write_all(leave, sizeof(leave)-1) != 0) status = 1;
#ifdef _WIN32
    SetConsoleCtrlHandler(win_console_handler, FALSE);
#endif
    if (status) fputs("错误：动画播放中断或数据损坏。\n", stderr);
    return status;
}

int main(int argc, char **argv) {
#ifdef _WIN32
    /* 静态文本同样需要 UTF-8 控制台，不能等到 play_animation 再设置。 */
    setup_windows_console();
#endif
    int count = 1, once = 0;
    double speed = 1.0, limit = -1.0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "baka")) {
            count++;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            print_help(); return 0;
        } else if (!strcmp(argv[i], "--list")) {
            print_list(); return 0;
        } else if (!strcmp(argv[i], "--once")) {
            once = 1;
        } else if (!strcmp(argv[i], "--speed")) {
            if (i+1 == argc || !number(argv[++i], &speed, 0.1, 100.0)) {
                fputs("错误：--speed 需要 0.1 至 100 的数字。\n", stderr); return 2;
            }
        } else if (!strcmp(argv[i], "--duration")) {
            if (i+1 == argc || !number(argv[++i], &limit, 0.0, 86400.0)) {
                fputs("错误：--duration 需要 0 至 86400 秒的数字。\n", stderr); return 2;
            }
        } else {
            fprintf(stderr, "错误：未知参数：%s\n运行 baka --help 查看用法。\n", argv[i]); return 2;
        }
    }
    if (count > MAX_BAKA) {
        fprintf(stderr, "错误：最多支持 %d 个 baka，当前输入 %d 个。\n", MAX_BAKA, count);
        return 2;
    }
    const struct baka_asset *asset = &baked_assets[count-1];
    if (count <= 4) {
        return write_all(asset->data, asset->len) == 0 ? 0 : 1;
    }
    return play_animation(asset, speed, limit, once);
}
