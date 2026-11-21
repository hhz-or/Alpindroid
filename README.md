# Alpindroid

A Linux system for H618 hardware (WalnutPi ZeroW), combining the official Debian 12 boot chain
with an Alpine Linux 3.23 userspace, targeting Waydroid (Android container) support.

It fixes the GPU and power-supply defects present in the official WalnutPi Debian 12 image,
and replaces the 1.1 GB Debian rootfs with a ~90 MB Alpine one.

**No AOSP compilation is involved.** The goal is a thin Alpine host that runs Android on top of it.

---

## Status: v0.18 (stable baseline)

| Subsystem | Status | Key implementation |
|---|---|---|
| Boot chain | Working | Vendor `boot.bin` / `boot.scr` untouched; p1 carries our `Image`, DTB and one overlay, p2 fully replaced |
| CPU frequency scaling | Working | `ondemand`, 480 MHz – 1.344 GHz, AXP313A `dcdc2` → `vdd-cpu` |
| Power management | Working | PMIC correctly identified as `axp313a` via DT overlay |
| HDMI | Working | KMS output on `sun4i-drm`; modes up to 1080p, panel tested here is 1024x600@60.1 |
| **WiFi** | Working | UNISOC uwe5622 (`sprdwl_ng`), auto-connects |
| Bluetooth | Working | `sprdbt_tty` |
| USB | Working | Includes `OpenWare Multi-Touch-V5000` touchscreen |
| **GPU** | Working | **Mali-G31 / Panfrost, OpenGL ES 3.1** |
| BinderFS | Working | `binder` / `hwbinder` / `vndbinder` (Waydroid prerequisite) |
| cgroup2 | Working | Auto-mounted (Waydroid prerequisite) |
| GPU validation | Built in | `/usr/local/bin/gpu_render_test` works out of the box |

### Verification evidence

```
GL_RENDERER   : Mali-G31 (Panfrost)
GL_VERSION    : OpenGL ES 3.1 Mesa 25.2.7
Stress test   : 10,000 frames / 2 s / 0 errors
Context churn : 100 create-destroy cycles / 16 s / 0 failures
Runtime PM    : 100/100 real suspend -> resume -> render cycles passed
Temperature   : 51 C -> 68 C under sustained load, no throttling issues
```

---

## Repository layout

```
.
├── README.md                        This file
├── CHANGELOG-Alpindroid.md          Complete technical record (root causes + evidence)
├── CHANGES-vs-debian12.md           Diff against the official Debian 12 image
├── IMAGES.md                        Image checksums and flashing guide
│
├── kernel/
│   └── config/config-6.1.31-plus    The exact .config used for the build
│
├── config/
│   ├── weston.ini                   Weston 14 profile (DRM + GL backend, HDMI head)
│   └── udev/99-alpindroid-touch.rules  Bind generic touchscreens to HDMI-A-1
│
├── patches/
│   ├── kernel/
│   │   ├── alpindroid-kernel.patch  Complete kernel diff (8 files, 17 KB)
│   │   ├── panfrost-resume-fix.patch
│   │   ├── fix_panfrost_pmrt.py     Applies the resume fix idempotently
│   │   ├── panfrost_device.c        Patched panfrost source (reference copy)
│   │   ├── panfrost_devfreq.c       Patched panfrost source (reference copy)
│   │   └── ppu/                     PPU driver: mainline copy + 6.1-adapted copy
│   └── dts/
│       ├── pmic-axp313a.dts         Device-tree overlay source (8 fragments)
│       ├── pmic-axp313a.dtbo        Compiled overlay
│       ├── AXP313A-FINDINGS.md      PMIC measurement log
│       └── gpu/                     GPU patch set and write-up
│
└── scripts/
    ├── setup-kernel.sh              Clone upstream + apply patches (one command)
    ├── build-alpindroid.sh          One-shot image builder (15 automated checks)
    ├── build-image.sh               Low-level assembler (base image + rootfs -> image)
    ├── replace-modules.sh           Safe kernel-module replacement
    ├── install-gpu-stack.sh         Inject Mesa via chroot + QEMU
    ├── install-wayland-stack.sh     Weston 14 + seatd + libinput + touch wiring
    ├── start-weston.sh              Start Weston on card0 (dev mode, via seatd)
    ├── wayland-check.sh             Wayland/GPU/touch acceptance checks (21 items)
    ├── alpine-run.sh                Run commands inside the Alpine rootfs (QEMU/binfmt)
    ├── gpu_render_test.c            Single-frame GPU acceptance test
    ├── gpu_render_test               Same test, prebuilt for aarch64
    ├── gpu_stress_test.c            GPU stress test (10k frames + 100 contexts)
    ├── hw-check.sh                  Hardware self-check
    ├── full-test.sh                 On-board full functional test / state snapshot
    ├── hdmi-diag.sh                 HDMI / DRM / fbcon display-path diagnostics
    ├── pmic-diag.sh                 Read-only PMIC information dump
    ├── pmic-regs.sh                 Raw PMIC register dump (i2c-tools)
    ├── pmic-force-read.sh           Forced PMIC reads (-f, bypasses the bound driver)
    ├── serial-capture.ps1           Serial log capture (Windows)
    └── ssh-run.ps1                  Remote exec/upload/download helper (Windows)
```

