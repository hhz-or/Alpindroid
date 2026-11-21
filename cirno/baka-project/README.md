# baka：Alpine Linux / H618 琪露诺终端彩蛋

## 对应关系

程序名 `baka` **本身算第 1 个**。后面每写一个字面量 `baka`，计数 +1。按以下顺序输出：

| baka 总数 | 显示内容 | 动画格式 |
|---:|---|---|
| 1 | `emoji.txt`，显示 `ᗜˬᗜ` | 静态 |
| 2 | `cirno1.txt` | 静态 |
| 3 | `cirno2.txt` | 静态 |
| 4 | `cirno3.txt` | 静态 |
| 5 | 黑白 ASCII 动画 | `mono` |
| 6 | 黑白 Braille 动画 | `braille-mono` |
| 7 | 彩色 ASCII 动画 | `ascii` |
| 8 | 彩色 Braille 动画 | `braille` |
| 9 | 彩色半块 Unicode 动画 | `normal` |

超过 9 个时打印错误，避免无限重复的 `baka` 使输出难以预期。

## Windows：生成、嵌入动画

1. 安装 Python 3；安装 Pillow：`py -m pip install Pillow`。
2. 把**已经抠成透明背景**的 `cirno.gif` 放在这个文件夹（与 `bake_cirno.py` 同级）。
3. 在 PowerShell 中执行：

   ```powershell
   .\build-windows.ps1
   ```

   如果 PowerShell 执行策略阻止运行，可以直接执行以下两条等价的命令：

   ```powershell
   py .\bake_cirno.py --size 40x20 --fps 10
   py .\build_assets.py --size 40x20
   ```

**如果你之前已经生成过 `.cirno` 文件：** 无需再次处理 GIF。把五种同尺寸的 `*.cirno` 放进 `baked/`，例如 `mono-40x20.cirno`、`braille-mono-40x20.cirno`、`ascii-40x20.cirno`、`braille-40x20.cirno`、`normal-40x20.cirno`，然后直接执行 `py .\build_assets.py --size 40x20`。

生成的 `assets.h` 包含**四份 UTF-8 文本和五种预烘焙动画的原始数据**，编译后全部存在 `baka` 二进制文件内部。`.cirno` 是中间文件，不需要复制到 H618 上。

> 为了照顾 H618，默认烘焙尺寸是 `40x20`，最高 `10fps`。可更改为 `50x25`、`12fps` 等，但必须让 `build_assets.py --size` 与烘焙时的 `--size` 一致。较高帧率、尺寸、色彩会增加终端输出和 CPU 开销。

## Alpine Linux / H618：编译成唯一的可执行文件

仅需要将 **`baka.c` 与 Windows 生成的 `assets.h`** 上传到 H618 的同一目录。

```sh
# root 用户执行。没有 sudo 可切换到 root。
apk add --no-cache build-base
cc -Os -std=c99 -Wall -Wextra -static -s -o baka baka.c -lm
./baka --list
./baka
./baka baka
```

安装为全局命令：

```sh
su -c 'install -m 755 ./baka /usr/local/bin/baka'
# 如果已经是 root，可直接：install -m 755 ./baka /usr/local/bin/baka
```

之后可以在任意工作目录输入 `baka`、`baka baka` 等；**不需要再部署** `cirno.gif`、`baked/`、Chafa、FFmpeg、Python、源码或字体文件。

也可以把整个项目复制到 Alpine 后运行：`sh build-alpine.sh`。

## 运行时参数

```sh
baka --help
baka --list
baka baka baka                       # 显示 cirno2
baka baka baka baka baka --once       # 黑白 ASCII 动画只播放一轮
baka baka baka baka baka --speed 1.5  # 1.5 倍速
baka baka baka baka baka --duration 8 # 8 秒后结束
```

动画默认无限循环，按 `Ctrl+C` 退出；使用备用屏幕和隐藏光标功能，退出后恢复终端。

## 字体说明

`baka` 内置的是 Unicode UTF-8 **字符本身**，而不是字体的字形图案。普通 CLI 程序无法把字体强制应用到运行它的 Windows Terminal、SSH 客户端或 Android 终端；文字最终由**客户端终端的字体和 fallback 字体**渲染。建议选支持 Unicode Braille（U+2800–U+28FF）、块元素（U+2580–U+259F）和 `ᗜˬᗜ` 的字体组合。

