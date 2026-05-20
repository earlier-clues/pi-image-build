#!/bin/bash
# MQTT broker installer (Mosquitto). Run inside the chroot.
LIB_API_VERSION=1

sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Install and configure Mosquitto MQTT broker as a systemd service.
# TLS is not currently supported; planned future enhancement.
#
# Flags (all optional):
#   --port PORT              listener port (default: 1883)
#   --allow-anonymous        accept anonymous connections (default)
#   --passwd-file PATH       path to password file for auth
#
# Only one of --allow-anonymous or --passwd-file may be specified.
#
# Examples:
#   install_mqtt_broker
#   install_mqtt_broker --port 8883
#   install_mqtt_broker --port 1883 --passwd-file /etc/mosquitto/passwd
install_mqtt_broker() {
    local port="1883"
    local auth_mode="anonymous"
    local passwd_file=""
    local ws_port=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                [[ -n "${2:-}" ]] || { echo "install_mqtt_broker: --port needs an argument" >&2; return 2; }
                port="$2"; shift 2 ;;
            --allow-anonymous)
                auth_mode="anonymous"; shift ;;
            --passwd-file)
                [[ -n "${2:-}" ]] || { echo "install_mqtt_broker: --passwd-file needs an argument" >&2; return 2; }
                auth_mode="passwd"
                passwd_file="$2"; shift 2 ;;
            --ws-port)
                [[ -n "${2:-}" ]] || { echo "install_mqtt_broker: --ws-port needs an argument" >&2; return 2; }
                ws_port="$2"; shift 2 ;;
            *)
                echo "install_mqtt_broker: unknown flag '$1'" >&2; return 2 ;;
        esac
    done

    # Validate auth mode
    if [[ "$auth_mode" == "passwd" && -z "$passwd_file" ]]; then
        echo "install_mqtt_broker: --passwd-file required when using password auth" >&2
        return 2
    fi

    # Install mosquitto from apt
    apt_install mosquitto mosquitto-clients

    # Render mosquitto config from template via sed substitution.
    # Build the auth block based on configuration.
    local auth_block="allow_anonymous true"
    if [[ "$auth_mode" == "passwd" ]]; then
        auth_block="password_file /etc/mosquitto/passwd"
    fi

    # Install the config template and apply substitutions
    local src="$LIB_DIR/mqtt-broker/mosquitto-pibuild.conf.template"
    local dst="/etc/mosquitto/conf.d/pibuild.conf"
    install -D -m 644 "$src" "$dst"

    local port_esc auth_block_esc
    port_esc=$(sed_escape "$port")
    auth_block_esc=$(sed_escape "$auth_block")

    local ws_block=""
    if [[ -n "$ws_port" ]]; then
        ws_block="\nlistener ${ws_port}\nprotocol websockets\n${auth_block}"
    fi
    local ws_block_esc
    ws_block_esc=$(sed_escape "$ws_block")

    sed -i \
        -e "s|@@PORT@@|${port_esc}|g" \
        -e "s|@@AUTH_BLOCK@@|${auth_block_esc}|g" \
        -e "s|@@WS_BLOCK@@|${ws_block_esc}|g" \
        "$dst"

    # If password file is specified, copy it to the rootfs with restricted permissions
    if [[ "$auth_mode" == "passwd" ]]; then
        [[ -f "$passwd_file" ]] || { echo "install_mqtt_broker: --passwd-file '$passwd_file' not found in chroot" >&2; return 3; }
        install -D -m 600 "$passwd_file" /etc/mosquitto/passwd
    fi

    # Enable mosquitto service in systemd
    systemctl enable mosquitto.service
}
