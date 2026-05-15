# boot-report module — wrap install_boot_report with env-driven config.

source "$LIB_DIR/boot-report.sh"

install_boot_report \
    --log-name      "$BOOT_REPORT_LOG_NAME" \
    --units         "$BOOT_REPORT_UNITS" \
    --journal-units "$BOOT_REPORT_JOURNAL_UNITS"
