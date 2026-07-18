# Guardian Shield — Cross-Platform Convergence Contract

**Scope:** define ONE policy schema, ONE event schema, and a capability-parity
porting plan shared by the two Guardian Shield implementations:

- **Linux** — this repo (`programs/guardian_shield/`): `libwarden.so`
  (LD_PRELOAD syscall guard) + BPF-LSM loader (`guardian-shield-v9/`) +
  `zig_sentinel` (eBPF anomaly/emoji sentinel) + `libwarden_fork` (fork-bomb
  limiter) + `input_sovereignty` (USB-HID sentinel).
- **macOS** — Metatron Security (Swift; `github_public/metatron-security/`):
  host app + `Guardian Shield Security` system extension
  (`FilterDataProvider.swift` ES `AUTH`, `DNSProxyProvider.swift`) +
  `NetworkApprovalManager.swift`.

This document is the authority both codebases converge toward. Where the two
diverge today, the "unified" column is the target; per-OS extension blocks are
explicitly namespaced so neither side has to implement the other's kernel
primitives.

> **Verified-vs-assumed:** every schema below is reconciled from source actually
> read on both sides — Linux `src/libwarden/config.zig`,
> `config/warden-config.example.json`, `guardian-shield-v9/guardian_shield_loader.zig`
> (`ViolationEvent`), `src/zig_sentinel/outputs.zig` (`JsonLogOutput`),
> `src/zig_sentinel/emoji_sanitizer.zig`; macOS `ShieldConstants.swift`,
> `ShieldEvent.swift`, `DNSPolicyStore.swift`, `JailProfile.swift`, and a skim of
> `NetworkApprovalManager.swift` + `FilterDataProvider.swift`. The unified
> field names are a NEW contract; neither codebase emits exactly this shape yet.
> Adopting it is the Phase-3 work this file commits both sides to.

---

## 1. Shared Policy Schema (`guardian-policy.json`)

One document that the Linux BPF-LSM loader / `libwarden` config parser and the
macOS extension can both consume. It is a superset reconciliation of:

- Linux `RawConfig` (`config.zig`): `global`, `protection.protected_paths[]`
  (`path`, `description`, `block_operations[]`), `protection.whitelisted_paths[]`,
  `directory_protection` (`protected_roots[]`, `protected_patterns[]`),
  `process_exemptions.exempt_processes[]`, `process_restrictions`, `advanced`.
- macOS: `protected-paths.json`, `network-rules.json`
  (`{mode: whitelist|blacklist, hosts[]}`), `denylist.json`, `dns-policy.json`
  (`DNSPolicyStore.Policy` = `{mode: allow|deny, block[], allow[]}`), and the
  `JailProfile` model (`stance`, `allowTools[]`, `escalateCommands[]`,
  `blockPaths[]`, `netMode`, `dnsMode`…).

