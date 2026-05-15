#!/bin/bash
# Generic Pi OS image remasterer. Runs INSIDE the build container
# (privileged, Linux). Decompresses the base, grows it, mounts loopback,
# stages the payload + lib, runs the payload's build.sh inside an arm64
# chroot, repacks.
#
# Inputs come from env vars (set by bin/build-image.sh via docker -e):
#   IN_IMG          path to base .img.xz inside the container (read-only mount)
#   OUT_IMG         path to write the customized image inside the container
#   OUT_FORMAT      xz | gz
#   EXTRA_MB        extra space to add to root partition (default 1536)
#   PAYLOAD_HOST    host-side path mapped to /payload in the container
#   LIB_HOST        host-side path mapped to /lib in the container
#   MOUNT_LABELS    space-separated list of extra mount labels (e.g. "game src")
#   <LABEL>_HOST    for each label, host-side path mapped to /mounts/<label>
# Customization env vars (HOSTNAME, TIMEZONE, etc.) are inherited from
# build-image.sh's `-e` forwarding.

set -euo pipefail

: "${IN_IMG:?IN_IMG required}"
: "${OUT_IMG:?OUT_IMG required}"
: "${OUT_FORMAT:?OUT_FORMAT required (xz|gz)}"
: "${EXTRA_MB:=1536}"

case "$OUT_FORMAT" in
    xz|gz) ;;
    *) echo "OUT_FORMAT must be xz or gz, got '$OUT_FORMAT'" >&2; exit 2 ;;
esac

say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }

IMG="/tmp/pi-os.img"
MNT="/mnt/rootfs"

# ----- decompress + grow ---------------------------------------------------

say "decompressing $IN_IMG → $IMG"
case "$IN_IMG" in
    *.xz) xz -dc "$IN_IMG" > "$IMG" ;;
    *.gz) gzip -dc "$IN_IMG" > "$IMG" ;;
    *.img) cp "$IN_IMG" "$IMG" ;;
    *) echo "unrecognized base image format: $IN_IMG" >&2; exit 2 ;;
esac
ok "image size: $(stat -c%s "$IMG") bytes"

say "growing image by ${EXTRA_MB}MB"
truncate -s +"${EXTRA_MB}M" "$IMG"
parted --script "$IMG" \
    print free \
    resizepart 2 100% \
    print free > /tmp/parted.log 2>&1 || { cat /tmp/parted.log; exit 3; }
ok "partition resized"

# ----- loop mount ----------------------------------------------------------

umount_all() {
    # Unmount in reverse order. Bind-mounted payload/lib/mounts go first
    # because they're inside the rootfs.
    if [[ -d "$MNT/tmp/pibuild" ]]; then
        for sub in "$MNT/tmp/pibuild/mounts/"*/ "$MNT/tmp/pibuild/payload" "$MNT/tmp/pibuild/lib" "$MNT/tmp/pibuild/modules"; do
            [[ -d "$sub" ]] && umount "$sub" 2>/dev/null || true
        done
    fi
    for m in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" \
             "$MNT/boot/firmware" "$MNT"; do
        umount "$m" 2>/dev/null || true
    done
}

cleanup_loop() {
    if [[ -n "${LOOP:-}" ]]; then
        kpartx -dv "$LOOP" >/dev/null 2>&1 || true
        losetup -d "$LOOP" >/dev/null 2>&1 || true
    fi
}

say "attaching loop device"
LOOP="$(losetup --find --show "$IMG")"
trap 'umount_all; cleanup_loop' EXIT
kpartx -av "$LOOP" >/dev/null
LOOP_BASENAME="$(basename "$LOOP")"
PART1="/dev/mapper/${LOOP_BASENAME}p1"
PART2="/dev/mapper/${LOOP_BASENAME}p2"
for _ in $(seq 1 20); do
    [[ -b "$PART2" ]] && break
    sleep 0.2
done
[[ -b "$PART2" ]] || { echo "error: $PART2 never appeared"; ls /dev/mapper/ >&2; exit 3; }
ok "loop: $LOOP → $PART1, $PART2"

e2fsck -f -y "$PART2" >/dev/null 2>&1 || true
resize2fs "$PART2" >/dev/null
ok "ext4 resized"

mkdir -p "$MNT"
mount "$PART2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "$PART1" "$MNT/boot/firmware"
ok "mounted root + boot"

# ----- qemu chroot ---------------------------------------------------------

# NOTE: Docker Desktop on macOS pre-registers qemu-aarch64 in its VM kernel.
# Adding a second binfmt registration here corrupts /usr/bin exec inside the
# container (every binary hits ELOOP). Keeping the registration disabled —
# Mac builds work without it because Docker Desktop handles it. Linux hosts
# may need an explicit binfmt-misc registration outside this container
# (`docker run --rm --privileged tonistiigi/binfmt --install arm64` or
# similar) before invoking pi-image-build.

cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
cat > "$MNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$MNT/usr/sbin/policy-rc.d"
ok "chroot ready"

