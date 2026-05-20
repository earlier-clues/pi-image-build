# mqtt-broker module

Install and configure Mosquitto MQTT broker as a systemd service. Useful for
setting up a central broker on a Pi that hosts other Pis publishing telemetry
(e.g., via the `mqtt-telemetry` module).

## Environment Variables

See `schema.sh` for authoritative declarations. Quick reference:

| Variable | Default | Notes |
|----------|---------|-------|
| `MQTT_BROKER_PORT` | `1883` | TCP listener port. |
| `MQTT_BROKER_WS_PORT` | (none) | WebSocket listener port for browser clients. Empty = disabled. |
| `MQTT_BROKER_AUTH` | `anonymous` | `anonymous` or `passwd`. |
| `MQTT_BROKER_PASSWD_PATH` | (none) | Password file path (required if `AUTH=passwd`). |

## Threat Model

The default configuration matches pi-image-build's **trusted-LAN** posture: no
authentication, plaintext protocol. This is appropriate when:

- The Pi is behind a private network (e.g., home AP)
- Physical access to the network is the threat
- All connecting clients are trusted

For less-trusted environments:

1. Set `MQTT_BROKER_AUTH=passwd` and provide a password file via
   `MQTT_BROKER_PASSWD_PATH`.
2. TLS is not currently supported. The broker listens in plaintext. For
   untrusted-network deployments, use Tailscale or another encrypted
   transport between clients and the broker until a properly-designed TLS
   option lands.

## Providing a password file

`MQTT_BROKER_PASSWD_PATH` is interpreted **inside the chroot**, not on your host. Two ways to make a passwd file visible there:

**Option A: drop it into the payload directory.** The payload dir is bind-mounted into the chroot at `/tmp/pibuild/payload/`. So if your payload is at `examples/my-broker/`:

```bash
# On your host:
mosquitto_passwd -c examples/my-broker/mosquitto-passwd alice

# In examples/my-broker/.env:
MQTT_BROKER_AUTH=passwd
MQTT_BROKER_PASSWD_PATH=/tmp/pibuild/payload/mosquitto-passwd
```

**Option B: pass via `--mount`.** Useful when the passwd file lives outside the repo:

```bash
bin/build-image.sh examples/my-broker --mount creds=/home/me/secrets

# In examples/my-broker/.env:
MQTT_BROKER_AUTH=passwd
MQTT_BROKER_PASSWD_PATH=/tmp/pibuild/mounts/creds/mosquitto-passwd
```

## Operational Notes

- **Service:** `mosquitto.service` is enabled and auto-starts on boot.
- **Logs:** Check `journalctl -u mosquitto` or syslog.
- **Persistence:** Enabled at `/var/lib/mosquitto/`.
- **Password file format:** Standard mosquitto format, one user:hash per line.
  Generate with `mosquitto_passwd -c /path/to/passwd username`.
