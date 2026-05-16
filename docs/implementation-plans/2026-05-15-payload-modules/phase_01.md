# payload-modules Implementation Plan — Phase 1: Loader scaffolding & contract dispatch

**Goal:** Make `bin/build-image.sh` dispatch on the presence of `modules.list` (new contract) vs `build.sh` (legacy), parse + validate module schemas host-side, emit a synthetic runner, and execute it inside the chroot — without breaking the legacy contract.

**Architecture:** A new sourceable `lib/modules-loader.sh` exposes the validator/resolver/emitter primitives (`require`, `optional`, `parse_modules_list`, `resolve_module`, `validate_schemas`, `emit_runner`). `bin/build-image.sh` picks the contract by file presence and, on the new path, calls the loader, adds two bind mounts (the repo-level `modules/` directory and the synthetic runner), and sets `BUILD_SCRIPT` + `MODULES_DIR`. `pipeline/remaster.sh` gets a one-line change: it `chroot`s into `${BUILD_SCRIPT:-/tmp/pibuild/payload/build.sh}` and adds `MODULES_DIR` to the chroot env. Validation failures (missing `require`, missing module, duplicate module) are collected across all schemas and reported in one error pass before any docker container starts.

**Tech Stack:** Bash 5+, set -euo pipefail, docker (existing pipeline container), no new external deps.

**Scope:** Phase 1 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — `bin/build-image.sh` (217 lines), `pipeline/remaster.sh` (211 lines), `lib/*.sh` (apt, hostname, locale, ssh, user, wifi), `examples/hello-payload/build.sh` (14 lines, legacy), `examples/mpv-loop/build.sh` (128 lines, legacy). No existing `modules/` directory. No existing `tests/` directory or test framework — operational verification only.

---

## Acceptance Criteria Coverage

This phase implements and tests:

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

---

## Project Conventions to Follow

Established by inspection of the existing codebase — match these in all new code:

- `#!/usr/bin/env bash` for executables under `bin/`, `#!/bin/bash` for lib files sourced inside the chroot.
- `set -euo pipefail` at the top of every script that is executed (not sourced for state).
- `say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }` and `ok() { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }` for progress output. Loader errors print to stderr with `echo "error: ..." >&2`.
- Exit codes: `2` = bad usage / bad input, `3` = upstream verification failure, `4` = container build failure. New loader failures use `2`.
- `LIB_API_VERSION=1` constant in each lib file.
- `local var=...` declarations always inside functions.
- `install -D -m <mode> <src> <dst>` pattern for placing files.
- Heredoc with quoted EOF (`<<'EOF'`) when expansion must be suppressed.
- Idempotent helpers: re-running a function with the same inputs is a no-op.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Create `lib/modules-loader.sh` — the host-side validator/resolver/emitter

**Verifies:** payload-modules.AC1.2, payload-modules.AC1.3, payload-modules.AC1.5, payload-modules.AC1.6, payload-modules.AC1.7, payload-modules.AC1.8, payload-modules.AC1.9 (function-level behavior; end-to-end coverage in Task 5).

**Files:**
- Create: `lib/modules-loader.sh` (new, sourceable from `bin/build-image.sh`).

**Implementation contract:**

Sourceable bash file. Public functions (all run host-side, never inside the chroot):

```
parse_modules_list <list-file>
    # Reads <list-file>, strips comments (#…) and blank lines, prints one
    # module name per line in declared order. Aborts with exit 2 if the
    # file contains a duplicate name. Stdout is consumed via `mapfile -t`
    # or `read -ra`. Error messages go to stderr.

resolve_module <name> <payload-dir> <repo-modules-dir>
    # Prints the absolute path to <name>'s module dir on stdout:
    # checks <payload-dir>/modules/<name>/ first (payload-local shadows),
    # then <repo-modules-dir>/<name>/. Aborts with exit 2 and a clear
    # error naming <name> if neither resolves.

validate_schemas <module-dir>...
    # Sources each module's schema.sh in a subshell with `require` and
    # `optional` bound to validator implementations. Collects errors
    # across ALL schemas (does not exit on first failure). On any error,
    # prints the full collected list to stderr and aborts with exit 2.
    # On success, prints the resolved env-var declarations (one
    # `export NAME=VALUE` per line) to stdout — INCLUDING every
    # schema-declared variable, not just optional defaults. This is the
    # single source of truth for "every var the chroot must see":
    #   - `require X` on success (X set non-empty) → `export X="$X"`
    #   - `optional X default=Y` with X unset       → `export X="$Y"`
    #   - `optional X default=Y` with X already set → `export X="$X"`
    # The caller (bin/build-image.sh Edit 6 forwarder) parses these
    # lines to discover which `-e NAME` args to add to the docker
    # invocation; missing a `require` here means the var never reaches
    # the chroot.

emit_runner <out-path> <module-chroot-path>...
    # Writes a synthetic bash script to <out-path> that, in declared
    # order, sources each <module-chroot-path>/module.sh. Each
    # `source` line is preceded by an `export MODULE_DIR=...` so the
    # module's own `module.sh` can reference its assets via $MODULE_DIR
    # without depending on ${BASH_SOURCE}. Header includes
    # `set -euo pipefail` and a comment naming each module being run.
```

