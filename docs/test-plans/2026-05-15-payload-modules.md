# Human Test Plan — payload-modules

Hardware-dependent acceptance criteria for the payload-modules implementation. Six deferred ACs plus one prose meta-assertion require an operator with physical Pi hardware and (in some cases) live external services.

## Prerequisites

- Pi 4 or Zero 2 W with SD card slot and HDMI capability
- macOS workstation with this repo checked out at `HEAD = 3579bb1`
- `bin/build-image.sh`, `bin/flash-image.sh` working; pipeline Docker image built
- SD card reader on the workstation
- For AC5.2: a Tailscale account with permission to mint auth keys
- For AC7.2/AC7.3: a reachable MQTT broker (`brew install mosquitto && mosquitto -v` on the workstation, or aether-server over tailnet) and the `mosquitto_sub` CLI
- For AC8.3: HDMI display + cable

Automated suite pre-flight (must already be green before any of the below):

- `python3 -m pytest tests/ -v` (52 passed)
- `bash -n bin/build-image.sh bin/diff-images.sh lib/modules-loader.sh`

## Phase H1: Real-hardware boot — core-only image (AC3.2)

Purpose: validate that an image built from `core` alone actually boots a Pi and accepts SSH with the configured key.

| Step | Action | Expected |
|------|--------|----------|
| 1 | `mkdir /tmp/core-test && cat > /tmp/core-test/modules.list <<<core && cat > /tmp/core-test/.env <<EOF`<br>`HOSTNAME=acceptance-core`<br>`TIMEZONE=UTC`<br>`PI_USER=pi`<br>`ENCRYPTED_PASSWORD=$(openssl passwd -6 changeme)`<br>`SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"`<br>`EOF` | Files created; payload has new-contract shape |
| 2 | `bin/build-image.sh /tmp/core-test --output-format gz` | Exit 0; image written to `out/core-test-*.img.gz` |
| 3 | `bin/flash-image.sh out/core-test-*.img.gz` | Operator selects correct SD card; write completes; macOS auto-ejects |
| 4 | Insert SD into Pi, attach Ethernet (no wifi creds in core-only), power on. Start a stopwatch | Green LED activity within ~5s |
| 5 | Find the Pi's IP (router DHCP table or `arp -a | grep -i b8:27`/`d8:3a:dd`/`dc:a6:32`). Wait until ~60s after power-on | IP reachable to `ping` |
| 6 | `ssh pi@<pi-ip> 'uname -a; hostname'` (no password prompt — key auth only) | Login succeeds; hostname prints `acceptance-core`; `uname -a` shows arm64 Linux |
| 7 | `ssh pi@<pi-ip> 'sudo -n true && echo ok'` | Prints `ok` (NOPASSWD sudoers entry from `core` is live) |

Evidence to capture: terminal log of steps 6 + 7.

## Phase H2: Tailscale firstboot enrollment (AC5.2)

Purpose: validate that `tailscale-firstboot.service` actually enrolls the Pi and then self-disables.

| Step | Action | Expected |
|------|--------|----------|
| 1 | At `https://login.tailscale.com/admin/settings/keys`, mint a **reusable** auth key, copy the `tskey-auth-…` string | Key stored on clipboard |
| 2 | `mkdir /tmp/ts-test && cat > /tmp/ts-test/modules.list <<EOF`<br>`core`<br>`tailscale`<br>`EOF` — then populate `/tmp/ts-test/.env` with the same `HOSTNAME=acceptance-ts`, locale, user, ssh keys as H1, plus `TAILSCALE_AUTHKEY=<minted key>` and `TAILSCALE_HOSTNAME=acceptance-test-pi` | `.env` complete |
| 3 | `bin/build-image.sh /tmp/ts-test --output-format gz` then `bin/flash-image.sh out/ts-test-*.img.gz` | Build + flash succeed |
| 4 | On a separate tailnet-joined device, open `https://login.tailscale.com/admin/machines` in a browser (or run `watch -n2 tailscale status`) | Current list of machines visible |
| 5 | Insert SD into Pi, attach internet-routable Ethernet, power on; start stopwatch | Pi powers up |
| 6 | Watch the admin console for `acceptance-test-pi` to appear as **online** | Hostname appears within ~60s of power-on |
| 7 | SSH in: `ssh pi@acceptance-test-pi` (via tailnet) `'systemctl is-enabled tailscale-firstboot.service; test -f /var/lib/tailscale/firstboot-done && echo done-marker-present'` | Prints `disabled` and `done-marker-present` (self-disable worked) |
| 8 | From admin console, **revoke** the test auth key | Key removed; existing enrollment preserved |

