import ChronosLedger
import Foundation

// XPC Service entry point. macOS launches this on demand when the app first
// connects and tears it down when the app quits — no launchctl, no sudo, App
// Store-compliant. The sink + signing key live ONLY in this sandboxed helper.

final class SinkService: NSObject, NSXPCListenerDelegate, ChronosSinkProtocol {
    let sink: ChronosSink

    // Share the ledger with the main app via an App Group container so the app
    // can surface "view audit log"; fall back to the service's own Application
    // Support if no group is configured.
    static let appGroup = "group.io.quantumencoding.cosmicduck"

    override init() {
        let fm = FileManager.default
        let base: URL =
            fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("ChronosLedger", isDirectory: true)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChronosLedger", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            sink = try ChronosSink(
                keyURL: base.appendingPathComponent("key"),
                ledgerURL: base.appendingPathComponent("ledger.ndjson"))
        } catch {
            NSLog("ChronosSink init failed: \(error)")
            exit(EXIT_FAILURE)  // a sink that can't sign must not pretend to
        }
        super.init()
    }

    // One-way: chain + sign + persist. Never replies → never blocks the app.
    func emit(_ eventJSON: Data) { sink.ingest(eventJSON) }

    func ledgerInfo(withReply reply: @escaping (String, String) -> Void) {
        reply(sink.ledgerPath, sink.publicKeyHex)
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ChronosSinkProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
}

let delegate = SinkService()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()  // does not return
