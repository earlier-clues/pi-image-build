#!/bin/bash
# wifi helpers. Run inside the chroot.
#
# On Debian 13+ /etc/default/crda is dead (crda was deprecated ~kernel 4.15
# and removed). Without a regdomain set at boot, the radio stays
# rfkill-soft-blocked and hostapd / wpa_supplicant / NetworkManager all fail
# in confusing ways. enable_wifi_regdom installs a oneshot that sets the
# regdomain + unblocks rfkill before any wifi service starts.
LIB_API_VERSION=1

# Install + enable the regdom oneshot. Requires `iw` and `rfkill` (apt them
# from the caller).
#
# Args:
#   $1 country code (e.g. US, GB)
enable_wifi_regdom() {
    local country="$1"
    local src="$LIB_DIR/wifi/regdom.service"
    local dst="/etc/systemd/system/pibuild-wifi-regdom.service"

    install -D -m 644 "$src" "$dst"
    sed -i "s|@@COUNTRY@@|$country|g" "$dst"
    systemctl enable pibuild-wifi-regdom.service
}

# Mask systemd-rfkill so it can't restore a persisted block state and race
# the regdom oneshot. After this, pibuild-wifi-regdom is the sole authority
# on rfkill state. Masking (not just disabling) prevents socket-triggered
# reactivation.
mask_systemd_rfkill() {
    systemctl mask systemd-rfkill.socket systemd-rfkill.service
}

# Pre-set NM's WirelessEnabled=true so it doesn't push a soft-block on
# startup that defeats the regdom oneshot.
prime_nm_wifi_enabled() {
    install -D -m 600 /dev/stdin /var/lib/NetworkManager/NetworkManager.state <<'NMSTATE'
[main]
NetworkingEnabled=true
WirelessEnabled=true
WWANEnabled=true
NMSTATE
}

# Drop-in that runs `rfkill unblock all` immediately before NetworkManager
# starts. Belt-and-suspenders alongside the regdom oneshot.
nm_rfkill_unblock_dropin() {
    install -D -m 644 "$LIB_DIR/wifi/nm-unblock.conf" \
        /etc/systemd/system/NetworkManager.service.d/pibuild-unblock.conf
}

# Install a NetworkManager wifi client connection profile. Caller controls
# autoconnect priority and whether the profile is bound to a specific
# interface.
#
# Args:
#   $1 connection id (also used as the file name)
#   $2 ssid
#   $3 psk
#   $4 (optional) interface name to bind to (e.g. wlan0). Empty = any.
#   $5 (optional) autoconnect priority (default 50)
install_nm_wifi() {
    local id="$1" ssid="$2" psk="$3"
    local iface="${4:-}"
    local priority="${5:-50}"
    local uuid; uuid="$(cat /proc/sys/kernel/random/uuid)"
    local file="/etc/NetworkManager/system-connections/${id}.nmconnection"

    install -d -m 755 /etc/NetworkManager/system-connections
    {
        cat <<NM
[connection]
id=$id
uuid=$uuid
type=wifi
autoconnect=true
autoconnect-priority=$priority
NM
        [[ -n "$iface" ]] && echo "interface-name=$iface"
        cat <<NM

[wifi]
mode=infrastructure
ssid=$ssid
hidden=false

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
NM
    } > "$file"
    chmod 600 "$file"
}
