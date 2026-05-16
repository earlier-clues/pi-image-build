# payload-modules Implementation Plan — Phase 7: Image-diff gate + migrate `examples/mpv-loop`

**Goal:** Build `bin/diff-images.sh` (the verification tool), use it to certify that migrating `examples/mpv-loop` from the legacy `build.sh` contract to `modules.list = core + mpv-loop` produces an image-equivalent result (modulo a documented ignore list), and complete the migration. Also: update `README.md` with the "Authoring a payload" section (the AC9 docs work).

**Architecture:** `bin/diff-images.sh OLD NEW` runs the existing pipeline container (which already has `kpartx`, `parted`, `xz-utils`, `gzip`) with `--privileged`, decompresses both images, kpartx-mounts each, runs `diff -rq` on the two rootfs trees, filters the output through a hardcoded ignore list that covers known sources of build-time entropy (machine-id, apt caches and dpkg databases, ssh host keys, NM connection uuids, systemd random-seed, var/log), and exits 0 if surviving differences are empty (otherwise prints them and exits 1). For the migration itself: `examples/mpv-loop/modules/mpv-loop/` is a payload-local module containing schema (declaring mpv-specific env vars), `module.sh` (the mpv-loop-specific work that today lives at `examples/mpv-loop/build.sh` lines 47–end), and `files/` (the existing systemd units and scripts moved verbatim from `examples/mpv-loop/files/`). The `modules.list = core + mpv-loop` means core does the baseline; the payload-local mpv-loop module does the rest. The pre- and post-migration images, built from identical env, should be diff-equivalent under the ignore list — that's the AC8.2 verification.

**Tech Stack:** Bash, `kpartx`, `diff`, `grep -E -v`. No new external dependencies (pipeline container already has everything).

**Scope:** Phase 7 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`. Includes the docs work for `payload-modules.AC9`.

**Codebase verified:** 2026-05-15 — `pipeline/Dockerfile` includes `parted e2fsprogs dosfstools kpartx util-linux mount coreutils kmod xz-utils gzip pigz` plus `diffutils` (transitively via coreutils baseline). `pipeline/remaster.sh` is the precedent for kpartx-mounting inside the container (lines 56–73). `examples/mpv-loop/build.sh` has 128 lines: lines 1–20 are header + sources, lines 22–44 are the baseline OS config block (subsumed by `core`), lines 46–end are mpv-specific. `examples/mpv-loop/files/` has 7 assets: `mpv-loop`, `mpv-loop-assign-hostname`, `mpv-loop-assign-hostname.service`, `mpv-loop-boot-report`, `mpv-loop-boot-report.service`, `mpv-loop-boot-report.timer`, `mpv-loop.service`, `wifi-powersave-off.service`. `examples/mpv-loop/build-example.sh` is a 139-line wrapper that loads `.env`, computes `ENCRYPTED_PASSWORD`/`SSH_PUBKEY`, resolves `VIDEO`, and exec's `bin/build-image.sh` — this wrapper stays in the new contract (with minor adjustments).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC8: `examples/mpv-loop` migrated with image-diff gate
- **payload-modules.AC8.1 Success:** `examples/mpv-loop/` no longer contains a top-level `build.sh`; it contains `modules.list = core + mpv-loop`, `.env.example`, and a payload-local `modules/mpv-loop/` containing the mpv-specific work (apt install, KMS config, assign-hostname unit, video baking).
- **payload-modules.AC8.2 Success:** `bin/diff-images.sh OLD NEW` returns 0 when comparing the pre-migration and post-migration mpv-loop images (after the documented ignore list).
- **payload-modules.AC8.3 Success:** The post-migration image boots on real Pi hardware and plays the configured video loop (manual hardware verification, same as pre-migration).
- **payload-modules.AC8.4 Edge:** Any surviving diff after the ignore list is documented (in the design plan or a Phase 7 PR comment) with a benign explanation; otherwise this AC fails.

### payload-modules.AC9: Documentation
- **payload-modules.AC9.1 Success:** `README.md` gains an "Authoring a payload" section walking through `hello-payload` and `mpv-loop` in the new shape.
- **payload-modules.AC9.2 Success:** The module catalog convention is documented: each module's `schema.sh` is its env-var documentation; longer prose goes in optional `modules/<name>/README.md`.

---

<!-- START_SUBCOMPONENT_A (task 1) -->
<!-- START_TASK_1 -->
### Task 1: Create `bin/diff-images.sh`

**Verifies:** payload-modules.AC8.2 (tool that produces the verification signal).

**Files:**
- Create: `bin/diff-images.sh`

**Design:**

The tool runs inside the existing pipeline container (so kpartx is available on macOS hosts). It accepts two paths to compressed image files (`.img.xz`, `.img.gz`, or `.img`), decompresses each to a tempfile inside the container, loopback-mounts each via kpartx, mounts the root partition (`p2`) of each to two distinct mountpoints, runs `diff -rq` between them, filters the result through an ignore list, and prints + exits according to whether differences survive.

**Usage:**

```
bin/diff-images.sh [--show-ignored] [--ignore PATTERN]... OLD NEW

