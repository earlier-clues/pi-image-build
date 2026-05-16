# pi-image-build — dev-host shortcuts.
# Recipes are thin wrappers over bin/*.sh; those scripts remain the
# canonical CLIs. This file is for ergonomics, not for being authoritative.

default:
    @just --list

# --- build pipeline -------------------------------------------------------

# Build an image from a payload directory. Extra args pass through.
build payload *args:
    bin/build-image.sh {{payload}} {{args}}

# Flash an image to an SD card (macOS only; prompts for device).
flash image:
    bin/flash-image.sh {{image}}

# Image-diff verification gate. Exit 0 = equivalent.
diff old new:
    bin/diff-images.sh {{old}} {{new}}

# QEMU smoke test (kernel + ext4 only — not a full Pi emulation).
qemu-test image:
    bin/test-image.sh {{image}}

# Python parser unit tests.
test:
    python3 -m pytest tests/ -v

# --- dev-host mqtt broker -------------------------------------------------
# Local mosquitto on :1883 for testing the mqtt-telemetry module against
# your dev machine. Anonymous, plaintext. Not part of the build pipeline.

# Start a local mosquitto broker.
broker-up:
    @mkdir -p /tmp/mosquitto
    @printf 'listener 1883 0.0.0.0\nallow_anonymous true\n' > /tmp/mosquitto/mosquitto.conf
    docker run -d --name mosquitto -p 1883:1883 \
        -v /tmp/mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro \
        eclipse-mosquitto
    @echo "broker up. tail with: just broker-sub"

# Subscribe to a topic on the local broker (default: pi/#).
broker-sub topic='pi/#':
    docker exec -it mosquitto mosquitto_sub -h localhost -t '{{topic}}' -v

# Tail the broker container's logs.
broker-logs:
    docker logs -f mosquitto

# Stop and remove the broker container.
broker-down:
    -docker stop mosquitto
    -docker rm mosquitto
