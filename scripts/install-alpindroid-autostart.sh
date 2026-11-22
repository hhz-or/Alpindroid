#!/bin/sh
# ============================================================================
# Alpindroid: enable/disable the desktop autostart (Weston + Waydroid on HDMI)
#
# A fresh boot leaves a text console on tty0. This installs one OpenRC service
# that brings the graphics stack up in the right order while keeping SSH usable
# if anything fails:
#
#   seatd, dbus -> weston (kiosk-shell, as the desktop user, via seatd)
#               -> waydroid container + waydroid0 bridge
#               -> waydroid session (inside its own dbus-run-session)
#               -> alpindroid-show-ui: waits for sys.boot_completed=1, then
#                  runs show-full-ui
#
# weston runs with --shell=kiosk on purpose. Waydroid's hwcomposer creates one
# full-output wayland surface with no desktop-window semantics; under the default
# desktop-shell it is never mapped and HDMI stays grey. kiosk-shell maps every
# surface to the whole output, which is what a single full-screen Android wants.
#
# Every stage is best-effort: a broken compositor must never take SSH or the
# network down, and `rc-service alpindroid-desktop stop` returns to text.
#
# Usage (as root on the board):
#   sh install-alpindroid-autostart.sh                 install + enable + start
#   sh install-alpindroid-autostart.sh --install-only  install + enable, no start
#   sh install-alpindroid-autostart.sh --disable       disable + stop
#   sh install-alpindroid-autostart.sh --status        report
# ============================================================================
set -u

DESKTOP_USER="${DESKTOP_USER:-alpine}"
SERVICE=/etc/init.d/alpindroid-desktop
WESTON_WRAPPER=/usr/local/sbin/alpindroid-weston
SHOWUI=/usr/local/sbin/alpindroid-show-ui

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
UID_NUM=$(id -u "$DESKTOP_USER" 2>/dev/null) || die "no such user: $DESKTOP_USER"

# --------------------------------------------------------------------- pieces
install_weston_wrapper() {
    cat > "$WESTON_WRAPPER" <<'WESTON'
#!/bin/sh
# Weston launcher for the alpindroid-desktop service: start-stop-daemon cannot
# set environment variables, and weston needs both of these.
UID_NUM="${1:-$(id -u)}"
export XDG_RUNTIME_DIR="/run/user/$UID_NUM"
export LIBSEAT_BACKEND=seatd
# kiosk-shell: Waydroid's hwcomposer creates a full-screen surface without a
# desktop-style window; under desktop-shell it stays invisible.
exec /usr/bin/weston --backend=drm --drm-device=card0 --renderer=gl \
    --shell=kiosk --socket=wayland-0 --log=/tmp/weston.log
WESTON
    chmod 0755 "$WESTON_WRAPPER"
}

install_show_ui() {
    cat > "$SHOWUI" <<'SHOWUI_EOF'
#!/bin/sh
# Bring the Android UI up on top of the compositor and keep it alive.
#
# Two things this must never do:
#   * call lxc-attach while the container is FROZEN - it blocks forever, which
#     is what previously deadlocked the whole startup;
#   * assume a single show-full-ui is enough - waydroid refreezes the container
#     whenever nothing consumes the UI, so we re-check with lxc-info (which only
#     reads state and never blocks) and unfreeze again.
UID_NUM="${1:-$(id -u)}"
export XDG_RUNTIME_DIR="/run/user/$UID_NUM"
export WAYLAND_DISPLAY=wayland-0
LXC_POOL=/var/lib/waydroid/lxc
LXC_NAME=waydroid

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> /tmp/alpindroid-show-ui.log; }

session_bus() {
    pid=$(pgrep -f 'waydroid session start' | head -n 1)
    if [ -z "$pid" ]; then
        return 1
    fi
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p'
}

container_state() { lxc-info -P "$LXC_POOL" -n "$LXC_NAME" -sH 2>/dev/null; }

show_ui() {
    lxc-unfreeze -P "$LXC_POOL" -n "$LXC_NAME" >/dev/null 2>&1
    bus=$(session_bus)
    if [ -n "$bus" ]; then
        DBUS_SESSION_BUS_ADDRESS="$bus" timeout 30 waydroid show-full-ui >/dev/null 2>&1
    fi
}

# 1) wait for the session (waydroid status never blocks)
i=0
while [ "$i" -lt 120 ]; do
    if waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
        break
    fi
    i=$((i + 1))
    sleep 2
done
if ! waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
    log "session never reached RUNNING"
    exit 1
fi
log "session RUNNING"

# 2) unfreeze + show-full-ui until the container stays RUNNING
i=0
while [ "$i" -lt 40 ]; do
    show_ui
    sleep 6
    state=$(container_state)
    if [ "$state" = "RUNNING" ]; then
        log "android UI up (container RUNNING after $i attempt(s))"
        break
    fi
    i=$((i + 1))
done

# 3) guardian: waydroid freezes the container whenever nobody consumes the UI
while :; do
    sleep 15
    state=$(container_state)
    if [ "$state" = "FROZEN" ]; then
        log "container frozen again; unfreezing"
        show_ui
    fi
done
SHOWUI_EOF
    chmod 0755 "$SHOWUI"
}

