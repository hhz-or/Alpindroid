# Alpindroid Changelog — from official Debian 12 to v0.18

Baseline: `walnutpi/walnutpi-1` v2.6.0 official image
`2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img`
(2,897,215,488 bytes, SHA256 `ece049da8889146a37ccc8a1daa29fe023f903cc5ec2b44aa34513c37d7c9d34`)

Current product: `Alpindroid-ZeroW-v0.18.img`
(SHA256 `79a83716919a6fa12fa516727f9cd9ef425953d9de0d2b5e4a5377dc197abbb5`)

---

## 1. Image architecture

### 1.1 Boot partition (p1) — 4 of 24 files changed (3 modified + 1 new)

| File | Change |
|---|---|
| `config.txt` | `console_uart=uart0`→`uart2`; `printk_level=3`→`7`; `overlays=` gains `pmic-axp313a`; `rootdev=PARTUUID=<new>-02` |
| `Image` | Our 6.1.31+ build (22,601,736 bytes) |
| `sun50i-h616-walnutpi-1b.dtb` | Rebuilt with DTS changes (40,524 bytes) |
| `overlays/sun50i-h616-pmic-axp313a.dtbo` | New (1,153 bytes, 8 fragments) |

The other 20 files are byte-identical, including `boot.bin`, `boot.scr`, `initrd.img-6.1.31`,
`uInitrd`, `config-6.1.31`, `-emmc.dtb`, and the 12 vendor overlays.

**Core principle:** the vendor bootloader is never modified. It supports `fdt apply`
natively, and an overlay failure rolls back automatically — giving a one-line rollback
(delete ` pmic-axp313a` from `config.txt`).

### 1.2 Root partition (p2) — Debian 12 fully replaced

| | Debian 12 | Alpindroid |
|---|---|---|
| Init | systemd | OpenRC |
| Packages | apt | apk |
| libc | glibc 2.36 | musl 1.2.5 |
| Size | ≈1.1 GB | ≈90 MB (≈250 MB with Mesa) |

---

## 2. Version history

| Version | Key change | Result |
|---|---|---|
| v0.2 | Alpine + NetworkManager + udev | Boots; CPU stuck at one frequency, no HDMI |
| v0.2b | NM connection dir permissions 700 + uuid | — |
| v0.2c | busybox-extras / sudo / chrony / wireless-regdb | Stable base |
| v0.3-pm | First PMIC overlay (with GPU disabled) | FAIL — HDMI completely black |
| v0.4 | Five power changes + `mali-supply`→`dcdc1` | FAIL — no boot (VGPU 0.9→0.8 V) |
| v0.5 | Revert `mali-supply`, add `dcdc1` floor | Boots; cpufreq works; no HDMI |
| v0.6 | Fix HDMI `hvcc` + GPU OPP voltage | FAIL — hangs at udev coldplug |
| v0.7 | Remove GPU OPP changes | **All core features working** |
| v0.8-gpu | Redo GPU power (`dcdc1` + OPP 0.9 V) | FAIL — hangs at "Loading hardware drivers" |
| v0.9 | v0.8 + panfrost blacklist | Boots; GPU can be tested manually |
| **v0.10** | v0.9 + `util-linux-login` + getty `-L` | **Local terminal login works** (needs full-speed keyboard) |
| v0.11 | Single GPU OPP (432 MHz fixed) | FAIL — panfrost still hangs |
| v0.12 | Rebuild kernel: align Panfrost init order with mainline | FAIL — still hangs after `bus_clock rate` |
| v0.13 | Rebuild kernel: disable GPU DVFS entirely | FAIL — narrowed to `panfrost_gpu_init` |
| **v0.14** | **Backport PPU driver + fix GPU rail in DTS** | GPU driver chain works |
| v0.15 | Fix leftover overlay phandle + `config.txt` | No WiFi (hit the `/lib/modules` defect) |
| **v0.16** | **Fix `/lib/modules` layout, bake build into one script** | **WiFi + GPU drivers load** |
| **v0.17** | **Add `reset_control_deassert` + `clk_prepare_enable` to `resume`** | **GPU renders for real (Mali-G31)** |
| **v0.18** | **Bake Mesa / cgroup2 / GPU tests into the image** | **Stable baseline, works out of the box** |

