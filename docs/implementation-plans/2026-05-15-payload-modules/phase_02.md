# payload-modules Implementation Plan — Phase 2: The `core` module

**Goal:** Provide `modules/core/` — a single repo-level module that bundles the baseline-OS-config block (hostname, locale, user, ssh, wifi, machine-id reset) currently copy-pasted across every payload's `build.sh`. Pure orchestration of existing `lib/*.sh` functions; no new lib code.

**Architecture:** `modules/core/` is a vanilla module directory: `schema.sh` declares the canonical customization env vars (`HOSTNAME`, `TIMEZONE`, `PI_USER`, `ENCRYPTED_PASSWORD`, `SSH_PUBKEY` as `require`; `KEYMAP`, `AP_COUNTRY` as `optional`), and `module.sh` sources the six existing lib helpers and calls them in the canonical order observed in `examples/mpv-loop/build.sh`. The module is intended to be strictly-superset of every current payload's baseline block — every `lib/*.sh` call that ANY current payload makes for baseline-OS config is made by `core` (with the design's noted exception of `nm_rfkill_unblock_dropin`, which aether/server omits today; `core` includes it).

**Tech Stack:** Bash 5+, existing `lib/*.sh` helpers (no new code).

**Scope:** Phase 2 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — `lib/hostname.sh` (set_hostname, reset_machine_id), `lib/locale.sh` (set_timezone, set_keyboard), `lib/user.sh` (ensure_user, add_to_sudoers_nopasswd, disable_userconfig_wizard), `lib/ssh.sh` (install_pubkey, enable_ssh, disable_password_auth), `lib/wifi.sh` (enable_wifi_regdom, mask_systemd_rfkill, prime_nm_wifi_enabled, nm_rfkill_unblock_dropin, install_nm_wifi), `lib/apt.sh` (apt_install, apt_clean). Canonical mpv-loop baseline order observed at `examples/mpv-loop/build.sh:22-44`. Modules loader from Phase 1 in place at `lib/modules-loader.sh`.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC3: `core` module
- **payload-modules.AC3.1 Success:** A payload with `modules.list = core` (and required env) builds an image whose rootfs has the configured hostname, timezone, keymap, user with sudoers-nopasswd, ssh enabled with password auth disabled and the configured pubkey installed, wifi regdom set, systemd-rfkill masked, NM wifi primed, the NM rfkill-unblock dropin installed, and `/etc/machine-id` empty.
- **payload-modules.AC3.2 Success:** The resulting image boots on real Pi hardware (manual hardware verification).
- **payload-modules.AC3.3 Edge:** `core` is strictly-superset of pre-this-work mpv-loop's baseline-OS-config block (verified via Phase 7's image-diff gate).

---

## Project Conventions to Follow

(Same as Phase 1 — match existing bash style: `set -euo pipefail`, `local` declarations, `install -D -m` for file drops, idempotent helpers.)

Additionally for modules specifically:

- A module's `schema.sh` is sourced *host-side* in a subshell. It must only contain `require X` / `optional X default=Y` lines (plus comments). No side effects (no file writes, no apt calls, no `echo` to stdout — stdout is collected as schema output by the loader).
- A module's `module.sh` is sourced *chroot-side* into the synthetic runner. It runs with `set -euo pipefail` already in scope (from the runner header) plus `MODULE_DIR`, `MODULES_DIR`, `PAYLOAD_DIR`, `LIB_DIR` exported. It must NOT call `set +e` or re-source the runner. Idempotent if possible.
- A module's `files/` directory (if present) holds static assets the `module.sh` copies into the rootfs via `install -D -m`. There is no automatic overlay.
- Module `module.sh` files do NOT have a shebang and are NOT executable — they are sourced, not exec'd.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Create `modules/core/schema.sh`

**Verifies:** payload-modules.AC3.1 (schema enforcement for the canonical baseline vars).

