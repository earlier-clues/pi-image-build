"""Unit tests for pibuild-mqtt-telemetry daemon parsers.

Pure function tests covering all parsers in the daemon. No subprocess calls,
no MQTT broker, no /proc reads. All fixtures are static snapshots.
"""

import pytest
from pathlib import Path

import pibuild_mqtt_telemetry as daemon


class TestParseThermalTemp:
    """Tests for parse_thermal_temp (parses /sys/class/thermal/thermal_zone0/temp)."""

    def test_parse_thermal_temp_happy_path(self):
        """45123 (millidegrees C) -> 45.123 degrees C."""
        assert daemon.parse_thermal_temp("45123") == 45.123

    def test_parse_thermal_temp_with_newline(self):
        """Trailing whitespace is stripped."""
        assert daemon.parse_thermal_temp("45123\n") == 45.123

    def test_parse_thermal_temp_zero(self):
        """Zero temperature is valid."""
        assert daemon.parse_thermal_temp("0") == 0.0

    def test_parse_thermal_temp_large_value(self):
        """Large temperature value (edge case)."""
        assert daemon.parse_thermal_temp("150000") == 150.0

    def test_parse_thermal_temp_invalid_empty_string(self):
        """Empty string raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_thermal_temp("")

    def test_parse_thermal_temp_invalid_non_numeric(self):
        """Non-numeric input raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_thermal_temp("invalid")


class TestParseVcgencmdTemp:
    """Tests for parse_vcgencmd_temp (parses vcgencmd measure_temp output)."""

    def test_parse_vcgencmd_temp_happy_path(self):
        """temp=45.0'C\\n -> 45.0."""
        assert daemon.parse_vcgencmd_temp("temp=45.0'C\n") == 45.0

    def test_parse_vcgencmd_temp_no_newline(self):
        """No trailing newline is OK."""
        assert daemon.parse_vcgencmd_temp("temp=45.0'C") == 45.0

    def test_parse_vcgencmd_temp_decimal_precision(self):
        """Preserves decimal precision."""
        assert daemon.parse_vcgencmd_temp("temp=47.3'C") == 47.3

    def test_parse_vcgencmd_temp_zero(self):
        """Zero temperature is valid."""
        assert daemon.parse_vcgencmd_temp("temp=0.0'C") == 0.0

    def test_parse_vcgencmd_temp_missing_prefix(self):
        """Missing 'temp=' prefix raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_vcgencmd_temp("45.0'C\n")

    def test_parse_vcgencmd_temp_missing_suffix(self):
        """Missing \"'C\" suffix raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_vcgencmd_temp("temp=45.0\n")

    def test_parse_vcgencmd_temp_malformed_degrees(self):
        """Wrong suffix (e.g., K) raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_vcgencmd_temp("temp=45.0'K")


class TestParseVcgencmdThrottled:
    """Tests for parse_vcgencmd_throttled (parses vcgencmd get_throttled hex bitmask)."""

    def test_parse_vcgencmd_throttled_happy_path(self):
        """throttled=0x50000\\n -> 0x50000 as int."""
        assert daemon.parse_vcgencmd_throttled("throttled=0x50000\n") == 0x50000

    def test_parse_vcgencmd_throttled_zero(self):
        """throttled=0x0 (no throttling) -> 0."""
        assert daemon.parse_vcgencmd_throttled("throttled=0x0\n") == 0

    def test_parse_vcgencmd_throttled_no_newline(self):
        """Trailing newline is optional."""
        assert daemon.parse_vcgencmd_throttled("throttled=0x50000") == 0x50000

    def test_parse_vcgencmd_throttled_large_bitmask(self):
        """Large bitmask value."""
        assert daemon.parse_vcgencmd_throttled("throttled=0xffffff") == 0xffffff

    def test_parse_vcgencmd_throttled_missing_prefix(self):
        """Missing 'throttled=' raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_vcgencmd_throttled("0x50000\n")

    def test_parse_vcgencmd_throttled_invalid_hex_character(self):
        """Invalid hex character raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_vcgencmd_throttled("throttled=0xGHIJK\n")


class TestParseMeminfo:
    """Tests for parse_meminfo (parses /proc/meminfo)."""

    def test_parse_meminfo_happy_path(self, meminfo_fixture):
        """Full /proc/meminfo snapshot contains expected keys."""
        result = daemon.parse_meminfo(meminfo_fixture)
        assert isinstance(result, dict)
        assert "MemTotal" in result
        assert "MemFree" in result
        assert "MemAvailable" in result
        assert "Buffers" in result
        assert result["MemTotal"] == 3793680
        assert result["MemFree"] == 2912088
        assert result["MemAvailable"] == 3304512

    def test_parse_meminfo_empty_string(self):
        """Empty input yields empty dict."""
        assert daemon.parse_meminfo("") == {}

    def test_parse_meminfo_malformed_lines_skipped(self):
        """Lines without ':' or non-numeric values are skipped gracefully."""
        text = """MemTotal:        1000 kB
