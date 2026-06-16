# Integrating chronos-ledger into a Rust app ("chronos, built in")

This is the emit-client SDK for the Chronos accountability ledger. Every
sensitive action your app's agent takes becomes a structured, tamper-evident
event on the ledger — without the app holding any key or doing any crypto.

## 1. Depend on it

```toml
# Cargo.toml
[dependencies]
chronos-ledger = { path = "../poly-repo/zig-forge/programs/cognitive_telemetry_kit/chronos-ledger/rust" }
```

## 2. One emitter for the app

```rust
use chronos_ledger::{Chronos, Event, Trust};

// agent name = how this host shows up on the ledger / leaderboard.
let chronos = Chronos::new("rust_gui")        // socket from $CHRONOS_LEDGER_SOCKET
    .model(settings.openai_model.clone())     // optional
    .session(session_id);                     // optional
```

`emit()` is **non-blocking and best-effort** — safe to call straight from the UI
thread. If the sink (`ledger-daemon` / Guardian Shield) isn't running, the call
is a cheap no-op; nothing stalls or panics.

## 3. Where to call it in rust_gui (the approval flow)

The choke point is already there: `chat.rs` runs every tool through
`execute_tool` after the user approves. Emit one event per action right there, so
the ledger records exactly what ran and that a human approved it.

```rust
// in approve_tool_call(), right after execute_tool(&approval.call, …):
let ev = match approval.call.name.as_str() {
    "read_workspace_file" => Event::read(arg_path(&approval.call)).trust(Trust::Repo),
    "write_file" | "apply_patch" => Event::write(arg_path(&approval.call)),
    "run_command" => Event::exec(arg_command(&approval.call)),
    other => Event::new(chronos_ledger::Kind::Other).tool(other),
}
.tool(&approval.call.name);
chronos.emit(&ev);

// in deny_tool_call(): denials are security-relevant — record them too.
chronos.emit(&Event::new(Kind::Other).tool(&approval.call.name).state("denied"));
```

Guidance:

- **`trust`** — mark reads of untrusted input (`Trust::External` for out-of-repo
  files, `Trust::Web` for fetched content). That's what arms the detector's
  domain-segmented taint, so a later egress to an unknown host is flagged.
- **`net`** — for any outbound HTTP (including the model API call itself), use
  `Event::net(url)`; the host is auto-extracted for egress-allowlist checks.
- **Don't** set `seq`/`prev`/`this`/`sig` — the sink owns the chain + signatures.

## 4. Verify it's flowing

Run the live demo (emits an exfil-shape chain) against the sink:

```sh
# sink
CHRONOS_LEDGER_SOCKET=/tmp/cl.sock CHRONOS_LEDGER_OUT=/tmp/cl.ndjson ledger-daemon &
# app side
CHRONOS_LEDGER_SOCKET=/tmp/cl.sock cargo run --example emit
# audit
CHRONOS_LEDGER_OUT=/tmp/cl.ndjson ledger-verify     # -> EXFIL_CHAIN, verdict critical
```

## Notes

- **No FFI, no `libchronos_ledger.a`.** The client is pure Rust (`serde_json` +
  `UnixDatagram`). The Zig sink does canonicalization, hash-chaining, and ML-DSA
  signing. Verified cross-language: Rust-emitted events chain + verify under the
  Zig `ledger-daemon`/`ledger-verify`.
- **macOS / Swift apps (e.g. CosmicDuckOS):** the same wire contract works from
  any language — either add a thin Swift `UnixDatagram` emitter (~30 lines,
  same JSON body) or call this crate over a small C-ABI shim. The body shape is
  the single source of truth (see `WireBody` in `src/lib.rs`).
