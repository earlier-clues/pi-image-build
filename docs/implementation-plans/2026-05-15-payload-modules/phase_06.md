# payload-modules Implementation Plan — Phase 6: `mqtt-telemetry` capability module

**Goal:** Ship `lib/mqtt-telemetry.sh` + `modules/mqtt-telemetry/` so any payload can publish per-Pi health/version/online status to an MQTT broker on a fixed cadence, with LWT-backed `online` semantics and MQTT v5. Includes a host-runnable unit test suite for the pure `/proc`-and-`vcgencmd` parsers (the first Python in the repo; first test framework in the repo).

**Architecture:** `lib/mqtt-telemetry.sh::install_mqtt_telemetry --role NAME --broker HOST:PORT [--cert PATH]` apt-installs `python3-paho-mqtt`, drops a single-file Python daemon at `/usr/local/bin/pibuild-mqtt-telemetry`, and drops a systemd unit at `/etc/systemd/system/pibuild-mqtt-telemetry.service` that runs the daemon with `Environment=` lines carrying role + broker + optional cert path. The daemon (~180 LOC) registers an LWT on `pi/<role>/<hostname>/online` with retained `false`, connects with MQTT v5, publishes a retained `version` once on boot, and loops publishing retained `health` JSON every 10s. The daemon's parsers are pure functions that take string inputs (file contents, subprocess stdout) and return values — they are unit-testable on macOS without a Pi or an MQTT broker.

