# tailscale module

Bakes a Tailscale auth key into a firstboot systemd unit. On first boot,
the unit runs `tailscale up`, enrolls the Pi on the tailnet, then
disables itself.

## Env vars

| Name | Required | Default | Notes |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | yes | — | tskey-auth-… from the admin console |
| `TAILSCALE_HOSTNAME` | no | (uses `/etc/hostname`) | Override the tailnet hostname |
| `TAILSCALE_FLAGS` | no | `--ssh` | Space-separated. Supported: `--ssh`, `--accept-routes` |

## Threat model

The auth key is stored in `/etc/systemd/system/tailscale-firstboot.service`
on the SD card. Anyone with physical access to the card can extract it.
Use only on cards you trust to stay with the Pi. For images shipped to
strangers, replace `TAILSCALE_AUTHKEY` with a per-device auth flow (out
of scope for this module).

## What it leaves behind

After successful enrollment:

- `tailscaled.service` running (from the deb's postinst).
- `tailscale-firstboot.service` disabled — `/var/lib/tailscale/firstboot-done` marker present.
- `/etc/systemd/system/tailscale-firstboot.service` still on disk (with the auth key) — operators concerned about the key after enrollment can `rm` the file post-first-boot via SSH; the file's existence after enrollment is harmless because the unit is disabled and conditioned.
