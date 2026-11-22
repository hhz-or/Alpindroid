#!/bin/sh
# Resolve the head on the same KMS card as alpindroid-weston. udev calls
# --output for each touchscreen, including USB devices added after boot.
set -eu

connected_output() {
    for status in /sys/class/drm/card0-*/status; do
        [ -r "$status" ] || continue
        read -r state < "$status" || continue
        [ "$state" = connected ] || continue
        connector=${status%/status}
        printf '%s\n' "${connector##*/card0-}"
        return 0
    done
    return 1
}

# HDMI-A-1 is the board's physical port, including before EDID is ready.
output=$(connected_output) || output=HDMI-A-1
case "${1:-}" in
    --output) printf '%s\n' "$output"; exit 0 ;;
    '') ;;
    *) echo "usage: $0 [--output]" >&2; exit 2 ;;
esac

# The image has one managed [output] section. Preserve custom multi-head
# configurations. Weston reads this file on launch.
ini=/etc/xdg/weston/weston.ini
if [ -f "$ini" ] && [ "$(grep -cxF '[output]' "$ini")" = 1 ]; then
    tmp=$(mktemp "$ini.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cp -p "$ini" "$tmp"
    awk -v out="$output" '
        /^\[/ { section = ($0 == "[output]") }
        section && /^name=/ { print "name=" out; next }
        { print }
    ' "$ini" > "$tmp"
    cmp -s "$ini" "$tmp" || mv "$tmp" "$ini"
fi

# 'trigger' only queues events. Wait for eudev and check what libinput
# will actually read. Devices arriving later run the same rule on add.
udevadm control --reload
udevadm trigger --subsystem-match=input --sysname-match='event*' --action=change
udevadm settle --timeout=8
output=$(connected_output) || output=HDMI-A-1
count=0
for ev in /dev/input/event*; do
    [ -e "$ev" ] || continue
    if ! props=$(udevadm info -q property "$ev"); then
        [ ! -e "$ev" ] && continue
        echo "$ev: cannot read udev properties" >&2
        exit 1
    fi
    printf '%s\n' "$props" | grep -qxF ID_INPUT_TOUCHSCREEN=1 || continue
    bound=$(printf '%s\n' "$props" | sed -n 's/^WL_OUTPUT=//p')
    echo "$ev: WL_OUTPUT=${bound:-unset}, expected $output"
    [ "$bound" = "$output" ] || exit 1
    count=$((count + 1))
done
[ "$count" -gt 0 ] || echo "No touchscreen enumerated yet; udev will bind it on add."