Options:
  --show-ignored      Also print lines that the ignore list would drop.
                      Useful for understanding what's being suppressed.
  --ignore PATTERN    Additional grep -E pattern to ignore. Repeatable.
                      Appended to the hardcoded list.

Exit codes:
  0   no surviving differences after ignore list (PASS)
  1   surviving differences (FAIL — list printed to stdout)
  2   bad usage / file not found / setup failure

Note: first run builds the pipeline container (~30s); subsequent runs
reuse the cached image.
```

**`bin/diff-images.sh`:**

```bash
#!/usr/bin/env bash
# Filesystem diff between two pi-image-build output images. Mounts both
# under kpartx, runs `diff -rq` on the rootfs, filters known-noise paths.
# Use as a migration gate: pre-change image vs post-change image should
# diff clean (exit 0).
#
# Runs the pipeline container with --privileged so kpartx works on
# macOS hosts where the kernel doesn't expose loop devices.

set -euo pipefail

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
}

SHOW_IGNORED=0
EXTRA_IGNORES=()
OLD=""
NEW=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show-ignored) SHOW_IGNORED=1; shift ;;
        --ignore)       EXTRA_IGNORES+=("$2"); shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)
            if   [[ -z "$OLD" ]]; then OLD="$1"
            elif [[ -z "$NEW" ]]; then NEW="$1"
            else echo "unexpected arg: $1" >&2; usage >&2; exit 2
            fi
            shift ;;
    esac
done

[[ -n "$OLD" && -n "$NEW" ]] || { echo "error: OLD and NEW required" >&2; usage >&2; exit 2; }
[[ -f "$OLD" ]] || { echo "error: not a file: $OLD" >&2; exit 2; }
[[ -f "$NEW" ]] || { echo "error: not a file: $NEW" >&2; exit 2; }

OLD="$(cd "$(dirname "$OLD")" && pwd)/$(basename "$OLD")"
NEW="$(cd "$(dirname "$NEW")" && pwd)/$(basename "$NEW")"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_TAG="pi-image-build:latest"

# Build the pipeline container if it isn't already built.
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    docker build -t "$IMAGE_TAG" "$HERE/pipeline" > /tmp/pibuild-docker-build.log 2>&1 \
        || { cat /tmp/pibuild-docker-build.log; exit 4; }
fi

# Hardcoded ignore list. Each entry is an extended regex matched against
# `diff -rq` output lines. These cover the known sources of build-time
# entropy:
#
#   - machine-id (reset to empty by core; mtime may differ)
#   - apt caches & dpkg internal state (mtime + install-time vary)
#   - var/log (timestamps in log files)
#   - systemd random-seed (generated at first boot, may pre-exist)
#   - ssh host keys (ssh-keygen -A produces fresh keys per build)
#   - NetworkManager connection UUIDs (uuidgen per build)
#   - tmp / run / proc / sys (runtime trees, empty in offline images)
IGNORES=(
    'machine-id'
    '/var/cache/apt/'
    '/var/lib/apt/'
    '/var/lib/dpkg/'
    '/var/log/'
    '/var/lib/systemd/random-seed'
    '/etc/ssh/ssh_host_'
    '/etc/ssh/moduli'
    '/etc/NetworkManager/system-connections/'
    '/var/lib/NetworkManager/secret_key'
    '/var/lib/NetworkManager/seen-bssids'
    '/var/lib/NetworkManager/timestamps'
    '/var/lib/dbus/machine-id'
    '^Common subdirectories'
    '/tmp/'
    '/run/'
)
IGNORES+=("${EXTRA_IGNORES[@]}")

