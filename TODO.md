# TODO

## Composability principle

`pi-image-build/lib/` ships **capabilities**, not bundles. wifi, tailscale,
and mqtt-telemetry are orthogonal — a payload picks which to enable. Each
lib is venue-agnostic and project-agnostic; deployment-specific config
(which wifi, which tailnet, which broker) lives in the payload's `.env`,
not in the lib.

Concretely: an mpv-loop pi at Gospel and an mpv-loop pi at Alice's house
share the same image-build code path. They differ only in `.env` values
(wifi SSID, tailscale auth key, mqtt broker). The lib code never says the
word "Gospel" or "aether".

## lib/tailscale.sh — reachability layer

Install tailscale (apt) and auth via a pre-auth key in env (`TAILSCALE_AUTHKEY`).
Once running, every pi gets a stable name on the tailnet — `ssh pi@mpv-loop-5ce700`
works from anywhere, regardless of which wifi the pi is on or whether you're
even on that wifi yourself.

Replaces the entire "find the pi on the LAN" pain stack: mDNS dependency,
hostname-from-MAC for LAN discovery, being-on-the-same-wifi-to-debug. Those
become legacy fallbacks for "tailscale daemon hasn't come up yet". This is
probably the single highest-leverage thing on this list.

Should be installable from a one-liner in a payload's `build.sh`:
```
install_tailscale "$TAILSCALE_AUTHKEY" --hostname "${HOSTNAME:-}" --ssh
```

## lib/boot-report.sh — offline diagnostic snapshot

Two copies of the same script now exist (`aether/payload/_common/files/videosync-boot-report`
and `examples/mpv-loop/files/mpv-loop-boot-report`); both dump to `/boot/firmware/<name>-boot.log`
at T+90–180s. Differences are: log filename, the unit list to `is-active`,
which units' journals to tail. Everything else (radio info, scan, NM
profiles, rfkill state, drop-ins, boot errors) is identical.

Extract into `lib/boot-report.sh` exposing
`install_boot_report --log-name foo --units "a.service b.service" --journal-units "a.service"`.
Both aether and mpv-loop migrate; future payloads get it for free.

Worth keeping even after tailscale lands — it's the snapshot you read when
the pi never came up at all (so tailscale isn't running either), by pulling
the SD card.

## lib/mqtt-telemetry.sh — live telemetry agent

Generic agent. Each pi runs a small script on a systemd timer that publishes
to `$MQTT_BROKER` under a configurable topic prefix. Fields it always publishes:
hostname, uptime, load, soc temp, journal-tail of one named service.

The agent doesn't know which deployment it's part of — it just knows
`MQTT_BROKER`, `MQTT_TOPIC_PREFIX`, `MQTT_SERVICE_TO_WATCH` from env. The
Gospel-specific config (broker on aether-server, topic prefix `gospel/pi/`,
watch `mpv-loop.service`) lives in the payload's `.env`, not in the lib.

Subscriber-side starts as `mosquitto_sub -t 'gospel/#'` in a terminal.
Grows into whatever UI when staring at terminal output gets old. The UI is
its own project; pi-image-build only owns the agent.

Depends on tailscale being there first (so the broker URL can be a
tailnet name, not a public-internet thing).

## sim/ — toy-network dev fixture for downstream UIs

A `docker compose` fixture that runs the mqtt broker plus N fake pis
publishing realistic telemetry, so subscriber-side UIs can be built
against a plausible producer without flashing hardware. Not a test
harness — a dev environment.

Shape:

```
sim/
├── docker-compose.yml   # broker + pi-a/b/c containers
└── scenarios/
    ├── happy.env        # all pis healthy
    ├── flaky.env        # one pi's watched service is failed
    └── offline.env      # one pi stops publishing partway
```

Containers are `python:3-slim` + `paho-mqtt` running the same agent
script that ships in `modules/mqtt-telemetry/`. No image build, no apt,
no systemd, no chroot — the agent reads its config from env, so the
container is just `CMD ["python", "/agent.py"]`. Fidelity we lose:
nothing the UI will ever see.

Explicitly NOT in scope:
- Testing image-build, kernel boot, or systemd unit behavior
  (QEMU + real Pi own those).
- Testing tailscale reachability (needs TUN + control plane;
  separate problem if we ever want it).

Build this **with the first UI commit**, not before — otherwise the
scenarios will be guessed and the fixture will bitrot. If a one-shot
`scripts/fake-publisher.py` covers the need, prefer that and skip the
compose setup entirely.

Depends on the mqtt-telemetry agent actually existing on disk
(currently `modules/mqtt-telemetry/` is schema + module.sh only).

## Centralized pi command center (re-evaluate after tailscale lands)

The original idea was one CLI (`pi build mpv-loop`, `pi ssh mpv-loop-5ce700`,
`pi status`). Once tailscale is in, most of this is just `ssh pi@<name>` +
`mosquitto_sub` and the custom-CLI value drops to "build + flash convenience"
which is small enough to not need a unified tool.

Revisit only if there's something the trio (tailscale + mqtt + per-project
build wrapper) doesn't cover.

## RANDOM EXTRA THING
we still need to migrate videosync-server, videosync-client, and aether-game to the new system. boot-report, mqtt-telemetry. videosync-server holds the mqtt broker and the mqtt dashboard. videosync-client is airgapped except for access to videosync-server basically (via the AP) and doesn't need tailscale

we'll also need to migrate whatever else phil made, altho that should be just a matter of making a new module and configuring it similarly to mpv-loop (which is one of the things he asked me to make and which i made quite nicely.
once this is done we should be able to easily, neatly, cutely, access the dashboard through the aether SSID or through tailscale. whatever. who cares. and then we can track all of our things.)

and going forward we can add more telemetry. ideally, any application should be able to instrument itself with some additional mqtt data and then we have a free consumer already setup. like, the aether-game reporting player scores is kind of a neat idea. we have these fuckin orb/sphere things that phil has that have esp32s, which could also be hooked into this if he can program them.
