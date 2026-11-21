# GPU（Mali-G31 / Panfrost）修复补丁集

针对核桃派 WalnutPi ZeroW（H618 / H616 家族）厂商内核 6.1.31 的 GPU 支持修复。

## 问题现象

`modprobe panfrost` 后**无限挂死**，串口最后输出：

```
panfrost 1800000.gpu: clock rate = 432000000
panfrost 1800000.gpu: bus_clock rate = 200000000
（卡死，无任何错误）
```

## 根因（三个叠加问题）

### 1. 厂商删除了 PPU 驱动 —— 主因

H616 的 GPU 电源由 **PRCM PPU**（Power Processing Unit，`0x07010250`）控制，GPU 挂在 **domain 2**。

主线 Kconfig 原文明确写着：

```
config SUN50I_H6_PRCM_PPU
	help
	  Say y to enable the Allwinner H6/H616 PRCM power domain driver.
	  This is required to enable the Mali GPU in the H616 SoC, it is
	  optional for the H6.
```

而厂商内核里：

| 位置 | 状态 |
|---|---|
| `drivers/soc/sunxi/` | 只有 `sunxi_mbus.c` / `sunxi_sram.c`，**无 PPU 驱动** |
| `walnutpi1b_defconfig` | **无任何 PPU 配置项** |
| `sun50i-h616.dtsi` | **无 `prcm_ppu` 节点** |
| GPU 节点 | **无 `power-domains`** |

→ GPU 电源域从未上电 → `panfrost_gpu_soft_reset()` 写复位命令后硬件无响应 → 无限轮询卡死。

### 2. 厂商把 `mali-supply` 接到了错误的 regulator

```dts
/* 厂商原版（错误） */
&gpu { mali-supply = <&reg_dcdc3>; };

reg_dcdc1: dcdc1 { regulator-name = "vdd-gpu-sys"; ... };  ← 真正的 GPU 电源
reg_dcdc3: dcdc3 { regulator-name = "vdd-dram";            ← DRAM 电源
                   regulator-min-microvolt = <1300000>;
                   regulator-max-microvolt = <1300000>; }; ← 固定 1.3V
```

`dcdc3` 是固定 1.3 V 的 DRAM 供电，不是 GPU 供电。

### 3. DT overlay 里硬编码 phandle

原 overlay 写 `mali-supply = <0x9e>`。每次重新编译 DTB 后 phandle 编号都会变（实测 dcdc1 在三个版本里分别是 `0x9e` → `0x9f` → `0x0d`），一旦对不上就指向无关节点，`devm_regulator_bulk_get()` 失败并静默返回 `-EPROBE_DEFER`，**probe 日志里看不到任何错误**。

## 修复内容

### ① 应用 PPU 驱动

`sun50i-h6-prcm-ppu-6.1.c` 是主线 `drivers/pmdomain/sunxi/sun50i-h6-prcm-ppu.c`（Arm Ltd. 2024, GPL-2.0）的 6.1 适配版，改动 4 处：

| 主线写法（6.10+） | 6.1 写法 |
|---|---|
| `devm_kzalloc_objs(dev, *pds, n)` | `devm_kcalloc(dev, n, sizeof(*pds), GFP_KERNEL)` |
| `devm_kzalloc_obj(dev, *ppu)` | `devm_kzalloc(dev, sizeof(*ppu), GFP_KERNEL)` |
| `devm_kzalloc_objs(dev, *ppu->domains, n)` | `devm_kcalloc(dev, n, sizeof(*ppu->domains), GFP_KERNEL)` |
| 缺 include | 补 `#include <linux/of_device.h>`、`<linux/slab.h>` |

放置到 `drivers/soc/sunxi/`：

