#!/bin/bash
# MQTT telemetry installer. Run inside the chroot.
LIB_API_VERSION=1

sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Drop the Python daemon, the launcher, and the systemd unit. Substitutes
# role + broker + cert path into the unit's Environment= lines.
#
# Flags:
#   --role NAME    required. Role token for topic prefix (pi/<role>/...).
#   --broker URL   required. 'host' or 'host:port'.
#   --cert PATH    optional. CA cert PEM for TLS broker.
#
# Example:
#   install_mqtt_telemetry --role mpv-loop --broker aether-server:1883
install_mqtt_telemetry() {
    local role=""
    local broker=""
    local cert=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)   role="$2";   shift 2 ;;
            --broker) broker="$2"; shift 2 ;;
            --cert)   cert="$2";   shift 2 ;;
            *) echo "install_mqtt_telemetry: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    [[ -n "$role"   ]] || { echo "install_mqtt_telemetry: --role required" >&2; return 2; }
    [[ -n "$broker" ]] || { echo "install_mqtt_telemetry: --broker required" >&2; return 2; }

    # Pull in paho-mqtt from apt (Debian bookworm ships it).
    apt_install python3-paho-mqtt

    # Daemon + launcher.
    install -D -m 755 "$LIB_DIR/mqtt-telemetry/pibuild-mqtt-telemetry.py" \
        /usr/local/bin/pibuild-mqtt-telemetry
    install -D -m 755 "$LIB_DIR/mqtt-telemetry/pibuild-mqtt-telemetry-launch" \
        /usr/local/bin/pibuild-mqtt-telemetry-launch

    # systemd unit, with substitutions.
    local dst="/etc/systemd/system/pibuild-mqtt-telemetry.service"
    install -D -m 644 "$LIB_DIR/mqtt-telemetry/pibuild-mqtt-telemetry.service" "$dst"
    local role_esc broker_esc cert_esc
    role_esc=$(sed_escape "$role")
    broker_esc=$(sed_escape "$broker")
    cert_esc=$(sed_escape "$cert")
    sed -i \
        -e "s|@@ROLE@@|${role_esc}|g" \
        -e "s|@@BROKER@@|${broker_esc}|g" \
        -e "s|@@CERT@@|${cert_esc}|g" \
        "$dst"

    systemctl enable pibuild-mqtt-telemetry.service
}