**Files:**
- Create: `modules/core/schema.sh`

**`modules/core/schema.sh`:**

```bash
# core module — baseline OS configuration. Required for any payload that
# wants a usable Pi (boots, has a user, sshable, on wifi). Composed of
# pure lib/*.sh calls; no new behavior.

require HOSTNAME
require TIMEZONE
require PI_USER
require ENCRYPTED_PASSWORD
require SSH_PUBKEY

optional KEYMAP default=us
optional AP_COUNTRY default=US
```

**Rationale for required vs optional:**

- `HOSTNAME` and `TIMEZONE`: every payload pre-this-work sets them. No reasonable default (`localhost`/`UTC` would be fine technically but every venue has a real timezone). Require.
- `PI_USER`: pre-this-work payloads default to `pi`. Defaulting in the schema is tempting (`optional PI_USER default=pi`), but the design plan calls it required. Following the design — the operator should explicitly choose. If this proves annoying in practice, downgrade to optional in a follow-up.
- `ENCRYPTED_PASSWORD` and `SSH_PUBKEY`: no safe default; absent values are operator error. Require.
- `KEYMAP`: `us` is the de-facto default. Optional.
- `AP_COUNTRY`: `US` is the de-facto default (matches `examples/mpv-loop/build.sh:38`). Optional. Note: payloads that don't use wifi (a future ethernet-only embedded Pi) still get the wifi-regdom service installed because `core` is fixed-shape — that's the cost of "one canonical baseline." If this becomes a real friction point, split `core` later; not in this phase.

**Verification:**

Run: `bash -n modules/core/schema.sh`
Expected: no output, exit 0.

Run host-side schema test (uses the loader from Phase 1):

```bash
# All required vars set → no error, optional defaults appear in output.
HOSTNAME=test TIMEZONE=UTC PI_USER=pi \
ENCRYPTED_PASSWORD='$6$x$y' SSH_PUBKEY='ssh-ed25519 AAAA test' \
bash -c '
  source lib/modules-loader.sh
  validate_schemas "$(pwd)/modules/core"
' 2>&1
```

Expected stdout: includes `export KEYMAP=us` and `export AP_COUNTRY=US`. No stderr.

Then with a required var unset:

```bash
( unset HOSTNAME
  HOSTNAME='' TIMEZONE=UTC PI_USER=pi \
  ENCRYPTED_PASSWORD='$6$x$y' SSH_PUBKEY='ssh-ed25519 AAAA test' \
  bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/core"
  '
) 2>&1
```

Expected: exit 2, stderr contains `core` and `HOSTNAME`.

**Commit:** `feat(modules/core): add schema.sh for baseline OS-config env vars`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create `modules/core/module.sh`

