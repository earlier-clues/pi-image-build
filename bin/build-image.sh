#!/usr/bin/env bash
# Build a customized Pi OS image from a payload directory.
#
# Usage:
#   build-image.sh <payload-dir> [options]
#
# The payload directory must contain a build.sh that runs inside the chroot.
# The build.sh has $LIB_DIR, $PAYLOAD_DIR, $MOUNTS_DIR plus any forwarded
# env vars in scope.
#
# Options:
#   -o, --output PATH        output image path (default: ./out/<payload>-<utc>.img.<ext>)
#   --output-format xz|gz    compression for the output (default: xz)
#   --base URL_OR_PATH       base image source (default: raspios-lite-arm64 latest URL)
#   --base-sha256 HEX        skip URL fetch + sha256 file; trust this hash on cached file
#   --extra-mb N             extra MB to grow the root partition (default: 1536)
#   --mount LABEL=PATH       extra dir to mount into the chroot at $MOUNTS_DIR/<label> (repeatable)
#   --env-regex REGEX        forward host env vars matching REGEX into the chroot (repeatable)
#   --cache DIR              base-image cache (default: $HOME/.cache/pi-image-build)
#
# Canonical customization env vars forwarded automatically when set:
#   HOSTNAME TIMEZONE KEYMAP PI_USER ENCRYPTED_PASSWORD SSH_PUBKEY
#
# Platform: macOS (Docker Desktop) or Linux with `docker` available. On
# Linux, you may need to register binfmt-misc for arm64 once before the
# first build (see remaster.sh notes).

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" && -z "${PIBUILD_FORCE_NON_DARWIN:-}" ]]; then
    cat >&2 <<EOF
$(basename "$0"): macOS-only as exercised. There's history of a binfmt-misc
registration in the container nuking the Mac Docker build environment when
ported to Linux — Linux support needs real work, not a flag. Set
PIBUILD_FORCE_NON_DARWIN=1 to bypass and debug it yourself.
EOF
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not installed" >&2
    exit 2
fi

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

# ----- arg parse -----------------------------------------------------------

PAYLOAD_DIR=""
OUTPUT=""
OUTPUT_FORMAT="xz"
BASE="${PIBUILD_BASE:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
BASE_SHA256=""
EXTRA_MB="${PIBUILD_EXTRA_MB:-1536}"
CACHE="${PIBUILD_CACHE:-$HOME/.cache/pi-image-build}"
MOUNTS=()
ENV_REGEXES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)         OUTPUT="$2"; shift 2 ;;
        --output-format)     OUTPUT_FORMAT="$2"; shift 2 ;;
        --base)              BASE="$2"; shift 2 ;;
        --base-sha256)       BASE_SHA256="$2"; shift 2 ;;
        --extra-mb)          EXTRA_MB="$2"; shift 2 ;;
        --mount)             MOUNTS+=("$2"); shift 2 ;;
        --env-regex)         ENV_REGEXES+=("$2"); shift 2 ;;
        --cache)             CACHE="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -z "$PAYLOAD_DIR" ]]; then PAYLOAD_DIR="$1"
            else echo "unexpected arg: $1" >&2; usage >&2; exit 2
            fi
            shift ;;
    esac
done

[[ -n "$PAYLOAD_DIR" ]] || { echo "error: payload directory required" >&2; usage >&2; exit 2; }
[[ -d "$PAYLOAD_DIR" ]] || { echo "error: payload dir not found: $PAYLOAD_DIR" >&2; exit 2; }
[[ -f "$PAYLOAD_DIR/build.sh" ]] || { echo "error: $PAYLOAD_DIR has no build.sh" >&2; exit 2; }

case "$OUTPUT_FORMAT" in
    xz|gz) ;;
    *) echo "--output-format must be xz or gz, got '$OUTPUT_FORMAT'" >&2; exit 2 ;;
esac

# Resolve to absolute paths for docker volume mounts.
PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$HERE/lib"
mkdir -p "$CACHE"

say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
sha256() { command -v sha256sum >/dev/null && sha256sum "$@" || shasum -a 256 "$@"; }

# ----- base image: fetch + verify -----------------------------------------