即使另行把一个字体文件放进二进制中，普通终端也不会自动使用它。想强制保证每个像素的外观，需要开发支持终端图像协议（如 Kitty / Sixel）的模式，或自行控制图形显示层，那是另一条渲染路线。

## 已知限制

- 当前打包没有附带原始 `cirno.gif`（它没有随本次文件上传），所以 ZIP 中只有四份静态素材与用于**生成完整单文件可执行程序**的源码/脚本；必须执行上面的 Windows 烘焙步骤才能生成包含动画的最终 `baka`。
- 用了 UTF-8 / ANSI 转义序列，终端需要支持这些字符和控制码；某些极简串口终端字体支持不足。
- 预烘焙是固定尺寸，改变尺寸需要在 Windows 重新生成并编译；播放端无法实时缩放。
- C 播放器只按烘焙的帧时间写入终端，不解码 GIF；性能最终仍受终端性能与 SSH 带宽影响。

## Windows 原生编译并测试 `baka.exe`

这个版本的 `baka.c` 已加入 Windows 兼容层：控制台 UTF-8、ANSI VT 控制码、Ctrl+C、单调时钟和 Sleep。Windows 和 Alpine 都使用同一份 `assets.h`，无需改动每种 `baka` 对应的素材。

### 方法 A：MSYS2 UCRT64 GCC（推荐）

1. 安装 [MSYS2](https://www.msys2.org/)。安装完成后打开 **MSYS2 UCRT64**（注意不是 MSYS 提示符），执行：

   ```sh
   pacman -Syu
   pacman -S --needed mingw-w64-ucrt-x86_64-gcc
   ```

   若更新后提示需要关闭窗口，重新打开 UCRT64 再运行第二条。

2. 解压本项目。**没有 GIF 也可以先编译并测试 1～4 档静态字符画**；若要测试全部动画，把透明 `cirno.gif` 放进项目根目录，并安装 Python 3 / Pillow：

   ```powershell
   py -m pip install Pillow
   ```

3. 在项目目录里打开 PowerShell，运行：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\build-windows.ps1
   ```

   脚本自动使用 `C:\msys64\ucrt64\bin\gcc.exe`（或 PATH 中的 gcc），生成 Windows 原生 `baka.exe`。

   其他选项：`-Size 40x20`、`-Fps 10`、`-SkipBake`（复用已烘焙动画）、`-RequireAnimation`（缺动画则直接报错）、`-Compiler gcc` / `-Compiler cl`。

不想运行 PowerShell 脚本时，直接在 **MSYS2 UCRT64** 中进入项目目录，执行：

```sh
gcc -Os -std=c11 -Wall -Wextra -static -s -o baka.exe baka.c -lm
```

如果已有 `cirno.gif`，请先在 PowerShell 中生成资源：

```powershell
py -m pip install Pillow
py .\bake_cirno.py --size 40x20 --fps 10
py .\build_assets.py --size 40x20
```

### 方法 B：Visual Studio / Build Tools（MSVC）

在已经安装 **Desktop development with C++** 工具的 *Developer PowerShell* 中，进入项目目录：

```powershell
.\build-windows.ps1 -Compiler cl
```

或手动编译：

```powershell
cl /nologo /O2 /utf-8 /std:c11 /Fe:baka.exe baka.c
```

### 在 Windows Terminal 中测试

```powershell
.\baka.exe                     # 1 个 baka：ᗜˬᗜ
.\baka.exe baka                # 2 个 baka：cirno1
.\baka.exe baka baka           # 3 个 baka：cirno2
.\baka.exe baka baka baka      # 4 个 baka：cirno3
.\baka.exe baka baka baka baka --once  # 5 个 baka：黑白 ASCII 动画一轮
.\baka.exe --list
```

动画模式默认无限循环，可按 `Ctrl+C` 退出。如果看到乱码，请使用 Windows Terminal 或兼容 VT 的控制台，并选择支持 Braille / Unicode 的字体。`baka.exe` 包含的是字符数据，**不会自动安装或切换终端字体**。

**注意：** 这个压缩包没有原始 `cirno.gif`。附带的 `assets.h` 只包含静态字符画；只有放入自己的 GIF 并执行预烘焙、重新生成 `assets.h` 之后，5～9 档才会播放真正的旋转动画。
