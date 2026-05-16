# tailscale module — install Tailscale and enroll on first boot via a
# baked-in auth key. The auth key ends up in /etc/systemd/system/ on the
# Pi; do not ship this image to anyone outside your trust boundary. See
# README.md for the threat model.

require TAILSCALE_AUTHKEY

# Resolves host-side at validate time from the .env-sourced HOSTNAME var.
# Matches the design plan's Phase 4 component spec. Using $HOSTNAME (rather
# than empty + tailscale's /etc/hostname fallback) means payloads that
# rewrite /etc/hostname on first boot (e.g. mpv-loop's assign-hostname unit)
# still get the build-time HOSTNAME as their tailnet name, which is the
# intent.
optional TAILSCALE_HOSTNAME default=$HOSTNAME

# Space-separated flag list. Default empty: tailscaled does not intercept
# port 22, so the Pi answers SSH via OpenSSH using the pubkey installed
# by `core` (`SSH_PUBKEY` → `/home/$PI_USER/.ssh/authorized_keys`).
#
# Set TAILSCALE_FLAGS=--ssh to opt in to Tailscale SSH (identity-based
# auth via the tailnet, no pubkey copies needed) — also requires an
# `ssh:` block in your tailnet ACL or every connection gets denied with
# 'tailnet policy does not permit you to SSH to this node'.
#
# Recognized flags: --ssh, --accept-routes.
optional TAILSCALE_FLAGS default=
