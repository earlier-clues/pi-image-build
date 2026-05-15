# payload-modules Design

## Summary

`pi-image-build` is a shell-based toolchain that builds customized Raspberry Pi OS images. Today, each *payload* (a named, deployable image configuration) carries a monolithic `build.sh` that duplicates the same baseline setup — hostname, locale, user accounts, SSH, wifi — across every payload in the repo. This design adds a module-composition layer: instead of a `build.sh`, a payload can declare an ordered `modules.list` of composable modules, each encapsulating one discrete concern (`core` for baseline OS setup, `tailscale` for VPN enrollment, `boot-report` for offline diagnostics, `mqtt-telemetry` for health publishing). Legacy `build.sh`-based payloads continue to build unchanged via a dispatch check in `bin/build-image.sh`.

The implementation is a thin validation and dispatch layer above the existing `lib/*.sh` function library. Host-side, a new `lib/modules-loader.sh` parses `modules.list`, resolves each module to a directory (payload-local shadows repo-level), validates env-var requirements from each module's `schema.sh`, and emits a synthetic runner script — aborting with collected errors before any container starts if validation fails. Inside the Docker/chroot build environment, `pipeline/remaster.sh` runs that runner, sourcing each `module.sh` in declared order with shared env state and lib access. Alongside the module system, the work delivers a filesystem-diff verification tool (`bin/diff-images.sh`) used as a gate to confirm that converting the `examples/mpv-loop` payload from the old shape to the new one produces a diff-equivalent image (after a documented ignore list for known-noise paths like `/etc/machine-id` and apt cache mtimes).

## Definition of Done

**Goal.** Add a module-composition layer to `pi-image-build` such that payloads can be declared as `modules.list` + `.env` + optional payload-local modules, while existing `build.sh`-style payloads continue to build unchanged.

**Deliverables:**

1. **Module loader & contract.** `bin/build-image.sh` dispatches by what's in the payload directory:
   - `modules.list` present → new contract. Parse list, resolve each name (payload-local `<payload>/modules/<name>/` shadows repo-level `pi-image-build/modules/<name>/`), source each `schema.sh`, validate env (`require` errors if unset; `optional X default=Y` fills in), abort before docker starts on failure. Inside the chroot, run each module's `module.sh` in list order with `LIB_DIR`, `MODULE_DIR`, `PAYLOAD_DIR`, `MOUNTS_DIR` in scope.
   - `build.sh` present, no `modules.list` → legacy contract, unchanged.
   - Env: auto-source `<payload>/.env` if no `--env-file` given; explicit `--env-file` wins.

2. **`lib/*.sh` unchanged.** Function signatures stable. Modules call into `lib/`; aether keeps calling into `lib/` directly. No renames, no moves.

3. **The `core` module.** `pi-image-build/modules/core/` bundles the repeated baseline-OS-config: hostname, locale, user (ensure + sudoers-nopasswd + disable userconfig wizard), ssh (install pubkey + enable + disable password auth), wifi-baseline (regdom + mask systemd-rfkill + prime NM + nm-rfkill-unblock dropin), reset machine-id. Strictly-superset of what every current payload does.

4. **Three new capability modules.** `pi-image-build/modules/tailscale/`, `modules/boot-report/`, `modules/mqtt-telemetry/`. Each venue-agnostic and project-agnostic; deployment specifics come from `.env`.

5. **Migrate `examples/hello-payload`.** New shape, minimum viable (one-line `modules.list: core`).

6. **Migrate `examples/mpv-loop`.** New shape: `modules.list = core + mpv-loop`, with the mpv-specific work in a payload-local `modules/mpv-loop/`. The mpv-loop-assign-hostname behavior is preserved by having `.env` set `HOSTNAME=mpv-loop` as the placeholder, with the rewriting systemd unit shipped from the payload-local module's `files/`.

7. **Verification gate.** Image diff: build `examples/mpv-loop` from the pre-migration commit, build from post-migration, mount both, diff the filesystems. Pass = empty diff or only explained-benign deltas (e.g., timestamps in machine-id-adjacent paths). This is the test for "no functional changes."

