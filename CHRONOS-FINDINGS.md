# Chronos Findings — origin/main & pre-fuzz-merge review

Investigated from branch `fuzz-divergeance` (divergence point `7c0e108`). Nothing was
merged or pushed.

## Branch topology since divergence (7c0e108)

- **`origin/pre-fuzz-merge`** (new, at `396fd3f`) is a **safety snapshot of old main
  taken just before the fuzz-branch work was merged in** — its tip is exactly the old
  main head. It contains the "Batch 17–51" hardening series (security purges,
  FIPS 203/204 KAT work, financial-decimal migration, PDF generator modularization)
  and nothing newer.
- **`origin/main`** (now `9ea5f63`) is 224 commits ahead of our divergence point: the
  pre-fuzz-merge content plus 143 newer commits — the fuzz-found bitcoin parser fixes,
  a large PDF generator/extractor arc (encryption, ML-DSA seal, PDF→MDX, Liquid Glass
  theme), terminal_mux/zterm, zig_inference embeddings, and **~28 commits of new
  Chronos work from the Mac side**.
- Our branch's headline fix already exists on main as its own commit (`3c9d392`,
  witness-array leak + overflow guard), so `fuzz-divergeance` carries 12 commits main
  doesn't have by patch-id — mostly CHRONOS ticks around the same change. This branch
  is effectively superseded by main.

## What the new mac Chronos stuff does

**1. `get-cognitive-state` was rewritten as a dual-backend script**
(`programs/chronos_engine/scripts/get-cognitive-state`). It now switches on `uname`:
Linux keeps the sqlite cognitive-watcher DB (V2 `cognitive_sessions` first, legacy
`raw_content` fallback — all three of the old NOT-DETECTED fixes preserved), while
**macOS reads per-PID cache files** `/tmp/cognitive-state-<pid>` (format
`<unix_ts>:<state>`, 30s staleness window) written by a DYLD `write()` interposer,
`libcognitive-capture.dylib` — reading the Linux DB on macOS was the bug behind every
Mac NOT-DETECTED stamp. New: env overrides (`COGNITIVE_DB_PATH`, `COGNITIVE_CACHE_DIR`,
`COGNITIVE_STATE_TIMEOUT_SECS`), a `--check`/`--init` preflight subcommand, Linux auto
schema-init, and a `/proc`-free process walk via `ps` on Darwin. `chronos-run.zig` is a
companion PTY wrapper that taps spinner gerunds (ANSI-aware) for capture.

**2. The tick hook (`chronos-hook`) gained new behaviors:** a **.gitignore-first
guard** (no root `.gitignore` → the hook refuses to stage and prints
`[CHRONOS ERROR]`), **per-agent stamping** (ticks from non-Claude agents get a
`[CHRONOS:<agent>]` prefix, agent resolved from process ancestry with `CHRONOS_AGENT`
override; PID recorded in tick + ledger), a 200-byte cap on tick detail (Codex
`apply_patch` dumped whole patches), Codex hook-payload support, and best-effort
ledger emission per tick.

**3. Auto-push is gone — replaced by `chronos-push`.** In a chronos-enabled repo
(`git config chronos.enabled=true`), `git push "msg"` folds all trailing
`[CHRONOS(:agent)]` ticks into one summary commit (replaying real commits with
byte-identical trees, asserted before touching the ref) and then pushes; any flagged
push (`-u`, `--force`) passes through to real git untouched.
`chronos-enable-repo`/`chronos-disable-repo` manage it, and `AGENT-GUIDE.md` documents
the one trap: `git add .` in ticks tracks build artifacts, and neither `.gitignore`
nor the fold removes already-tracked bloat — `git rm -r --cached` is the recipe.

**4. Brand-new subsystem: `chronos-ledger`** — a tamper-evident agent-accountability
ledger. Zig core does RFC 8785 canonical JSON + SHA-256 hash-chaining + ML-DSA-65
milestone signing; a privileged `ledger-daemon` receives events over a Unix datagram
socket and writes NDJSON; `ledger-verify` runs a detection engine (chain integrity,
domain-segmented taint, sensitive paths, egress allowlist — it flags
read→search→egress exfil chains). Emit clients exist in Zig, **pure Rust**
(`UnixDatagram` + serde, no FFI — explicitly written for `rust_gui`), and Swift
(CosmicDuckOS package with an in-app XPC sink, `AuditLogView`, and `UDSLedgerListener`
to fold spawned-CLI-agent emits into the app ledger).

