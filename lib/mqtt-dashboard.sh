#!/bin/bash
# MQTT dashboard installer. Run inside the chroot.
LIB_API_VERSION=1

sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Drop the Python daemon, its launcher, and the systemd unit. Substitutes
# broker + topic + port into the unit's Environment= lines.
#
# Flags:
#   --broker URL   required. 'host' or 'host:port' for the broker to subscribe to.
#   --topic GLOB   optional. MQTT subscription glob (default 'pi/#').
#   --port N       optional. HTTP listen port (default 8080).
#
# Example:
#   install_mqtt_dashboard --broker localhost:1883 --topic 'pi/#' --port 8080
install_mqtt_dashboard() {
    local broker=""
    local topic="pi/#"
    local port="8080"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --broker) broker="$2"; shift 2 ;;
            --topic)  topic="$2";  shift 2 ;;
            --port)   port="$2";   shift 2 ;;
            *) echo "install_mqtt_dashboard: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    [[ -n "$broker" ]] || { echo "install_mqtt_dashboard: --broker required" >&2; return 2; }

    apt_install python3-paho-mqtt

    install -D -m 755 "$LIB_DIR/mqtt-dashboard/pibuild-mqtt-dashboard.py" \
        /usr/local/bin/pibuild-mqtt-dashboard
    install -D -m 755 "$LIB_DIR/mqtt-dashboard/pibuild-mqtt-dashboard-launch" \
        /usr/local/bin/pibuild-mqtt-dashboard-launch

    local dst="/etc/systemd/system/pibuild-mqtt-dashboard.service"
    install -D -m 644 "$LIB_DIR/mqtt-dashboard/pibuild-mqtt-dashboard.service" "$dst"
    local broker_esc topic_esc port_esc
    broker_esc=$(sed_escape "$broker")
    topic_esc=$(sed_escape "$topic")
    port_esc=$(sed_escape "$port")
    sed -i \
        -e "s|@@BROKER@@|${broker_esc}|g" \
        -e "s|@@TOPIC@@|${topic_esc}|g" \
        -e "s|@@PORT@@|${port_esc}|g" \
        "$dst"

    systemctl enable pibuild-mqtt-dashboard.service
}
