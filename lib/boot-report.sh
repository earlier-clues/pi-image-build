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
sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

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
    # service + timer are static. Escape replacement values to prevent
    # sed metacharacters (&, |, \) from being interpreted.
    install -D -m 755 "$src_script" "$dst_script"
    local log_name_esc units_esc journal_units_esc
    log_name_esc=$(sed_escape "$log_name")
    units_esc=$(sed_escape "$units")
    journal_units_esc=$(sed_escape "$journal_units")
    sed -i \
        -e "s|@@LOG_NAME@@|${log_name_esc}|g" \
        -e "s|@@UNITS@@|${units_esc}|g" \
        -e "s|@@JOURNAL_UNITS@@|${journal_units_esc}|g" \
        "$dst_script"

    install -D -m 644 "$src_service" "$dst_service"
    install -D -m 644 "$src_timer"   "$dst_timer"

    systemctl enable pibuild-boot-report.timer
}
