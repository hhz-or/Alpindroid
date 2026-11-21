#!/bin/sh
# ============================================================================
# Alpindroid: analyse a debug-waydroid.sh capture
#
# Usage:
#   sh analyse-waydroid.sh /root/waydroid-debug-20261122-021500
#   sh analyse-waydroid.sh                 # newest capture under /root
#
# Prints, in order:
#   1. the container state timeline (start/stop edges)
#   2. who asked for a shutdown/reboot (Android init, sys.powerctl, LXC stop)
#   3. critical service failures and crashes
#   4. memory pressure / OOM kills
#   5. graphics / allocator / cgroup complaints
#   6. the last Android / manager / kernel lines before the container went away
# ============================================================================
set -u

D="${1:-}"
if [ -z "$D" ]; then
    D=$(ls -dt /root/waydroid-debug-* 2>/dev/null | head -n1)
fi
if [ -z "$D" ] || [ ! -d "$D" ]; then
    echo "no capture directory found" >&2
    exit 1
fi
echo "analysing: $D"

sec() { printf '\n=== %s ===\n' "$*"; }

sec "1. container state timeline"
if [ -f "$D/state.log" ]; then
    awk 'NR==1 || $0 != prev { print } { prev = $0 }' "$D/state.log" | head -n 40
else
    echo "  (no state.log)"
fi

sec "2. shutdown / reboot requests"
grep -nEi 'sys\.powerctl|init: *Rebooting|reboot|shutdown|poweroff|Shutting down|CRITICAL' \
    "$D/android.log" "$D/android-errors.log" "$D/kernel.log" "$D/manager.log" 2>/dev/null | tail -n 40

sec "3. critical service failures / crashes"
grep -nEi 'critical|CRITICAL|SIGSEGV|SIGABRT|FATAL|Fatal|watchdog|service .* exited|died|Abort message|tombstone|minijail' \
    "$D/android.log" "$D/android-errors.log" 2>/dev/null | tail -n 50

sec "4. memory pressure / OOM"
grep -nEi 'Out of memory|oom-kill|Killed process|lowmemorykiller|lmkd|page allocation failure' \
    "$D/kernel.log" "$D/android.log" 2>/dev/null | tail -n 30

sec "5. graphics / allocator / cgroup complaints"
grep -nEi 'gralloc|allocator|hwcomposer|surfaceflinger|createProcessGroup|cgroup|dma_heap' \
    "$D/android.log" "$D/android-errors.log" 2>/dev/null | tail -n 30

sec "6. last 60 Android lines"
if [ -f "$D/android.log" ]; then tail -n60 "$D/android.log"; else echo "  (no android.log)"; fi

sec "7. last 40 manager lines"
if [ -f "$D/manager.log" ]; then tail -n40 "$D/manager.log"; else echo "  (no manager.log)"; fi

sec "8. last 40 kernel lines"
if [ -f "$D/kernel.log" ]; then tail -n40 "$D/kernel.log"; else echo "  (no kernel.log)"; fi

sec "files"
ls -l "$D"
