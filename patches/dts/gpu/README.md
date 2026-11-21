# GPU (Mali-G31 / Panfrost) patch set

Fixes the GPU support in the WalnutPi ZeroW vendor kernel 6.1.31 (H618 / H616 family).

## Symptom

`modprobe panfrost` hangs forever. The last serial output is:

```
panfrost 1800000.gpu: clock rate = 432000000
panfrost 1800000.gpu: bus_clock rate = 200000000
(hang — no error, no panic, no further output)
```

## Root causes — three defects stacked on top of each other

### 1. The vendor deleted the PPU driver (primary cause)

On H616 the GPU is powered through the **PRCM PPU** (Power Processing Unit, `0x07010250`),
with the GPU on **domain 2**.

Mainline `Kconfig` states this explicitly:

```
config SUN50I_H6_PRCM_PPU
	help
	  Say y to enable the Allwinner H6/H616 PRCM power domain driver.
	  This is required to enable the Mali GPU in the H616 SoC, it is
	  optional for the H6.
```

The vendor kernel has none of it:

| Location | State |
|---|---|
| `drivers/soc/sunxi/` | Only `sunxi_mbus.c` / `sunxi_sram.c` — **no PPU driver** |
| `walnutpi1b_defconfig` | **No PPU config option** |
| `sun50i-h616.dtsi` | **No `prcm_ppu` node** |
| GPU node | **No `power-domains`** |

→ The GPU power domain is never powered on → `panfrost_gpu_soft_reset()` writes a
reset command and polls forever for hardware that has no power → hang.

### 2. `mali-supply` points at the wrong regulator

```dts
/* vendor (wrong) */
&gpu { mali-supply = <&reg_dcdc3>; };

reg_dcdc1: dcdc1 { regulator-name = "vdd-gpu-sys"; ... };  /* ← the real GPU rail */
reg_dcdc3: dcdc3 { regulator-name = "vdd-dram";            /* DRAM rail */
                   regulator-min-microvolt = <1300000>;
                   regulator-max-microvolt = <1300000>; };  /* fixed 1.3 V */
```

### 3. The DT overlay used a hardcoded phandle

The overlay wrote `mali-supply = <0x9e>`. Phandle numbers change on every DTB rebuild
(observed: `0x9e` → `0x9f` → `0x0d` across three builds). When it drifts it points at an
unrelated node, `devm_regulator_bulk_get()` fails, and the driver silently returns
`-EPROBE_DEFER` — **with no error in the log at all**.

## Fix

### ① Apply the PPU driver

`../../kernel/ppu/sun50i-h6-prcm-ppu-6.1.c` is the mainline
`drivers/pmdomain/sunxi/sun50i-h6-prcm-ppu.c` (Arm Ltd. 2024, GPL-2.0) adapted to 6.1.
The unmodified mainline copy is kept next to it as `sun50i-h6-prcm-ppu.c`, for reference.
Four changes:

| Mainline (6.10+) | 6.1 equivalent |
|---|---|
| `devm_kzalloc_objs(dev, *pds, n)` | `devm_kcalloc(dev, n, sizeof(*pds), GFP_KERNEL)` |
| `devm_kzalloc_obj(dev, *ppu)` | `devm_kzalloc(dev, sizeof(*ppu), GFP_KERNEL)` |
| `devm_kzalloc_objs(dev, *ppu->domains, n)` | `devm_kcalloc(dev, n, sizeof(*ppu->domains), GFP_KERNEL)` |
| missing includes | add `<linux/of_device.h>`, `<linux/slab.h>` |

Install into `drivers/soc/sunxi/` — run from the kernel tree root, with `<repo>` being
a checkout of this repository:

```bash
cp <repo>/patches/kernel/ppu/sun50i-h6-prcm-ppu-6.1.c  drivers/soc/sunxi/sun50i-h6-prcm-ppu.c

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

echo 'obj-$(CONFIG_SUN50I_H6_PRCM_PPU) += sun50i-h6-prcm-ppu.o' >> drivers/soc/sunxi/Makefile

./scripts/config --enable SUN50I_H6_PRCM_PPU
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

Requirements already satisfied: `CONFIG_PM_GENERIC_DOMAINS=y`, `CONFIG_PM_GENERIC_DOMAINS_OF=y`.

> **Note:** the full patch set (`../../kernel/alpindroid-kernel.patch`) does all of the above in one go —
> `scripts/setup-kernel.sh` applies it automatically.

### ② Apply the DTS patches

```bash
cd <kernel>
patch -p1 < <repo>/patches/dts/gpu/dtsi-prcm-ppu.patch        # adds the prcm_ppu node
patch -p1 < <repo>/patches/dts/gpu/board-dts-gpu-fix.patch    # GPU rail + single OPP + power-domains
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- allwinner/sun50i-h616-walnutpi-1b.dtb
```

### ③ Remove GPU fragments from the overlay

`fragment@9` (defined `gpu_opp_fixed`) and `fragment@10` (`mali-supply` /
`operating-points-v2`) **must be removed** from `patches/dts/pmic-axp313a.dts` —
their hardcoded phandles would otherwise override the correct board-DTS settings.

The remaining 8 fragments cover: PMIC (`compatible` / `dcdc2` / `dcdc1` / `dcdc3`),
thermal (cpu/gpu/polling/critical temperature), HDMI (`hvcc-supply`).

### ④ Remove the panfrost blacklist

```bash
rm -f /etc/modprobe.d/blacklist-panfrost.conf
```

### ⑤ Fix `resume` — the fourth defect

Probing works, the DRM device registers, and idle operation is fine — but **any actual
use of the GPU hard-hangs the bus** (no printk at all, requires a power cycle).

Comparing against mainline `panfrost_device_runtime_resume()` shows why:

```c
/* mainline */
if (pfdev->comp->pm_features & BIT(GPU_PM_RT)) {
    ret = reset_control_deassert(pfdev->rstc);   /* ① release reset */
    ret = panfrost_clks_enable(pfdev, true);     /* ② re-enable clocks */
}
panfrost_device_reset(pfdev, true);
panfrost_devfreq_resume(pfdev);

