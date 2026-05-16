# bin/ — public CLIs

Last verified: 2026-05-16

## Purpose
Public entry points. Everything a user (human or CI) invokes directly
lives here. The CLIs orchestrate; the actual image work happens in
`pipeline/remaster.sh` inside the build container, and the actual
configuration work happens via `modules/*/module.sh` inside the chroot.

## Contracts

### `build-image.sh <payload-dir> [opts]`
Public CLI. Dispatch logic:

1. Resolve `<payload-dir>` to an absolute path.
2. Look for `modules.list` (new contract) — if present, set
   `PAYLOAD_CONTRACT=modules`.
3. Else look for `build.sh` (legacy) — if present, `PAYLOAD_CONTRACT=legacy`.
4. Else fail with exit 2.

For `modules` contract: source `<payload>/.env` (unless `--env-file` overrides),
parse `modules.list`, resolve each name, validate every schema, emit a
synthetic runner to `build-scratch/run-modules.sh`, then pass
`BUILD_SCRIPT=/tmp/pibuild/run-modules.sh` to the container. All
schema-resolved vars are forwarded automatically as `-e` args AND listed
in `SCHEMA_VARS` so `pipeline/remaster.sh` includes them in the chroot
env (including empty strings).

For `legacy` contract: skip the env-file auto-source. Caller must already
have env vars in scope. `pipeline/remaster.sh` defaults
`BUILD_SCRIPT=/tmp/pibuild/payload/build.sh`.

Canonical env vars forwarded if set: `HOSTNAME TIMEZONE KEYMAP PI_USER
ENCRYPTED_PASSWORD SSH_PUBKEY`. Anything matching `--env-regex REGEX`
goes via `PASSTHROUGH` (newline-separated `NAME=VALUE` list).

### `diff-images.sh OLD NEW`
Migration-equivalence gate. Runs the build container with `--privileged`,
kpartx-mounts both images, runs `diff -rq` on rootfs, filters known-noise
paths (machine-id, /etc/shadow salt, ssh host keys, apt state, etc.).

- Exit 0: image-equivalent (modulo ignore list).
- Exit 1: surviving differences (printed).
- Exit 2: usage/setup error.

Use this when refactoring a payload to a new structure that should
produce the same image (e.g. the mpv-loop legacy → modules migration).

### `flash-image.sh IMG`
macOS-only SD-card writer.

### `test-image.sh IMG`
QEMU raspi3b boot sanity check. Reaches ext4 mount and then init exits
(emulation can't run Pi-4 userspace). "Bootable to ext4 mount" is the
verification; full smoke-testing requires real hardware.

## Dependencies
- **Uses**: `pipeline/` (Docker container), `lib/modules-loader.sh`
  (host-side), `modules/` (resolved by name).
- **Used by**: humans, CI, project-specific wrapper scripts (see
  `README.md` § "Build something real").
- **Boundary**: nothing in `bin/` should know about specific modules
  (`core`, `tailscale`, …). The loader resolves modules generically.

## Invariants
- `bin/build-image.sh` is bash-3.2-compatible (macOS default bash).
  No `mapfile`, no `${arr[@]:0:1}` slicing without testing on 3.2.
- The build container is `pi-image-build:latest`, rebuilt every run;
  Docker's layer cache keeps this cheap.
- Exit code conventions: 0=ok, 2=usage/input error, 3=verification
  failure (sha256, partitions), 4=container/internal error.

## Gotchas
- `--env-regex` is for forwarding *additional* host env vars beyond
  what module schemas declare. Module-declared vars are auto-forwarded;
  don't double-list them.
- `--mount LABEL=PATH` shows up as `$MOUNTS_DIR/<label>` inside the
  chroot. The path is bind-mounted read-only.
- The `.env` auto-source happens only for the modules contract. Legacy
  payloads must have env vars in scope before invoking `build-image.sh`.
