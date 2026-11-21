# Image manifest

Image files are ~2.7 GB each and are **not** stored in this repository.
This file records their checksums for verification and version tracking.

## Current baseline

| Version | SHA256 | Notes |
|---|---|---|
| **v0.22** | `111ecaba36314386308b97e3656fc8f305d5b2afc6f4fe8848b4b0fbb1ca48c1` | **Latest**: Waydroid (LineageOS 20) as the primary UI. Weston/Panfrost/touch as in v0.19, plus lxc + waydroid packages, the six container fixes, `extraargs=psi=1`, first-boot root growth and `waydroid-setup`. Android images are **not** in the image (downloaded once on the board). |
| v0.18 | `79a83716919a6fa12fa516727f9cd9ef425953d9de0d2b5e4a5377dc197abbb5` | Kernel-stable baseline: GPU fully working, Mesa preinstalled, cgroup2 auto-mounted |
| v0.17 | `03e9647446ded3d888b6a6e8e458314b258c5e34538cb71baf0a20c7190967c6` | First version with working GPU rendering (resume fix) |
| v0.16 | `536c81782d9402afe3283bbb5d7cc1d4cf43132c9edcd6beb6812bb5077f3856` | Fixed `/lib/modules` layout; WiFi restored |
| v0.10 | `f27f18e4cf6c7f07…` | **Long-term baseline** (vendor kernel, GPU disabled, WiFi/cpufreq/HDMI all working). Archived to cloud storage |
| v0.7 | — | **Long-term baseline**, all core features working |

## Historical versions

20 images (v0.1 through v0.18) are kept on the build host under `~/alpindroid/output/`, about 54 GB total.

## First boot of v0.22

```sh
# automatic (OpenRC local, online, no reboot):
#   /etc/local.d/alpindroid-firstboot.start -> growpart + resize2fs
#   marker: /etc/.alpindroid-grown   log: /var/log/alpindroid-firstboot.log
# then once, with network (a proxy helps):
waydroid-setup          # downloads ~1.1 GB of Android images, initialises the container
```

After that the container starts offline. Autostart is deliberately disabled.

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