**Tech Stack:** Python 3.11+ (Pi OS bookworm ships 3.11; tests run on whatever host Python ≥ 3.10 the operator has), `python3-paho-mqtt` (apt-installable inside the chroot; for tests, `pip install paho-mqtt` on the host or just don't import it in the test files), `pytest` (new test dependency; introduced into the repo via `tests/requirements.txt` and a `tests/README.md` saying `python3 -m pytest tests/`).

**Scope:** Phase 6 of 7 from `docs/design-plans/2026-05-15-payload-modules.md`.

**Codebase verified:** 2026-05-15 — no existing Python in the repo. No existing `tests/` directory. `docs/design-plans/2026-05-14-mqtt-venue-telemetry.md` is the upstream design for this module's payload shape and topic layout; consult it for cross-references but Phase 6 is the implementation home. `pipeline/Dockerfile` does not include any Python — the chroot does (Pi OS Lite ships Python 3.11 by default).

**External dependency findings (paho-mqtt v2):**
- ✓ `python3-paho-mqtt` is in Debian bookworm/trixie main. Version on bookworm is 1.6.1; trixie has 2.x. Both support MQTT v5 (v5 was added in 1.6).
- ✓ Python API for MQTT v5: `client = mqtt.Client(client_id=cid, protocol=mqtt.MQTTv5)`. paho-mqtt 2.x uses `CallbackAPIVersion.VERSION2` constructor — write code that works against 1.6.1 syntax for max compatibility.
- ✓ LWT: `client.will_set(topic, payload, qos=0, retain=True)` — set BEFORE `connect()`.
- ✓ Connect: `client.connect(host, port, keepalive=60)`. For TLS: `client.tls_set(ca_certs=…)` before connect.
- ✓ Publish retained: `client.publish(topic, payload, qos=0, retain=True)`.
- ✓ Loop: `client.loop_start()` returns immediately and runs the network loop in a thread; daemon does its own 10s timing in the main thread.
- 📖 Source: https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html (accessed 2026-05-15) and the paho-mqtt 1.6.1 source for the `will_set` signature.

**External dependency findings (vcgencmd):**
- ✓ `vcgencmd measure_temp` → `temp=45.0'C\n`
- ✓ `vcgencmd get_throttled` → `throttled=0x0\n` (hex bitmask)
- ✓ `vcgencmd version` → multiline firmware info; we use the first non-empty line as a fingerprint
- ✓ Not all Pi OS environments have `vcgencmd` (it requires `/dev/vcio`); fall back to `/sys/class/thermal/thermal_zone0/temp` for CPU temp if vcgencmd absent.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### payload-modules.AC7: `mqtt-telemetry` module
- **payload-modules.AC7.1 Success:** A payload with `modules.list = core + mqtt-telemetry` and valid `MQTT_BROKER` + `MQTT_ROLE` builds an image with the daemon + systemd unit installed.
- **payload-modules.AC7.2 Success:** On real hardware with a reachable mosquitto broker, `mosquitto_sub -t 'pi/+/+/health'` shows retained messages within 30s of boot.
- **payload-modules.AC7.3 Success:** Powering off the Pi flips the retained `pi/<role>/<hostname>/online` topic to `false` via LWT.
- **payload-modules.AC7.4 Success:** Python unit tests on the /proc + vcgencmd readers pass (no MQTT network involvement).
- **payload-modules.AC7.5 Failure:** Missing `MQTT_BROKER` or `MQTT_ROLE` aborts host-side with a clear error.

---

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->
<!-- START_TASK_1 -->
### Task 1: Create the Python daemon `lib/mqtt-telemetry/pibuild-mqtt-telemetry.py`

**Verifies:** payload-modules.AC7.1, payload-modules.AC7.2, payload-modules.AC7.3 (implementation; verified end-to-end in Task 5 and on hardware).

**Files:**
- Create: `lib/mqtt-telemetry/pibuild-mqtt-telemetry.py`

**Design notes:**

- One file, importable as a Python module from tests via `importlib.util.spec_from_file_location` (the file has no `.py` extension after install on the Pi, but on the host the development copy ends in `.py` so it's a normal import target).
- Pure parsers (no I/O) live at module level: `parse_thermal_temp`, `parse_vcgencmd_temp`, `parse_vcgencmd_throttled`, `parse_meminfo`, `parse_uptime`, `parse_loadavg`, `parse_iw_link_rssi`, `parse_ip_addr_v4`. Each takes a string, returns the parsed type.
- I/O wrappers (`read_*`): pure parsers wrapped with a file-read or subprocess call. Robust to missing files/commands (return `None`).
- `collect_health()` orchestrates the readers and returns a `dict` matching the documented schema in `docs/design-plans/2026-05-14-mqtt-venue-telemetry.md`.
- `main()` is the entry point: argparse for `--role`, `--broker`, `--cert`, `--cadence` (default 10s); sets up paho client with LWT; loops `collect_health()` → `publish` until SIGTERM.
- The module exits cleanly on SIGTERM/SIGINT (systemd stop). The retained `online=true` is published on connect; LWT flips it to `false` if the broker sees the client drop without a clean disconnect. On clean SIGTERM, the daemon explicitly publishes `online=false` retained, then disconnects.

**`lib/mqtt-telemetry/pibuild-mqtt-telemetry.py`:**

```python
#!/usr/bin/env python3
"""pi-image-build MQTT telemetry daemon.

Publishes per-Pi health, version, and online status to an MQTT broker on
a fixed cadence. Topic layout:

    pi/<role>/<hostname>/health     retained, every <cadence> seconds
    pi/<role>/<hostname>/version    retained, once on connect
    pi/<role>/<hostname>/online     retained, "true" on connect / "false" via LWT or clean shutdown

Pure parser functions at module level are unit-testable without an MQTT
broker or a Pi.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

import paho.mqtt.client as mqtt

# ----- pure parsers (unit-tested) -----------------------------------------

def parse_thermal_temp(thermal_text: str) -> float:
    """Parse /sys/class/thermal/thermal_zone0/temp content. Returns degrees C."""
    return int(thermal_text.strip()) / 1000.0


def parse_vcgencmd_temp(line: str) -> float:
    """Parse `vcgencmd measure_temp` output: 'temp=45.0\\'C\\n'."""
    s = line.strip()
    if not s.startswith("temp=") or not s.endswith("'C"):
        raise ValueError(f"unexpected vcgencmd measure_temp output: {line!r}")
    return float(s[len("temp="):-len("'C")])


def parse_vcgencmd_throttled(line: str) -> int:
    """Parse `vcgencmd get_throttled` output: 'throttled=0x50000\\n'. Returns int."""
    s = line.strip()
    if not s.startswith("throttled="):
        raise ValueError(f"unexpected vcgencmd get_throttled output: {line!r}")
    return int(s[len("throttled="):], 16)


def parse_meminfo(meminfo_text: str) -> dict[str, int]:
    """Parse /proc/meminfo. Returns {key: kB} for every line."""
    out: dict[str, int] = {}
    for ln in meminfo_text.splitlines():
        if ":" not in ln:
            continue
        k, rest = ln.split(":", 1)
        parts = rest.strip().split()
        if not parts:
            continue
        try:
            out[k.strip()] = int(parts[0])
        except ValueError:
            continue
    return out


def parse_uptime(uptime_text: str) -> float:
    """Parse /proc/uptime first field. Returns seconds (float)."""
    return float(uptime_text.split()[0])


def parse_loadavg(loadavg_text: str) -> float:
    """Parse /proc/loadavg first field. Returns 1m load as float."""
    return float(loadavg_text.split()[0])


def parse_iw_link_rssi(iw_link_text: str) -> Optional[int]:
    """Parse `iw dev wlan0 link` output, return signal in dBm or None if disconnected."""
    for ln in iw_link_text.splitlines():
        ln = ln.strip()
        if ln.startswith("signal:"):
            # "signal: -57 dBm"
            try:
                return int(ln.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def parse_ip_addr_v4(ip_addr_text: str) -> Optional[str]:
    """Parse `ip -4 -o addr show` output, return first non-loopback IPv4 or None."""
    for ln in ip_addr_text.splitlines():
        parts = ln.split()
        # Format: "2: eth0 inet 192.168.1.10/24 brd ..."
        if "inet" not in parts:
            continue
        try:
            ip_with_cidr = parts[parts.index("inet") + 1]
        except (IndexError, ValueError):
            continue
        ip = ip_with_cidr.split("/")[0]
        if ip.startswith("127."):
            continue
        return ip
    return None


# ----- I/O wrappers -------------------------------------------------------

def _read_file(path: str) -> Optional[str]:
    try:
        return Path(path).read_text()
    except OSError:
        return None


def _run(cmd: list[str], timeout: float = 2.0) -> Optional[str]:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=True
        ).stdout
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def read_cpu_temp_c() -> Optional[float]:
    """Prefer vcgencmd, fall back to thermal_zone0."""
    out = _run(["/usr/bin/vcgencmd", "measure_temp"])
    if out:
        try:
            return parse_vcgencmd_temp(out)
        except ValueError:
            pass
    thermal = _read_file("/sys/class/thermal/thermal_zone0/temp")
    if thermal:
        try:
            return parse_thermal_temp(thermal)
        except ValueError:
            return None
    return None


def read_throttled() -> Optional[int]:
    out = _run(["/usr/bin/vcgencmd", "get_throttled"])
    if not out:
        return None
    try:
        return parse_vcgencmd_throttled(out)
    except ValueError:
        return None


def read_ram_free_mb() -> Optional[int]:
    text = _read_file("/proc/meminfo")
    if not text:
        return None
    info = parse_meminfo(text)
    # MemAvailable is what userspace can actually allocate without swapping.
    kb = info.get("MemAvailable") or info.get("MemFree")
    return None if kb is None else kb // 1024


def read_disk_free_mb(path: str = "/") -> Optional[int]:
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    return (st.f_bavail * st.f_frsize) // (1024 * 1024)


def read_uptime_s() -> Optional[float]:
    text = _read_file("/proc/uptime")
    return None if text is None else parse_uptime(text)


def read_load_1m() -> Optional[float]:
    text = _read_file("/proc/loadavg")
    return None if text is None else parse_loadavg(text)


def read_wifi_rssi_dbm() -> Optional[int]:
    out = _run(["/usr/sbin/iw", "dev", "wlan0", "link"])
    return None if out is None else parse_iw_link_rssi(out)


def read_ipv4() -> Optional[str]:
    out = _run(["/usr/sbin/ip", "-4", "-o", "addr", "show"])
    return None if out is None else parse_ip_addr_v4(out)


def read_version_fingerprint() -> str:
    """Identify the running image. Reads /etc/pibuild-version if present
    (future hook for aether's version_hash.py output), else returns the
    image's PRETTY_NAME from /etc/os-release."""
    v = _read_file("/etc/pibuild-version")
    if v:
        return v.strip()
    osr = _read_file("/etc/os-release") or ""
    for ln in osr.splitlines():
        if ln.startswith("PRETTY_NAME="):
            return ln.split("=", 1)[1].strip().strip('"')
    return "unknown"


# ----- collectors ---------------------------------------------------------

def collect_health(role: str) -> dict:
    """Return a dict matching docs/design-plans/2026-05-14-mqtt-venue-telemetry.md
    schema. Missing fields are omitted (not None) so subscribers can
    distinguish absent from zero."""
    fields = {
        "ts": time.time(),
        "role": role,
        "cpu_temp_c": read_cpu_temp_c(),
        "ram_free_mb": read_ram_free_mb(),
        "disk_free_mb": read_disk_free_mb(),
        "uptime_s": read_uptime_s(),
        "wifi_rssi_dbm": read_wifi_rssi_dbm(),
        "throttled": read_throttled(),
        "load_1m": read_load_1m(),
        "version": read_version_fingerprint(),
        "ip": read_ipv4(),
    }
    return {k: v for k, v in fields.items() if v is not None}


# ----- daemon -------------------------------------------------------------

def parse_broker(s: str) -> tuple[str, int]:
    """'host:port' → ('host', int(port)). Plain 'host' defaults to 1883."""
    if ":" in s:
        host, port = s.rsplit(":", 1)
        return host, int(port)
    return s, 1883


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="pi-image-build MQTT telemetry daemon")
    ap.add_argument("--role", required=True, help="role name (e.g. mpv-loop)")
    ap.add_argument("--broker", required=True, help="host or host:port")
    ap.add_argument("--cert", default=None, help="optional CA cert PEM for TLS")
    ap.add_argument("--cadence", type=float, default=10.0, help="seconds between health publishes")
    ap.add_argument("--once", action="store_true", help="publish one cycle and exit (for smoke tests)")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log = logging.getLogger("pibuild-mqtt-telemetry")

    host = socket.gethostname()
    role = args.role
    broker_host, broker_port = parse_broker(args.broker)
    base = f"pi/{role}/{host}"

    client_id = f"pibuild-{role}-{host}-{os.getpid()}"
    client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv5)
    if args.cert:
        client.tls_set(ca_certs=args.cert)

    # LWT must be set before connect.
    client.will_set(f"{base}/online", "false", qos=0, retain=True)

    stop = False
    def _shutdown(signum, _frame):
        nonlocal stop
        log.info("received signal %s, shutting down", signum)
        stop = True
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    log.info("connecting to %s:%d as %s", broker_host, broker_port, client_id)
    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    client.publish(f"{base}/online", "true", qos=0, retain=True)
    client.publish(f"{base}/version", read_version_fingerprint(), qos=0, retain=True)

    try:
        while not stop:
            health = collect_health(role)
            client.publish(f"{base}/health", json.dumps(health, separators=(",", ":")), qos=0, retain=True)
            if args.once:
                break
            for _ in range(int(args.cadence * 10)):
                if stop:
                    break
                time.sleep(0.1)
    finally:
        client.publish(f"{base}/online", "false", qos=0, retain=True)
        client.loop_stop()
        client.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(main())
```

**Verification:**

Compile-check on the host:

```bash
python3 -c "import ast; ast.parse(open('lib/mqtt-telemetry/pibuild-mqtt-telemetry.py').read())"
```
Expected: no output, exit 0.

If `paho-mqtt` is installed locally (`pip install paho-mqtt` or `brew install ...`), also:

```bash
python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('d', 'lib/mqtt-telemetry/pibuild-mqtt-telemetry.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.collect_health('test'))
"
```
Expected: a dict with at least `ts`, `role`, `version`. Other fields may be None or absent on macOS.

**Commit:** `feat(lib/mqtt-telemetry): add Python telemetry daemon`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create the systemd unit and the lib installer

**Verifies:** payload-modules.AC7.1.

**Files:**
- Create: `lib/mqtt-telemetry/pibuild-mqtt-telemetry.service`
- Create: `lib/mqtt-telemetry.sh`

**`lib/mqtt-telemetry/pibuild-mqtt-telemetry.service`:**

```ini
[Unit]
Description=pi-image-build MQTT telemetry daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MQTT_ROLE=@@ROLE@@
Environment=MQTT_BROKER=@@BROKER@@
Environment=MQTT_CERT=@@CERT@@
ExecStart=/usr/local/bin/pibuild-mqtt-telemetry-launch
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**`lib/mqtt-telemetry/pibuild-mqtt-telemetry-launch`** (tiny launcher; lets us pass `--cert PATH` only when set without needing a more complex `ExecStart=` substitution):

```bash
#!/bin/bash
# Launch the pi-image-build MQTT telemetry daemon with env-derived args.
set -euo pipefail

ARGS=( --role "$MQTT_ROLE" --broker "$MQTT_BROKER" )
[[ -n "${MQTT_CERT:-}" ]] && ARGS+=( --cert "$MQTT_CERT" )

exec /usr/local/bin/pibuild-mqtt-telemetry "${ARGS[@]}"
```

**`lib/mqtt-telemetry.sh`:**

```bash
#!/bin/bash
# MQTT telemetry installer. Run inside the chroot.
LIB_API_VERSION=1

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
    sed -i \
        -e "s|@@ROLE@@|${role}|g" \
        -e "s|@@BROKER@@|${broker}|g" \
        -e "s|@@CERT@@|${cert}|g" \
        "$dst"

    systemctl enable pibuild-mqtt-telemetry.service
}
```

**Verification:**

```bash
bash -n lib/mqtt-telemetry.sh
bash -n lib/mqtt-telemetry/pibuild-mqtt-telemetry-launch
```
Expected: no output, exit 0.

**Commit:** `feat(lib/mqtt-telemetry): add installer, launcher, and systemd unit`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `modules/mqtt-telemetry/`

**Verifies:** payload-modules.AC7.1, payload-modules.AC7.5.

**Files:**
- Create: `modules/mqtt-telemetry/schema.sh`
- Create: `modules/mqtt-telemetry/module.sh`

**`modules/mqtt-telemetry/schema.sh`:**

```bash
# mqtt-telemetry module — publish per-Pi health/version/online to an MQTT
# broker on a fixed cadence. See docs/design-plans/2026-05-14-mqtt-venue-telemetry.md
# for the topic layout and payload schema.

require MQTT_BROKER
require MQTT_ROLE

# Optional: PEM file with CA cert for TLS. Empty = plaintext MQTT.
optional MQTT_CERT_PATH default=
```

**`modules/mqtt-telemetry/module.sh`:**

```bash
# mqtt-telemetry module — wrap install_mqtt_telemetry with env-driven
# config.

source "$LIB_DIR/mqtt-telemetry.sh"

_mt_args=( --role "$MQTT_ROLE" --broker "$MQTT_BROKER" )
[[ -n "${MQTT_CERT_PATH:-}" ]] && _mt_args+=( --cert "$MQTT_CERT_PATH" )

install_mqtt_telemetry "${_mt_args[@]}"
unset _mt_args
```

**Verification:**

```bash
bash -n modules/mqtt-telemetry/schema.sh
bash -n modules/mqtt-telemetry/module.sh
```

Host-side schema test — missing `MQTT_BROKER` and `MQTT_ROLE`:

```bash
( unset MQTT_BROKER MQTT_ROLE
  bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/mqtt-telemetry"
  '
) 2>&1 | tee /tmp/v-ac7.5.log

grep -q "MQTT_BROKER"     /tmp/v-ac7.5.log || { echo "FAIL AC7.5: MQTT_BROKER missing"; exit 1; }
grep -q "MQTT_ROLE"       /tmp/v-ac7.5.log || { echo "FAIL AC7.5: MQTT_ROLE missing"; exit 1; }
grep -q "mqtt-telemetry"  /tmp/v-ac7.5.log || { echo "FAIL AC7.5: module name missing"; exit 1; }
echo "PASS AC7.5"
```

Then with both required set:

```bash
MQTT_BROKER=aether-server:1883 MQTT_ROLE=test-role bash -c '
    source lib/modules-loader.sh
    validate_schemas "$(pwd)/modules/mqtt-telemetry"
'
```
Expected stdout: `export MQTT_CERT_PATH=`. No stderr.

**Commit:** `feat(modules/mqtt-telemetry): add mqtt-telemetry capability module`
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 4-5) -->
<!-- START_TASK_4 -->
### Task 4: Add `tests/` infrastructure and unit tests for daemon parsers

**Verifies:** payload-modules.AC7.4.

**Files:**
- Create: `tests/README.md`
- Create: `tests/requirements.txt`
- Create: `tests/conftest.py`
- Create: `tests/test_mqtt_telemetry_parsers.py`
- Create: `tests/fixtures/proc-meminfo.txt`
- Create: `tests/fixtures/proc-uptime.txt`
- Create: `tests/fixtures/proc-loadavg.txt`
- Create: `tests/fixtures/sys-thermal-temp.txt`
- Create: `tests/fixtures/vcgencmd-measure_temp.txt`
- Create: `tests/fixtures/vcgencmd-get_throttled.txt`
- Create: `tests/fixtures/iw-dev-wlan0-link.txt`
- Create: `tests/fixtures/iw-dev-wlan0-link-disconnected.txt`
- Create: `tests/fixtures/ip-4-o-addr-show.txt`

**`tests/README.md`:**

```markdown
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
```

**`tests/requirements.txt`:**

```
pytest>=7
# The chroot installs paho-mqtt 1.6.1 from Debian apt (python3-paho-mqtt).
# Pin tests to the same major to avoid paho 2.x's CallbackAPIVersion-
# required constructor signature, which would diverge tests from the
# image-side daemon's runtime environment. Re-pin to 2.x when the chroot's
# apt version moves.
paho-mqtt>=1.6,<2
```

**`tests/conftest.py`:**

```python
"""Make the daemon importable without installing it. Loads
lib/mqtt-telemetry/pibuild-mqtt-telemetry.py as a Python module
named `pibuild_mqtt_telemetry`."""

import importlib.util
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
_DAEMON = _HERE.parent / "lib" / "mqtt-telemetry" / "pibuild-mqtt-telemetry.py"

spec = importlib.util.spec_from_file_location("pibuild_mqtt_telemetry", _DAEMON)
mod = importlib.util.module_from_spec(spec)
sys.modules["pibuild_mqtt_telemetry"] = mod
spec.loader.exec_module(mod)
```

**`tests/test_mqtt_telemetry_parsers.py`** — describes tests, not actual code (task-implementor generates fresh):

Tests must cover, one per parser, with both happy-path and edge-case fixtures:

| Parser | Happy-path test | Edge-case test |
|---|---|---|
| `parse_thermal_temp` | `45123` → `45.123` | trailing newline tolerated; empty string raises ValueError |
| `parse_vcgencmd_temp` | `temp=45.0'C\n` → `45.0` | malformed (`temp=45.0\n` no `'C`) raises ValueError |
| `parse_vcgencmd_throttled` | `throttled=0x50000\n` → `0x50000` (int) | `throttled=0x0\n` → `0`; malformed raises |
| `parse_meminfo` | full /proc/meminfo fixture → dict has `MemAvailable`, `MemFree`, `Buffers`, etc. with int values | empty input → empty dict; malformed line skipped |
| `parse_uptime` | `12345.67 8910.11\n` → `12345.67` | empty string raises |
| `parse_loadavg` | `0.42 0.31 0.20 1/123 4567\n` → `0.42` | empty string raises |
| `parse_iw_link_rssi` | full link output with `signal: -57 dBm` → `-57` | `Not connected.` → `None`; missing `signal:` line → `None` |
| `parse_ip_addr_v4` | full `ip -4 -o addr` output with eth0 → first non-loopback IPv4 | only-loopback input → `None`; empty → `None` |
| `parse_broker` | `aether-server:1883` → `("aether-server", 1883)` | `aether-server` → `("aether-server", 1883)` (default port); `host:abc` raises ValueError |
| `collect_health` | given mocked readers returning known values, returns dict with all expected keys and None-valued fields omitted | when all readers return None, dict still contains `ts`, `role` |

**Fixture files** are exact byte snapshots of representative outputs (the task-implementor captures these from a real Pi or constructs them by hand). Example shapes:

`tests/fixtures/proc-meminfo.txt`:

```
MemTotal:        3793680 kB
MemFree:         2912088 kB
MemAvailable:    3304512 kB
Buffers:           29804 kB
Cached:           308120 kB
```

(Real /proc/meminfo has ~50 lines; the test fixture can be the full first 30 lines from a real Pi for realism.)

`tests/fixtures/iw-dev-wlan0-link.txt`:

```
Connected to aa:bb:cc:dd:ee:ff (on wlan0)
	SSID: aether
	freq: 2412
	RX: 1234 bytes (12 packets)
	TX: 5678 bytes (34 packets)
	signal: -57 dBm
	tx bitrate: 65.0 MBit/s MCS 7
```

`tests/fixtures/iw-dev-wlan0-link-disconnected.txt`:

```
Not connected.
```

**Verification:**

```bash
python3 -m venv tests/.venv
source tests/.venv/bin/activate
pip install -r tests/requirements.txt
python3 -m pytest tests/ -v
```

Expected: all tests pass. AC7.4 verified.

**Commit:** `test(mqtt-telemetry): unit tests for daemon parsers (AC7.4)`
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: End-to-end build with `core + mqtt-telemetry`

**Verifies:** payload-modules.AC7.1 (image contains daemon + service).

**Files:**
- No new files. Temp payload.

**Setup:**

```bash
mkdir -p /tmp/mqtt-test
cat > /tmp/mqtt-test/modules.list <<'EOF'
core
mqtt-telemetry
EOF
cat > /tmp/mqtt-test/.env <<EOF
HOSTNAME=mqtt-test
TIMEZONE=UTC
PI_USER=pi
ENCRYPTED_PASSWORD='$(openssl passwd -6 'mqtt-test')'
SSH_PUBKEY='$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "ssh-ed25519 AAAA test")'
MQTT_BROKER=test-broker.invalid:1883
MQTT_ROLE=mqtt-test
EOF
```

**Build:**

```bash
bin/build-image.sh /tmp/mqtt-test --output-format gz
```

Expected: exit 0, `==> modules: core mqtt-telemetry`, `apt-get install python3-paho-mqtt` succeeds inside the chroot.

Capture: `IMG=$(ls -t out/mqtt-test-*.img.gz | head -1)`.

**Inspect:**

```bash
docker run --rm --privileged \
    -v "$(pwd)/$IMG:/in/image.img.gz:ro" \
    pi-image-build:latest \
    bash -c '
        set -euo pipefail
        gzip -dc /in/image.img.gz > /tmp/img
        LOOP=$(losetup --find --show /tmp/img)
        trap "kpartx -dv $LOOP >/dev/null 2>&1 || true; losetup -d $LOOP >/dev/null 2>&1 || true" EXIT
        kpartx -av "$LOOP" >/dev/null
        BASE=$(basename "$LOOP")
        for _ in $(seq 1 20); do [[ -b /dev/mapper/${BASE}p2 ]] && break; sleep 0.2; done
        mkdir -p /mnt/r
        mount /dev/mapper/${BASE}p2 /mnt/r

        echo "=== daemon + launcher ==="
        ls -la /mnt/r/usr/local/bin/pibuild-mqtt-telemetry \
               /mnt/r/usr/local/bin/pibuild-mqtt-telemetry-launch

        echo "=== systemd unit (with substituted vars) ==="
        cat /mnt/r/etc/systemd/system/pibuild-mqtt-telemetry.service

        echo "=== unit enabled ==="
        ls -la /mnt/r/etc/systemd/system/multi-user.target.wants/pibuild-mqtt-telemetry.service

        echo "=== paho-mqtt installed ==="
        ls /mnt/r/usr/lib/python3/dist-packages/paho/mqtt/ 2>&1 | head -5

        umount /mnt/r
    '
```

**AC7.1 verified:**
- `/usr/local/bin/pibuild-mqtt-telemetry` and `/usr/local/bin/pibuild-mqtt-telemetry-launch` present.
- `/etc/systemd/system/pibuild-mqtt-telemetry.service` contains `MQTT_ROLE=mqtt-test` and `MQTT_BROKER=test-broker.invalid:1883` (and `MQTT_CERT=` empty).
- Unit enabled in `multi-user.target.wants/`.
- `paho.mqtt` Python package installed.
- No surviving `@@…@@` placeholders.

**AC7.2 / AC7.3 (real hardware + live broker):** manual operator verification. Spin up a mosquitto broker (`brew install mosquitto && mosquitto -v` on the operator's Mac); flash the image with `MQTT_BROKER=<operator-mac-tailnet-ip>:1883`; boot the Pi; on the Mac, run `mosquitto_sub -t 'pi/+/+/#' -v` and confirm `health`, `version`, `online=true` retained messages arrive within 30s. Power off the Pi; confirm `online` flips to `false` within ~75s (paho keepalive timeout default is 60s + 15s broker grace). Mark as operator-confirmed.

**Commit:** `test(modules/mqtt-telemetry): end-to-end build inspection`
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

---

## Phase Summary

After Phase 6, `mqtt-telemetry` is a one-line opt-in. The daemon is a single Python file with unit-tested pure parsers. The repo now has a `tests/` directory and a documented `pytest` workflow. `lib/mqtt-telemetry.sh::install_mqtt_telemetry` is available to legacy `build.sh` payloads. The companion `mqtt-broker` module (mosquitto installer for `aether/server`) is explicitly out of scope per the design's "Future" section.

**Build is green at end of phase:** the temp `/tmp/mqtt-test` payload builds, image contains the substituted unit and the daemon. `pytest tests/` passes. Phases 1–5 outputs still build.
