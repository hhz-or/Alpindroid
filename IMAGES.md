# 镜像清单

镜像文件体积 2.7 GB，不入版本库。此文件记录 SHA256 供校验与版本追溯。

## 当前稳定基线

| 版本 | SHA256 | 说明 |
|---|---|---|
| **v0.18** | `79a83716919a6fa12fa516727f9cd9ef425953d9de0d2b5e4a5377dc197abbb5` | **当前最新**：GPU 完整可用 + Mesa 固化 + cgroup2，稳定性测试全通过 |
| v0.17 | `03e9647446ded3d888b6a6e8e458314b258c5e34538cb71baf0a20c7190967c6` | resume 修复，GPU 真实渲染首次通过 |
| v0.16 | `536c81782d9402afe3283bbb5d7cc1d4cf43132c9edcd6beb6812bb5077f3856` | 修复 `/lib/modules` 层级，WiFi 恢复 |
| v0.10 | `f27f18e4cf6c7f07...` | **长期稳定基线**（原厂内核，GPU 禁用，WiFi/调频/HDMI 全通），已云端归档 |
| v0.7 | — | **长期稳定基线**，全部核心功能正常 |

## 历史版本（仅编译机保留）

`~/alpindroid/output/` 下保留 v0.1 ~ v0.18 共 20 个镜像，约 54 GB。

## 校验方法

```powershell
# Windows
Get-FileHash output\Alpindroid-ZeroW-v0.18.img -Algorithm SHA256
```

```bash
# Linux
sha256sum Alpindroid-ZeroW-v0.18.img
```

## 烧录

用 balenaEtcher / Rufus / dd 写入 SD 卡（≥16 GB）。

**首次启动后建议扩容**：

```sh
apk add cloud-utils-growpart e2fsprogs-extra
sfdisk -d /dev/mmcblk1 > /root/partition-backup.sfdisk
growpart /dev/mmcblk1 2
resize2fs /dev/mmcblk1p2
df -h /
```