---

## 3. Defect 1 — the vendor deleted the PPU driver

### 3.1 Evidence

| Location | State |
|---|---|
| `drivers/soc/sunxi/` | Only `sunxi_mbus.c` / `sunxi_sram.c` — **no PPU driver** |
| `walnutpi1b_defconfig` | No PPU config option |
| `sun50i-h616.dtsi` | No `prcm_ppu` node |
| GPU node | No `power-domains` |

Mainline `Kconfig` is explicit: *"This is required to enable the Mali GPU in the H616 SoC,
it is optional for the H6."*

### 3.2 Fix

Backport `drivers/pmdomain/sunxi/sun50i-h6-prcm-ppu.c` (Arm Ltd. 2024), adapting four
API differences for 6.1:

| Mainline (6.10+) | 6.1 |
|---|---|
| `devm_kzalloc_objs(dev, *pds, n)` | `devm_kcalloc(dev, n, sizeof(*pds), GFP_KERNEL)` |
| `devm_kzalloc_obj(dev, *ppu)` | `devm_kzalloc(dev, sizeof(*ppu), GFP_KERNEL)` |
| `devm_kzalloc_objs(dev, *ppu->domains, n)` | `devm_kcalloc(dev, n, sizeof(*ppu->domains), GFP_KERNEL)` |
| — | add `#include <linux/of_device.h>`, `<linux/slab.h>` |

Plus a `prcm_ppu` node in the DTSI and `power-domains = <&prcm_ppu 2>` on the GPU.

---

## 4. Defect 2 — `mali-supply` on the wrong rail

```dts
reg_dcdc1: dcdc1 { regulator-name = "vdd-gpu-sys"; min=810000; max=1160000; };
reg_dcdc3: dcdc3 { regulator-name = "vdd-dram";    min=max=1300000; };  /* DRAM, fixed */

&gpu { mali-supply = <&reg_dcdc3>; };  /* vendor: wrong rail */
```

`dcdc3` is the DRAM rail at a fixed 1.3 V. The GPU rail is `dcdc1` (`vdd-gpu-sys`).

Because `dcdc1` is shared with the system rail, the OPP table must be a single point
(432 MHz @ 0.9 V) — a multi-point table would request 810 mV and brown out the board
(measured in v0.4).

---

## 5. Defect 3 — overlay used hardcoded phandles

The overlay wrote `hvcc-supply = <0x22>` for HDMI. Phandles are renumbered on every
DTB rebuild; measured drift across three builds: `0x22` pointed at `vcc-wifi-io`,
then at `vcc33-wifi`.

Result: **HDMI was managing the WiFi 3.3 V supply as its own IO rail**, corrupting the
WiFi power-up sequence → no SDIO device → no `wlan0`.

Fix: do it in the board DTS with a label, and drop the fragment from the overlay.

```dts
&hdmi { hvcc-supply = <&reg_vcc_wifi_io>; };
```

**Rule:** never write `<0x..>` in a DT overlay. Always use labels.

---

## 6. Defect 4 — `/lib/modules` missing the version directory

Every module failed to load (no WiFi, no BT, no GPU), yet the system still booted —
because the core drivers are built in. Highly misleading.

Cause, one bad `cp`:

```sh
rm -rf "$ROOT/lib/modules"
cp -a /tmp/newmods/lib/modules/6.1.31+ "$ROOT/lib/modules/"   # WRONG
```

After `rm -rf`, `/lib/modules` no longer exists, so GNU `cp -a src dst/` creates `dst`
**as a copy of src** — swallowing the `6.1.31+` level. Result:

```
/lib/modules/kernel/...        ← actual
/lib/modules/modules.dep
```

But `uname -r` is `6.1.31+`, so `modprobe` only looks in `/lib/modules/6.1.31+/` —
which does not exist.

**Fix** (`scripts/replace-modules.sh`):