```jsonc
{
  "schema": "guardian.policy/v1",
  "meta": {
    "enabled": true,
    "mode": "enforce",              // "enforce" | "audit" | "observe"
    "log_level": "normal",         // debug|normal|verbose  (Linux global.log_level)
    "os_target": "any"             // "any" | "linux" | "macos" — informational
  },

  // ---- FILE PROTECTION (both OSes) --------------------------------------
  // Linux: enforced by libwarden/BPF-LSM. macOS: FilterDataProvider AUTH vnode.
  "protected_paths": [
    {
      "path": "/etc/",
      "description": "System configuration",
      "mode": "blacklist",          // "blacklist" = block listed ops here (default)
                                    // "whitelist" = allow ONLY listed ops here
      // Unified op vocabulary (superset of libwarden block_operations +
      // ShieldEvent types). Each op is delete|read|write-class:
      "block_operations": ["unlink","unlinkat","rmdir","rename","renameat",
                            "open_write","truncate","ftruncate",
                            "symlink","link","mkdir"],
      // Optional finer intent flags (map onto block_operations for OSes that
      // can't express the full syscall list — e.g. macOS AUTH events):
      "deny": { "delete": true, "write": true, "read": false }
    }
  ],
  "whitelisted_paths": [
    { "path": "/proc/self/", "description": "Process-specific proc entries" },
    { "path": "/tmp/",       "description": "Temp dir" }
  ],
  "directory_protection": {            // Linux directory_protection; macOS = path prefixes
    "enabled": true,
    "protected_roots":    ["/home/founder/work"],
    "protected_patterns": ["**/.git"]
  },

  // ---- AGENT / PROCESS IDENTITY (both OSes) -----------------------------
  // Reconciles Linux process_exemptions + process_restrictions with macOS
  // JailProfile.allowTools/escalate/block + responsiblePID attribution.
  "agents": {
    "exempt_processes": ["cc","ld","zig","git"],   // Linux process_exemptions
    "restricted_processes": [                        // Linux process_restrictions
      { "name": "node", "restrictions": { "block_tmp_execute": true } }
    ],
    // Unified agent-tree identity: attribute an op to the RESPONSIBLE process
    // (the agent that spawned the tree), not just the immediate pid. macOS
    // already has this via responsiblePID; Linux gains it via BPF task-tree walk.
    "identify_by": "responsible_process",   // "pid" | "responsible_process"
    "command_rules": [                       // macOS JailProfile.escalate/block, arg-aware
      { "binary": "rm", "args": ["-rf"], "verdict": "escalate" },
      { "binary": "git", "args": ["reset","--hard"], "verdict": "escalate" }
    ]
  },

  // ---- NETWORK (macOS today; Linux target) ------------------------------
  // macOS: NetworkApprovalManager + content filter. Linux: TARGET (zig_http_sentinel).
  "network": {
    "mode": "blacklist",             // "whitelist"|"blacklist" (macOS network-rules.json)
    "allow": ["api.anthropic.com"],
    "deny":  ["telemetry.example.com"],
    "prompt_on_unknown": true        // macOS approval popup; Linux TARGET
  },

  // ---- DNS (macOS today; Linux target) ----------------------------------
  // macOS: DNSPolicyStore.Policy consumed by DNSProxyProvider.
  "dns": {
    "mode": "allow",                 // "allow" = block-known-bad; "deny" = allowlist-only
    "block": ["doubleclick.net"],
    "allow": [],
    "doh_upstream": "https://dns.quad9.net/dns-query"   // macOS-implemented; Linux TARGET
  },

  // ---- ADVANCED (Linux advanced{}; macOS ignores unknown keys) ----------
  "advanced": {
    "canonicalize_paths": true,
    "allow_symlink_bypass": false,
    "notify_auditd": true,
    "auditd_key": "libwarden_block"
  },

  // ---- PER-OS EXTENSION BLOCKS (each side reads only its own) ------------
  "linux": {
    "fork_bomb": { "enabled": true, "max_children_per_sec": 50 },  // libwarden_fork
    "input_hid": { "enabled": true, "device": "/dev/input/event5" },// input_sovereignty
    "emoji_sanitizer": { "enabled": true, "zwc_density_threshold": 0.15 }
  },
  "macos": {
    "jail_profiles_ref": "jail-profiles.json",   // JailProfile store
    "app_group": "group.io.quantumencoding.workspace",
    "shared_data_dir": "/Library/Application Support/GuardianShield"
  }
}
```

### Reconciliation notes

- **`block_operations` vocabulary is the union.** Linux emits the exact syscall
  names; macOS ES `AUTH` events map to the coarse `deny.{delete,read,write}`
  flags (an `AUTH_UNLINK`/`AUTH_RENAME` → `delete`, `AUTH_OPEN` write →
  `write`). A loader on each OS lowers the unified doc to its native form.
- **`mode: whitelist|blacklist` per path** subsumes libwarden's implicit
  "protected = blacklist, whitelisted = allow" split AND Metatron's
  `network-rules.json` mode flag — one flag, two subsystems.