8. **Docs.** README gains an "Authoring a payload" section walking through `hello-payload` and `mpv-loop` in the new shape. Module catalog convention: each module's `schema.sh` is its env-var documentation; longer prose goes in optional `modules/<name>/README.md`.

**Out of scope, explicitly:**

- Migrating aether* payloads (`aether/payload/server`, `aether/payload/zero`, `aether-arcade-game/payload/arcade`). They stay on the legacy `build.sh` contract and must build unchanged.
- Any aether/aether-arcade-game reorganization.
- Module-depends-on-module declarations; conditional module inclusion; templated module sets.
- Schema vocabulary beyond `require` and `optional`.
- Bit-equivalent reproducibility of the underlying Pi OS base image.

## Acceptance Criteria

### payload-modules.AC1: New-contract dispatch (`modules.list`)
- **payload-modules.AC1.1 Success:** `bin/build-image.sh` on a payload with `modules.list` + valid env builds an image end-to-end without error.
- **payload-modules.AC1.2 Success:** Module-list run order matches file order; comments (`#`) and blank lines are ignored.
- **payload-modules.AC1.3 Success:** A module name resolves to `<payload>/modules/<name>/` if present, else `<repo>/modules/<name>/`.
- **payload-modules.AC1.4 Success:** `<payload>/.env` is auto-sourced when no `--env-file` is given; `--env-file FILE` wins when given.
- **payload-modules.AC1.5 Failure:** `require X` in a schema with `$X` unset aborts the build host-side, before docker starts, with a clear error naming `X` and the module.
- **payload-modules.AC1.6 Failure:** Multiple `require` failures across modules are all reported in one error pass (not just the first).
- **payload-modules.AC1.7 Failure:** A `modules.list` entry that resolves nowhere aborts with a clear error naming the missing module.
- **payload-modules.AC1.8 Failure:** A duplicate module name in `modules.list` aborts with a clear error.
- **payload-modules.AC1.9 Edge:** `optional X default=Y` with `$X` unset sets `X=Y` and exports it into the chroot.

### payload-modules.AC2: Legacy-contract dispatch (`build.sh`) unchanged
- **payload-modules.AC2.1 Success:** A payload with `build.sh` and no `modules.list` builds via the legacy path with no behavioral change vs. pre-this-work.
- **payload-modules.AC2.2 Success:** `lib/*.sh` function signatures are unchanged; aether's payloads (not built here, but readable) would still consume them identically.
- **payload-modules.AC2.3 Failure:** A payload with neither `modules.list` nor `build.sh` aborts with a clear error.

### payload-modules.AC3: `core` module
- **payload-modules.AC3.1 Success:** A payload with `modules.list = core` (and required env) builds an image whose rootfs has the configured hostname, timezone, keymap, user with sudoers-nopasswd, ssh enabled with password auth disabled and the configured pubkey installed, wifi regdom set, systemd-rfkill masked, NM wifi primed, the NM rfkill-unblock dropin installed, and `/etc/machine-id` empty.
- **payload-modules.AC3.2 Success:** The resulting image boots on real Pi hardware (manual hardware verification).
- **payload-modules.AC3.3 Edge:** `core` is strictly-superset of pre-this-work mpv-loop's baseline-OS-config block (verified via Phase 7's image-diff gate).

### payload-modules.AC4: `examples/hello-payload` migrated
- **payload-modules.AC4.1 Success:** `examples/hello-payload/` no longer contains a top-level `build.sh`; it contains `modules.list`, `.env.example`, and a payload-local `modules/hello/`.
- **payload-modules.AC4.2 Success:** `bin/build-image.sh examples/hello-payload` produces an image containing `/etc/pibuild-hello` (the sentinel file).