# Build the grep filter pattern. Each entry becomes one alternative.
# `printf '%s\n' "${IGNORES[@]}" | paste -sd '|' -` is the portable form.
FILTER_PATTERN="$(printf '%s\n' "${IGNORES[@]}" | paste -sd '|' -)"

# Inside the container, do the mounting and diffing.
docker run --rm --privileged \
    -v "$OLD":/in/old.img.compressed:ro \
    -v "$NEW":/in/new.img.compressed:ro \
    -e "FILTER_PATTERN=$FILTER_PATTERN" \
    -e "SHOW_IGNORED=$SHOW_IGNORED" \
    "$IMAGE_TAG" \
    bash <<'BASH'
set -euo pipefail

decompress() {
    local in="$1" out="$2"
    case "$(file -b --mime-type "$in")" in
        application/x-xz)         xz -dc "$in" > "$out" ;;
        application/gzip)         gzip -dc "$in" > "$out" ;;
        application/octet-stream) cp "$in" "$out" ;;
        *)
            echo "unknown image compression for $in: $(file -b "$in")" >&2
            exit 2 ;;
    esac
}

mount_image() {
    local img="$1" mnt="$2"
    local loop; loop="$(losetup --find --show "$img")"
    echo "$loop" >> /tmp/loops
    kpartx -av "$loop" >/dev/null
    local base; base="$(basename "$loop")"
    for _ in $(seq 1 20); do
        [[ -b "/dev/mapper/${base}p2" ]] && break
        sleep 0.2
    done
    [[ -b "/dev/mapper/${base}p2" ]] || { echo "p2 missing on $loop"; exit 3; }
    mkdir -p "$mnt"
    mount -o ro "/dev/mapper/${base}p2" "$mnt"
}

cleanup() {
    local rc=$?
    umount /mnt/old 2>/dev/null || true
    umount /mnt/new 2>/dev/null || true
    if [[ -f /tmp/loops ]]; then
        while IFS= read -r L; do
            kpartx -dv "$L" >/dev/null 2>&1 || true
            losetup -d "$L" >/dev/null 2>&1 || true
        done < /tmp/loops
    fi
    exit "$rc"
}
trap cleanup EXIT

: > /tmp/loops

decompress /in/old.img.compressed /tmp/old.img
decompress /in/new.img.compressed /tmp/new.img

mount_image /tmp/old.img /mnt/old
mount_image /tmp/new.img /mnt/new

# diff -rq: report differing files by name only (no content diff).
# Returns 0 if equal, 1 if differences found.
diff -rq /mnt/old /mnt/new > /tmp/diff.out 2>&1 || true

if (( SHOW_IGNORED )); then
    echo "==== full diff output (before filter) ===="
    cat /tmp/diff.out
    echo "==== end full diff ===="
fi

# Apply ignore filter. Lines NOT matching any ignore pattern survive.
if [[ -n "$FILTER_PATTERN" ]]; then
    grep -E -v "$FILTER_PATTERN" /tmp/diff.out > /tmp/diff.filtered || true
else
    cp /tmp/diff.out /tmp/diff.filtered
fi

if [[ -s /tmp/diff.filtered ]]; then
    echo "==== surviving diffs (after ignore list) ===="
    cat /tmp/diff.filtered
    echo "==== END FAIL ===="
    exit 1
fi

