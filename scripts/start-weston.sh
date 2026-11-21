#!/bin/sh
# ============================================================================
# Alpindroid: start Weston 14 on the HDMI head (development mode)
#
# Runs as the desktop user (NOT root): Weston talks to seatd over
# /run/seatd.sock, seatd opens /dev/dri/card0 and /dev/input/event* on its
# behalf. Starting as root bypasses that path and hides seatd problems.
#
# Defaults: DRM backend on card0 (sun4i-drm HDMI), GL renderer on the Panfrost
# node (renderD128), socket wayland-0, log /tmp/weston.log.
#
# Usage:
#   sh start-weston.sh                 # foreground, Ctrl-C to stop
#   sh start-weston.sh -b              # background (setsid), returns at once
#   sh start-weston.sh -b -D           # background + "weston --debug"
#                                      # (input/touch events land in the log)
#   sh start-weston.sh -p pixman       # software fallback, for comparison
#   sh start-weston.sh -c /path/weston.ini
#
# Environment:
#   XDG_RUNTIME_DIR   defaults to /run/user/$(id -u)
#   LIBSEAT_BACKEND   forced to seatd here
#   DRM_DEVICE        defaults to card0  (card1 is Panfrost, no scanout)
#   RENDERER          defaults to gl
#   WESTON_LOG        defaults to /tmp/weston.log
# ============================================================================
set -e

BACKGROUND=0
DEBUG=0
DRM_DEVICE="${DRM_DEVICE:-card0}"
RENDERER="${RENDERER:-gl}"
SOCKET="${SOCKET:-wayland-0}"
LOG="${WESTON_LOG:-/tmp/weston.log}"
CONFIG=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while getopts "bd:r:l:c:p:s:hD" opt; do
    case "$opt" in
        b) BACKGROUND=1 ;;
        d) DRM_DEVICE="$OPTARG" ;;
        r) RENDERER="$OPTARG" ;;
        p) RENDERER="$OPTARG" ;;
        l) LOG="$OPTARG" ;;
        s) SOCKET="$OPTARG" ;;
        c) CONFIG="$OPTARG" ;;
        D) DEBUG=1 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
EXTRA="$*"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as the desktop user, not root (use sudo -u <user>)"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -d "$XDG_RUNTIME_DIR" ] || die "$XDG_RUNTIME_DIR is missing; run install-wayland-stack.sh as root first"
export XDG_RUNTIME_DIR
export LIBSEAT_BACKEND=seatd

# seatd reachable? (group membership matters, not just the socket)
if [ -S /run/seatd.sock ]; then
    [ -w /run/seatd.sock ] || die "/run/seatd.sock not writable by $(id -un) (missing seat group? re-login after addgroup)"
else
    die "/run/seatd.sock missing; is seatd running? (rc-service seatd status)"
fi

# the DRM node must exist before Weston starts, otherwise the backend aborts
[ -e "/dev/dri/$DRM_DEVICE" ] || die "/dev/dri/$DRM_DEVICE not found"

set -- --backend=drm --drm-device="$DRM_DEVICE" --renderer="$RENDERER" \
       --socket="$SOCKET" --log="$LOG"
if [ -n "$CONFIG" ]; then
    set -- "$@" --config="$CONFIG"
fi
if [ "$DEBUG" -eq 1 ]; then
    set -- "$@" --debug
fi
if [ -n "$EXTRA" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $EXTRA
fi

echo "weston: device=$DRM_DEVICE renderer=$RENDERER socket=$SOCKET"
echo "weston: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR LIBSEAT_BACKEND=seatd"
echo "weston: log=$LOG"

if [ "$BACKGROUND" -eq 1 ]; then
    setsid weston "$@" </dev/null >/dev/null 2>&1 &
    sleep 3
    if pgrep -x weston >/dev/null 2>&1; then
        echo "weston: running (pgrep -a weston)"
        echo "weston: tail -n 40 $LOG"
    else
        echo "weston: FAILED, see $LOG" >&2
        [ -f "$LOG" ] && tail -n 30 "$LOG" >&2
        exit 1
    fi
else
    exec weston "$@"
fi
