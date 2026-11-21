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
### 14.6 Touch bring-up (verified working)

Every layer checks out and the panel reports real MT-B touch events:

| Layer | Result |
|---|---|
| USB enumeration | OK — `222a:0001`, three HID interfaces, full-speed on the OHCI controller |
| HID report descriptor | OK — `Usage Page Digitizer / Usage Touch Screen`, Report ID `0x15`, MT-B contacts, X 0..1920 / Y 0..1080 |
| Driver binding | OK — `hid-multitouch` on interface 0, `INPUT_PROP_DIRECT`, 10 points |
| udev + output binding | OK — `ID_INPUT_TOUCHSCREEN=1`, `WL_OUTPUT=HDMI-A-1`; Weston logs `associating input device event1 with output HDMI-A-1 (HDMI-A-1 by udev)` |
| evdev events | **OK — 6768 bytes / 282 events** captured from the `PROP=2` node |
| Weston desktop | **OK — the pointer follows the finger, coordinates land under the finger, `weston-terminal` is usable** |

Decoded sample (24-byte `input_event` records):

```
EV_ABS ABS_MT_SLOT       = 0
EV_ABS ABS_MT_POSITION_X = 693
EV_ABS ABS_MT_POSITION_Y = 433
EV_KEY BTN_TOUCH         = 1        (finger down)
EV_ABS ABS_X             = 693
EV_ABS ABS_Y             = 433
EV_SYN SYN_REPORT        = 0
```

The panel reports in a 1920x1080 coordinate space while the head runs 1024x600;
libinput scales it automatically and the measured result needs no calibration
matrix.

Normal behaviour worth knowing (all of it was wrongly suspected at first):

* enumeration goes `hid-generic` first, then `hid-multitouch` rebinds interface 0
  a few seconds later;
* cold boot logs `usb 5-1: reset full-speed USB device number 2 using
  ohci-platform` about 6 s after that rebind — the vendor image shows the exact
  same sequence, so neither is a defect;
* unplugging the touch USB cable makes `222a:0001` disappear from `lsusb`
  completely, which proves the enumerated device really is this panel's
  controller.

`install-wayland-stack.sh` deliberately does **not** add `hid_multitouch` to
`/etc/modules`: udev autoloads it from the USB modalias at enumeration time, and
deferring the load to the `modules` service only forces an extra rebind.

### 14.7 A false negative, and why it happened

Earlier rounds concluded "no touch events on either OS". That was wrong: the
fault was in the measurement, not in the hardware.

| Mistake | Effect |
|---|---|
| `dd if=/dev/input/eventN bs=24 count=1 \| od -An -tx1 > /tmp/log` | `od` buffers its output (4 KB); a few touches produce a few hundred bytes, so the file stayed at 0 bytes and looked like "no events" |
| sampling windows that did not overlap the actual touches | the capture had already timed out, or was started after the finger was lifted |
| treating the `ohci_hcd` interrupt counter as the primary signal | an idle interrupt endpoint NAKs without raising the host-controller interrupt count, so "no interrupt" does not prove "no touch" |

The fix, now used in `scripts/touch-diag.sh --live` and
`scripts/wayland-check.sh --touch`:

```sh
# unbuffered: the file size grows the moment a report arrives
dd if=/dev/input/eventN of=/tmp/cap.raw bs=24 count=2000
```

With that, the same panel produced 6768 bytes on the first attempt — on both
Alpindroid and the vendor image.

Two notes from the vendor A/B run:

* the vendor `debian12_server` image has no desktop at all (no Xorg, no
  display-manager, no `xinput`), so "touch works on the vendor image" is not
  reproducible there as-is;
* the vendor image shows the same `hid-generic` -> `hid-multitouch` rebind and
  the same `usb reset`; both are normal for this controller.

### 14.8 Adaptive resolution and touch scaling (v0.19)

Nothing in the stack is pinned to this particular 1024x600 panel:

| Risk of hard-coding | What the implementation does |
|---|---|
| Connector name | `scripts/wayland-adapt.sh` reads `cardN-<NAME>/status` from DRM sysfs, takes the first `connected` head, and rewrites **both** `/etc/udev/rules.d/99-alpindroid-touch.rules` (`ENV{WL_OUTPUT}="<head>"`) and `weston.ini`'s `[output] name`. It is installed to `/usr/local/sbin`, runs from `/etc/local.d/alpindroid-runtime.start` on every boot, and can be re-run by hand after swapping screens. With no connected head (e.g. inside a chroot while building an image) it removes the `WL_OUTPUT` rule instead of guessing, and Weston falls back to the first enabled output. |
| Panel resolution | `mode=preferred` everywhere — EDID decides. The measured head is 1024x600; the same config drives a 1080p monitor with no edit. |
| Touch coordinate range | The panel reports MT-B in 0..1920 / 0..1080; libinput scales that onto whatever the output is, so no `LIBINPUT_CALIBRATION_MATRIX` is baked in. Verified: `EV_ABS ABS_MT_POSITION_X/Y = 693/433` lands under the finger on the 1024x600 head. |
| Fonts / colours | `scripts/install-terminal-polish.sh` maps `monospace -> Source Code Pro` and `sans-serif -> Noto Sans` via `/etc/fonts/local.conf` (`prepend … strong`, because WenQuanYi also advertises monospace), adds CJK fallback, `LS_COLORS`, a coloured prompt for **both** ash and bash (bash needs `\[ \]`, busybox ash must not get them), `inputrc`, and a framebuffer console font. |