Evidence: screenshot of admin console showing `acceptance-test-pi` online with timestamp; terminal output of step 7. Note elapsed wall-clock seconds between step 5 power-on and step 6 appearance.

## Phase H3: Boot report on FAT partition (AC6.2)

Purpose: validate that `pibuild-boot-report.timer` fires twice and writes both reports to the FAT bootfs.

| Step | Action | Expected |
|------|--------|----------|
| 1 | `mkdir /tmp/br-test && cat > /tmp/br-test/modules.list <<EOF`<br>`core`<br>`boot-report`<br>`EOF` — `.env` as in H1, no extra boot-report vars (defaults) | Payload prepared |
| 2 | `bin/build-image.sh /tmp/br-test --output-format gz && bin/flash-image.sh out/br-test-*.img.gz` | Build + flash succeed |
| 3 | Insert SD into Pi, attach Ethernet, power on; start stopwatch | Pi boots |
| 4 | Wait ≥ 4 minutes (T+180s report + slack) | Time elapsed |
| 5 | Power off the Pi (cleanly via `ssh pi@<ip> 'sudo poweroff'` OR yank cord — either works; the timer writes the file before T+180s completes) | Pi off |
| 6 | Pull SD card, insert into Mac; the FAT volume `bootfs` mounts at `/Volumes/bootfs` | Volume visible |
| 7 | `cat /Volumes/bootfs/boot.log` | File exists; contains **two** blocks each starting with `boot report: <timestamp>` separated by `======================================================================` |
| 8 | Confirm each block contains all sections: `--- wifi radio ---`, `--- wlan0 addresses ---`, `--- visible SSIDs (scan) ---`, `--- NetworkManager ---`, `--- systemd-rfkill state ---`, `--- NM drop-ins ---`, `--- boot-time errors ---` | All seven section headers per block |
| 9 | Confirm timestamps in the two blocks are ~90s apart (T+90s and T+180s) | Difference between block 1 and block 2 timestamps ≈ 90s ± 5s |

Evidence: copy `boot.log` to a PR comment or attach to the AC6.2 sign-off ticket.

## Phase H4: MQTT telemetry — health + LWT (AC7.2 + AC7.3)

Purpose: validate that mqtt-telemetry publishes health within 30s of boot AND that LWT flips `online` to `false` on ungraceful power-off.

### H4a (AC7.2): retained messages within 30s

| Step | Action | Expected |
|------|--------|----------|
| 1 | On workstation: `brew install mosquitto && mosquitto -v` in a dedicated terminal — note the IP/hostname mosquitto binds (default `0.0.0.0:1883`). If the Pi will reach mosquitto over tailnet, use the tailnet name; if LAN, use the workstation's LAN IP | Broker listening on `:1883` |
| 2 | In a second terminal: `mosquitto_sub -h <broker-host> -t 'pi/+/+/#' -v` | Subscriber attached, no output yet |
| 3 | `mkdir /tmp/mqtt-test && cat > /tmp/mqtt-test/modules.list <<EOF`<br>`core`<br>`mqtt-telemetry`<br>`EOF` — `.env` as in H1 plus `MQTT_BROKER=<broker-host>:1883`, `MQTT_ROLE=acceptance-test` | Payload prepared |
| 4 | `bin/build-image.sh /tmp/mqtt-test --output-format gz && bin/flash-image.sh out/mqtt-test-*.img.gz` | Build + flash succeed |
| 5 | Insert SD into Pi, attach network reaching broker, power on; start stopwatch | Pi boots |
| 6 | Watch the subscriber terminal | Within ~30s: `pi/acceptance-test/<hostname>/online true`, `pi/acceptance-test/<hostname>/version <…>`, `pi/acceptance-test/<hostname>/health {<json>}` all arrive |
| 7 | Note elapsed wall-clock seconds from step 5 to first `online true` | ≤ 30s |
| 8 | Leave Pi running ≥ 60s; observe ≥ 6 successive `…/health` messages (10s cadence per design) | Cadence confirmed |

### H4b (AC7.3): LWT on power-loss

