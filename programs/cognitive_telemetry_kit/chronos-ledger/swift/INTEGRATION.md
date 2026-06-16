# ChronosLedger (Swift) — "chronos, built in" for CosmicDuckOS

Native Swift emit-client for the Chronos accountability ledger. No Rust, no FFI,
no `libchronos_ledger.a` — pure Foundation + POSIX `AF_UNIX` datagram. Same wire
body as the Rust crate and `chronos-hook`, so the same Zig `ledger-daemon`
ingests, chains, and ML-DSA-signs Swift-emitted events (verified end-to-end).

## 1. Add to the Xcode project

In **CosmicDuckOS.xcodeproj** → *Package Dependencies* → *Add Local…* and pick:

```
poly-repo/zig-forge/programs/cognitive_telemetry_kit/chronos-ledger/swift
```

Then add the `ChronosLedger` library to the app target. (Or in a Package.swift:
`.package(path: "…/chronos-ledger/swift")` + product `"ChronosLedger"`.)

## 2. One emitter for the app

```swift
import ChronosLedger

let chronos = Chronos(agent: "CosmicDuckOS")     // socket from $CHRONOS_LEDGER_SOCKET
    .model(activeModelSlug)                       // optional
    .session(sessionID)                           // optional
```

`emit` is **non-blocking and best-effort** — call it straight from the main
thread. If the sink (`ledger-daemon` / Guardian Shield) isn't running, it's a
cheap no-op; nothing stalls or throws.

## 3. Emit per action

Wherever the app (or its hosted agent) takes a sensitive action:

```swift
chronos.emit(.read(filePath).trust(.external))          // reading untrusted input → taints session
chronos.emit(.exec("/usr/bin/git status"))              // a shell-out
chronos.emit(.net(requestURL).trust(.web))              // any outbound HTTP; host auto-extracted
chronos.emit(.write(savedPath).tool("apply_patch"))     // a file write/edit
```

- **`trust`** — mark reads of out-of-sandbox files `.external` and fetched
  content `.web`; that arms the detector's domain-segmented taint so a later
  egress to an unlisted host is flagged.
- **Don't** set `seq`/`prev`/`this`/`sig` — the sink owns the chain + signatures.

## 4. Verify it's flowing

```sh
CHRONOS_LEDGER_SOCKET=/tmp/cl.sock CHRONOS_LEDGER_OUT=/tmp/cl.ndjson ledger-daemon &
CHRONOS_LEDGER_SOCKET=/tmp/cl.sock swift run chronos-emit-demo
CHRONOS_LEDGER_OUT=/tmp/cl.ndjson ledger-verify        # -> EXFIL_CHAIN, verdict critical
```

## Notes

- **App Sandbox:** the app must be allowed to reach the sink's `AF_UNIX` socket.
  Put the socket somewhere the sandbox permits (a shared group container, or a
  path granted by a temporary-exception entitlement), and set
  `CHRONOS_LEDGER_SOCKET` accordingly. On macOS the privileged sink is Guardian
  Shield; for local testing the `ledger-daemon` binary works.
- **iOS:** the package builds for iOS too, but `AF_UNIX` egress is constrained —
  on-device you'd point the sink at an app-group container path.
- The wire body (`WireBody` in `Sources/ChronosLedger/Chronos.swift`) is the
  single source of truth, identical across the Zig hook, the Rust crate, and this
  package.
