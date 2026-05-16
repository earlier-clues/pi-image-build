# mqtt-telemetry module — publish per-Pi health/version/online to an MQTT
# broker on a fixed cadence. See docs/design-plans/2026-05-14-mqtt-venue-telemetry.md
# for the topic layout and payload schema.

require MQTT_BROKER
require MQTT_ROLE

# Optional: PEM file with CA cert for TLS. Empty = plaintext MQTT.
optional MQTT_CERT_PATH default=
