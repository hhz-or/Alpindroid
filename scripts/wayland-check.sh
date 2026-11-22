#!/bin/sh
# ============================================================================
# Alpindroid: Wayland/GPU/touch acceptance checks (run on the board)
#
# Verifies the three v0.19 acceptance points:
#   1. HDMI output   - sun4i-drm card0 is connected, enabled and driven by Weston
#   2. GPU rendering - Weston uses the GL renderer on Panfrost (renderD128),
#                      not llvmpipe/softpipe and not the pixman compositor
#   3. Touch input   - generic USB HID multi-touch (hid_multitouch, MT-B,
#                      INPUT_PROP_DIRECT) is visible to libinput and bound to
#                      the HDMI output via the WL_OUTPUT udev property
#
# Usage (as the desktop user that runs Weston):
#   sh wayland-check.sh              # static checks only
#   sh wayland-check.sh --client     # also run weston-simple-egl for 4 s
#   sh wayland-check.sh --dmabuf     # also run weston-simple-dmabuf-egl
#   sh wayland-check.sh --touch      # touch the panel while capturing raw events
#   sh wayland-check.sh --touch=15   # same, 15 s window
#
# Exit code: 0 = all checks passed, 1 = at least one failure.
# ============================================================================
set -u

WESTON_LOG="${WESTON_LOG:-/tmp/weston.log}"
DRM_CARD="${DRM_CARD:-card0}"
if [ -z "${OUTPUT_NAME:-}" ]; then
    for status in /sys/class/drm/"$DRM_CARD"-*/status; do
        [ -r "$status" ] && [ "$(cat "$status")" = connected ] || continue
        connector=${status%/status}
        OUTPUT_NAME=${connector##*/"$DRM_CARD"-}
        break
    done
fi
OUTPUT_NAME=${OUTPUT_NAME:-HDMI-A-1}
RUN_CLIENT=0
RUN_DMABUF=0
RUN_TOUCH=0
TOUCH_SECS=6

for arg in "$@"; do
    case "$arg" in
        --client) RUN_CLIENT=1 ;;
        --dmabuf) RUN_DMABUF=1 ;;
        --touch) RUN_TOUCH=1 ;;
        --touch=*) RUN_TOUCH=1; TOUCH_SECS="${arg#--touch=}" ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }
head2() { printf '\n=== %s ===\n' "$*"; }

xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR="$xdg"

# ---------------------------------------------------------------- 1. HDMI / DRM
head2 "1. HDMI output (sun4i-drm, /dev/dri/$DRM_CARD)"

[ -e "/dev/dri/$DRM_CARD" ] && ok "/dev/dri/$DRM_CARD present" || bad "/dev/dri/$DRM_CARD missing"
card_sys="/sys/class/drm/$DRM_CARD-$OUTPUT_NAME"
if [ -d "$card_sys" ]; then
    st=$(cat "$card_sys/status" 2>/dev/null)
    en=$(cat "$card_sys/enabled" 2>/dev/null)
    [ "$st" = connected ] && ok "$OUTPUT_NAME connector: connected" || bad "$OUTPUT_NAME connector: ${st:-unknown}"
    [ "$en" = enabled ] && ok "$OUTPUT_NAME enabled (modeset done)" || bad "$OUTPUT_NAME enabled=${en:-unknown}"
    info "modes: $(head -n 1 "$card_sys/modes" 2>/dev/null) (preferred)"
else
    bad "no $DRM_CARD-$OUTPUT_NAME in /sys/class/drm"
fi

# ---------------------------------------------------------------- 2. compositor
head2 "2. Weston compositor"

if weston_pids=$(pidof weston); then
    ok "weston running (pid $weston_pids)"
else
    bad "weston not running (start it with scripts/start-weston.sh)"
fi

[ -S "$xdg/wayland-0" ] && ok "wayland socket: $xdg/wayland-0" || bad "no wayland socket in $xdg"

if [ -f "$WESTON_LOG" ]; then
    grep -q "GL renderer: Mali-G31" "$WESTON_LOG" \
        && ok "log: GL renderer Mali-G31 (Panfrost)" \
        || bad "log: no 'GL renderer: Mali-G31' line"
    grep -q "Using rendering device: /dev/dri/renderD128" "$WESTON_LOG" \
        && ok "log: renders on renderD128 (Panfrost node)" \
        || bad "log: not using renderD128"
    grep -q "Using GL renderer" "$WESTON_LOG" \
        && ok "log: GL renderer active (not pixman)" \
        || bad "log: GL renderer not active"
    grep -q "Output '$OUTPUT_NAME' enabled" "$WESTON_LOG" \
        && ok "log: output $OUTPUT_NAME enabled" \
        || bad "log: output $OUTPUT_NAME not enabled"
    if grep -qE 'llvmpipe|softpipe' "$WESTON_LOG"; then
        bad "log: software rasterizer mentioned (llvmpipe/softpipe)"
    else
        ok "log: no llvmpipe/softpipe"
    fi
    if grep -q "libseat: session control granted" "$WESTON_LOG"; then
        ok "log: seatd session granted"
    else
        warn "log: no libseat grant line"
    fi
else
    bad "weston log $WESTON_LOG missing"
fi

# ---------------------------------------------------------------- 3. GPU stack
head2 "3. GPU (Mesa / Panfrost)"

[ -e /dev/dri/renderD128 ] && ok "/dev/dri/renderD128 present" || bad "/dev/dri/renderD128 missing"
if [ -f /sys/class/drm/card1/device/uevent ] && grep -qi panfrost /sys/class/drm/card1/device/uevent 2>/dev/null; then
    ok "card1 is the Panfrost DRM device"
