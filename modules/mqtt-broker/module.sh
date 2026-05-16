# mqtt-broker module — wrap install_mqtt_broker with env-driven config.

source "$LIB_DIR/mqtt-broker.sh"

_mb_args=( --port "$MQTT_BROKER_PORT" )

# Validate and apply auth mode
case "$MQTT_BROKER_AUTH" in
    anonymous)
        _mb_args+=( --allow-anonymous )
        ;;
    passwd)
        if [[ -z "${MQTT_BROKER_PASSWD_PATH:-}" ]]; then
            echo "modules/mqtt-broker: MQTT_BROKER_AUTH=passwd requires MQTT_BROKER_PASSWD_PATH" >&2
            exit 2
        fi
        _mb_args+=( --passwd-file "$MQTT_BROKER_PASSWD_PATH" )
        ;;
    *)
        echo "modules/mqtt-broker: unknown MQTT_BROKER_AUTH value '$MQTT_BROKER_AUTH'" >&2
        echo "                     supported: anonymous, passwd" >&2
        exit 2
        ;;
esac

install_mqtt_broker "${_mb_args[@]}"
unset _mb_args