### payload-modules.AC5: `tailscale` module
- **payload-modules.AC5.1 Success:** A payload with `modules.list = core + tailscale` and a valid `TAILSCALE_AUTHKEY` builds an image with tailscale installed and a `tailscale-firstboot.service` configured.
- **payload-modules.AC5.2 Success:** On real hardware, the Pi appears on the tailnet within ~60s of first boot with hostname `${TAILSCALE_HOSTNAME:-$HOSTNAME}` (manual hardware verification).
- **payload-modules.AC5.3 Success:** The `tailscale-firstboot.service` disables itself after its first successful run.
- **payload-modules.AC5.4 Failure:** Missing `TAILSCALE_AUTHKEY` aborts host-side with a clear error.

### payload-modules.AC6: `boot-report` module
- **payload-modules.AC6.1 Success:** A payload with `modules.list = core + boot-report` builds an image with the report script + service + timer installed.
- **payload-modules.AC6.2 Success:** On real hardware, pulling the SD card after first boot reveals `/boot/firmware/<BOOT_REPORT_LOG_NAME>` containing the documented sections (radio info, scan, NM profiles, rfkill state, drop-ins, boot errors) at both T+90s and T+180s (manual hardware verification).
- **payload-modules.AC6.3 Edge:** Default `BOOT_REPORT_LOG_NAME` is `boot.log`; default `BOOT_REPORT_UNITS` and `BOOT_REPORT_JOURNAL_UNITS` are empty (report still runs, just doesn't list per-unit status).

### payload-modules.AC7: `mqtt-telemetry` module
- **payload-modules.AC7.1 Success:** A payload with `modules.list = core + mqtt-telemetry` and valid `MQTT_BROKER` + `MQTT_ROLE` builds an image with the daemon + systemd unit installed.
- **payload-modules.AC7.2 Success:** On real hardware with a reachable mosquitto broker, `mosquitto_sub -t 'pi/+/+/health'` shows retained messages within 30s of boot.
- **payload-modules.AC7.3 Success:** Powering off the Pi flips the retained `pi/<role>/<hostname>/online` topic to `false` via LWT.
- **payload-modules.AC7.4 Success:** Python unit tests on the /proc + vcgencmd readers pass (no MQTT network involvement).
- **payload-modules.AC7.5 Failure:** Missing `MQTT_BROKER` or `MQTT_ROLE` aborts host-side with a clear error.

### payload-modules.AC8: `examples/mpv-loop` migrated with image-diff gate
- **payload-modules.AC8.1 Success:** `examples/mpv-loop/` no longer contains a top-level `build.sh`; it contains `modules.list = core + mpv-loop`, `.env.example`, and a payload-local `modules/mpv-loop/` containing the mpv-specific work (apt install, KMS config, assign-hostname unit, video baking).
- **payload-modules.AC8.2 Success:** `bin/diff-images.sh OLD NEW` returns 0 when comparing the pre-migration and post-migration mpv-loop images (after the documented ignore list).
- **payload-modules.AC8.3 Success:** The post-migration image boots on real Pi hardware and plays the configured video loop (manual hardware verification, same as pre-migration).
- **payload-modules.AC8.4 Edge:** Any surviving diff after the ignore list is documented (in the design plan or a Phase 7 PR comment) with a benign explanation; otherwise this AC fails.

### payload-modules.AC9: Documentation
- **payload-modules.AC9.1 Success:** `README.md` gains an "Authoring a payload" section walking through `hello-payload` and `mpv-loop` in the new shape.
- **payload-modules.AC9.2 Success:** The module catalog convention is documented: each module's `schema.sh` is its env-var documentation; longer prose goes in optional `modules/<name>/README.md`.

## Glossary

- **payload**: A named directory containing everything needed to build one Pi OS image — a module list (or legacy `build.sh`), an optional `.env`, and any payload-local modules. Analogous to a "role" or "profile" in other configuration systems; the unit of work for `bin/build-image.sh`.
- **module**: A directory with up to three parts: `schema.sh` (env-var declarations), `module.sh` (the chroot-side shell work), and `files/` (static assets copied into the rootfs). The atom of composition in the new contract.
- **modules.list**: The new-contract declaration file in a payload directory. One module name per line, `#` comments and blank lines ignored; order is execution order.
- **schema.sh**: The env-var interface for a module. Declares `require VAR` (must be set or the build aborts) and `optional VAR default=VALUE` (filled in if absent). Sourced host-side before any container starts; all failures are collected and reported together rather than stopping at the first.
- **module.sh**: The chroot-side shell script that performs a module's work — apt installs, file drops, systemd-unit enables, etc. *Sourced* (not exec'd) into the runner shell, so it shares env state and lib functions with adjacent modules in the same run.
- **remaster.sh**: `pipeline/remaster.sh` — the script that runs inside the Docker build container. It sets up chroot bind mounts and invokes the build script (legacy `build.sh` or the synthetic runner emitted by the loader). The single chroot-side entry point for the pipeline.
- **kpartx**: A Linux utility (`kpartx -av image.img`) that reads a disk image's partition table and creates loop device mappings for each partition, making individual partitions mountable on the host without physical media. Used by `bin/diff-images.sh` to mount both images for filesystem comparison.
- **regdom**: Wireless regulatory domain — the two-letter country code (`AP_COUNTRY`) that tells the kernel which radio-frequency rules apply. Must be set to activate the wifi radio legally and functionally; configured via `iw reg set` or equivalent.
- **rfkill / systemd-rfkill**: `rfkill` is the Linux kernel mechanism that software-blocks wireless radios. `systemd-rfkill.service` restores saved rfkill state on every boot, which can re-block a radio that was unblocked during image build. The `core` module masks `systemd-rfkill.service` and installs an NM drop-in to force-unblock, preventing the radio from going dark after first boot.
- **machine-id**: `/etc/machine-id` — a 32-hex-char unique identifier consumed by systemd, D-Bus, and dhclient. When a Pi OS image is cloned to multiple SD cards, all copies share the same ID unless it is cleared. The `core` module resets it to empty; systemd regenerates a unique ID on first boot.
- **NetworkManager (NM)**: The Linux network management daemon used on Pi OS for wifi and ethernet. Abbreviated as NM throughout. The `core` module pre-configures NM wifi state and writes drop-in overrides for rfkill handling.
- **dropin**: A systemd configuration override file placed in a `<unit>.d/` subdirectory alongside the main unit file. Drop-ins are merged at load time, allowing partial overrides without editing the upstream unit. Referenced as the "nm-rfkill-unblock dropin" in the `core` module and as a reported section in `boot-report` output.
- **tailscale**: A VPN mesh network service. When installed, a device is reachable by hostname across the internet via WireGuard tunnels managed by the Tailscale control plane. The `tailscale` module bakes a one-time auth key into a oneshot firstboot service that enrolls the Pi on first boot and then disables itself.
- **MQTT LWT (Last Will and Testament)**: An MQTT protocol feature where the client registers a "death message" with the broker at connection time; the broker publishes it automatically if the client disconnects without a clean goodbye. The `mqtt-telemetry` module uses this to flip the retained `online` topic to `false` when a Pi loses power unexpectedly.
- **paho-mqtt**: Eclipse Paho's Python MQTT client library. Used by the `mqtt-telemetry` daemon to connect to the broker, publish retained telemetry messages, and register the LWT.
- **mosquitto**: Eclipse Mosquitto — a lightweight open-source MQTT message broker. Used as the reference broker in hardware acceptance tests (`mosquitto_sub -t 'pi/+/+/health'`), and anticipated as a future `mqtt-broker` module target.
- **vcgencmd**: A Raspberry Pi firmware utility (`/usr/bin/vcgencmd`) that exposes VideoCore GPU and board-level information — temperature, throttle state, firmware version. Used by the `mqtt-telemetry` Python daemon to read hardware telemetry for the health payload.
- **image-diff gate**: The verification mechanism for the `examples/mpv-loop` migration. `bin/diff-images.sh` kpartx-mounts both the pre-migration and post-migration images and diffs their filesystems with a hardcoded ignore list. A zero-delta result (or all surviving deltas documented as benign) is a required exit condition before the migration phase is considered done.

