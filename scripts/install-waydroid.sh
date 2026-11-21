#!/bin/sh
# ============================================================================
# Alpindroid v0.22: Waydroid (Android 14 / LineageOS 20 container) — the primary UI
#
# Runs on the board as root. Idempotent for everything except `waydroid init`
# (which only downloads once; pass --reinit to wipe and re-fetch the images).
#
# Kernel prerequisites — already enabled in kernel/config/config-6.1.31-plus
# since v0.22 and required for Android's graphics allocator:
#   CONFIG_DMABUF_HEAPS=y
#   CONFIG_DMABUF_HEAPS_SYSTEM=y
#   CONFIG_DMABUF_HEAPS_CMA=y
#   CONFIG_PSI=y                    (optional, silences libpsi/lmkd warnings)
#   binderfs + cgroup2              (already in the v0.18 baseline)
# Without DMABUF_HEAPS the container starts and then dies with
#   Gralloc4: AIDL IAllocator declared but failed to get service
#   GraphicBufferAllocator: Failed to allocate (128 x 128) ... : 7
#
# Container-side fixes applied here, all of them measured on hardware:
#   1. /run/user/<uid>/pulse/native placeholder — the generated LXC config bind
#      mounts a PulseAudio socket that does not exist on a bare Alpine rootfs,
#      and a missing bind source aborts the whole container start;
#   2. lxc.mount.auto = cgroup:mixed instead of cgroup:ro — Android must create
#      per-uid cgroups; with :ro init fails with
#      "createProcessGroup(NNN, ...) failed: Read-only file system";
#   3. /dev/dma_heap bind mount into the container — the allocator HAL needs the
#      heaps, and Waydroid's generated config predates them on this kernel;
#   4. /metadata bind mount — Android 12+ keeps bootstat/installd state there;
#   5. waydroid-net.sh start before the container — the bridge waydroid0 must
#      exist, otherwise lxc-start fails to attach the veth;
#   6. the session user needs a session bus:
#      `dbus-run-session -- waydroid session start`.
#
# Usage (on the board, as root):
#   sh install-waydroid.sh              # setup + start container, no UI
#   sh install-waydroid.sh --reinit     # re-download the Android images
#   sh install-waydroid.sh --status     # only report state
#
# The UI itself must be started by the desktop user (see the summary at the end).
# ============================================================================
set -u

DESKTOP_USER="${DESKTOP_USER:-alpine}"
REINIT=0
STATUS_ONLY=0
NO_IMAGES=0
SYSTEM_TYPE="${SYSTEM_TYPE:-VANILLA}"

for a in "$@"; do
    case "$a" in
        --reinit) REINIT=1 ;;
        --status) STATUS_ONLY=1 ;;
        --no-images) NO_IMAGES=1 ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$a" >&2; exit 1 ;;
    esac
done

LXC_DIR=/var/lib/waydroid/lxc/waydroid
NODES="$LXC_DIR/config_nodes"
MAIN_CFG="$LXC_DIR/config"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
UID_NUM=$(id -u "$DESKTOP_USER" 2>/dev/null) || die "no such user: $DESKTOP_USER"

status() {
    printf '\n=== waydroid status ===\n'
    waydroid status 2>&1
    printf '\n=== lxc ===\n'
    lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH 2>/dev/null
    printf '\n=== kernel prerequisites ===\n'
    ls -d /dev/dma_heap 2>/dev/null || echo "  /dev/dma_heap MISSING (CONFIG_DMABUF_HEAPS)"
    ls /dev/binder 2>/dev/null || echo "  /dev/binder MISSING"
    grep -q cgroup2 /proc/mounts && echo "  cgroup2 mounted"
}

if [ "$STATUS_ONLY" = "1" ]; then
    status
    exit 0
fi

# ---------------------------------------------------------------- 1. packages
say "1/7 packages: waydroid + lxc"
if grep -q 'dl-cdn.alpinelinux.org' /etc/apk/repositories 2>/dev/null; then
    sed -i 's|https\?://dl-cdn.alpinelinux.org|https://mirrors.aliyun.com|' /etc/apk/repositories
fi
apk add --no-cache waydroid waydroid-openrc lxc dnsmasq iptables
rc-update add waydroid-container default >/dev/null 2>&1 || true

# ------------------------------------------------------------- 2. prerequisites
say "2/7 kernel prerequisites"
if [ ! -d /dev/dma_heap ]; then
    printf '  WARN /dev/dma_heap missing -> Android graphics will fail.\n'
    printf '       Rebuild the kernel with CONFIG_DMABUF_HEAPS{,_SYSTEM,_CMA}=y\n'
    printf '       (kernel/config/config-6.1.31-plus already has them since v0.22).\n'
else
    echo "  /dev/dma_heap: $(ls /dev/dma_heap | tr '\n' ' ')"
fi
# Android's lmkd is a *critical* process: without pressure information it exits
# immediately, init counts 4 exits and calls InitFatalReboot, which tears the
# whole container down ~30-40 s after start. CONFIG_PSI=y is compiled in, but
# CONFIG_PSI_DEFAULT_DISABLED=y keeps it off unless the kernel gets `psi=1`:
#   /boot/config.txt  ->  extraargs=psi=1
if [ -r /proc/pressure/cpu ]; then
    echo "  PSI: enabled ($(head -n1 /proc/pressure/cpu))"
else
    printf '  WARN PSI not enabled -> lmkd will exit and Android will reboot-loop.\n'
    printf '       Add "extraargs=psi=1" to /boot/config.txt (or rebuild without\n'
    printf '       CONFIG_PSI_DEFAULT_DISABLED) and reboot.\n'
