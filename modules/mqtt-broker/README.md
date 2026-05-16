# mqtt-broker module

Install and configure Mosquitto MQTT broker as a systemd service. Useful for
setting up a central broker on a Pi that hosts other Pis publishing telemetry
(e.g., via the `mqtt-telemetry` module).

## Environment Variables

See `schema.sh` for authoritative declarations. Quick reference:

| Variable | Default | Notes |
|----------|---------|-------|
| `MQTT_BROKER_PORT` | `1883` | Listener port. |
| `MQTT_BROKER_AUTH` | `anonymous` | `anonymous` or `passwd`. |
| `MQTT_BROKER_PASSWD_PATH` | (none) | Password file path (required if `AUTH=passwd`). |
| `MQTT_BROKER_CERT_PATH` | (none) | TLS CA cert path; empty = plaintext. |

## Threat Model

The default configuration matches pi-image-build's **trusted-LAN** posture: no
authentication, plaintext protocol. This is appropriate when:

- The Pi is behind a private network (e.g., home AP)
- Physical access to the network is the threat
- All connecting clients are trusted

For less-trusted environments:

1. Set `MQTT_BROKER_AUTH=passwd` and provide a password file via
   `MQTT_BROKER_PASSWD_PATH`.
2. Optionally provide a TLS certificate via `MQTT_BROKER_CERT_PATH` for
   encrypted transport.

## Operational Notes

- **Service:** `mosquitto.service` is enabled and auto-starts on boot.
- **Logs:** Check `journalctl -u mosquitto` or syslog.
- **Persistence:** Enabled at `/var/lib/mosquitto/`.
- **Password file format:** Standard mosquitto format, one user:hash per line.
  Generate with `mosquitto_passwd -c /path/to/passwd username`.