**Verifies:** payload-modules.AC3.1 (every baseline-OS-config behavior), payload-modules.AC3.3 (strictly-superset of mpv-loop's pre-migration block).

**Files:**
- Create: `modules/core/module.sh`

**`modules/core/module.sh`:**

```bash
# core module — baseline OS configuration. Sourced into the synthetic
# module runner inside the chroot. Inputs (validated host-side by
# modules/core/schema.sh): HOSTNAME, TIMEZONE, PI_USER, ENCRYPTED_PASSWORD,
# SSH_PUBKEY required; KEYMAP, AP_COUNTRY optional with defaults.
#
# This module is the canonical opinion of pi-image-build on what a "usable
# Pi" looks like: named, time-set, a sudo user, sshable with a pubkey,
# wifi radio legally activated, machine-id ready to regenerate on first
# boot. Match exactly what examples/mpv-loop/build.sh does today (the
# strictly-superset claim per AC3.3).

source "$LIB_DIR/hostname.sh"
source "$LIB_DIR/locale.sh"
source "$LIB_DIR/user.sh"
source "$LIB_DIR/ssh.sh"
source "$LIB_DIR/wifi.sh"
source "$LIB_DIR/apt.sh"

# Hostname + locale + keymap.
set_hostname    "$HOSTNAME"
set_timezone    "$TIMEZONE"
set_keyboard    "$KEYMAP"

# User + sudoers + wizard disable. add_to_sudoers_nopasswd is the
# trusted-LAN posture documented in README.md — included unchanged.
ensure_user             "$PI_USER" "$ENCRYPTED_PASSWORD"
disable_userconfig_wizard
add_to_sudoers_nopasswd "$PI_USER"

# Pi OS Lite doesn't ship iw/rfkill/openssh-server by default; the wifi
# regdom oneshot needs them. Install before invoking the wifi lib.
apt_install iw rfkill openssh-server

# SSH: install pubkey for the configured user, enable sshd, disable
# password auth.
install_pubkey "$SSH_PUBKEY" "$PI_USER"
enable_ssh
disable_password_auth

# Wifi baseline: regdom oneshot, mask systemd-rfkill so it can't fight
# the oneshot, prime NM state, drop-in to belt-and-suspenders unblock
# rfkill at NM start.
enable_wifi_regdom    "$AP_COUNTRY"
mask_systemd_rfkill
prime_nm_wifi_enabled
nm_rfkill_unblock_dropin

# Reset machine-id so every Pi from this image generates its own on
# first boot.
reset_machine_id
```

**Order rationale:**

The order replicates `examples/mpv-loop/build.sh:22-44`. The only deviations are:

- mpv-loop runs `apt_install iw rfkill openssh-server` *between* `add_to_sudoers_nopasswd` and `install_pubkey`. `core` matches that exactly.
- mpv-loop does NOT call `apt_clean` at the baseline-block boundary (it does at the very end). `core` does NOT call `apt_clean` either — that's a runner-end concern, not a module concern. Per design, the runner does not auto-`apt_clean`; capability modules and `core` leave caches in place for the next module's `apt_install` to consume cheaply. The chroot cleanup in `pipeline/remaster.sh:201-202` (`rm -rf $MNT/var/cache/apt/archives/*.deb`, `rm -rf $MNT/var/lib/apt/lists/*`) handles end-of-build cache removal regardless.

The strictly-superset claim (payload-modules.AC3.3) is verified in Phase 7 via the image-diff gate — if `core` orchestration produces a different image from mpv-loop's hand-written baseline block, that's a diff to investigate.

**Testing:**

This module's behavior is tested end-to-end in Task 3 (a test payload with `modules.list = core` builds an image, and the image is inspected for the expected mutations). It is also tested via the Phase 7 image-diff gate when `examples/mpv-loop` migrates and the pre/post images are compared.

**Verification:**

Run: `bash -n modules/core/module.sh`
Expected: no output, exit 0.

(Functional verification is Task 3.)

**Commit:** `feat(modules/core): add module.sh — baseline OS config via lib/*.sh`
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (task 3) -->
<!-- START_TASK_3 -->
### Task 3: End-to-end build with `core`

**Verifies:** payload-modules.AC3.1 (every baseline-OS-config mutation present in the resulting image).

**Files:**
- No new files. Reuses `examples/loader-smoke/` from Phase 1 with a swapped `modules.list` for the duration of the test, OR uses a temp test payload. The instructions below use a temp payload to avoid polluting the existing smoke fixture.

**Approach:**

Build an image with `modules.list = core` and a `.env` providing the required vars. Mount the resulting image (kpartx-mount via a one-off invocation of the pipeline container, similar to what Phase 7's `bin/diff-images.sh` will formalize) and inspect the rootfs for each expected mutation.

**Setup — test payload:**

```bash
mkdir -p /tmp/core-test
cat > /tmp/core-test/modules.list <<'EOF'
core
EOF
cat > /tmp/core-test/.env <<'EOF'
HOSTNAME=core-test
TIMEZONE=UTC
PI_USER=pi
KEYMAP=us
AP_COUNTRY=US
ENCRYPTED_PASSWORD=$6$dummyhash$abcdef
SSH_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY core-test
EOF
```

(The dummy `ENCRYPTED_PASSWORD` is a syntactically valid SHA-512 crypt prefix; `chpasswd -e` will accept the format even though the hash is bogus. For real hardware testing, replace with a real value from `openssl passwd -6`.)

**Build:**

```bash
bin/build-image.sh /tmp/core-test --output-format gz
```

Expected stdout (in order):
- `==> env-file: /tmp/core-test/.env`
- `==> parsing modules.list`
- `==> validating schemas`
- `==> modules: core`
- `==> runner: /Users/.../pi-image-build/build-scratch/run-modules.sh`
- `==> building remaster container`
- `==> remastering (/tmp/core-test → /Users/.../out/core-test-<utc>.img.gz)`
- Inside the chroot run: `==> module: core` (echoed by the synthetic runner)
- `==> image built: /Users/.../out/core-test-<utc>.img.gz`

Build must succeed (exit 0). Capture the output path: `IMG=$(ls -t out/core-test-*.img.gz | head -1)`.

**Inspect — kpartx-mount the image and check each AC3.1 expectation:**

Run a one-off inspection container (same image the pipeline uses):

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

        echo "=== hostname ==="
        cat /mnt/r/etc/hostname

        echo "=== /etc/hosts ==="
        grep 127.0.1.1 /mnt/r/etc/hosts

        echo "=== timezone ==="
        cat /mnt/r/etc/timezone

        echo "=== keymap ==="
        grep XKBLAYOUT /mnt/r/etc/default/keyboard

        echo "=== user ==="
        grep "^pi:" /mnt/r/etc/passwd
        ls -la /mnt/r/etc/sudoers.d/

        echo "=== userconfig disabled ==="
        ls -la /mnt/r/etc/systemd/system/userconfig.service || true

        echo "=== ssh ==="
        ls -la /mnt/r/home/pi/.ssh/authorized_keys
        cat /mnt/r/home/pi/.ssh/authorized_keys
        cat /mnt/r/etc/ssh/sshd_config.d/10-pi-image-build.conf
        ls -la /mnt/r/etc/systemd/system/multi-user.target.wants/ssh.service || \
            ls -la /mnt/r/etc/systemd/system/sshd.service.wants/ || true

        echo "=== wifi regdom service ==="
        cat /mnt/r/etc/systemd/system/pibuild-wifi-regdom.service
        ls -la /mnt/r/etc/systemd/system/multi-user.target.wants/pibuild-wifi-regdom.service

        echo "=== systemd-rfkill masked ==="
        ls -la /mnt/r/etc/systemd/system/systemd-rfkill.service
        ls -la /mnt/r/etc/systemd/system/systemd-rfkill.socket

        echo "=== NM primed ==="
        cat /mnt/r/var/lib/NetworkManager/NetworkManager.state

        echo "=== NM rfkill-unblock dropin ==="
        cat /mnt/r/etc/systemd/system/NetworkManager.service.d/pibuild-unblock.conf

        echo "=== machine-id ==="
        stat -c "%n size=%s" /mnt/r/etc/machine-id
        ls -la /mnt/r/var/lib/dbus/machine-id 2>/dev/null || echo "  (absent — good)"

        umount /mnt/r
    '
```

**Each AC3.1 sub-claim verified:**

| AC3.1 sub-claim | What to look for in the inspection output |
|---|---|
| hostname configured | `/etc/hostname` contains `core-test`; `/etc/hosts` has `127.0.1.1\tcore-test` |
| timezone | `/etc/timezone` contains `UTC` |
| keymap | `/etc/default/keyboard` has `XKBLAYOUT="us"` |
| user with sudoers-nopasswd | `pi` exists in `/etc/passwd`; `/etc/sudoers.d/010-pi-nopasswd` exists |
| userconfig wizard disabled | `/etc/systemd/system/userconfig.service → /dev/null` (symlink) |
| ssh enabled | `/etc/ssh/sshd_config.d/10-pi-image-build.conf` exists; `ssh.service` enabled (symlinked into `multi-user.target.wants/`) |
| password auth disabled | `PasswordAuthentication no` in the conf |
| pubkey installed | `/home/pi/.ssh/authorized_keys` contains the `SSH_PUBKEY` |
| wifi regdom set | `pibuild-wifi-regdom.service` contains `iw reg set US`; enabled in multi-user.target.wants |
| systemd-rfkill masked | `systemd-rfkill.service → /dev/null` and `systemd-rfkill.socket → /dev/null` |
| NM wifi primed | `/var/lib/NetworkManager/NetworkManager.state` has `WirelessEnabled=true` |
| NM rfkill-unblock dropin | `/etc/systemd/system/NetworkManager.service.d/pibuild-unblock.conf` exists |
| machine-id empty | `/etc/machine-id` has size 0; `/var/lib/dbus/machine-id` absent |

If any check fails, fix the corresponding lib call in `modules/core/module.sh` or the underlying `lib/*.sh` (the latter should not be needed since lib is frozen).

**payload-modules.AC3.2 (boots on real hardware):**

Manual verification. Flash the resulting image to an SD card:

```bash
bin/flash-image.sh out/core-test-*.img.gz
```

Insert into a Pi, power on. Expected: Pi boots, SSH login as `pi` with the configured pubkey works (assuming wifi creds match the real environment; for `core`-alone with no wifi profile, ethernet must be plugged in). Mark this AC as "manual hardware verification — operator-confirmed" in the test-requirements artifact.

**payload-modules.AC3.3 (strictly-superset of mpv-loop pre-migration):**

Deferred to Phase 7's image-diff gate. The only thing to verify in Phase 2 is that `modules/core/module.sh` calls a strict superset of the lib functions `examples/mpv-loop/build.sh:22-44` calls. Confirm by inspection:

| lib function called by mpv-loop baseline (lines 22-44) | called by `modules/core/module.sh`? |
|---|---|
| `set_hostname` | ✓ |
| `set_timezone` | ✓ |
| `set_keyboard` | ✓ |
| `ensure_user` | ✓ |
| `disable_userconfig_wizard` | ✓ |
| `add_to_sudoers_nopasswd` | ✓ |
| `apt_install iw rfkill openssh-server` | ✓ |
| `install_pubkey` | ✓ |
| `enable_ssh` | ✓ |
| `disable_password_auth` | ✓ |
| `enable_wifi_regdom` | ✓ |
| `mask_systemd_rfkill` | ✓ |
| `prime_nm_wifi_enabled` | ✓ |
| `nm_rfkill_unblock_dropin` | ✓ |
| `reset_machine_id` | ✓ |

All 15 calls present in `core`. Confirmed strictly-superset by source comparison. Image-level confirmation happens in Phase 7.

**Commit:** `test(modules/core): end-to-end build + inspection verifies AC3.1`

(As with Phase 1, this verification may not need its own commit if no fixes are required. If `core` produces a wrong-shape image, fold fixes into Task 2.)
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_B -->

---

## Phase Summary

After Phase 2, `modules/core/` exists and is the canonical baseline for any new-contract payload. A payload with `modules.list = core` and a fully-populated `.env` produces a usable Pi OS image with all baseline mutations applied. No `lib/*.sh` files were modified. The next phase migrates `examples/hello-payload` to `modules.list = core + hello` to exercise `core` against a real first-party payload.

**Build is green at end of phase:** the temp `/tmp/core-test` payload from Task 3 builds, its image passes all AC3.1 file-presence checks, no `lib/*.sh` regressions. AC3.2 (hardware boot) is operator-confirmed; AC3.3 (image-diff equivalence) is deferred to Phase 7.