# ----- bind-mount payload + lib + extra mounts into chroot ----------------
# Bind-mounting (vs rsync) avoids copying potentially-large mount sources
# into the image partition. The image stays the size of the OS + the things
# the payload's build.sh deliberately writes.

PIBUILD="$MNT/tmp/pibuild"
mkdir -p "$PIBUILD/lib" "$PIBUILD/payload" "$PIBUILD/mounts"

say "binding payload + lib into chroot"
mount --bind /pibuild/lib     "$PIBUILD/lib"
mount --bind /pibuild/payload "$PIBUILD/payload"

if [[ -d /pibuild/mounts ]]; then
    for label_dir in /pibuild/mounts/*/; do
        [[ -d "$label_dir" ]] || continue
        label="$(basename "$label_dir")"
        install -d -m 755 "$PIBUILD/mounts/$label"
        mount --bind "$label_dir" "$PIBUILD/mounts/$label"
    done
fi
ok "bound"

# Repo-level modules (always present; payload-local modules live under
# /pibuild/payload/modules/ and are accessed via the payload bind mount).
if [[ -d /pibuild/modules ]]; then
    mkdir -p "$PIBUILD/modules"
    mount --bind /pibuild/modules "$PIBUILD/modules"
fi

# Synthetic runner emitted by the loader (new-contract builds only).
if [[ -f /pibuild/run-modules.sh ]]; then
    install -m 755 /pibuild/run-modules.sh "$PIBUILD/run-modules.sh"
fi

BUILD_SCRIPT_PATH="${BUILD_SCRIPT:-/tmp/pibuild/payload/build.sh}"

if [[ -z "${BUILD_SCRIPT:-}" ]]; then
    [[ -f "$PIBUILD/payload/build.sh" ]] || {
        echo "error: payload at $PAYLOAD_HOST has no build.sh" >&2
        exit 2
    }
    [[ -x "$PIBUILD/payload/build.sh" ]] || {
        echo "error: $PAYLOAD_HOST/build.sh is not executable (chmod +x it)" >&2
        exit 2
    }
else
    [[ -f "$PIBUILD/run-modules.sh" ]] || {
        echo "error: synthetic runner not found at \$PIBUILD/run-modules.sh (BUILD_SCRIPT=$BUILD_SCRIPT)" >&2
        exit 2
    }
fi

# ----- run payload's build.sh inside chroot -------------------------------

# Forward the canonical env-var set (lib functions consume these) plus any
# extra vars the caller named in PASSTHROUGH (newline-separated NAME=VALUE).
CHROOT_ENV=(
    "HOME=/root"
    "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
    "LIB_DIR=/tmp/pibuild/lib"
    "PAYLOAD_DIR=/tmp/pibuild/payload"
    "MOUNTS_DIR=/tmp/pibuild/mounts"
    "MODULES_DIR=/tmp/pibuild/modules"
)
# Canonical customization vars — forwarded if present. lib/ functions know
# what to do with them; payloads can also read them directly.
# Forwarded when present in the new-contract case (harmless for legacy).
[[ -n "${BUILD_SCRIPT:-}" ]] && CHROOT_ENV+=("BUILD_SCRIPT=${BUILD_SCRIPT}")
for v in HOSTNAME TIMEZONE KEYMAP PI_USER ENCRYPTED_PASSWORD SSH_PUBKEY; do
    [[ -n "${!v:-}" ]] && CHROOT_ENV+=("$v=${!v}")
done
# Caller-supplied passthrough: a newline-separated NAME=VALUE list.
if [[ -n "${PASSTHROUGH:-}" ]]; then
    while IFS= read -r kv; do
        [[ -n "$kv" ]] && CHROOT_ENV+=("$kv")
    done <<< "$PASSTHROUGH"
fi

say "running payload build.sh"
chroot "$MNT" env -i "${CHROOT_ENV[@]}" \
    "$BUILD_SCRIPT_PATH"
ok "payload customization done"

# ----- clean up build state inside image ----------------------------------
# Unmount bind mounts before removing the dirs, otherwise rm follows into
# the source trees on the container.

for sub in "$MNT/tmp/pibuild/mounts/"*/ "$MNT/tmp/pibuild/payload" "$MNT/tmp/pibuild/lib" "$MNT/tmp/pibuild/modules"; do
    [[ -d "$sub" ]] && umount "$sub" 2>/dev/null || true
done
rm -rf "$MNT/tmp/pibuild"
rm -f "$MNT/usr/bin/qemu-aarch64-static"
rm -f "$MNT/usr/sbin/policy-rc.d"
rm -rf "$MNT/var/cache/apt/archives/"*.deb
rm -rf "$MNT/var/lib/apt/lists/"*
ok "cleaned"

# ----- detach + repack ----------------------------------------------------

umount_all
trap - EXIT
cleanup_loop

say "compressing ($OUT_FORMAT)"
case "$OUT_FORMAT" in
    xz) xz -T0 -f "$IMG"; mv "$IMG.xz" "$OUT_IMG" ;;
    gz) pigz -f "$IMG";   mv "$IMG.gz" "$OUT_IMG" ;;
esac
ok "output: $OUT_IMG ($(stat -c%s "$OUT_IMG") bytes)"
