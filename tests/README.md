# Tests

Host-runnable test suite for pi-image-build. Bash-only modules are
verified operationally via `bin/build-image.sh` runs (see implementation
plans). This directory currently holds Python unit tests for the
mqtt-telemetry daemon's pure parsers.

## Setup

```
python3 -m venv tests/.venv
source tests/.venv/bin/activate
pip install -r tests/requirements.txt
```

## Run

```
python3 -m pytest tests/ -v
```

All parser tests are pure (no /proc reads, no subprocesses, no MQTT
broker). Tests run on macOS and Linux identically.
