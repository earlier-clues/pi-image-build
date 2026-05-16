"""Make daemon scripts under lib/ importable without installing them.
Each (script_path, module_name) pair gets loaded once and registered
in sys.modules so tests can `import pibuild_mqtt_telemetry`."""

import importlib.util
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
_LIB = _HERE.parent / "lib"

_DAEMONS = [
    (_LIB / "mqtt-telemetry" / "pibuild-mqtt-telemetry.py", "pibuild_mqtt_telemetry"),
    (_LIB / "mqtt-dashboard" / "pibuild-mqtt-dashboard.py", "pibuild_mqtt_dashboard"),
]

for path, name in _DAEMONS:
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
