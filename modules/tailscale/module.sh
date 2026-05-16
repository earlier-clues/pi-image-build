# tailscale module — wrap install_tailscale with env-driven config.

source "$LIB_DIR/tailscale.sh"

# Build the flag list. TAILSCALE_FLAGS is space-separated free-form,
# parsed positionally below. Recognized flags: --ssh, --accept-routes.
_ts_args=()
[[ -n "${TAILSCALE_HOSTNAME:-}" ]] && _ts_args+=(--hostname "$TAILSCALE_HOSTNAME")
read -ra _extra_flags <<<"${TAILSCALE_FLAGS:-}"
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
unset _ts_args _extra_flags f
