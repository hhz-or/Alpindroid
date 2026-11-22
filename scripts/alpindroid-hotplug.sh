#!/bin/sh
# ============================================================================
# Alpindroid: udev RUN+ helper for DRM connector changes
#
# udev kills RUN+ programs after a short timeout and expects them to block, so
# this wrapper does the real work detached: re-detect the connected head and
# rewrite the touchscreen's WL_OUTPUT binding, plus weston.ini's [output] name.
#
# Installed by the image build; triggered by
# /etc/udev/rules.d/98-alpindroid-hotplug.rules on every DRM change event.
# ============================================================================
LOG=/tmp/alpindroid-hotplug.log

printf '%s hotplug event: ' "$(date '+%F %T')" >> "$LOG"
for d in /sys/class/drm/card*-*/status; do
    [ -f "$d" ] || continue
    printf '%s=%s ' "$(basename "$(dirname "$d")")" "$(cat "$d" 2>/dev/null)" >> "$LOG"
done
printf '\n' >> "$LOG"

# detach so udev does not wait for it
setsid /usr/local/sbin/wayland-adapt.sh >> "$LOG" 2>&1 &

exit 0
