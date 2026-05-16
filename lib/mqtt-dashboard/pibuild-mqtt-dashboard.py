#!/usr/bin/env python3
"""
pi-image-build MQTT dashboard daemon.

Subscribes to a topic prefix on an MQTT broker, maintains a per-host
live state + rolling event log, and serves a tiny refresh-every-5s
status page over HTTP.

Topics consumed (matching the mqtt-telemetry agent):
    pi/<role>/<host>/online     retained: "true" | "false"
    pi/<role>/<host>/version    retained: image fingerprint
    pi/<role>/<host>/health     retained: JSON health blob

State is in-memory only; restarts lose the rolling event log. Live
state recovers immediately from the broker's retained values.

HTTP routes:
    GET /              text/html status page (meta-refresh every 5s)
    GET /health.json   application/json full state dump (for debugging)
"""
from __future__ import annotations

import argparse
import http.server
import json
import logging
import os
import signal
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Deque, Optional, Tuple

import paho.mqtt.client as mqtt


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("dashboard")


# ----- state -------------------------------------------------------------

@dataclass
class PiState:
    role: str
    online: Optional[bool] = None
    version: Optional[str] = None
    last_health: Optional[dict] = None
    last_health_ts: Optional[float] = None
    events: Deque[Tuple[float, str, str]] = field(default_factory=lambda: deque(maxlen=50))

    def add_event(self, kind: str, msg: str) -> None:
        self.events.appendleft((time.time(), kind, msg))


state_lock = threading.Lock()
fleet: dict[str, PiState] = {}


# ----- event detection (pure, given (old, new) health dicts) -------------

THROTTLED_BITS = {
    0: "under-voltage now",
    1: "arm freq capped now",
    2: "currently throttled",
    3: "soft temp limit now",
    16: "under-voltage occurred",
    17: "arm freq cap occurred",
    18: "throttling occurred",
    19: "soft temp limit occurred",
}


def detect_events(old: Optional[dict], new: dict) -> list[Tuple[str, str]]:
    """Return list of (kind, msg) for state changes worth recording.
    Pure function — easy to unit test."""
    if old is None:
        return []
    out: list[Tuple[str, str]] = []

    n_thr = int(new.get("throttled", 0) or 0)
    o_thr = int(old.get("throttled", 0) or 0)
    if n_thr != o_thr:
        newly_set = n_thr & ~o_thr
        names = [v for k, v in THROTTLED_BITS.items() if newly_set & (1 << k)]
        if names:
            out.append(("throttled", "set: " + ", ".join(names)))
        else:
            out.append(("throttled", f"0x{o_thr:x} → 0x{n_thr:x}"))

    n_t = new.get("cpu_temp_c")
    o_t = old.get("cpu_temp_c")
    if isinstance(n_t, (int, float)) and isinstance(o_t, (int, float)):
        if abs(n_t - o_t) >= 10:
            out.append(("temp", f"cpu temp: {o_t:.1f}°C → {n_t:.1f}°C"))

    n_ip = new.get("ip")
    o_ip = old.get("ip")
    if n_ip and o_ip and n_ip != o_ip:
        out.append(("ip", f"ip: {o_ip} → {n_ip}"))

    return out


# ----- MQTT callbacks ----------------------------------------------------

def on_message(client, userdata, msg) -> None:
    parts = msg.topic.split("/")
    if len(parts) != 4 or parts[0] != "pi":
        return
    _, role, host, kind = parts
    payload = msg.payload.decode("utf-8", errors="replace")

    with state_lock:
        pi = fleet.get(host)
        if pi is None:
            pi = PiState(role=role)
            fleet[host] = pi
            pi.add_event("discovered", f"first message: {kind}")

        if kind == "online":
            new_online = payload == "true"
            if pi.online is not None and pi.online != new_online:
                pi.add_event(
                    "online" if new_online else "offline",
                    f"online: {str(pi.online).lower()} → {str(new_online).lower()}",
                )
            pi.online = new_online
        elif kind == "version":
            if pi.version is not None and pi.version != payload:
                pi.add_event(
                    "version",
                    f"{pi.version[:24]}… → {payload[:24]}…",
                )
            pi.version = payload
        elif kind == "health":
            try:
                health = json.loads(payload)
            except json.JSONDecodeError:
                log.warning("bad health JSON from %s: %s", host, payload[:120])
                return
            for kind_, msg_ in detect_events(pi.last_health, health):
                pi.add_event(kind_, msg_)
            pi.last_health = health
            pi.last_health_ts = time.time()


def on_connect(client, userdata, flags, reason_code, properties=None) -> None:
    rc = getattr(reason_code, "value", reason_code)
    if int(rc) != 0:
        log.warning("connect rejected: reason_code=%s", reason_code)


# ----- HTML rendering ----------------------------------------------------

def _esc(s) -> str:
    if s is None:
        return "—"
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _fmt_temp(c) -> str:
    return f"{c:.1f}°C" if isinstance(c, (int, float)) else "—"


def _fmt_load(l) -> str:
    return f"{l:.2f}" if isinstance(l, (int, float)) else "—"


def _fmt_rssi(r) -> str:
    return f"{r} dBm" if isinstance(r, (int, float)) else "—"


