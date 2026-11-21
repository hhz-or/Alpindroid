# Alpindroid 变更总览：官方 Debian 12 → v0.10

对比基线：`walnutpi/walnutpi-1` v2.6.0 官方镜像
`2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img`

最终产物：`Alpindroid-ZeroW-v0.10.img`（SHA256 `f27f18e4cf6c7f0761ccf341a161f8d37ace5f8ef7479dfcda6a09048329c80c`）

---

## 一、镜像结构层

### 1.1 boot 分区（p1）：24 个文件中只改 2 处

| 文件 | 改动 |
|---|---|
| `config.txt` | ① `rootdev=PARTUUID=e97f9f8e-02` → `rootdev=PARTUUID=<新ID>-02`（新磁盘 ID）<br>② `overlays=spi1 i2c1 i2c2 uart2` → 追加 ` pmic-axp313a` |
| `overlays/sun50i-h616-pmic-axp313a.dtbo` | **新增**（1.6 KB，11 个 fragment） |
| 其余 22 个文件 | **MD5 逐字节相同**：`boot.bin`、`boot.scr`、`Image`(6.1.31)、`sun50i-h616-walnutpi-1b.dtb`(md5 `67164bec…`)、`-emmc.dtb`(`2a946d14…`)、`overlays/` 12 项、`initrd.img-6.1.31`、`uInitrd`、`config-6.1.31` |

**核心原则：原 DTB 完全不改，全部修复通过 DT overlay 实现，可一键回退。**

### 1.2 分区表

| 项 | 官方 | Alpindroid |
|---|---|---|
| 类型 / 布局 | msdos，p1 8192s+286720s(fat16,boot)、p2 294912s+5363712s(ext4) | 结构完全相同 |
| label-id | `0xe97f9f8e` | 每次构建重新生成 |

### 1.3 rootfs（p2）：Debian 12 → Alpine 3.23.8

| 项 | 官方 Debian 12 | Alpindroid |
|---|---|---|
| init | systemd | busybox init + OpenRC |
| 包管理 | dpkg/apt | apk（159 个包） |
| 内核模块 | 133 MB | 原样迁移（含 uwe5622 三个 .ko） |
| 固件 | 3.8 MB | 原样迁移 + 新增 `regulatory.db` |

---

## 二、DT Overlay 的 11 项设备树修复

`patches/dts/pmic-axp313a.dts` → `sun50i-h616-pmic-axp313a.dtbo`

| # | 目标路径 | 改动 | 修复的问题 |
|---|---|---|---|
| 0 | `pmic@36` | `compatible = "x-powers,axp313a"` | 原为 axp305/805/806 → 驱动按 AXP806 处理，regulator 变成 `dcdca~dcdce`，与 DTB 的 `dcdc1/2/3` 完全不匹配 → `cpu-supply` 解析失败 → `cpufreq-dt: deferred probe pending` |
| 1 | `regulators/dcdc2` | `regulator-ramp-delay = <400>` | 驱动未提供 ramp_delay、DTB 也没写 → 框架认为电压爬升时间为 0 → 升压后立即升频，电压未到位就提频 |
| 2 | `regulators/dcdc1` | `ramp-delay = <400>` + `min-microvolt = 900000` | 同上；下限护栏防止 GPU 把共享的 SYS 供电压低 |
| 3 | `regulators/dcdc3` | `min = max = 1100000` | 原厂 DTS 写 **1.3 V**，实测硬件 **1.1 V**（主线 orangepi-zero3/zero2w 也是 1.1 V）。不修正则切到 AXP313A 后 `machine_constraints_voltage()` 会把 DRAM 从 1.1 V 拉到 1.3 V |
| 4 | `thermal-zones/cpu-thermal` | `polling-delay(-passive) = 1000` | 原为 0 → thermal 完全不采样 |
| 5 | `cpu-thermal/trips/cpu-crit` | `temperature = 115000` | 原为 **300000（300 °C）**，永不可能触发 |
| 6 | `thermal-zones/gpu-thermal` | `polling-delay(-passive) = 1000` | 同 #4 |
| 7 | `gpu-thermal/trips/gpu-crit` | `type = "critical"` | 原误设为 `passive`，过热只降频不保护 |
| 8 | `hdmi@6000000` | `hvcc-supply = <0x22>`（vcc-wifi-io） | 原指向 `bldo1` —— **AXP806 的 regulator，AXP313A 根本没有** → HDMI 拿不到供电引用 → `sun4i-drm: Couldn't bind all pipelines components` → 无 `/dev/dri`、无 `/dev/fb0` |
| 9 | `gpu@1800000` | `mali-supply = <0x9e>`（dcdc1） | 原指向 `dcdc3`（DRAM 轨），拓扑错误；按原理图 DCDC1 = GPU+SYS，主线 H618 板级 DTS 亦然 |
| 10 | `gpu-opp-table` | 五档 `opp-microvolt = 900000` | 原 810/810/810/960/1080 mV。810 mV 低于 SYS 工作点 900 mV，会让 Panfrost 把 DCDC1（含 SYS）压低。统一 900 mV 既不降压、又能让 OPP 正常注册 |

---

## 三、用户空间（rootfs）改动

### 3.1 相对 Alpine minirootfs：包 16 → 159

显式安装（`/etc/apk/world`）从 6 项增至 33 项，关键新增：

```
alpine-base, openrc, openssh-server, openssh-client-default
networkmanager, networkmanager-cli, networkmanager-wifi, networkmanager-openrc
dbus, dbus-openrc, eudev, eudev-openrc, wpa_supplicant
ca-certificates, tzdata, e2fsprogs, util-linux, util-linux-login
kmod, iproute2, iputils, iw, ifupdown-ng-wifi
rsync, nano, busybox-extras, sudo, chrony, wireless-regdb, pciutils, usbutils
```

