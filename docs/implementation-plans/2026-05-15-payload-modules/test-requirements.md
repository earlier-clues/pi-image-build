# Test Requirements: payload-modules

Each acceptance criterion from `docs/design-plans/2026-05-15-payload-modules.md` is mapped to either an automated test (runnable from the project pipeline) or a human-verification step (real Pi, SD card, live broker, live tailnet, or operator review). Cross-referenced against the "Verifies:" lines in `phase_01.md` … `phase_07.md`.

## Coverage summary

| AC | Automated? | Test location / Operator action |
|----|------------|---------------------------------|
| AC1.1 | Yes | e2e: `bin/build-image.sh examples/loader-smoke` builds end-to-end |
| AC1.2 | Yes | functional: `bash -c '… parse_modules_list …'` on a comment/blank-line fixture |
| AC1.3 | Yes | functional: `bash -c '… resolve_module …'` on a payload-local-shadows-repo fixture |
| AC1.4 | Yes | e2e: stdout contains `env-file: …/.env` on `examples/loader-smoke` build |
| AC1.5 | Yes | negative: `bin/build-image.sh examples/loader-smoke --env-file /dev/null` exits 2, stderr names var + module |
| AC1.6 | Yes | negative: tempdir with two require-failing modules; stderr names both vars |
| AC1.7 | Yes | negative: tempdir with `modules.list = nosuch-module`; stderr names `nosuch-module` |
| AC1.8 | Yes | negative: tempdir with duplicate entries in `modules.list`; stderr says `duplicate` |
| AC1.9 | Yes | functional: `validate_schemas` on `optional FOO default=bar` (FOO unset) emits `export FOO=bar` |
| AC2.1 | Yes | e2e: `bin/build-image.sh examples/hello-payload` (legacy git ref) builds end-to-end |
| AC2.2 | Yes | functional: `git diff --stat <phase-base> -- lib/{hostname,locale,user,ssh,wifi,apt}.sh` is empty |
| AC2.3 | Yes | negative: `bin/build-image.sh` on an empty tempdir; stderr names both `modules.list` and `build.sh` |
| AC3.1 | Yes | e2e: build temp `core`-only payload, kpartx-mount, inspect rootfs for every baseline mutation |
| AC3.2 | **Human** | Flash core-only image to SD, boot Pi, confirm POST + login |
| AC3.3 | Yes | Subsumed by AC8.2 (image-diff gate proves `core` is strictly-superset of pre-migration mpv-loop baseline) |
| AC4.1 | Yes | filesystem: assert `examples/hello-payload/` has `modules.list`, `.env.example`, `modules/hello/`; no `build.sh` |
| AC4.2 | Yes | e2e: build `examples/hello-payload`, kpartx-mount, assert `/etc/pibuild-hello` exists |
| AC5.1 | Yes | e2e: build `core + tailscale` temp payload, kpartx-mount, assert `tailscale` binary + substituted `tailscale-firstboot.service` present |
| AC5.2 | **Human** | Flash tailscale-enabled image, boot Pi, watch tailnet admin console for hostname appearance within ~60s |
| AC5.3 | Yes | mount inspect: rendered `tailscale-firstboot.service` contains `ExecStartPost=… systemctl disable tailscale-firstboot.service` + `ConditionPathExists=!/var/lib/tailscale/firstboot-done` |
| AC5.4 | Yes | negative: `validate_schemas modules/tailscale` with `TAILSCALE_AUTHKEY` unset; stderr names var + module |
| AC6.1 | Yes | e2e: build `core + boot-report` temp payload, kpartx-mount, assert script + `.service` + `.timer` present and timer enabled |
| AC6.2 | **Human** | Flash boot-report image, boot Pi, wait 4 minutes, power off, pull SD, read `/boot/firmware/boot.log` on Mac/Linux, confirm two report blocks present |
| AC6.3 | Yes | mount inspect: rendered `pibuild-boot-report` script has `LOG=/boot/firmware/boot.log`, `UNITS=""`, `JOURNAL_UNITS=""` |
| AC7.1 | Yes | e2e: build `core + mqtt-telemetry` temp payload, kpartx-mount, assert daemon + launcher + substituted unit + `python3-paho-mqtt` present |
| AC7.2 | **Human** | Run mosquitto broker, flash mqtt-telemetry image pointed at broker, boot Pi, observe `mosquitto_sub -t 'pi/+/+/health'` within 30s |
| AC7.3 | **Human** | After AC7.2 confirmation, power off Pi; observe `pi/<role>/<hostname>/online` flip to `false` retained within ~75s |
| AC7.4 | Yes | pytest: `tests/test_mqtt_telemetry_parsers.py` covers every pure parser |
| AC7.5 | Yes | negative: `validate_schemas modules/mqtt-telemetry` with `MQTT_BROKER` and `MQTT_ROLE` unset; stderr names both vars + module |
| AC8.1 | Yes | filesystem: assert `examples/mpv-loop/` has `modules.list = core + mpv-loop`, `.env.example`, `modules/mpv-loop/`; no top-level `build.sh`; no `files/` |
| AC8.2 | Yes | `bin/diff-images.sh out/mpv-loop-pre-migration.img.gz out/mpv-loop-post-migration.img.gz` exits 0 |
| AC8.3 | **Human** | Flash post-migration mpv-loop image, boot Pi, confirm `mpv-loop.service` starts and video plays |
| AC8.4 | **Human** | Operator review: any ignore-list addition or surviving delta in Phase 7 is documented with benign explanation in design plan / PR comment |
| AC9.1 | Yes | grep: `README.md` contains "Authoring a payload" section with code-fenced walkthroughs of `hello-payload` and `mpv-loop` |
| AC9.2 | Yes | grep: `README.md` documents the schema.sh-is-env-var-docs convention + optional `modules/<name>/README.md` |