/* vendor — ①② both missing */
panfrost_device_reset(pfdev);      /* touches registers while in reset / clockless */
panfrost_devfreq_resume(pfdev);
```

`pm_features` / `GPU_PM_RT` do not exist in this tree, but the vendor calls
`pm_runtime_enable()` unconditionally, so the runtime-PM path is live and the
missing steps apply.

Fix (`../../kernel/panfrost-resume-fix.patch`, or run `../../kernel/fix_panfrost_pmrt.py`):

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

Make `suspend` symmetric (`clk_disable_unprepare` x2 + `reset_control_assert`).

## Design trade-offs

- **Single OPP (432 MHz @ 0.9 V) instead of DVFS.** `dcdc1` is `vdd-gpu-sys`, shared with
  the system rail. A multi-point OPP table makes Panfrost request 810 mV at the lowest
  frequency, which browns out the board (measured in v0.4: VGPU 0.9 → 0.8 V, no boot).
  Lifting this needs the PLL reparent backport for CVE-2025-38041.
- **Labels instead of phandles.** Every cross-node reference uses `&reg_dcdc1` /
  `&prcm_ppu`. Never `0x..`.

## Verification

```bash
# 1. PPU driver bound
ls -l /sys/bus/platform/devices/7010250.power-controller/driver
#   → sun50i-h6-prcm-ppu

# 2. genpd domains present (expect PLL / ANA / GPU)
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -i gpu

# 3. GPU devices
ls -l /dev/dri/
#   → card0 (HDMI) card1 (panfrost) renderD128 (panfrost)

# 4. Hardware identified
dmesg | grep -E "mali-g31|Initialized panfrost"
#   → panfrost 1800000.gpu: mali-g31 id 0x7093 major 0x0 minor 0x0 status 0x0
#   → [drm] Initialized panfrost 1.2.0 20180908 for 1800000.gpu on minor 1
```

## Measured results

```
/dev/dri:
  card0        sun4i-drm (HDMI)
  card1        panfrost
  renderD128   panfrost

Auto-loads 5.97 s after boot:
  panfrost 1800000.gpu: mali-g31 id 0x7093 major 0x0 minor 0x0 status 0x0
  panfrost 1800000.gpu: Features: L2:0x07100206 Tiler:0x00000209 MMU:0x00002821 AS:0xff JS:0x7
  panfrost 1800000.gpu: shader_present=0x1 l2_present=0x1
  [drm] Initialized panfrost 1.2.0 20180908 for 1800000.gpu on minor 1

Runtime PM works:
  /devices/platform/soc/1800000.gpu   suspended

Rendering (scripts/gpu_render_test.c):
  GL_RENDERER   : Mali-G31 (Panfrost)
  GL_VERSION    : OpenGL ES 3.1 Mesa 25.2.7
  PIXEL center  : R=0 G=255 B=0 A=255
  RESULT        : PASS
```

## Files

| File | Description |
|---|---|
| `../../kernel/alpindroid-kernel.patch` | **Complete kernel diff** — includes all of the above; this is the recommended way |
| `../../kernel/ppu/sun50i-h6-prcm-ppu-6.1.c` | Standalone PPU driver, adapted to the 6.1 API |
| `../../kernel/ppu/sun50i-h6-prcm-ppu.c` | Unmodified mainline PPU driver, kept for reference |
| `dtsi-prcm-ppu.patch` | Adds the `prcm_ppu` node to `sun50i-h616.dtsi` |
| `board-dts-gpu-fix.patch` | Board DTS: GPU rail, single OPP, `power-domains` |
| `../../kernel/panfrost-resume-fix.patch` | The `resume` fix |
| `../../kernel/fix_panfrost_pmrt.py` | Applies the `resume` fix idempotently |