特别说明：
- **`util-linux-login`**：Alpine 3.23 的 busybox **不含 login applet**，`busybox-suid` 的 `bbsuid` 只有 67 KB 且 applet 数为 0，所以必须装这个包提供 `/bin/login`，否则 getty 拉不起登录、键盘输入无人接收。
- **`sudo` + wheel 组**：`alpine` 用户已加入 `wheel`，`/etc/sudoers.d/wheel` 授权。
- **`wireless-regdb`**：解决 `cfg80211: failed to load regulatory.db`。

### 3.2 `/etc` 改动：0 删除 / 277 新增 / 8 修改

被修改的既有文件：

| 文件 | 改动 |
|---|---|
| `hostname` | `localhost` → `alpindroid` |
| `hosts` | 加 `alpindroid` / `alpine` 与 ip6 别名 |
| `inittab` | ① 追加 `ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100`<br>② `tty1~tty6` 的 getty 加 `-L`（跳过载波检测，虚拟终端没有 DCD 信号） |
| `modules` | 追加 `sprdwl_ng`、`sprdbt_tty` |
| `passwd` / `group` / `shadow` | `alpine`(1000) + `messagebus`(100) + `plugdev`(102)；root 与 alpine 设密码 |
| `apk/world` | 见 3.1 |

关键新增：

| 路径 | 说明 |
|---|---|
| `/etc/NetworkManager/system-connections/home.nmconnection` | 600 权限，目录 700；SSID/psk/`interface-name=wlan0` |
| `/etc/conf.d/networkmanager` | `output_log`/`error_log` 落盘 + `-n --log-level=DEBUG` |
| `/etc/conf.d/wpa_supplicant` | `wpa_supplicant_args="-u"`（纯 D-Bus 模式，避免与 NM 抢 wlan0） |
| `/etc/modprobe.d/blacklist-panfrost.conf` | `blacklist panfrost`（见第五节） |
| `/etc/chrony/chrony.conf` | `pool ntp.aliyun.com`、`initstepslew 10`、`rtcsync` |
| `/etc/ssh/sshd_config` | `PermitRootLogin no` + `PasswordAuthentication yes` |
| `/etc/localtime`、`/etc/timezone` | Asia/Shanghai |
| `/etc/runlevels/*` | 见 3.3 |

### 3.3 OpenRC 服务布局

```
sysinit : devfs dmesg hwdrivers udev udev-trigger
boot    : hostname hwclock modules wpa_supplicant
default : chronyd dbus networkmanager sshd
```

---

## 四、功能对比

| 能力 | 官方 Debian 12 | Alpindroid v0.10 |
|---|---|---|
| 包管理 | apt | apk（159 包） |
| **CPU 调频** | ❌ 有报告的锁频问题 | ✅ **6 档 480 MHz–1.344 GHz，ondemand，当前 792 MHz** |
| **CPU 过热保护** | ⚠️ critical=300 °C，仅形式存在 | ✅ **115 °C 生效，cooling_device0 联动** |
| **HDMI 显示** | ✅ | ✅ **1024×600，fbcon 已绑定，EDID 正常** |
| WiFi | ✅ | ✅ `sprdwl_ng`，`home-wifi` 已连接 |
| SSH | ✅ | ✅ `alpine` 用户 + sudo |
| USB 键鼠 | ✅ | ✅ 键盘/触摸屏/红外均识别 |
| 本地终端登录 | ✅ | ✅ getty + util-linux login（键盘本身需为全速/高速设备） |
| 根分区容量 | 2.6 GB | **117 GB（已扩容）** |
| 桌面环境 | 服务器版无桌面 | 无桌面（TTY） |
| GPU 3D | Panfrost 模块存在 | ⚠️ 默认禁用（见第五节） |
| Binder/Waydroid | 未启用 | 未启用（需重编内核） |
| 内核 | 6.1.31 | **同一个 6.1.31，未重编** |

---

## 五、关键技术发现（均有实机证据）

| # | 发现 | 证据 |
|---|---|---|
| 1 | **PMIC 型号声明错误** | 原 DTB `compatible = "x-powers,axp305","axp805","axp806"` → `axp20x-i2c 3-0036: AXP20x variant AXP806 found`；而注册出的是 `dcdca~dcdce`，DTB 需要的是 `dcdc1/2/3` |
| 2 | **芯片实际是 AXP313A** | I2C 直读 `0x13=0x28`→900 mV、`0x14=0x28`→900 mV、`0x15=0x3c`→1100 mV、`0x16=0x0d`→1800 mV、`0x17=0x1c`→3300 mV，按 AXP313A 公式换算全部落在 LPDDR4 典型值 |
| 3 | **DCDC3 应为 1.1 V 而非 1.3 V** | 硬件实测 1.1 V；主线 `sun50i-h618-orangepi-zero3/zero2w` 的 `dcdc3` 也是 `min=max=1100000` |
| 4 | **HDMI 因 `bldo1` 失效** | `hvcc-supply` → `pmic@36/regulators/bldo1`，AXP313A 驱动不创建 bldo1 → `Couldn't bind all pipelines components` |
| 5 | **GPU 供电拓扑错误且共享 SYS** | `mali-supply` → `dcdc3`(DRAM)；而 DCDC1(`vdd-gpu-sys`) 同时供 GPU 和 SYS。v0.4 实测把 GPU 接 dcdc1 后 VGPU 0.9→0.8 V，SYS 供电不足导致无法启动 |
| 6 | **OPP 注册成功会导致 Panfrost 挂起** | v0.6（opp 1.1 V 匹配 dcdc3）与 v0.8（opp 0.9 V 匹配 dcdc1）都无法启动，卡点分别是 udev-trigger 之后与 hwdrivers 中；v0.5/v0.7（opp 被剔除 → 立即 `-ERANGE`）则正常 |
| 7 | **Alpine 3.23 缺 login** | `busybox --list` 无 `login`；`busybox-suid` 只含 67 KB 的 `bbsuid`（applet 数 0）→ `login: must be suid to work properly`。装 `util-linux-login` 解决 |

