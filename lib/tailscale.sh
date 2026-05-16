#!/bin/bash
# Tailscale install + firstboot enrollment. Run inside the chroot.
LIB_API_VERSION=1

# Install tailscale using the official Tailscale install.sh script, then drop a
# oneshot firstboot service that runs `tailscale up` on first boot with
# the configured auth key, then disables itself.
#
# The official install.sh handles OS detection, apt repo setup (legacy or keyring-based),
# and package installation. For Raspberry Pi OS, no systemd startup is attempted,
# making it safe for chroot environments.
#
# Args:
#   $1 auth key (tskey-…) — required, positional.
#
# Flags (any order, after the auth key):
#   --hostname HN       hostname to register on the tailnet
#                       (default: empty → tailscale derives from /etc/hostname)
#   --ssh               include `--ssh` in `tailscale up`
#   --accept-routes     include `--accept-routes` in `tailscale up`
#
# Examples:
#   install_tailscale "$TS_AUTHKEY"
#   install_tailscale "$TS_AUTHKEY" --hostname "$HOSTNAME" --ssh
sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

install_tailscale() {
    local authkey="$1"; shift
    local hostname=""
    local flags=""

    [[ -n "$authkey" ]] || { echo "install_tailscale: AUTHKEY required" >&2; return 2; }

    # install.sh itself uses curl to fetch the keyring + sources.list, and we
    # use curl to fetch install.sh. Pi OS Lite bookworm ships both but make the
    # dependency explicit so a future minified base image doesn't break this
    # silently.
    apt_install curl ca-certificates

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                [[ -n "${2:-}" ]] || { echo "install_tailscale: --hostname needs an argument" >&2; return 2; }
                hostname="$2"; shift 2 ;;
            --ssh)
                flags+="${flags:+ }--ssh"; shift ;;
            --accept-routes)
                flags+="${flags:+ }--accept-routes"; shift ;;
            *)
                echo "install_tailscale: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    # 1) Run the official Tailscale install.sh script.
    # It handles OS detection, apt repo setup (legacy or keyring-based),
    # and package installation. For Raspberry Pi OS, it does not attempt
    # systemd startup, making it chroot-safe.
    curl -fsSL https://tailscale.com/install.sh | sh \
        || { echo "install_tailscale: failed to run official install.sh" >&2; return 3; }

    # 2) Verify tailscale package was successfully installed.
    if ! dpkg-query -W tailscale >/dev/null 2>&1; then
        echo "install_tailscale: tailscale package not found after install.sh" >&2
        return 3
    fi

    # 3) Render the firstboot service from the template. Escape all
    # replacement values to prevent sed metacharacters from being interpreted.
    local src="$LIB_DIR/tailscale/tailscale-firstboot.service"
    local dst="/etc/systemd/system/tailscale-firstboot.service"
    install -D -m 644 "$src" "$dst"
    local authkey_esc hostname_esc flags_esc
    authkey_esc=$(sed_escape "$authkey")
    hostname_esc=$(sed_escape "$hostname")
    flags_esc=$(sed_escape "$flags")
    sed -i \
        -e "s|@@AUTHKEY@@|${authkey_esc}|g" \
        -e "s|@@HOSTNAME@@|${hostname_esc}|g" \
        -e "s|@@FLAGS@@|${flags_esc}|g" \
        "$dst"

    # 4) Enable. The unit's ExecStartPost disables it after a successful
    # `tailscale up`.
    systemctl enable tailscale-firstboot.service || { echo "install_tailscale: failed to enable firstboot service" >&2; return 3; }
}
