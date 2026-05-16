# mqtt-dashboard module — thin wrapper over lib/mqtt-dashboard.sh.

source "$LIB_DIR/mqtt-dashboard.sh"

echo "--- mqtt-dashboard module ---"
install_mqtt_dashboard \
    --broker "$MQTT_DASHBOARD_BROKER" \
    --topic  "$MQTT_DASHBOARD_TOPIC" \
    --port   "$MQTT_DASHBOARD_PORT"
echo "--- mqtt-dashboard module done ---"
