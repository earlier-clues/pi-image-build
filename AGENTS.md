# pi-image-build

Last verified: 2026-05-16

A Pi OS image customizer. Decompress raspios-lite-arm64 → grow → loop-mount →
arm64 chroot → run payload → repack. Pipeline is dumb (knows how to
manipulate images), payloads know what they want done inside.

For human-facing usage docs, see `README.md`. For non-obvious architectural
choices and rationale, see `DESIGN_DECISIONS.md`. For roadmap, see `TODO.md`.

## Tech Stack
- Bash 3.2+ (macOS-default) for build orchestration and chroot work
- Python 3 + paho-mqtt for one daemon only (mqtt-telemetry on the Pi)
- Docker (privileged container) for the arm64 chroot environment
- pytest for the (parser-only) unit-test suite

## Commands
- `bin/build-image.sh <payload-dir> [--output-format gz|xz]` — build an image
- `bin/diff-images.sh OLD NEW` — image-diff verification gate (migration tool)
- `bin/flash-image.sh IMG` — write to SD card (macOS-only)
- `bin/test-image.sh IMG` — QEMU raspi3b boot sanity check (kernel + ext4 only)
- `python3 -m pytest tests/ -v` — run parser unit tests
- `just` — `justfile` wraps the above with shorter aliases (`just build`, `just flash`, `just diff`, `just test`) plus dev-host helpers (`just broker-up|sub|logs|down` for a local mosquitto). Run `just` with no args to list.

## Project Structure
- `bin/` — public CLIs (build, diff, flash, test)
- `pipeline/` — `Dockerfile` + `remaster.sh` (runs INSIDE the container)
- `lib/` — chroot-side capability libs + host-side `modules-loader.sh`
- `modules/` — repo-level payload modules (core, tailscale, boot-report, mqtt-telemetry)
- `examples/` — reference payloads (hello-payload, mpv-loop, loader-smoke)
- `tests/` — Python unit tests (parser-only; pure functions)
- `docs/design-plans/`, `docs/implementation-plans/` — historical planning docs

## Two payload contracts (DISPATCH)

`bin/build-image.sh` dispatches on what's in the payload dir:

| Marker file | Contract | Status |
|---|---|---|
| `modules.list` present | **new** (preferred) | core path; auto-sources `<payload>/.env`; auto-forwards schema vars |
| `build.sh` present (no `modules.list`) | **legacy** | still supported; caller manages env vars + forwarding |
| neither | error |

**New work should use the modules contract.** Legacy is supported only so external payloads keep building. The two examples that ship in-repo are both new-contract (`mpv-loop` was migrated and image-diff'd against the legacy build for equivalence — see `bin/diff-images.sh` and the Phase 5 plan).

## Conventions worth knowing

- **Host-side vs chroot-side code.** Most `lib/*.sh` files are sourced *inside the chroot* by modules/payload `build.sh`. The one exception is `lib/modules-loader.sh`, which runs *host-side* in `bin/build-image.sh` (it parses `modules.list`, validates schemas, emits a synthetic runner). Treat this split as a hard boundary.
- **Capabilities, not bundles.** `lib/wifi.sh`, `lib/tailscale.sh`, etc. each ship one orthogonal capability. Deployment-specific config lives in the payload's `.env`, never in lib code. See `TODO.md` § "Composability principle".
- **Schema-declared env vars are auto-forwarded.** When a module's `schema.sh` calls `require X` or `optional X default=Y`, `X` is automatically passed to the chroot. Payloads do NOT need `--env-regex` for module-declared vars; that flag is for *additional* host env vars beyond the module schemas.
- **macOS-only.** Linux support is intentionally gated behind `PIBUILD_FORCE_NON_DARWIN=1`. See `README.md` § Caveats for the binfmt history.
- **Trusted-LAN posture.** `core` enables `sudoers NOPASSWD` for the pi user and disables ssh password auth. Don't ship to a stranger without re-evaluating — see `README.md` § Caveats.

## Boundaries
- Safe to edit: `bin/`, `lib/`, `modules/`, `pipeline/`, `tests/`, `examples/`, `docs/`
- Generated, do not commit: `out/`, `build-scratch/`, `tests/.venv/`, `tests/__pycache__/`
- Never edit: `*.lock`-style state (none yet) or anything under `.cache/pi-image-build/`

## Key Decisions (see DESIGN_DECISIONS.md)
- 2026-05-13: Roll our own module system rather than Nix or Ansible — bake-time config is the right grain. Migration triggers documented.

## Working in this repo
- Skill: `coding-effectively`, plus `howto-code-in-rust` and `howto-code-in-typescript` are **not** relevant here. Bash + a single Python daemon.
- For schema/contract changes, update `README.md`'s module catalog table too.
- For changes that should be image-equivalent (refactors), run `bin/diff-images.sh` against the pre-change image.
