# DEPRECATED — slated for removal, WITH ONE COUPLING TO RESOLVE FIRST

**Status:** RETIRED prototype (the macOS ES reimplementation) — BUT this
directory's `build.zig` is currently the ONLY build recipe for the unique,
KEEP capability `input-guardian` (USB-HID input sovereignty). Read the coupling
section before deleting.

## What is dead here (retire)

- `es_warden.zig`, `main.zig` — a macOS Endpoint Security reimplementation
  (`es-warden`) plus a DYLD-interposition variant (`libmacwarden.dylib`).
- `macwarden.conf.example` — carries stale hardcoded `/Users/director/...`
  protected/whitelist paths (single-developer-box leftover).
- `es_warden.entitlements`, `sign-es-warden.sh`, `.gitignore`, `history.txt`.

These are superseded by **Metatron Security** (`FilterDataProvider.swift` ES
`AUTH`, host app + system extension). Not referenced by the main
`guardian_shield/build.zig`.

## The coupling — do NOT break `input-guardian`

`src/libmacwarden/build.zig` builds THREE targets:

1. `macwarden` (dylib)  — DEAD, retire.
2. `es-warden` (ES exe) — DEAD, retire. (Imports `ctk` from
   `../../../cognitive_telemetry_kit/core/core.zig`, which exists.)
3. **`input-guardian`** — ALIVE. Root source is
   `../input_sovereignty/input-guardian.zig` (the cross-platform HID sentinel:
   Linux `/dev/input/eventX`, macOS `IOHIDManager`). This is the UNIQUE Linux
   capability we are KEEPING. `src/input_sovereignty/` has **no `build.zig` of
   its own** — this file is its only build harness.

Dependency direction: `libmacwarden/build.zig` → `input_sovereignty/*.zig`
(build harness depends on source). `input_sovereignty` does NOT depend on
`libmacwarden`. So the *source* here is safe to delete; only the
`input-guardian` build stanza must be preserved.

## Required decoupling BEFORE deletion

1. Create `src/input_sovereignty/build.zig` containing only the `input-guardian`
   stanza lifted from `src/libmacwarden/build.zig` (the `input_mod` /
   `input_exe` block). Make the `IOKit` / `CoreFoundation` framework links
   **macOS-conditional** (`if (target.result.os.tag == .macos)`), since
   `input-guardian.zig` already `comptime`-switches Linux vs macOS internally.
   Point `root_source_file` at `input-guardian.zig` (now a sibling), not
   `../input_sovereignty/...`.
2. Verify `zig build` in `src/input_sovereignty/` produces the `input-guardian`
   binary on both targets.
3. Only THEN delete `src/libmacwarden/` in full.

Until step 1 lands, deleting this directory removes the only way to build
`input-guardian`.

## Replacement (for the es-warden / dylib parts)

| This prototype | Replaced by (Metatron) |
|---|---|
| `es-warden` ES daemon | `Guardian Shield Security/FilterDataProvider.swift` |
| `libmacwarden.dylib` DYLD interposition | Metatron system extension (no DYLD hack) |
| `macwarden.conf` | `ShieldConstants.swift` protected-paths / config |

See `docs/CONVERGENCE.md`.
