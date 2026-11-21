# Changes vs. the official Debian 12 image

Baseline: `2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img`
(2,897,215,488 bytes, SHA256 `ece049da8889146a37ccc8a1daa29fe023f903cc5ec2b44aa34513c37d7c9d34`)

---

## 1. Boot partition (p1)

Only **3 of 24 files** are modified.

| File | Change |
|---|---|
| `config.txt` | `console_uart=uart0` → `uart2`; `printk_level=3` → `7`; `overlays=` gains ` pmic-axp313a`; `rootdev=PARTUUID=<new disk id>-02` |
| `Image` | Replaced with our own 6.1.31+ build (22.6 MB) |
| `sun50i-h616-walnutpi-1b.dtb` | Rebuilt from vendor source + our DTS changes (40.5 KB) |
| `overlays/sun50i-h616-pmic-axp313a.dtbo` | **New** (1.2 KB, 8 fragments) |

Everything else is byte-identical: `boot.bin`, `boot.scr`, `initrd.img-6.1.31`, `uInitrd`,
`config-6.1.31`, the `-emmc.dtb`, and the other 12 vendor overlays.

> The vendor `boot.bin` / `boot.scr` are never touched — they natively support `fdt apply`,
> so an overlay failure rolls back to a plain boot.

---

## 2. Root partition (p2)

Debian 12 (≈1.1 GB) is entirely replaced by Alpine 3.23.8 (≈90 MB base).

| Item | Debian 12 original | Alpindroid |
|---|---|---|
| Init system | systemd | OpenRC |
| Package manager | apt/dpkg | apk |
| glibc | glibc 2.36 | musl 1.2.5 |
| Rootfs size | ≈1.1 GB | ≈90 MB (≈250 MB with Mesa) |
| Login | systemd getty | `util-linux-login` + busybox getty `-L` |
| Networking | NetworkManager | NetworkManager (same, kept for compatibility) |

Kernel modules and firmware are migrated from the vendor image, then replaced by our own build.

---

## 3. Kernel modifications

Base: `https://github.com/walnutpi/linux` branch `6.1.31`, HEAD `30ff3fd5cf45417622b447a12e7a947402ffe34d`

| File | Change |
|---|---|
| `drivers/soc/sunxi/sun50i-h6-prcm-ppu.c` | **New** — H616 PRCM power-domain driver, backported from mainline and adapted to the 6.1 API |
| `drivers/soc/sunxi/Kconfig` | Add `SUN50I_H6_PRCM_PPU` |
| `drivers/soc/sunxi/Makefile` | Add `obj-$(CONFIG_SUN50I_H6_PRCM_PPU)` |
| `drivers/gpu/drm/panfrost/panfrost_device.c` | Fix init order; add `reset_control_deassert` + `clk_prepare_enable` to `resume`, symmetric teardown in `suspend` |
| `drivers/gpu/drm/panfrost/panfrost_devfreq.c` | Disable GPU DVFS (single fixed OPP instead) |
| `arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi` | Add `prcm_ppu` node |
| `arch/arm64/boot/dts/allwinner/sun50i-h616-walnutpi-1b.dts` | `mali-supply` → `reg_dcdc1`; add `power-domains`; single-OPP table; `hvcc-supply` → `reg_vcc_wifi_io` |
| `arch/arm64/configs/walnutpi1b_defconfig` | Enable `CONFIG_SUN50I_H6_PRCM_PPU=y` |

Full diff: `patches/kernel/alpindroid-kernel.patch` (8 files, 17 KB).

---

## 4. Device-tree overlay

`patches/dts/pmic-axp313a.dts` — 8 fragments, **zero hardcoded phandles**.

| # | Target | Purpose |
|---|---|---|
| 0 | `/soc/i2c@7081400/pmic@36` | `compatible = "x-powers,axp313a"` — the vendor DTS claims AXP806, which breaks every regulator lookup |
| 1 | `regulators/dcdc2` | `regulator-ramp-delay = <400>` |
| 2 | `regulators/dcdc1` | `ramp-delay`, `min-microvolt = <900000>` (GPU+CPU/SYS shared rail) |
| 3 | `regulators/dcdc3` | `min = max = <1100000>` (vendor said 1.3 V; measured 1.1 V) |
| 4 | `/thermal-zones/cpu-thermal` | `polling-delay(-passive) = <1000>` (vendor: 0 → no polling) |
| 5 | `cpu-thermal/trips/cpu-crit` | `temperature = <115000>` (vendor: 300000 — i.e. 300 °C) |
| 6 | `/thermal-zones/gpu-thermal` | `polling-delay(-passive) = <1000>` |
| 7 | `gpu-thermal/trips/gpu-crit` | `type = "critical"` (vendor: `passive`) |

GPU power and OPP are handled directly in the board DTS, not in the overlay — see
`patches/dts/gpu/README.md` for why (phandle drift).

---

## 5. User-space additions

| Item | Purpose |
|---|---|
| mesa 25.2.7 (`mesa-dri-gallium`, `mesa-egl`, `mesa-gles`, `mesa-gl`, `mesa-gbm`, `mesa-utils`) | GPU userspace |
| `/usr/local/bin/gpu_render_test` | GPU acceptance test |
| `/usr/local/src/gpu_render_test.c` | Its source |
| `/etc/sysctl.d/99-printk.conf` | `kernel.printk = 8 4 1 7` |
| `sysctl` in boot runlevel | Makes the above actually apply |
| `/etc/fstab`: `binder` + `cgroup2` | Waydroid prerequisites |
| `/etc/modules`: `sprdwl_ng`, `sprdbt_tty` | WiFi/BT autoload |
| chrony pool → `ntp1.aliyun.com` | Vendor default `ntp.aliyun.com` does not exist (NXDOMAIN) |

---

## 6. Deliberate non-changes

| Item | Why |
|---|---|
| `boot.bin` / `boot.scr` | Vendor bootloader works; it supports `fdt apply` with rollback |
| `initrd.img-6.1.31` | Not used (rootfs mounted directly) |
| GPU DVFS | Deliberately single OPP 432 MHz @ 0.9 V. `dcdc1` is shared with SYS; dropping to 810 mV destabilises the whole system (measured in v0.4) |
| Vendor `-emmc.dtb` | Not used by this board variant |