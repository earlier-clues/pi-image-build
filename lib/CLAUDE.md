# lib/ — capability libraries + the loader

Last verified: 2026-05-16

## Purpose
Single-capability building blocks. A payload (or a module's `module.sh`)
sources whichever lib functions it needs. No bundling, no "default
config" — each lib does one orthogonal thing.

See `../TODO.md` § "Composability principle" for the policy.

## Contracts

**Two execution contexts live here. Don't mix them.**

| Where it runs | Files | Sourced by |
|---|---|---|
| **Host-side** (in `bin/build-image.sh`) | `modules-loader.sh` only | `bin/build-image.sh` |
| **Chroot-side** (inside the arm64 chroot) | `apt.sh`, `hostname.sh`, `locale.sh`, `ssh.sh`, `user.sh`, `wifi.sh`, `tailscale.sh`, `boot-report.sh`, `mqtt-telemetry.sh` | modules' `module.sh` or legacy `build.sh` |

Every chroot-side lib declares `LIB_API_VERSION=1` near the top. Bump
this when a function signature changes incompatibly.

## Asset directories

Several chroot-side libs ship verbatim files alongside the `.sh`:

- `lib/wifi/` — `regdom.service`, `nm-unblock.conf`
- `lib/tailscale/` — `tailscale-firstboot.service`
- `lib/boot-report/` — script template + .service + .timer
- `lib/mqtt-telemetry/` — Python daemon, launcher, .service unit
- `lib/user/` — currently empty placeholder

These are installed into the image by their corresponding `lib/<name>.sh`
install function (e.g. `lib/tailscale.sh:install_tailscale` reads from
`lib/tailscale/`). Don't relocate without updating the installer.

## Host-side: `lib/modules-loader.sh`

Public API (sourced by `bin/build-image.sh`):

- `parse_modules_list <list-file>` → prints names in declared order;
  exit 2 on duplicates or missing file.
- `resolve_module <name> <payload-dir> <repo-modules-dir>` → prints
  absolute path; payload-local shadows repo-level; exit 2 if neither.
- `validate_schemas <module-dir>...` → sources each `schema.sh` in a
  subshell with `require`/`optional` bound; collects ALL errors before
  exiting; prints `export NAME=VALUE` lines for resolved vars on stdout.
- `emit_runner <out-path> <module-chroot-path>...` → writes a synthetic
  bash script that sources each `module.sh` in order with `MODULE_DIR`
  set per module.

## Dependencies
- **Chroot-side libs use**: only standard Pi OS Lite packages (apt-installed
  by the lib itself if needed — see `core` module installing `iw rfkill openssh-server`).
- **mqtt-telemetry depends on**: `paho-mqtt` (apt: `python3-paho-mqtt`).
- **Used by**: modules' `module.sh` (preferred) and legacy `build.sh`.
- **Boundary**: nothing in `lib/` should reference `examples/`, `modules/`, or `bin/`.
  Libs are leaf nodes.

## Python intrusion (mqtt-telemetry)

`lib/mqtt-telemetry/pibuild-mqtt-telemetry.py` is the only Python in
this repo. It's the on-Pi runtime daemon, not build-time code. The
parsers are pure functions and have pytest coverage in `tests/`.
Everything else (build orchestration, installers) stays bash.

## Invariants
- Lib functions read state from positional args + named flags, never
  from ambient env vars. The `core` module reads env vars; the libs it
  calls take args.
- `enable_ssh` + `disable_password_auth` + `add_to_sudoers_nopasswd`
  are the trusted-LAN posture. Don't compose them into a non-trusted-LAN
  payload without thinking.

## Gotchas
- `sed_escape` is duplicated in `lib/boot-report.sh` and `lib/mqtt-telemetry.sh`
  because libs can't depend on each other (the chroot sources whichever
  the module asked for). If you find yourself needing a third copy,
  reconsider the split.
- `pibuild-boot-report.sh.template` is a template — substitutions happen
  in the installer via `sed`. Don't `chmod +x` it; the installer does.
