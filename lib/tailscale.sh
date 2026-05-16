#!/bin/bash
# Tailscale install + firstboot enrollment. Run inside the chroot.
LIB_API_VERSION=1

# Install tailscale (from the official Debian apt repo) and drop a
# oneshot firstboot service that runs `tailscale up` on first boot with
# the configured auth key, then disables itself.
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

    # curl + ca-certificates are required for the apt-repo bootstrap below.
    # Pi OS Lite bookworm ships both, but make the dependency explicit so a
    # future minified base image doesn't break this silently.
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

    # 1) Set up the Tailscale apt repo for this Pi OS codename.
    local codename
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    [[ -n "$codename" ]] || { echo "install_tailscale: cannot determine VERSION_CODENAME from /etc/os-release" >&2; return 3; }

    install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
        || { echo "install_tailscale: failed to fetch Tailscale GPG keyring" >&2; return 3; }
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list \
        || { echo "install_tailscale: failed to fetch Tailscale apt sources list" >&2; return 3; }

    # 2) Update apt cache for the new repo, then install tailscale.
    # (apt_install only runs apt-get update once per build, so we must do it
    # explicitly here after adding a new repo source.)
    apt-get update -qq
    apt_install tailscale

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
    systemctl enable tailscale-firstboot.service
}