## Architecture

A module is a directory: `schema.sh` (env-var declarations), `module.sh` (the chroot work), optional `files/` (assets the module copies into the rootfs). Modules live at `pi-image-build/modules/<name>/` (repo-level, shared) or `<payload>/modules/<name>/` (payload-local, shadows repo-level by the same name).

A new-contract payload is `<payload>/modules.list` (one module name per line, ordered, `#` comments, blank lines ignored) plus an optional `<payload>/.env`. The legacy `<payload>/build.sh` contract continues to work unchanged; `bin/build-image.sh` dispatches by presence: `modules.list` → new path, `build.sh` → legacy path, neither → error.

**Host-side flow (new contract).** `bin/build-image.sh` sources a new `lib/modules-loader.sh` and:

1. Sources `<payload>/.env` if no `--env-file` given; explicit flag wins.
2. Parses `modules.list` into an ordered name array (rejects duplicates).
3. Resolves each name: payload-local first, repo-level second. Errors with a clear message if unresolved.
4. For each resolved module: sources its `schema.sh` with `require` and `optional` bound to validator functions. `require X` errors immediately if `$X` is unset; `optional X default=Y` sets and exports `X=Y` if unset. Validation collects all errors, then aborts before docker starts if any failed.
5. Emits a synthetic runner `build-scratch/run-modules.sh` containing one `source <module-chroot-path>/module.sh` line per module in list order.
6. Adds bind mounts: `<repo>/modules` → `/tmp/pibuild/modules`, `build-scratch/run-modules.sh` → `/tmp/pibuild/run-modules.sh`. Passes `BUILD_SCRIPT=/tmp/pibuild/run-modules.sh` to the container.

