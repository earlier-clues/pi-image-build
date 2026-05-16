# pi-image-build

A small, generic Pi OS image customizer. Decompresses the official Raspberry Pi OS Lite (arm64) image, mounts loopback, runs a payload's `build.sh` inside an arm64 chroot, repacks. The pipeline is dumb: it knows how to manipulate images. Payloads know what they want done inside.

## Layout

| Path | What |
|---|---|
| `bin/build-image.sh` | public CLI. Build an image from a payload directory. |
| `bin/diff-images.sh` | image-diff verification gate. Compares two built images, ignores known build-time entropy. |
| `bin/flash-image.sh` | public CLI. Write a built image to an SD card (macOS). |
| `bin/test-image.sh` | boots a built image under QEMU raspi3b emulation as a "kernel + ext4 mount worked" sanity check. Doesn't reach userspace — see caveats. |
| `pipeline/Dockerfile` | privileged build container (Debian trixie + parted + kpartx + qemu-user-static). |
| `pipeline/remaster.sh` | runs inside the container. Decompress → grow → mount → chroot → run payload → repack. |
| `lib/apt.sh` | `apt_install`, `apt_clean` |
| `lib/hostname.sh` | `set_hostname`, `reset_machine_id` |
| `lib/locale.sh` | `set_timezone`, `set_keyboard` |
| `lib/modules-loader.sh` | host-side module parser/validator/runner-emitter. Sourced by `bin/build-image.sh`. |
| `lib/ssh.sh` | `install_pubkey`, `enable_ssh`, `disable_password_auth` |
| `lib/user.sh` | `ensure_user`, `add_to_sudoers_nopasswd`, `disable_userconfig_wizard` |
| `lib/wifi.sh` | `enable_wifi_regdom`, `mask_systemd_rfkill`, `prime_nm_wifi_enabled`, `nm_rfkill_unblock_dropin`, `install_nm_wifi` |
| `modules/` | repo-level modules. Each is `<name>/{schema.sh, module.sh, [files/, README.md]}`. |
| `examples/hello-payload/` | smoke-test payload. Sets a hostname and writes `/etc/pibuild-hello`. |

## The payload contract

A payload is a directory containing at minimum a `build.sh`. The script runs inside the chroot with these env vars in scope:

| Var | Source | Notes |
|---|---|---|
| `LIB_DIR` | `/tmp/pibuild/lib` | sourceable helpers |
| `PAYLOAD_DIR` | `/tmp/pibuild/payload` | the payload directory itself, available read-only inside the chroot |
| `MOUNTS_DIR` | `/tmp/pibuild/mounts` | extra dirs the caller passed via `--mount LABEL=PATH` |
| `HOSTNAME`, `TIMEZONE`, `KEYMAP`, `PI_USER`, `ENCRYPTED_PASSWORD`, `SSH_PUBKEY` | host env, forwarded if set | |
| anything matching `--env-regex REGEX` | host env, forwarded by name | for project-specific config |

`build.sh` sources the lib functions it wants, calls them, and does whatever else it needs (apt, install systemd units, drop config files). See `examples/hello-payload/build.sh` for the minimal shape.

## Authoring a payload (new contract — `modules.list`)

A payload directory contains:

| File | Purpose |
|---|---|
| `modules.list` | one module name per line; ordered; `#` comments + blank lines ignored |
| `.env.example` | the operator's documented env vars (commit) |
| `.env` | the operator's filled-in values (gitignored) |
| `modules/<name>/` (optional) | payload-local modules — shadow repo-level modules by name |

### Minimum viable: `examples/hello-payload`

```
examples/hello-payload/
├── modules.list           # "core\nhello"
├── .env.example
└── modules/
    └── hello/
        ├── schema.sh      # optional HELLO_MESSAGE, HELLO_OUTPUT_PATH defaults
        └── module.sh      # writes /etc/pibuild-hello
```

Build it:

```
cp examples/hello-payload/.env.example examples/hello-payload/.env
# fill in PI_PASSWORD (or ENCRYPTED_PASSWORD) and SSH_PUBKEY
bin/build-image.sh examples/hello-payload --output-format gz
```

`bin/build-image.sh` auto-sources `<payload>/.env`, parses `modules.list`,
validates each module's `schema.sh` host-side (`require X` errors if `$X`
unset; `optional X default=Y` fills in defaults), and runs each module's
`module.sh` inside the chroot in declared order.

### With a capability module: `examples/mpv-loop`

```
examples/mpv-loop/
├── modules.list           # "core\nmpv-loop"
├── .env.example
├── build-example.sh       # wrapper that loads .env and exec's bin/build-image.sh
├── content/               # video file(s) baked into the image
└── modules/
    └── mpv-loop/
        ├── schema.sh
        ├── module.sh      # mpv install, KMS config, services
        └── files/         # static assets (.service units, scripts)
```

