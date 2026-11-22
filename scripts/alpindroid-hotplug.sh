#!/bin/sh
# Called by a DRM change event. Queue input events and return immediately:
# waiting for udev to settle inside its own worker would wait on this event.
set -eu
output=$(/usr/local/sbin/wayland-adapt.sh --output)
[ "$(cat "/sys/class/drm/card0-$output/status" 2>/dev/null)" = connected ] || exit 0
for event in /sys/class/input/event*; do
    [ -e "$event" ] || continue
    props=$(udevadm info -q property -p "$event") || continue
    printf '%s\n' "$props" | grep -qxF ID_INPUT_TOUCHSCREEN=1 || continue
    printf '%s\n' "$props" | grep -qxF "WL_OUTPUT=$output" && continue
    # libinput reads WL_OUTPUT at device add. Re-enumerate only panels
    # whose mapping changed, leaving keyboards, pointers and Android up.
    printf 'remove\n' > "$event/uevent"
    printf 'add\n' > "$event/uevent"
    logger -t alpindroid-hotplug "${event##*/}: rebind to $output"
done