**Chroot-side flow.** `pipeline/remaster.sh` gains one change: it runs `${BUILD_SCRIPT:-/tmp/pibuild/payload/build.sh}` instead of the hardcoded path. Legacy payloads pick up the default; new-contract payloads pick up the synthetic runner. The chroot env gains `MODULES_DIR=/tmp/pibuild/modules` (the repo-level modules root). Each module computes its own `MODULE_DIR` from `${BASH_SOURCE[0]%/*}` inside `module.sh`.

**Module dispatch.** Modules are `source`d into the runner shell, not exec'd as subprocesses. They share env state with each other and with the lib helpers they source. This matches how aether's `build.sh` already composes lib functions today.

**files/ convention.** Explicit copy in `module.sh` (`install -D -m 644 "$MODULE_DIR/files/foo.service" /etc/systemd/system/foo.service`). No auto-overlay magic. Matches today's payload pattern.

**The `core` module** bundles the baseline-OS-config block (hostname, locale, user, ssh, wifi-baseline, machine-id reset) currently copy-pasted across every payload. It is strictly-superset of what aether/server, aether/zero, arcade, and mpv-loop do today, and contains no new behavior — only orchestration of existing `lib/*.sh` functions.

**The three new capability modules** (`tailscale`, `boot-report`, `mqtt-telemetry`) each wrap a corresponding new `lib/<name>.sh` we ship in this work. The lib functions are parametrized installers (e.g., `install_tailscale AUTHKEY [--hostname HN] [--ssh]`); the module schemas declare the env vars that map into those parameters. This mirrors how `lib/wifi.sh::install_nm_wifi` already works.

**Verification.** `bin/diff-images.sh OLD NEW` runs inside the existing pipeline container, decompresses both images, kpartx-mounts each, runs `diff -rq` with a hardcoded ignore list (machine-id paths, apt cache mtimes, systemd random-seed, `/var/log/*`). Returns 0 if the surviving diff is empty, 1 otherwise. Used as the migration gate for `examples/mpv-loop`: pre-migration image vs. post-migration image must diff clean.

## Existing Patterns

**Investigated and followed.**

