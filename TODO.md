# TODO

## Centralized pi command center

Every pi project (aether server, aether zero, mpv-loop, future ones) reinvents the same dance: a `.env`, a wrapper that loads it + derives ENCRYPTED_PASSWORD/SSH_PUBKEY, a call into `bin/build-image.sh`, then `bin/flash-image.sh`, then ssh/journalctl to whichever pi. The wrappers diverge (aether's `_lib-build.sh` is heavyweight with profiles + prefix-grouped envs; mpv-loop's `build-example.sh` is a stripped-down copy of the same idea).

Want: one CLI (`pi`?) that knows about registered projects, can `pi build mpv-loop`, `pi flash mpv-loop`, `pi ssh <host>`, `pi log <host>`, maybe `pi status` showing which pis are up. Probably lives here in pi-image-build since it owns the build pipeline; project-specific bits register via a manifest (payload dir, env-regex, default mounts, default output format).

Not today.

## Hoist boot-report into pi-image-build/lib

There are now two copies of essentially the same script:

- `aether/payload/_common/files/videosync-boot-report` (origin)
- `examples/mpv-loop/files/mpv-loop-boot-report` (copy with the videosync-specific units swapped for mpv-loop ones)

Both dump to a `*-boot.log` on `/boot/firmware/` (FAT, macOS-readable) at T+90–180s. Differences are: log filename, the unit list to `is-active`, and which units' journals to tail. Everything else (radio info, scan, NM profiles, rfkill state, drop-ins, boot errors) is identical.

Extract into `lib/boot-report.sh` exposing something like `install_boot_report --log-name foo --units "a.service b.service" --journal-units "a.service"`. Generates the script + service + timer in the chroot. Both aether and mpv-loop migrate; future payloads get it for free.

Tied to (and a stepping-stone toward) the MQTT telemetry layer below.

## MQTT telemetry / health layer baked into pi-image-build

Pull the videosync server's per-pi health logic out into a generic telemetry agent that ships in every pi-image-build image (zero, mpv-loop, future). Each pi publishes uptime / load / temp / journal-tail to MQTT; a server (or just `mosquitto_sub`) aggregates. Decouples telemetry from videosync — mpv-loop pis would be visible without pretending to be videosync clients. Aspirational; design when there are 2+ projects that need it (mpv-loop is the second, so: soon-ish).
