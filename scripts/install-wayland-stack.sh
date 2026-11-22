#!/bin/sh
# ============================================================================
# Alpindroid: install the Wayland stack (Weston 14 + DRM backend + seatd)
#
# Runs on the board (or in a chroot of the target rootfs) as root. Idempotent:
# re-running it only fixes what is missing.
#
# The display and touch paths are both generic kernel interfaces:
#   * HDMI out  -> sun4i-drm, /dev/dri/card0 (KMS)
#   * GPU       -> Panfrost, /dev/dri/renderD128 (Mesa 25.2.7)
#   * Touch     -> USB HID multi-touch (OpenWare Multi-Touch-V5000, 222a:0001)
#                  driven by the in-kernel hid_multitouch module in MT-B mode,
#                  INPUT_PROP_DIRECT, handled by libinput. No vendor driver.
#
# Usage (on the board, as root):
#   sh install-wayland-stack.sh [desktop-user] [--install-only]
#     desktop-user defaults to "alpine"
#
# Optional environment:
#   WESTON_INI_SRC   path to config/weston.ini to install as
#                    /etc/xdg/weston/weston.ini (a built-in default is used if
#                    the file is absent and no weston.ini exists yet)
#   UDEV_RULE_SRC    path to config/udev/99-alpindroid-touch.rules
# ============================================================================
set -e

DESKTOP_USER="${1:-alpine}"
WESTON_INI_SRC="${WESTON_INI_SRC:-}"
UDEV_RULE_SRC="${UDEV_RULE_SRC:-}"
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)

INSTALL_ONLY=0
case "${2:-}" in
    --install-only) INSTALL_ONLY=1 ;;
    '') ;;
    *) echo "unknown option: $2" >&2; exit 2 ;;
esac

RUNTIME_DIR_INIT=/etc/local.d/alpindroid-runtime.start
TOUCH_RULE=/etc/udev/rules.d/99-alpindroid-touch.rules
WESTON_INI=/etc/xdg/weston/weston.ini

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
id "$DESKTOP_USER" >/dev/null 2>&1 || die "no such user: $DESKTOP_USER"
UID_NUM=$(id -u "$DESKTOP_USER")
GID_NUM=$(id -g "$DESKTOP_USER")

# ---------------------------------------------------------------- 1. packages
say "1/6 packages: weston + drm backend + seatd + libinput"
# Speed up the (slow) official CDN in CN; harmless elsewhere.
if grep -q 'dl-cdn.alpinelinux.org' /etc/apk/repositories 2>/dev/null; then
    echo "  switching to mirrors.aliyun.com"
    sed -i 's|https\?://dl-cdn.alpinelinux.org|https://mirrors.aliyun.com|' /etc/apk/repositories
fi
apk add --no-cache \
    weston \
    weston-backend-drm \
    weston-shell-desktop \
    weston-clients \
    weston-terminal \
    seatd \
    seatd-openrc \
    libinput-tools \
    adwaita-icon-theme

# ------------------------------------------------------- 2. generic touch path
say "2/6 kernel: hid_multitouch (generic HID multi-touch driver)"
# The module ships with our 6.1.31+ kernel (CONFIG_HID_MULTITOUCH=m) and udev
# autoloads it from the USB modalias the moment the device enumerates — the same
# way the vendor image does it. Do NOT add it to /etc/modules: that defers the
# load until after hid-generic has already bound the interface, forcing a rebind.
if [ "$INSTALL_ONLY" = 1 ]; then
    echo "  module autoloaded on the target"
elif modprobe hid_multitouch 2>/dev/null; then
    echo "  hid_multitouch loaded (udev autoloads it on hotplug as well)"
else
    echo "  WARN hid_multitouch not loadable (kernel module missing?)"
fi
if grep -qx 'hid_multitouch' /etc/modules 2>/dev/null; then
    echo "  NOTE hid_multitouch is listed in /etc/modules; the vendor image does not do that"
fi

# ---------------------------------------------------------------- 3. seatd
say "3/6 seatd service + seat group"
rc-update add seatd default >/dev/null 2>&1 || true
if [ "$INSTALL_ONLY" = 0 ]; then rc-service seatd start; fi
grep -q '^seat:' /etc/group || addgroup -S seat
addgroup "$DESKTOP_USER" seat >/dev/null 2>&1 || true
if [ "$INSTALL_ONLY" = 1 ]; then
    echo "  seatd enabled for first boot"
elif rc-service seatd status >/dev/null 2>&1; then
    echo "  seatd: started"
else
    echo "  WARN seatd is not running"