```sh
rm -rf "$ROOT/lib/modules"
mkdir -p "$ROOT/lib/modules/6.1.31+"
cp -a /tmp/newmods/lib/modules/6.1.31+/. "$ROOT/lib/modules/6.1.31+/"
```

The `src/.` form copies the *contents*, not the directory itself.

**Related trap:** the vendor base image uses `6.1.31` (no `+`), our kernel is `6.1.31+`.
`scripts/build-image.sh` now accepts both.

**Verify all three levels, not just "the file exists":**

```sh
ls -d /lib/modules/*/                                    # ① version directory
ls /lib/modules/$(uname -r)/modules.dep                  # ② dep database inside it
find /lib/modules/$(uname -r) -name '*.ko' | wc -l       # ③ module count
```

`find /lib/modules -name xxx.ko` succeeds even with the wrong layout — which is exactly
why this bug hid for two releases.

---

## 7. Defect 5 — `resume` missing reset deassert and clock enable

The hardest one. Probe succeeds, the DRM device registers, idle is stable — but **any
actual GPU use hard-hangs the bus**: no printk, no panic, power cycle required.

### 7.1 Ruling things out

| Observation | Inference |
|---|---|
| Probe reads `mali-g31 id 0x7093` | Hardware, clocks, power, MMU init all fine |
| Autosuspend after ~50 ms, `GPU off-0` | Device suspends |
| Any later GPU access (`eglinfo`, `echo on > power/control`, `rmmod panfrost`) → silent hard hang | Bus-level lockup |
| PPU register reads `0x1`; forcing it to `0x0` and touching the GPU also hangs | **Polarity is not the cause** |

### 7.2 Root cause

```c
/* mainline panfrost_device_runtime_resume() */
if (pfdev->comp->pm_features & BIT(GPU_PM_RT)) {
    ret = reset_control_deassert(pfdev->rstc);   /* ① release reset */
    ret = panfrost_clks_enable(pfdev, true);     /* ② re-enable clocks */
}
panfrost_device_reset(pfdev, true);
panfrost_devfreq_resume(pfdev);

/* vendor — both steps missing */
panfrost_device_reset(pfdev);      /* touches registers in reset, clockless */
panfrost_devfreq_resume(pfdev);
```

### 7.3 Fix

Apply `patches/kernel/panfrost-resume-fix.patch` (or run
`patches/kernel/fix_panfrost_pmrt.py`), and make `suspend` symmetric.

### 7.4 Verification

```
# The previously fatal operation now completes instantly
echo on > /sys/devices/platform/soc/1800000.gpu/power/control
  rc=0
  runtime_status: active

# Real rendering
GL_RENDERER   : Mali-G31 (Panfrost)
GL_VERSION    : OpenGL ES 3.1 Mesa 25.2.7
PIXEL center  : R=0 G=255 B=0 A=255
RESULT        : PASS
```

---

## 8. Debugging methodology

### 8.1 Serial console is mandatory

Three rounds of blind experimentation (init reordering, disabling DVFS, fixed OPP) all
failed, because the only visible symptom was "the last line is `bus_clock rate`".

**ZeroW has two UARTs:**

| Port | Pins | Where |
|---|---|---|
| UART0 | PH0 (TX) / PH1 (RX) | FPC connector (needs an adapter board) |
| UART2 | PI5 (TX) / PI6 (RX) | 40-pin header |

For UART2 set `console_uart=uart2` in `config.txt`.

Wiring: `PI5 → USB-TTL RX`, `PI6 → USB-TTL TX`, `GND → GND`, **VCC unconnected** (3.3 V logic).

`scripts/serial-capture.ps1` automates capture on Windows (auto-detects the COM port,
keeps DTR/RTS low so the board is not reset).

### 8.2 Step markers

Inserting `pr_info("Alpindroid-STEP: ...")` before each init step resolved it in one shot:

```
pm_domain_init -> reset_init -> clk_init -> devfreq_init
-> regulator_init -> ioremap -> gpu_init     ← hung here, three times in a row
```

This ruled out clocks, voltage and DVFS, and pointed at hardware power instead.

### 8.3 Proving the GPU actually works

`eglinfo` succeeding only proves the EGL path initialises. Real proof requires
shader compilation, a draw call, and reading pixels back:

```c
glClear / glDrawArrays / glReadPixels -> expect (0,255,0,255)
```

`scripts/gpu_render_test.c` does exactly this. **`GL_RENDERER`** distinguishes hardware
from software: `Mali-G31 (Panfrost)` = hardware, `llvmpipe`/`softpipe` = CPU.

---

## 9. GPU stability regression (v0.18 acceptance)

Single-frame success is not stability. Four test classes:

| Test | Method | Result |
|---|---|---|
| **A Sustained rendering** | One EGL context, 10,000 frames, sampled pixel readback | PASS — 2 s, `bad=0` (≈5000 FPS at 256×256) |
| **B Context churn** | Create/destroy EGL context 100 times | PASS — 16 s, `fails=0` |
| **C Runtime PM** | Drop resources, let it autosuspend, render again, 100 rounds | PASS — **100/100, `SAW_SUSPENDED=100`** |
| **D Sustained load** | Temperature and stability | PASS — 51→68 °C, no hang, zero GPU errors in dmesg |

### Runtime PM evidence

```
Before: active=0         suspended=90,786 ms
After:  active=24,625    suspended=1,118,309 ms

The whole run took 18 s, but the GPU accumulated only +13.1 s of active time.
→ it suspends right after each frame and resumes on the next access.
→ reset_control_deassert + clk_prepare_enable executed 200+ times, all successful.
```

**Pitfall:** `power/control` must be `auto`. If it is `on`, the device never suspends and
you are not testing the resume path at all. And 100 PASS lines alone prove nothing —
you must observe `runtime_status=suspended` *and* see the counters grow.

---

## 10. User-space and tooling notes

| Item | Detail |
|---|---|
| Alpine mirror | Official CDN is unusably slow from CN (apk update stalled 20 min). Use `https://mirrors.aliyun.com/alpine/v3.23/{main,community}` |
| Mesa | `apk add mesa mesa-dri-gallium mesa-gbm mesa-egl mesa-gles mesa-gl mesa-utils libdrm-tests` → 25.2.7, 184 packages, 288 MiB |
| Build tools | `apk add gcc musl-dev mesa-dev` → 226 packages, 688 MiB |
| Device permissions | `card1` is `crw-rw---- root:video` (add user to `video`); `renderD128` is `crw-rw-rw-` |
| `sysctl` service | Must be in the boot runlevel, otherwise `/etc/sysctl.d/*.conf` is ignored and `printk` stays at 1 |
| chrony | Vendor config points at `ntp.aliyun.com`, which does **not** exist (NXDOMAIN). Use `ntp1.aliyun.com` |
| Board clock | No RTC battery — the clock resets to 1970 on every power cycle, which breaks apk TLS. Fix with `date -s` or let chrony sync |
| `resize2fs` | Lives in `e2fsprogs-extra`, not `e2fsprogs` |
| `devmem` | Not in Alpine busybox; install `devmem2` |
| Root expand | `apk add cloud-utils-growpart e2fsprogs-extra` → `growpart /dev/mmcblk1 2` → `resize2fs /dev/mmcblk1p2` (measured 2.4 GB → 117 GB) |

---

## 11. Rollback

| Scenario | Action |
|---|---|
| Single-boot rollback | Edit `config.txt` on the boot partition and drop ` pmic-axp313a` from `overlays=` |
| Full rollback | Flash `v0.2c` (`7904e30c…`) or the official image |
| Disable GPU | Re-create `/etc/modprobe.d/blacklist-panfrost.conf` |
| GPU hangs again | Revert to the v0.13 kernel (`88e6f13a…`), or remove the `power-domains` line from the board DTS and rebuild |

---

## 12. Known limitations

| Item | Notes |
|---|---|
| GPU DVFS | Fixed single OPP 432 MHz @ 0.9 V. Enabling DVFS needs the CVE-2025-38041 PLL reparent backport |
| Clock persistence | No RTC battery; chrony syncs after boot |
| Waydroid | Kernel prerequisites met (BinderFS + cgroup2 + namespaces); userspace not yet installed |
| Graphics stack | No Wayland compositor yet — v0.19 target |