---

## 六、遗留问题

| # | 问题 | 说明 | 建议 |
|---|---|---|---|
| 1 | GPU 3D 不可用 | `panfrost` 已加入黑名单。O PP 注册成功时它在 devfreq 初始化挂起，需串口日志定位挂起点（时钟/电源域/MMU） | 后续单独实验，v0.7/v0.10 均可作为基线 |
| 2 | i2c2 引脚冲突 | `pin PI5 already requested by 5000800.serial` | 确认不用后从 `overlays=` 移除 `i2c2` |
| 3 | ac200 音频 codec | `probe of 5-0010 failed with error -22` | 核对板上是否真有该 codec |
| 4 | Binder / Waydroid | 内核无 `CONFIG_ANDROID_BINDER_IPC` | 需重编内核（并同步重编 uwe5622 外部模块） |

---

## 七、版本演进

| 版本 | 关键改动 | 结果 |
|---|---|---|
| v0.2 | Alpine + NetworkManager + udev | 可启动，CPU 锁频、HDMI 无输出 |
| v0.2b | NM 连接目录权限 700 + uuid | — |
| v0.2c | busybox-extras / sudo / chrony / wireless-regdb | 稳定基线 |
| v0.3-pm | 首次 PMIC overlay（含禁用 GPU） | ❌ HDMI 全黑 |
| v0.4 | 5 项电源改动 + mali-supply→dcdc1 | ❌ 无法启动（VGPU 0.9→0.8 V） |
| v0.5 | 撤销 mali-supply，加 dcdc1 下限 | ✅ 启动，cpufreq 工作，HDMI 无显示 |
| v0.6 | 修 HDMI hvcc + GPU OPP 电压 | ❌ 卡 udev coldplug |
| v0.7 | 移除 GPU OPP 改动 | ✅ **全部核心功能正常** |
| v0.8-gpu | 重做 GPU 供电（dcdc1 + OPP 0.9 V） | ❌ 卡 hwdrivers |
| v0.9 | v0.8 + panfrost 黑名单 | ✅ 可启动，GPU 可手动实验 |
| **v0.10** | v0.9 + `util-linux-login` + getty `-L` | ✅ **本地终端可登录（键盘需全速设备）** |
| v0.11 | 单档 GPU OPP（432 MHz 固定） | ❌ panfrost 仍挂死 |
| v0.12 | 重编内核：Panfrost 初始化顺序对齐主线 | ❌ 仍挂死（卡在 `bus_clock rate` 之后） |
| v0.13 | 重编内核：完全禁用 GPU DVFS | ❌ 仍挂死（定位到 `panfrost_gpu_init`） |
| **v0.14** | **backport PPU 驱动 + DTS 修正 GPU 供电** | ✅ GPU 驱动链路打通（模块加载受 v0.14 的 bug 影响） |
| v0.15 | 修 overlay 残留 phandle + `config.txt` 漏改 | ⚠️ 仍无 WiFi（遇 `/lib/modules` 层级 bug） |
| **v0.16** | **修 `/lib/modules` 版本目录 + 构建流程固化为一键脚本** | ✅ 全部修复，WiFi/GPU 驱动加载正常 |
| **v0.17** | **补 `panfrost_device_resume` 的复位解除 + 时钟使能** | ✅ **GPU 真实渲染通过（Mali-G31 / Panfrost）** |
| **v0.18** | **Mesa/cgroup2/GPU 验收工具固化进镜像** | ✅ 开箱即用，`/usr/local/bin/gpu_render_test` |

### v0.18 摘要（当前最新）

产物：`Alpindroid-ZeroW-v0.18.img`
SHA256：`79a83716919a6fa12fa516727f9cd9ef425953d9de0d2b5e4a5377dc197abbb5`

相对 v0.17，把原本需要在板上手工完成的工作全部固化：

| 项目 | 内容 |
|---|---|
| GPU 软件栈 | chroot + QEMU 安装 `mesa / mesa-dri-gallium / mesa-gbm / mesa-egl / mesa-gles / mesa-gl / mesa-utils / libdrm-tests` |
| GPU 验收工具 | `/usr/local/src/gpu_render_test.c`（源码）+ `/usr/local/bin/gpu_render_test`（aarch64 二进制） |
| Waydroid 前置 | `cgroup2` 自动挂载（写入 `/etc/fstab`） |
| 系统服务 | `sysctl` 加入 boot runlevel、BinderFS 写入 fstab、chrony 用 `ntp1.aliyun.com` |

构建时自动校验 15 项，含 `panfrost_dri.so` / `eglinfo` / `cgroup2` 三项 GPU 相关检查。

**烧录后开箱验证**：

```sh
# GPU（无需安装任何东西）
/usr/local/bin/gpu_render_test        # 期望 RESULT: PASS

# Waydroid 前置
findmnt /sys/fs/cgroup                # 期望 cgroup2
ls /dev/binderfs/                     # binder hwbinder vndbinder
```

### v0.17 摘要

产物：`Alpindroid-ZeroW-v0.17.img`
SHA256：`03e9647446ded3d888b6a6e8e458314b258c5e34538cb71baf0a20c7190967c6`

相对 v0.16：
- `panfrost_device_resume/suspend` 补上 `reset_control_deassert` + `clk_prepare_enable`（详见 9.12）
- 构建脚本自动启用 `sysctl` 服务、挂载 BinderFS、修正 chrony 时间源

