# payload-modules Implementation Plan — Phase 5: `boot-report` capability module

**Goal:** Generalize the offline-diagnostic dump that `examples/mpv-loop/files/mpv-loop-boot-report` provides today into `lib/boot-report.sh` + `modules/boot-report/`. Any new-contract payload can drop the module into `modules.list` and gain a `/boot/firmware/<log-name>` snapshot at T+90s and T+180s after every boot.

**Architecture:** `lib/boot-report.sh::install_boot_report --log-name foo.log --units "a.service b.service" --journal-units "a.service"` installs a report script (from a template at `lib/boot-report/pibuild-boot-report.sh.template`), a `.service`, and a `.timer` into the rootfs. The report script writes a snapshot to `/boot/firmware/<log-name>` (FAT-readable from any OS — pull the SD, plug into a Mac, read), then sleeps 90s and writes again, so a single oneshot fires at T+90s and produces dumps at both T+90s and T+180s. The unit list (services to `is-active`) and journal-unit list (units whose journals to tail) are parametrized. The generic sections (radio info, scan, NM profiles, rfkill state, NM drop-ins, boot errors) are always present.

**Tech Stack:** Bash, systemd `.service` + `.timer`. No new build-time dependencies.

**Scope:** Phase 5 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — `examples/mpv-loop/files/mpv-loop-boot-report` (118 lines) is the existing instance to generalize from. Its hardcoded specifics: log path `/boot/firmware/mpv-loop-boot.log`, unit list at lines 30–37, journal units at lines 95–98. mpv-specific bits (video files dump at lines 80–82, mpv config dump at lines 84–87) are NOT carried into the generic lib — payloads that want those keep them in payload-local modules. `lib/wifi/regdom.service` + `enable_wifi_regdom` is the canonical template-and-sed precedent.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC6: `boot-report` module
- **payload-modules.AC6.1 Success:** A payload with `modules.list = core + boot-report` builds an image with the report script + service + timer installed.
- **payload-modules.AC6.2 Success:** On real hardware, pulling the SD card after first boot reveals `/boot/firmware/<BOOT_REPORT_LOG_NAME>` containing the documented sections (radio info, scan, NM profiles, rfkill state, drop-ins, boot errors) at both T+90s and T+180s (manual hardware verification).
- **payload-modules.AC6.3 Edge:** Default `BOOT_REPORT_LOG_NAME` is `boot.log`; default `BOOT_REPORT_UNITS` and `BOOT_REPORT_JOURNAL_UNITS` are empty (report still runs, just doesn't list per-unit status).

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Create `lib/boot-report.sh` + the template assets

**Verifies:** payload-modules.AC6.1, payload-modules.AC6.3 (default-values behavior in the generic case).

**Files:**
- Create: `lib/boot-report.sh`
- Create: `lib/boot-report/pibuild-boot-report.sh.template`
- Create: `lib/boot-report/pibuild-boot-report.service`
- Create: `lib/boot-report/pibuild-boot-report.timer`

**`lib/boot-report.sh`:**

```bash
#!/bin/bash
# Offline diagnostic snapshot dropped to /boot/firmware/<log-name> at
# T+90s and T+180s after every boot. Run inside the chroot.
LIB_API_VERSION=1

# Install the boot-report script + systemd service + timer.
#
# Flags (all optional):
#   --log-name NAME           filename under /boot/firmware/
#                             (default: boot.log)
#   --units "u1.svc u2.svc"   space-separated unit names to `is-active`
#                             (default: empty → no per-unit section)
#   --journal-units "u1.svc"  space-separated unit names whose journals
#                             to tail (default: empty)
#
# Example:
#   install_boot_report \
#       --log-name mpv-loop-boot.log \
#       --units "mpv-loop.service mpv-loop-assign-hostname.service" \
#       --journal-units "mpv-loop.service"
install_boot_report() {
    local log_name="boot.log"
    local units=""
    local journal_units=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-name)
                [[ -n "${2:-}" ]] || { echo "install_boot_report: --log-name needs an argument" >&2; return 2; }
                log_name="$2"; shift 2 ;;
            --units)
                units="${2:-}"; shift 2 ;;
            --journal-units)
                journal_units="${2:-}"; shift 2 ;;
            *)
                echo "install_boot_report: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    local src_script="$LIB_DIR/boot-report/pibuild-boot-report.sh.template"
    local dst_script="/usr/local/bin/pibuild-boot-report"
    local src_service="$LIB_DIR/boot-report/pibuild-boot-report.service"
    local dst_service="/etc/systemd/system/pibuild-boot-report.service"
    local src_timer="$LIB_DIR/boot-report/pibuild-boot-report.timer"
    local dst_timer="/etc/systemd/system/pibuild-boot-report.timer"

    # The script is rendered from the template via sed substitution. The
    # service + timer are static.
    install -D -m 755 "$src_script" "$dst_script"
    sed -i \
        -e "s|@@LOG_NAME@@|${log_name}|g" \
        -e "s|@@UNITS@@|${units}|g" \
        -e "s|@@JOURNAL_UNITS@@|${journal_units}|g" \
        "$dst_script"

    install -D -m 644 "$src_service" "$dst_service"
    install -D -m 644 "$src_timer"   "$dst_timer"

    systemctl enable pibuild-boot-report.timer
}
```

**`lib/boot-report/pibuild-boot-report.sh.template`:**

```bash
#!/bin/bash
# Dump a diagnostic snapshot to /boot/firmware/@@LOG_NAME@@ at T+90s and
# again at T+180s on every boot. /boot/firmware is the FAT partition, so
# the log is readable from any OS — pull the SD, plug into your Mac, open
# the file. Designed for the case where the Pi never came up on the
# network and there's nowhere else to look.
#
# Configured at image-build time by lib/boot-report.sh::install_boot_report:
#   @@LOG_NAME@@       — filename under /boot/firmware/
#   @@UNITS@@          — space-separated unit names to `is-active`
#   @@JOURNAL_UNITS@@  — space-separated unit names to journalctl-tail
set +e  # always finish writing the report

LOG=/boot/firmware/@@LOG_NAME@@
[ -w /boot/firmware ] || exit 0

UNITS="@@UNITS@@"
JOURNAL_UNITS="@@JOURNAL_UNITS@@"

unit_installed() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .
}

write_report() {
    {
        echo
        echo "======================================================================"
        echo "boot report: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "uptime:      $(cut -d' ' -f1 /proc/uptime)s"
        echo "hostname:    $(hostname)"
        echo "kernel:      $(uname -r)"
        echo "build:       $(grep PRETTY_NAME /etc/os-release)"
        echo "======================================================================"

        if [ -n "$UNITS" ]; then
            echo
            echo "--- service states ---"
            for u in $UNITS; do
                unit_installed "$u" || continue
                printf "  %-36s %s\n" "$u" "$(systemctl is-active "$u")"
            done
        fi

        echo
        echo "--- wifi radio ---"
        /usr/sbin/rfkill list 2>&1
        echo
        /usr/sbin/iw reg get 2>&1 | head -5
        echo
        /usr/sbin/iw dev wlan0 info 2>&1

        echo
        echo "--- wlan0 addresses ---"
        ip addr show wlan0 2>&1

        echo
        echo "--- visible SSIDs (scan) ---"
        # Bring wlan0 up first because NM may have left it down if association failed.
        ip link set wlan0 up 2>/dev/null
        /usr/sbin/iw dev wlan0 scan 2>&1 | awk '
            /^BSS/    { bssid=$2 }
            /signal:/ { sig=$2 }
            /freq:/   { freq=$2 }
            /SSID:/   { ssid=substr($0, index($0,$2));
                        printf "  %-32s  %s dBm  %s MHz  %s\n", ssid, sig, freq, bssid }
        ' | sort -k2 -n -r | head -20

        echo
        echo "--- NetworkManager ---"
        if command -v nmcli >/dev/null 2>&1; then
            nmcli -t device status 2>&1
            echo
            nmcli -t connection show 2>&1
            echo
            echo "  installed connection profiles:"
            ls -la /etc/NetworkManager/system-connections/ 2>&1 | sed 's/^/    /'
        else
            echo "(nmcli not installed)"
        fi

        echo
        echo "--- systemd-rfkill state (should be masked by core) ---"
        systemctl is-enabled systemd-rfkill.service systemd-rfkill.socket 2>&1

        echo
        echo "--- NM drop-ins ---"
        find /etc/systemd/system/NetworkManager.service.d/ -type f 2>/dev/null \
            | while read -r f; do echo "  >>> $f"; sed 's/^/    /' "$f"; done

        if [ -n "$JOURNAL_UNITS" ]; then
            echo
            echo "--- service journals (last 40 each) ---"
            for u in $JOURNAL_UNITS; do
                unit_installed "$u" || continue
                echo
                echo "  >>> $u"
                journalctl -u "$u" -b --no-pager -n 40 2>&1 | sed 's/^/    /'
            done
        fi

        echo
        echo "--- boot-time errors ---"
        journalctl -b -p err --no-pager 2>&1 | tail -30

        echo
        echo "--- end of report ---"
        echo
    } >> "$LOG" 2>&1
    sync
}

# Fire at T+90s (when the timer kicks us off), again ~T+180s.
write_report
sleep 90
write_report
```

**`lib/boot-report/pibuild-boot-report.service`:**

```ini
[Unit]
Description=pi-image-build boot diagnostics — dump radio/NM/journal state to /boot/firmware

[Service]
Type=oneshot
TimeoutStartSec=600
ExecStart=/usr/local/bin/pibuild-boot-report
```

**`lib/boot-report/pibuild-boot-report.timer`:**

```ini
[Unit]
Description=Fire pibuild-boot-report at T+90s after boot

[Timer]
OnBootSec=90s
AccuracySec=5s
Unit=pibuild-boot-report.service

[Install]
WantedBy=timers.target
```

**Design notes:**

- The script does both T+90s and T+180s reports in a single service invocation. Cleaner than two timer units; the service holds for ~90s but that's fine (oneshot, no dependencies pinned to it).
- `TimeoutStartSec=600` gives the script room to write two reports (~10–30s each in practice) plus the 90s sleep with headroom.
- `set +e` at the top of the script intentionally disables fail-fast — a partial report is better than no report. The whole point is "the Pi is broken; what do we know."
- The `--units` / `--journal-units` flags accept space-separated names. When empty, the relevant section is omitted (per AC6.3). Validate this in Task 3.
- Existing `mpv-loop-boot-report.timer` (in `examples/mpv-loop/files/`) and `mpv-loop-boot-report.service` are kept untouched in this phase — Phase 7 migrates mpv-loop to use the generic boot-report and removes the old files.

**Verification:**

```bash
bash -n lib/boot-report.sh
bash -n lib/boot-report/pibuild-boot-report.sh.template
```
Expected: no output, exit 0. (`bash -n` parses placeholders fine because they're inside double-quoted strings and assignments — Bash doesn't fail on unresolved `@@TOKEN@@` literals at parse time.)

**Commit:** `feat(lib/boot-report): generic boot-report installer + script + units`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create `modules/boot-report/`

**Verifies:** payload-modules.AC6.1, payload-modules.AC6.3.

**Files:**
- Create: `modules/boot-report/schema.sh`
- Create: `modules/boot-report/module.sh`

**`modules/boot-report/schema.sh`:**

```bash
# boot-report module — drop a diagnostic snapshot to /boot/firmware on
# every boot. Pull the SD, read on any OS.

optional BOOT_REPORT_LOG_NAME default=boot.log
optional BOOT_REPORT_UNITS default=
optional BOOT_REPORT_JOURNAL_UNITS default=
```

**`modules/boot-report/module.sh`:**

```bash
# boot-report module — wrap install_boot_report with env-driven config.

source "$LIB_DIR/boot-report.sh"

install_boot_report \
    --log-name      "$BOOT_REPORT_LOG_NAME" \
    --units         "$BOOT_REPORT_UNITS" \
    --journal-units "$BOOT_REPORT_JOURNAL_UNITS"
```

**Verification:**

```bash
bash -n modules/boot-report/schema.sh
bash -n modules/boot-report/module.sh
```

Host-side schema verification (all defaults):

```bash
bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/boot-report"
'
```
Expected stdout:
```
export BOOT_REPORT_LOG_NAME=boot.log
export BOOT_REPORT_UNITS=
export BOOT_REPORT_JOURNAL_UNITS=
```

**Commit:** `feat(modules/boot-report): add boot-report capability module`
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (task 3) -->
<!-- START_TASK_3 -->
### Task 3: End-to-end build with `core + boot-report`

**Verifies:** payload-modules.AC6.1, payload-modules.AC6.3 (empty defaults still produce a valid script).

**Files:**
- No new files. Temp payload.

**Setup:**

```bash
mkdir -p /tmp/boot-report-test
cat > /tmp/boot-report-test/modules.list <<'EOF'
core
boot-report
EOF
cat > /tmp/boot-report-test/.env <<EOF
HOSTNAME=br-test
TIMEZONE=UTC
PI_USER=pi
ENCRYPTED_PASSWORD='$(openssl passwd -6 'br-test')'
SSH_PUBKEY='$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "ssh-ed25519 AAAA test")'
# Leave BOOT_REPORT_* unset to exercise AC6.3 (defaults).
EOF
```

**Build:**

```bash
bin/build-image.sh /tmp/boot-report-test --output-format gz
```

Expected: exit 0, `==> modules: core boot-report` in stdout.

Capture: `IMG=$(ls -t out/boot-report-test-*.img.gz | head -1)`.

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

        echo "=== boot-report script ==="
        ls -la /mnt/r/usr/local/bin/pibuild-boot-report
        head -10 /mnt/r/usr/local/bin/pibuild-boot-report
        echo
        echo "    LOG name resolved?"
        grep "^LOG=" /mnt/r/usr/local/bin/pibuild-boot-report
        echo "    UNITS resolved (should be empty between quotes)?"
        grep "^UNITS=" /mnt/r/usr/local/bin/pibuild-boot-report
        echo "    JOURNAL_UNITS resolved?"
        grep "^JOURNAL_UNITS=" /mnt/r/usr/local/bin/pibuild-boot-report

        echo
        echo "=== service ==="
        cat /mnt/r/etc/systemd/system/pibuild-boot-report.service

        echo
        echo "=== timer ==="
        cat /mnt/r/etc/systemd/system/pibuild-boot-report.timer

        echo
        echo "=== timer enabled ==="
        ls -la /mnt/r/etc/systemd/system/timers.target.wants/pibuild-boot-report.timer

        umount /mnt/r
    '
```

**AC6.1 verified:**
- `/usr/local/bin/pibuild-boot-report` exists, mode 755.
- `/etc/systemd/system/pibuild-boot-report.service` exists.
- `/etc/systemd/system/pibuild-boot-report.timer` exists.
- Timer enabled.

**AC6.3 verified:**
- `LOG=/boot/firmware/boot.log` (the documented default).
- `UNITS=""` (empty string, the documented default).
- `JOURNAL_UNITS=""` (empty string, the documented default).
- No `@@…@@` placeholders survive in the rendered script.

If a placeholder still shows up (substitution missed it), fix the `sed` in `lib/boot-report.sh` and rebuild.

**AC6.2 (real hardware, T+90s and T+180s reports):** manual operator verification. Flash, boot, wait 4 minutes, power off, pull SD, read `/boot/firmware/boot.log` on a Mac/Linux host. Confirm two report blocks (each starting with `boot report:` and a different timestamp) are present. Mark as operator-confirmed.

**Commit:** `test(modules/boot-report): end-to-end build inspection — image contains rendered script + units`
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_B -->

---

## Phase Summary

After Phase 5, `boot-report` is a one-line opt-in. A payload that just wants the generic radio/NM/rfkill/boot-errors snapshot picks it up for free. Payloads that want per-service `is-active` lines or per-service journal tails (mpv-loop) pass them via env vars at build time. `lib/boot-report.sh::install_boot_report` is also available to legacy `build.sh` payloads. The pre-existing `examples/mpv-loop/files/mpv-loop-boot-report*` files are NOT touched in this phase — they go away in Phase 7 when mpv-loop migrates.

**Build is green at end of phase:** the temp `/tmp/boot-report-test` payload builds with all-default env, produces a rendered script with no unresolved placeholders. Phase 3 hello-payload and legacy mpv-loop still build.
