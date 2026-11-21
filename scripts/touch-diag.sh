#!/bin/sh
# ============================================================================
# Alpindroid: touchscreen diagnostic (read-only)
#
# Works both on Alpindroid and on the vendor Debian 12 image, so the two can be
# compared directly. Answers three questions:
#   1. is a touch device present and which driver took it?
#   2. does the kernel expose it as a proper touchscreen (MT-B, PROP_DIRECT)?
#   3. does the device actually report anything when a finger touches the panel?
#
# Usage:
#   sh touch-diag.sh                # static report
#   sudo sh touch-diag.sh --live 20 # also read raw events for 20 s (touch then)
#
# The --live part needs root: it opens /dev/input/event* directly.
# ============================================================================
set -u

LIVE=0
SECS=15
while [ $# -gt 0 ]; do
    case "$1" in
        --live)
            LIVE=1
            if [ $# -gt 1 ]; then
                case "$2" in
                    [0-9]*) SECS="$2"; shift ;;
                esac
            fi
            ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

sec() { printf '\n=== %s ===\n' "$*"; }

sec "1. system"
[ -e /proc/device-tree/model ] && { cat /proc/device-tree/model | tr -d '\0'; echo; }
uname -a
if [ -f /etc/os-release ]; then
    grep -E '^PRETTY_NAME=' /etc/os-release
elif [ -f /etc/alpine-release ]; then
    printf 'Alpine %s\n' "$(cat /etc/alpine-release)"
fi

sec "2. USB devices"
if command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -viE 'root hub|host controller'
else
    for d in /sys/bus/usb/devices/*/product; do
        [ -e "$d" ] || continue
        printf '  %s: %s\n' "$(basename "$(dirname "$d")")" "$(cat "$d" 2>/dev/null)"
    done
fi

sec "3. HID interfaces and their driver"
for h in /sys/class/hidraw/hidraw*; do
    [ -e "$h/device/uevent" ] || continue
    name=$(sed -n 's/^HID_NAME=//p' "$h/device/uevent")
    id=$(sed -n 's/^HID_ID=//p' "$h/device/uevent")
    drv=$(basename "$(readlink -f "$h/device/driver" 2>/dev/null)" 2>/dev/null)
    printf '  %-10s id=%s  %s  driver=%s\n' "$(basename "$h")" "$id" "$name" "${drv:-none}"
done

sec "4. input nodes (props=2 means INPUT_PROP_DIRECT, i.e. a touchscreen)"
for e in /sys/class/input/event*; do
    [ -e "$e" ] || continue
    printf '  %-10s props=%-3s name=%s\n' "$(basename "$e")" \
        "$(cat "$e/device/properties" 2>/dev/null)" \
        "$(cat "$e/device/name" 2>/dev/null)"
    printf '             abs=%s\n' "$(cat "$e/device/capabilities/abs" 2>/dev/null)"
done

sec "5. udev tags"
if command -v udevadm >/dev/null 2>&1; then
    for e in /dev/input/event*; do
        [ -e "$e" ] || continue
        info=$(udevadm info "$e" 2>/dev/null) || continue
        case "$info" in
            *ID_INPUT_TOUCHSCREEN=1*)
                printf '  %s: ID_INPUT_TOUCHSCREEN=1' "$e"
                wl=$(printf '%s\n' "$info" | sed -n 's/^E: WL_OUTPUT=//p' | head -n 1)
                [ -n "$wl" ] && printf '  WL_OUTPUT=%s' "$wl"
                printf '\n'
                ;;
        esac
    done
else
    echo "  (udevadm not available)"
fi

sec "6. modules"
grep -iE 'hid_multitouch|usbtouchscreen|usbhid|hid_generic' /proc/modules 2>/dev/null ||
    echo "  (none of them loaded)"
ls /etc/modules-load.d/*.conf 2>/dev/null

sec "7. dmesg: touch + usb resets"
dmesg 2>/dev/null | grep -iE 'multitouch|touchscreen|222A|hid-generic.*222A|usb [0-9]+-[0-9.]+: reset|USB disconnect' | tail -n 25

if [ "$LIVE" -eq 1 ]; then
    sec "8. live capture (${SECS}s) -- TOUCH THE SCREEN NOW"
    node=""
    for e in /sys/class/input/event*; do
        if [ "$(cat "$e/device/properties" 2>/dev/null)" = "2" ]; then
            node="/dev/input/$(basename "$e")"
        fi
    done
    if [ -z "$node" ]; then
        echo "  no touchscreen node (properties=2) found"
    else
        echo "  capturing $node for up to ${SECS}s ..."
        out=$(timeout "$SECS" dd if="$node" bs=24 count=6 2>/dev/null | od -An -tx1)
        if [ -z "$out" ]; then
            echo "  RESULT: no input events at all -- the kernel sees nothing from this device"
        else
            echo "  RESULT: events received:"
            printf '%s\n' "$out" | sed 's/^/    /'
        fi
        [ "$(id -u)" -ne 0 ] && echo "  NOTE: run as root, otherwise the read is refused"
    fi
fi

sec "done"
