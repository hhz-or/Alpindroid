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
| Boot chain | Working | Vendor `boot.bin` / `boot.scr` / DTB kept intact; only p2 replaced |
| CPU frequency scaling | Working | `ondemand`, 480 MHz – 1.344 GHz, AXP313A `dcdc2` → `vdd-cpu` |
| Power management | Working | PMIC correctly identified as `axp313a` via DT overlay |
| HDMI | Working | 1080p output, `hvcc-supply` → `vcc-wifi-io` |
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
├── patches/
│   ├── kernel/
│   │   ├── alpindroid-kernel.patch  Complete kernel diff (8 files, 17 KB)
│   │   ├── panfrost-resume-fix.patch
│   │   └── fix_panfrost_pmrt.py     Applies the resume fix idempotently
│   └── dts/
│       ├── pmic-axp313a.dts         Device-tree overlay source (8 fragments)
│       ├── pmic-axp313a.dtbo        Compiled overlay
│       ├── AXP313A-FINDINGS.md      PMIC measurement log
│       └── gpu/                     GPU patch set and write-up
│
└── scripts/
    ├── setup-kernel.sh              Clone upstream + apply patches (one command)
    ├── build-alpindroid.sh          One-shot image builder (15 automated checks)
    ├── replace-modules.sh           Safe kernel-module replacement
    ├── install-gpu-stack.sh         Inject Mesa via chroot + QEMU
    ├── gpu_render_test.c            Single-frame GPU acceptance test
    ├── gpu_stress_test.c            GPU stress test (10k frames + 100 contexts)
    ├── hw-check.sh                  Hardware self-check
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

- **v0.19** — Weston (DRM backend) + Panfrost + HDMI + touchscreen
- **v0.20** — Waydroid container
- **v0.21** — Android graphics acceleration

## License

MIT — see [LICENSE](LICENSE).