echo "PASS: no surviving differences."
BASH
```

**Notes:**

- The `'^Common subdirectories'` ignore drops `diff -rq`'s reporting of subtrees both sides have in common but where one side has files the other doesn't (those individual files DO survive the filter — only the redundant directory-existence summary lines are dropped).
- The cleanup trap unmounts and detaches loops even on failure. The temp file `/tmp/loops` records which loops were created; if `losetup --find --show` was called but the subsequent kpartx failed, we still cleanup the loop.
- `paste -sd '|' -` joins the array into a pipe-separated regex. Works on macOS and Linux.
- The tool itself is the only thing in `bin/` that operates on pre-built images (alongside `flash-image.sh` and `test-image.sh`). It's not part of the build pipeline; it's a verification gate.

**Verification:**

```bash
bash -n bin/diff-images.sh
chmod +x bin/diff-images.sh
bin/diff-images.sh --help
```
Expected: usage text printed, exit 0.

```bash
# Self-test: an image diffed against itself should always exit 0.
IMG=$(ls out/*.img.gz 2>/dev/null | head -1)
[[ -n "$IMG" ]] && bin/diff-images.sh "$IMG" "$IMG" && echo "PASS self-diff"
```
Expected (if any prior build artifact exists): `PASS: no surviving differences.`

**Commit:** `feat(bin/diff-images): image-diff verification tool with ignore list`
<!-- END_TASK_1 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 2-5) -->
<!-- START_TASK_2 -->
### Task 2: Build the pre-migration mpv-loop image (baseline for the diff)

**Verifies:** payload-modules.AC8.2 (prerequisite — establishes the "OLD" image).

**Files:**
- No source changes in this task. This task captures a build artifact for the diff comparison.

**Steps:**

This task runs BEFORE the destructive migration changes in Tasks 3–5. The git HEAD must still contain the legacy `examples/mpv-loop/build.sh`.

```bash
# Confirm legacy file still present.
test -f examples/mpv-loop/build.sh || { echo "ABORT: mpv-loop already migrated, no baseline to build"; exit 1; }

# Configure a real .env (operator's video, real wifi creds). The operator
# should already have one at examples/mpv-loop/.env per the legacy workflow.
test -f examples/mpv-loop/.env || cp examples/mpv-loop/.env.example examples/mpv-loop/.env

# Build the legacy image. Use deterministic --output so the artifact name
# is predictable for Task 5's diff.
mkdir -p out
examples/mpv-loop/build-example.sh \
    --output out/mpv-loop-pre-migration.img.gz \
    --output-format gz
```

Expected: legacy build succeeds, artifact at `out/mpv-loop-pre-migration.img.gz`.

Stash this image somewhere safe (don't rebuild between Tasks 3–4 and Task 5):

```bash
test -f out/mpv-loop-pre-migration.img.gz \
    && echo "  pre-migration baseline captured ($(stat -c%s out/mpv-loop-pre-migration.img.gz 2>/dev/null || stat -f%z out/mpv-loop-pre-migration.img.gz) bytes)"
```

**Verification:**

`ls -la out/mpv-loop-pre-migration.img.gz` shows a non-zero-size file.

**Commit:** No commit (build artifact only, gitignored by `out/` rule in `.gitignore`).
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `examples/mpv-loop/modules/mpv-loop/` with schema, module, and moved assets

**Verifies:** payload-modules.AC8.1 (new file shape).

**Files:**
- Create: `examples/mpv-loop/modules/mpv-loop/schema.sh`
- Create: `examples/mpv-loop/modules/mpv-loop/module.sh`
- Create: `examples/mpv-loop/modules/mpv-loop/files/` (directory)
- Move (via `git mv`): each asset under `examples/mpv-loop/files/` → `examples/mpv-loop/modules/mpv-loop/files/`

**`examples/mpv-loop/modules/mpv-loop/schema.sh`:**

```bash
# mpv-loop module — payload-local. Installs mpv + alsa-utils, KMS config,
# the assign-hostname-from-MAC unit, the wifi-powersave-off unit, and the
# mpv-loop service that plays a looped video.

optional MPV_AUDIO_OUT default=null

# Wifi profile is optional — only installed if AP_SSID is set. Both
# AP_PSK and (existing optional) AP_COUNTRY are consumed by core, but
# the *profile install* lives here so mpv-loop-without-wifi works.
optional AP_SSID  default=
optional AP_PSK   default=
```

**`examples/mpv-loop/modules/mpv-loop/module.sh`:**

```bash
# mpv-loop module — payload-local. Everything in pre-migration
# examples/mpv-loop/build.sh that's NOT the baseline-OS-config block
# (that's now in modules/core).
#
# Inputs (from schema.sh): MPV_AUDIO_OUT (default null), AP_SSID/AP_PSK
# (optional, default empty).

source "$LIB_DIR/wifi.sh"
source "$LIB_DIR/apt.sh"

# Ordering check: mpv-loop must come AFTER core in modules.list. We
# can't check via `command -v` because mpv-loop re-sources lib/wifi.sh
# itself; instead check for a SIDE EFFECT of core having run — the
# PI_USER account must already exist (created by core's ensure_user).
# Without core, downstream `chown -R "$PI_USER:$PI_USER"` would fail
# with a confusing "invalid user" error.
if ! id "$PI_USER" >/dev/null 2>&1; then
    echo "modules/mpv-loop: PI_USER='$PI_USER' does not exist — core must precede mpv-loop in modules.list" >&2
    exit 2
fi

FILES="$MODULE_DIR/files"
PI_USER="${PI_USER:-pi}"

echo "--- mpv-loop module ---"

# ----- mpv + audio stack -------------------------------------------------

apt_install mpv alsa-utils

# ----- mpv config (KMS on Pi OS Lite, no X/Wayland) ----------------------
# vo=gpu/drm draws straight to /dev/dri/card0. ao defaults to null
# because Pi OS Lite has no audio backend; mpv's auto-fallback
# (PipeWire/JACK/Pulse) spams retries and chews CPU. Override
# MPV_AUDIO_OUT (e.g. alsa) when audio is wanted.
install -d -m 755 /etc/mpv
cat > /etc/mpv/mpv.conf <<MPV
vo=gpu
gpu-context=drm
gpu-api=opengl
hwdec=auto-safe
ao=${MPV_AUDIO_OUT}
fullscreen=yes
osc=no
input-default-bindings=no
terminal=no
MPV

# ----- wifi profile ------------------------------------------------------
# Optional: only install if AP_SSID is provided.

if [[ -n "$AP_SSID" ]]; then
    install_nm_wifi mpv-loop "$AP_SSID" "$AP_PSK" "" 100
else
    echo "  note: AP_SSID unset, no wifi profile installed (ethernet only)"
fi

# ----- per-device hostname from MAC --------------------------------------

install -D -m 755 "$FILES/mpv-loop-assign-hostname" \
    /usr/local/bin/mpv-loop-assign-hostname
install -D -m 644 "$FILES/mpv-loop-assign-hostname.service" \
    /etc/systemd/system/mpv-loop-assign-hostname.service

# ----- wifi power save off (latency spikes otherwise) --------------------

install -D -m 644 "$FILES/wifi-powersave-off.service" \
    /etc/systemd/system/wifi-powersave-off.service

# ----- mpv-loop service + launcher ---------------------------------------

install -D -m 755 "$FILES/mpv-loop" /usr/local/bin/mpv-loop
install -D -m 644 "$FILES/mpv-loop.service" \
    /etc/systemd/system/mpv-loop.service

# ----- boot-time diagnostic dump (writes to FAT bootfs) ------------------
# Kept verbatim from pre-migration so the image-diff gate passes.
# Future cleanup: migrate to the generic boot-report module from Phase 5
# and remove these three files. Not done in this phase because that
# would produce a non-trivial image diff and fail AC8.2.

install -D -m 755 "$FILES/mpv-loop-boot-report" \
    /usr/local/bin/mpv-loop-boot-report
install -D -m 644 "$FILES/mpv-loop-boot-report.service" \
    /etc/systemd/system/mpv-loop-boot-report.service
install -D -m 644 "$FILES/mpv-loop-boot-report.timer" \
    /etc/systemd/system/mpv-loop-boot-report.timer

# ----- bake the video in -------------------------------------------------

VIDEO_DIR="/home/$PI_USER/video"
install -d -m 755 "$VIDEO_DIR"
if [[ -d "${MOUNTS_DIR:-}/video" ]]; then
    cp -aL "$MOUNTS_DIR/video/." "$VIDEO_DIR/"
    count=$(find "$VIDEO_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
    echo "  baked $count file(s) into $VIDEO_DIR"
else
    echo "  WARNING: no --mount video=DIR provided; image has no video to play"
fi
chown -R "$PI_USER:$PI_USER" "$VIDEO_DIR"

# ----- enable services ---------------------------------------------------

systemctl enable mpv-loop-assign-hostname.service
systemctl enable wifi-powersave-off.service
systemctl enable mpv-loop.service
systemctl enable mpv-loop-boot-report.timer

apt_clean
echo "--- mpv-loop module done ---"
```

**Move the asset files (`git mv` preserves history):**

```bash
mkdir -p examples/mpv-loop/modules/mpv-loop/files
for f in mpv-loop mpv-loop-assign-hostname mpv-loop-assign-hostname.service \
         mpv-loop-boot-report mpv-loop-boot-report.service mpv-loop-boot-report.timer \
         mpv-loop.service wifi-powersave-off.service; do
    git mv "examples/mpv-loop/files/$f" "examples/mpv-loop/modules/mpv-loop/files/$f"
done
# Remove the now-empty directory.
rmdir examples/mpv-loop/files
```

**Verification:**

```bash
bash -n examples/mpv-loop/modules/mpv-loop/schema.sh
bash -n examples/mpv-loop/modules/mpv-loop/module.sh
ls examples/mpv-loop/modules/mpv-loop/files/ | wc -l   # expect 8
```

**Commit:** `refactor(examples/mpv-loop): extract mpv-specific work into payload-local module`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Create `modules.list`, update `.env.example`, and delete `build.sh`

**Verifies:** payload-modules.AC8.1 (no top-level `build.sh`, `modules.list` present, `.env.example` present).

**Files:**
- Create: `examples/mpv-loop/modules.list`
- Modify: `examples/mpv-loop/.env.example`
- Delete: `examples/mpv-loop/build.sh`
- Update: `examples/mpv-loop/build-example.sh` (the wrapper — minor adjustments to env-var forwarding)

**`examples/mpv-loop/modules.list`:**

```
# mpv-loop — Pi that boots, joins wifi, and plays a video on infinite loop.
# core does the baseline OS config; the payload-local mpv-loop module does
# the mpv install, KMS config, video baking, and the assign-hostname unit.

core
mpv-loop
```

**`examples/mpv-loop/.env.example`** — replace pre-migration content with the new-contract shape (the wrapper `build-example.sh` derives `ENCRYPTED_PASSWORD` and `SSH_PUBKEY` from `PI_PASSWORD` and `SSH_PUBKEY_FILE` respectively):

```
# mpv-loop example config. Copy to .env and fill in.

# --- required by modules/core (baseline OS config) ---
HOSTNAME=mpv-loop            # placeholder; first boot rewrites to mpv-loop-<MAC[-6:]>
TIMEZONE=America/Los_Angeles
PI_USER=pi
# Either PI_PASSWORD (clear; build-example.sh hashes it) OR
# ENCRYPTED_PASSWORD (pre-hashed). One must be set.
PI_PASSWORD=changeme
# Path to your SSH public key; relative paths resolve against this file.
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub

# --- required (or pass --video on the CLI) ---
# Path to the video file (or a directory containing it).
VIDEO=./my-video.mp4

# --- optional, consumed by core ---
# KEYMAP=us
# AP_COUNTRY=US

# --- optional, consumed by the mpv-loop module ---
# MPV_AUDIO_OUT=null         # set to alsa for sound out HDMI
# AP_SSID=aether             # leave unset for ethernet-only
# AP_PSK=changeme

# --- optional, consumed by build-example.sh ---
# OUTPUT_FORMAT=gz           # gz (pigz, fast) or xz (slower, smaller)
```

**`examples/mpv-loop/build-example.sh`** — adjust the `--env-regex` invocation to NOT pass the AP_* and MPV_* vars (the new contract sources `.env` itself so the wrapper doesn't need to forward those via env-regex), but DO still forward HOSTNAME/PI_USER/etc. as it does today:

Locate the `exec "$PIBUILD/bin/build-image.sh" ...` block near the end of the file (around line 131). Change:

```
exec "$PIBUILD/bin/build-image.sh" \
    "$PAYLOAD_DIR" \
    --output-format "$OUTPUT_FORMAT" \
    --env-regex 'AP_.*|MPV_.*' \
    --mount "video=$VIDEO_MOUNT" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
```

to:

```
# New-contract: build-image.sh auto-sources <payload>/.env, so AP_*/MPV_*
# come in via the env-file path. We still forward the wrapper-derived
# ENCRYPTED_PASSWORD and SSH_PUBKEY (computed above), plus the canonical
# customization vars, via the bin/build-image.sh built-in forwarding.
exec "$PIBUILD/bin/build-image.sh" \
    "$PAYLOAD_DIR" \
    --output-format "$OUTPUT_FORMAT" \
    --mount "video=$VIDEO_MOUNT" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
```

(The `--env-regex 'AP_.*|MPV_.*'` is removed — `.env` carries those vars and the new-contract dispatch sources them. ENCRYPTED_PASSWORD and SSH_PUBKEY are exported by the wrapper and forwarded via build-image.sh's canonical-vars loop.)

**Delete the legacy `build.sh`:**

```bash
git rm examples/mpv-loop/build.sh
```

**Verification:**

```bash
ls examples/mpv-loop/
```
Expected: `.env`, `.env.example`, `build-example.sh`, `content/`, `modules.list`, `modules/`, `README.md`, plus the pre-existing `aether-pi.pub` if it's still there. NO `build.sh`. NO `files/`.

```bash
cat examples/mpv-loop/modules.list
```
Expected: the new-contract content above.

**Commit:** `refactor(examples/mpv-loop): drop legacy build.sh — replaced by modules.list (core + mpv-loop)`
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Build post-migration image and run the image-diff gate

**Verifies:** payload-modules.AC8.2 (post-migration is image-equivalent to pre-migration after ignore list), payload-modules.AC8.4 (any surviving deltas documented as benign).

**Files:**
- No source changes. Build artifact + verification.

**Build post-migration:**

```bash
# Use the same .env as Task 2 so the only thing changed between builds
# is the contract shape.
examples/mpv-loop/build-example.sh \
    --output out/mpv-loop-post-migration.img.gz \
    --output-format gz
```

Expected: build succeeds, artifact at `out/mpv-loop-post-migration.img.gz`. `==> modules: core mpv-loop` in stdout.

**Run the diff gate:**

```bash
bin/diff-images.sh \
    out/mpv-loop-pre-migration.img.gz \
    out/mpv-loop-post-migration.img.gz
```

**Expected outcomes:**

**Outcome A — clean PASS:** Tool exits 0, prints `PASS: no surviving differences.` Phase 7 is done; commit a verification note.

**Outcome B — surviving deltas, all benign:** Tool exits 1 with a list of differing files. For each, determine whether it's a known source of entropy (timestamp, uuid, etc.) that should be added to the ignore list, or a real behavioral change.

Common surviving deltas to expect and how to handle each:

| Diff line | Cause | Action |
|---|---|---|
| `Only in /mnt/{old,new}/...: <some apt-deb file>` | apt's view of installed packages drifted between builds (e.g., a package version updated upstream) | If the binary content is the same, add the path to the ignore list. If the version changed, document the version delta in a Phase 7 PR comment as benign. |
| `Files .../etc/ssh/sshd_config.d/10-pi-image-build.conf differ` | Should NOT differ — both use `lib/ssh.sh::disable_password_auth`. If this surfaces, investigate. | Real change — fix in `core` or the migration. |
| `Only in .../home/pi/video: ...` | The baked video files are different between builds | Ensure both builds used the same `--video` source. Re-run if needed. |
| `Files .../etc/mpv/mpv.conf differ` | `ao=` line differs (default `null` vs whatever the operator set) | Confirm both builds used the same `MPV_AUDIO_OUT`. If yes and still differs, investigate. |

**Iterate:**

1. If real behavioral differences appear, fix them (most likely in `examples/mpv-loop/modules/mpv-loop/module.sh` or in the asset move).
2. If new noise patterns appear that the ignore list missed, add them to `bin/diff-images.sh::IGNORES` and document the addition in a comment above the array.
3. Rebuild post-migration image and re-run diff.

**Documenting AC8.4:**

After the gate passes, ANY surviving (un-suppressed) deltas — or ignore-list additions made during this phase — must be documented in a Phase 7 PR comment OR in `docs/design-plans/2026-05-15-payload-modules.md`'s "Additional Considerations" section. The documentation must say:

- Which file path differs.
- Why it differs (build-time entropy source: machine-id, ssh keys, uuid, dpkg state, etc.).
- Why the difference is benign (e.g., "regenerated on first boot anyway", or "two random keys, neither used until later boot").

A documented surviving delta satisfies AC8.4. An undocumented one fails it.

**AC8.3 (real-hardware boot + video plays):** manual operator verification. Flash `out/mpv-loop-post-migration.img.gz` to an SD card, boot the Pi, confirm `mpv-loop.service` starts and the video plays. Mark as operator-confirmed.

**Commit:** `test(mpv-loop): image-diff gate confirms migration is image-equivalent`

(Body of the commit: any ignore-list additions made during iteration, with one-line rationale for each.)
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (task 6) -->
<!-- START_TASK_6 -->
### Task 6: Update `README.md` — "Authoring a payload" section + module-catalog convention

**Verifies:** payload-modules.AC9.1, payload-modules.AC9.2.

**Files:**
- Modify: `README.md` — add a new top-level section after the existing "The payload contract" section (around line 32). Keep the existing legacy-contract section; the new section documents the new contract alongside it.

**New section content** (inserted into `README.md` after the existing "The payload contract" section):

```markdown
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
| `tailscale` | `TAILSCALE_AUTHKEY` | `TAILSCALE_HOSTNAME`, `TAILSCALE_FLAGS=--ssh` | Install Tailscale, enroll on first boot, self-disable. |
| `boot-report` | — | `BOOT_REPORT_LOG_NAME=boot.log`, `BOOT_REPORT_UNITS`, `BOOT_REPORT_JOURNAL_UNITS` | Drop a diagnostic dump to `/boot/firmware/<log-name>` at T+90s and T+180s. |
| `mqtt-telemetry` | `MQTT_BROKER`, `MQTT_ROLE` | `MQTT_CERT_PATH` | Publish per-Pi health/version/online to an MQTT broker on a 10s cadence with LWT. |
```

**`README.md` "Layout" table update** — add three rows for the new components:

| `bin/diff-images.sh` | image-diff verification gate. Compares two built images, ignores known build-time entropy. |
| `lib/modules-loader.sh` | host-side module parser/validator/runner-emitter. Sourced by `bin/build-image.sh`. |
| `modules/` | repo-level modules. Each is `<name>/{schema.sh, module.sh, [files/, README.md]}`. |

**Verification:**

```bash
# README parses as valid Markdown (no broken table syntax).
# Manual visual inspection.
less README.md
```

Confirm: new section is present, module catalog table lists all four repo-level modules with correct env vars, code-fenced examples are accurate.

**Commit:** `docs(README): add "Authoring a payload" section + module catalog (AC9)`
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_C -->

---

## Phase Summary

After Phase 7, `examples/mpv-loop/` is the canonical example of a payload that combines `core` with a payload-local module. The migration produced an image-equivalent (or documented-benign-different) result, verified by `bin/diff-images.sh`. The README documents the new contract for any future payload author. The full work scope from the design plan is complete.

**What's deliberately deferred (per the design plan's "Out of scope" section):**
- `aether/*` payload migrations — they continue to consume `lib/*.sh` directly via their existing `build.sh` files.
- Replacing mpv-loop's custom `mpv-loop-boot-report*` files with the generic `modules/boot-report` — would cause a non-trivial image diff and break AC8.2 in this phase. A clean follow-up task.
- `examples/mqtt-broker/` payload — anticipated future work for aether/server.
- Module-depends-on-module declarations, conditional module inclusion, templated module sets.

**Build is green at end of phase:** legacy `examples/mpv-loop` no longer exists (it's now new-contract); `examples/hello-payload` (new-contract) builds; both `examples/*` produce bootable images. `bin/diff-images.sh` self-test passes (image diffed against itself is empty). `pytest tests/` passes. The README has the new docs.
