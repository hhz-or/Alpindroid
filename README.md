# Alpindroid

WalnutPi ZeroW（Allwinner H618）上的 **Alpine Linux 3.23 系统**，从官方 Debian 12 镜像改造而来。

不编译 AOSP，目标是在轻量 Alpine 上把硬件全部跑通，最终承载 Waydroid（Android 容器）。

---

## 当前状态：v0.18（稳定基线）

| 子系统 | 状态 | 关键实现 |
|---|---|---|
| 启动链 | ✅ 原厂 boot.bin / boot.scr / Image | 只替换 p2 用户空间 |
| CPU 调频 | ✅ ondemand, 480 MHz ~ 1.344 GHz | AXP313A `dcdc2` → `vdd-cpu` |
| 电源管理 | ✅ PMIC 识别为 `axp313a` | DT overlay 修正 `compatible` |
| HDMI 显示 | ✅ 1080p 输出 | `hvcc-supply` 指向 `vcc-wifi-io` |
| **WiFi** | ✅ `wlan0` 自动连网 | UNISOC uwe5622（`sprdwl_ng`） |
| 蓝牙 | ✅ | `sprdbt_tty` |
| USB | ✅ 含触摸屏 | `OpenWare Multi-Touch-V5000` |
| **GPU** | ✅ **Mali-G31 / Panfrost, OpenGL ES 3.1** | backport PPU 驱动 + resume 修复 |
| BinderFS | ✅ binder/hwbinder/vndbinder | 为 Waydroid 准备 |
| cgroup2 | ✅ 自动挂载 | Waydroid 必需 |
| GPU 验收 | ✅ 开箱可用 | `/usr/local/bin/gpu_render_test` |

**验证证据**：

```
GL_RENDERER   : Mali-G31 (Panfrost)
GL_VERSION    : OpenGL ES 3.1 Mesa 25.2.7
渲染压力测试   : 10000 帧 / 2 秒 / 0 错误
Context 反复   : 100 次 / 16 秒 / 0 失败
Runtime PM    : 100/100 真实 suspend→resume 后绘制成功
```

---

## 仓库结构

```
├── CHANGELOG-Alpindroid.md      ★ 完整技术档案（含所有根因分析与验证证据）
├── CHANGES-vs-debian12.md       与官方 Debian 12 镜像的差异
├── IMAGES.md                    镜像清单与 SHA256
│
├── kernel/                      ★ 内核修改（可重现构建的核心资产）
│   ├── alpindroid-kernel.patch  相对上游的完整 diff
│   ├── config/
│   │   └── config-6.1.31-plus   实际使用的 .config
│   └── linux-6.1.31/            修改后的完整源文件
│       ├── drivers/soc/sunxi/                       PPU 驱动（新增）
│       ├── drivers/gpu/drm/panfrost/                resume 修复
│       └── arch/arm64/                              DTS + defconfig
│
├── patches/
│   ├── dts/
│   │   ├── pmic-axp313a.dts     DT overlay 源（8 fragment）
│   │   ├── AXP313A-FINDINGS.md  PMIC 实测记录
│   │   └── gpu/                 GPU 修复补丁集 + README
│   └── kernel/
│       ├── panfrost-resume-fix.patch
│       └── fix_panfrost_pmrt.py 自动应用脚本
│
└── scripts/                     构建与测试工具
    ├── build-alpindroid.sh      ★ 一键构建（15 项自动校验）
    ├── replace-modules.sh       安全替换内核模块
    ├── install-gpu-stack.sh     mesa 注入（chroot+QEMU）
    ├── gpu_render_test.c        GPU 单次渲染验收
    ├── gpu_stress_test.c        GPU 压力测试（万帧 + 百次 context）
    ├── hw-check.sh              硬件自检
    ├── serial-capture.ps1       串口抓日志（排障必备）
    └── ssh-run.ps1              远程执行/上传/下载
```

---

## 快速开始

### 构建镜像

```bash
cd ~/alpindroid/scripts
sudo sh build-alpindroid.sh v0.19 /tmp/newmods/lib/modules/6.1.31+
```

输出 `~/alpindroid/output/Alpindroid-ZeroW-v0.19.img`，构建时自动校验 15 项。

### 内核修改如何复现

```bash
# 1. 取上游源码
git clone --depth 1 -b 6.1.31 https://github.com/walnutpi/linux.git linux-6.1.31
cd linux-6.1.31

# 2. 应用改动（用仓库里的完整文件覆盖，或打 patch）
#    方式 A：直接覆盖（最简单）
cp -a <repo>/kernel/linux-6.1.31/. .
cp    <repo>/kernel/config/config-6.1.31-plus .config

#    方式 B：打 diff
patch -p1 < <repo>/kernel/alpindroid-kernel.patch

# 3. 编译
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j8 Image modules dtbs
```

### 板上验收（无需安装任何东西）

```sh
/usr/local/bin/gpu_render_test     # 期望 RESULT: PASS
```

---

## 三个最关键的坑（详见 CHANGELOG 第九、十章）

| # | 问题 | 现象 | 教训 |
|---|---|---|---|
| 1 | 厂商删除 **PPU 驱动** | `modprobe panfrost` 无限挂死 | GPU 电源域控制器缺失，硬件根本没电 |
| 2 | `mali-supply` 接错 `dcdc3`（vdd-dram） | 供电错乱 | 名字 `vdd-gpu-sys` 才是 GPU 电源 |
| 3 | **`resume` 缺 reset deassert + clk enable** | probe 正常，一用 GPU 就静默硬挂死 | runtime PM 必须 suspend/resume 成对检查 |
| 4 | **`/lib/modules` 少版本目录** | 所有模块加载失败 | `cp -a src dst/` 会吃掉一层，要用 `src/.` |
| 5 | overlay 硬编码 phandle | 重编 DTB 后指向错节点，静默 EPROBE_DEFER | **一律用 label** |

---

## 下一步

- **v0.19**：Weston（DRM backend）+ Panfrost + HDMI + 触摸屏
- **v0.20**：Waydroid 容器
- **v0.21**：Android 图形加速

详见 `CHANGELOG-Alpindroid.md` 路线图章节。