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
#   --env-file PATH          source env vars from PATH before dispatch (default: <payload>/.env if present)
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
ENV_FILE=""
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
        --env-file)          ENV_FILE="$2"; shift 2 ;;
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

# Resolve payload to absolute path now so contract dispatch (next) and
# subsequent docker mounts both use the same canonical path.
PAYLOAD_DIR="$(cd "$PAYLOAD_DIR" && pwd)"

# Contract dispatch: modules.list (new) > build.sh (legacy) > error.
if [[ -f "$PAYLOAD_DIR/modules.list" ]]; then
    PAYLOAD_CONTRACT="modules"
elif [[ -f "$PAYLOAD_DIR/build.sh" ]]; then
    PAYLOAD_CONTRACT="legacy"
else
    echo "error: $PAYLOAD_DIR has neither modules.list nor build.sh" >&2
    exit 2
fi

case "$OUTPUT_FORMAT" in
    xz|gz) ;;
    *) echo "--output-format must be xz or gz, got '$OUTPUT_FORMAT'" >&2; exit 2 ;;
esac


HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$HERE/lib"
mkdir -p "$CACHE"

# Env-file resolution (new contract only; legacy payloads have always
# expected the caller to set env vars before invoking build-image.sh).
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    if [[ -z "$ENV_FILE" && -f "$PAYLOAD_DIR/.env" ]]; then
        ENV_FILE="$PAYLOAD_DIR/.env"
    fi
    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || { echo "error: --env-file not found: $ENV_FILE" >&2; exit 2; }
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
        ok "env-file: $ENV_FILE"
    fi
fi

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

# New-contract: bind-mount the repo-level modules dir, copy in the runner,
# and tell remaster.sh to invoke it.
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    DOCKER_ARGS+=(
        -v "$MODULES_REPO_DIR":/pibuild/modules:ro
        -v "$RUN_MODULES_SH":/pibuild/run-modules.sh:ro
        -e "BUILD_SCRIPT=/tmp/pibuild/run-modules.sh"
    )
fi

# Canonical customization vars: forward if set in the host env.
for v in HOSTNAME TIMEZONE KEYMAP PI_USER ENCRYPTED_PASSWORD SSH_PUBKEY; do
    [[ -n "${!v:-}" ]] && DOCKER_ARGS+=(-e "$v")
done

# New-contract: forward every schema-resolved var to the chroot
# regardless of --env-regex. The user did not opt these in; the schemas
# declared them as part of the module's contract.
if [[ "$PAYLOAD_CONTRACT" == "modules" && -n "${SCHEMA_DEFAULTS:-}" ]]; then
    # SCHEMA_DEFAULTS is `export NAME=VALUE` lines. Extract NAMEs.
    while IFS= read -r line; do
        [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        DOCKER_ARGS+=(-e "$name")
    done <<< "$SCHEMA_DEFAULTS"
fi

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

# New-contract: parse modules.list, validate schemas host-side, emit a
# synthetic runner. Anything that aborts here aborts BEFORE docker starts.
RUN_MODULES_SH=""
MODULES_REPO_DIR="$HERE/modules"
if [[ "$PAYLOAD_CONTRACT" == "modules" ]]; then
    # shellcheck source=../lib/modules-loader.sh
    source "$HERE/lib/modules-loader.sh"

    say "parsing modules.list"
    mapfile -t MODULE_NAMES < <(parse_modules_list "$PAYLOAD_DIR/modules.list")
    (( ${#MODULE_NAMES[@]} > 0 )) || { echo "error: modules.list is empty after stripping comments" >&2; exit 2; }

    # Resolve each name to its host-side module dir.
    MODULE_HOST_DIRS=()
    MODULE_CHROOT_DIRS=()
    for name in "${MODULE_NAMES[@]}"; do
        host_dir="$(resolve_module "$name" "$PAYLOAD_DIR" "$MODULES_REPO_DIR")"
        MODULE_HOST_DIRS+=("$host_dir")
        # Translate host-side path to chroot-side path:
        # - <PAYLOAD_DIR>/modules/<name>  → /tmp/pibuild/payload/modules/<name>
        # - <MODULES_REPO_DIR>/<name>     → /tmp/pibuild/modules/<name>
        # Use [[ == ]] string-prefix matching rather than a `case` glob:
        # PAYLOAD_DIR could in principle contain glob metachars, and
        # case-glob would match unpredictably. [[ "$host_dir" == "$PAYLOAD_DIR"/* ]]
        # is a literal prefix test.
        if   [[ "$host_dir" == "$PAYLOAD_DIR"/* ]]; then
            MODULE_CHROOT_DIRS+=("/tmp/pibuild/payload/${host_dir#"$PAYLOAD_DIR"/}")
        elif [[ "$host_dir" == "$MODULES_REPO_DIR"/* ]]; then
            MODULE_CHROOT_DIRS+=("/tmp/pibuild/modules/${host_dir#"$MODULES_REPO_DIR"/}")
        else
            echo "internal error: unexpected module path $host_dir" >&2
            exit 4
        fi
    done
    ok "modules: ${MODULE_NAMES[*]}"

    # Validate schemas, collect resolved defaults into SCHEMA_DEFAULTS.
    say "validating schemas"
    SCHEMA_DEFAULTS="$(validate_schemas "${MODULE_HOST_DIRS[@]}")"
    # SCHEMA_DEFAULTS is a series of `export NAME=VALUE` lines. Source
    # them so the values are visible to the docker `-e` forwarding below
    # and so the `--env-regex` loop sees them too.
    if [[ -n "$SCHEMA_DEFAULTS" ]]; then
        # shellcheck disable=SC1091
        eval "$SCHEMA_DEFAULTS"
    fi
    ok "schemas validated"

    # Emit the synthetic runner.
    mkdir -p "$HERE/build-scratch"
    RUN_MODULES_SH="$HERE/build-scratch/run-modules.sh"
    emit_runner "$RUN_MODULES_SH" "${MODULE_CHROOT_DIRS[@]}"
    chmod +x "$RUN_MODULES_SH"
    ok "runner: $RUN_MODULES_SH"
fi

# ----- run -----------------------------------------------------------------

say "remastering ($PAYLOAD_DIR → $OUTPUT)"
docker run "${DOCKER_ARGS[@]}" "$IMAGE_TAG" \
    bash /pipeline/remaster.sh

ok "image built: $OUTPUT"