---

## Quick start

### 1. Prepare the kernel source tree

```bash
sh scripts/setup-kernel.sh
# clones https://github.com/walnutpi/linux.git (branch 6.1.31) into ./build/linux-6.1.31
# applies patches/kernel/alpindroid-kernel.patch
# installs kernel/config/config-6.1.31-plus as .config
# verifies 7 critical changes
```

### 2. Build the kernel

```bash
cd build/linux-6.1.31
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=/tmp/newmods modules_install
```

Takes ~25 minutes on 8 cores.

### 3. Build the SD-card image

```bash
sudo sh scripts/build-alpindroid.sh v0.19 /tmp/newmods/lib/modules/6.1.31+
```

Output: `output/Alpindroid-ZeroW-v0.19.img`. The script runs 15 automated checks
(module directory layout, key `.ko` files, DTB nodes, firmware, `config.txt`, Mesa, cgroup2)
and aborts on any failure.

### 4. Verify on the board

```sh
/usr/local/bin/gpu_render_test     # expects RESULT: PASS
```

---

## Wayland + touch (v0.19, in progress)

Weston 14.0.2 runs on the v0.18 board image with **no kernel change and no Weston
build** — everything comes from the Alpine 3.23 aarch64 repositories.

| Layer | Implementation |
|---|---|
| Output | `sun4i-drm`, `/dev/dri/card0` (KMS, atomic modeset), head `HDMI-A-1` |
| Renderer | GL (`gl-renderer.so`) on `/dev/dri/renderD128` — Mesa 25.2.7, Mali-G31 (Panfrost) |
| Session | `seatd` + `libseat` (`LIBSEAT_BACKEND=seatd`); no root, no `chmod 777 /dev/dri` |
| Touch | generic USB HID multi-touch: in-kernel `hid_multitouch`, MT-B slots, `INPUT_PROP_DIRECT`, 10 points → `libinput` |
| Output binding | udev rule sets `WL_OUTPUT=HDMI-A-1` on any device with `ID_INPUT_TOUCHSCREEN=1` |

The touchscreen is **not** driven by a vendor driver. The panel enumerates as a
standard USB HID device (`222a:0001`, `OpenWare Multi-Touch-V5000`), and the
in-kernel `hid_multitouch` module (`CONFIG_HID_MULTITOUCH=m` in
`kernel/config/config-6.1.31-plus`) turns it into an MT-B input node with
`INPUT_PROP_DIRECT`. The same wiring therefore works for any HID multi-touch
panel — nothing here is specific to this screen.

```sh
# on the board, as root: packages, hid_multitouch, seatd, udev rule, weston.ini
sh scripts/install-wayland-stack.sh alpine

# as the desktop user: DRM backend on card0, GL renderer on Panfrost
sh scripts/start-weston.sh -b

# acceptance: HDMI output, GL renderer (not llvmpipe), touch binding, dmabuf
sh scripts/wayland-check.sh --client --dmabuf

# live touch capture (stops nothing by itself: kill weston first, then touch)
pkill -x weston
sh scripts/wayland-check.sh --touch=15
```

Measured on the ZeroW:

```
weston 14.0.2
libseat: session control granted            (seatd backend)
using /dev/dri/card0                        (sun4i-drm)
Using rendering device: /dev/dri/renderD128
GL renderer: Mali-G31 (Panfrost)            OpenGL ES 3.1 Mesa 25.2.7
Output 'HDMI-A-1' enabled                   1024x600@60.1, preferred
Touchscreen - OpenWare Multi-Touch-V5000 - event3   (MT-B, PROP=DIRECT)
wayland-check.sh                            PASS 21  FAIL 0
```