- *Lib-helpers-plus-payload-build.sh.* `lib/*.sh` files define small functions; payload `build.sh` files source them and call them. Aether's `payload/server/build.sh`, `payload/zero/build.sh`, and `aether-arcade-game/payload/arcade/build.sh` all follow this. Modules formalize the recipe-of-helpers part without replacing the helpers. `lib/*.sh` signatures stay frozen.
- *Parametrized installer functions in lib.* `lib/wifi.sh::install_nm_wifi NAME SSID PSK` and `lib/ssh.sh::install_pubkey KEY USER` already follow this shape. The new `lib/tailscale.sh::install_tailscale`, `lib/boot-report.sh::install_boot_report`, `lib/mqtt-telemetry.sh::install_mqtt_telemetry` extend it.
- *Chroot bind-mount staging.* `pipeline/remaster.sh` bind-mounts `lib`, `payload`, and labelled `mounts/*` into the chroot under `/tmp/pibuild/`. The new `modules/` mount and synthetic runner mount use the same mechanism and the same `/tmp/pibuild/` namespace.
- *Env-passthrough discipline.* `bin/build-image.sh` collects passthrough env vars host-side (`--env-regex`) and forwards them through `env -i`'s whitelist in `remaster.sh`. Schema-filled defaults from new-contract validation merge into the same passthrough list.

**No divergence from existing patterns.** The module system is a thin composition layer above the existing lib/payload split. Aether's payloads remain unchanged consumers of `lib/*.sh`; they may adopt the new `lib/{tailscale,boot-report,mqtt-telemetry}.sh` helpers at their own pace, without going through the module layer.

## Implementation Phases

<!-- START_PHASE_1 -->
### Phase 1: Loader scaffolding & contract dispatch
**Goal:** `bin/build-image.sh` can parse `modules.list`, validate schemas host-side, emit a synthetic runner, and run it inside the chroot. Legacy `build.sh` contract still works.

**Components:**
- `lib/modules-loader.sh` — exposes `require`, `optional`, `parse_modules_list`, `resolve_module`, `validate_schemas`, `emit_runner`. Sourced by `bin/build-image.sh`.
- `bin/build-image.sh` — adds dispatch on `modules.list` vs `build.sh`. New-contract path calls the loader functions, mounts `<repo>/modules` and the synthetic runner, sets `BUILD_SCRIPT` env var.
- `pipeline/remaster.sh` — one-line change: runs `${BUILD_SCRIPT:-/tmp/pibuild/payload/build.sh}` instead of the hardcoded path. Chroot env gains `MODULES_DIR`.
- A minimal test payload at `examples/loader-smoke/` (or inline in the existing `hello-payload` test) that exercises new-contract dispatch.

**Dependencies:** None.

**Done when:** `bash -n` clean on all touched scripts; shellcheck clean; legacy `examples/hello-payload` (still on `build.sh` contract until Phase 3) builds end-to-end with no behavior change; a smoke-test new-contract payload with one trivial module builds end-to-end. Covers `payload-modules.AC1.*`, `payload-modules.AC2.*`.
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: The `core` module
**Goal:** `modules/core/` provides the baseline-OS-config block as a one-line opt-in. No new lib code; pure orchestration.

**Components:**
- `modules/core/schema.sh` — declares `HOSTNAME`, `TIMEZONE`, `PI_USER`, `ENCRYPTED_PASSWORD`, `SSH_PUBKEY` as required; `KEYMAP` (default `us`), `AP_COUNTRY` (default `US`) as optional.
- `modules/core/module.sh` — sources `lib/{hostname,locale,user,ssh,wifi,apt}.sh` and runs the canonical baseline block in the canonical order: hostname → locale → user → ssh → wifi-baseline → machine-id reset.
- `modules/core/README.md` (optional) — one paragraph on what it bundles and why.

**Dependencies:** Phase 1.

**Done when:** A new-contract payload with `modules.list` containing only `core` builds end-to-end and produces a Pi image that boots, accepts the configured SSH key, joins the configured wifi (manual hardware test acceptable for boot-level), and has machine-id reset to empty. Covers `payload-modules.AC3.*`.
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: Migrate `examples/hello-payload`
**Goal:** Smoke-test the loader + `core` end-to-end with the minimum viable payload. Validates the contract before any capability modules complicate things.

