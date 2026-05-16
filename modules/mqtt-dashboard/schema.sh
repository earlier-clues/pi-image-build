# mqtt-dashboard — tiny refresh-every-5s status page for an MQTT-publishing
# Pi fleet. Subscribes to a topic prefix, maintains live state + a rolling
# in-memory event log per host, serves an HTML status page on HTTP.
#
# Pair with `mqtt-broker` on the same Pi to get a self-contained venue
# server: pis publish → local mosquitto → local dashboard → operator's
# browser. No DB, no external services.

optional MQTT_DASHBOARD_BROKER default=localhost:1883
optional MQTT_DASHBOARD_TOPIC  default=pi/#
optional MQTT_DASHBOARD_PORT   default=8080
