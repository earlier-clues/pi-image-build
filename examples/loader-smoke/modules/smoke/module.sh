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
