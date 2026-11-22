# Image manifest

Image files are ~2.7 GB each and are **not** stored in this repository.
This file records their checksums for verification and version tracking.

## Current baseline

| Version | SHA256 | Notes |
|---|---|---|
| **v0.22d** | `080159ff12f80d9a66cda9043cf50275e9b7f7e04c5c627eeca51581765d25cf` | **Latest**, 6.0 GB: touch works on a cold boot. The autostart service now runs `wayland-adapt.sh` → `udevadm reload` → `udevadm trigger` → weston, in that order; previously weston enumerated input before the udev database carried `WL_OUTPUT`, so the panel got no output association and touch was dead while everything else worked. Same content as v0.22c otherwise: `baka` easter egg, HDMI/USB hotplug, one-shot `show-full-ui`, kiosk-shell weston, Android baked in. 53 build checks. |
| v0.22c | `b169919a03a128267c3894bff7fc6f5371a8422c9c584ff143a59a0f78986e42` | 6.0 GB: adds the `baka` terminal easter egg (`/usr/local/bin/baka`, statically linked, all 9 tiers, animations embedded) and HDMI/USB hotplug handling — a DRM `change` udev rule re-runs `wayland-adapt.sh` so the touch binding follows the connected head, and the autostart service applies the input udev rule before starting weston. 53 build checks. |
| v0.22b | `372adee0b5442e3e7490b2ea1322b0d757d6f392052cc39e8e0c6a75b3fa4883` | 6.0 GB: `show-full-ui` is issued exactly once per boot, so the notification shade no longer slides down every few seconds (Waydroid's `show-full-ui` runs `expand()/sleep(0.5)/collapse()` as a "refresh" hack). The autostart helper also runs as root, so `lxc-info`/`lxc-unfreeze` finally work instead of failing with "Insufficent privileges". Everything else as v0.22: Android baked in, kiosk-shell weston, offline first boot, 49 build checks. |
| v0.22 | `a4d992ec734d3431eb925ea244cb794e0b13c766dd4fd412301d5c2ce2d15ac1` | 6.0 GB: Waydroid (LineageOS 20) as the primary UI, **Android images baked in** (`system.img` 1.9 G + `vendor.img` 403 M) so first boot needs **no network**, and **the desktop autostarts** — `alpindroid-desktop` (OpenRC) brings up weston with `--shell=kiosk`, the container, the session and finally `show-full-ui`. Root partition is pre-grown to 5.7 G; the first-boot hook expands it to the whole card. GLES 3.1 on Mali-G31 (Panfrost) in both the host and Android. 49 build checks, all passing. |
| v0.18 | `79a83716919a6fa12fa516727f9cd9ef425953d9de0d2b5e4a5377dc197abbb5` | Kernel-stable baseline: GPU fully working, Mesa preinstalled, cgroup2 auto-mounted |
| v0.17 | `03e9647446ded3d888b6a6e8e458314b258c5e34538cb71baf0a20c7190967c6` | First version with working GPU rendering (resume fix) |
| v0.16 | `536c81782d9402afe3283bbb5d7cc1d4cf43132c9edcd6beb6812bb5077f3856` | Fixed `/lib/modules` layout; WiFi restored |
| v0.10 | `f27f18e4cf6c7f07…` | **Long-term baseline** (vendor kernel, GPU disabled, WiFi/cpufreq/HDMI all working). Archived to cloud storage |
| v0.7 | — | **Long-term baseline**, all core features working |

## Historical versions

20 images (v0.1 through v0.18) are kept on the build host under `~/alpindroid/output/`, about 54 GB total.

## First boot of v0.22 (no network needed, nothing to run)

Everything comes up by itself:

```sh
# 1. /etc/local.d/alpindroid-firstboot.start  -> growpart + resize2fs
#    marker: /etc/.alpindroid-grown   log: /var/log/alpindroid-firstboot.log
# 2. rc-service alpindroid-desktop (default runlevel)
#      weston --shell=kiosk  -> waydroid-container -> waydroid session
#      -> alpindroid-show-ui, which waits for sys.boot_completed=1
#         and then runs show-full-ui
```

The Android images and the whole Waydroid configuration are baked into the image
(`/var/lib/waydroid/{images,waydroid.cfg,waydroid_base.prop,lxc/waydroid/*}`),
so nothing is downloaded.

`weston` must run with `--shell=kiosk`: Waydroid's hwcomposer creates one
full-output wayland surface with no window semantics, and the default
`desktop-shell` never maps it (HDMI just stays grey).

Useful controls:

```sh
rc-service alpindroid-desktop status|restart|stop
rc-update del alpindroid-desktop default     # disable the autostart
tail -f /tmp/weston.log /tmp/alpindroid-show-ui.log
```

## Verifying

```powershell
# Windows
Get-FileHash output\Alpindroid-ZeroW-v0.18.img -Algorithm SHA256
```

```bash
# Linux
sha256sum Alpindroid-ZeroW-v0.18.img
```

## Flashing

Use balenaEtcher, Rufus, or `dd` to write to an SD card (16 GB or larger).

**Expand the root partition after the first boot** — the image ships with a 2.4 GB rootfs
and the card is usually much larger:

```sh
apk add cloud-utils-growpart e2fsprogs-extra
sfdisk -d /dev/mmcblk1 > /root/partition-backup.sfdisk   # back up the partition table first
growpart /dev/mmcblk1 2
resize2fs /dev/mmcblk1p2
df -h /
```

Measured result on a 128 GB card: 2.4 GB -> 117 GB usable.

> **Note**: `resize2fs` lives in `e2fsprogs-extra` on Alpine, not in `e2fsprogs`.