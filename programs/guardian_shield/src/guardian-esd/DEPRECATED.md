# DEPRECATED — slated for removal

**Status:** RETIRED prototype. Not built, not shipped, superseded.

This directory (`src/guardian-esd/`) is an abandoned macOS Endpoint Security
daemon prototype (Swift Package). It is **not referenced by the main
`guardian_shield/build.zig`** (which builds only the Linux libwarden / eBPF
artifacts) and has no consumer in the tree.

## Why it is dead

- Superseded by the mature, signed macOS product **Metatron Security**
  (`FilterDataProvider.swift` does ES `AUTH` enforcement, and the host app +
  system extension already do everything this prototype gestured at, better).
- Carries stale, machine-specific markers: hardcoded `/Users/director/...`
  protected/whitelist paths in `Sources/GuardianESD/main.swift` and
  `SETUP_GUIDE.md`. It was never generalized past one developer's box.
- Never wired into any build orchestration in this repo.

## Replacement

| This prototype | Replaced by (Metatron) |
|---|---|
| ES daemon `AUTH` file protection | `Guardian Shield Security/FilterDataProvider.swift` |
| protected-paths config | `GuardianShield/ShieldConstants.swift` (`protected-paths.json`) + host app UI |
| event/violation output | `GuardianShield/ShieldEvent.swift` |

The cross-platform contract that both OSes converge on is in
`docs/CONVERGENCE.md`.

## Removal

Safe to delete in full. See the operator command list in the Phase-3
convergence report / `docs/CONVERGENCE.md` migration note. No decoupling
required — nothing in-tree depends on this directory.
