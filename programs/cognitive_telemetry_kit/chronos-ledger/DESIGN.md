# Chronos Ledger — tamper-evident accountability log for AI agents

Status: **design locked, pre-implementation** (2026-06-14)

The Chronos *tick/squash* system (see `../chronos-hook/AGENT-GUIDE.md`) gives
humans clean git history. The Chronos *Ledger* is the opposite-purpose sibling:
an **append-only, hash-chained, signed record of every agent action**, built to
detect prompt-injection / exfiltration chains such as:

> `read maliciousfile.md` → `search sshcredentials` → `send https://evildomain`

The two share one capture point but live on separate planes. The tick commit is
squashable; the ledger event is permanent and leaves the box before the agent
can touch it.

---

## Scope: who owns what

| Concern | Owner |
|---|---|
| **Stamping** — capture, structure, hash-chain, sign, deliver events | **chronos-ledger** (this) |
| **Enforcement** — block egress, ground-truth via syscalls/connections | **Guardian Shield** (macOS ES + Network Extension) / cloud nftables |
| **Detection + storage** — ingest, verify, domain-segmented taint, alert | **qai proxy** (`api.quantumencoding.ai`) |

chronos-ledger does **not** block and does **not** decide policy. It produces a
log rich enough (`source_trust`, `dest_host`, content hashes) that the proxy and
Guardian Shield can implement domain-segmented taint and enforcement.

---

## Threat model the design must survive (the audited agent is adversarial)

A prompt-injected agent will try to forge, mute, or bypass the log. Therefore:

1. **The audited process never holds the signing key.** Chaining + signing
   happen in a *privileged sink* the agent cannot read or impersonate. The
   in-agent client only emits raw events.
2. **Silence is evidence.** Per-session monotonic `seq` + chain `prev` links mean
   a killed/mocked client leaves a detectable gap or fork at the proxy.
3. **The OS is the tiebreaker.** Guardian Shield's ES/NetExt observe real
   `open()`/`connect()`. When the agent's self-reported ledger diverges from the
   kernel's view, *that divergence is the alarm.* (Owned by Guardian Shield;
   chronos-ledger just makes the agent's claims comparable.)

### Two-process split

```
 ┌─────────────────────────┐        local UDS / XPC         ┌──────────────────────────────┐
 │ agent (unprivileged)     │  raw event (no keys, no chain) │ privileged ledger sink         │
 │  emit-client  ───────────┼───────────────────────────────▶  chain → Merkle head → sign    │
 │  (Claude hook / app FFI) │                                │  root at milestones → ship     │
 └─────────────────────────┘                                └───────────────┬───────────────┘
                                                                             │
                          cloud: privileged user + netns,                    ▼
                          nftables forces egress → proxy            qai proxy  /  user bundle
                          macOS: the sink IS Guardian Shield
```

- **Cloud build:** agent runs as unprivileged user; the ledger sink runs as a
  separate privileged user with its own network namespace; **nftables forces all
  agent egress through the proxy**, so a raw-socket bypass is structurally
  impossible (Addition 1).
- **macOS (Cosmic Duck):** Guardian Shield's privileged ES client is the sink and
  the enforcement anchor; the app's agents call the emit-client which hands off to
  GS over XPC.

---

## Event schema (v1)

Canonical JSON, one object per action. `this` and `sig` are computed by the
*sink*, never the client.

```jsonc
{
  "v": 1,
  "seq": 42,                       // uint64, per-session monotonic (gap = tamper signal)
  "prev": "<hex>",                 // previous chain head; genesis = 64 zeros
  "this": "<hex>",                 // Hᵢ = SHA-256(prev ‖ canonical(event\{this,sig}))
  "t_mono_ns": 12950034901,        // monotonic — for ordering (never trust wall clock for order)
  "t_wall_ms": 1750000000000,      // wall — for human display only
  "agent": { "id": "...", "session": "...", "model": "claude-opus-4-8", "user": "rich?" },
  "kind": "read|write|exec|net|search|think|other",
  "act": {
    // read:   { "path","sha256","bytes","source_trust":"repo|external|web|user" }
    // write:  { "path","sha256","bytes" }
    // exec:   { "argv":[...], "cwd" }
    // net:    { "method","url","dest_host","dest_ip","req_sha256","req_bytes","resp_sha256","resp_bytes" }
    // search: { "query_sha256" }            // hash, not the query — it may carry secrets
    // think:  { "state":"<gerund>", "summary":"<intent line>" }
  },
  "taint": { "tainted": true, "sources": ["web:example.com/x"] },   // rolling; decision is the detector's
  "milestone": true,               // net | write | session-end → trigger root signing
  "sig": {                         // present ONLY on milestone-signed events
    "alg": "ML-DSA-65", "over": "this", "value": "<base64>", "key_id": "<pub-fingerprint>"
  }
}
```

