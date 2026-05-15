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

# Space-separated flag list. Default --ssh enables Tailscale SSH so the
# Pi is reachable from any tailnet device without managing local keys.
optional TAILSCALE_FLAGS default=--ssh
