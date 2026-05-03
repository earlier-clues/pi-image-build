#!/bin/bash
# SSH helpers. Run inside the chroot.
LIB_API_VERSION=1

# Install a single pubkey for $user (default pi). Idempotent — appends only
# if the line isn't already there.
install_pubkey() {
    local pubkey="$1"
    local user="${2:-pi}"
    local home; home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] || { echo "install_pubkey: user '$user' has no home" >&2; return 1; }

    install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    grep -qxF "$pubkey" "$home/.ssh/authorized_keys" \
        || printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"
    chown "$user:$user" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
}

# Generate SSH host keys in the chroot so sshd has something to present on
# first boot. Without this, ssh.service fails ("no hostkeys available") and
# the Pi is unreachable until keyboard+HDMI recovery. Trade-off: every Pi
# from this build has identical host keys — fine for trusted LANs, rotate
# with `sudo ssh-keygen -A -f /etc/ssh/` per device if it matters.
enable_ssh() {
    ssh-keygen -A
    systemctl enable ssh
}

# Drop-in disabling password auth. Sets PubkeyAuthentication=yes for clarity.
disable_password_auth() {
    local file="/etc/ssh/sshd_config.d/10-pi-image-build.conf"
    cat > "$file" <<'SSHD'
PasswordAuthentication no
PubkeyAuthentication yes
SSHD
}
