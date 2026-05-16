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
