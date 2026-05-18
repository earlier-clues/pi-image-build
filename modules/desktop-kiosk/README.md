# desktop-kiosk

Configure a Pi OS Full desktop session for unattended kiosk operation.

## Prerequisites

- **Base image:** Pi OS Full (desktop + Wayfire compositor). Does not work on Pi OS Lite.
- **modules.list:** Must appear after `core` (needs `PI_USER` to exist).

## Schema

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `KIOSK_USER` | optional | `$PI_USER` | User account for autologin and wayfire config |
| `KIOSK_DEBLOAT` | optional | `true` | Purge desktop bloat packages (libreoffice, wolfram, etc.) |

## What it does

1. **Autologin** — boots to desktop session without login prompt
2. **Purge piwiz** — removes the first-boot setup wizard (always, regardless of `KIOSK_DEBLOAT`)
3. **Desktop debloat** — when `KIOSK_DEBLOAT=true`, purges: libreoffice, wolfram, sonic-pi, thonny, scratch, minecraft-pi, realvnc, rpi-chromium-mods
4. **Cursor hiding** — installs `unclutter` to hide the mouse pointer after idle
5. **Wayfire config** — writes base `wayfire.ini` with `hide-cursor` and `idle` plugins enabled, DPMS disabled, and an empty `[autostart]` section
6. **Boot quieting** — suppresses splash screen, kernel logo, and console cursor

## Adding autostart entries

Payload-local modules that run after `desktop-kiosk` can append to the `[autostart]` section of wayfire.ini:

```bash
sed -i '/^\[autostart\]$/a my-app = /usr/local/bin/my-app-launcher' \
    "/home/$KIOSK_USER/.config/wayfire.ini"
```

Or install a systemd unit that starts after `graphical.target`.