Boot-time evidence on the board:

```
wayland-adapt: connected head = HDMI-A-1
  wrote /etc/udev/rules.d/99-alpindroid-touch.rules (WL_OUTPUT=HDMI-A-1)
  updated [output] name in /etc/xdg/weston/weston.ini
  event1: WL_OUTPUT=HDMI-A-1

weston: Using config file '/etc/xdg/weston/weston.ini'
        GL renderer: Mali-G31 (Panfrost)
        associating input device event1 with output HDMI-A-1 (HDMI-A-1 by udev)
        Output 'HDMI-A-1' enabled with head(s) HDMI-A-1
wayland-check.sh -> PASS 19  FAIL 0
```

Baking it into the image (`scripts/build-alpindroid.sh`):

* new step `[5c]` runs `install-wayland-stack.sh` and `install-terminal-polish.sh`
  inside the rootfs chroot (`qemu-aarch64-static`, with `proc`/`sys`/`dev` and
  `resolv.conf` mounted), so a v0.19 image boots with the Wayland stack, the
  touch binding and the fonts already present — no post-boot `apk add`;
* 13 new checks were added to step `[6/6]` (weston + DRM + GL modules, seatd and
  its runlevel, libinput, `hid_multitouch.ko`, `weston.ini`, the adapter, the
  local.d boot hook, the colour profile and the fonts), so the builder now runs
  28 checks and still aborts on any failure;
* v0.18 is untouched: everything above lives in the user-space layer.

---

## 15. v0.20 bring-up — Waydroid (in progress)

Goal: Android (LineageOS 20 "VANILLA") in an LXC container on top of the v0.19
graphics stack. Everything below is measured on the board.

### 15.1 Disk

The stock image ships a 2.4 GB root partition inside a 119 GB card, and the
Android images need ~2.3 GB. Grown online, no reboot:

```sh
apk add cloud-utils-growpart e2fsprogs-extra
sfdisk -d /dev/mmcblk1 > /root/partition-backup.sfdisk
growpart /dev/mmcblk1 2      # 5363712 -> 249442271 sectors
resize2fs /dev/mmcblk1p2     # 2.4 G -> 117 G
```

### 15.2 Kernel: DMABUF_HEAPS is mandatory

The v0.18/v0.19 kernel (vendor defconfig) has `# CONFIG_DMABUF_HEAPS is not
set`, so `/dev/dma_heap` does not exist. Without it Android's allocator HAL
starts and immediately fails:

```
E android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa:
    Unsupported combination -- pixel format: RGBA_FP16, drm format:DRM_FOURCC_AB4H ...
E GraphicBufferAllocator: Failed to allocate (128 x 128) layerCount 1 format 22 usage 100: 7
E Gralloc4: AIDL IAllocator declared but failed to get service
```

Fix (`kernel/config/config-6.1.31-plus`, compiled on the build host):

```
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_PSI=y                 # silences libpsi / lmkd warnings
```

After flashing the rebuilt Image + modules: `uname -r` = `6.1.31` (the upstream
build sets `LOCALVERSION=` and touches `.scmversion`, so the `+` suffix is gone;
`/lib/modules/6.1.31` is the new path) and `/dev/dma_heap/{system,reserved}`
appear. With that, the allocator works — measured inside the container:

```
Allocated: 1024x568, stride: 4096        (the panel-sized buffer)
init.svc.vendor.graphics.allocator-4-0: running
init.svc.vendor.hwcomposer-2-1:         running
surfaceflinger:                          running
```

### 15.3 Container-side defects, all needed before Android stays up

