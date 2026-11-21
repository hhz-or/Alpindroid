# Alpindroid v0.2 相对官方 Debian 12 镜像的改动清单

对比对象：

| 项 | 路径 |
|---|---|
| 基线（官方） | `images/2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img` |
| 产物（Alpindroid） | `output/Alpindroid-ZeroW-v0.2.img` |
| Alpine 基线 | `alpine/alpine-minirootfs-3.23.8-aarch64.tar.gz` → 解包到 `work/baseline-rootfs` |

所有数据来自对镜像/目录的实测 diff，非人工罗列。

---

## 一、镜像结构层（最关键的结论）

### 1.1 boot 分区 p1：24 个文件，**只有 1 个变了**

逐文件 MD5 对比结果：

```
差异只有：
  config.txt   官方 795073eb167dfca808a3010feea961f1
               新版 761d34da3dda3b33069349faeeb9e795
文件数：官方 24 / 新版 24
```

即 **U-Boot SPL（`boot.bin`）、`boot.scr`、`Image`(Linux 6.1.31)、两个 DTB、
`overlays/` 12 个 dtbo、`initrd.img-6.1.31`、`uInitrd`、`config-6.1.31`
全部与官方**逐字节相同**。启动链零改动。

`config.txt` 的唯一改动：
```diff
-rootdev=PARTUUID=e97f9f8e-02
+rootdev=PARTUUID=5e9eaabe-02
```

### 1.2 分区表：结构完全相同，仅磁盘 ID 变化

| 项 | 官方 | Alpindroid |
|---|---|---|
| 分区表类型 | msdos | msdos |
| p1 | start=8192, size=286720, type=c, bootable | **相同** |
| p2 | start=294912, size=5363712, type=83 | **相同** |
| label-id | `0xe97f9f8e` | `0x5e9eaabe` |

磁盘 ID 变化是刻意的（避免与原卡 PARTUUID 冲突），并按此同步修改了
`config.txt` 的 `rootdev` 与 `/etc/fstab` 的两条 PARTUUID。

### 1.3 用户空间 p2：Debian 12 被 Alpine 3.23.8 完全替换

| 项 | 官方 Debian 12 | Alpindroid v0.2 |
|---|---|---|
| init | systemd | busybox init + OpenRC |
| 包管理 | dpkg/apt | apk |
| 内核模块 | 133 M | 133 M（**从官方镜像原样迁移**） |
| 固件 | 3.8 M | 3.8 M（**原样迁移**，含 `aic8800d80`、uwe5622 相关） |

> 注意：`/lib/modules` 与 `/lib/firmware` 不在 `work/rootfs` 目录里，
> 它们是在 `build-image.sh` 第 [5/7] 步从官方镜像直接 rsync 进 p2 的。

---

## 二、包层面：16 → 146

```
官方 minirootfs : 16 个包
Alpindroid v0.2 : 146 个包
新增            : 130 个
移除            : 0 个
```

显式安装（`/etc/apk/world`）从 6 项增加到 32 项，新增 26 项：

```
alpine-base  ca-certificates  dbus  dbus-openrc  e2fsprogs  eudev  eudev-openrc
ifupdown-ng-wifi  iproute2  iputils  iw  kmod  nano
networkmanager  networkmanager-cli  networkmanager-openrc  networkmanager-wifi
openrc  openssh-client-default  openssh-server  pciutils  rsync  tzdata
usbutils  util-linux  wpa_supplicant
```

其余 104 个是上述包的依赖（`glib`、`libnm`、`libnl3`、`dbus-libs`、`eudev-libs`、
`sqlite-libs`、`nss`、`libcurl`、`util-linux` 系列等）。

---

## 三、`/etc` 配置改动：0 删除 / 277 新增 / 8 修改

### 3.1 被修改的 8 个文件（逐个 diff）

**`/etc/hostname`**
```diff
-localhost
+alpindroid
```

**`/etc/hosts`**
```diff
-127.0.0.1	localhost localhost.localdomain
-::1		localhost localhost.localdomain
+127.0.0.1	localhost localhost.localdomain alpindroid alpine
+::1		localhost localhost localdomain ip6-localhost ip6-loopback
```

**`/etc/inittab`**（`tty1` 是 Alpine 原有的，未改动）
```diff
+ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
```

**`/etc/modules`**
```diff
 af_packet
 ipv6
+sprdwl_ng
+sprdbt_tty
```

**`/etc/passwd`**
```diff
+alpine:x:1000:1000::/home/alpine:/bin/ash          ← 新建的登录用户
+messagebus:x:100:101:messagebus:/dev/null:/sbin/nologin   ← dbus 包创建
```

**`/etc/group`**
```diff
+alpine:x:1000:
+messagebus:x:101:messagebus
+plugdev:x:102:                                    ← eudev 包创建
```

**`/etc/shadow`**
```diff
-root:*::0:::::                                    ← 基线 root 被锁定
+root:$6$Nzf8Sjk0...:20777:0:::::                   ← 已设密码（串口维护用）
+alpine:$6$78Fx.XEQ...:20777:0:99999:7:::
+messagebus:!:20777:0:99999:7:::
```

**`/etc/apk/world`** —— 见第二节。