InvalidLine
MemFree:         500 kB
MemWithoutNumber: kB
MemAvailable:    750 kB
"""
        result = daemon.parse_meminfo(text)
        assert result["MemTotal"] == 1000
        assert result["MemFree"] == 500
        assert result["MemAvailable"] == 750
        assert "InvalidLine" not in result

    def test_parse_meminfo_single_entry(self):
        """Single entry is parsed correctly."""
        result = daemon.parse_meminfo("MemTotal:        3793680 kB")
        assert result == {"MemTotal": 3793680}


class TestParseUptime:
    """Tests for parse_uptime (parses /proc/uptime first field)."""

    def test_parse_uptime_happy_path(self):
        """First field of /proc/uptime is returned as float."""
        assert daemon.parse_uptime("12345.67 8910.11\n") == 12345.67

    def test_parse_uptime_integer(self):
        """Integer uptime is converted to float."""
        assert daemon.parse_uptime("1000 500") == 1000.0

    def test_parse_uptime_scientific_notation(self):
        """Scientific notation is handled."""
        assert daemon.parse_uptime("1e5 9000") == 1e5

    def test_parse_uptime_empty_string(self):
        """Empty string raises ValueError on empty input."""
        with pytest.raises(ValueError):
            daemon.parse_uptime("")

    def test_parse_uptime_no_space(self):
        """Single number with no second field."""
        assert daemon.parse_uptime("12345.67") == 12345.67


class TestParseLoadavg:
    """Tests for parse_loadavg (parses /proc/loadavg first field)."""

    def test_parse_loadavg_happy_path(self):
        """First field of /proc/loadavg is 1m load average."""
        assert daemon.parse_loadavg("0.42 0.31 0.20 1/123 4567\n") == 0.42

    def test_parse_loadavg_zero(self):
        """Zero load is valid."""
        assert daemon.parse_loadavg("0.0 0.0 0.0 0/1 1") == 0.0

    def test_parse_loadavg_high_load(self):
        """High load value."""
        assert daemon.parse_loadavg("4.20 3.10 2.00 2/5 100") == 4.20

    def test_parse_loadavg_empty_string(self):
        """Empty string raises ValueError on empty input."""
        with pytest.raises(ValueError):
            daemon.parse_loadavg("")


class TestParseIwLinkRssi:
    """Tests for parse_iw_link_rssi (parses iw dev wlan0 link output)."""

    def test_parse_iw_link_rssi_happy_path(self, iw_connected_fixture):
        """Extract signal level from connected iw link output."""
        result = daemon.parse_iw_link_rssi(iw_connected_fixture)
        assert result == -57

    def test_parse_iw_link_rssi_disconnected(self, iw_disconnected_fixture):
        """Disconnected device has no signal line -> None."""
        result = daemon.parse_iw_link_rssi(iw_disconnected_fixture)
        assert result is None

    def test_parse_iw_link_rssi_weak_signal(self):
        """Very weak signal (high dBm magnitude)."""
        output = """Connected to aa:bb:cc:dd:ee:ff (on wlan0)
	signal: -80 dBm
"""
        assert daemon.parse_iw_link_rssi(output) == -80

    def test_parse_iw_link_rssi_strong_signal(self):
        """Strong signal (low dBm magnitude)."""
        output = """Connected to aa:bb:cc:dd:ee:ff (on wlan0)
	signal: -30 dBm