---

## Automated Tests

### payload-modules.AC1.1 Success: `bin/build-image.sh` on `modules.list` payload builds end-to-end
- **Type**: e2e operational
- **Test**: `bin/build-image.sh examples/loader-smoke --output-format gz`
- **Asserts**: exit 0; stdout includes `==> parsing modules.list`, `==> validating schemas`, `==> modules: smoke`; output image produced at `out/loader-smoke-*.img.gz`.

### payload-modules.AC1.2 Success: module order matches file order; comments/blanks ignored
- **Type**: unit (shell functional)
- **Test**: inline `bash -c 'source lib/modules-loader.sh; mapfile -t arr < <(parse_modules_list <(printf "# c\n\nfoo\nbar\n  # c2\nbaz\n")); declare -p arr'`
- **Asserts**: array is `(foo bar baz)` in that order, comments + blanks stripped, no exit error.

### payload-modules.AC1.3 Success: payload-local module shadows repo-level
- **Type**: unit (shell functional)
- **Test**: Phase 1 / Task 5 V3 script — tempdir with both `<payload>/modules/foo/` and `<repo-modules>/foo/`; call `resolve_module foo …`; then delete the payload-local copy and re-call.
- **Asserts**: first call returns payload-local path; second call returns repo-level path.

### payload-modules.AC1.4 Success: `<payload>/.env` auto-sourced; `--env-file FILE` wins
- **Type**: e2e operational
- **Test**: `bin/build-image.sh examples/loader-smoke --output-format gz` (auto-source) then `bin/build-image.sh examples/loader-smoke --env-file /tmp/alt-env --output-format gz` (override).
- **Asserts**: first run's stdout contains `env-file: …/examples/loader-smoke/.env`; second run's stdout contains `env-file: /tmp/alt-env`.

### payload-modules.AC1.5 Failure: missing `require` aborts host-side with named var + module
- **Type**: negative integration
- **Test**: Phase 1 / Task 5 V4 — `( unset SMOKE_MESSAGE; bin/build-image.sh examples/loader-smoke --env-file /dev/null --output-format gz )`
- **Asserts**: exit 2; stderr contains both `SMOKE_MESSAGE` and `smoke`; docker is never invoked (no new container with the build tag).

