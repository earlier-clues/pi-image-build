#!/bin/bash
# User account helpers. Run inside the chroot.
LIB_API_VERSION=1

# Create the named user if absent (with the standard Pi groups), set the
# password, and unlock the account. Idempotent: re-running just resets the
# password.
#
# Args:
#   $1 user
#   $2 encrypted password (output of `openssl passwd -6 ...`)
ensure_user() {
    local user="$1"
    local enc_pw="$2"

    if ! id "$user" >/dev/null 2>&1; then
        if [ -x /usr/lib/userconf-pi/userconf ]; then
            /usr/lib/userconf-pi/userconf "$user" "$enc_pw"
        else
            useradd -m -s /bin/bash \
                -G sudo,adm,dialout,cdrom,tty,audio,video,plugdev,games,users,input,render,netdev,spi,i2c,gpio \
                "$user"
            echo "$user:$enc_pw" | chpasswd -e
        fi
    else
        echo "$user:$enc_pw" | chpasswd -e
    fi

    usermod -s /bin/bash "$user" || true
    passwd -u "$user" 2>/dev/null || true
}

# NOPASSWD sudo via a named drop-in. Trust this on trusted LANs only — it
# means a stolen SD card has root with the user's password.
add_to_sudoers_nopasswd() {
    local user="$1"
    local file="/etc/sudoers.d/010-${user}-nopasswd"
    echo "$user ALL=(ALL) NOPASSWD: ALL" > "$file"
    chmod 0440 "$file"
    visudo -cf "$file"
}

# Mask Pi OS Bookworm Lite's first-boot user wizard. Without this, even when
# the pi user already exists, userconfig.service grabs tty1 with the blue TUI
# on every boot until someone completes it interactively. Mask via symlink so
# it works whether the unit file is present or not.
disable_userconfig_wizard() {
    ln -sf /dev/null /etc/systemd/system/userconfig.service
}