Status: **development mode only** — Weston is started by hand over SSH/TTY. No
autostart service is installed yet, so a crashing compositor cannot lock you out
of the board. v0.18 stays frozen; all of this lives in the user-space layer.

> **Touch is verified working.** The panel is a plain USB HID multi-touch device:
> `hid-multitouch` binds it as an MT-B node (`INPUT_PROP_DIRECT`, 10 points,
> Report ID `0x15`), libinput scales its 1920x1080 coordinate space onto the
> 1024x600 head, and our udev rule pins it to `HDMI-A-1`. Measured: 6768 bytes /
> 282 events from the `PROP=2` node, and the pointer follows the finger on the
> Weston desktop. Details and the measurement pitfalls that once made this look
> like a hardware fault are in `CHANGELOG-Alpindroid.md` §14.6/§14.7.

---

## How the modifications were found

Five distinct defects, each confirmed on hardware. Full write-up in `CHANGELOG-Alpindroid.md`.

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | **Vendor removed the PPU driver** (GPU power-domain controller) | `modprobe panfrost` hangs forever at `panfrost_gpu_init` | Backport `sun50i-h6-prcm-ppu.c`, add `prcm_ppu` node + `power-domains` |
| 2 | **`mali-supply` wired to `dcdc3`** (which is `vdd-dram`, fixed 1.3 V) | Wrong rail powered | Point to `reg_dcdc1` (`vdd-gpu-sys`), single OPP 432 MHz @ 0.9 V |
| 3 | **`resume` missing `reset_control_deassert` + `clk_prepare_enable`** | Probe succeeds, but any GPU use hard-hangs with zero console output | Align with mainline `panfrost_device_runtime_resume` |
| 4 | **`/lib/modules` missing the version directory** | Every module fails to load (WiFi/BT/GPU all dead) yet the system still boots | `cp -a src/. dst/` to preserve the `6.1.31+` level |
| 5 | **DT overlay used hardcoded phandles** | After rebuilding the DTB the phandle drifted, silently giving `-EPROBE_DEFER` | Use labels (`&reg_dcdc1`) everywhere; never raw `0x..` |

### Debugging methodology

The breakthrough came from **serial console access**. Before that, three rounds of blind
experimentation (reordering init, disabling DVFS, fixed OPP) all failed because the only
visible symptom was "last message is `bus_clock rate`".

Inserting `pr_info("Alpindroid-STEP: ...")` before each init step pinpointed the hang to
`panfrost_gpu_init` — which ruled out clocks/voltage/DVFS and pointed at hardware power.

The ZeroW exposes two UARTs:

- **UART0 = PH0/PH1** — official debug port, on the FPC connector (needs an adapter)
- **UART2 = PI5(TX) / PI6(RX)** — on the 40-pin header, set `console_uart=uart2` in `config.txt`

Wiring: `PI5 -> USB-TTL RX`, `PI6 -> USB-TTL TX`, `GND -> GND`, **VCC left unconnected** (3.3 V logic).

---

## References

| Source | Purpose |
|---|---|
| `https://github.com/walnutpi/linux` (branch 6.1.31, HEAD `30ff3fd5cf`) | Vendor kernel, the base for our patches |
| `https://github.com/walnutpi/walnutpi_wiki` | Official docs (pinout, boot flow) |
| `https://github.com/walnutpi/walnutpi-build` | Vendor image builder (reference only, not used here) |
| `torvalds/linux` master | Reference for PPU driver and panfrost runtime-PM logic |

## Not tracked in this repository

| Path | Reason |
|---|---|
| `output/*.img` | 2.7 GB per image; checksums recorded in `IMAGES.md` |
| `images/`, `work/`, `build/` | Vendor base image and kernel source tree |
| `ssh.txt` | **Contains plaintext credentials** |
| `debian12/` | Vendor build-tool copy, re-obtainable from GitHub |

## Roadmap

- **v0.19** — Weston (DRM backend) + Panfrost + HDMI + touchscreen — path working on hardware, image integration pending
- **v0.20** — Waydroid container
- **v0.21** — Android graphics acceleration

## License

MIT — see [LICENSE](LICENSE).