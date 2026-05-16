# MQTT venue-wide Pi telemetry

Status: design, not built. Ambition raised post-show on 2026-05-13.

## The pitch

Every Pi image that pi-image-build produces — videosync server, videosync
zero, mpv-loop, future ones — comes up on some venue's wifi and then
becomes a black box until something visibly breaks. We don't know if its
CPU is throttled, RAM is exhausted, disk is filling, the radio is barely
clinging on, or whether it's running the code we think it's running.

The videosync UDP TELEMETRY protocol already solves this *for videosync
zeros only*. It can't be reused for non-videosync Pi images: it's
videosync-protocol-specific, the receiver is the videosync coordinator,
and a venue with a mpv-loop installation + no aether server has no place
for those packets to go.

Want: a generic Pi-level health channel that any image baked from
pi-image-build can opt into, publishing to a venue-wide broker. Any
device on the venue wifi (operator's Mac, the videosync server itself,
a phone, a dedicated controller Pi) can subscribe.

## Why MQTT

- Pub/sub with retained-message semantics: a late-joining dashboard
  immediately gets the last-known state of every Pi without polling.
- Tiny client footprint (paho-mqtt is ~30KB on Python; the broker
  mosquitto is ~5MB RSS).
- Topic hierarchy maps cleanly to "fleet / role / pi / signal":
  `pi/<role>/<hostname>/health`, `pi/<role>/<hostname>/version`, etc.
- Battle-tested in IoT contexts; no need to invent a protocol.
- TLS + per-Pi client cert is a known recipe.

UDP TELEMETRY isn't competing — it stays as the show's tight low-latency
sync substrate. MQTT is the slow ambient channel: "how is the fleet
doing?", not "where is monitor 3 on its chapter?".

## Topic layout (proposed)

```
pi/<role>/<hostname>/health      retained, every 10s
pi/<role>/<hostname>/version     retained, on boot + on change
pi/<role>/<hostname>/online      retained, LWT-backed boolean
pi/<role>/<hostname>/log         non-retained, structured log lines
```

- `<role>` = `videosync-server`, `videosync-zero`, `mpv-loop`, etc.
  Set at image-bake time by the payload's `build.sh`.
- `<hostname>` = the Pi's hostname (already unique per image bake).
- `online` uses MQTT's Last Will and Testament so a clean death or a
  silent network drop both flip the retained value to `false`.
- `version` carries the same `version_hash.hash_code()` outputs that
  aether already computes, so staleness detection works across the fleet
  with one source of truth.

## Health payload (proposed)

```json
{
  "ts": 1736389234.12,
  "cpu_temp_c": 64.2,
  "ram_free_mb": 312,
  "disk_free_mb": 28104,
  "uptime_s": 8240,
  "wifi_rssi_dbm": -57,
  "throttled": 0,
  "load_1m": 0.42,
  "role": "videosync-zero",
  "version": "a1b2c3d…",
  "ip": "192.168.50.198"
}
```

Same field names as aether's `HealthSample` so subscribers can share
formatters. Optional fields a payload doesn't have are omitted.

## Where the bits live

This is a pi-image-build feature, not an aether feature, because every
payload should opt into it the same way they opt into
`install_boot_report`.

- `lib/mqtt-telemetry.sh` exposes
  `install_mqtt_telemetry --role <name> --broker <host:port> [--cert …]`.
  Generates a small Python daemon + systemd unit + timer in the chroot.
- The daemon is ~80 lines: paho-mqtt client, /proc + vcgencmd readers,
  LWT setup, retained publish on a fixed cadence.
- Existing aether `shared/version_hash.py` gets copied into the daemon
  at bake time so the code-version field is consistent with what aether
  already computes.

aether's videosync-server payload becomes a *subscriber*: the dashboard
already exists, gain a "fleet" tab that talks to the broker and surfaces
non-videosync Pis alongside the zeros.

## Open decisions

**(a) Broker placement.** Three viable hosts:
1. **The videosync server** (Pi 4, already running). Adds mosquitto to
   the server payload. Pro: zero net-new hardware. Con: now the broker
   is coupled to videosync availability — a server reboot kills fleet
   visibility for non-videosync Pis.
2. **Dedicated controller Pi.** Clean separation, but it's a Pi we have
   to procure, image, and physically install per venue.
3. **First-Pi-wins election.** Cute, fragile, probably not worth it for
   a 6-20 device fleet.
   
   My call: **(1) for v0**, with the broker config split out as a
   separate payload so a venue without a videosync server can drop the
   broker onto whichever Pi is there.

**(b) Authentication.** Three options:
1. Anonymous on the venue subnet (DREAM AP is isolated, only Pis +
   operator gear on it). Simplest.
2. Username/password baked at image build.
3. TLS + per-Pi client cert from a CA baked into the broker payload.
   pi-image-build already does ssh-keypair bake; cert bake is the same
   shape.
   
   My call: **(1) for v0**, **(3) when we put a non-isolated Pi on the
   public internet**. Username/password is the worst of both worlds.

**(c) Cadence.** 10s health, retained. Logs non-retained streaming.
Version on boot + on `version_hash` recompute. Open: what's the
recompute trigger? Maybe just on boot — code only changes after a
deploy, deploy restarts the daemon anyway.

**(d) MQTT v5 vs v3.1.1.** v5 has nicer features (request/response,
shared subscriptions, message expiry). Mosquitto supports both.
Defaulting to v5 means the broker version pin matters; v3.1.1 means
shared subscriptions don't work and we'd hand-roll fanout for any future
"command the fleet" feature.

  My call: **v5**. Pin mosquitto >= 2.0.

**(e) Should this replace UDP TELEMETRY?** No. UDP TELEMETRY is the
clock-sync substrate; latency-bound, optimized for the show. MQTT is the
ambient channel; throughput-bound, optimized for "is the fleet OK
tomorrow morning?". Different jobs.

## Path to v0

1. Land `lib/mqtt-telemetry.sh` in pi-image-build with the daemon.
2. Ship `examples/mqtt-broker/` as a standalone payload (mosquitto +
   default config + systemd unit). Smoke-test with the hello-payload.
3. Wire videosync's server payload to install both (broker + a "fleet"
   subscriber daemon).
4. Add a "fleet" tab to the aether dashboard that talks to the broker.
5. Mpv-loop opts in.

Real work: maybe a long weekend. Not blocking any show.

## What this gets us

- A new Pi on the venue wifi is visible within 10s of boot, regardless
  of project.
- "Why is this Pi unhappy?" goes from SSH-and-grep to one glance at a
  fleet view.
- Staleness detection (already half-built in aether) becomes a fleet
  property, not a per-project re-invention.
- Future "command the fleet" capabilities (restart-all, reboot-all,
  reflash-all) get a clean substrate to live on.
