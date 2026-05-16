# payload-modules Implementation Plan — Phase 3: Migrate `examples/hello-payload`

**Goal:** Replace `examples/hello-payload/build.sh` with the new-contract shape: `modules.list = core + hello`, a payload-local `modules/hello/` module that writes the sentinel file, a `.env.example`, and (so the example is runnable) a `.env` excluded by `.gitignore`. Exercises the loader + `core` end-to-end as the canonical "minimum viable new-contract payload."

**Architecture:** `examples/hello-payload/build.sh` (14 lines) currently writes `/etc/pibuild-hello`. That single behavior moves into a tiny payload-local module `examples/hello-payload/modules/hello/` with a `schema.sh` declaring its own optional env (`HELLO_MESSAGE`, `HELLO_OUTPUT_PATH`) and a `module.sh` that writes the file. The pre-existing baseline-OS-config that hello-payload's `build.sh` *did not* do (no user, no ssh, no wifi) now comes for free because `core` is the first module in `modules.list` — meaning the post-migration hello-payload produces a *more* configured image than the pre-migration one (a user, ssh, wifi setup, etc.). That is a deliberate change in scope: pre-migration hello-payload was a "does the pipeline run?" smoke test; post-migration it is "does the loader-plus-core path produce a usable image?" smoke test.

**Tech Stack:** Bash, modules-loader (Phase 1), `modules/core/` (Phase 2). No new code.

**Scope:** Phase 3 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — `examples/hello-payload/build.sh` is a 14-line script that sources `lib/hostname.sh` + `lib/locale.sh`, sets a default hostname (`hellopi`) and timezone (`UTC`), and writes `/etc/pibuild-hello`. No `.env`, no `files/`, no `modules/`. README.md describes hello-payload as the smoke test.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC4: `examples/hello-payload` migrated
- **payload-modules.AC4.1 Success:** `examples/hello-payload/` no longer contains a top-level `build.sh`; it contains `modules.list`, `.env.example`, and a payload-local `modules/hello/`.
- **payload-modules.AC4.2 Success:** `bin/build-image.sh examples/hello-payload` produces an image containing `/etc/pibuild-hello` (the sentinel file).

---

## Project Conventions to Follow

(Same as Phases 1 and 2.)

