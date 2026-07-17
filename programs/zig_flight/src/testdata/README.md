# zig_flight wire-format fixtures

Golden fixtures for the X-Plane 12 Web API wire messages that `protocol.zig`
parses. Each `.json` file is embedded verbatim (`@embedFile`) by a test in
`protocol.zig`; the tests assert the parsed result byte-for-byte, so a
misreading of the wire format (or an accidental change to a parser) fails a
test instead of silently corrupting the MFD display.

## Provenance

These fixtures are shaped to the **documented X-Plane 12 Web API v3 wire
format** (the `dataref_subscribe_values` / `dataref_update_values` /
`dataref_set_values` message envelope and the REST `datarefs` collection).
They are NOT captured from a live X-Plane 12 session — no simulator is
reachable from the build/CI environment.

To upgrade these to true externally-anchored fixtures (per the repo golden
rule), replay them against a running X-Plane 12: point `zig-flight-dump` at
the sim, capture the raw WebSocket text payloads and REST bodies, and
overwrite these files with the captured bytes (the parsers and tests already
consume them verbatim, so no test code needs to change — only the expected
values in the corresponding test asserts). Until then, treat these as
format-pinning regression fixtures, not a substitute for a live capture.

## Files

- `dataref_update_values.json` — a 10 Hz streaming update carrying scalar
  datarefs and an array-valued dataref (e.g. per-tank fuel quantity).
- `dataref_lookup.json` — a REST `GET /api/v3/datarefs?filter[name]=...`
  collection response used at startup for name→ID resolution.
- `result_success.json` — a `result` acknowledgement with `success:true`.
- `result_error.json` — a `result` acknowledgement with `success:false`.