def _fmt_uptime(s) -> str:
    if not isinstance(s, (int, float)):
        return "—"
    s = int(s)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


def _fmt_events(events: Deque[Tuple[float, str, str]]) -> str:
    if not events:
        return "—"
    rows = []
    for ts, kind, msg in list(events)[:10]:
        t = datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S")
        rows.append(f'<div>{t} <b>{_esc(kind)}</b> {_esc(msg)}</div>')
    return "".join(rows)


def render_html() -> str:
    with state_lock:
        rows = sorted(fleet.items())

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    body_rows: list[str] = []
    for host, pi in rows:
        h = pi.last_health or {}
        age = "—"
        status_class = "unknown"
        status_text = "unknown"
        if pi.online is True:
            status_class, status_text = "online", "online"
        elif pi.online is False:
            status_class, status_text = "offline", "offline"
        if pi.last_health_ts is not None:
            dt = int(time.time() - pi.last_health_ts)
            age = f"{dt}s"
            if dt > 30 and status_class == "online":
                status_class = "stale"
                status_text = "stale"
        body_rows.append(f"""        <tr>
          <td>{_esc(host)}</td>
          <td>{_esc(pi.role)}</td>
          <td class="{status_class}">{_esc(status_text)}</td>
          <td>{_fmt_uptime(h.get("uptime_s"))}</td>
          <td>{_fmt_temp(h.get("cpu_temp_c"))}</td>
          <td>{_fmt_load(h.get("load_1m"))}</td>
          <td>{_fmt_rssi(h.get("wifi_rssi_dbm"))}</td>
          <td>{_esc(h.get("ip"))}</td>
          <td>{age}</td>
          <td class="events">{_fmt_events(pi.events)}</td>
        </tr>""")

    table = (
        "\n".join(body_rows)
        if body_rows
        else '<tr><td colspan="10" class="empty">no pis seen yet — waiting for retained messages</td></tr>'
    )

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>pi fleet</title>
  <meta http-equiv="refresh" content="5">
  <style>
    body {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: #0d0d0d; color: #d0d0d0; margin: 1.5em; }}
    h1 {{ margin: 0 0 0.2em 0; font-weight: 500; }}
    .meta {{ color: #777; font-size: 0.85em; margin-bottom: 1.2em; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ padding: 0.45em 0.85em; text-align: left; border-bottom: 1px solid #222; vertical-align: top; }}
    th {{ color: #777; font-weight: normal; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.05em; }}
    .online  {{ color: #7cdb7c; }}
    .offline {{ color: #f06464; }}
    .stale   {{ color: #f0c060; }}
    .unknown {{ color: #777; }}
    .events  {{ font-size: 0.8em; color: #999; max-width: 28em; }}
    .empty   {{ color: #555; font-style: italic; }}
  </style>
</head>
<body>
  <h1>pi fleet</h1>
  <div class="meta">refresh: {now} · {len(rows)} pi(s) known · auto-reload 5s</div>
  <table>
    <tr>
      <th>host</th><th>role</th><th>status</th><th>uptime</th><th>cpu</th>
      <th>load</th><th>rssi</th><th>ip</th><th>health age</th><th>recent events</th>
    </tr>
{table}
  </table>
</body>
</html>"""


# ----- HTTP server -------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug("%s - " + fmt, self.address_string(), *args)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            body = render_html().encode("utf-8")
            ct = "text/html; charset=utf-8"
        elif self.path == "/health.json":
            with state_lock:
                snap = {
                    "now": time.time(),
                    "pis": {
                        host: {
                            "role": pi.role,
                            "online": pi.online,
                            "version": pi.version,
                            "last_health": pi.last_health,
                            "last_health_ts": pi.last_health_ts,
                            "events": [
                                {"ts": ts, "kind": k, "msg": m}
                                for ts, k, m in pi.events
                            ],
                        }
                        for host, pi in fleet.items()
                    },
                }
            body = json.dumps(snap, default=str).encode()
            ct = "application/json"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


# ----- main --------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="pi-image-build MQTT dashboard")
    ap.add_argument("--broker", required=True, help="host or host:port")
    ap.add_argument("--topic", default="pi/#", help="subscription topic (default: pi/#)")
    ap.add_argument("--port", type=int, default=8080, help="HTTP listen port (default: 8080)")
    args = ap.parse_args()

    host, _, port_s = args.broker.partition(":")
    broker_port = int(port_s) if port_s else 1883

    client = mqtt.Client(
        client_id=f"pibuild-dashboard-{os.getpid()}",
        protocol=mqtt.MQTTv5,
    )
    client.on_connect = on_connect
    client.on_message = on_message

    log.info("connecting to %s:%d, subscribing to %s", host, broker_port, args.topic)
    client.connect(host, broker_port, keepalive=60)
    client.subscribe(args.topic, qos=0)
    client.loop_start()

    stop = threading.Event()

    def _shutdown(signum, _frame):
        log.info("received signal %s, shutting down", signum)
        stop.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    log.info("serving on http://0.0.0.0:%d", args.port)

    stop.wait()
    server.shutdown()
    client.loop_stop()
    client.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(main())