if [[ "$BASE" =~ ^https?:// ]]; then
    BASE_FILE="$CACHE/$(basename "$BASE").img.xz"
    if [[ -z "$BASE_SHA256" ]]; then
        say "fetching base image checksum"
        curl -fL -o "$CACHE/base.sha256" "${BASE}.sha256"
        BASE_SHA256="$(awk '{print $1}' "$CACHE/base.sha256")"
        [[ "$BASE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "bad sha256 file" >&2; exit 3; }
    fi
    need=1
    if [[ -f "$BASE_FILE" ]]; then
        got="$(sha256 "$BASE_FILE" | awk '{print $1}')"
        [[ "$got" == "$BASE_SHA256" ]] && need=0
    fi
    if (( need )); then
        say "downloading base image"
        curl -fL -o "$BASE_FILE" "$BASE"
        got="$(sha256 "$BASE_FILE" | awk '{print $1}')"
        [[ "$got" == "$BASE_SHA256" ]] || { echo "sha256 mismatch on download" >&2; exit 3; }
    fi
    ok "base: $BASE_FILE (sha256 verified)"
else
    [[ -f "$BASE" ]] || { echo "base image not found: $BASE" >&2; exit 2; }
    BASE_FILE="$(cd "$(dirname "$BASE")" && pwd)/$(basename "$BASE")"
    ok "base: $BASE_FILE (local file)"
fi

# ----- output path ---------------------------------------------------------

if [[ -z "$OUTPUT" ]]; then
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    PAYLOAD_NAME="$(basename "$PAYLOAD_DIR")"
    OUTPUT="$PWD/out/${PAYLOAD_NAME}-${STAMP}.img.${OUTPUT_FORMAT}"
fi
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

# ----- build the remaster container ---------------------------------------

IMAGE_TAG="pi-image-build:latest"
say "building remaster container"
docker build -t "$IMAGE_TAG" "$HERE/pipeline" > /tmp/pibuild-docker-build.log 2>&1 || {
    cat /tmp/pibuild-docker-build.log; exit 4;
}
ok "container: $IMAGE_TAG"

# ----- assemble docker args -----------------------------------------------

# Preserve the base file's compression extension in the container path,
# since pipeline/remaster.sh dispatches on it.
case "$BASE_FILE" in
    *.img.xz) IN_NAME="base.img.xz" ;;
    *.img.gz) IN_NAME="base.img.gz" ;;
    *.xz)     IN_NAME="base.img.xz" ;;
    *.gz)     IN_NAME="base.img.gz" ;;
    *.img|*)  IN_NAME="base.img"    ;;
esac

DOCKER_ARGS=(
    --rm --privileged
    -v "$BASE_FILE":/in/"$IN_NAME":ro
    -v "$(dirname "$OUTPUT")":/out
    -v "$HERE/pipeline":/pipeline:ro
    -v "$LIB_DIR":/pibuild/lib:ro
    -v "$PAYLOAD_DIR":/pibuild/payload:ro
    -e "IN_IMG=/in/$IN_NAME"
    -e "OUT_IMG=/out/$(basename "$OUTPUT")"
    -e "OUT_FORMAT=$OUTPUT_FORMAT"
    -e "EXTRA_MB=$EXTRA_MB"
    -e "PAYLOAD_HOST=$PAYLOAD_DIR"
    -e "LIB_HOST=$LIB_DIR"
)

# Extra mounts: --mount LABEL=PATH → /mounts/<label> in container.
if (( ${#MOUNTS[@]} )); then
    MOUNT_LABELS=()
    for m in "${MOUNTS[@]}"; do
        label="${m%%=*}"
        path="${m#*=}"
        [[ "$label" != "$m" ]] || { echo "bad --mount '$m' (need LABEL=PATH)" >&2; exit 2; }
        [[ -d "$path" ]] || { echo "--mount path not found: $path" >&2; exit 2; }
        path="$(cd "$path" && pwd)"
        DOCKER_ARGS+=(-v "$path":/pibuild/mounts/"$label":ro)
        MOUNT_LABELS+=("$label")
    done
    DOCKER_ARGS+=(-e "MOUNT_LABELS=${MOUNT_LABELS[*]}")
fi

# Canonical customization vars: forward if set in the host env.
for v in HOSTNAME TIMEZONE KEYMAP PI_USER ENCRYPTED_PASSWORD SSH_PUBKEY; do
    [[ -n "${!v:-}" ]] && DOCKER_ARGS+=(-e "$v")
done

# --env-regex: collect matching host env vars into PASSTHROUGH (newline-
# separated NAME=VALUE), then forward as a single env var. This avoids the
# `env -i` inside the chroot from dropping them.
if (( ${#ENV_REGEXES[@]} )); then
    PASSTHROUGH=""
    while IFS='=' read -r name value; do
        [[ -z "$name" ]] && continue
        for re in "${ENV_REGEXES[@]}"; do
            if [[ "$name" =~ $re ]]; then
                PASSTHROUGH+="$name=$value"$'\n'
                break
            fi
        done
    done < <(env)
    DOCKER_ARGS+=(-e "PASSTHROUGH=$PASSTHROUGH")
fi

# ----- run -----------------------------------------------------------------

say "remastering ($PAYLOAD_DIR → $OUTPUT)"
docker run "${DOCKER_ARGS[@]}" "$IMAGE_TAG" \
    bash /pipeline/remaster.sh

ok "image built: $OUTPUT"