---

## 13. Reproducing the build

```bash
# 1. Kernel source + patches
sh scripts/setup-kernel.sh

# 2. Build
cd build/linux-6.1.31
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=/tmp/newmods modules_install

# 3. Image (15 automated checks, aborts on failure)
cd ../..
sudo sh scripts/build-alpindroid.sh v0.19 /tmp/newmods/lib/modules/6.1.31+

# 4. On the board
/usr/local/bin/gpu_render_test      # expects RESULT: PASS
```

Full build time: ~25 minutes for the kernel on 8 cores, ~3 minutes for the image.
---

## 14. v0.19 bring-up — Wayland + generic touch (in progress)

Nothing in the v0.18 kernel changed. Weston 14.0.2, seatd and libinput are plain
Alpine 3.23 aarch64 packages running against the existing sun4i-drm + Panfrost
stack.

### 14.1 Session layer

`seatd` 0.9.1 with `libseat`: socket `/run/seatd.sock` owned by `root:seat`, the
desktop user added to `seat`, `LIBSEAT_BACKEND=seatd`. Weston therefore runs as
an unprivileged user — DRM master and input access are handed over by seatd, no
`chmod 777 /dev/dri` and no root-owned compositor.

### 14.2 Output and renderer

```
using /dev/dri/card0                        sun4i-drm, atomic modesetting
Using rendering device: /dev/dri/renderD128
GL renderer: Mali-G31 (Panfrost)            OpenGL ES 3.1 Mesa 25.2.7
Output 'HDMI-A-1' enabled                   1024x600@60.1, preferred
```

`card1` / `renderD128` is render-only; every scanout goes through `card0`. The
panel reports 1024x600 via EDID (`PNP(LTM) LONTIUM`), so `mode=preferred` is used
instead of forcing a mode the panel cannot lock. EDID has a malformed CTA-861
extension block; the driver logs a conformity warning and continues.

### 14.3 Touch is a generic HID device

The panel is not a vendor char device. USB identity `222a:0001`
("OpenWare Multi-Touch-V5000"), three HID interfaces:

| Interface | Driver | Node | libinput role |
|---|---|---|---|
| input0 | `hid-multitouch` | `event3` (input6) | touchscreen, `PROP=2` (DIRECT), `ABS=2608…003` (MT-B slot + X + Y), 10 points |
| input1 | `hid-generic` | `event4` | keyboard |
| input2 | `hid-generic` | `event5` | pointer |

`CONFIG_HID_MULTITOUCH=m` was already in our config, so the standard in-kernel
multi-touch path was available all along — only the user-space side was missing.
`hid_multitouch` is also listed in `/etc/modules` so it does not depend on udev
winning the coldplug race with the compositor.

### 14.4 Binding touch to the head

Weston associates an input device with the first enabled output unless udev says
otherwise, which is why the first session logged
`input device event3 has no enabled output associated`. `config/udev/99-alpindroid-touch.rules`
sets `WL_OUTPUT=HDMI-A-1` on every `ID_INPUT_TOUCHSCREEN=1` device, so the mapping
no longer depends on bring-up order and keeps working with a second head.

### 14.5 Acceptance

`scripts/wayland-check.sh` performs 21 checks — connector state and modeset, GL
renderer identity, `renderD128` usage, absence of llvmpipe/softpipe, seatd
session grant, `hid_multitouch` presence, MT-B abs capabilities,
`INPUT_PROP_DIRECT`, `WL_OUTPUT`, plus optional EGL and dmabuf clients:

```
PASS 21   FAIL 0
RESULT: PASS
```

Not done yet: touch coordinate verification with a real finger (and
`weston-touch-calibrator` if the panel needs a matrix), autostart service, and
baking the stack into a v0.19 image. v0.18 remains the frozen baseline.
### 14.6 Touch bring-up status (open)

The touch controller initialises but never reports, and everything below is
measured, not guessed:

| Layer | Result |
|---|---|
| USB enumeration | OK — `222a:0001`, three HID interfaces, full-speed on the OHCI controller |
| HID report descriptor | OK — `Usage Page Digitizer / Usage Touch Screen`, Report ID `0x15`, MT-B contacts, X 0..1920 / Y 0..1080 |
| Driver binding | OK — `hid-multitouch` on interface 0, `INPUT_PROP_DIRECT`, 10 points |
| udev + output binding | OK — `ID_INPUT_TOUCHSCREEN=1`, `WL_OUTPUT=HDMI-A-1` (our rule is picked up: `associating input device event3 with output HDMI-A-1 (HDMI-A-1 by udev)`) |
| evdev (`/dev/input/eventN`) | **no events** |
| HID core (`/sys/kernel/debug/hid/*/events`) | **no events** |
| raw reports (`/dev/hidraw0/1/2`) | **no data** |
| OHCI interrupt counter while touching | **unchanged** |
| Vendor kernel config (extracted from the image) | identical for `CONFIG_HID_MULTITOUCH`, `CONFIG_TOUCHSCREEN_USB_COMPOSITE`, `CONFIG_HID_GENERIC`, `CONFIG_USB_HID` |
| Board DTB vs vendor DTB | identical for all USB/PHY nodes (only phandle renumbering from our added `prcm_ppu`) |
| Vendor rootfs | no device-specific udev rule or libinput quirk (full-image scan for `222a:0001` / `Multi-Touch-V5000` / `OpenWare` = 0 hits); only generic `xorg` + `xserver-xorg-input-evdev` |

Observations worth keeping:

* cold boot logs `usb 5-1: reset full-speed USB device number 2 using ohci-platform`
  ~6 s *after* `hid-multitouch` binds, and nothing re-probes afterwards;
* enumeration always goes `hid-generic` first, then `hid-multitouch` rebinds
  interface 0 a few seconds later;
* forcing a re-enumeration (`authorized 0 → 1`) or `unbind/bind` re-creates the
  device and the input nodes, but still no reports.

Consequence for this repository: `install-wayland-stack.sh` deliberately does
**not** add `hid_multitouch` to `/etc/modules` any more (that defers the load and
forces the rebind, which the vendor image never does). `scripts/touch-diag.sh`
prints the whole chain above and, with `--live`, whether raw events arrive at
all — it runs unchanged on the vendor Debian 12 image so the two can be compared.

### 14.7 Vendor A/B on the same board, same panel, same cable

Flashed the vendor `2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img`
(kernel `6.1.31 #98`, SSH `pi@`, no desktop at all — no Xorg, no
display-manager) and measured the same way:

```
[ 2.920209] hid-generic 0003:222A:0001.0001: input,hidraw0 ... input0
[ 2.985138] hid-generic 0003:222A:0001.0002: input,hidraw1 ... Keyboard
[ 2.990922] hid-generic 0003:222A:0001.0003: input,hidraw2 ... Mouse
[ 5.500304] hid-multitouch 0003:222A:0001.0001: input,hidraw0 ... input0
[13.300939] usb 7-1: reset full-speed USB device number 2 using ohci-platform
```

So the vendor image shows the *same* `hid-generic` → `hid-multitouch` rebind and
the *same* `usb reset` a few seconds later — both are normal for this device and
were wrongly suspected earlier.

Touching the panel on the vendor image produces nothing either:

| Probe on the vendor image | Result |
|---|---|
| `dd if=/dev/input/event0` (node with `PROP=2`) | blocks, 0 bytes |
| `ohci_hcd:usb7` interrupt counter | 110 → 110 |
| `/sys/kernel/debug/hid` | not available in that kernel config |

**Conclusion:** the controller does not report on either OS. This is not an
Alpindroid configuration problem — kernel config, board DTB and rootfs were
compared, and the runtime behaviour matches the vendor image. The remaining
candidates are on the panel/controller side: touch FPC seating, the controller's
power rail, or firmware initialisation that only the vendor tooling performs
(the published `walnutpi-build` has no touch handling beyond generic
`xorg` + `xserver-xorg-input-evdev`).

Touch is therefore **not** part of the v0.19 acceptance yet: HDMI output, GPU
rendering and pointer input work, the touchscreen path is wired but silent.