# payload-modules Implementation Plan — Phase 4: `tailscale` capability module

**Goal:** Ship `lib/tailscale.sh` + `modules/tailscale/` so any new-contract payload can add `tailscale` to its `modules.list` and gain auto-enroll on first boot via a oneshot service that disables itself after a successful `tailscale up`.

**Architecture:** `lib/tailscale.sh::install_tailscale AUTHKEY [--hostname HN] [--ssh] [--accept-routes]` is the parametrized installer (parallel shape to `lib/wifi.sh::install_nm_wifi`). It sets up the official Tailscale apt repo, installs the `tailscale` package, and drops a `tailscale-firstboot.service` (oneshot, `RemainAfterExit=yes`) into `/etc/systemd/system/` from a template at `lib/tailscale/tailscale-firstboot.service`. The unit runs `tailscale up --auth-key=… --hostname=… [flags]` and `systemctl disable`s itself in `ExecStartPost` so it doesn't try to re-enroll on subsequent boots. `modules/tailscale/` wraps the lib call with a schema declaring `TAILSCALE_AUTHKEY` (required), `TAILSCALE_HOSTNAME` (optional, default `$HOSTNAME`), and `TAILSCALE_FLAGS` (optional, default `--ssh`).

**Tech Stack:** Bash, Tailscale's Debian apt repository, systemd. No new build-time dependencies (curl is already in `pipeline/Dockerfile`).

**Scope:** Phase 4 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — `lib/wifi.sh` (template-and-sed pattern in `enable_wifi_regdom` at lines ~18–27) is the canonical model for a lib function that installs a systemd unit with placeholders. `lib/wifi/regdom.service` (lib-adjacent template directory) is the existing precedent for non-script lib assets. `pipeline/Dockerfile` has `curl` and `ca-certificates`. The chroot has internet access during build (apt installs already work).

**External dependency findings (Tailscale apt repo):**
- ✓ Official Debian repo at `https://pkgs.tailscale.com/stable/debian/` keyed by Debian codename (e.g. `bookworm`, `trixie`). arm64 supported.
- ✓ GPG keyring fetch URL: `https://pkgs.tailscale.com/stable/debian/<codename>.noarmor.gpg`
- ✓ Sources.list fetch URL: `https://pkgs.tailscale.com/stable/debian/<codename>.tailscale-keyring.list` (returns a pre-formatted `deb [signed-by=…] … main` line)
- ✓ Package name: `tailscale` (provides both `tailscaled` daemon and `tailscale` CLI). Auto-starts `tailscaled.service` on install via the deb's postinst.
- ✓ `tailscale up --auth-key=KEY --hostname=NAME --ssh --accept-routes` exits 0 on successful enrollment. Auth keys may be one-time-use or reusable depending on how they're minted in the admin console.
- ✓ Codename detection inside the chroot: `. /etc/os-release; echo "$VERSION_CODENAME"` — Pi OS Lite on the current base is `bookworm`.
- 📖 Source: https://tailscale.com/download/linux (Debian instructions, accessed 2026-05-15).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC5: `tailscale` module
- **payload-modules.AC5.1 Success:** A payload with `modules.list = core + tailscale` and a valid `TAILSCALE_AUTHKEY` builds an image with tailscale installed and a `tailscale-firstboot.service` configured.
- **payload-modules.AC5.2 Success:** On real hardware, the Pi appears on the tailnet within ~60s of first boot with hostname `${TAILSCALE_HOSTNAME:-$HOSTNAME}` (manual hardware verification).
- **payload-modules.AC5.3 Success:** The `tailscale-firstboot.service` disables itself after its first successful run.
- **payload-modules.AC5.4 Failure:** Missing `TAILSCALE_AUTHKEY` aborts host-side with a clear error.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Create `lib/tailscale.sh` and the firstboot template

**Verifies:** payload-modules.AC5.1, payload-modules.AC5.3.

**Files:**
- Create: `lib/tailscale.sh`
- Create: `lib/tailscale/tailscale-firstboot.service`

**`lib/tailscale.sh`:**