| # | Symptom | Cause / fix |
|---|---|---|
| 1 | `lxc-start: Failed to mount "/run/user/1000/pulse/native"` → container aborts | Waydroid's generated LXC config bind-mounts a PulseAudio socket; a bare Alpine rootfs has none. Create an empty placeholder file (and recreate it on boot). |
| 2 | `init: createProcessGroup(NNN, ...) failed: Read-only file system`, `statsd`/`lmkd` die | `lxc.mount.auto = cgroup:ro`; Android must create per-uid cgroups → switch to `cgroup:mixed`. |
| 3 | `Gralloc4: ... failed to get service` even with DMABUF_HEAPS | Waydroid's LXC node list predates dma-buf heaps → add `lxc.mount.entry = /dev/dma_heap dev/dma_heap none bind,create=dir,optional 0 0`. |
| 4 | `bootstat: Failed to read /metadata/...` | Android 12+ needs a metadata mount → `/var/lib/waydroid/metadata` + bind mount. |
| 5 | `Failed to attach "vethXXX" to bridge "waydroid0"` | The bridge is only created by `waydroid-net.sh`; `rc-service waydroid-container restart` tears it down. Run `waydroid-net.sh start` right before the session, or do not restart the daemon. |
| 6 | `Unable to autolaunch a dbus-daemon without a $DISPLAY for X11` | The session needs a session bus: `dbus-run-session -- waydroid session start`. |

All six are applied by `scripts/install-waydroid.sh` (idempotent) and re-applied
at boot from `/etc/local.d/alpindroid-waydroid.start`.

### 15.4 Images

`waydroid init -s VANILLA` works but is unusably slow without a proxy
(DNS for github.com fails on the board, sourceforge direct ~60 KB/s). Through
the Windows LAN proxy it pulled over the OTA channel at ~2-3 MB/s:

```
system: lineage-20.0-20260927-VANILLA-waydroid_arm64-system.zip   912 MB -> 1.9 GB img
vendor: lineage-20.0-20261022-MAINLINE-waydroid_arm64-vendor.zip  148 MB -> 402 MB img
/var/lib/waydroid/images: 2.3 GB total
```

### 15.5 Current state (open)

Session reaches `RUNNING`, Android boots through `zygote`, `SystemServer`,
`SurfaceFlinger`, `hwcomposer` and the graphics allocator allocate real buffers
(1024x568), but the container still terminates ~30-40 s after start and
`waydroid status` then shows `Container: STOPPED`. Remaining work: capture the
container's init/console output until the reboot reason is visible (LXC console
capture is currently empty, `lxc-attach` + `logcat` snapshots lose the last
seconds), then decide between a `HALIUM_13` vendor image and a metadata
initialisation fix.

Known limitations carried forward: no PulseAudio (Android audio silent), IPv6
not configured inside the container (kernel lacks the ip6tables tables), and the
container is not started automatically at boot yet.

### 15.6 Root cause of the 30-40 s container exit: lmkd without PSI

The capture from `scripts/debug-waydroid.sh` nailed it in the kernel stream:

```
[ 1636.311193] init: critical process 'lmkd' exited 4 times before boot completed
[ 1636.323541] init: InitFatalReboot: signal 6
```