- **Agent identity is unified on `responsible_process`.** This is the
  "unified agent-process-tree identity" parity item: macOS supplies it free
  (`responsiblePID`); Linux must add a BPF task-ancestry walk to populate it.
- **`network` + `dns` are macOS-authoritative today.** Linux carries the keys
  but only `zig_http_sentinel` (HTTP host filtering, currently excluded from the
  build for Zig-0.16 drift) partially implements them — see §3.
- **Unknown-key tolerance is mandatory both ways.** Linux `config.zig` already
  parses with `ignore_unknown_fields = true`; macOS `JSONDecoder` drops unknown
  keys (relied on by `JailProfile` Phase-B). So the per-OS extension blocks are
  safe to ship before the other side implements them.

---

## 2. Shared Event Schema (`guardian.event/v1`, JSONL)

One violation/telemetry record so a single dashboard/log consumer works for both
OSes. Reconciles:

- Linux `ViolationEvent` (`guardian_shield_loader.zig`): `pid`, `uid`, `comm`,
  `event_type`, `path`, `target_path`, `error_code`, `timestamp` (ns).
- Linux `zig_sentinel` `JsonLogOutput` line: `{timestamp, severity, type, pid,
  syscall, observed, expected, stddev, z_score, message}`.
- Linux `emoji_sanitizer` `EmojiInfo`: `codepoint, expected_bytes,
  actual_bytes, result, offset, zwc_count, zwc_density`.
- macOS `ShieldEvent`: `timestamp` (epoch double), `type`, `path`,
  `processName`, `pid`, `ppid`, `responsiblePID`, `decision`, `category`,
  `correlationId`, plus the `DecisionClass` taxonomy (`blocked` / `wouldBlock` /
  `allowed` / `observed`).

```jsonc
{
  "schema": "guardian.event/v1",
  "ts": 1752800000.123,          // epoch seconds (double). Linux converts ns→s.
  "os": "linux",                 // "linux" | "macos"
  "type": "unlink",              // unified type vocab (see below)
  "category": "file",            // file | net | dns | process | input | emoji | agent_msg
  "decision": "blocked",         // raw decision string (OS-native)
  "decision_class": "blocked",   // blocked | would_block | allowed | observed
                                 //   (macOS ShieldEvent.classify(); Linux sets directly)
  "threat_level": "high",        // none|low|medium|high|critical  (maps sentinel z_score/severity)
  "path": "/etc/passwd",
  "target_path": "",             // rename/link destination (Linux target_path)
  "process": {
    "pid": 4242,
    "ppid": 4200,
    "responsible_pid": 4100,     // agent-tree root (macOS responsiblePID; Linux BPF walk)
    "comm": "rm",                // Linux comm / macOS processName
    "uid": 1000
  },
  "error_code": 1,               // Linux errno on the blocked syscall; 0/absent on macOS
  "correlation_id": null,        // macOS agent_msg dedup / provenance tie-back
  "detail": {                    // OPTIONAL type-specific payload (one of):
    // sentinel anomaly (zig_sentinel JsonLogOutput):
    "syscall": 87, "observed": 12, "expected": 2.1, "stddev": 0.8, "z_score": 12.4,
    // emoji stego (emoji_sanitizer EmojiInfo):
    "codepoint": 128512, "expected_bytes": 4, "actual_bytes": 9,
    "result": "oversized", "zwc_count": 5, "zwc_density": 0.22,
    // net/dns:
    "host": "telemetry.example.com"
  },
  "message": "libwarden blocked unlink on protected path"
}
```

### Unified `type` vocabulary

Superset of macOS `ShieldEvent.type` and Linux `EventType`/sentinel outputs:

`exec`, `fork`, `exit`, `unlink`, `rename`, `create`, `write`, `truncate`,
`open`, `net_connect`, `net_block`, `net_dns`, `net_dns_block`, `net_exfil`,
`secret_read`, `agent_command`, `agent_msg`, `input_hid` *(Linux/HID, new)*,
`emoji_stego` *(Linux sentinel, new)*, `fork_bomb` *(Linux, new)*,
`sentinel` *(anomaly)*.