**Components:**
- `examples/hello-payload/modules.list` — single line `core`.
- `examples/hello-payload/.env.example` — documents required env vars.
- `examples/hello-payload/build.sh` — deleted. The sentinel-file behavior (`echo "… OK at $(date)" > /etc/pibuild-hello`) moves into a tiny payload-local module `examples/hello-payload/modules/hello/module.sh`, with `modules.list` becoming `core\nhello`.

**Dependencies:** Phase 1, Phase 2.

**Done when:** `bin/build-image.sh examples/hello-payload` succeeds with no env-file (defaults kick in for the few required-by-core vars via wrapper or explicit defaults), produces an image, and the image contains `/etc/pibuild-hello`. Covers `payload-modules.AC4.*`.
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: `tailscale` capability module
**Goal:** Any payload can add one line to `modules.list` and gain tailscale auto-enroll on first boot.

**Components:**
- `lib/tailscale.sh` — exposes `install_tailscale AUTHKEY [--hostname HN] [--ssh] [--accept-routes]`. Adds the tailscale apt repo, `apt_install tailscale`, drops a `tailscale-firstboot.service` (oneshot, `RemainAfterExit=true`) that runs `tailscale up --authkey=… --hostname=… [flags]` and `systemctl disable`s itself.
- `modules/tailscale/schema.sh` — `require TAILSCALE_AUTHKEY`, `optional TAILSCALE_HOSTNAME default=$HOSTNAME`, `optional TAILSCALE_FLAGS default=--ssh`.
- `modules/tailscale/module.sh` — sources `lib/tailscale.sh`, calls `install_tailscale` with env values.
- `modules/tailscale/files/tailscale-firstboot.service` — the systemd template.

**Dependencies:** Phase 1.

**Done when:** A test payload with `modules.list = core + tailscale` builds; on real hardware the Pi appears on the tailnet within ~60s of first boot with the expected hostname. Covers `payload-modules.AC5.*`.
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: `boot-report` capability module
**Goal:** Any payload can ship an offline-diagnostic dump to `/boot/firmware/<log-name>` at T+90s and T+180s.

**Components:**
- `lib/boot-report.sh` — exposes `install_boot_report --log-name foo.log --units "a.service b.service" --journal-units "a.service"`. Drops a generic report script + `.service` + `.timer` into the rootfs.
- `modules/boot-report/schema.sh` — `optional BOOT_REPORT_LOG_NAME default=boot.log`, `optional BOOT_REPORT_UNITS default=""`, `optional BOOT_REPORT_JOURNAL_UNITS default=""`.
- `modules/boot-report/module.sh` — wraps the lib call.
- `modules/boot-report/files/boot-report.sh.template`, `.service`, `.timer`.

**Dependencies:** Phase 1.

**Done when:** A test payload with `modules.list = core + boot-report` builds; on real hardware, pulling the SD card after first boot reveals `/boot/firmware/<log-name>` containing the expected sections (radio info, scan, NM profiles, rfkill state, drop-ins, boot errors). Covers `payload-modules.AC6.*`.
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: `mqtt-telemetry` capability module
**Goal:** Any payload can publish health/version/online status to an MQTT broker on a 10s cadence with LWT.

**Components:**
- `lib/mqtt-telemetry.sh` — exposes `install_mqtt_telemetry --role NAME --broker HOST:PORT [--cert PATH]`. Drops a Python paho-mqtt daemon (~80 LOC: /proc + vcgencmd readers, retained publish, LWT setup) + systemd unit. Installs paho-mqtt via pip-into-venv or apt as available.
- `modules/mqtt-telemetry/schema.sh` — `require MQTT_BROKER`, `require MQTT_ROLE`, `optional MQTT_CERT_PATH default=""`.
- `modules/mqtt-telemetry/module.sh` — wraps the lib call.
- `modules/mqtt-telemetry/files/mqtt-telemetry.py`, `mqtt-telemetry.service`.
- Python unit tests on the /proc + vcgencmd readers (no MQTT network involvement).

**Dependencies:** Phase 1.