```bash
cp sun50i-h6-prcm-ppu-6.1.c  drivers/soc/sunxi/sun50i-h6-prcm-ppu.c

# Kconfig 追加
cat >> drivers/soc/sunxi/Kconfig <<'EOF'

config SUN50I_H6_PRCM_PPU
	tristate "Allwinner H6/H616 PRCM power domain driver"
	depends on ARCH_SUNXI || COMPILE_TEST
	depends on PM
	select PM_GENERIC_DOMAINS
	help
	  Say y to enable the Allwinner H6/H616 PRCM power domain driver.
	  This is required to enable the Mali GPU in the H616 SoC, it is
	  optional for the H6.
EOF

# Makefile 追加
echo 'obj-$(CONFIG_SUN50I_H6_PRCM_PPU) += sun50i-h6-prcm-ppu.o' >> drivers/soc/sunxi/Makefile

# 启用配置
./scripts/config --enable SUN50I_H6_PRCM_PPU
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

依赖已满足：`CONFIG_PM_GENERIC_DOMAINS=y`、`CONFIG_PM_GENERIC_DOMAINS_OF=y`。

### ② 应用 DTS 补丁

```bash
cd <kernel>
patch -p1 < dtsi-prcm-ppu.patch        # 加 prcm_ppu 节点
patch -p1 < board-dts-gpu-fix.patch    # 修 GPU 供电 + 单档 OPP
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- allwinner/sun50i-h616-walnutpi-1b.dtb
```

### ③ overlay 必须移除 GPU 相关 fragment

原 `patches/dts/pmic-axp313a.dts` 的 `fragment@9`（定义 `gpu_opp_fixed`）和 `fragment@10`（设置 `mali-supply` / `operating-points-v2`）**必须删掉**，否则硬编码 phandle 会覆盖板级 dts 的正确设置。

现 overlay 保留 9 个 fragment：PMIC（compatible/dcdc2/dcdc1/dcdc3）、thermal（cpu/gpu/polling/临界温度）、HDMI（hvcc-supply）。

### ④ 移除 panfrost 黑名单

```bash
rm -f /etc/modprobe.d/blacklist-panfrost.conf
```

## 设计取舍

- **单档 OPP（432 MHz @ 0.9 V）而非 DVFS**：`dcdc1` 是 `vdd-gpu-sys`，与 SYS 共用。若启用多档 OPP，Panfrost 会按低频档要求 810 mV，把 SYS 电压一起压低导致系统不稳（v0.4 实测 VGPU 0.9→0.8 V 后无法启动）。因此固定 0.9 V 单档，先保证稳定，DVFS 留待后续单独攻关（涉及 CVE-2025-38041 的 PLL reparent 补丁回移）。
- **用 label 而非 phandle**：所有跨节点引用一律 `&reg_dcdc1` / `&prcm_ppu`，避免重编译后 phandle 漂移。

## 验证方法

```bash
# 1. PPU 驱动绑定
ls -l /sys/bus/platform/devices/7010250.power-controller/driver
#   → sun50i-h6-prcm-ppu

# 2. genpd 域（应有 PLL / ANA / GPU）
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -i gpu

# 3. GPU 设备
ls -l /dev/dri/
#   → card0(HDMI) card1(panfrost) renderD128(panfrost)

# 4. 驱动绑定
cat /sys/class/drm/card1/device/driver/../uevent | head -3

# 5. 硬件识别
dmesg | grep -E "mali-g31|Initialized panfrost"
#   → panfrost 1800000.gpu: mali-g31 id 0x7093 major 0x0 minor 0x0 status 0x0
#   → [drm] Initialized panfrost 1.2.0 20180908 for 1800000.gpu on minor 1
```

## 实测结果

```
/dev/dri:
  card0        sun4i-drm (HDMI)
  card1        panfrost
  renderD128   panfrost

开机 5.97 秒自动加载：
  panfrost 1800000.gpu: mali-g31 id 0x7093 major 0x0 minor 0x0 status 0x0
  panfrost 1800000.gpu: Features: L2:0x07100206 Tiler:0x00000209 MMU:0x00002821 AS:0xff JS:0x7
  panfrost 1800000.gpu: shader_present=0x1 l2_present=0x1
  [drm] Initialized panfrost 1.2.0 20180908 for 1800000.gpu on minor 1

runtime PM 正常：
  /devices/platform/soc/1800000.gpu   suspended
```

## 文件清单

| 文件 | 说明 |
|---|---|
| `sun50i-h6-prcm-ppu-6.1.c` | PPU 驱动 6.1 适配版（可直接替换进 `drivers/soc/sunxi/`） |
| `sun50i-h6-prcm-ppu.c` | 主线原始版本（参考用，未改动） |
| `dtsi-prcm-ppu.patch` | `sun50i-h616.dtsi` 增加 `prcm_ppu` 节点 |
| `board-dts-gpu-fix.patch` | 板级 dts：`mali-supply` → dcdc1、单档 OPP、`power-domains` |