### Reconciliation notes

- **`decision_class` is the canonical UI bucket.** macOS already computes it
  (`ShieldEvent.classify`, ~14 raw strings → 4 classes). Linux currently only
  prints `BLOCKED`/`allowed`; it must emit `decision_class` directly (its
  enforcement is binary today, so `blocked`/`allowed` only, `would_block` when
  `meta.mode == "audit"`).
- **Time:** unified `ts` is **epoch seconds (double)** — macOS
  `timeIntervalSince1970` native; Linux divides its ns `ViolationEvent.timestamp`
  by 1e9. (Per CLAUDE.md §6: wall-clock `ts` is a wire timestamp for the
  dashboard, NOT a security check — no expiry logic keys off it.)
- **`threat_level`** is derived, not native: Linux sentinel maps `z_score`
  bands / `severity`; hard file blocks default `high`; macOS maps
  `decision_class`+`type` (e.g. `net_exfil`/`secret_read` → `critical`).
- **`responsible_pid`** is the shared join key for agent-tree attribution
  (§ policy `agents.identify_by`).
- **Transport:** append-only JSONL, one object per line, matching Metatron's
  `events-history.jsonl` / `shield-logs.jsonl` convention (`ShieldConstants`).
  Linux writes to `/var/log/guardian/events.jsonl`; a per-OS collector can ship
  both to one dashboard.

---

## 3. Capability Parity + Porting Plan

| Capability | Linux status | macOS status | Porting action |
|---|---|---|---|
| **File AUTH protection** (delete/write/rename guard) | Shipping — `libwarden.so` + BPF-LSM (`guardian-shield-v9`) | Shipping — `FilterDataProvider.swift` ES `AUTH` | None. Converge on §1 `protected_paths` schema both sides parse. |
| **Fork-bomb limiter** | Shipping — `src/libwarden_fork` (`libwarden-fork.so`) | **Absent** | **Port → macOS.** No ES fork-rate primitive; implement in the extension by counting `ES_EVENT_TYPE_NOTIFY_FORK` per responsible-pid over a sliding window and killing the offending tree (host app already tracks process trees). Config: `linux.fork_bomb` → new `macos.fork_bomb`. |
| **Unicode/emoji-stego sanitizer** | Shipping — `zig_sentinel/emoji_sanitizer.zig` + `emoji_database.zig` (oversized / undersized / ZWC-smuggling detection) | **Absent** | **Port → macOS.** Pure-logic detector (no kernel dep). Reimplement in Swift, or (faster) compile the Zig module to a static lib and call it from the extension over the clipboard/paste + `write` event stream. Emits `emoji_stego` events (§2). |
| **USB-HID input sovereignty** | Present — `src/input_sovereignty/input-guardian.zig` (Linux `/dev/input/eventX`, Grimoire pattern engine) | Partial — same file `comptime`-switches to `IOHIDManager`, but only built by `libmacwarden/build.zig` (being retired) | **KEEP + decouple.** Give `input_sovereignty/` its own `build.zig` (lift the `input-guardian` stanza from `libmacwarden/build.zig`, make IOKit/CoreFoundation links macOS-conditional). Then macOS gets HID parity by targeting `-Dtarget=…-macos`. Emits `input_hid` events. |
| **DNS proxy / DoH filtering** | **Stub only** — no DNS proxy in tree | Shipping — `DNSProxyProvider.swift` + `DNSPolicyStore.swift` (curated + live abuse.ch/StevenBlack feeds, `dns-policy.json`) | **Port → Linux.** Implement a local resolver (systemd-resolved hook or a small forwarding proxy) that reads unified §1 `dns` block; reuse Metatron's feed-fetch/parse logic (hosts-format → domain set). Emits `net_dns` / `net_dns_block`. |
| **Network approval-popup UX** | **Stub only** — `zig_http_sentinel` does HTTP-host filtering but is excluded from the build (Zig-0.16 drift) | Shipping — `NetworkApprovalManager.swift` (pending-approvals poll → user prompt → dynamic allowlist/denylist) | **Port → Linux.** Repair `zig_http_sentinel` for Zig 0.16, then add the file-IPC approval contract (`pending-approvals.json` → prompt → `dynamic-allowlist.json`) mirroring Metatron's shape so ONE UX model spans both. Emits `net_connect`/`net_block`. |
| **Unified agent-process-tree identity** | Partial — `process_exemptions` / `process_restrictions` by `comm` only | Shipping — `responsiblePID` on every `ShieldEvent`; `JailProfile` arg-aware command rules | **Port → Linux (both converge).** Linux adds a BPF task-ancestry walk to populate `responsible_pid`; both adopt §1 `agents` (`identify_by: responsible_process`, arg-aware `command_rules`). Metatron's `JailProfile.CommandRule.matches()` is the reference matcher. |
| **Behavioral anomaly / eBPF sentinel** | Shipping — `zig_sentinel` (baseline, z-score, Grimoire patterns) | Partial — baseline/behavioral in extension | Converge event output on §2 `sentinel` + `detail.z_score`; no port, just schema alignment. |
| **Cognitive telemetry (CTK)** | Present — `cognitive_telemetry_kit` (UDP :9847) | Present — `ShieldConstants.ctkUDPPort = 9847`, `cognitive-state.json` | Already aligned on port 9847. No action. |