```bash
#!/bin/bash
# Tailscale install + firstboot enrollment. Run inside the chroot.
LIB_API_VERSION=1

# Install tailscale (from the official Debian apt repo) and drop a
# oneshot firstboot service that runs `tailscale up` on first boot with
# the configured auth key, then disables itself.
#
# Args:
#   $1 auth key (tskey-…) — required, positional.
#
# Flags (any order, after the auth key):
#   --hostname HN       hostname to register on the tailnet
#                       (default: empty → tailscale derives from /etc/hostname)
#   --ssh               include `--ssh` in `tailscale up`
#   --accept-routes     include `--accept-routes` in `tailscale up`
#
# Examples:
#   install_tailscale "$TS_AUTHKEY"
#   install_tailscale "$TS_AUTHKEY" --hostname "$HOSTNAME" --ssh
install_tailscale() {
    local authkey="$1"; shift
    local hostname=""
    local flags=""

    [[ -n "$authkey" ]] || { echo "install_tailscale: AUTHKEY required" >&2; return 2; }

    # curl + ca-certificates are required for the apt-repo bootstrap below.
    # Pi OS Lite bookworm ships both, but make the dependency explicit so a
    # future minified base image doesn't break this silently.
    apt_install curl ca-certificates

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                [[ -n "${2:-}" ]] || { echo "install_tailscale: --hostname needs an argument" >&2; return 2; }
                hostname="$2"; shift 2 ;;
            --ssh)
                flags+="${flags:+ }--ssh"; shift ;;
            --accept-routes)
                flags+="${flags:+ }--accept-routes"; shift ;;
            *)
                echo "install_tailscale: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    # 1) Set up the Tailscale apt repo for this Pi OS codename.
    local codename
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    [[ -n "$codename" ]] || { echo "install_tailscale: cannot determine VERSION_CODENAME from /etc/os-release" >&2; return 3; }

    install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list

    # 2) Install tailscale. apt_install handles the one-time `apt update`.
    apt_install tailscale

    # 3) Render the firstboot service from the template. Auth keys are
    # base64-ish (alphanumeric + hyphens); safe under `sed` with `|` delim.
    local src="$LIB_DIR/tailscale/tailscale-firstboot.service"
    local dst="/etc/systemd/system/tailscale-firstboot.service"
    install -D -m 644 "$src" "$dst"
    sed -i \
        -e "s|@@AUTHKEY@@|${authkey}|g" \
        -e "s|@@HOSTNAME@@|${hostname}|g" \
        -e "s|@@FLAGS@@|${flags}|g" \
        "$dst"

    # 4) Enable. The unit's ExecStartPost disables it after a successful
    # `tailscale up`.
    systemctl enable tailscale-firstboot.service
}
```

**`lib/tailscale/tailscale-firstboot.service`:**

```ini
[Unit]
Description=Tailscale first-boot enrollment (oneshot, self-disables on success)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
ConditionPathExists=!/var/lib/tailscale/firstboot-done

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
ExecStart=/usr/bin/tailscale up --auth-key=@@AUTHKEY@@ --hostname=@@HOSTNAME@@ @@FLAGS@@
ExecStartPost=/bin/sh -c 'install -d /var/lib/tailscale && touch /var/lib/tailscale/firstboot-done && /usr/bin/systemctl disable tailscale-firstboot.service'
Restart=no

[Install]
WantedBy=multi-user.target
```

**Design notes:**

- `ConditionPathExists=!/var/lib/tailscale/firstboot-done` is a belt-and-suspenders second line of defence against re-enrollment. The primary mechanism is `systemctl disable` in `ExecStartPost`; the condition is the recovery path if `disable` somehow failed but the marker file got written. Either way, a successful first boot leaves a marker that prevents re-running the auth-key flow.
- `TimeoutStartSec=300` — if `tailscale up` can't reach the control plane within 5 minutes (network failure, key revoked, etc.), the unit times out and goes inactive. No retry; the operator must re-flash or `systemctl restart tailscale-firstboot.service` manually.
- `--auth-key=@@AUTHKEY@@` rather than `--authkey=…` — both work on current tailscale, `--auth-key` is the documented modern form.
- Empty `--hostname=` (when `TAILSCALE_HOSTNAME` is unset) is a valid Tailscale flag: it falls back to the OS hostname, which `modules/core/module.sh` set earlier via `set_hostname`.
- Empty `@@FLAGS@@` substitution leaves a trailing space in the `ExecStart=` line — harmless to systemd. Not worth shell-trimming.

**Verification:**

```bash
bash -n lib/tailscale.sh
```
Expected: no output, exit 0.

```bash
# systemd-analyze can verify the unit file is syntactically valid
# (won't catch placeholder substitution errors but catches structural ones).
systemd-analyze verify lib/tailscale/tailscale-firstboot.service 2>&1 \
    | grep -v "@@" || true
```
Expected: no errors (warnings about `@@` placeholders are ignorable — they only resolve at install time).