"""
        assert daemon.parse_iw_link_rssi(output) == -30

    def test_parse_iw_link_rssi_empty_string(self):
        """Empty output has no signal line -> None."""
        assert daemon.parse_iw_link_rssi("") is None

    def test_parse_iw_link_rssi_malformed_signal_line(self):
        """Malformed signal line is skipped -> None."""
        output = """Connected to aa:bb:cc:dd:ee:ff (on wlan0)
	signal: invalid dBm
"""
        result = daemon.parse_iw_link_rssi(output)
        assert result is None


class TestParseIpAddrV4:
    """Tests for parse_ip_addr_v4 (parses ip -4 -o addr show)."""

    def test_parse_ip_addr_v4_happy_path(self, ip_addr_fixture):
        """Extract first non-loopback IPv4 from ip command output."""
        result = daemon.parse_ip_addr_v4(ip_addr_fixture)
        assert result == "192.168.1.10"

    def test_parse_ip_addr_v4_only_loopback(self):
        """Only loopback interface present -> None."""
        output = "1: lo inet 127.0.0.1/8 scope host lo\n"
        assert daemon.parse_ip_addr_v4(output) is None

    def test_parse_ip_addr_v4_empty_string(self):
        """Empty output -> None."""
        assert daemon.parse_ip_addr_v4("") is None

    def test_parse_ip_addr_v4_multiple_addresses(self):
        """First non-loopback is returned (not loopback)."""
        output = """1: lo inet 127.0.0.1/8 scope host lo
2: eth0 inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0
3: eth1 inet 10.0.0.5/24 brd 10.0.0.255 scope global eth1
"""
        assert daemon.parse_ip_addr_v4(output) == "192.168.1.10"

    def test_parse_ip_addr_v4_ipv6_ignored(self):
        """IPv6 lines are skipped; first inet found."""
        output = """1: lo inet6 ::1/128 scope host lo