fi
mount | grep -q 'type cgroup2' && echo "  cgroup2 ok" || echo "  WARN cgroup2 not mounted (needed by Android)"

# ----------------------------------------------------------- 3. android images
say "3/7 android images"
if [ "$REINIT" = "1" ] && [ -d /var/lib/waydroid/images ]; then
    echo "  --reinit: removing existing images"
    rm -rf /var/lib/waydroid/images /var/lib/waydroid/rootfs /var/lib/waydroid/overlay \
           /var/lib/waydroid/overlay_rw /var/lib/waydroid/overlay_work
fi
if [ -f /var/lib/waydroid/images/system.img ] && [ -f /var/lib/waydroid/images/vendor.img ]; then
    echo "  images present: $(du -sh /var/lib/waydroid/images | cut -f1)"
elif [ "$NO_IMAGES" = "1" ]; then
    echo "  --no-images: skipping the download (image build / offline setup)"
    echo "  run this script again without --no-images on first boot, or:"
    echo "    https_proxy=... waydroid init -s $SYSTEM_TYPE"
else
    echo "  downloading (needs network; in CN a proxy helps a lot):"
    echo "    https_proxy=... waydroid init -s $SYSTEM_TYPE"
    if ! waydroid init -s "$SYSTEM_TYPE"; then
        die "waydroid init failed (check network / proxy, or fetch the images by hand)"
    fi
fi

# --------------------------------------------------- 4. container-side fixes
say "4/7 container fixes"
mkdir -p "/run/user/$UID_NUM/pulse"
[ -f "/run/user/$UID_NUM/pulse/native" ] || : > "/run/user/$UID_NUM/pulse/native"
chown -R "$UID_NUM:$UID_NUM" "/run/user/$UID_NUM/pulse"
echo "  pulse socket placeholder ok"

mkdir -p /var/lib/waydroid/metadata
echo "  /var/lib/waydroid/metadata ok"

# the LXC config is regenerated on every `waydroid session start`, so patch it
# every time this script runs (and keep a hook so the patch survives restarts)
if [ -f "$MAIN_CFG" ]; then
    sed -i 's|lxc.mount.auto = cgroup:ro|lxc.mount.auto = cgroup:mixed|' "$MAIN_CFG"
    echo "  $(grep 'lxc.mount.auto' "$MAIN_CFG")"
else
    echo "  NOTE $MAIN_CFG not created yet; it appears on the first session start"
fi

if [ -f "$NODES" ]; then
    grep -q 'dev/dma_heap' "$NODES" || \
        echo 'lxc.mount.entry = /dev/dma_heap dev/dma_heap none bind,create=dir,optional 0 0' >> "$NODES"
    grep -q ' metadata ' "$NODES" || \
        echo 'lxc.mount.entry = /var/lib/waydroid/metadata metadata none bind,create=dir,optional 0 0' >> "$NODES"
    echo "  dma_heap + metadata mounts present"
fi

# keep the fixes across reboots: a local.d hook re-applies them
cat > /etc/local.d/alpindroid-waydroid.start <<EOF
#!/bin/sh
# Generated by install-waydroid.sh: re-apply the container fixes on boot
mkdir -p /run/user/$UID_NUM/pulse
[ -f /run/user/$UID_NUM/pulse/native ] || : > /run/user/$UID_NUM/pulse/native
chown -R $UID_NUM:$UID_NUM /run/user/$UID_NUM/pulse
mkdir -p /var/lib/waydroid/metadata
[ -f $MAIN_CFG ] && sed -i 's|lxc.mount.auto = cgroup:ro|lxc.mount.auto = cgroup:mixed|' $MAIN_CFG
[ -f $NODES ] && grep -q 'dev/dma_heap' $NODES || echo 'lxc.mount.entry = /dev/dma_heap dev/dma_heap none bind,create=dir,optional 0 0' >> $NODES
[ -f $NODES ] && grep -q ' metadata ' $NODES || echo 'lxc.mount.entry = /var/lib/waydroid/metadata metadata none bind,create=dir,optional 0 0' >> $NODES
exit 0
EOF
chmod 0755 /etc/local.d/alpindroid-waydroid.start
rc-update add local default >/dev/null 2>&1 || true
echo "  boot hook: /etc/local.d/alpindroid-waydroid.start"

# ------------------------------------------------------------- 5. container up
say "5/7 container daemon + network"
rc-service waydroid-container restart >/dev/null 2>&1 || rc-service waydroid-container start
sleep 3
/usr/lib/waydroid/data/scripts/waydroid-net.sh start >/dev/null 2>&1 || true
ip -br link show waydroid0 2>/dev/null || echo "  WARN waydroid0 bridge missing"

# ------------------------------------------------------------- 6. sanity check
say "6/7 sanity"
status

# --------------------------------------------------------------- 7. next steps
say "7/7 done"
cat <<EOF
Start the Android UI as $DESKTOP_USER (needs a running Weston session):

  export XDG_RUNTIME_DIR=/run/user/$UID_NUM
  export WAYLAND_DISPLAY=wayland-0
  dbus-run-session -- sh -c 'waydroid session start &'
  sleep 20
  waydroid show-full-ui

Notes
  * the container is started on demand by the session; 'waydroid status' shows
    Session: RUNNING and Container: RUNNING once it is up;
  * IPv6 in the container is not configured (ip6tables tables are missing from
    this kernel), Android logs netd errors for it but continues;
  * no PulseAudio on the board -> Android audio is silent for now.
EOF
