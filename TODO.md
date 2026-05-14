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

## Centralized pi command center (re-evaluate after tailscale lands)

The original idea was one CLI (`pi build mpv-loop`, `pi ssh mpv-loop-5ce700`,
`pi status`). Once tailscale is in, most of this is just `ssh pi@<name>` +
`mosquitto_sub` and the custom-CLI value drops to "build + flash convenience"
which is small enough to not need a unified tool.

Revisit only if there's something the trio (tailscale + mqtt + per-project
build wrapper) doesn't cover.
