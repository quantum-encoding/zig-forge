# Bundling the Chronos sink as an XPC Service in CosmicDuckOS

The "Zero-Sudo" option: the tamper-evident, post-quantum-signed audit ledger ships
**inside `CosmicDuckOS.app`** as a sandboxed XPC Service. No installer, no
`launchctl`, no root, App Store-compliant. macOS launches the helper when the app
first connects and kills it on quit. The signing key lives only in the helper, so
a compromised agent in the main app can't read or forge it.

```
CosmicDuckOS.app
├─ Contents/MacOS/CosmicDuckOS          ← app: emits via XPCChronos
└─ Contents/XPCServices/
   └─ ChronosSink.xpc                    ← helper: links libchronos_ledger.a, signs, writes ledger
```

**Architecture note:** we do **not** bundle the `ledger-daemon` binary (that's a
UDS process — wrong IPC for XPC). The XPC service links the Zig **C-ABI**
(`libchronos_ledger.a`) and *is* the sink — same chain+sign core, driven by XPC
messages. Verified: Swift drives the C-ABI in-process and the output passes the Zig
`ledger-verify`.

## 0. Build the static lib

```sh
swift/build-apple-lib.sh        # → swift/Vendor/libchronos_ledger.a (repacked, gitignored)
```

Header stays at `chronos-ledger/include/chronos_ledger.h`.

## 1. Add the SwiftPM package

In `CosmicDuckOS.xcodeproj` → *Package Dependencies* → *Add Local…* →
`chronos-ledger/swift`. Add the **ChronosLedger** library to **both** the app
target and (next step) the XPC target — the service needs `ChronosSinkProtocol`.

## 2. Add the XPC Service target

*File → New → Target… → macOS → XPC Service.* Name **ChronosSink**, bundle id
**`io.quantumencoding.cosmicduck.ChronosSink`**. Then:

1. Delete Xcode's template `main.swift`; add these from `swift/xpc-service/`:
   `main.swift`, `ChronosSink.swift`.
2. **Build Settings → Objective-C Bridging Header** → `swift/xpc-service/bridge.h`.
3. **Header Search Paths** → `…/chronos-ledger/include`.
4. **Link Binary With Libraries** → `swift/Vendor/libchronos_ledger.a`.
5. **General → Frameworks and Libraries / Dependencies** → add **ChronosLedger**.
6. Use `swift/xpc-service/Info.plist` (sets `XPCService.ServiceType = Application`)
   and `ChronosSink.entitlements` (sandbox + App Group).

Xcode auto-embeds the `.xpc` into `Contents/XPCServices/` because the service is a
dependency of the app.

## 3. App Group (so the app can read the ledger)

The app and the service have **separate** sandbox containers; share the ledger via
an App Group. On **both** targets → *Signing & Capabilities → App Groups* → add
`group.io.quantumencoding.cosmicduck`. (`main.swift` writes to that group
container, falling back to Application Support if it's absent.)

## 4. Emit from the app

```swift
import ChronosLedger

let chronos = XPCChronos(
    serviceName: "io.quantumencoding.cosmicduck.ChronosSink",
    agent: "CosmicDuckOS")

// wherever the app / its agent acts (same Event API as the UDS Chronos):
chronos.emit(.read(path).trust(.external))
chronos.emit(.net(url).trust(.web))
chronos.emit(.write(savedPath).tool("apply_patch"))

// "View audit log":
chronos.ledgerInfo { ledgerPath, pubKeyHex in /* show / verify */ }
```

`emit` is fire-and-forget over XPC — never blocks the main thread; if the helper
isn't up yet, macOS spins it up on demand.

## 5. "View Audit Log" UI (drop-in)

The package ships `AuditLogView` — reads the signed NDJSON from the App Group
container and shows a verification banner (✓ chain intact / ⚠️ tampering at seq N)
plus the per-action history. Verification is delegated to the sink service (only
it has the key + the C-ABI verifier):

```swift
import ChronosLedger

// the shared group container path the sink writes to:
let ledgerURL = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.io.quantumencoding.cosmicduck")!
    .appendingPathComponent("ChronosLedger/ledger.ndjson")

AuditLogView(ledgerURL: ledgerURL) { await chronos.verifyLedger() }
```

`chronos.verifyLedger()` (on `XPCChronos`) round-trips to the service, which
re-walks the ledger with `cl_verify` and returns a `LedgerVerdict`
(`chainOk`/`sigsOk`/`firstBadSeq`). Validated: a one-byte body edit flips
`chainOk` to false and pins `firstBadSeq`.

## 6. Verify from the CLI too

Point the bundled `ledger-verify` (or the Zig one) at the group container's
`ChronosLedger/ledger.ndjson` — expect a clean chain, or `EXFIL_CHAIN` on an
actual injection. The `.pub` sidecar is the verifying key.

## Notes

- The same `ChronosSink.swift` is what we validated standalone against the Zig
  verifier — the XPC target just wraps it in an `NSXPCListener`.
- For **iOS** there are no XPC Services; there, link `ChronosSink.swift` directly
  into the app (in-process sink) and point the ledger at the app container, or use
  the UDS `Chronos` against a network sink.