**实测结果**：`GL_RENDERER = Mali-G31 (Panfrost)`，真实绘制三角形后 `glReadPixels` 回读 `(0,255,0,255)`，**RESULT: PASS**。

### v0.16 摘要

产物：`Alpindroid-ZeroW-v0.16.img`
SHA256：`536c81782d9402afe3283bbb5d7cc1d4cf43132c9edcd6beb6812bb5077f3856`

`scripts/build-alpindroid.sh` 一键构建，内含 11 项自动校验（模块层级 / 关键 .ko / DTB 节点 / 固件 / config.txt），任一失败即中止。详见 9.6–9.8 三节。

### 9.9 v0.16 实机验证：全部通过 ★★★

烧录 v0.16 后（板子 DHCP 到 `192.168.137.195`，MAC `bc:3f:0b:44:1a:c2`）：

| 项目 | 状态 | 实测值 |
|---|---|---|
| 内核 | ✅ | `6.1.31+` |
| **模块目录** | ✅ | `/lib/modules/6.1.31+`，3034 个 `.ko`，`modules.dep` 存在 |
| **WiFi** | ✅ | `wlan0 UP`，`192.168.137.195/24`，SSID=`Desktop`，NM 状态 `connected` |
| WiFi 模块 | ✅ | `sprdwl_ng` / `uwe5622_bsp_sdio`（2 引用）/ `sprdbt_tty` / `cfg80211` / `rfkill` |
| **GPU** | ✅ | `/dev/dri/{card0,card1,renderD128}` |
| panfrost | ✅ | 3 模块加载；`mali-g31 id 0x7093`；`shader_present=0x1 l2_present=0x1`；`Initialized panfrost 1.2.0` |
| PMIC | ✅ | `x-powers,axp313a`（overlay 生效） |
| 电源实测 | ✅ | `vcc33-wifi 3300000` / `vcc-wifi-io 1800000` / `vdd-gpu-sys 900000` / `vdd-cpu 900000` / `vdd-dram 1100000` µV |
| CPU 调频 | ✅ | `policy0` ondemand，cur/max = 1344000 |
| BinderFS | ✅ | `binder` `hwbinder` `vndbinder` `binder-control` `features` |
| HDMI | ✅ | `connected` |
| 串口 | ✅ | `console=ttyS2,115200 console=tty0`，`printk = 8 4 1 7` |
| 时间同步 | ✅ | chrony `200 OK`，与真实时间一致 |

### 9.10 板上收尾修复（已回灌构建脚本）

| 问题 | 原因 | 修复 |
|---|---|---|
| `printk` 仍是 `1 4 1 7` | Alpine 的 `sysctl` 服务没在 runlevel 里，`/etc/sysctl.d/*.conf` 不执行 | `rc-update add sysctl boot` |
| BinderFS 未挂载 | 内核 `CONFIG_ANDROID_BINDERFS=y` 但无挂载点 | 挂载 + 写 `/etc/fstab` |
| 时间停在 1970 | chrony 默认配置的 `ntp.aliyun.com` **域名不存在**（NXDOMAIN，正确名是 `ntp1..7.aliyun.com`） | 改用 `ntp1.aliyun.com`，`chronyc makestep` 立即校正 |

### 9.11 仍然遗留

| 事项 | 说明 |
|---|---|
| 磁盘未扩容 | rootfs 2.4 G（p2 分区 2.6 G）。需要时 `growpart /dev/mmcblk1 2` + `resize2fs` |
| mesa 未装 | 板子 `apk` 源曾因时间 1970 导致 TLS 失败；时间已修，可正常 `apk add mesa*` 后再做 glmark2 基准 |
| GPU DVFS | 仍为单档 432 MHz @ 0.9 V（有意，`dcdc1` 与 SYS 共用）。放开需先回移 CVE-2025-38041 的 PLL reparent 补丁 |
| 时间不持久 | 无 RTC 电池，每次断电回到 1970；已靠 chrony 联网自动校正 |

### 9.12 GPU 渲染攻关：第四个 bug —— `resume` 缺复位解除与时钟使能 ★★★

v0.16 之后 GPU 能 probe、能识别、空闲正常，但**一使用 GPU 就硬挂死**（串口连 printk 都打不出来，必须断电重启）。这是本次攻关最难的一个 bug。

**现象与排除过程**：

| 观察 | 推断 |
|---|---|
| probe 能读到 `mali-g31 id 0x7093` | GPU 硬件、时钟、电源、MMU 初始化都正常 |
| 空闲 50 ms 后 autosuspend（`control=auto`），`GPU off-0` | GPU 进入挂起 |
| 任何后续 GPU 访问（`eglinfo` / `echo on > power/control` / `rmmod panfrost`）→ **静默硬挂死** | 总线级锁死，不是普通 oops |
| PPU 寄存器实测 `GPU gate = 0x1`，手动写 `0x0` 后再访问 GPU → **两种极性都挂死** | **排除电源极性假设** |

**根因**（对比主线源码发现）：

```c
/* 主线 panfrost_device_runtime_resume() */
if (pfdev->comp->pm_features & BIT(GPU_PM_RT)) {
    ret = reset_control_deassert(pfdev->rstc);   /* ① 解除复位 */
    ret = panfrost_clks_enable(pfdev, true);     /* ② 重新使能时钟 */
}
panfrost_device_reset(pfdev, true);
panfrost_devfreq_resume(pfdev);

/* 厂商 panfrost_device_resume() —— ①② 全缺！ */
panfrost_device_reset(pfdev);      /* 直接在「复位中 + 无时钟」状态下访问寄存器 */
panfrost_devfreq_resume(pfdev);
```

