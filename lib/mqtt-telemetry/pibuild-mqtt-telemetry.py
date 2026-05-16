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

# pattern: Mixed (unavoidable)
# Reason: single-file daemon installed at /usr/local/bin/pibuild-mqtt-telemetry.
# Pure parsers (parse_*, collect_health caller-side) live above the
# "----- I/O wrappers -----" banner and are exercised by tests/ without
# any I/O. I/O wrappers and main() handle subprocess, file, socket, and
# MQTT calls. Splitting into two files would complicate the install
# target without testability benefit; tests already import only the
# pure parsers in practice.

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import sys
import threading
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
    """Parse /proc/uptime first field. Returns seconds (float).
    Raises ValueError on empty input."""
    parts = uptime_text.split()
    if not parts:
        raise ValueError("empty uptime")
    return float(parts[0])


def parse_loadavg(loadavg_text: str) -> float:
    """Parse /proc/loadavg first field. Returns 1m load as float.
    Raises ValueError on empty input."""
    parts = loadavg_text.split()
    if not parts:
        raise ValueError("empty loadavg")
    return float(parts[0])


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

    connected_event = threading.Event()
    def on_connect(client_, userdata, flags, reason_code, properties=None):
        connected_event.set()
    client.on_connect = on_connect

    log.info("connecting to %s:%d as %s", broker_host, broker_port, client_id)
    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    if not connected_event.wait(timeout=10.0):
        log.error("connect timeout")
        return 1

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
        if connected_event.is_set():
            client.publish(f"{base}/online", "false", qos=0, retain=True)
        client.loop_stop()
        client.disconnect()

    return 0


if __name__ == "__main__":
    sys.exit(main())