**Store hashes, not content.** The audit log of a credential theft must never
itself leak the credential. Paths/URLs are kept (needed for detection); file
bodies, request/response bodies, and search queries are SHA-256 only.

---

## Cryptographic ledger (Addition 3)

- **Chain:** `H₀ = 0…0`; `Hᵢ = SHA-256(Hᵢ₋₁ ‖ canonical(eventᵢ))`. Each head
  commits to the entire history before it — modify any past event and every later
  head changes.
- **Signing:** ML-DSA-65 (`../../zig-quantum-encryption/src/ml_dsa.zig`, already
  audited) signs the **current head only at milestones** — outbound `net`, file
  `write`, session start/end, and a max-interval heartbeat. O(1) signatures per
  batch instead of O(N) per event, with identical tamper-evidence (a forged
  intermediate invalidates the next signed head).
- **Encryption in transit/at rest:** ML-KEM-768 (`ml_kem_api.zig`) wraps the
  stream so the ledger — a map of what every agent read and where it sent data —
  isn't a new exf(iltration) target.

---

## Delivery (per the storage decision)

- **Cloud, stateless:** stream off-box. **Milestone events flush immediately**
  (synchronously, carrying the signed head); benign `read`/`think` ticks
  micro-batch (≤N events or ≤T ms). On process exit, force-flush + sign a
  `session-end` root. No reliance on local disk surviving the container — the
  proxy is the source of truth and the chain exposes any dropped/forged event.
- **App user (remote work):** accumulate the signed chain locally; at
  **session end deliver the notes log + final signed root + pubkey to the user**
  for inspection (human-readable render of `think.summary` + the action list,
  plus a `verify` that re-walks the chain and checks the ML-DSA signature).

---

## Identity / keys

- **Cloud:** ephemeral keypair generated at sink boot, held in memory only;
  pubkey attested to the proxy (signed by the build-image root key or boot
  attestation) so the proxy authenticates who emitted each event.
- **App:** user keypair in the macOS keychain; pubkey known to the proxy /
  co-anchored by Guardian Shield.

---

## Domain-segmented taint (Addition 2 — detector-side, fields we provide)

A flat "untrusted-read → credential-touch → egress = block" deadlocks on normal
work (a web search then a legit `git push` with a GitHub token). The detector
(proxy/GS) instead enforces: **once a session is tainted, egress is confined to a
cryptographically pinned allowlist** (the model API host, `api.github.com`, the
configured DB host…); egress to any unregistered domain/raw IP while tainted is
blocked. chronos-ledger's job is only to stamp the inputs that make this
decidable: `source_trust` on every read, `dest_host`/`dest_ip` on every `net`,
and the rolling `taint` set.

---

## First implementation increment

Cloud streaming path (self-contained, no Guardian Shield internals):

1. `chronos_ledger` Zig lib: event schema + canonical encoder + rolling chain +
   ML-DSA-65 milestone signing. Reused by client, sink, and proxy verifier.
2. **emit-client**: extend `chronos-hook` to also emit a structured v1 event
   (full args + content hashes) over a local UDS — no keys, no chaining.
3. **ledger-daemon** (privileged reference sink): receive over UDS, chain, sign
   roots at milestones, `POST /v1/ledger` (batched; milestones immediate).
4. Proxy stub: verify chain + signature, store append-only, run the taint /
   egress-allowlist / sensitive-path checks, alert on the example chain.

macOS reuses the same emit-client; the sink role is Guardian Shield over XPC.