### 3.2 关键新增文件（277 项中的重点）

| 路径 | 说明 |
|---|---|
| `/etc/network/interfaces` | 仅 `auto lo` + `iface lo inet loopback`（wlan0 交给 NM） |
| `/etc/NetworkManager/system-connections/home.nmconnection` | 600 权限，SSID `Desktop` / psk / `interface-name=wlan0` |
| `/etc/wpa_supplicant/wpa_supplicant.conf` | 600 权限（NM 不读它，保留作手动调试） |
| `/etc/ssh/sshd_config` | `PermitRootLogin no` + `PasswordAuthentication yes` |
| `/etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key` | 3 把主机密钥已生成 |
| `/etc/runlevels/{sysinit,boot,default}/*` | OpenRC 服务链接（见下） |
| `/etc/localtime`、`/etc/timezone` | Asia/Shanghai |
| `/etc/resolv.conf` | 基线**无此文件**（属新增），当前为公网 DNS，NM 启动后会重写 |
| `/etc/udev/`、`/etc/mdev.conf` | udev 已接管，mdev 配置保留但不启用 |
| `/etc/dbus-1/`、`/etc/NetworkManager/` | NetworkManager/dbus 配置目录 |

### 3.3 OpenRC 服务布局（相对 Debian 的 systemd）

```
sysinit : devfs dmesg hwdrivers udev udev-trigger     ← 原 mdev 已移除
boot    : hostname modules                            ← 原 networking 已移除
default : dbus networkmanager sshd
```

对比官方 Debian 的对应关系：

| 功能 | Debian（systemd） | Alpindroid（OpenRC） |
|---|---|---|
| 设备管理 | `systemd-udevd` | `udev` + `udev-trigger`（eudev） |
| 网络管理 | `NetworkManager.service` | `networkmanager`（+ `dbus`） |
| SSH | `ssh.service` | `sshd` |
| 串口控制台 | `serial-getty@ttyS0` | inittab 的 `ttyS0::respawn:` |
| 本地终端 | `getty@tty1` | inittab 的 `tty1::respawn:`（原样保留） |

---

## 四、完全**未**改动的部分

| 项 | 状态 |
|---|---|
| U-Boot SPL / U-Boot（`boot.bin`） | 逐字节相同 |
| 内核 `Image`（Linux 6.1.31） | 逐字节相同 |
| 设备树 DTB（1b / 1b-emmc） | 逐字节相同 |
| DT overlays（12 个 dtbo + fixup.scr） | 逐字节相同 |
| `boot.scr` / `boot.cmd` | 逐字节相同 |
| `initrd.img-6.1.31` / `uInitrd` | 逐字节相同（`bootlogo=false` 时不加载） |
| 内核 config | 逐字节相同 |
| `/lib/modules/6.1.31`（含 uwe5622 三个 .ko） | 原样迁移，未重编 |
| `/lib/firmware` | 原样迁移 |
| ext4 文件系统 UUID | `79121c5e-50ed-4cda-bfe3-9ddb63fe7605`（未重新格式化，与官方镜像相同） |

---

## 五、已知待清理项（**v0.2 镜像里仍存在**）

| 项 | 大小 | 来源 |
|---|---|---|
| `/etc/hosts.orig` | 小 | 我修改 hosts 前的备份 |
| `/etc/modules.orig` | 小 | 我追加 wifi 模块前的备份 |
| `/etc/ssh/sshd_config.orig` | 小 | 我改 sshd 配置前的备份 |
| `/var/cache/apk/` | 2.8 M | apk 索引缓存（APKINDEX） |

不影响启动，但做“干净镜像”时应删除后重建。

---

## 六、能力边界（与官方的功能差异）

| 能力 | 官方 Debian 12 | Alpindroid v0.2 | 说明 |
|---|---|---|---|
| 包管理 | apt（Debian 源） | apk（Alpine 源） | 全部已装包见第二节 |
| 桌面环境 | 有自己的服务器版软件集 | **无桌面**，仅 TTY | HDMI 文本终端 + USB 键鼠 |
| CPU 调频 | 取决于内核/DTB（有已知问题） | **同上，未修复** | `patches/dts/AXP313A-FINDINGS.md` 记录了实测问题 |
| Binder / Waydroid | 未启用 | **未启用**（内核无 `CONFIG_ANDROID_BINDER_IPC`） | 需重编内核 |
| GPU 3D | Panfrost 模块存在 | 同上（模块已迁移） | DTB 供电引用有已知问题 |
| 内核 | 6.1.31 | **同一个 6.1.31** | 未重编 |

---

## 七、复现方式

```sh
sudo bash ~/alpindroid/scripts/build-image.sh \
  ~/alpindroid/images/2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img \
  ~/alpindroid/work/rootfs \
  ~/alpindroid/output/Alpindroid-ZeroW-vX.Y.img
```

脚本行为：复制底板 → 生成新 MBR Disk ID → rsync 替换 p2 用户空间 →
从底板迁移 `/lib/modules` + `/lib/firmware` → 按新 PARTUUID 重写
`/etc/fstab` 与 boot 分区 `config.txt` 的 `rootdev` → 清理 loop/挂载。