## What the diary session (~/rust_programs) needs to know

- **Nothing on this Linux box has changed yet.** The installed
  `/usr/local/bin/get-cognitive-state` (symlink into guardian-shield) is the older
  Linux-only version and is functionally equivalent on Linux; `chronos-push` is not
  installed, so `git push` here is still a raw push and ticks are not auto-folded; the
  installed `chronos-hook` binary is from Nov 2025 and predates all of the above.
  Current workflows keep working as-is.
- **If/when the new toolkit gets installed here**, three things bite: (a) repos
  **must have a root `.gitignore`** or every tick fails with `[CHRONOS ERROR]` —
  several ~/rust_programs projects should be checked before tooling runs there;
  (b) anything that parses tick prefixes must accept `[CHRONOS:<agent>]`, i.e. match
  `^\[CHRONOS(:[a-z0-9_-]+)?\]`, not just `^\[CHRONOS\]`; (c) tick detail is truncated
  to 200 bytes, so don't rely on full command text in commit messages. The hook's
  ledger emits are best-effort no-ops when no `ledger-daemon` socket exists — harmless.
- **If the diary session touches `rust_gui`**: the ledger's Rust crate is the intended
  integration — path-dep on
  `zig-forge/programs/cognitive_telemetry_kit/chronos-ledger/rust`, emit one event per
  approved tool at the `execute_tool` choke point (and on denials), mark untrusted
  reads with `Trust::External`/`Trust::Web`, use `Event::net(url)` for outbound HTTP,
  and never set `seq`/`prev`/`this`/`sig` — the sink owns the chain. Socket comes from
  `$CHRONOS_LEDGER_SOCKET`; `emit()` is non-blocking and safe on the UI thread.
- The four copies of `get-cognitive-state` (zig-forge canonical,
  cognitive_telemetry_kit copy, guardian-shield installed copy, and now origin/main's
  rewrite) are **out of sync** — any future edit should propagate the new dual-backend
  version to all of them, per the existing keep-in-sync convention.

## Addendum (2026-07-10): terminal_mux / zterm + secrets CLI on this box

- `programs/terminal_mux` is built on local main (`zig build -Doptimize=ReleaseFast`
  in that dir): `zig-out/bin/{tmux,tmux-bench,zterm}` + `zig-out/lib/libterminal_mux.a`.
  All 62 unit tests pass (run them with `zig test -fllvm -lc src/lib.zig src/capi.zig`
  style — plain `zig build test` fails on this host because Debug's self-hosted linker
  can't handle gcc-16 crt1.o's SFrame relocations; ReleaseFast/LLD is unaffected).
- **Driving zterm** (`zterm server`, then `zterm cli …`): `send` types text with
  **no implicit Enter**, and a trailing `\n` in the text is stripped by the wire
  protocol — always follow `send <id> <text>` with `enter <id>`. `spawn`/`list` emit
  JSON; `list` carries pid+cwd. A spawn-hang bug (forked shell inherited the client
  socket, so the EOF-framed client blocked) is fixed on local main via FD_CLOEXEC —
  use a binary built from ≥ that commit.
- **Fresh zterm panes block at `Vault passphrase:`** — the login shell runs
  `eval $(secrets env)`. Interactively: `send <id> test` + `enter <id>`. Headless:
  export `SECRETS_PASSPHRASE` into the environment before spawning, which
  short-circuits every prompt in the secrets CLI.
- The **secrets CLI** (`~/tauri_apps/secrets-vault`, installed at
  `/usr/local/bin/secrets`) was pulled to `902dca1` and reinstalled: adds `gen`,
  `exec <project> -- <cmd>` (scoped child-only injection — the blessed pattern),
  `has`, `list --names-only`, write-only `inbox`, project grants
  (`authorize`/`revoke`), and pluggable GSM backend. `secrets env` still works but is
  deprecated and prints a loud warning; it fails closed when headless with no
  `SECRETS_PASSPHRASE`. Touch ID/keychain paths are macOS-only; Linux uses env var or
  TTY prompt.