elif [ -d /sys/class/drm/card1 ]; then
    warn "card1 exists but could not confirm panfrost in uevent"
fi
if command -v eglinfo >/dev/null 2>&1; then
    eglinfo 2>/dev/null | grep -q "Mali-G31" && ok "eglinfo: Mali-G31 renderer" || warn "eglinfo: Mali-G31 not reported"
else
    warn "eglinfo not installed (mesa-utils)"
fi

# ---------------------------------------------------------------- 4. touch input
head2 "4. Touch input (generic HID multi-touch)"

if grep -q '^hid_multitouch' /proc/modules 2>/dev/null || grep -qx 'hid_multitouch' /etc/modules 2>/dev/null; then
    ok "hid_multitouch loaded / configured"
else
    bad "hid_multitouch not loaded and not in /etc/modules"
fi

touch_found=0
node=""
for ev in /dev/input/event*; do
    [ -e "$ev" ] || continue
    info_line=$(udevadm info "$ev" 2>/dev/null)
    case "$info_line" in
        *ID_INPUT_TOUCHSCREEN=1*)
            touch_found=$((touch_found + 1))
            [ -n "$node" ] || node="$ev"
            name=$(printf '%s\n' "$info_line" | sed -n 's/^E: ID_MODEL=//p' | head -n 1)
            wl=$(printf '%s\n' "$info_line" | sed -n 's/^E: WL_OUTPUT=//p' | head -n 1)
            ok "touchscreen: $ev ($name)"
            [ "$wl" = "$OUTPUT_NAME" ] && ok "  WL_OUTPUT=$wl" || bad "  WL_OUTPUT=${wl:-unset}, expected $OUTPUT_NAME"
            # weston --log appends across restarts. An older successful
            # association must not mask a failed boot in the latest session.
            if [ -r "$WESTON_LOG" ]; then
                if awk -v dev="${ev##*/}" -v out="$OUTPUT_NAME" '
                    /Command line:/ { associated = 0 }
                    index($0, "associating input device " dev " with output ") {
                        associated = index($0, "with output " out " (" out " by udev)") > 0
                    }
                    END { exit !associated }
                ' "$WESTON_LOG"; then
                    ok "  Weston associated ${ev##*/} with $OUTPUT_NAME"
                else
                    bad "  no matching Weston association for ${ev##*/} in latest session"
                fi
            fi
            dev=/sys/class/input/$(basename "$ev")/device
            props=$(cat "$dev/properties" 2>/dev/null)
            [ "$props" = "2" ] && ok "  INPUT_PROP_DIRECT (properties=$props)" || warn "  properties=$props (expected 2 = DIRECT)"
            abs=$(cat "$dev/capabilities/abs" 2>/dev/null)
            case "$abs" in
                *260800000000003*) ok "  MT-B abs capabilities (slot + position)" ;;
                *) [ -n "$abs" ] && info "  abs=$abs" ;;
            esac
            ;;
    esac
done
[ "$touch_found" -gt 0 ] || bad "no touchscreen found via udev (ID_INPUT_TOUCHSCREEN)"

if [ -x /usr/bin/weston-touch-calibrator ] || command -v weston-touch-calibrator >/dev/null 2>&1; then
    info "calibration helper available: weston-touch-calibrator (run if touch coordinates are off)"
fi

# ---------------------------------------------------------------- 5. rendering
if [ "$RUN_CLIENT" -eq 1 ]; then
    head2 "5. Rendering client (weston-simple-egl)"
    if ! command -v weston-simple-egl >/dev/null 2>&1; then
        warn "weston-simple-egl not installed (weston-clients)"
    else
        out=$(timeout 6 weston-simple-egl 2>&1) || true
        printf '%s\n' "$out" | sed 's/^/  | /'
        printf '%s\n' "$out" | grep -q "Using config" \
            && ok "weston-simple-egl created an EGL window" \
            || bad "weston-simple-egl did not report a config"
    fi
fi

if [ "$RUN_DMABUF" -eq 1 ]; then
    head2 "6. dmabuf client (Waydroid-critical path)"
    if ! command -v weston-simple-dmabuf-egl >/dev/null 2>&1; then
        warn "weston-simple-dmabuf-egl not installed (weston-clients)"
    else
        out=$(timeout 6 weston-simple-dmabuf-egl 2>&1) || true
        printf '%s\n' "$out" | sed 's/^/  | /'
        if printf '%s\n' "$out" | grep -qiE 'error|failed'; then
            bad "weston-simple-dmabuf-egl reported an error"
        else
            ok "weston-simple-dmabuf-egl ran without error"
        fi
    fi
fi

if [ "$RUN_TOUCH" -eq 1 ]; then
    head2 "7. Touch events (live capture, ${TOUCH_SECS}s)"
    if [ -z "$node" ]; then
        bad "no touchscreen node identified by udev"
    elif [ ! -r "$node" ]; then
        bad "$node is not readable by $(id -un); re-run with sudo for the live capture"
    else
        printf '  TOUCH THE SCREEN NOW (%ss) ...\n' "$TOUCH_SECS"
        bytes=$(timeout "$TOUCH_SECS" dd if="$node" bs=24 count=2000 2>/dev/null | wc -c)
        bytes=${bytes:-0}
        if [ "$bytes" -gt 0 ]; then
            ok "touch events received: ${bytes} bytes ($((bytes / 24)) events) from $node"
        else
            bad "no touch events from $node within ${TOUCH_SECS}s"
        fi
    fi
fi

# ---------------------------------------------------------------- summary
printf '\n=== summary ===\n'
printf '  PASS %d   FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    printf '  RESULT: PASS\n'
    exit 0
fi
printf '  RESULT: FAIL\n'
exit 1
