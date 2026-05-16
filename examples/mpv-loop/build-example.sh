#!/usr/bin/env bash
# Convenience wrapper for the mpv-loop example. Loads a .env, derives
# ENCRYPTED_PASSWORD + SSH_PUBKEY from it, resolves the video to bake in,
# and exec's bin/build-image.sh with the right flags.
#
# Usage:
#   build-example.sh [-c PATH] [--video PATH] [extra args for build-image.sh]
#
# -c / --config PATH   .env to source. Default: ./.env, then
#                      examples/mpv-loop/.env.
# --video PATH         file or directory to bake in. Default: $VIDEO from
#                      the .env. If a file, it's staged into a tempdir and
#                      that dir is mounted.
#
# Extra args (e.g. --output, --output-format, --extra-mb) pass through
# verbatim to bin/build-image.sh.
#
# .env keys:
#   required:  PI_PASSWORD  SSH_PUBKEY_FILE
#   one of:    VIDEO (path)        — or pass --video on the CLI
#   optional:  HOSTNAME  TIMEZONE  KEYMAP  PI_USER  MPV_AUDIO_OUT
#              AP_SSID  AP_PSK  AP_COUNTRY  OUTPUT_FORMAT (xz|gz, default xz)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PIBUILD="$(cd "$HERE/../.." && pwd)"
PAYLOAD_DIR="$HERE"

CONFIG_FILE=""
VIDEO=""
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ -n "${2:-}" ]] || { echo "error: --config requires a path" >&2; exit 2; }
            if [[ "$2" = /* ]]; then CONFIG_FILE="$2"; else CONFIG_FILE="$PWD/$2"; fi
            shift 2 ;;
        --video)
            [[ -n "${2:-}" ]] || { echo "error: --video requires a path" >&2; exit 2; }
            VIDEO="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            PASSTHROUGH+=("$1"); shift ;;
    esac
done

# ----- locate + load .env ------------------------------------------------

if [[ -z "$CONFIG_FILE" ]]; then
    if   [[ -f "$PWD/.env" ]];          then CONFIG_FILE="$PWD/.env"
    elif [[ -f "$PAYLOAD_DIR/.env" ]];  then CONFIG_FILE="$PAYLOAD_DIR/.env"
    else
        echo "error: no .env found (looked at ./.env and $PAYLOAD_DIR/.env)" >&2
        echo "       pass -c PATH, or create one — see $PAYLOAD_DIR/.env.example" >&2
        exit 2
    fi
fi
[[ -f "$CONFIG_FILE" ]] || { echo "error: config not found: $CONFIG_FILE" >&2; exit 2; }
echo "==> loading config: $CONFIG_FILE"
_video_cli="$VIDEO"
set -a; source "$CONFIG_FILE"; set +a
# CLI --video wins over .env's VIDEO=.
[[ -n "$_video_cli" ]] && VIDEO="$_video_cli"
unset _video_cli

# ----- required + computed env vars --------------------------------------

: "${PI_PASSWORD:?PI_PASSWORD required in $CONFIG_FILE}"
: "${SSH_PUBKEY_FILE:?SSH_PUBKEY_FILE required in $CONFIG_FILE}"

# Resolve relative SSH_PUBKEY_FILE against the .env's directory.
if [[ "$SSH_PUBKEY_FILE" != /* ]]; then
    SSH_PUBKEY_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$SSH_PUBKEY_FILE"
fi
[[ -f "$SSH_PUBKEY_FILE" ]] || { echo "error: ssh pubkey not found: $SSH_PUBKEY_FILE" >&2; exit 2; }

export ENCRYPTED_PASSWORD="$(openssl passwd -6 "$PI_PASSWORD")"
export SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"

# ----- resolve video → mount directory -----------------------------------

[[ -n "$VIDEO" ]] || { echo "error: no video given (--video PATH or VIDEO= in .env)" >&2; exit 2; }

# Resolve relative VIDEO against the .env's directory, like SSH_PUBKEY_FILE.
if [[ "$VIDEO" != /* ]]; then
    VIDEO="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$VIDEO"
fi
[[ -e "$VIDEO" ]] || { echo "error: video not found: $VIDEO" >&2; exit 2; }

# build-image.sh's --mount only takes directories. If --video is a file,
# stage it in a tempdir and mount that. Earlier this used `ln -s` for
# speed, but Docker bind-mounts treat symlinks as opaque — the link's
# target is a host path that doesn't exist inside the container, so the
# chroot bake shipped a dangling symlink to the pi and mpv crash-looped
# trying to open it. Real copy now; ~1s for a 100MB clip.
CLEANUP_TMP=""
if [[ -d "$VIDEO" ]]; then
    VIDEO_MOUNT="$VIDEO"
else
    CLEANUP_TMP="$(mktemp -d -t mpv-loop-stage.XXXXXX)"
    cp "$VIDEO" "$CLEANUP_TMP/$(basename "$VIDEO")"
    VIDEO_MOUNT="$CLEANUP_TMP"
fi
trap '[[ -n "$CLEANUP_TMP" ]] && rm -rf "$CLEANUP_TMP"' EXIT

echo "==> video mount: $VIDEO_MOUNT (from $VIDEO)"

# ----- forward optional canonical envs -----------------------------------

export TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
export KEYMAP="${KEYMAP:-us}"
export PI_USER="${PI_USER:-pi}"
[[ -n "${HOSTNAME:-}" ]] && export HOSTNAME

# Default gz, not xz: the image is mostly an already-compressed mp4 so
# xz's better ratio buys nothing, and pigz (parallel gzip, used by
# pipeline/remaster.sh) is much faster than xz on big payloads.
OUTPUT_FORMAT="${OUTPUT_FORMAT:-gz}"

# ----- exec the builder --------------------------------------------------

# build-image.sh's default OUTPUT is $PWD/out/<payload>-<utc>.img.<fmt>.
# cd to the pi-image-build root so artifacts land in pi-image-build/out/
# (where flash-image.sh's name resolver looks), not in whatever dir the
# user happened to run this wrapper from.
cd "$PIBUILD"

# New-contract: build-image.sh auto-sources <payload>/.env, so AP_*/MPV_*
# come in via the env-file path. We still forward the wrapper-derived
# ENCRYPTED_PASSWORD and SSH_PUBKEY (computed above), plus the canonical
# customization vars, via the bin/build-image.sh built-in forwarding.
exec "$PIBUILD/bin/build-image.sh" \
    "$PAYLOAD_DIR" \
    --output-format "$OUTPUT_FORMAT" \
    --mount "video=$VIDEO_MOUNT" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
