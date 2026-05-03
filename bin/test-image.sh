#!/usr/bin/env bash
# Boot a built Pi image under QEMU raspi3b emulation and verify the kernel
# gets far enough to mount the root filesystem. Crude but real:
#
#   PASS = kernel boots, MMC + ext4 work, partition layout is sane,
#          /sbin/init is reachable.
#   FAIL = kernel panic before rootfs mount, or no progress within timeout.
#
# Why so limited:
#
#   QEMU's raspi3b is the only Pi machine that produces serial output on
#   Bookworm. raspi4b emulation is silent (broken). And `-M virt` would be
#   fast but the Pi OS kernel is built without virtio, so virt-attached
#   disks are invisible. Pi 3 emulation of a Pi 4 image gets us through the
#   boot path up to ext4 mount; init then exits because of Pi-3-vs-Pi-4
#   userspace mismatch. We treat reaching ext4 as the success signal.
#
# Usage:
#   test-image.sh <image> [--boot-timeout SECONDS] [--keep]
#
# Requirements (macOS):
#   brew install qemu mtools

set -euo pipefail

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; }

IMAGE=""
BOOT_TIMEOUT=240
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
        --keep)         KEEP=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -z "$IMAGE" ]]; then IMAGE="$1"
            else echo "unexpected arg: $1" >&2; usage >&2; exit 2
            fi
            shift ;;
    esac
done

[[ -n "$IMAGE" && -f "$IMAGE" ]] || { echo "error: image required" >&2; usage >&2; exit 2; }
for cmd in qemu-system-aarch64 mcopy python3; do
    command -v "$cmd" >/dev/null \
        || { echo "error: '$cmd' not installed (brew install qemu mtools)" >&2; exit 2; }
done

say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
no()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; }

WORK="$(mktemp -d -t pibuild-test.XXXXXX)"
QEMU_PID=""
cleanup() {
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
    [[ -n "$QEMU_PID" ]] && wait "$QEMU_PID" 2>/dev/null || true
    if (( KEEP == 0 )); then
        rm -rf "$WORK"
    else
        echo "kept: $WORK" >&2
    fi
}
trap cleanup EXIT INT TERM

# ----- decompress + extract kernel/dtb/initramfs --------------------------

RAW="$WORK/disk.img"
say "decompressing"
case "$IMAGE" in
    *.gz)  gzip -dc "$IMAGE" > "$RAW" ;;
    *.xz)  xz   -dc "$IMAGE" > "$RAW" ;;
    *.img) cp           "$IMAGE" "$RAW" ;;
    *)     echo "expected .img / .img.gz / .img.xz" >&2; exit 2 ;;
esac

# raspi3b SD device requires the disk to be a power of 2. 8 GiB is plenty
# for anything we currently produce.
truncate -s 8G "$RAW"

# Read partition 1's LBA from the MBR.
BOOT_OFFSET_SECTORS="$(python3 -c "
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(446 + 8)
    print(struct.unpack('<I', f.read(4))[0])
" "$RAW")"
BOOT_OFFSET=$(( BOOT_OFFSET_SECTORS * 512 ))

KERNEL="$WORK/kernel8.img"
INITRD="$WORK/initramfs8"
DTB="$WORK/bcm2710-rpi-3-b.dtb"
mcopy -i "$RAW@@$BOOT_OFFSET" ::kernel8.img             "$KERNEL"
mcopy -i "$RAW@@$BOOT_OFFSET" ::initramfs8              "$INITRD" 2>/dev/null \
    || { echo "error: image has no initramfs8" >&2; exit 4; }
mcopy -i "$RAW@@$BOOT_OFFSET" ::bcm2710-rpi-3-b.dtb     "$DTB" \
    || { echo "error: image has no bcm2710-rpi-3-b.dtb" >&2; exit 4; }
ok "kernel + initramfs + Pi-3-B dtb extracted"

# ----- boot under raspi3b -------------------------------------------------
# raspi3b is software-emulated arm64 (no hvf accel for Pi machines). Allow
# generous time-to-rootfs.

LOG="$WORK/serial.log"
APPEND="earlycon=pl011,0x3f201000 console=ttyAMA0,115200 root=/dev/mmcblk0p2 rw rootfstype=ext4 init=/sbin/init rootwait"

say "booting raspi3b (timeout ${BOOT_TIMEOUT}s, log: $LOG)"
qemu-system-aarch64 \
    -M raspi3b -m 1G \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -initrd "$INITRD" \
    -append "$APPEND" \
    -drive "file=$RAW,if=sd,format=raw" \
    -display none -monitor none -no-reboot \
    -serial "file:$LOG" &
QEMU_PID=$!

# ----- watch for success or panic ----------------------------------------

SUCCESS_RE='EXT4-fs \(mmcblk0p2\): mounted filesystem'
PANIC_RE='Kernel panic - not syncing: (Unable to mount root|VFS|Attempted to kill init)'

start=$(date +%s)
result=""
last_size=0
quiet_ticks=0
while :; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        result="qemu-exited"
        break
    fi
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed > BOOT_TIMEOUT )); then
        result="timeout"
        break
    fi
    if [[ -f "$LOG" ]]; then
        # The success line appears BEFORE the post-init panic on raspi3b.
        if grep -qE "$SUCCESS_RE" "$LOG"; then
            result="ext4-mounted"
            break
        fi
        # Kernel panics that happen BEFORE ext4 mount are real failures.
        if grep -qE "$PANIC_RE" "$LOG" \
           && ! grep -qE 'Attempted to kill init' "$LOG"; then
            result="panic-before-rootfs"
            break
        fi
        # No-output watchdog: 120s with no new bytes = stuck.
        size="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
        if (( size == last_size )); then
            quiet_ticks=$((quiet_ticks + 1))
        else
            quiet_ticks=0
            last_size=$size
        fi
        if (( quiet_ticks > 120 )); then
            result="stuck"
            break
        fi
    fi
    sleep 1
done

# ----- report -------------------------------------------------------------

case "$result" in
    ext4-mounted)
        ok "kernel booted, MMC detected, ext4 root mounted (${elapsed}s)"
        printf '  (init exits after this point — Pi-3-emu/Pi-4-userspace mismatch, expected)\n'
        exit 0
        ;;
    panic-before-rootfs)
        no "kernel panic before ext4 mount"
        echo "--- last serial log ---" >&2
        tail -25 "$LOG" >&2
        exit 1
        ;;
    qemu-exited)
        no "qemu exited unexpectedly"
        echo "--- last serial log ---" >&2
        tail -25 "$LOG" >&2 || true
        exit 1
        ;;
    timeout)
        no "no rootfs mount within ${BOOT_TIMEOUT}s"
        echo "--- last serial log ---" >&2
        tail -25 "$LOG" >&2 || true
        exit 1
        ;;
    stuck)
        no "serial output silent for >120s — kernel hung"
        echo "--- last serial log ---" >&2
        tail -25 "$LOG" >&2 || true
        exit 1
        ;;
esac
