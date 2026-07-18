# DEPRECATED — slated for removal

**Status:** RETIRED prototype. Not built, not shipped, superseded.

This directory (`src/network-filter/`) is an abandoned macOS Network Extension
content-filter prototype (Swift Package). It is **not referenced by the main
`guardian_shield/build.zig`** and has no consumer in the tree.

## Why it is dead

- Superseded by Metatron Security's shipping network stack:
  `NetworkApprovalManager.swift` (interactive per-host approval popup UX +
  dynamic allowlist), `DNSProxyProvider.swift` / `DNSPolicyStore.swift`
  (DNS/DoH filtering with curated + live threat feeds), and the content filter
  provider in the `Guardian Shield Security` extension target.
- Never wired into any build orchestration in this repo; a bare prototype
  Package with entitlements and a `Sources/` skeleton.

## Replacement

| This prototype | Replaced by (Metatron) |
|---|---|
| NE content filter | `Guardian Shield Security` extension + `NetworkApprovalManager.swift` |
| host allowlist/denylist | `ShieldConstants.swift` (`network-rules.json`, `denylist.json`, `dynamic-allowlist.json`) |
| DNS policy | `DNSPolicyStore.swift` (`dns-policy.json`) + `DNSProxyProvider.swift` |

The **Linux** side is what actually LACKS this capability. The porting action
(bring DNS-proxy/DoH and the network-approval-popup UX *to Linux*) is tracked in
`docs/CONVERGENCE.md`, not by resurrecting this prototype.

## Removal

Safe to delete in full. No decoupling required — nothing in-tree depends on it.
