#!/usr/bin/env bash
# Flash a Pi image to an SD card. macOS-only as written.
#
# Usage:
#   flash-image.sh <image-file> <device>
#
# Image may be .img, .img.gz, or .img.xz (auto-detected).
# Device must be external (refuses internal disks).
#
# For "latest of a kind" resolution (e.g. "newest videosync-server image"),
# do that in a consumer-side wrapper and call this with the resolved path.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: flash-image.sh is macOS-only" >&2
    exit 2
fi

usage() {
    cat >&2 <<USAGE
usage: $(basename "$0") <image-file> <device>
       <image-file> is .img, .img.gz, or .img.xz
       <device> is e.g. /dev/disk4 (external only)

available external disks:
$(diskutil list external physical 2>/dev/null | sed 's/^/  /')
USAGE
}

[[ $# -eq 2 ]] || { usage; exit 2; }
IMG_FILE="$1"
DEVICE="$2"

[[ -f "$IMG_FILE" ]] || { echo "image not found: $IMG_FILE" >&2; exit 2; }
case "$IMG_FILE" in
    *.img|*.img.gz|*.img.xz) ;;
    *) echo "expected .img, .img.gz, or .img.xz, got $IMG_FILE" >&2; exit 2 ;;
esac

diskutil info "$DEVICE" >/dev/null 2>&1 \
    || { echo "$DEVICE is not a valid disk" >&2; exit 2; }

if diskutil info "$DEVICE" | grep -qE "Internal:\s+Yes"; then
    echo "$DEVICE is internal. refusing." >&2
    exit 2
fi

SIZE="$(diskutil info "$DEVICE" | awk -F'[()]' '/Disk Size/ {gsub(/ /,"",$2); print $2; exit}')"
IMG_SIZE="$(ls -lh "$IMG_FILE" | awk '{print $5}')"

say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }

cat <<INFO

Writing:
  image:  $IMG_FILE   ($IMG_SIZE)
  device: $DEVICE       ($SIZE)

INFO
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "aborted."; exit 1; }

say "unmounting $DEVICE"
diskutil unmountDisk "$DEVICE" >/dev/null

RDEVICE="/dev/rdisk${DEVICE##*disk}"
say "writing"
case "$IMG_FILE" in
    *.gz) gzip -dc "$IMG_FILE" | sudo dd of="$RDEVICE" bs=4m status=progress ;;
    *.xz) xz -dc   "$IMG_FILE" | sudo dd of="$RDEVICE" bs=4m status=progress ;;
    *)    sudo dd if="$IMG_FILE" of="$RDEVICE" bs=4m status=progress ;;
esac
sync
ok "bytes written"

say "ejecting"
diskutil eject "$DEVICE" >/dev/null
ok "done"
