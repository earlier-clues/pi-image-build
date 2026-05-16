# tests/ — host-runnable test suite

Last verified: 2026-05-16

## Purpose
Unit tests for code that is amenable to pure-function testing.
Currently: parser/serializer functions in
`lib/mqtt-telemetry/pibuild-mqtt-telemetry.py` (52 tests).

See `README.md` (this directory) for setup/run commands.

## Contracts
- **Exposes**: a pytest suite invokable as
  `python3 -m pytest tests/ -v`.
- **Guarantees**: every test in here runs without root, without docker,
  without network, without /proc reads, without subprocesses. Pure
  functions only.
- **Expects**: a virtualenv with `tests/requirements.txt` installed.

## Scope (what belongs here)
- Pure parsers (parse `/proc/loadavg`-style strings, format topics, etc.).
- Pure formatters / serializers.
- Property-based tests for round-tripping where sensible.

## Out of scope (what doesn't belong here)
- Bash module behavior — modules are verified operationally by running
  `bin/build-image.sh` on `examples/hello-payload` or `examples/loader-smoke`
  and inspecting outcomes. Bash unit-testing is not worth the harness cost
  at the current scale.
- Tests that mount images, talk to a broker, or shell out — those are
  integration concerns. Add them as scripted gates outside `tests/`
  (see `bin/diff-images.sh` for the existing image-equivalence gate).
- /proc reads, file I/O, subprocesses, MQTT brokers.

## Dependencies
- **Uses**: paho-mqtt (only for type imports in the daemon module), pytest.
- **Used by**: humans, CI (when wired up).
- **Boundary**: tests import from `lib/mqtt-telemetry/`; nothing else
  imports `tests/`.

## Invariants
- All tests pass on macOS and Linux identically (no platform-specific paths).
- Tests do not require root, docker, or network.
- Adding a test that violates the pure-function invariant breaks the
  domain's purpose. If you genuinely need I/O coverage, design a separate
  gate (see `bin/diff-images.sh` for the pattern).

## Gotchas
- The daemon at `lib/mqtt-telemetry/pibuild-mqtt-telemetry.py` is imported
  by tests as a module path. Keep parser functions at module top level so
  they're importable without running the main loop.
- `__pycache__/` is gitignored; never commit it.