fi
echo "  $(grep '^seat:' /etc/group)"
echo "  socket: $(ls -l /run/seatd.sock 2>/dev/null || echo '(missing)')"

# ------------------------------------- 4. udev: touch -> the connected head
say "4/6 udev: bind touchscreens to the connected head (auto-detected)"
mkdir -p /etc/udev/rules.d
# Ship the adapter so the binding can be regenerated for any board/screen
# instead of hard-coding one connector name.
if [ -f "$SCRIPTDIR/wayland-adapt.sh" ]; then
    mkdir -p /usr/local/sbin
    install -m 0755 "$SCRIPTDIR/wayland-adapt.sh" /usr/local/sbin/wayland-adapt.sh
    echo "  installed /usr/local/sbin/wayland-adapt.sh"
fi
[ -x /usr/local/sbin/wayland-adapt.sh ] || die "wayland-adapt.sh is required"
# The image builder preinstalls the DRM hook. Also install it on live upgrades.
if [ -f "$SCRIPTDIR/alpindroid-hotplug.sh" ] && [ -f "$SCRIPTDIR/../config/udev/98-alpindroid-hotplug.rules" ]; then
    install -m 0755 "$SCRIPTDIR/alpindroid-hotplug.sh" /usr/local/sbin/alpindroid-hotplug
    install -m 0644 "$SCRIPTDIR/../config/udev/98-alpindroid-hotplug.rules" /etc/udev/rules.d/
fi
UDEV_RULE_SRC=${UDEV_RULE_SRC:-$SCRIPTDIR/../config/udev/99-alpindroid-touch.rules}
if [ -f "$UDEV_RULE_SRC" ]; then
    install -m 0644 "$UDEV_RULE_SRC" "$TOUCH_RULE"
elif ! grep -qF 'wayland-adapt.sh --output' "$TOUCH_RULE" 2>/dev/null; then
    die "missing touchscreen rule: $UDEV_RULE_SRC"
fi

# ---------------------------------------------------------------- 5. weston.ini
say "5/6 weston.ini"
mkdir -p /etc/xdg/weston
if [ -n "$WESTON_INI_SRC" ] && [ -f "$WESTON_INI_SRC" ]; then
    install -m 0644 "$WESTON_INI_SRC" "$WESTON_INI"
    echo "  installed $WESTON_INI_SRC -> $WESTON_INI"
elif [ -f "$WESTON_INI" ]; then
    echo "  keeping existing $WESTON_INI"
else
    cat > "$WESTON_INI" <<'EOF'
[core]
backend=drm
renderer=gl
shell=desktop
idle-time=0
require-input=false
require-outputs=none

[output]
name=HDMI-A-1
mode=preferred

[libinput]
enable-tap=true

[shell]
panel-position=bottom
EOF
    echo "  wrote default $WESTON_INI"
fi

# --------------------------------------------------- 6. XDG_RUNTIME_DIR for user
say "6/6 /run/user/$UID_NUM (survives a reboot)"
mkdir -p "/run/user/$UID_NUM"
chown "$UID_NUM:$GID_NUM" "/run/user/$UID_NUM"
chmod 0700 "/run/user/$UID_NUM"
mkdir -p /etc/local.d
cat > "$RUNTIME_DIR_INIT" <<EOF
#!/bin/sh
# Created by install-wayland-stack.sh for manual Weston launches. The desktop service prepares its own runtime.
mkdir -p /run/user/$UID_NUM
chown $UID_NUM:$GID_NUM /run/user/$UID_NUM
chmod 0700 /run/user/$UID_NUM
if [ ! -e /etc/runlevels/default/alpindroid-desktop ]; then
    exec /usr/local/sbin/wayland-adapt.sh
fi
EOF
chmod 0755 "$RUNTIME_DIR_INIT"
rc-update add local default >/dev/null 2>&1 || true
echo "  $RUNTIME_DIR_INIT"

if [ "$INSTALL_ONLY" = 0 ]; then
    /usr/local/sbin/wayland-adapt.sh
fi
say "done"
cat <<EOF
Next steps (as $DESKTOP_USER, not root):

  XDG_RUNTIME_DIR=/run/user/$UID_NUM LIBSEAT_BACKEND=seatd \\
      sh scripts/start-weston.sh

  sh scripts/wayland-check.sh          # acceptance checks

Notes
  * Reboot first if $DESKTOP_USER was just added to the seat group,
    otherwise libseat cannot open /run/seatd.sock.
  * Weston logs to /tmp/weston.log by default.
EOF
