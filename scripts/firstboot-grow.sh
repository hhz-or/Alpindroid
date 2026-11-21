#!/bin/sh
# ============================================================================
# Alpindroid: first-boot root partition growth
#
# The shipped image carries a 2.4 GB root partition whatever the card size, so a
# fresh flash always wastes most of the SD card. This runs once from OpenRC's
# local service and expands partition 2 + the ext4 filesystem to fill the card.
#
# Design notes:
#   * runs online (growpart + resize2fs on a mounted ext4 works), so no reboot;
#   * idempotent: a marker file stops it after the first successful run, and the
#     size check makes a second run a no-op even without the marker;
#   * never blocks boot: every failure path exits 0, the marker is only written
#     after a successful resize;
#   * cloud-utils-growpart and e2fsprogs-extra are preinstalled by the image
#     builder, so this works without network access.
#
# Install as /etc/local.d/alpindroid-firstboot.start (the image builder does it).
# ============================================================================
set -u

MARK=/etc/.alpindroid-grown
LOG=/var/log/alpindroid-firstboot.log

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

[ -f "$MARK" ] && exit 0

# --- identify the device backing /
# /proc/mounts reports "/dev/root" on Alpine and that path usually does not
# exist, so resolve it through root=PARTUUID=<uuid> from the kernel cmdline.
ROOT_SRC=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
REAL_ROOT=""
if [ -b "$ROOT_SRC" ]; then
    REAL_ROOT=$(readlink -f "$ROOT_SRC" 2>/dev/null)
fi
if [ -z "$REAL_ROOT" ] || [ ! -b "$REAL_ROOT" ]; then
    PARTUUID=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline | head -n1)
    if [ -n "$PARTUUID" ] && [ -e "/dev/disk/by-partuuid/$PARTUUID" ]; then
        REAL_ROOT=$(readlink -f "/dev/disk/by-partuuid/$PARTUUID" 2>/dev/null)
    fi
fi
if [ -z "$REAL_ROOT" ] || [ ! -b "$REAL_ROOT" ]; then
    log "cannot resolve the root block device (mounts=$ROOT_SRC cmdline=$(cat /proc/cmdline))"
    exit 1
fi
log "root device resolved to $REAL_ROOT"

PART_NAME=$(basename "$REAL_ROOT")
case "$PART_NAME" in
    *p[0-9]*) DISK_NAME=${PART_NAME%p[0-9]*}; PART_NUM=${PART_NAME##*p} ;;
    *[0-9])   DISK_NAME=${PART_NAME%[0-9]}; PART_NUM=${PART_NAME##*[!0-9]} ;;
    *) log "cannot parse partition name $PART_NAME"; : > "$MARK"; exit 0 ;;
esac
DISK=/dev/$DISK_NAME

log "root=$ROOT_SRC disk=$DISK part=$PART_NUM"

# --- already spanning the card?
DISK_SECTORS=$(cat "/sys/block/$DISK_NAME/size" 2>/dev/null || echo "")
PART_SECTORS=$(cat "/sys/block/$DISK_NAME/$PART_NAME/size" 2>/dev/null || echo "")
if [ -n "$DISK_SECTORS" ] && [ -n "$PART_SECTORS" ]; then
    # tolerate the 2048-sector alignment gap at the end of the disk
    if [ "$PART_SECTORS" -ge "$((DISK_SECTORS - 2048))" ]; then
        log "partition already spans the card ($PART_SECTORS/$DISK_SECTORS sectors)"
        : > "$MARK"
        exit 0
    fi
    log "growing: $PART_SECTORS -> $DISK_SECTORS sectors"
fi

command -v growpart >/dev/null 2>&1 || { log "growpart missing (cloud-utils-growpart)"; exit 0; }
command -v resize2fs >/dev/null 2>&1 || { log "resize2fs missing (e2fsprogs-extra)"; exit 0; }

# --- back up the table before touching it
sfdisk -d "$DISK" > /root/partition-backup.sfdisk 2>/dev/null || true

if ! growpart "$DISK" "$PART_NUM" >> "$LOG" 2>&1; then
    log "growpart failed; leaving the system as is"
    exit 0
fi

if ! resize2fs "$REAL_ROOT" >> "$LOG" 2>&1; then
    log "resize2fs failed; partition table was already changed"
    exit 0
fi

log "done: $(df -h / | tail -n1)"
: > "$MARK"
exit 0