`lmkd` (Android's low-memory killer) is registered as a **critical** service.
Without pressure information it bails out immediately:

```
E lowmemorykiller: Kernel does not support memory pressure events or in-kernel low memory killer
I lowmemorykiller: exiting
E libpsi: No kernel psi monitor support (errno=2)
```

Android's init then counts four exits and calls `InitFatalReboot` with SIGABRT —
inside a container that is a plain exit, so LXC reports the container stopped and
`waydroid status` flips back to `Container: STOPPED` ~30-40 s after start.

The kernel had `CONFIG_PSI=y` since 15.2, but also `CONFIG_PSI_DEFAULT_DISABLED=y`,
so `/proc/pressure/*` stays empty unless the kernel is told to enable it:

```
# /boot/config.txt
extraargs=psi=1
```

After a reboot:

```
$ cat /proc/pressure/cpu
some avg10=1.51 avg60=1.01 avg300=0.41 total=1755437
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

and the container now stays up (measured over 115 s and counting):

```
Session:	RUNNING
Container:	RUNNING
Vendor type:	MAINLINE
IP address:	192.168.240.112        <- Android's own DHCP lease on waydroid0
Session user:	alpine(1000)
Wayland display:	wayland-0
```

`waydroid show-full-ui` was then started from the session's own bus.

### 15.7 Debug tooling (kept in the repo)

| Script | Purpose |
|---|---|
| `scripts/debug-waydroid.sh [seconds]` | Captures four streams at once into `/root/waydroid-debug-<stamp>/`: Android `logcat` (via `lxc-attach`, so no session bus needed), a rolling host `dmesg` window, `/var/lib/waydroid/waydroid.log`, and a timestamped `lxc-info` state timeline. Leaves the container untouched. |
| `scripts/analyse-waydroid.sh [dir]` | Prints the state timeline, then greps for shutdown/reboot requests, critical-service crashes, OOM, and graphics/cgroup complaints, followed by the tail of each stream. |

Note: an empty `lxc.console.logfile` proves nothing — Android logs through logd
and `/dev/kmsg`, not through the LXC console. The lmkd evidence above came from
the host `dmesg` stream, not from the console.

### 15.8 Version bookkeeping

`v0.20-debug` marks the state where the container finally stays up. It is still
not a release image: Android's UI has only just been launched, touch and GLES
inside Android are unverified, audio is silent (no PulseAudio on the host), IPv6
is missing inside the container, and the container is not started at boot yet.

### 15.9 How the release image is assembled (small base, Android on first boot)

The 2.3 GB of Android images do **not** go into the base image. A release build
ships a ~2.7 GB image and the container is materialised on the board, so Android
can be upgraded later without republishing the whole file.

`scripts/build-alpindroid.sh` now organises it like this:

| Step | What it does |
|---|---|
| `[3b]` | `config.txt`: keeps the existing `extraargs` and appends `psi=1` (idempotent); aborts the build if `psi=1` is missing. Everything else (uart2, printk 7, overlays + `pmic-axp313a`) is unchanged. |
| `[5c]` | Weston/seatd/libinput/touch/fonts (unchanged from v0.19). |
| `[5d]` | `install-waydroid.sh --no-images` inside the chroot: waydroid + lxc + OpenRC service, the six container fixes, the boot hook. Also installs `cloud-utils-growpart` + `e2fsprogs-extra`, drops `firstboot-grow.sh` into `/etc/local.d/alpindroid-firstboot.start`, and copies `waydroid-setup`, `debug-waydroid`, `analyse-waydroid` into `/usr/local/sbin`. |
| `[6/6]` | 8 new checks: `waydroid`, its OpenRC service, `lxc-start`, `waydroid-setup`, the first-boot hook, `growpart`, `resize2fs`, and `extraargs` containing `psi=1`. 36 checks total now. |

First boot on a freshly flashed card:

```sh
# happens automatically (OpenRC local service, no reboot needed):
#   /etc/local.d/alpindroid-firstboot.start -> growpart + resize2fs
#   marker: /etc/.alpindroid-grown, log: /var/log/alpindroid-firstboot.log

# then, once, on the board (needs network; a proxy speeds it up a lot):
waydroid-setup                # = install-waydroid.sh: packages already there,
                              #   this downloads VANILLA system + MAINLINE vendor
                              #   (~1.1 GB) and initialises the container

# afterwards, per session (auto-start deliberately still disabled):
sh /home/alpine/.../start-weston.sh -b     # or wherever the scripts live
dbus-run-session -- sh -c 'waydroid session start &'
sleep 20 && waydroid show-full-ui
```

Kernel stays as validated: `DMABUF_HEAPS{,_SYSTEM,_CMA}=y`, BinderFS, Panfrost,
cgroup2 — and `CONFIG_PSI_DEFAULT_DISABLED=y` is deliberately kept, with
`psi=1` in the boot args instead of another 25-minute rebuild.

Not enabled yet, by design: Waydroid autostart. `v0.20` becomes the release
candidate only after three things are verified on hardware — the Android desktop
is visible on HDMI, touch inside Android works, and GLES renders through
Panfrost from inside the container.

### 15.10 Verified: the container starts with no internet at all

The images live on the card (`/var/lib/waydroid/images`: 1.9 GB `system.img` +
402 MB `vendor.img`), so bringing Android up must not need the network. Measured
by deleting the default route (LAN kept, so SSH survives) and restarting the
whole stack:

```
$ ip route
192.168.137.0/24 dev wlan0  proto kernel  scope link  src 192.168.137.184
192.168.240.0/24 dev waydroid0 proto kernel scope link  src 192.168.240.1
                                  # no default route
$ wget -qO- https://mirrors.aliyun.com
wget: can't connect to remote host (222.73.33.51): Network unreachable

# weston -> waydroid-container -> waydroid-net.sh -> session
$ waydroid status
Session:        RUNNING
Container:      RUNNING
Vendor type:    MAINLINE
IP address:     192.168.240.112
Session user:   alpine(1000)
Wayland display: wayland-0

$ grep 'is ready' /tmp/offline2.log
[02:53:37] Android with user 0 is ready
```

So the boot chain needs **no** external network: the Android images are local,
`waydroid0` + dnsmasq only serve the internal 192.168.240.0/24, and Waydroid's
OTA endpoints are only touched by `waydroid init`, never by a session start.

Network is needed exactly once, on a freshly flashed card, to run
`waydroid-setup` (≈1.1 GB). Everything after that — growpart, container start,
Android boot — works offline. On this board the growth step is already done:

```
/dev/root  117.0G  3.4G used  108.9G available  3%
mmcblk1p2  124721135 sectors   (the whole card)
```