install_service() {
    cat > "$SERVICE" <<'INITD'
#!/sbin/openrc-run
# Alpindroid desktop autostart: Weston (kiosk-shell, DRM/GL) + Waydroid on HDMI.
# Generated by install-alpindroid-autostart.sh — edit that script, not this.

description="Alpindroid desktop (Weston + Waydroid)"

depend() {
    need seatd dbus
    after waydroid-container
    want networkmanager
}

start() {
    ebegin "Starting Alpindroid desktop"
    UID_NUM=$(id -u "${DESKTOP_USER:-alpine}")
    RUNTIME="/run/user/$UID_NUM"

    # XDG_RUNTIME_DIR and the PulseAudio placeholder Waydroid's LXC config mounts
    mkdir -p "$RUNTIME/pulse"
    chown "$UID_NUM:$UID_NUM" "$RUNTIME"
    chmod 0700 "$RUNTIME"
    [ -f "$RUNTIME/pulse/native" ] || : > "$RUNTIME/pulse/native"
    chown "$UID_NUM:$UID_NUM" "$RUNTIME/pulse/native"

    # 1) Weston on card0, GL on renderD128, as the desktop user through seatd
    start-stop-daemon --start --background --make-pidfile \
        --pidfile /run/alpindroid-weston.pid \
        --user "${DESKTOP_USER:-alpine}" \
        --exec /usr/local/sbin/alpindroid-weston -- "$UID_NUM"

    i=0
    while [ "$i" -lt 24 ]; do
        [ -S "$RUNTIME/wayland-0" ] && break
        i=$((i + 1))
        sleep 0.5
    done
    if [ ! -S "$RUNTIME/wayland-0" ]; then
        ewarn "weston socket missing — see /tmp/weston.log"
        eend 1
        return 1
    fi

    # 2) waydroid container daemon + internal bridge.
    #    waydroid-container sits in the boot runlevel and thus comes up long
    #    before weston exists; its hwcomposer would try to connect to a wayland
    #    socket that is not there yet and then never retry, leaving a black
    #    screen. Restarting it now makes hwcomposer connect to the live socket.
    rc-service waydroid-container restart >/dev/null 2>&1
    /usr/lib/waydroid/data/scripts/waydroid-net.sh start >/dev/null 2>&1

    # 3) session in its own D-Bus session bus (waydroid cannot autolaunch one)
    start-stop-daemon --start --background --make-pidfile \
        --pidfile /run/alpindroid-waydroid-session.pid \
        --user "${DESKTOP_USER:-alpine}" \
        --exec /usr/bin/dbus-run-session -- \
        -- /bin/sh -c "XDG_RUNTIME_DIR=$RUNTIME WAYLAND_DISPLAY=wayland-0 waydroid session start"

    # 4) wait for Android, then show-full-ui (background helper)
    start-stop-daemon --start --background --make-pidfile \
        --pidfile /run/alpindroid-waydroid-ui.pid \
        --user "${DESKTOP_USER:-alpine}" \
        --exec /usr/local/sbin/alpindroid-show-ui -- "$UID_NUM"

    eend 0
}

stop() {
    ebegin "Stopping Alpindroid desktop"
    start-stop-daemon --stop --pidfile /run/alpindroid-waydroid-ui.pid --retry TERM/5 2>/dev/null
    start-stop-daemon --stop --pidfile /run/alpindroid-waydroid-session.pid --retry TERM/10 2>/dev/null
    start-stop-daemon --stop --pidfile /run/alpindroid-weston.pid --retry TERM/5 2>/dev/null
    rm -f /run/alpindroid-waydroid-ui.pid /run/alpindroid-waydroid-session.pid /run/alpindroid-weston.pid
    eend 0
}
INITD
    chmod 0755 "$SERVICE"
}

enable_service() {
    rc-update add alpindroid-desktop default 2>&1 | tail -n 1
}

status() {
    printf '\n=== service ===\n'
    rc-service alpindroid-desktop status 2>&1
    printf '\n=== default runlevel ===\n'
    rc-update show default 2>/dev/null | grep alpindroid-desktop || echo "  (not enabled)"
    printf '\n=== processes ===\n'
    pgrep -a weston | head -n 2
    pgrep -af 'waydroid session start' | head -n 2
    printf '\n=== waydroid ===\n'
    waydroid status 2>&1 | head -n 6
    printf '\n=== shell in use ===\n'
    grep -o 'shell=[a-z-]*' /usr/local/sbin/alpindroid-weston 2>/dev/null || echo "  (wrapper missing)"
    printf '\n=== ui log ===\n'
    tail -n 5 /tmp/alpindroid-show-ui.log 2>/dev/null || echo "  (none)"
}

# ---------------------------------------------------------------------- main
case "${1:-}" in
    --status)
        status
        exit 0
        ;;
    --install-only)
        # Used by the image build: install everything and enable the service,
        # but never try to start a compositor inside a chroot.
        say "installing pieces (no start)"
        install_weston_wrapper
        install_show_ui
        install_service
        enable_service
        exit 0
        ;;
    --disable)
        say "disabling autostart"
        rc-service alpindroid-desktop stop 2>&1 | tail -n 2
        rc-update del alpindroid-desktop default 2>&1 | tail -n 1
        exit 0
        ;;
esac

say "installing pieces"
install_weston_wrapper
install_show_ui
install_service
say "enabling in the default runlevel"
enable_service

say "starting now (a failure here leaves SSH and the text console intact)"
rc-service alpindroid-desktop restart 2>&1 | tail -n 3

say "done"
cat <<EOF
Control it with:
  rc-service alpindroid-desktop status|restart|stop
  rc-update del alpindroid-desktop default     # stop autostarting
  tail -f /tmp/weston.log /tmp/alpindroid-show-ui.log

Notes
  * weston runs with --shell=kiosk: Waydroid's hwcomposer surface has no window
    semantics, so desktop-shell would leave HDMI grey;
  * weston runs as $DESKTOP_USER through seatd, so seatd must be in the boot
    runlevel and the user must be in the seat group;
  * a failure at any stage keeps the text console and SSH working.
EOF
