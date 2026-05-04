#!/bin/bash
# Hostname helpers. Run inside the chroot.
LIB_API_VERSION=1

set_hostname() {
    local name="$1"
    echo "$name" > /etc/hostname
    if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$name/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$name" >> /etc/hosts
    fi
}

# Reset /etc/machine-id so each Pi from this image generates its own on first
# boot. Without this, every Pi shares one machine-id, breaking journal
# aggregation, NM's DHCP DUID, and anything else keyed by it.
reset_machine_id() {
    truncate -s 0 /etc/machine-id
    rm -f /var/lib/dbus/machine-id
}