### payload-modules.AC1.6 Failure: multiple `require` failures all reported in one pass
- **Type**: negative integration
- **Test**: Phase 1 / Task 5 V5 — tempdir payload with two modules each declaring a different unset `require`; build with `--env-file /dev/null`.
- **Asserts**: exit 2; stderr contains BOTH `VAR_AAA` and `VAR_BBB`.

### payload-modules.AC1.7 Failure: unresolved module name aborts with clear error
- **Type**: negative integration
- **Test**: Phase 1 / Task 5 V6 — tempdir with `modules.list` containing `nosuch-module`; build.
- **Asserts**: exit 2; stderr contains `nosuch-module`.

### payload-modules.AC1.8 Failure: duplicate module in `modules.list` aborts
- **Type**: negative integration
- **Test**: Phase 1 / Task 5 V7 — tempdir with `modules/dup/` and `modules.list = dup\ndup`; build.
- **Asserts**: exit 2; stderr matches `/duplicate/i` and contains `dup`.

### payload-modules.AC1.9 Edge: `optional X default=Y` sets and exports X=Y when unset
- **Type**: unit (shell functional)
- **Test**: `( unset FOO; source lib/modules-loader.sh; tmp=$(mktemp -d); printf 'optional FOO default=bar\n' > $tmp/schema.sh; touch $tmp/module.sh; validate_schemas "$tmp" )`
- **Asserts**: stdout contains `export FOO=bar`; with `FOO=preset` pre-set, stdout contains `export FOO=preset`.

### payload-modules.AC2.1 Success: legacy `build.sh` payload builds unchanged
- **Type**: e2e operational
- **Test**: Phase 1 / Task 5 V1 — `HOSTNAME=hellopi TIMEZONE=UTC bin/build-image.sh examples/hello-payload --output-format gz` against the git ref where hello-payload still has its legacy `build.sh` (i.e. before Phase 3).
- **Asserts**: exit 0; image produced; `git diff lib/` is empty.

