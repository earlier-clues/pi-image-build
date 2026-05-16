# modules/ — repo-level payload modules

Last verified: 2026-05-16

## Purpose
Composable, bake-time configuration units. A payload picks which modules
to run via `modules.list`; each module declares its env-var contract in
`schema.sh` and runs its install steps in `module.sh` inside the chroot.

The shape mirrors NixOS modules deliberately, so a future Nix migration
maps 1:1. See `../DESIGN_DECISIONS.md` § "Module system".

## Contracts

Each module is a directory with this shape:

```
<name>/
├── schema.sh       # required. Calls require/optional. Sourced HOST-SIDE.
├── module.sh       # required. Sourced INSIDE the chroot, in declared order.
└── README.md       # optional, for modules that warrant prose explanation.
```

**`schema.sh` DSL** (helpers bound by `lib/modules-loader.sh`):
- `require VAR` — fail validation if `$VAR` is unset/empty.
- `optional VAR default=VALUE` — fall back to `VALUE` if unset.
- `default=` may interpolate other env vars (e.g. `default=$HOSTNAME`).

**`module.sh` execution environment** (set by the synthetic runner):
- `LIB_DIR=/tmp/pibuild/lib` — source `lib/*.sh` capabilities from here.
- `MODULE_DIR=/tmp/pibuild/modules/<name>` (repo-level) or
  `/tmp/pibuild/payload/modules/<name>` (payload-local) — reference module's own assets.
- `PAYLOAD_DIR=/tmp/pibuild/payload`, `MOUNTS_DIR=/tmp/pibuild/mounts`,
  `MODULES_DIR=/tmp/pibuild/modules` — same as the legacy contract.
- All schema-declared vars are forwarded automatically.

## Resolution order

`bin/build-image.sh` looks up each name in `modules.list` as:

1. `<payload>/modules/<name>/` (payload-local, takes precedence — "shadowing")
2. `<repo-root>/modules/<name>/` (repo-level)
3. error if neither exists

Payload-local modules let a payload override a repo-level one by name, or
ship its own one-off module without committing to the repo.

## Dependencies
- **Uses**: `lib/*.sh` (chroot-side capability libs).
- **Used by**: `bin/build-image.sh` via `lib/modules-loader.sh`.
- **Boundary**: a `module.sh` must not assume any other module ran before
  it — the only ordering guarantee is the order in `modules.list`. If a
  module needs `core` to have run first, it expects `core` to be earlier
  in `modules.list` (or it explicitly does its own thing).

## Invariants
- A module's schema is its public contract. Every `require`/`optional`
  is documented downstream in `README.md`'s module-catalog table.
- Schemas are validated host-side BEFORE Docker starts. If `require X`
  fails, the build aborts with exit 2 without spinning up the container.
- Empty-string is a legal value for `optional ... default=` and is
  forwarded to the chroot as such (this is why `pipeline/remaster.sh`
  uses `SCHEMA_VARS` and forwards always, even if empty).
- A module never reads the payload's `.env` directly; the loader sources
  it once host-side and forwards declared vars only.

## Catalog (repo-level)
- `core` — baseline OS config (hostname, user, ssh, wifi, machine-id reset).
- `tailscale` — install + firstboot enrollment via baked-in auth key.
- `boot-report` — systemd timer dumping diagnostics to `/boot/firmware/`.
- `mqtt-telemetry` — Python daemon publishing health/version/online.

## Gotchas
- `require X` checks `[[ -z "$X" ]]`, so the empty string fails the check
  even if `X=` is set. `optional X default=` distinguishes "unset" from
  "explicitly empty" only loosely; assume both are equivalent.
- `TAILSCALE_FLAGS` is a free-form space-separated list parsed positionally;
  only `--ssh` and `--accept-routes` are allowlisted in the module.
- Schemas run in a subshell so `set +a` and similar side effects do not
  escape. Don't try to share state between schema and module via globals;
  go through env vars.