2: eth0 inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0
"""
        assert daemon.parse_ip_addr_v4(output) == "192.168.1.10"


class TestParseBroker:
    """Tests for parse_broker (parses broker URL)."""

    def test_parse_broker_host_and_port(self):
        """'host:port' -> (host, int(port))."""
        assert daemon.parse_broker("aether-server:1883") == ("aether-server", 1883)

    def test_parse_broker_plain_host(self):
        """Plain 'host' defaults to port 1883."""
        assert daemon.parse_broker("aether-server") == ("aether-server", 1883)

    def test_parse_broker_ip_and_port(self):
        """IP address with port."""
        assert daemon.parse_broker("192.168.1.1:8883") == ("192.168.1.1", 8883)

    def test_parse_broker_plain_ip(self):
        """Plain IP address defaults to port 1883."""
        assert daemon.parse_broker("192.168.1.1") == ("192.168.1.1", 1883)

    def test_parse_broker_localhost(self):
        """Localhost with custom port."""
        assert daemon.parse_broker("localhost:9999") == ("localhost", 9999)

    def test_parse_broker_invalid_port_non_numeric(self):
        """Non-numeric port raises ValueError."""
        with pytest.raises(ValueError):
            daemon.parse_broker("host:notaport")


class TestCollectHealth:
    """Tests for collect_health (orchestrates all readers)."""

    def test_collect_health_happy_path(self, monkeypatch):
        """With all readers returning values, dict contains all fields."""
        monkeypatch.setattr(daemon, "read_cpu_temp_c", lambda: 45.0)
        monkeypatch.setattr(daemon, "read_ram_free_mb", lambda: 2048)
        monkeypatch.setattr(daemon, "read_disk_free_mb", lambda: 5000)
        monkeypatch.setattr(daemon, "read_uptime_s", lambda: 12345.67)
        monkeypatch.setattr(daemon, "read_load_1m", lambda: 0.5)
        monkeypatch.setattr(daemon, "read_wifi_rssi_dbm", lambda: -57)
        monkeypatch.setattr(daemon, "read_throttled", lambda: 0)
        monkeypatch.setattr(daemon, "read_version_fingerprint", lambda: "test-version")
        monkeypatch.setattr(daemon, "read_ipv4", lambda: "192.168.1.10")

        result = daemon.collect_health("test-role")

        assert result["role"] == "test-role"
        assert result["cpu_temp_c"] == 45.0
        assert result["ram_free_mb"] == 2048
        assert result["disk_free_mb"] == 5000
        assert result["uptime_s"] == 12345.67
        assert result["load_1m"] == 0.5
        assert result["wifi_rssi_dbm"] == -57
        assert result["throttled"] == 0
        assert result["version"] == "test-version"
        assert result["ip"] == "192.168.1.10"
        assert "ts" in result

    def test_collect_health_all_readers_return_none(self, monkeypatch):
        """When all readers return None, dict omits None values but includes ts and role."""
        monkeypatch.setattr(daemon, "read_cpu_temp_c", lambda: None)
        monkeypatch.setattr(daemon, "read_ram_free_mb", lambda: None)
        monkeypatch.setattr(daemon, "read_disk_free_mb", lambda: None)
        monkeypatch.setattr(daemon, "read_uptime_s", lambda: None)
        monkeypatch.setattr(daemon, "read_load_1m", lambda: None)
        monkeypatch.setattr(daemon, "read_wifi_rssi_dbm", lambda: None)
        monkeypatch.setattr(daemon, "read_throttled", lambda: None)
        monkeypatch.setattr(daemon, "read_version_fingerprint", lambda: "fallback")
        monkeypatch.setattr(daemon, "read_ipv4", lambda: None)

        result = daemon.collect_health("test-role")

        assert result["role"] == "test-role"
        assert result["version"] == "fallback"
        assert "ts" in result
        assert "cpu_temp_c" not in result
        assert "ram_free_mb" not in result
        assert "disk_free_mb" not in result

    def test_collect_health_mixed_none_and_values(self, monkeypatch):
        """Some readers return values, some return None."""
        monkeypatch.setattr(daemon, "read_cpu_temp_c", lambda: 45.0)
        monkeypatch.setattr(daemon, "read_ram_free_mb", lambda: None)
        monkeypatch.setattr(daemon, "read_disk_free_mb", lambda: 5000)
        monkeypatch.setattr(daemon, "read_uptime_s", lambda: None)
        monkeypatch.setattr(daemon, "read_load_1m", lambda: 0.5)
        monkeypatch.setattr(daemon, "read_wifi_rssi_dbm", lambda: None)
        monkeypatch.setattr(daemon, "read_throttled", lambda: None)
        monkeypatch.setattr(daemon, "read_version_fingerprint", lambda: "test-version")
        monkeypatch.setattr(daemon, "read_ipv4", lambda: None)

        result = daemon.collect_health("mixed-role")

        assert result["cpu_temp_c"] == 45.0
        assert result["disk_free_mb"] == 5000
        assert result["load_1m"] == 0.5
        assert result["version"] == "test-version"
        assert "ram_free_mb" not in result
        assert "uptime_s" not in result
        assert "wifi_rssi_dbm" not in result


# ---- Fixtures ----

@pytest.fixture
def meminfo_fixture():
    """Load the full /proc/meminfo fixture."""
    fixture_path = Path(__file__).parent / "fixtures" / "proc-meminfo.txt"
    return fixture_path.read_text()


@pytest.fixture
def iw_connected_fixture():
    """Load the iw dev wlan0 link (connected) fixture."""
    fixture_path = Path(__file__).parent / "fixtures" / "iw-dev-wlan0-link.txt"
    return fixture_path.read_text()


@pytest.fixture
def iw_disconnected_fixture():
    """Load the iw dev wlan0 link (disconnected) fixture."""
    fixture_path = Path(__file__).parent / "fixtures" / "iw-dev-wlan0-link-disconnected.txt"
    return fixture_path.read_text()


@pytest.fixture
def ip_addr_fixture():
    """Load the ip -4 -o addr show fixture."""
    fixture_path = Path(__file__).parent / "fixtures" / "ip-4-o-addr-show.txt"
    return fixture_path.read_text()