| Step | Action | Expected |
|------|--------|----------|
| 9 | Keep subscriber from H4a attached | Stream still flowing |
| 10 | **Yank the Pi's power cord** (do NOT `shutdown -h now` — clean exit masks LWT) | Power dies |
| 11 | Watch subscriber | Within ~75s (keepalive timeout + grace), broker publishes retained `pi/acceptance-test/<hostname>/online false` |
| 12 | In a third terminal: `mosquitto_sub -h <broker-host> -t 'pi/+/+/online' -v` (fresh subscriber) | **Immediately** receives retained `pi/acceptance-test/<hostname>/online false` (validates retention) |

Evidence for H4a + H4b: full subscriber transcript saved (timestamps via `ts` or `mosquitto_sub --pretty -F '%I %t %p'`). Note elapsed times.

## Phase H5: mpv-loop on hardware (AC8.3)

Purpose: validate the post-migration `examples/mpv-loop` actually boots and plays video on real hardware (the migration's image-equivalence is already proven by AC8.2; this confirms equivalence translates to runtime behavior).

| Step | Action | Expected |
|------|--------|----------|
| 1 | Configure `examples/mpv-loop/.env` (copy from `.env.example`, set `PI_PASSWORD`, `SSH_PUBKEY_FILE`, `VIDEO=<path to test loop>`, AP creds if needed). Drop a known-good test video into `examples/mpv-loop/content/` if VIDEO points there | `.env` populated |
| 2 | `examples/mpv-loop/build-example.sh --output out/mpv-loop-post-migration.img.gz --output-format gz` | Build exit 0; image present |
| 3 | `bin/flash-image.sh out/mpv-loop-post-migration.img.gz` | Flash succeeds |
| 4 | Connect Pi to HDMI display, power on Pi after display is ready | Display shows boot text |
| 5 | Wait for configured video to start playing on the HDMI display | Video plays within ~60s; loops cleanly |
| 6 | SSH in: `ssh pi@<pi-ip> 'systemctl status mpv-loop.service'` | Service `active (running)`; recent log line shows mpv started |
| 7 | Visually compare to a pre-migration mpv-loop boot (if a Pi running the legacy build is available): same video, same loop behavior, same audio routing | Behavior matches baseline |

Evidence: photo of the Pi-driven HDMI showing the loop; terminal output of step 6. Operator narrative comparing to pre-migration behavior.

## End-to-End: Full-fleet smoke (optional but recommended before merge)

Purpose: validate that all four repo-level modules compose without surprise interaction.

Steps:

1. Build a payload with `modules.list` = `core`, `tailscale`, `boot-report`, `mqtt-telemetry` and `.env` covering every required var across the four schemas (`HOSTNAME`, `TIMEZONE`, `PI_USER`, `ENCRYPTED_PASSWORD`, `SSH_PUBKEY`, `TAILSCALE_AUTHKEY`, `MQTT_BROKER`, `MQTT_ROLE`).
2. Flash, boot Pi, with both broker and tailnet observers attached.
3. Within 60s expect: Pi visible on tailnet (H2 signal), MQTT health flowing (H4a signal), SSH reachable (H1 signal).
4. After 4 min: power off, pull SD, confirm two boot-report blocks (H3 signal).

Records that all four capability modules work in combination, not just individually.

## Human Verification Required

| Criterion | Why Manual | Steps |
|-----------|------------|-------|
| AC3.2 — image boots on real Pi | Bootloader / firmware / kernel cmdline / real hardware interactions invisible from a chroot mount | Phase H1 |
| AC5.2 — tailscale appears on tailnet within ~60s | Live Tailscale control plane + internet egress + wall-clock window | Phase H2 |
| AC6.2 — boot reports present on FAT at T+90s and T+180s | systemd timer fires on real boot clock; output only exists at runtime | Phase H3 |
| AC7.2 — mqtt-telemetry retained messages within 30s | Live broker, live NIC, live network | Phase H4a |
| AC7.3 — LWT flips `online` to `false` on power-off | Requires ungraceful disconnect; only observable via a real subscriber against a real broker | Phase H4b |
| AC8.3 — mpv-loop video plays on HDMI | mpv on KMS rendering to real GPU/display; no headless analog | Phase H5 |
| AC8.4 — surviving deltas documented (meta-assertion) | "Documented benignly" is a prose judgement, not a runtime check | Reviewer checks PR: either AC8.2 is clean PASS with no ignore additions OR each ignore addition / waived delta has a comment naming the path + entropy source + why benign |