suspend 时 GPU 电源域关闭、时钟停摆、复位被断言；resume 时厂商版本既不 deassert 复位也不重新使能时钟，就直接去读写 GPU 寄存器 → **总线锁死**。

**修复**（`patches/kernel/panfrost-resume-fix.patch`，也可用 `patches/kernel/fix_panfrost_pmrt.py` 自动应用）：

```c
int panfrost_device_resume(struct device *dev)
{
    int ret;
    ret = reset_control_deassert(pfdev->rstc);
    if (ret) return ret;

    ret = clk_prepare_enable(pfdev->clock);
    if (ret) { reset_control_assert(pfdev->rstc); return ret; }

    if (pfdev->bus_clock) {
        ret = clk_prepare_enable(pfdev->bus_clock);
        if (ret) {
            clk_disable_unprepare(pfdev->clock);
            reset_control_assert(pfdev->rstc);
            return ret;
        }
    }

    panfrost_device_reset(pfdev);
    panfrost_devfreq_resume(pfdev);
    return 0;
}
```

suspend 侧同步做对称处理（`clk_disable_unprepare` × 2 + `reset_control_assert`）。

**验证证据（实机）**：

```
# ① 曾经必死的动作，现在瞬间完成
echo on > /sys/devices/platform/soc/1800000.gpu/power/control
  rc=0   （耗时 0 秒）
  runtime_status: active

# ② EGL 报告的是真硬件 renderer
EGL_PLATFORM=surfaceless eglinfo -B
  OpenGL core profile renderer: Mali-G31 (Panfrost)
  OpenGL core profile version : 3.1 (Core Profile) Mesa 25.2.7
  OpenGL ES profile renderer  : Mali-G31 (Panfrost)
  OpenGL ES profile version   : OpenGL ES 3.1 Mesa 25.2.7

# ③ 真实渲染测试（scripts/gpu_render_test.c）
GL_RENDERER   : Mali-G31 (Panfrost)
GL_VERSION    : OpenGL ES 3.1 Mesa 25.2.7
GLSL version  : OpenGL ES GLSL ES 3.10
PIXEL center  : R=0 G=255 B=0 A=255     ← 回读像素与预期一致
RESULT        : PASS（GPU 真实完成了光栅化）
DONE   rc=0
```

**方法论要点**：

1. **`eglinfo` 成功 ≠ GPU 可用**。它只证明 EGL 初始化路径通。必须做到「编译 shader → draw call → `glReadPixels` 校验像素值」，才能证明光栅化真的发生。`scripts/gpu_render_test.c` 就是为此写的。
2. **判断硬件 vs 软件渲染**：看 `GL_RENDERER`。`Mali-G31 (Panfrost)` = 硬件；`llvmpipe`/`softpipe` = CPU 软件渲染。
3. **静默硬挂死时，串口都打不出 printk**，说明是总线级锁死，而非普通内核 oops——这时只能靠「哪些动作会触发」来缩小范围，并用寄存器直读做对照实验。
4. **修 runtime PM 类问题时，必须 suspend/resume 成对检查**。只改 resume 不改 suspend，会留下「时钟开着但电源域已关」的中间态。

### 9.13 GPU 稳定性回归（v0.18 验收）★★★

单次渲染通过不代表稳定。按三类测试做完整回归（脚本 `scripts/gpu_stress_test.c` + 用户提供的 repeat 脚本）：

| 测试 | 内容 | 结果 |
|---|---|---|
| **A 连续渲染** | 单 EGL Context 连续 10,000 帧，抽样回读像素 | ✅ 2 秒完成，`bad=0`（≈5000 FPS @ 256×256） |
| **B 资源反复创建** | 创建/销毁 EGL Context 100 次 | ✅ 16 秒完成，`fails=0` |
| **C Runtime PM** | 释放资源→等自动休眠→再渲染，100 轮 | ✅ **100/100 PASS，`SAW_SUSPENDED=100`** |
| **D 持续负载** | 温度与稳定性 | ✅ 51°C→68°C，无卡死，dmesg 无 GPU 错误 |

**Runtime PM 决定性证据**（`power/runtime_active_time` / `runtime_suspended_time`）：

```
测试前  active=0         suspended=90,786 ms
测试后  active=24,625    suspended=1,118,309 ms

100 轮 C + 100 轮 B 期间，GPU 累计活跃仅 +13.1 秒，
说明每轮渲染完立刻回到 suspended，下次访问时再 resume。
→ reset_control_deassert + clk_prepare_enable 这条路径至少被执行 200 次，全部成功。
```

验证要点：`power/control` 必须是 `auto`（若为 `on` 则根本不会休眠，测不出 resume 路径）；只看 100 次 PASS 不够，必须同时观察到 `runtime_status=suspended` 且计数器增长。

### 9.14 mesa 与工具链

```sh
# 官方源在国内极慢（apk update 20 分钟无进展），换阿里云镜像
echo "https://mirrors.aliyun.com/alpine/v3.23/main
https://mirrors.aliyun.com/alpine/v3.23/community" > /etc/apk/repositories

apk add mesa mesa-dri-gallium mesa-egl mesa-gles mesa-utils libdrm-tests
# → mesa 25.2.7，184 包 / 288 MiB
# → /usr/lib/dri/ 出现 panfrost_dri.so / kms_swrast_dri.so / swrast_dri.so

# 编译渲染测试需要
apk add gcc musl-dev mesa-dev    # 226 包 / 688 MiB
```

注意 `card1`（panfrost）权限是 `crw-rw---- root video`，非 root 用户需加入 `video` 组；`renderD128` 是 `crw-rw-rw-`，任何用户可访问。

---

## 九、v0.14：GPU（Mali-G31 / Panfrost）彻底修复 ★

