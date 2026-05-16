"""Unit tests for the mqtt-dashboard event-detection logic.

`detect_events(old, new)` is the pure function that produces the rolling
event log entries. It's the most subtle part of the daemon (especially
the throttled-bit decoding), so it's the natural target for tests.
"""
import pibuild_mqtt_dashboard as dash


def test_old_none_returns_empty():
    """No prior health means no events — first sample establishes baseline."""
    assert dash.detect_events(None, {"cpu_temp_c": 50.0}) == []


def test_identical_returns_empty():
    h = {"cpu_temp_c": 50.0, "throttled": 0, "ip": "10.0.0.1"}
    assert dash.detect_events(h, h) == []


def test_throttled_bit_newly_set_under_voltage_now():
    old = {"throttled": 0}
    new = {"throttled": 1}  # bit 0 = under-voltage now
    events = dash.detect_events(old, new)
    assert len(events) == 1
    kind, msg = events[0]
    assert kind == "throttled"
    assert "under-voltage now" in msg


def test_throttled_bit_newly_set_thermal_throttle():
    old = {"throttled": 0}
    new = {"throttled": 1 << 2}  # bit 2 = currently throttled
    events = dash.detect_events(old, new)
    assert events[0][0] == "throttled"
    assert "currently throttled" in events[0][1]


def test_throttled_multiple_bits_set():
    old = {"throttled": 0}
    new = {"throttled": (1 << 0) | (1 << 16)}  # under-voltage now + occurred
    events = dash.detect_events(old, new)
    assert len(events) == 1
    msg = events[0][1]
    assert "under-voltage now" in msg
    assert "under-voltage occurred" in msg


def test_throttled_only_lower_bit_cleared_no_new_set():
    """Bits clearing produces a generic 'old → new' event since no NEWLY-set bit names apply."""
    old = {"throttled": 1}  # under-voltage now
    new = {"throttled": 0}  # cleared
    events = dash.detect_events(old, new)
    assert len(events) == 1
    kind, msg = events[0]
    assert kind == "throttled"
    assert "0x1" in msg and "0x0" in msg


def test_throttled_unchanged_emits_nothing():
    old = {"throttled": 0x5}
    new = {"throttled": 0x5}
    assert dash.detect_events(old, new) == []


def test_temp_spike_above_10c_emits():
    old = {"cpu_temp_c": 45.0}
    new = {"cpu_temp_c": 56.0}
    events = dash.detect_events(old, new)
    assert any(k == "temp" for k, _ in events)


def test_temp_drop_above_10c_emits():
    old = {"cpu_temp_c": 70.0}
    new = {"cpu_temp_c": 55.0}
    events = dash.detect_events(old, new)
    assert any(k == "temp" for k, _ in events)


def test_temp_jitter_below_10c_quiet():
    old = {"cpu_temp_c": 55.0}
    new = {"cpu_temp_c": 60.0}
    assert dash.detect_events(old, new) == []


def test_temp_missing_in_old_quiet():
    old = {}
    new = {"cpu_temp_c": 80.0}
    assert dash.detect_events(old, new) == []


def test_temp_missing_in_new_quiet():
    old = {"cpu_temp_c": 80.0}
    new = {}
    assert dash.detect_events(old, new) == []


def test_ip_change_emits():
    old = {"ip": "192.168.1.10"}
    new = {"ip": "192.168.1.11"}
    events = dash.detect_events(old, new)
    assert len(events) == 1
    kind, msg = events[0]
    assert kind == "ip"
    assert "192.168.1.10" in msg and "192.168.1.11" in msg


def test_ip_initial_assignment_quiet():
    """Going from no-ip to some-ip is not an event (no transition to report)."""
    old = {}
    new = {"ip": "192.168.1.10"}
    assert dash.detect_events(old, new) == []


def test_ip_loss_quiet():
    """Going from some-ip to no-ip is also not reported (might be a transient
    blip during health collection; conservative: don't spam events for it)."""
    old = {"ip": "192.168.1.10"}
    new = {}
    assert dash.detect_events(old, new) == []


def test_multiple_changes_emit_multiple_events():
    old = {"throttled": 0, "cpu_temp_c": 50.0, "ip": "10.0.0.1"}
    new = {"throttled": 1, "cpu_temp_c": 65.0, "ip": "10.0.0.2"}
    events = dash.detect_events(old, new)
    kinds = {k for k, _ in events}
    assert kinds == {"throttled", "temp", "ip"}


def test_throttled_missing_treated_as_zero():
    """A health dict without `throttled` should not crash — treat as 0."""
    old = {}
    new = {"throttled": 1}
    events = dash.detect_events(old, new)
    assert events[0][0] == "throttled"


def test_throttled_none_treated_as_zero():
    old = {"throttled": None}
    new = {"throttled": 1}
    events = dash.detect_events(old, new)
    assert events[0][0] == "throttled"