`core` (a repo-level module at `modules/core/`) supplies the baseline OS
config — hostname, user, ssh, wifi setup, machine-id reset. The
`mpv-loop` payload-local module does the project-specific work.

### Module catalog convention

Each module's `schema.sh` is its env-var documentation: every `require`
or `optional` line is the canonical source-of-truth for what that
module consumes. For modules whose behavior warrants more explanation,
add an optional `modules/<name>/README.md`. The repo-level modules
ship with their own READMEs where useful.

Available repo-level modules:

| Module | Required env | Optional env | What it does |
|---|---|---|---|
| `core` | `HOSTNAME`, `TIMEZONE`, `PI_USER`, `ENCRYPTED_PASSWORD`, `SSH_PUBKEY` | `KEYMAP=us`, `AP_COUNTRY=US` | Baseline OS config: hostname, locale, user (sudoers-nopasswd), ssh, wifi-baseline, machine-id reset. |
| `tailscale` | `TAILSCALE_AUTHKEY` | `TAILSCALE_HOSTNAME=$HOSTNAME`, `TAILSCALE_FLAGS=` | Install Tailscale, enroll on first boot, self-disable. Set `TAILSCALE_FLAGS=--ssh` to enable Tailscale SSH (requires matching `ssh:` ACL). |
| `boot-report` | — | `BOOT_REPORT_LOG_NAME=boot.log`, `BOOT_REPORT_UNITS`, `BOOT_REPORT_JOURNAL_UNITS` | Drop a diagnostic dump to `/boot/firmware/<log-name>` at T+90s and T+180s. |
| `mqtt-broker` | — | `MQTT_BROKER_PORT=1883`, `MQTT_BROKER_AUTH=anonymous`, `MQTT_BROKER_PASSWD_PATH` | Install Mosquitto MQTT broker as a systemd service. Anonymous default; optional passwd-file auth. |
| `mqtt-telemetry` | `MQTT_BROKER`, `MQTT_ROLE` | `MQTT_CERT_PATH` | Publish per-Pi health/version/online to an MQTT broker on a 10s cadence with LWT. |
| `mqtt-dashboard` | — | `MQTT_DASHBOARD_BROKER=localhost:1883`, `MQTT_DASHBOARD_TOPIC=pi/#`, `MQTT_DASHBOARD_PORT=8080` | Tiny HTML status page for an mqtt-publishing fleet. Pair with `mqtt-broker` for a self-contained venue server. |

## Build a smoke-test image

```
./bin/build-image.sh examples/hello-payload --output-format gz
# → ./out/hello-payload-<utc>.img.gz
```

## Build something real

The convention is: each project ships its own payload directory and a thin wrapper that exports the right env vars and invokes pi-image-build:

```bash
# in some-project/scripts/build-foo-image.sh
set -a
source "$PROJECT/.env"
set +a
export ENCRYPTED_PASSWORD="$(openssl passwd -6 "$PI_PASSWORD")"
export SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
exec ../pi-image-build/bin/build-image.sh "$PROJECT/payload/foo" \
    --output-format xz \
    --env-regex 'AP_.*|VIDEO_SYNC_.*|MONITOR_INDEX' \
    --mount game=../some-other-repo
```

The wrapper owns: which env vars exist, where the SSH key lives, which extra mounts to pass. pi-image-build owns: how to actually build the image.

## Caveats

- **macOS only.** Linux is not supported — there's a real history of a binfmt-misc registration in the container nuking the Mac Docker build environment when someone tried, and the seam hasn't been worked out. `PIBUILD_FORCE_NON_DARWIN=1` bypasses the check if you want to be the person who fixes it.
- **QEMU testing is limited.** `bin/test-image.sh` boots under raspi3b emulation and confirms the kernel reaches the EXT4 root mount. After that, init exits because Pi-3 emulation can't fully run a Pi-4 userspace — that's not a bug in your image, it's the price of QEMU not having `-M raspi4b` working on Bookworm. Reaching ext4 mount means the image is bootable enough that real Pi-4 hardware would proceed past where QEMU got. For full smoke-testing of services/SSH/wifi, flash to real hardware.
- **Trusted-LAN posture.** `lib/user.sh` includes `add_to_sudoers_nopasswd` and `lib/ssh.sh` includes `enable_ssh` + `disable_password_auth`. These match what gets baked into a self-configuring Pi behind an AP, where physical access to the SD card is the threat. Don't enable both on something you'd ship to a stranger without re-evaluating.
