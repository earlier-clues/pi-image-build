#!/bin/bash
# apt wrappers. Run inside the chroot.
LIB_API_VERSION=1

# Marker so we only apt-get update once per build, not once per call.
__APT_UPDATED=0

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    if (( ! __APT_UPDATED )); then
        apt-get update -qq
        __APT_UPDATED=1
    fi
    apt-get install -y --no-install-recommends "$@"
}

# Remove apt's caches so the resulting image stays small. Call once at the
# end of customization.
apt_clean() {
    rm -rf /var/cache/apt/archives/*.deb
    rm -rf /var/lib/apt/lists/*
}
