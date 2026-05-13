#!/bin/bash
# mpv-loop payload. A Pi that boots, joins wifi, and plays a single video
# file on a fullscreen KMS surface, looped forever. The video is baked in
# at build time via `--mount video=/path/to/dir`. Runs INSIDE the chroot.
set -euo pipefail

source "$LIB_DIR/hostname.sh"
source "$LIB_DIR/locale.sh"
source "$LIB_DIR/user.sh"
source "$LIB_DIR/ssh.sh"
source "$LIB_DIR/wifi.sh"
source "$LIB_DIR/apt.sh"

FILES="$PAYLOAD_DIR/files"
PI_USER="${PI_USER:-pi}"

echo "--- mpv-loop payload ---"

# ----- baseline OS config ------------------------------------------------

# Placeholder hostname; mpv-loop-assign-hostname.service rewrites it from
# the wlan0 MAC on every boot.
set_hostname    "${HOSTNAME:-mpv-loop}"
set_timezone    "${TIMEZONE:-UTC}"
set_keyboard    "${KEYMAP:-us}"
ensure_user     "$PI_USER" "$ENCRYPTED_PASSWORD"
disable_userconfig_wizard
add_to_sudoers_nopasswd "$PI_USER"

apt_install iw rfkill openssh-server
install_pubkey "$SSH_PUBKEY" "$PI_USER"
enable_ssh
disable_password_auth

enable_wifi_regdom "${AP_COUNTRY:-US}"
mask_systemd_rfkill
prime_nm_wifi_enabled
nm_rfkill_unblock_dropin

reset_machine_id

# ----- mpv + audio stack -------------------------------------------------

apt_install mpv alsa-utils

# ----- mpv config (KMS on Pi OS Lite, no X/Wayland) ----------------------
# vo=gpu/drm draws straight to /dev/dri/card0. ao defaults to null because
# Pi OS Lite has no audio backend; mpv's auto-fallback (PipeWire/JACK/Pulse)
# spams retries and chews CPU. Override MPV_AUDIO_OUT (e.g. alsa) when
# audio is wanted.
install -d -m 755 /etc/mpv
cat > /etc/mpv/mpv.conf <<MPV
vo=gpu
gpu-context=drm
gpu-api=opengl
hwdec=auto-safe
ao=${MPV_AUDIO_OUT:-null}
fullscreen=yes
osc=no
input-default-bindings=no
terminal=no
MPV

# ----- wifi profile ------------------------------------------------------
# Optional: only install if AP_SSID is provided. This example expects the
# aether AP env (AP_SSID / AP_PSK / AP_COUNTRY) to be forwarded via
# `--env-regex 'AP_.*'`.

if [[ -n "${AP_SSID:-}" ]]; then
    install_nm_wifi mpv-loop "$AP_SSID" "${AP_PSK:-}" "" 100
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
    # Copy everything the caller dropped in the mount. The launcher
    # picks the first file at runtime; if you bake more than one,
    # only the lexicographically first one plays. -L dereferences
    # symlinks (and hard-fails on dangling ones) — a host-side symlink
    # into the mount has no meaning inside the chroot.
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
echo "--- mpv-loop payload done ---"
