#if os(macOS)
import Foundation

/// Client transport that emits to the **bundled XPC sink service** instead of a
/// UDS daemon. Use this inside CosmicDuckOS (where the sink ships in the .app);
/// use `Chronos` when talking to a separate `ledger-daemon`.
///
/// Same `emit(_:)` API as `Chronos`, so call sites are transport-agnostic. The
/// connection is lazy and auto-reconnects; emits are fire-and-forget and never
/// block the main thread.
public final class XPCChronos: ChronosEmitting, @unchecked Sendable {
    private let serviceName: String
    private let agent: String
    private let session: String?
    private let model: String?
    private let user: String?
    private let lock = NSLock()
    private var _connection: NSXPCConnection?

    /// - Parameter serviceName: the XPC service bundle id, e.g.
    ///   `"io.quantumencoding.cosmicduck.ChronosSink"`.
    public init(
        serviceName: String,
        agent: String,
        session: String? = nil,
        model: String? = nil,
        user: String? = nil
    ) {
        self.serviceName = serviceName
        self.agent = agent
        self.session = session
        self.model = model
        self.user = user
    }

    private func proxy() -> ChronosSinkProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if _connection == nil {
            let c = NSXPCConnection(serviceName: serviceName)
            c.remoteObjectInterface = NSXPCInterface(with: ChronosSinkProtocol.self)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self._connection = nil
                self.lock.unlock()
            }
            c.resume()
            _connection = c
        }
        return _connection?.remoteObjectProxyWithErrorHandler { _ in
            // Swallowed: a down service must never surface as an app error.
        } as? ChronosSinkProtocol
    }

    @discardableResult
    public func emit(_ event: Event) -> Bool {
        guard
            let data = Chronos.encode(
                event, agent: agent, session: session, model: model, user: user)
        else { return false }
        guard let proxy = proxy() else { return false }
        proxy.emit(data)
        return true
    }

    /// Fetch the sink's ledger path + public key (for a "view audit log" UI).
    public func ledgerInfo(_ reply: @escaping (String, String) -> Void) {
        guard let proxy = proxy() else { return reply("", "") }
        proxy.ledgerInfo(withReply: reply)
    }
}
#endif
