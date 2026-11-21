#!/bin/sh
# ============================================================================
# Alpindroid: capture everything needed to explain why the Waydroid container
# exits. Three streams at once, plus a container-state timeline:
#
#   1. host kernel log      (rolling dmesg window, catches OOM/binder/init)
#   2. waydroid manager log (/var/lib/waydroid/waydroid.log, lifecycle + lxc)
#   3. Android logcat       (via lxc-attach, so it also works without a session
#                            bus; waydroid logcat would need DBUS_SESSION_BUS_*
#                            from the running session)
#   4. state.log            (timestamped lxc-info state, shows start/stop edges)
#
# Android does not write to the LXC console, so an empty lxc.console.logfile is
# expected and proves nothing — this script does not rely on it.
#
# Usage (as root on the board):
#   sh debug-waydroid.sh [seconds]      # default 120
#
# Exit state leaves the container untouched; it only reads.
# ============================================================================
set -u

DURATION="${1:-120}"
OUT="/root/waydroid-debug-$(date +%Y%m%d-%H%M%S)"
LXC_P="-P /var/lib/waydroid/lxc"
LXC_N="-n waydroid"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$OUT"

echo "capture dir : $OUT"
echo "duration    : ${DURATION}s"
echo
echo "Arm now, then start the session in another shell:"
echo "  dbus-run-session -- sh -c 'waydroid session start'"
echo

# ---- static context
cp /var/lib/waydroid/lxc/waydroid/config       "$OUT/lxc-config"        2>/dev/null
cp /var/lib/waydroid/lxc/waydroid/config_nodes "$OUT/lxc-config_nodes"  2>/dev/null
cp /var/lib/waydroid/lxc/waydroid/config_session "$OUT/lxc-config_session" 2>/dev/null
cp /var/lib/waydroid/waydroid.cfg              "$OUT/waydroid.cfg"      2>/dev/null
cp /var/lib/waydroid/waydroid.prop             "$OUT/waydroid.prop"     2>/dev/null
dmesg > "$OUT/kernel-before.log" 2>&1
free -m > "$OUT/memory-before.log" 2>&1
ls -l /dev/dma_heap/ > "$OUT/dma_heap.log" 2>&1

# ---- 1. host kernel: rolling window, busybox dmesg has no reliable -w
(
    while :; do
        printf '===== %s -----\n' "$(date '+%H:%M:%S')"
        dmesg 2>/dev/null | tail -n60
        sleep 2
    done
) > "$OUT/kernel.log" 2>&1 &
KP=$!

# ---- 2. manager log
if [ -f /var/lib/waydroid/waydroid.log ]; then
    tail -n40 -f /var/lib/waydroid/waydroid.log > "$OUT/manager.log" 2>&1 &
    MP=$!
else
    : > "$OUT/manager.log"
    MP=0
fi

# ---- 3+4. container state timeline and Android logcat
(
    attached=0
    while :; do
        ST=$(lxc-info $LXC_P $LXC_N -sH 2>/dev/null || true)
        printf '%s | %s\n' "$(date '+%H:%M:%S')" "${ST:-unknown}" >> "$OUT/state.log"

        if [ "$ST" = "RUNNING" ] && [ "$attached" -eq 0 ]; then
            attached=1
            # rc = 0: hook (which creates waydroid) was installed by installer (idempotent, no re-download)
            lxc-attach $LXC_P $LXC_N -- /system/bin/logcat >> "$OUT/android.log" 2>> "$OUT/android-errors.log"
            printf '%s | logcat exited (container still %s)\n' \
                "$(date '+%H:%M:%S')" \
                "$(lxc-info $LXC_P $LXC_N -sH 2>/dev/null || echo gone)" >> "$OUT/state.log"
            attached=0
        fi
        sleep 1
    done
) &
LP=$!

cleanup() {
    kill "$KP" 2>/dev/null
    [ "$MP" != "0" ] && kill "$MP" 2>/dev/null
    kill "$LP" 2>/dev/null
    dmesg > "$OUT/kernel-after.log" 2>&1
    free -m > "$OUT/memory-after.log" 2>&1
    lxc-info $LXC_P $LXC_N -sH > "$OUT/state-final.log" 2>&1
    printf '\n=== saved ===\n%s\n' "$OUT"
    printf 'files:\n'
    for f in state.log android.log kernel.log manager.log; do
        [ -f "$OUT/$f" ] && printf '  %-14s %s lines\n' "$f" "$(wc -l < "$OUT/$f")"
    done
    printf '\nanalyse with:\n'
    printf "  sh %s/analyse-waydroid.sh %s\n" "$(dirname "$0")" "$OUT"
}
trap cleanup EXIT INT TERM

sleep "$DURATION"
