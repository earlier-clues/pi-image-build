# mqtt-dashboard

Tiny refresh-every-5s status page for an MQTT-publishing Pi fleet. Designed
to be paired with `mqtt-broker` on the same Pi so a venue server is
self-contained: pis publish → local mosquitto → local dashboard → operator's
browser at `http://<server>:8080/`. No DB, no external services.

## What it shows

For each host seen on the broker:

- live status (online / offline / stale / unknown) from the `online` retained topic
- last `health` reading (cpu temp, load, rssi, uptime, ip)
- last seen age (seconds since most recent health message)
- a rolling event log (last 50 per host, in-memory) of:
  - online ↔ offline transitions
  - throttled-bit changes (under-voltage, thermal throttle, etc.)
  - cpu temperature jumps ≥10°C
  - ip address changes
  - version changes

State is in-memory only. Restarts lose the rolling event log; live state
recovers immediately from the broker's retained `online` / `version` /
`health` topics.

## Topics consumed

Matches the layout published by the `mqtt-telemetry` module:

```
pi/<role>/<host>/online    "true" | "false"   retained
pi/<role>/<host>/version   image fingerprint  retained
pi/<role>/<host>/health    JSON               retained
```

Subscription glob is `MQTT_DASHBOARD_TOPIC` (default `pi/#`).

## Routes

| Route          | Content-Type             | Purpose |
|----------------|--------------------------|---------|
| `GET /`        | `text/html; charset=utf-8` | HTML page with `<meta http-equiv="refresh" content="5">` |
| `GET /health.json` | `application/json`   | Full state dump for debugging / external scrapers |

## Env vars

All optional; sane defaults work for "co-located with `mqtt-broker` on
the same Pi":

| Var | Default | What |
|-----|---------|------|
| `MQTT_DASHBOARD_BROKER` | `localhost:1883` | broker to subscribe to |
| `MQTT_DASHBOARD_TOPIC`  | `pi/#`           | subscription glob |
| `MQTT_DASHBOARD_PORT`   | `8080`           | HTTP listen port |

## Posture

No auth on the HTTP port. Bind is `0.0.0.0`. If the Pi is on a tailnet
this means anyone on the tailnet can read fleet status — same posture
as `mqtt-broker` (anonymous, plaintext) and `core` (sudoers NOPASSWD).
Trusted-LAN / trusted-tailnet only. See top-level `README.md` § Caveats.
