#!/usr/bin/env bash
# Flash a Pi image to an SD card. macOS-only as written.
#
# Usage:
#   flash-image.sh <image-or-name> <device>
#
# <image-or-name> is one of:
#   - a path to .img, .img.gz, or .img.xz (used as-is)
#   - a payload name (e.g. "mpv-loop"); resolves to the newest
#     ./out/<name>-*.img.{xz,gz,img} by mtime. Matches the naming
#     scheme bin/build-image.sh emits by default.
#
# Device must be external (refuses internal disks).

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: flash-image.sh is macOS-only" >&2
    exit 2
fi

usage() {
    cat >&2 <<USAGE
usage: $(basename "$0") <image-or-name> <device>
       <image-or-name> is a path to .img/.img.gz/.img.xz, or a payload
         name like 'mpv-loop' (resolves to newest ./out/<name>-*.img.*).
       <device> is e.g. /dev/disk4 (external only)

available external disks:
$(diskutil list external physical 2>/dev/null | sed 's/^/  /')
USAGE
}

[[ $# -eq 2 ]] || { usage; exit 2; }
IMG_ARG="$1"
DEVICE="$2"

# Resolve <image-or-name>. If it's an existing file with a known
# extension, use it. Otherwise treat it as a payload name and pick the
# newest matching artifact in ./out/.
resolve_image() {
    local arg="$1"
    if [[ -f "$arg" ]]; then
        case "$arg" in
            *.img|*.img.gz|*.img.xz) printf '%s\n' "$arg"; return 0 ;;
            *) echo "expected .img, .img.gz, or .img.xz, got $arg" >&2; return 2 ;;
        esac
    fi
    if [[ "$arg" == */* ]]; then
        echo "image not found: $arg" >&2; return 2
    fi
    local out_dir="$PWD/out"
    [[ -d "$out_dir" ]] || { echo "no ./out/ in $PWD; pass an explicit path" >&2; return 2; }
    # Newest by mtime among matching artifacts; stat -f for BSD/macOS.
    local newest
    newest="$(
        find "$out_dir" -maxdepth 1 -type f \
            \( -name "${arg}-*.img" -o -name "${arg}-*.img.gz" -o -name "${arg}-*.img.xz" \) \
            -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2-
    )"
    if [[ -z "$newest" ]]; then
        echo "no images matching '${arg}-*.img[.gz|.xz]' in $out_dir" >&2
        return 2
    fi
    printf '%s\n' "$newest"
}

IMG_FILE="$(resolve_image "$IMG_ARG")" || exit $?

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