### payload-modules.AC2.2 Success: `lib/*.sh` function signatures unchanged
- **Type**: unit (git diff)
- **Test**: Phase 1 / Task 5 V10 — `git diff --stat $PHASE_BASE -- lib/hostname.sh lib/locale.sh lib/user.sh lib/ssh.sh lib/wifi.sh lib/apt.sh`
- **Asserts**: zero lines of output (no existing lib/*.sh modified by this work; `lib/modules-loader.sh`, `lib/tailscale.sh`, `lib/boot-report.sh`, `lib/mqtt-telemetry.sh` are new additions and excluded from this check).

### payload-modules.AC2.3 Failure: payload with neither `modules.list` nor `build.sh` aborts
- **Type**: negative integration
- **Test**: Phase 1 / Task 5 V8 — empty tempdir; `bin/build-image.sh "$TMP" --output-format gz`.
- **Asserts**: exit 2; stderr names both `modules.list` and `build.sh`.

### payload-modules.AC3.1 Success: `core` produces image with all baseline mutations
- **Type**: e2e operational + filesystem inspection
- **Test**: Phase 2 / Task 3 — build temp `/tmp/core-test` payload (`modules.list = core`, populated `.env`), then kpartx-mount the resulting `img.gz` and inspect the rootfs via the inspection container.
- **Asserts**: `/etc/hostname` = `core-test`; `/etc/hosts` has `127.0.1.1 core-test`; `/etc/timezone` = `UTC`; `/etc/default/keyboard` has `XKBLAYOUT="us"`; `pi` in `/etc/passwd`; `/etc/sudoers.d/010-pi-nopasswd` present; `userconfig.service` symlinked to `/dev/null`; `/home/pi/.ssh/authorized_keys` contains the configured pubkey; `/etc/ssh/sshd_config.d/10-pi-image-build.conf` exists with `PasswordAuthentication no`; ssh.service enabled; `pibuild-wifi-regdom.service` installed + enabled; `systemd-rfkill.service` and `.socket` symlinked to `/dev/null`; `/var/lib/NetworkManager/NetworkManager.state` has `WirelessEnabled=true`; `/etc/systemd/system/NetworkManager.service.d/pibuild-unblock.conf` exists; `/etc/machine-id` is size 0; `/var/lib/dbus/machine-id` absent.

### payload-modules.AC3.3 Edge: `core` strictly-superset of pre-migration mpv-loop baseline
- **Type**: e2e operational (subsumed)
- **Test**: Satisfied transitively by AC8.2 — if `bin/diff-images.sh` returns 0 between pre- and post-migration mpv-loop images, every baseline mutation in pre-migration is reproduced by `core` (or accounted for by the ignore list). No separate automated check.
- **Asserts**: see AC8.2.

### payload-modules.AC4.1 Success: `examples/hello-payload/` has the new-contract shape
- **Type**: unit (filesystem check)
- **Test**: `bash -c 'set -e; [[ ! -f examples/hello-payload/build.sh ]]; [[ -f examples/hello-payload/modules.list ]]; [[ -f examples/hello-payload/.env.example ]]; [[ -d examples/hello-payload/modules/hello ]]'`
- **Asserts**: no top-level `build.sh`; `modules.list`, `.env.example`, and `modules/hello/` are present; exit 0.

### payload-modules.AC4.2 Success: `examples/hello-payload` image contains `/etc/pibuild-hello`
- **Type**: e2e operational + filesystem inspection
- **Test**: Phase 3 / Task 5 — `bin/build-image.sh examples/hello-payload --output-format gz`, then kpartx-mount the image and `cat /mnt/r/etc/pibuild-hello`.
- **Asserts**: file exists; first line starts with `pi-image-build hello-payload OK at`.

### payload-modules.AC5.1 Success: `core + tailscale` image has tailscale + firstboot service
- **Type**: e2e operational + filesystem inspection
- **Test**: Phase 4 / Task 3 — build temp `/tmp/tailscale-test` payload with a fake auth key, kpartx-mount, inspect.
- **Asserts**: `/usr/bin/tailscale` and `/usr/sbin/tailscaled` present; `/etc/systemd/system/tailscale-firstboot.service` exists with `ExecStart=/usr/bin/tailscale up --auth-key=tskey-auth-FAKE…`; unit enabled in `multi-user.target.wants/`; no `@@…@@` placeholders survive.

### payload-modules.AC5.3 Success: `tailscale-firstboot.service` disables itself after first run
- **Type**: unit (filesystem inspection of rendered unit)
- **Test**: Phase 4 / Task 3 inspection step — grep the rendered service file inside the mounted rootfs.
- **Asserts**: `ExecStartPost=` line contains `systemctl disable tailscale-firstboot.service` and writes `/var/lib/tailscale/firstboot-done`; `ConditionPathExists=!/var/lib/tailscale/firstboot-done` present.

### payload-modules.AC5.4 Failure: missing `TAILSCALE_AUTHKEY` aborts host-side
- **Type**: negative integration
- **Test**: Phase 4 / Task 2 — `( unset TAILSCALE_AUTHKEY; bash -c 'source lib/modules-loader.sh; validate_schemas "$(pwd)/modules/tailscale"' )`
- **Asserts**: exit 2; stderr contains both `TAILSCALE_AUTHKEY` and `tailscale`.

### payload-modules.AC6.1 Success: `core + boot-report` image has script + service + timer
- **Type**: e2e operational + filesystem inspection
- **Test**: Phase 5 / Task 3 — build temp `/tmp/boot-report-test` payload, kpartx-mount, inspect.
- **Asserts**: `/usr/local/bin/pibuild-boot-report` mode 755; `/etc/systemd/system/pibuild-boot-report.service` and `…timer` present; timer symlinked into `timers.target.wants/`.

### payload-modules.AC6.3 Edge: default `BOOT_REPORT_*` values render correctly
- **Type**: unit (filesystem inspection of rendered template)
- **Test**: Phase 5 / Task 3 inspection step — grep the rendered `/usr/local/bin/pibuild-boot-report` script.
- **Asserts**: `LOG=/boot/firmware/boot.log`; `UNITS=""`; `JOURNAL_UNITS=""`; no surviving `@@…@@` placeholders.

### payload-modules.AC7.1 Success: `core + mqtt-telemetry` image has daemon + unit
- **Type**: e2e operational + filesystem inspection
- **Test**: Phase 6 / Task 5 — build temp `/tmp/mqtt-test` payload, kpartx-mount, inspect.
- **Asserts**: `/usr/local/bin/pibuild-mqtt-telemetry` and `/usr/local/bin/pibuild-mqtt-telemetry-launch` present; `/etc/systemd/system/pibuild-mqtt-telemetry.service` contains `MQTT_ROLE=mqtt-test` and `MQTT_BROKER=test-broker.invalid:1883`; unit enabled; `paho.mqtt` Python package installed under `/usr/lib/python3/dist-packages/paho/mqtt/`; no surviving `@@…@@` placeholders.

### payload-modules.AC7.4 Success: Python parser unit tests pass
- **Type**: unit (pytest)
- **Test**: `python3 -m pytest tests/test_mqtt_telemetry_parsers.py -v`
- **Asserts**: every parser (`parse_thermal_temp`, `parse_vcgencmd_temp`, `parse_vcgencmd_throttled`, `parse_meminfo`, `parse_uptime`, `parse_loadavg`, `parse_iw_link_rssi`, `parse_ip_addr_v4`, `parse_broker`, `collect_health`) has happy-path + edge-case assertions and all pass.

### payload-modules.AC7.5 Failure: missing `MQTT_BROKER` or `MQTT_ROLE` aborts host-side
- **Type**: negative integration
- **Test**: Phase 6 / Task 3 — `( unset MQTT_BROKER MQTT_ROLE; bash -c 'source lib/modules-loader.sh; validate_schemas "$(pwd)/modules/mqtt-telemetry"' )`
- **Asserts**: exit 2; stderr contains `MQTT_BROKER`, `MQTT_ROLE`, and `mqtt-telemetry`.

### payload-modules.AC8.1 Success: `examples/mpv-loop/` has the new-contract shape
- **Type**: unit (filesystem check)
- **Test**: `bash -c 'set -e; [[ ! -f examples/mpv-loop/build.sh ]]; [[ ! -d examples/mpv-loop/files ]]; [[ -f examples/mpv-loop/modules.list ]]; [[ -f examples/mpv-loop/.env.example ]]; [[ -d examples/mpv-loop/modules/mpv-loop/files ]]; grep -qx core examples/mpv-loop/modules.list; grep -qx mpv-loop examples/mpv-loop/modules.list'`
- **Asserts**: no top-level `build.sh`; no top-level `files/`; `modules.list`, `.env.example`, `modules/mpv-loop/`, and `modules/mpv-loop/files/` are present; `modules.list` lists both `core` and `mpv-loop`.

### payload-modules.AC8.2 Success: pre/post-migration mpv-loop images diff-equivalent
- **Type**: integration (image diff)
- **Test**: Phase 7 / Task 5 — `bin/diff-images.sh out/mpv-loop-pre-migration.img.gz out/mpv-loop-post-migration.img.gz`
- **Asserts**: exit 0; stdout prints `PASS: no surviving differences.`

### payload-modules.AC9.1 Success: README contains "Authoring a payload" section
- **Type**: unit (grep)
- **Test**: `bash -c 'grep -q "^## Authoring a payload" README.md && grep -q "examples/hello-payload" README.md && grep -q "examples/mpv-loop" README.md'`
- **Asserts**: section heading present; both example payloads referenced in code-fenced walkthroughs.

### payload-modules.AC9.2 Success: module catalog convention documented
- **Type**: unit (grep)
- **Test**: `bash -c 'grep -q "schema.sh" README.md && grep -q "modules/<name>/README.md" README.md && grep -E -q "core.*tailscale.*boot-report.*mqtt-telemetry" README.md'` (the third grep against the catalog table reading row-by-row, or substitute a multi-line `grep -A` for the table block).
- **Asserts**: README documents that `schema.sh` is the env-var documentation source and that optional `modules/<name>/README.md` is the longer-prose home; module catalog table lists all four repo-level modules with their env vars.

---

## Human Verification

### payload-modules.AC3.2: Image boots on real Pi hardware
- **Justification**: A booting OS exercises bootloader, kernel cmdline, initramfs, systemd target ordering, and physical hardware (UART, USB, HDMI, SD reader) — none of which are observable from inside a build container that only sees the offline filesystem. Emulating a Pi under QEMU would still miss firmware-level interactions.
- **Procedure**:
  1. Build `core`-only test image: `bin/build-image.sh /tmp/core-test --output-format gz` (per Phase 2 / Task 3 setup).
  2. Flash to SD: `bin/flash-image.sh out/core-test-*.img.gz`.
  3. Insert SD into a Pi (4 or Zero 2 W), connect ethernet (no wifi creds in core-only `.env`), power on.
  4. Wait ~60s. Attempt SSH: `ssh pi@<pi-ip>` using the key from the configured `SSH_PUBKEY`.
- **Evidence**: screenshot or terminal log of successful SSH session; `uname -a` and `hostname` output from the Pi captured in the operator's test-run notes.

### payload-modules.AC5.2: Pi appears on tailnet within ~60s of first boot
- **Justification**: Requires the live Tailscale control plane to accept the auth key, an internet-routable network from the Pi, and a clock-aware 60s window. None of those are simulable from the build pipeline.
- **Procedure**:
  1. Mint a real tailscale auth key from `https://login.tailscale.com/admin/settings/keys`.
  2. Build a `core + tailscale` payload with that key in `.env` and a known `TAILSCALE_HOSTNAME` (e.g., `acceptance-test-pi`).
  3. Flash + boot the Pi on an internet-connected ethernet or wifi network.
  4. From a second tailnet-joined device, run `tailscale status` repeatedly (or watch `https://login.tailscale.com/admin/machines`).
  5. Start a timer at power-on; confirm `acceptance-test-pi` appears as online within ~60s.
- **Evidence**: screenshot of admin console / `tailscale status` showing the new hostname with timestamp; operator note of elapsed wall-clock time from power-on to "online."

### payload-modules.AC6.2: `/boot/firmware/<log-name>` contains documented sections at T+90s and T+180s
- **Justification**: The report runs on a systemd timer triggered by actual boot time, dumps live `rfkill`/`iw`/`nmcli`/`journalctl` output that only exists on a running Pi, and writes to the FAT bootfs which is then read by pulling the SD card. No build-time analog.
- **Procedure**:
  1. Build `core + boot-report` image (Phase 5 / Task 3 setup).
  2. Flash to SD, boot the Pi, wait ≥ 4 minutes.
  3. Power off the Pi cleanly (or yank — both produce the report files; the report does not need a clean shutdown).
  4. Pull SD card, mount on a Mac/Linux/Windows host (FAT partition appears as a normal volume).
  5. Open `/boot/firmware/boot.log` (or whatever `BOOT_REPORT_LOG_NAME` was configured).
- **Evidence**: copy of `boot.log` saved with the test-run notes; confirm two `======================================================================` report blocks each starting with `boot report: <timestamp>` and roughly 90s apart; confirm each block contains the sections `--- wifi radio ---`, `--- wlan0 addresses ---`, `--- visible SSIDs (scan) ---`, `--- NetworkManager ---`, `--- systemd-rfkill state ---`, `--- NM drop-ins ---`, `--- boot-time errors ---`.

### payload-modules.AC7.2: MQTT health messages arrive within 30s of boot
- **Justification**: Requires a live MQTT broker, a live network path from the Pi to the broker, and the Pi to be running long enough for `tailscaled`/network bring-up and one publish cycle. Test would need a real broker process and a real Pi NIC.
- **Procedure**:
  1. On the operator's Mac: `brew install mosquitto && mosquitto -v` (or run on aether-server, accessible via tailnet).
  2. Build a `core + mqtt-telemetry` image with `MQTT_BROKER=<operator-host-or-tailnet-name>:1883` and `MQTT_ROLE=acceptance-test`.
  3. On the operator's Mac: `mosquitto_sub -t 'pi/+/+/#' -v` (in a watch terminal).
  4. Flash + boot the Pi.
  5. Start a timer at power-on.
- **Evidence**: terminal output capturing `pi/acceptance-test/<hostname>/health`, `…/version`, and `…/online true` messages arriving in the subscriber within 30s. Note the elapsed wall-clock time.

### payload-modules.AC7.3: `online` flips to `false` retained via LWT on power-off
- **Justification**: Validates the broker's LWT mechanism plus paho-mqtt keepalive behavior under real disconnect (ungraceful power loss). Requires the same live-broker setup as AC7.2 plus a second subscriber to observe the retained value.
- **Procedure**:
  1. Continue from AC7.2 with the subscriber still attached.
  2. Power off the Pi by yanking the cord (not `shutdown -h now` — the daemon's clean-exit path explicitly publishes `online=false` and would mask LWT behavior; we want to verify LWT specifically).
  3. Watch the subscriber for the retained `pi/acceptance-test/<hostname>/online` topic value flipping to `false`.
  4. After observation, attach a fresh subscriber: `mosquitto_sub -t 'pi/+/+/online' -v` — the retained `false` should be delivered immediately.
- **Evidence**: timestamped subscriber log showing `online true` (during boot), then `online false` (after power-loss) within ~75s of the yank. Fresh-subscriber output confirming retained `false`.

### payload-modules.AC8.3: Post-migration mpv-loop image boots and plays video
- **Justification**: Same as AC3.2 (real Pi boot) plus mpv on KMS rendering to HDMI requires real GPU + display. No build-pipeline equivalent.
- **Procedure**:
  1. Build post-migration image: `examples/mpv-loop/build-example.sh --output out/mpv-loop-post-migration.img.gz --output-format gz`.
  2. Flash to SD: `bin/flash-image.sh out/mpv-loop-post-migration.img.gz`.
  3. Insert SD into a Pi connected to an HDMI display, power on.
  4. Wait for the configured video to start playing on the display.
  5. SSH in (`ssh pi@<pi-ip>`); run `systemctl status mpv-loop.service` and confirm `active (running)`.
- **Evidence**: photo or video of the Pi-driven display playing the configured loop; terminal output of `systemctl status mpv-loop.service` showing `active (running)` and a recent log line; operator confirmation that behavior matches pre-migration baseline (same video loops cleanly, same audio behavior).

### payload-modules.AC8.4: Surviving image-diff deltas (if any) are documented as benign
- **Justification**: "Documented with a benign explanation" is a meta-assertion about prose written by humans for humans. No automated check can determine whether a written explanation is actually correct or whether the operator believes it. Verification is a code-review / merge-review concern.
- **Procedure**:
  1. After Phase 7 / Task 5 runs `bin/diff-images.sh`, review the Phase 7 commits / PR.
  2. If the diff-images tool exited 0 with the default ignore list and no new patterns were added: AC8.4 is trivially satisfied; record this in the PR description.
  3. If new ignore patterns were added to `bin/diff-images.sh::IGNORES` during iteration: confirm each addition has a comment in the array (or in the Phase 7 commit message) naming the path, the entropy source, and why it's benign.
  4. If `bin/diff-images.sh` reports surviving (non-ignored) deltas that were waived by hand: confirm each such delta has an entry in `docs/design-plans/2026-05-15-payload-modules.md`'s "Additional Considerations" section OR in a Phase 7 PR comment, naming the path and explaining why the difference is harmless.
- **Evidence**: reviewer signoff on the Phase 7 PR confirming that the three cases above are covered; either "clean PASS, no additions" or a list of additions/waivers with their corresponding documentation pointers.