### 9.1 根因（三个叠加问题）

| # | 问题 | 证据 |
|---|---|---|
| **1** | **厂商删除了 PPU 驱动**（GPU 电源域控制器） | `drivers/soc/sunxi/` 只有 `sunxi_mbus.c`/`sunxi_sram.c`；defconfig 无任何 PPU 配置；dtsi 无 `prcm_ppu` 节点。主线 Kconfig 原文：*"This is required to enable the Mali GPU in the H616 SoC"* |
| **2** | **厂商把 `mali-supply` 接到 `dcdc3`**，而 dcdc3 是 `vdd-dram`（固定 1.3 V） | 板级 dts：`reg_dcdc3 { regulator-name = "vdd-dram"; min = max = 1300000; }`；真正的 GPU 电源是 `reg_dcdc1`（`vdd-gpu-sys`） |
| **3** | **overlay 里硬编码 phandle `0x9e`** 指向 dcdc1，重编 DTB 后编号变成 `0x0d`/`0x9f` | 每次编译 phandle 都变；`mali-supply` 指向错节点 → 静默 `-EPROBE_DEFER` |

**挂死机制**：GPU 的 PPU domain 2 从未上电 → `panfrost_gpu_soft_reset()` 向寄存器写复位命令后永远等不到硬件响应 → 无限轮询卡死。

### 9.2 修复内容

**① backport PPU 驱动**（`patches/kernel/ppu/sun50i-h6-prcm-ppu-6.1.c`）
- 来源：主线 `drivers/pmdomain/sunxi/sun50i-h6-prcm-ppu.c`（5710 B，Arm Ltd. 2024）
- 适配 6.1 的 4 处改动：
  - `devm_kzalloc_objs(dev, *pds, n)` → `devm_kcalloc(dev, n, sizeof(*pds), GFP_KERNEL)`
  - `devm_kzalloc_obj(dev, *ppu)` → `devm_kzalloc(dev, sizeof(*ppu), GFP_KERNEL)`
  - `devm_kzalloc_objs(dev, *ppu->domains, n)` → `devm_kcalloc(dev, n, sizeof(*ppu->domains), GFP_KERNEL)`
  - 补 `#include <linux/of_device.h>`（`of_device_get_match_data` 声明）与 `<linux/slab.h>`
- 落地位置：`drivers/soc/sunxi/`，配 Kconfig `SUN50I_H6_PRCM_PPU` + Makefile + `CONFIG_SUN50I_H6_PRCM_PPU=y`

**② dtsi 加 PPU 节点**（`sun50i-h616.dtsi`，`r_ccu` 之后）
```dts
prcm_ppu: power-controller@7010250 {
    compatible = "allwinner,sun50i-h616-prcm-ppu";
    reg = <0x07010250 0x10>;
    #power-domain-cells = <1>;
};
```

**③ 板级 dts 修正 GPU 供电与电源域**（`sun50i-h616-walnutpi-1b.dts`）
```dts
&gpu {
    mali-supply = <&reg_dcdc1>;              /* 原为 &reg_dcdc3 (vdd-dram!) */
    operating-points-v2 = <&gpu_opp_fixed>;  /* 原为三档 gpu_opp_table */
    power-domains = <&prcm_ppu 2>;           /* 新增：GPU 电源域 */
    status = "okay";
};

/* 单档 OPP：dcdc1 与 SYS 共用，压低会拖垮系统，故固定 0.9 V 不做 DVFS */
&{/} {
    gpu_opp_fixed: gpu-opp-fixed {
        compatible = "operating-points-v2";
        opp-432000000 {
            opp-hz = /bits/ 64 <432000000>;
            opp-microvolt = <900000>;
        };
    };
};
```
另外 `reg_dcdc1` 的 `regulator-min-microvolt` 由 `810000` 提高到 `900000`。

**④ overlay 移除 GPU fragment**：删除原 `fragment@9`（`gpu_opp_fixed`）和 `fragment@10`（`mali-supply`/`operating-points-v2`），因为这两项已进板级 dts，overlay 里的硬编码 phandle 会覆盖成错误节点。现 overlay 只保留 9 个 fragment（PMIC / thermal / HDMI）。

**⑤ 移除 `/etc/modprobe.d/blacklist-panfrost.conf`**，GPU 开机自加载。

### 9.3 验证证据（实机）

```
=== /dev/dri ===
card0        HDMI (sun4i-drm)
card1        panfrost        ← 新增
renderD128   panfrost        ← GPU render node

=== 开机 5.97 秒自动初始化 ===
panfrost 1800000.gpu: clock rate = 432000000
panfrost 1800000.gpu: bus_clock rate = 200000000
panfrost 1800000.gpu: mali-g31 id 0x7093 major 0x0 minor 0x0 status 0x0
panfrost 1800000.gpu: Features: L2:0x07100206 Shader:0x00000000 Tiler:0x00000209 Mem:0x1 MMU:0x00002821 AS:0xff JS:0x7
panfrost 1800000.gpu: shader_present=0x1 l2_present=0x1
[drm] Initialized panfrost 1.2.0 20180908 for 1800000.gpu on minor 1

=== PPU genpd ===
/sys/bus/platform/devices/7010250.power-controller → sun50i-h6-prcm-ppu
genpd 域: PLL / ANA / GPU

=== 节点引用校验 ===
mali-supply  = 0x0d  ↔  dcdc1       = 0x0d   ✅
opp          = 0x0e  ↔  gpu-opp-fixed = 0x0e ✅
power-domains= 0x0f+2 ↔ prcm_ppu    = 0x0f   ✅
vdd-gpu-sys  = 900000 µV                      ✅
```

### 9.4 调试方法论（可复用）

