# mqtt-telemetry module — wrap install_mqtt_telemetry with env-driven
# config.

source "$LIB_DIR/mqtt-telemetry.sh"

_mt_args=( --role "$MQTT_ROLE" --broker "$MQTT_BROKER" )
[[ -n "${MQTT_CERT_PATH:-}" ]] && _mt_args+=( --cert "$MQTT_CERT_PATH" )

install_mqtt_telemetry "${_mt_args[@]}"
unset _mt_args
