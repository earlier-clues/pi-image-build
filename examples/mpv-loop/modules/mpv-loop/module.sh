# mpv-loop module — payload-local. Everything in pre-migration
# examples/mpv-loop/build.sh that's NOT the baseline-OS-config block
# (that's now in modules/core).
#
# Inputs (from schema.sh): MPV_AUDIO_OUT (default null), AP_SSID/AP_PSK
# (optional, default empty).

source "$LIB_DIR/wifi.sh"
source "$LIB_DIR/apt.sh"

# Ordering check: mpv-loop must come AFTER core in modules.list. We
# can't check via `command -v` because mpv-loop re-sources lib/wifi.sh
# itself; instead check for a SIDE EFFECT of core having run — the
# PI_USER account must already exist (created by core's ensure_user).
# Without core, downstream `chown -R "$PI_USER:$PI_USER"` would fail
# with a confusing "invalid user" error.
if ! id "$PI_USER" >/dev/null 2>&1; then
    echo "modules/mpv-loop: PI_USER='$PI_USER' does not exist — core must precede mpv-loop in modules.list" >&2
    exit 2
fi

FILES="$MODULE_DIR/files"
PI_USER="${PI_USER:-pi}"

echo "--- mpv-loop module ---"

# ----- mpv + audio stack -------------------------------------------------

apt_install mpv alsa-utils

# ----- mpv config (KMS on Pi OS Lite, no X/Wayland) ----------------------
# vo=gpu/drm draws straight to /dev/dri/card0. ao defaults to null
# because Pi OS Lite has no audio backend; mpv's auto-fallback
# (PipeWire/JACK/Pulse) spams retries and chews CPU. Override
# MPV_AUDIO_OUT (e.g. alsa) when audio is wanted.
install -d -m 755 /etc/mpv
cat > /etc/mpv/mpv.conf <<MPV
vo=gpu
gpu-context=drm
gpu-api=opengl
hwdec=auto-safe
ao=${MPV_AUDIO_OUT}
fullscreen=yes
osc=no
input-default-bindings=no
terminal=no
MPV

# ----- wifi profile ------------------------------------------------------
# Optional: only install if AP_SSID is provided.

if [[ -n "$AP_SSID" ]]; then
    install_nm_wifi mpv-loop "$AP_SSID" "$AP_PSK" "" 100
else
    echo "  note: AP_SSID unset, no wifi profile installed (ethernet only)"
fi

# ----- per-device hostname from MAC --------------------------------------

install -D -m 755 "$FILES/mpv-loop-assign-hostname" \
    /usr/local/bin/mpv-loop-assign-hostname
install -D -m 644 "$FILES/mpv-loop-assign-hostname.service" \
    /etc/systemd/system/mpv-loop-assign-hostname.service

# ----- wifi power save off (latency spikes otherwise) --------------------

install -D -m 644 "$FILES/wifi-powersave-off.service" \
    /etc/systemd/system/wifi-powersave-off.service

# ----- mpv-loop service + launcher ---------------------------------------

install -D -m 755 "$FILES/mpv-loop" /usr/local/bin/mpv-loop
install -D -m 644 "$FILES/mpv-loop.service" \
    /etc/systemd/system/mpv-loop.service

# ----- boot-time diagnostic dump (writes to FAT bootfs) ------------------
# Kept verbatim from pre-migration so the image-diff gate passes.
# Future cleanup: migrate to the generic boot-report module from Phase 5
# and remove these three files. Not done in this phase because that
# would produce a non-trivial image diff and fail AC8.2.

install -D -m 755 "$FILES/mpv-loop-boot-report" \
    /usr/local/bin/mpv-loop-boot-report
install -D -m 644 "$FILES/mpv-loop-boot-report.service" \
    /etc/systemd/system/mpv-loop-boot-report.service
install -D -m 644 "$FILES/mpv-loop-boot-report.timer" \
    /etc/systemd/system/mpv-loop-boot-report.timer

# ----- bake the video in -------------------------------------------------

VIDEO_DIR="/home/$PI_USER/video"
install -d -m 755 "$VIDEO_DIR"
if [[ -d "${MOUNTS_DIR:-}/video" ]]; then
    cp -aL "$MOUNTS_DIR/video/." "$VIDEO_DIR/"
    count=$(find "$VIDEO_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
    echo "  baked $count file(s) into $VIDEO_DIR"
else
    echo "  WARNING: no --mount video=DIR provided; image has no video to play"
fi
chown -R "$PI_USER:$PI_USER" "$VIDEO_DIR"

# ----- enable services ---------------------------------------------------

systemctl enable mpv-loop-assign-hostname.service
systemctl enable wifi-powersave-off.service
systemctl enable mpv-loop.service
systemctl enable mpv-loop-boot-report.timer

apt_clean
echo "--- mpv-loop module done ---"