**关键突破点：串口**。ZeroW 的调试串口有两个位置：
- **UART0 = PH0/PH1**（官方调试口，在 **FPC 座**上，需转接板）
- **UART2 = PI5(TX)/PI6(RX)**（40Pin 排针，改 `config.txt` 的 `console_uart=uart2` 即可）

接线：`PI5 → USB-TTL RX`、`PI6 → USB-TTL TX`、`GND → GND`（**VCC 悬空**，3.3V 电平）。

配套脚本 `scripts/serial-capture.ps1`（Windows，自动检测 COM 口，DTR/RTS 保持关闭避免复位板子）。

**定位手法**：在 `panfrost_device_init()` 的每个步骤前插 `pr_info("Alpindroid-STEP: xxx")`，挂死时串口最后一行即精确位置：
```
pm_domain_init → reset_init → clk_init → devfreq_init
→ regulator_init → ioremap → gpu_init   ← 三次尝试都卡在这
```
这直接推翻了「时钟/电压/DVFS」假设，把问题指向硬件供电。

### 9.5 踩过的坑

| 坑 | 现象 | 解法 |
|---|---|---|
| overlay 硬编码 phandle | 重编 DTB 后 `mali-supply` 指向错节点，静默 `-EPROBE_DEFER`，probe 无任何错误日志 | 一律用 **label**（`&reg_dcdc1`）而非 phandle 数字 |
| `panfrost.ko` 变成 0 字节 | `insmod: Invalid parameters`，但 `lsmod` 仍显示模块已加载（易误判为成功） | 板子挂死时 `cp` 可能写不完整；判断 probe 结果要看 `/sys/bus/platform/devices/*/driver` 绑定 |
| 模块与内核 vermagic | 内核改了配置（加 PPU）后旧 `.ko` 会 `Invalid argument` | 换内核必须同步 `modules_install` 并用新 `.ko` |
| DTS 语法 | `Properties must precede subnodes` | 新节点用 `&{/} { ... }` 追加到文件末尾，不要插在属性中间 |
| 板子时间 1970 | `apk` 报 `TLS: server certificate not trusted` | `date -s` 同步时间后正常 |
| PowerShell 读 UTF-8 无 BOM 脚本 | 中文乱码导致解析错误 | 存成 **UTF-8 with BOM** |
| `apk` 数据库锁 | `Unable to lock database` | 之前卡住的 `apk search` 进程未退出；精确 `kill -9 <pid>`（**勿用宽泛 pkill**） |

### 9.6 v0.15 补修：overlay 硬编码 phandle 拖垮 WiFi ★

v0.14 烧录后 **WiFi 消失（无 wlan0）**。根因是同类问题的遗漏——overlay 里**还剩一处硬编码 phandle**：

```dts
/* overlay fragment@8（v0.14 时仍在） */
fragment@8 {
    target-path = "/soc/hdmi@6000000";
    __overlay__ {
        hvcc-supply = <0x22>;    /* 本意 = vcc-wifi-io */
    };
};
```

板级 dts 原本写的是 `hvcc-supply = <&reg_bldo1>`，而 **AXP313A 没有 bldo1**（那是 AXP806 的），所以厂商用 overlay 以硬编码 phandle 兜底。重编 DTB 后：

| DTB 版本 | phandle `0x22` 指向 |
|---|---|
| 原厂 DTB | `vcc-wifi-io`（1.8 V，WiFi IO） |
| 重编 DTB | **`vcc33-wifi`（3.3 V，WiFi 主供电）** ← 漂移 |

结果 **HDMI 驱动把 WiFi 的 3.3 V 主供电当成自己的 IO 电源来管理**（regulator framework 会 enable/disable），WiFi 模块上电时序被打乱 → SDIO 探测失败 → `ip link` 看不到 wlan0。

**修法**：彻底不再依赖 overlay 的 phandle。

```dts
/* 板级 dts 直接写对（用 label） */
&hdmi {
    hvcc-supply = <&reg_vcc_wifi_io>;
    status = "okay";
};
```

并删除 overlay 的 `fragment@8`。现 overlay 只剩 **8 个 fragment**（PMIC 4 + thermal 4），**全文 0 处硬编码 phandle**，此后重编 DTB 不会再出现 phandle 漂移问题。

验证：新 DTB 里 `hdmi@6000000/hvcc-supply = 0x23`，而 `vcc-wifi-io = 0x23`、`vcc33-wifi = 0x22` —— 指向正确。

**通用教训**：DT overlay 里**永远不要写 `<0x..>` 形式的 phandle 引用**，一律用 label（`&reg_xxx`）。若目标节点在 dtsi 中无 label，就给它加 label，或直接把属性写进板级 dts。

### 9.7 v0.15 第二个 bug：构建流程漏改 `config.txt` ★

v0.14 的 WiFi 消失其实有**两个**叠加原因，第二个更致命：

`scripts/build-image.sh` 是从**原厂底板镜像**复制 boot 分区的，因此 `config.txt` 保持原厂内容。而我在 v0.12~v0.14 的构建流程里**只在板子上手动改过 config.txt，构建镜像时忘了改**。于是 v0.14 镜像里：

```ini
console_uart=uart0                    # 应该是 uart2（否则 40Pin 串口无输出）
overlays=spi1 i2c1 i2c2 uart2         # 缺少 pmic-axp313a ！
```

**dtbo 文件放进了 `/boot/overlays/`，但 `config.txt` 从不引用它 → overlay 根本没被 apply。**

连锁后果：