**Done when:** A test payload with `modules.list = core + mqtt-telemetry` builds; on real hardware, with a mosquitto broker reachable, `mosquitto_sub -t 'pi/+/+/health'` shows messages within 30s of boot, and `/online` flips to `false` retained when the Pi is powered off. Python unit tests pass. Covers `payload-modules.AC7.*`.
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: Image-diff gate + migrate `examples/mpv-loop`
**Goal:** Build the verification tool, then use it to certify that migrating mpv-loop produces an image-equivalent (or behaviorally-equivalent with explained deltas) result.

**Components:**
- `bin/diff-images.sh OLD NEW` — runs inside the pipeline container, kpartx-mounts both images, runs `diff -rq` with the documented ignore list (machine-id paths, apt cache, log files, random-seed), prints surviving deltas, returns 0/1.
- `examples/mpv-loop/modules.list` — `core` then `mpv-loop`.
- `examples/mpv-loop/modules/mpv-loop/{schema.sh, module.sh, files/}` — everything in current `examples/mpv-loop/build.sh` that's *not* the baseline-OS-config block (mpv install, KMS config, video baking, the assign-hostname systemd unit). Existing files under `examples/mpv-loop/files/` move into the payload-local module's `files/`.
- `examples/mpv-loop/.env.example` — documents required env vars including `HOSTNAME=mpv-loop` as the placeholder that the assign-hostname unit rewrites on each boot.
- Migration verification: build pre-migration image (from git HEAD before this phase's commits), build post-migration image, run `bin/diff-images.sh` — must exit 0.

**Dependencies:** Phase 1, Phase 2. Phases 4–6 not strictly required but recommended (so we exercise capability modules against a real payload).

**Done when:** `bin/diff-images.sh out/mpv-loop-pre.img.xz out/mpv-loop-post.img.xz` returns 0; the post-migration image boots and plays the configured video loop on real hardware (manual hardware test). Covers `payload-modules.AC8.*`.
<!-- END_PHASE_7 -->

## Additional Considerations

**`nm_rfkill_unblock_dropin` asymmetry.** `aether/payload/server/build.sh` calls `prime_nm_wifi_enabled` but not `nm_rfkill_unblock_dropin`, while every other payload calls both. The `core` module includes both (strictly-superset). If aether/server ever migrates to `core`, the extra dropin file appears in its image — behaviorally inert if rfkill state is already clean, but image-diff non-empty. Worth verifying at aether/server migration time.

**Tailscale auth key sensitivity.** The auth key is baked into a systemd unit's `Environment=` line on the image. Acceptable for the SD-card-physical-access threat model that pi-image-build's other secrets (encrypted password, SSH private keys for some payloads) already accept. Not acceptable for an image shipped to a stranger. Documented in `modules/tailscale/README.md`.

**`lib/mqtt-telemetry.sh` is genuinely new code.** Unlike `lib/tailscale.sh` and `lib/boot-report.sh` (which mostly orchestrate apt + systemd-unit drops), the mqtt-telemetry lib ships a Python daemon. Function signature is per the 2026-05-14 design plan but the daemon implementation will be refined during Phase 6. Schema and module shape are stable; daemon internals are an implementation-plan concern.

**Future: mqtt-broker module.** Anticipated follow-up work: `lib/mqtt-broker.sh` + `modules/mqtt-broker/` (mosquitto installation + config). Eventually consumed by aether/server when it migrates. Out of this work's scope.

**Future: aether* payload migrations.** Out of scope here. They continue to consume `lib/*.sh` directly via their existing `build.sh` files. They *may* adopt the new `lib/tailscale.sh` / `lib/boot-report.sh` / `lib/mqtt-telemetry.sh` helpers at their own pace, independent of the module system, the same way they consume existing lib helpers today.

**Module count budget.** `DESIGN_DECISIONS.md` flags ~20 modules total or ~10 payloads as a Nix-migration trigger. This work lands 4 shared modules (`core`, `tailscale`, `boot-report`, `mqtt-telemetry`) plus 2 payload-local modules (`hello`, `mpv-loop`). With the anticipated `mqtt-broker` that's 5 shared. Plenty of headroom; revisit the trigger when we approach the limit.