Plus the two schema vocabulary helpers used *inside* `validate_schemas`'s subshells (not exported as public API to callers, but exposed as bash functions when the schema is sourced):

```
require <NAME>
    # If $NAME is unset or empty, append "module <mod>: required var
    # NAME is unset" to the validation error list and DO NOT write to
    # the exports file. If $NAME is set, append `export NAME="$NAME"`
    # to __LOADER_EXPORTS_FILE. Implementation detail: writes to a
    # file descriptor or temp file so the parent shell can collect
    # cross-schema failures.

optional <NAME> default=<VALUE>
    # If $NAME is unset or empty, set NAME=<VALUE> (export it) and
    # append `export NAME="<VALUE>"` to __LOADER_EXPORTS_FILE.
    # If $NAME is set, leave it alone and append `export NAME="$NAME"`
    # to __LOADER_EXPORTS_FILE. `default=` is the literal syntax,
    # the `=` separator is required. Empty value after `=`
    # (`optional X default=`) is supported and sets X to the empty
    # string when X is unset; export semantics treat it as `export X=""`.
    # Used by tailscale, boot-report, mqtt-telemetry schemas for
    # "feature off by default."
```

Schema example (for reference — this is what a module's `schema.sh` will look like):

```bash
require HOSTNAME
require SSH_PUBKEY
optional KEYMAP default=us
optional AP_COUNTRY default=US
```

**Implementation notes:**

- The cross-schema error collection is the trickiest bit. A clean pattern: `validate_schemas` creates a tempfile under `${TMPDIR:-/tmp}` for errors, exports its path as `__LOADER_ERR_FILE`, then sources each schema in a subshell. The `require` implementation appends `"module $CURRENT_MODULE: required var NAME unset"` to that file when validation fails (and never exits); when validation succeeds, `require` appends `export NAME="$NAME"` to a second tempfile (`__LOADER_EXPORTS_FILE`). `optional` always writes `export NAME="$NAME"` (or the default value) to `__LOADER_EXPORTS_FILE`. After all schemas are processed, `validate_schemas` reads the error file, prints all lines to stderr, removes both tempfiles, then exits 2 if any errors. On success, prints the contents of the exports file to stdout — which now contains EVERY schema-declared variable, not just optionals.
- `CURRENT_MODULE` is set by `validate_schemas` before each schema is sourced, so `require`/`optional` can name the offending module in errors.
- Schema parsing is **bash sourcing**, not regex parsing. `require X` and `optional X default=Y` are real bash function calls. This means schemas can also do conditional logic if absolutely needed (we don't encourage it, but the door is open).
- `parse_modules_list` duplicate detection: build the array, then `printf '%s\n' "${arr[@]}" | sort | uniq -d` — if non-empty, names are duplicated. Print each duplicated name on its own line in the error.
- `resolve_module` does not validate that `module.sh` exists inside the resolved directory — that's a `module.sh`-load-time concern. It only checks the directory exists. A module dir without `module.sh` will fail at runner-execution time, with a clearer error from the synthetic runner itself.
- `emit_runner` output looks like:
  ```bash
  #!/bin/bash
  # Synthetic module runner — generated by lib/modules-loader.sh.
  # Modules: core, hello
  set -euo pipefail
  export MODULES_DIR="${MODULES_DIR:-/tmp/pibuild/modules}"
  export PAYLOAD_DIR="${PAYLOAD_DIR:-/tmp/pibuild/payload}"
  export LIB_DIR="${LIB_DIR:-/tmp/pibuild/lib}"

  echo "==> module: core"
  export MODULE_DIR="/tmp/pibuild/modules/core"
  source "$MODULE_DIR/module.sh"

  echo "==> module: hello"
  export MODULE_DIR="/tmp/pibuild/payload/modules/hello"
  source "$MODULE_DIR/module.sh"
  ```
  The chroot-side paths (`/tmp/pibuild/...`) are passed in by the caller (`bin/build-image.sh`) as the `<module-chroot-path>` arguments; `emit_runner` does not know about host-side paths.

**Testing:**

Operational tests via `bash lib/modules-loader.sh` invocation with fixtures (see Task 5). Verifies:
- payload-modules.AC1.2: `parse_modules_list` on a list with comments, blanks, leading whitespace preserves order and strips noise.
- payload-modules.AC1.3: `resolve_module foo /tmp/payload-with-foo /tmp/repo-modules` returns the payload-local path when both exist; returns repo-level path when only it exists.
- payload-modules.AC1.5: `validate_schemas` on a single schema with one unset `require` exits 2 and the stderr names both the var and the module.
- payload-modules.AC1.6: `validate_schemas` on two schemas each with one unset `require` exits 2 and the stderr names BOTH errors (not just the first).
- payload-modules.AC1.7: `resolve_module nosuch ...` exits 2 with stderr naming `nosuch`.
- payload-modules.AC1.8: `parse_modules_list` on a list with `core\nfoo\ncore` exits 2 with stderr naming `core` as duplicate.
- payload-modules.AC1.9: `validate_schemas` on a schema with `optional FOO default=bar`, FOO unset → stdout includes `export FOO=bar`. With FOO=preset → stdout includes `export FOO=preset`.

**Verification:**

Run: `bash -n lib/modules-loader.sh`
Expected: no output, exit 0.

Run: `bash -c 'set -euo pipefail; source lib/modules-loader.sh; echo OK'`
Expected: `OK`, exit 0.

If shellcheck is installed: `shellcheck lib/modules-loader.sh` — expected clean (warnings about `LIB_API_VERSION` being unused are fine; suppress with `# shellcheck disable=SC2034` next to the declaration).

**Commit:** `feat(loader): add lib/modules-loader.sh — host-side validator/resolver/emitter`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Modify `pipeline/remaster.sh` — chroot-side dispatch

**Verifies:** payload-modules.AC1.1, payload-modules.AC2.1 (end-to-end behavior in Task 5).

**Files:**
- Modify: `pipeline/remaster.sh` — six edits (1–6 below).

**Edit 1 — chroot env additions (around line 169–175, the `CHROOT_ENV=(` array):**

Add `MODULES_DIR=/tmp/pibuild/modules` to the canonical env list:

```
CHROOT_ENV=(
    "HOME=/root"
    "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
    "LIB_DIR=/tmp/pibuild/lib"
    "PAYLOAD_DIR=/tmp/pibuild/payload"
    "MOUNTS_DIR=/tmp/pibuild/mounts"
    "MODULES_DIR=/tmp/pibuild/modules"
)
```

Legacy payloads ignore the var. New-contract payloads consume it via the synthetic runner.

**Edit 2 — replace the hardcoded `build.sh` path with the `BUILD_SCRIPT_PATH` declared in Edit 6 (around line 178):**

The current line:

```
chroot "$MNT" env -i "${CHROOT_ENV[@]}" \
    /tmp/pibuild/payload/build.sh
```

becomes:

```
chroot "$MNT" env -i "${CHROOT_ENV[@]}" \
    "$BUILD_SCRIPT_PATH"
```

`BUILD_SCRIPT_PATH` is declared by Edit 6 (which lands earlier in the file, at lines ~147–156).

**Edit 3 — also forward `BUILD_SCRIPT` to the chroot env (so the `chroot env -i` whitelist includes it, harmless for legacy):**

Add to `CHROOT_ENV=(` initialization block, after the canonical vars and BEFORE the loop that adds `HOSTNAME`/`TIMEZONE`/etc., a line:

```
[[ -n "${BUILD_SCRIPT:-}" ]] && CHROOT_ENV+=("BUILD_SCRIPT=${BUILD_SCRIPT}")
```

This is belt-and-suspenders: `chroot env -i` already passes only the whitelist, and `BUILD_SCRIPT_PATH` is resolved in the *parent* shell before the `chroot env -i` call, so the chroot itself doesn't strictly need `BUILD_SCRIPT`. But surfacing it inside the chroot makes diagnostic output truthful (e.g., the synthetic runner can echo `BUILD_SCRIPT=$BUILD_SCRIPT`).

**Edit 4 — also bind-mount the `modules/` directory and the synthetic runner into the chroot:**

Below the `mount --bind /pibuild/payload "$PIBUILD/payload"` line (around line 130), add:

```
# Repo-level modules (always present; payload-local modules live under
# /pibuild/payload/modules/ and are accessed via the payload bind mount).
if [[ -d /pibuild/modules ]]; then
    mkdir -p "$PIBUILD/modules"
    mount --bind /pibuild/modules "$PIBUILD/modules"
fi

# Synthetic runner emitted by the loader (new-contract builds only).
if [[ -f /pibuild/run-modules.sh ]]; then
    install -m 755 /pibuild/run-modules.sh "$PIBUILD/run-modules.sh"
fi
```

Note: the runner is `install`-copied (not bind-mounted) because bind-mounting a single file into the chroot can fail if the destination doesn't exist as a file. The runner is small (<2KB) and ephemeral; copying is simpler and matches how the chroot already treats `qemu-aarch64-static`.

**Edit 5 — extend the unmount loop in `umount_all` and the cleanup-before-repack section to handle the modules bind mount:**

In `umount_all`, change:
```
for sub in "$MNT/tmp/pibuild/mounts/"*/ "$MNT/tmp/pibuild/payload" "$MNT/tmp/pibuild/lib"; do
```
to include `modules`:
```
for sub in "$MNT/tmp/pibuild/mounts/"*/ "$MNT/tmp/pibuild/payload" "$MNT/tmp/pibuild/lib" "$MNT/tmp/pibuild/modules"; do
```

Same change in the cleanup-before-repack block (the duplicate `for sub in ...` loop around line 190).

**Edit 6 — scope the legacy `build.sh` precondition check to the legacy path, and declare `BUILD_SCRIPT_PATH` here (used by Edit 2 below):**

The existing `remaster.sh` checks for `build.sh` being a regular file and executable. With the modules contract, that check fails because there's no `build.sh`. Re-confirm it's gated by `BUILD_SCRIPT` resolution, AND declare `BUILD_SCRIPT_PATH` at the top of the new block so Edit 2 (later in the file) can use it.

The existing block (around lines 147–156) is:

```
[[ -f "$PIBUILD/payload/build.sh" ]] || {
    echo "error: payload at $PAYLOAD_HOST has no build.sh" >&2
    exit 2
}
[[ -x "$PIBUILD/payload/build.sh" ]] || {
    echo "error: $PAYLOAD_HOST/build.sh is not executable (chmod +x it)" >&2
    exit 2
}
```

Replace with:

```
BUILD_SCRIPT_PATH="${BUILD_SCRIPT:-/tmp/pibuild/payload/build.sh}"

if [[ -z "${BUILD_SCRIPT:-}" ]]; then
    [[ -f "$PIBUILD/payload/build.sh" ]] || {
        echo "error: payload at $PAYLOAD_HOST has no build.sh" >&2
        exit 2
    }
    [[ -x "$PIBUILD/payload/build.sh" ]] || {
        echo "error: $PAYLOAD_HOST/build.sh is not executable (chmod +x it)" >&2
        exit 2
    }
else
    [[ -f "$PIBUILD/run-modules.sh" ]] || {
        echo "error: synthetic runner not found at \$PIBUILD/run-modules.sh (BUILD_SCRIPT=$BUILD_SCRIPT)" >&2
        exit 2
    }
fi
```

The new-contract synthetic runner is `install`-copied with mode 755 in Edit 4 (which runs earlier in the file order), so it's executable by construction; no need to re-check the executable bit. The `[[ -f "$PIBUILD/run-modules.sh" ]]` check uses the chroot-host-side path (matches Edit 4's `install -m 755 /pibuild/run-modules.sh "$PIBUILD/run-modules.sh"`) rather than `$BUILD_SCRIPT_PATH` (which is the in-chroot path `/tmp/pibuild/run-modules.sh` and would not exist on the host file system at this point in execution).

**Verification:**

Run: `bash -n pipeline/remaster.sh`
Expected: no output, exit 0.

(End-to-end run is in Task 5.)

**Commit:** `feat(remaster): support BUILD_SCRIPT + MODULES_DIR for new-contract payloads`
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: Modify `bin/build-image.sh` — host-side dispatch

**Verifies:** payload-modules.AC1.1, payload-modules.AC1.3, payload-modules.AC1.4, payload-modules.AC1.5, payload-modules.AC1.6, payload-modules.AC1.7, payload-modules.AC1.8, payload-modules.AC1.9, payload-modules.AC2.1, payload-modules.AC2.3.

**Files:**
- Modify: `bin/build-image.sh` — multiple edits, all listed below.

**Edit 1 — add `--env-file` flag to arg parsing:**

In the option parsing loop (around lines 53–69), add a case branch:

```
--env-file)          ENV_FILE="$2"; shift 2 ;;
```

Initialize `ENV_FILE=""` near the top with the other `OUTPUT=""` etc.

Update the usage block (the leading comments at the top of the file): add `--env-file PATH        source env vars from PATH before dispatch (default: <payload>/.env if present)`.

**Edit 2 — replace the `[[ -f "$PAYLOAD_DIR/build.sh" ]]` precondition with contract dispatch:**

The current line (around line 74):

```
[[ -f "$PAYLOAD_DIR/build.sh" ]] || { echo "error: $PAYLOAD_DIR has no build.sh" >&2; exit 2; }
```

Replace with:

```
# Resolve payload to absolute path now so contract dispatch (next) and
# subsequent docker mounts both use the same canonical path.
PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"

# Contract dispatch: modules.list (new) > build.sh (legacy) > error.
if [[ -f "$PAYLOAD_DIR/modules.list" ]]; then
    PAYLOAD_CONTRACT="modules"
elif [[ -f "$PAYLOAD_DIR/build.sh" ]]; then
    PAYLOAD_CONTRACT="legacy"
else
    echo "error: $PAYLOAD_DIR has neither modules.list nor build.sh" >&2
    exit 2
fi
```

The existing `PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"` line below (around line 82) becomes redundant — remove it. The `HERE=...` and `LIB_DIR=...` lines stay.

**Edit 3 — env-file sourcing block, immediately after dispatch:**

After the dispatch `if/elif/else/fi`, before `LIB_DIR="$HERE/lib"`:

```
# Env-file resolution (new contract only; legacy payloads have always
# expected the caller to set env vars before invoking build-image.sh).
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    if [[ -z "$ENV_FILE" && -f "$PAYLOAD_DIR/.env" ]]; then
        ENV_FILE="$PAYLOAD_DIR/.env"
    fi
    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || { echo "error: --env-file not found: $ENV_FILE" >&2; exit 2; }
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
        ok "env-file: $ENV_FILE"
    fi
fi
```

`set -a` causes every `var=value` assignment in the sourced file to be auto-exported, matching how `examples/mpv-loop/build-example.sh` already loads `.env`.

**Edit 4 — new-contract dispatch block, immediately before the docker-build line (`docker build -t "$IMAGE_TAG" "$HERE/pipeline" ...`):**

```
# New-contract: parse modules.list, validate schemas host-side, emit a
# synthetic runner. Anything that aborts here aborts BEFORE docker starts.
RUN_MODULES_SH=""
MODULES_REPO_DIR="$HERE/modules"
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    # shellcheck source=../lib/modules-loader.sh
    source "$HERE/lib/modules-loader.sh"

    say "parsing modules.list"
    mapfile -t MODULE_NAMES < <(parse_modules_list "$PAYLOAD_DIR/modules.list")
    (( ${#MODULE_NAMES[@]} > 0 )) || { echo "error: modules.list is empty after stripping comments" >&2; exit 2; }

    # Resolve each name to its host-side module dir.
    MODULE_HOST_DIRS=()
    MODULE_CHROOT_DIRS=()
    for name in "${MODULE_NAMES[@]}"; do
        host_dir="$(resolve_module "$name" "$PAYLOAD_DIR" "$MODULES_REPO_DIR")"
        MODULE_HOST_DIRS+=("$host_dir")
        # Translate host-side path to chroot-side path:
        # - <PAYLOAD_DIR>/modules/<name>  → /tmp/pibuild/payload/modules/<name>
        # - <MODULES_REPO_DIR>/<name>     → /tmp/pibuild/modules/<name>
        # Use [[ == ]] string-prefix matching rather than a `case` glob:
        # PAYLOAD_DIR could in principle contain glob metachars, and
        # case-glob would match unpredictably. [[ "$host_dir" == "$PAYLOAD_DIR"/* ]]
        # is a literal prefix test.
        if   [[ "$host_dir" == "$PAYLOAD_DIR"/* ]]; then
            MODULE_CHROOT_DIRS+=("/tmp/pibuild/payload/${host_dir#"$PAYLOAD_DIR"/}")
        elif [[ "$host_dir" == "$MODULES_REPO_DIR"/* ]]; then
            MODULE_CHROOT_DIRS+=("/tmp/pibuild/modules/${host_dir#"$MODULES_REPO_DIR"/}")
        else
            echo "internal error: unexpected module path $host_dir" >&2
            exit 4
        fi
    done
    ok "modules: ${MODULE_NAMES[*]}"

    # Validate schemas, collect resolved defaults into SCHEMA_DEFAULTS.
    say "validating schemas"
    SCHEMA_DEFAULTS="$(validate_schemas "${MODULE_HOST_DIRS[@]}")"
    # SCHEMA_DEFAULTS is a series of `export NAME=VALUE` lines. Source
    # them so the values are visible to the docker `-e` forwarding below
    # and so the `--env-regex` loop sees them too.
    if [[ -n "$SCHEMA_DEFAULTS" ]]; then
        # shellcheck disable=SC1091
        eval "$SCHEMA_DEFAULTS"
    fi
    ok "schemas validated"

    # Emit the synthetic runner.
    mkdir -p "$HERE/build-scratch"
    RUN_MODULES_SH="$HERE/build-scratch/run-modules.sh"
    emit_runner "$RUN_MODULES_SH" "${MODULE_CHROOT_DIRS[@]}"
    chmod +x "$RUN_MODULES_SH"
    ok "runner: $RUN_MODULES_SH"
fi
```

**Also append `build-scratch/` to `.gitignore` in the same commit as this edit** (the directory is regenerated on every new-contract build and should not be tracked):

```bash
if ! grep -qxF 'build-scratch/' .gitignore 2>/dev/null; then
    printf '\n# synthetic module runner — regenerated per build\nbuild-scratch/\n' >> .gitignore
fi
```

**Edit 5 — extend `DOCKER_ARGS` for the new-contract mounts and `BUILD_SCRIPT`:**

In the `DOCKER_ARGS=(...)` block (around lines 136–149), do NOT change the existing entries. After the `-v "$PAYLOAD_DIR":/pibuild/payload:ro` line is already there. Append (after the existing block, before the `# Extra mounts: --mount ...` comment):

```
# New-contract: bind-mount the repo-level modules dir, copy in the runner,
# and tell remaster.sh to invoke it.
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    DOCKER_ARGS+=(
        -v "$MODULES_REPO_DIR":/pibuild/modules:ro
        -v "$RUN_MODULES_SH":/pibuild/run-modules.sh:ro
        -e "BUILD_SCRIPT=/tmp/pibuild/run-modules.sh"
    )
fi
```

(The `:ro` on the runner is fine even though `pipeline/remaster.sh` `install`-copies it; the source bind-mount stays read-only, the copy in the chroot is writable by virtue of being a new file.)

**Edit 6 — extend the canonical env-var forwarding loop to include schema-resolved values:**

The existing block (around lines 160–162):

```
for v in HOSTNAME TIMEZONE KEYMAP PI_USER ENCRYPTED_PASSWORD SSH_PUBKEY; do
    [[ -n "${!v:-}" ]] && DOCKER_ARGS+=(-e "$v")
done
```

stays unchanged. The schema-resolved values from `eval "$SCHEMA_DEFAULTS"` have already exported their names into the parent shell, so they get picked up either by:
- This canonical loop (for the canonical set), OR
- The `--env-regex` loop (if the module schema declares a non-canonical var the caller wants forwarded).

For *module-declared* vars that are neither canonical nor `--env-regex`-matched (e.g., `MQTT_BROKER`), the schema-resolution alone is insufficient — they must reach the chroot. Add an explicit forwarder for module-declared names after the canonical loop:

```
# New-contract: forward every schema-resolved var to the chroot
# regardless of --env-regex. The user did not opt these in; the schemas
# declared them as part of the module's contract.
if [[ "$PAYLOAD_CONTRACT" == "modules" && -n "$SCHEMA_DEFAULTS" ]]; then
    # SCHEMA_DEFAULTS is `export NAME=VALUE` lines. Extract NAMEs.
    while IFS= read -r line; do
        [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        DOCKER_ARGS+=(-e "$name")
    done <<< "$SCHEMA_DEFAULTS"
fi
```

**Verification:**

Run: `bash -n bin/build-image.sh`
Expected: no output, exit 0.

Run: `bin/build-image.sh --help`
Expected: usage text includes `--env-file` flag.

End-to-end runs are in Task 5.

**Commit:** `feat(build-image): dispatch modules.list vs build.sh, source .env, mount modules`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Create `examples/loader-smoke/` — minimal new-contract test payload

**Verifies:** payload-modules.AC1.1 (success build), payload-modules.AC1.2 (order + comments), payload-modules.AC1.9 (optional default).

**Files:**
- Create: `examples/loader-smoke/modules.list`
- Create: `examples/loader-smoke/.env.example`
- Create: `examples/loader-smoke/modules/smoke/schema.sh`
- Create: `examples/loader-smoke/modules/smoke/module.sh`

The smoke payload deliberately does NOT depend on the `core` module (which arrives in Phase 2) — it only exercises the loader-and-dispatch path. A single payload-local module writes a sentinel file analogous to `hello-payload`'s `/etc/pibuild-hello`, plus the loader-level basics (env-file sourcing, schema with both `require` and `optional`, comment + blank-line handling).

**`examples/loader-smoke/modules.list`:**

```
# loader-smoke payload — exercises Phase-1 loader without depending on
# the core module. One trivial payload-local module, comments + blanks
# stripped, run-order preserved.

smoke
```

(One module, surrounded by comments and a blank line, to exercise the parser's comment/blank handling per AC1.2.)

**`examples/loader-smoke/.env.example`:**

```
# Required by the smoke module.
SMOKE_MESSAGE="loader smoke OK"

# Optional — has a default in schema.sh, override if you want.
# SMOKE_OUTPUT_PATH=/etc/pibuild-loader-smoke
```

**`examples/loader-smoke/modules/smoke/schema.sh`:**

```bash
require SMOKE_MESSAGE
optional SMOKE_OUTPUT_PATH default=/etc/pibuild-loader-smoke
```

**`examples/loader-smoke/modules/smoke/module.sh`:**

```bash
#!/bin/bash
# Loader-smoke module. Writes a sentinel file containing SMOKE_MESSAGE
# and the build timestamp to SMOKE_OUTPUT_PATH. Verifies that the loader
# successfully parsed modules.list, validated the schema, and dispatched
# to module.sh inside the chroot.
set -euo pipefail

: "${SMOKE_MESSAGE:?SMOKE_MESSAGE required (should have been validated host-side)}"
: "${SMOKE_OUTPUT_PATH:?SMOKE_OUTPUT_PATH required (should have been validated host-side)}"

install -d -m 755 "$(dirname "$SMOKE_OUTPUT_PATH")"
{
    echo "pi-image-build loader-smoke OK at $(date -u +%FT%TZ)"
    echo "message: $SMOKE_MESSAGE"
    echo "module_dir: $MODULE_DIR"
} > "$SMOKE_OUTPUT_PATH"
chmod 644 "$SMOKE_OUTPUT_PATH"
```

**Verification:**

Run: `bash -n examples/loader-smoke/modules/smoke/module.sh examples/loader-smoke/modules/smoke/schema.sh`
Expected: no output, exit 0.

End-to-end runs are in Task 5.

**Commit:** `feat(examples): add loader-smoke payload for new-contract smoke testing`
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (task 5) -->
<!-- START_TASK_5 -->
### Task 5: End-to-end verification — legacy + new contract, success + failure paths

**Verifies:** all of payload-modules.AC1.* and payload-modules.AC2.* via operational tests.

**Files:**
- No new files. All verification is via direct invocation of `bin/build-image.sh` and/or sourcing `lib/modules-loader.sh` with inline fixtures.

**Approach:**

The project has no test harness (no bats, no shellcheck config). Verification is operational: invoke the loader / builder with curated inputs and check exit codes + stderr. Each AC gets its own bash one-liner; failure ACs use exit code + stderr-grep; success ACs use a real build to xz output.

Run these verifications in order. Each is independent; if any fails, fix it before proceeding to the next.

**V1 — payload-modules.AC2.1 + AC2.2 (legacy hello-payload unchanged):**

```bash
# Set required env vars for the legacy hello-payload (it only consumes
# HOSTNAME and TIMEZONE, but build-image.sh forwards them all if set).
HOSTNAME=hellopi TIMEZONE=UTC \
    bin/build-image.sh examples/hello-payload --output-format gz
```

Expected: build succeeds, image lands at `./out/hello-payload-<utc>.img.gz`. No errors. lib/ files untouched (run `git diff lib/` — should be empty).

If desired, run `bin/test-image.sh ./out/hello-payload-*.img.gz` and confirm it reports a successful ext4 mount.

**V2 — payload-modules.AC1.1, AC1.2, AC1.4, AC1.9 (new contract, success):**

Create `examples/loader-smoke/.env` (gitignored, but the operator does this to test):

```
SMOKE_MESSAGE="loader smoke OK"
# SMOKE_OUTPUT_PATH intentionally unset to exercise AC1.9 optional default
```

Then:

```bash
bin/build-image.sh examples/loader-smoke --output-format gz
```

Expected:
- Stdout contains `==> parsing modules.list`, `==> validating schemas`, `==> modules: smoke`, `env-file: examples/loader-smoke/.env`.
- Build succeeds.
- Mount the resulting image (or skip and trust): `/etc/pibuild-loader-smoke` exists containing the sentinel text and `message: loader smoke OK`. (Optional: kpartx-mount it locally to inspect; not required for AC1.9 since the schema's `optional` defaulting is observable in the runner log.)
- The synthetic runner script at `build-scratch/run-modules.sh` exists and contains a `source` line for the `smoke` module.

**V3 — payload-modules.AC1.3 (payload-local shadows repo-level):**

Sanity check by inspection — Phase 1 has no repo-level modules to shadow, so this AC is exercised by Phase 2's `core` and Phase 3's hello-payload migration. For Phase 1, verify the resolver function logic directly:

```bash
# Set up a tempdir with a repo-modules dir containing 'foo' and a
# payload dir containing modules/foo (shadow).
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/repo-modules/foo" "$TMPDIR/payload/modules/foo"
touch "$TMPDIR/repo-modules/foo/schema.sh" "$TMPDIR/payload/modules/foo/schema.sh"

# Source the loader and resolve 'foo'.
source lib/modules-loader.sh
result="$(resolve_module foo "$TMPDIR/payload" "$TMPDIR/repo-modules")"

# Expect the payload-local path.
[[ "$result" == "$TMPDIR/payload/modules/foo" ]] || { echo "FAIL AC1.3 (shadow)"; exit 1; }
echo "PASS AC1.3 shadow"

# Now also verify fallback to repo-level when payload-local is absent.
rm -rf "$TMPDIR/payload/modules/foo"
result="$(resolve_module foo "$TMPDIR/payload" "$TMPDIR/repo-modules")"
[[ "$result" == "$TMPDIR/repo-modules/foo" ]] || { echo "FAIL AC1.3 (fallback)"; exit 1; }
echo "PASS AC1.3 fallback"
rm -rf "$TMPDIR"
```

**V4 — payload-modules.AC1.5 (single missing require, host-side abort):**

```bash
# Use loader-smoke, but unset the required SMOKE_MESSAGE.
( unset SMOKE_MESSAGE; \
  bin/build-image.sh examples/loader-smoke --env-file /dev/null --output-format gz \
    2>&1 1>/dev/null ) | tee /tmp/v4-stderr.log

grep -q "SMOKE_MESSAGE" /tmp/v4-stderr.log || { echo "FAIL AC1.5: stderr lacks 'SMOKE_MESSAGE'"; exit 1; }
grep -q "smoke" /tmp/v4-stderr.log || { echo "FAIL AC1.5: stderr lacks module name"; exit 1; }
# Confirm docker did NOT run — check docker ps -a created no new container with the build tag.
echo "PASS AC1.5"
```

(`--env-file /dev/null` forces no env to be sourced; the operator-set environment is otherwise empty for SMOKE_MESSAGE.)

**V5 — payload-modules.AC1.6 (multiple require failures all reported):**

Create a temporary payload with two modules, each declaring a `require` for a different unset var:

```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/modules/aaa" "$TMP/modules/bbb"
cat > "$TMP/modules.list" <<EOF
aaa
bbb
EOF
echo 'require VAR_AAA' > "$TMP/modules/aaa/schema.sh"
echo '#' > "$TMP/modules/aaa/module.sh"
echo 'require VAR_BBB' > "$TMP/modules/bbb/schema.sh"
echo '#' > "$TMP/modules/bbb/module.sh"

bin/build-image.sh "$TMP" --env-file /dev/null --output-format gz 2>&1 \
    | tee /tmp/v5-stderr.log >/dev/null

grep -q "VAR_AAA" /tmp/v5-stderr.log || { echo "FAIL AC1.6: VAR_AAA missing"; exit 1; }
grep -q "VAR_BBB" /tmp/v5-stderr.log || { echo "FAIL AC1.6: VAR_BBB missing (only first reported)"; exit 1; }
echo "PASS AC1.6"
rm -rf "$TMP"
```

**V6 — payload-modules.AC1.7 (missing module):**

```bash
TMP=$(mktemp -d)
echo "nosuch-module" > "$TMP/modules.list"
bin/build-image.sh "$TMP" --output-format gz 2>&1 | tee /tmp/v6-stderr.log >/dev/null
grep -q "nosuch-module" /tmp/v6-stderr.log || { echo "FAIL AC1.7: stderr lacks module name"; exit 1; }
echo "PASS AC1.7"
rm -rf "$TMP"
```

**V7 — payload-modules.AC1.8 (duplicate module):**

```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/modules/dup"
touch "$TMP/modules/dup/schema.sh" "$TMP/modules/dup/module.sh"
cat > "$TMP/modules.list" <<EOF
dup
dup
EOF
bin/build-image.sh "$TMP" --output-format gz 2>&1 | tee /tmp/v7-stderr.log >/dev/null
grep -qi "duplicate" /tmp/v7-stderr.log || { echo "FAIL AC1.8: stderr lacks 'duplicate'"; exit 1; }
grep -q "dup" /tmp/v7-stderr.log || { echo "FAIL AC1.8: stderr lacks module name"; exit 1; }
echo "PASS AC1.8"
rm -rf "$TMP"
```

**V8 — payload-modules.AC2.3 (no contract):**

```bash
TMP=$(mktemp -d)
# No modules.list, no build.sh.
bin/build-image.sh "$TMP" --output-format gz 2>&1 | tee /tmp/v8-stderr.log >/dev/null
grep -q "modules.list" /tmp/v8-stderr.log || { echo "FAIL AC2.3: stderr lacks 'modules.list'"; exit 1; }
grep -q "build.sh"     /tmp/v8-stderr.log || { echo "FAIL AC2.3: stderr lacks 'build.sh'"; exit 1; }
echo "PASS AC2.3"
rm -rf "$TMP"
```

**V9 — bash -n + optional shellcheck across all touched files:**

```bash
for f in bin/build-image.sh pipeline/remaster.sh lib/modules-loader.sh \
         examples/loader-smoke/modules/smoke/schema.sh \
         examples/loader-smoke/modules/smoke/module.sh; do
    bash -n "$f" || { echo "FAIL bash -n: $f"; exit 1; }
done
echo "PASS bash -n all"

# Optional, if shellcheck is installed.
if command -v shellcheck >/dev/null; then
    shellcheck bin/build-image.sh pipeline/remaster.sh lib/modules-loader.sh \
               examples/loader-smoke/modules/smoke/module.sh \
        || echo "(shellcheck reported issues — fix or annotate with disable comments)"
fi
```

**V10 — `git diff lib/` is empty for the original six lib files (payload-modules.AC2.2):**

Capture the phase-base SHA before any of this phase's commits land (the executor should set this at the start of Phase 1, before Task 1):

```bash
PHASE_BASE=$(git rev-parse HEAD)
# … phase work happens, multiple commits …
```

Then verify lib API stability at phase end:

```bash
# Lib API stability: this phase adds lib/modules-loader.sh but must not
# alter any of the existing lib/*.sh function signatures.
git diff --stat "$PHASE_BASE" -- \
    lib/hostname.sh lib/locale.sh lib/user.sh \
    lib/ssh.sh lib/wifi.sh lib/apt.sh
```

Expected: no files listed in the diff (this phase's commits should add `lib/modules-loader.sh` but not touch any of the others). If `PHASE_BASE` wasn't captured at phase start, fall back to `$(git rev-parse @{u})` (the upstream tracking branch tip).

**Commit:** `test(loader): end-to-end + failure-path verification for Phase 1 AC coverage`

(This commit may consist solely of running the verifications and confirming each PASS line. If any AC requires a small follow-up tweak to error messages or arg parsing, fold it into the preceding tasks rather than this verification task.)
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_C -->

---

## Phase Summary

After Phase 1, the loader is operational: `modules.list` payloads parse, validate, and dispatch through the existing pipeline. The legacy `build.sh` path is unchanged. The `core` module does not yet exist (Phase 2), and `hello-payload` is still on the legacy contract (migrated in Phase 3). The only new-contract payload after Phase 1 is `examples/loader-smoke/`, which exists primarily as a phase-isolation smoke test.

**Build is fully green at end of phase:** `bin/build-image.sh examples/hello-payload` (legacy) succeeds, `bin/build-image.sh examples/loader-smoke` (new) succeeds, all V1–V10 verifications pass.