For this phase specifically: `examples/hello-payload/` is the first first-party example of the new contract. Its file shape is the template every future new-contract payload (including aether's eventual migrations) will be modeled on. Keep file names, layout, and comments unsurprising — this is what gets pointed at from the README's "Authoring a payload" section in Phase 7's docs work.

---

<!-- START_SUBCOMPONENT_A (tasks 1-4) -->
<!-- START_TASK_1 -->
### Task 1: Create `examples/hello-payload/modules.list`

**Verifies:** payload-modules.AC4.1 (new-contract file shape).

**Files:**
- Create: `examples/hello-payload/modules.list`

**`examples/hello-payload/modules.list`:**

```
# hello-payload — the new-contract smoke test. core does the baseline
# OS config (hostname, user, ssh, wifi, …); hello writes a sentinel file
# so CI can confirm the chroot ran end-to-end.

core
hello
```

**Verification:**

`cat examples/hello-payload/modules.list` shows the contents above.

**Commit:** `feat(examples/hello-payload): add modules.list (core + hello)`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create `examples/hello-payload/.env.example`

**Verifies:** payload-modules.AC4.1.

**Files:**
- Create: `examples/hello-payload/.env.example`

**`examples/hello-payload/.env.example`:**

```
# hello-payload example .env. Copy to .env (gitignored) and fill in.
#
# These five are required by modules/core (baseline OS config).

HOSTNAME=hellopi
TIMEZONE=UTC
PI_USER=pi
ENCRYPTED_PASSWORD='$6$replaceme$replaceme'    # generate with: openssl passwd -6 'your-password'
SSH_PUBKEY='ssh-ed25519 AAAA… your-key-here'

# Optional, both have defaults in modules/core/schema.sh:
# KEYMAP=us
# AP_COUNTRY=US

# Optional, used by the payload-local 'hello' module:
# HELLO_MESSAGE="hello from pi-image-build"
# HELLO_OUTPUT_PATH=/etc/pibuild-hello
```

**Verification:**

`bash -n examples/hello-payload/.env.example` (env files parse as bash assignments).

Run the env-file sourcing logic and confirm no errors:
```bash
set -a; source examples/hello-payload/.env.example; set +a; echo "$HOSTNAME"
```
Expected: `hellopi`.

**Commit:** `feat(examples/hello-payload): add .env.example`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `examples/hello-payload/modules/hello/`

**Verifies:** payload-modules.AC4.1 (payload-local module present), payload-modules.AC4.2 (sentinel file written).

**Files:**
- Create: `examples/hello-payload/modules/hello/schema.sh`
- Create: `examples/hello-payload/modules/hello/module.sh`

**`examples/hello-payload/modules/hello/schema.sh`:**

```bash
# hello module — writes a sentinel file inside the chroot. Both vars
# are optional with sensible defaults so the bare `core + hello` payload
# works out of the box.

optional HELLO_MESSAGE default="hello from pi-image-build"
optional HELLO_OUTPUT_PATH default=/etc/pibuild-hello
```

**`examples/hello-payload/modules/hello/module.sh`:**

```bash
# hello module — writes the canonical pi-image-build sentinel file.
# Inputs: HELLO_MESSAGE, HELLO_OUTPUT_PATH (both optional, defaulted by
# schema.sh).

install -d -m 755 "$(dirname "$HELLO_OUTPUT_PATH")"
{
    echo "pi-image-build hello-payload OK at $(date -u +%FT%TZ)"
    echo "message: $HELLO_MESSAGE"
} > "$HELLO_OUTPUT_PATH"
chmod 644 "$HELLO_OUTPUT_PATH"
```

The sentinel content is intentionally a strict-superset of pre-migration `build.sh`'s `"pi-image-build hello-payload OK at <date>"` line — old consumers of the file (CI grepping for `pi-image-build hello-payload OK`) still pass, plus the new `message:` line is available for richer assertions.

**Verification:**

```bash
bash -n examples/hello-payload/modules/hello/schema.sh
bash -n examples/hello-payload/modules/hello/module.sh
```
Expected: no output, exit 0.

**Commit:** `feat(examples/hello-payload): add payload-local hello module`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Delete `examples/hello-payload/build.sh`

**Verifies:** payload-modules.AC4.1 (no top-level `build.sh`).

**Files:**
- Delete: `examples/hello-payload/build.sh`

```bash
git rm examples/hello-payload/build.sh
```

**Verification:**

```bash
ls examples/hello-payload/
```
Expected: `.env.example`, `modules/`, `modules.list`. No `build.sh`.

**Commit:** `refactor(examples/hello-payload): drop legacy build.sh — replaced by core + hello modules`
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (task 5) -->
<!-- START_TASK_5 -->
### Task 5: End-to-end build + image inspection

**Verifies:** payload-modules.AC4.2 (image contains `/etc/pibuild-hello`).

**Files:**
- Create (locally, gitignored): `examples/hello-payload/.env` — operator-provided real values for the env vars from `.env.example`. The file is gitignored at the repo level (`.gitignore` already excludes `**/.env` per the pre-existing `examples/mpv-loop/.env` pattern; confirm and add the entry if missing).

**Pre-flight: confirm `.env` is gitignored:**

```bash
grep -E '^\.env$|^\*\*/\.env$|/\.env$' .gitignore || echo "  .env may not be gitignored"
```

If `.env` is not gitignored, add to `.gitignore`:

```
# Per-payload .env files (operator secrets — never commit).
**/.env
```

Commit with: `chore(gitignore): exclude per-payload .env files`.

**Setup — create `examples/hello-payload/.env`:**

```bash
cp examples/hello-payload/.env.example examples/hello-payload/.env

# Set real values:
sed -i.bak \
    -e "s|^ENCRYPTED_PASSWORD=.*|ENCRYPTED_PASSWORD='$(openssl passwd -6 'pibuild-hello-test')'|" \
    -e "s|^SSH_PUBKEY=.*|SSH_PUBKEY='$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo 'ssh-ed25519 AAAA test')'|" \
    examples/hello-payload/.env
rm examples/hello-payload/.env.bak
```

(The `sed -i.bak` form works on both BSD/macOS and GNU sed.)

**Build:**

```bash
bin/build-image.sh examples/hello-payload --output-format gz
```

Expected:
- Exit 0.
- `==> modules: core hello` in stdout.
- `==> module: core` and `==> module: hello` inside the chroot log.
- Output at `out/hello-payload-<utc>.img.gz`.

Capture: `IMG=$(ls -t out/hello-payload-*.img.gz | head -1)`.

**Inspect the image:**

Use the same one-off inspection container approach as Phase 2 Task 3:

```bash
docker run --rm --privileged \
    -v "$(pwd)/$IMG:/in/image.img.gz:ro" \
    pi-image-build:latest \
    bash -c '
        set -euo pipefail
        gzip -dc /in/image.img.gz > /tmp/img
        LOOP=$(losetup --find --show /tmp/img)
        trap "kpartx -dv $LOOP >/dev/null 2>&1 || true; losetup -d $LOOP >/dev/null 2>&1 || true" EXIT
        kpartx -av "$LOOP" >/dev/null
        BASE=$(basename "$LOOP")
        for _ in $(seq 1 20); do [[ -b /dev/mapper/${BASE}p2 ]] && break; sleep 0.2; done
        mkdir -p /mnt/r
        mount /dev/mapper/${BASE}p2 /mnt/r

        echo "=== /etc/pibuild-hello ==="
        cat /mnt/r/etc/pibuild-hello

        echo "=== sanity: core mutations present ==="
        cat /mnt/r/etc/hostname
        ls -la /mnt/r/etc/sudoers.d/

        umount /mnt/r
    '
```

Expected:
- `/etc/pibuild-hello` exists and contains a line starting with `pi-image-build hello-payload OK at` (the strict-superset of the pre-migration sentinel) — AC4.2 verified.
- `/etc/hostname` contains `hellopi` (the default from `.env.example`) — confirms `core` ran.
- `/etc/sudoers.d/010-pi-nopasswd` exists — confirms `core` ran.

**Commit:** `test(examples/hello-payload): end-to-end verification of new-contract migration`

(Verification-only commit — no source changes if the migration is correct.)
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

---

## Phase Summary

After Phase 3, `examples/hello-payload/` is the canonical example of the new contract: a `modules.list`, an `.env.example`, and a single payload-local module. The pre-migration `build.sh` is gone. The image still contains `/etc/pibuild-hello`, plus all the baseline-OS-config that `core` now applies (user, ssh, wifi, etc.). README updates for "Authoring a payload" come in Phase 7.

**Build is green at end of phase:** `bin/build-image.sh examples/hello-payload` succeeds, the output image contains the sentinel file, the legacy `bin/build-image.sh examples/mpv-loop` still works unchanged (mpv-loop is still on the legacy contract until Phase 7).
