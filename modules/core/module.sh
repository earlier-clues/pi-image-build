# core module — baseline OS configuration. Sourced into the synthetic
# module runner inside the chroot. Inputs (validated host-side by
# modules/core/schema.sh): HOSTNAME, TIMEZONE, PI_USER, ENCRYPTED_PASSWORD,
# SSH_PUBKEY required; KEYMAP, AP_COUNTRY optional with defaults.
#
# This module is the canonical opinion of pi-image-build on what a "usable
# Pi" looks like: named, time-set, a sudo user, sshable with a pubkey,
# wifi radio legally activated, machine-id ready to regenerate on first
# boot. Match exactly what examples/mpv-loop/build.sh does today (the
# strictly-superset claim per AC3.3).

source "$LIB_DIR/hostname.sh"
source "$LIB_DIR/locale.sh"
source "$LIB_DIR/user.sh"
source "$LIB_DIR/ssh.sh"
source "$LIB_DIR/wifi.sh"
source "$LIB_DIR/apt.sh"

# Hostname + locale + keymap.
set_hostname    "$HOSTNAME"
set_timezone    "$TIMEZONE"
set_keyboard    "$KEYMAP"

# User + sudoers + wizard disable. add_to_sudoers_nopasswd is the
# trusted-LAN posture documented in README.md — included unchanged.
ensure_user             "$PI_USER" "$ENCRYPTED_PASSWORD"
disable_userconfig_wizard
add_to_sudoers_nopasswd "$PI_USER"

# Pi OS Lite doesn't ship iw/rfkill/openssh-server by default; the wifi
# regdom oneshot needs them. Install before invoking the wifi lib.
apt_install iw rfkill openssh-server

# SSH: install pubkey for the configured user, enable sshd, disable
# password auth.
install_pubkey "$SSH_PUBKEY" "$PI_USER"
enable_ssh
disable_password_auth

# Wifi baseline: regdom oneshot, mask systemd-rfkill so it can't fight
# the oneshot, prime NM state, drop-in to belt-and-suspenders unblock
# rfkill at NM start.
enable_wifi_regdom    "$AP_COUNTRY"
mask_systemd_rfkill
prime_nm_wifi_enabled
nm_rfkill_unblock_dropin

# Reset machine-id so every Pi from this image generates its own on
# first boot.
reset_machine_id