Direction legend: **Port → macOS** = Linux-unique, bring to Metatron.
**Port → Linux** = macOS-unique, bring to the Zig tree. **Converge** = both
exist, align on the shared schema only.

---

## 4. Migration Note — retired prototypes

Three abandoned macOS ES/NE prototypes in the Linux tree are RETIRED. Each now
carries a `DEPRECATED.md`. All three are **unreferenced by the main
`guardian_shield/build.zig`** (which builds only Linux artifacts) and were
verified to carry stale single-developer markers (hardcoded `/Users/director/...`
paths).

| Retired prototype | What it tried to be | Replaced by |
|---|---|---|
| `src/guardian-esd/` | macOS ES daemon (Swift Package) | Metatron `FilterDataProvider.swift` (ES `AUTH`) |
| `src/network-filter/` | macOS NE content filter (Swift Package) | Metatron `NetworkApprovalManager.swift` + `DNSProxyProvider.swift` + content filter |
| `src/libmacwarden/` | macOS ES reimpl in Zig (`es-warden`, `libmacwarden.dylib`) | Metatron system extension |

**`src/input_sovereignty/` is NOT retired** — it is the unique USB-HID
capability (§3, KEEP). The only snag: `libmacwarden/build.zig` is currently the
sole build recipe for `input-guardian`. Resolve the coupling (give
`input_sovereignty/` its own `build.zig`) **before** deleting `libmacwarden/`.
See `src/libmacwarden/DEPRECATED.md` for the exact stanza to lift.

---

## 5. What this contract commits both codebases to

1. **One policy document** (`guardian.policy/v1`, §1) — Linux `libwarden`/BPF
   loader and the Metatron extension each lower the SAME JSON to native form;
   per-OS primitives live in namespaced `linux`/`macos` blocks; both parsers
   tolerate unknown keys.
2. **One event record** (`guardian.event/v1`, §2, JSONL) — with a shared
   `decision_class` taxonomy, unified `type` vocabulary, epoch-seconds `ts`, and
   `responsible_pid` agent-tree attribution — so ONE dashboard consumes both.
3. **A directional porting plan** (§3): fork-bomb + emoji-stego + HID → macOS;
   DNS/DoH + network-approval UX → Linux; `responsible_pid` agent identity →
   both.
4. **Retirement of the three dead prototypes** (§4), preserving the unique
   `input_sovereignty` build via an explicit decoupling step.