| 环节 | 后果 |
|---|---|
| PMIC 被识别为 AXP806（`compatible` 未改） | regulator 变成 `dcdca~dcdce`/`aldo1~2`/`bldo1`/`cldo1` |
| 板级 dts 定义的 `dcdc1/dcdc2/dcdc3` 全部找不到 | `cpu-supply`/`mali-supply` 悬空 |
| **`vcc5v` / `vcc3v3` 供电树异常** | **WiFi 模块 3.3 V 主供电时序错乱 → SDIO 探测不到设备 → 没有 wlan0** |
| `console_uart=uart0` | 串口接在 PI5/PI6（UART2）上时看不到任何内核日志，排障失明 |

**修法**：构建镜像时必须同时改这两行：

```bash
sed -i 's/^console_uart=uart0/console_uart=uart2/'                  /mnt/boot/config.txt
sed -i 's/^overlays=\(.*\)/overlays=\1 pmic-axp313a/'               /mnt/boot/config.txt
```

**教训**：**凡是「镜像构建 + 板上手动调参」两条腿走路时，手动步骤必须回灌到构建脚本**，否则重烧镜像就等于丢掉全部手动修复。判断 overlay 是否真生效，最可靠的检查是：

```sh
# 板子上（不看文件存在性，看运行时实际值）
cat /proc/device-tree/soc/i2c@7081400/pmic@36/compatible   # 应为 x-powers,axp313a
cat /proc/cmdline | tr ' ' '\n' | grep console             # 应为 console=ttyS2,115200
```

### 9.8 v0.15 第三个 bug（最致命）：`/lib/modules` 少了版本目录 ★★★

v0.14/v0.15 里 **所有模块都加载不了**，WiFi 自然也没有。根因是一行 cp 的用法错误：

```sh
rm -rf "$ROOT/lib/modules"
cp -a /tmp/newmods/lib/modules/6.1.31+ "$ROOT/lib/modules/"     # ← 错
```

`rm -rf` 之后 `$ROOT/lib/modules` 已不存在，此时 GNU `cp -a src dst/` 会**把 `dst` 本身创建成 src 的副本**，于是 `6.1.31+` 这一层被吃掉，镜像里变成：

```
/lib/modules/kernel/...          ← 实际
/lib/modules/modules.dep
```

而内核 `uname -r` = `6.1.31+`，`modprobe` 只会去 `/lib/modules/6.1.31+/` 找东西 —— **目录不存在，一切模块加载失败**。系统仍能启动，因为核心驱动全部 built-in，极具迷惑性。

**症状识别**：

```sh
ls /lib/modules/            # 若直接看到 kernel/、modules.dep 而没有 6.1.31+/ 目录 → 就是这个 bug
ls /lib/modules/$(uname -r)/   # No such file or directory
modprobe sprdwl_ng          # FATAL: Module sprdwl_ng not found in directory /lib/modules/6.1.31+
```

**修法**（见 `scripts/replace-modules.sh`）：

```sh
rm -rf "$ROOT/lib/modules"
mkdir -p "$ROOT/lib/modules/6.1.31+"
cp -a /tmp/newmods/lib/modules/6.1.31+/. "$ROOT/lib/modules/6.1.31+/"
```

关键在 **`src/.`**：复制「源目录的内容」而不是「源目录本身」，避免层级被吃。

**另一处配套隐患**：原厂底板镜像的模块目录叫 `6.1.31`（无 `+`），自编内核是 `6.1.31+`（有 `+`，因 git 有额外提交）。`build-image.sh` 原先硬编码检查 `6.1.31`，已改为两者都接受。

**通用教训**：替换内核模块后，**必须验证三层**：

```sh
ls -d /lib/modules/*/                      # ① 版本目录存在
ls /lib/modules/$(uname -r)/modules.dep    # ② dep 数据库在版本目录内
find /lib/modules/$(uname -r) -name '*.ko' | wc -l   # ③ 模块数量合理
```

不要只看「文件是否存在」——`find /lib/modules -name xxx.ko` 在层级错误时**照样能找到**，但 `modprobe` 用不到。

---

## 八、回退方式

| 场景 | 操作 |
|---|---|
| 单次启动回退 | boot 分区（FAT32）编辑 `config.txt`，删掉 `overlays=` 里的 ` pmic-axp313a` |
| 完全回退 | 重烧 `v0.2c`（`7904e30c…`）或官方镜像 |
| GPU 恢复实验 | 删除 `/etc/modprobe.d/blacklist-panfrost.conf` 或手动 `modprobe panfrost` |
| GPU 再次挂死 | 恢复 `patches/kernel/ppu/` 之外的旧内核（v0.13 的 `88e6f13a…`），或从板级 dts 移除 `power-domains` 行重新编译 DTB |

### 8.1 镜像存放位置

| 版本 | SHA256（前 16 位） | 存放位置 | 说明 |
|---|---|---|---|
| **v0.10** | `f27f18e4cf6c7f07` | **云端归档**（用户保存）+ 编译机 `~/alpindroid/output/` | **长期稳定基线**：原厂内核、CPU 调频 / HDMI / WiFi 全通、GPU 禁用 |
| v0.7 | — | 本地 `output/` + 编译机 | **长期稳定基线**：全部核心功能正常 |
| **v0.16** | `536c81782d9402af` | 本地 `output/` + 编译机 | 当前最新：GPU + WiFi 完整修复 |
| v0.1 ~ v0.15 | 见编译机 `sha256sum` | 仅编译机 `~/alpindroid/output/`（20 个镜像约 54 GB） | 中间版本，本地已部分清理 |

复现任一版本：

```sh
# 编译机上重新构建（推荐，脚本已固化全部修复）
cd ~/alpindroid/scripts
sudo sh build-alpindroid.sh v0.17 /tmp/newmods14/lib/modules/6.1.31+

# 或从编译机下载历史镜像
scp lz@192.168.71.68:~/alpindroid/output/Alpindroid-ZeroW-v0.10.img .
```

