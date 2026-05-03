#!/bin/bash
# Smoke-test payload. Verifies the pipeline can stage + chroot + repack an
# image without doing anything project-specific.
set -euo pipefail

source "$LIB_DIR/hostname.sh"
source "$LIB_DIR/locale.sh"

set_hostname "${HOSTNAME:-hellopi}"
set_timezone "${TIMEZONE:-UTC}"

# Sentinel file CI looks for to confirm the chroot ran end-to-end.
echo "pi-image-build hello-payload OK at $(date -u +%FT%TZ)" > /etc/pibuild-hello
chmod 644 /etc/pibuild-hello