If `systemd-analyze` is not available locally (it isn't on macOS), defer this check to the in-container build verification in Task 3.

**Commit:** `feat(lib/tailscale): install_tailscale + firstboot service template`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create `modules/tailscale/`

**Verifies:** payload-modules.AC5.1, payload-modules.AC5.4.

**Files:**
- Create: `modules/tailscale/schema.sh`
- Create: `modules/tailscale/module.sh`
- Create: `modules/tailscale/README.md` (optional but recommended — security note)

**`modules/tailscale/schema.sh`:**

```bash
# tailscale module — install Tailscale and enroll on first boot via a
# baked-in auth key. The auth key ends up in /etc/systemd/system/ on the
# Pi; do not ship this image to anyone outside your trust boundary. See
# README.md for the threat model.

require TAILSCALE_AUTHKEY

# Resolves host-side at validate time from the .env-sourced HOSTNAME var.
# Matches the design plan's Phase 4 component spec. Using $HOSTNAME (rather
# than empty + tailscale's /etc/hostname fallback) means payloads that
# rewrite /etc/hostname on first boot (e.g. mpv-loop's assign-hostname unit)
# still get the build-time HOSTNAME as their tailnet name, which is the
# intent.
optional TAILSCALE_HOSTNAME default=$HOSTNAME

# Space-separated flag list. Default --ssh enables Tailscale SSH so the
# Pi is reachable from any tailnet device without managing local keys.
optional TAILSCALE_FLAGS default=--ssh
```

**`modules/tailscale/module.sh`:**

```bash
# tailscale module — wrap install_tailscale with env-driven config.

source "$LIB_DIR/tailscale.sh"

# Build the flag list. TAILSCALE_FLAGS is space-separated free-form,
# parsed positionally below. Recognized flags: --ssh, --accept-routes.
_ts_args=()
[[ -n "${TAILSCALE_HOSTNAME:-}" ]] && _ts_args+=(--hostname "$TAILSCALE_HOSTNAME")
# shellcheck disable=SC2206  # word-split is desired here
_extra_flags=( ${TAILSCALE_FLAGS:-} )
for f in "${_extra_flags[@]}"; do
    case "$f" in
        --ssh|--accept-routes) _ts_args+=("$f") ;;
        "" ) : ;;
        *)
            echo "modules/tailscale: unknown TAILSCALE_FLAGS entry '$f'" >&2
            echo "                   supported: --ssh --accept-routes" >&2
            exit 2 ;;
    esac
done

install_tailscale "$TAILSCALE_AUTHKEY" "${_ts_args[@]}"
unset _ts_args _extra_flags
```

**`modules/tailscale/README.md`:**

```markdown
# tailscale module

Bakes a Tailscale auth key into a firstboot systemd unit. On first boot,
the unit runs `tailscale up`, enrolls the Pi on the tailnet, then
disables itself.

## Env vars

| Name | Required | Default | Notes |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | yes | — | tskey-auth-… from the admin console |
| `TAILSCALE_HOSTNAME` | no | (uses `/etc/hostname`) | Override the tailnet hostname |
| `TAILSCALE_FLAGS` | no | `--ssh` | Space-separated. Supported: `--ssh`, `--accept-routes` |

## Threat model

The auth key is stored in `/etc/systemd/system/tailscale-firstboot.service`
on the SD card. Anyone with physical access to the card can extract it.
Use only on cards you trust to stay with the Pi. For images shipped to
strangers, replace `TAILSCALE_AUTHKEY` with a per-device auth flow (out
of scope for this module).

## What it leaves behind

After successful enrollment:

- `tailscaled.service` running (from the deb's postinst).
- `tailscale-firstboot.service` disabled — `/var/lib/tailscale/firstboot-done` marker present.
- `/etc/systemd/system/tailscale-firstboot.service` still on disk (with the auth key) — operators concerned about the key after enrollment can `rm` the file post-first-boot via SSH; the file's existence after enrollment is harmless because the unit is disabled and conditioned.
```

**Verification:**

```bash
bash -n modules/tailscale/schema.sh
bash -n modules/tailscale/module.sh
```
Expected: no output, exit 0.

Host-side schema verification (loader from Phase 1):

```bash
# Missing TAILSCALE_AUTHKEY → host-side abort (payload-modules.AC5.4).
( unset TAILSCALE_AUTHKEY
  bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/tailscale"
  '
) 2>&1 | tee /tmp/v-ac5.4.log

grep -q "TAILSCALE_AUTHKEY" /tmp/v-ac5.4.log || { echo "FAIL AC5.4"; exit 1; }
grep -q "tailscale"         /tmp/v-ac5.4.log || { echo "FAIL AC5.4: module name missing"; exit 1; }
echo "PASS AC5.4"
```

```bash
# All required → success, no error.
TAILSCALE_AUTHKEY=tskey-auth-test bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/tailscale"
'
```
Expected stdout: `export TAILSCALE_HOSTNAME=` and `export TAILSCALE_FLAGS=--ssh`. No stderr.

**Commit:** `feat(modules/tailscale): add tailscale capability module`
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (task 3) -->
<!-- START_TASK_3 -->
### Task 3: End-to-end build with `core + tailscale`

**Verifies:** payload-modules.AC5.1, payload-modules.AC5.3 (the unit's `ExecStartPost` is observable in the image).

**Files:**
- No new files. Use a temp payload as in Phase 2.

**Setup:**

```bash
mkdir -p /tmp/tailscale-test
cat > /tmp/tailscale-test/modules.list <<'EOF'
core
tailscale
EOF
cat > /tmp/tailscale-test/.env <<EOF
HOSTNAME=tailscale-test
TIMEZONE=UTC
PI_USER=pi
ENCRYPTED_PASSWORD='$(openssl passwd -6 'tailscale-test')'
SSH_PUBKEY='$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "ssh-ed25519 AAAA test")'
TAILSCALE_AUTHKEY=tskey-auth-FAKE-DO-NOT-USE-IN-PRODUCTION
EOF
```

(Auth key is bogus — the build succeeds; only first-boot `tailscale up` would fail, which is fine since this test only inspects the *image*, not the running Pi.)

**Build:**

```bash
bin/build-image.sh /tmp/tailscale-test --output-format gz
```

Expected:
- Exit 0.
- `==> modules: core tailscale` in stdout.
- The build pulls and installs the `tailscale` package (visible in apt log inside the chroot).

Capture: `IMG=$(ls -t out/tailscale-test-*.img.gz | head -1)`.

**Inspect:**

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

        echo "=== tailscale binary ==="
        ls -la /mnt/r/usr/bin/tailscale /mnt/r/usr/sbin/tailscaled

        echo "=== firstboot service ==="
        cat /mnt/r/etc/systemd/system/tailscale-firstboot.service

        echo "=== firstboot enabled ==="
        ls -la /mnt/r/etc/systemd/system/multi-user.target.wants/tailscale-firstboot.service

        umount /mnt/r
    '
```

**AC5.1 verified:**
- `/usr/bin/tailscale` and `/usr/sbin/tailscaled` present.
- `/etc/systemd/system/tailscale-firstboot.service` contains a fully-substituted `ExecStart=/usr/bin/tailscale up --auth-key=tskey-auth-FAKE… --hostname=… --ssh`.
- The unit is enabled (symlinked in `multi-user.target.wants/`).

**AC5.3 verified by inspection of the unit file:**
- `ExecStartPost=` contains `systemctl disable tailscale-firstboot.service` and writes the `firstboot-done` marker.
- `ConditionPathExists=!/var/lib/tailscale/firstboot-done` is present (belt-and-suspenders).

If the substitution failed (placeholders still present), fix the `sed` in `lib/tailscale.sh` and rebuild.

**AC5.2 (on-tailnet within ~60s on real hardware):** manual operator verification. Flash to SD, boot the Pi, watch `tailscale status` on a peer device, confirm the Pi appears. Mark as operator-confirmed in test-requirements.

**Commit:** `test(modules/tailscale): end-to-end build inspection — image contains substituted firstboot unit`
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_B -->

---

## Phase Summary

After Phase 4, `tailscale` is a one-line opt-in for any new-contract payload. `lib/tailscale.sh::install_tailscale` is available to legacy `build.sh`-style payloads too (aether's payloads can adopt it without going through the module system). The auth key is baked into a firstboot unit that self-disables; threat model documented in the module's README. AC5.2 (on-tailnet within 60s) is a hardware verification deferred to operator testing.

**Build is green at end of phase:** the temp `/tmp/tailscale-test` payload builds, the resulting image contains tailscale + a correctly-substituted firstboot unit. Existing `examples/hello-payload` (Phase 3) still builds. Legacy `examples/mpv-loop` still builds.
