# mqtt-broker module — install and configure Mosquitto MQTT broker as a
# systemd service. Provides a listener for mqtt-telemetry clients to publish
# to. Matches the trusted-LAN posture: anonymous by default.

optional MQTT_BROKER_PORT default=1883

# Authentication mode: 'anonymous' for no auth (default), 'passwd' for
# password file-based auth. Mutually exclusive with MQTT_BROKER_PASSWD_PATH.
optional MQTT_BROKER_AUTH default=anonymous

# Path to mosquitto password file (must exist at build time when
# MQTT_BROKER_AUTH=passwd). If specified, will be copied to the rootfs
# at /etc/mosquitto/passwd with mode 0600.
optional MQTT_BROKER_PASSWD_PATH default=

# Path to TLS CA certificate (PEM format). If specified, TLS is enabled
# for the listener. The cert must be present in the chroot at build time
# and on the Pi at runtime; this module only configures the broker to use it.
optional MQTT_BROKER_CERT_PATH default=
