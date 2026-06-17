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
    private let pid: String?
    private let ppid: String?
    private let lock = NSLock()
    private var _connection: NSXPCConnection?

    /// - Parameters:
    ///   - serviceName: the XPC service bundle id, e.g.
    ///     `"io.quantumencoding.cosmicduck.ChronosSink"`.
    ///   - pid/ppid: firing process pid/ppid (the GS-correlation join key). For an
    ///     in-app emitter wrapping a spawned agent, pass that child's pid.
    public init(
        serviceName: String,
        agent: String,
        session: String? = nil,
        model: String? = nil,
        user: String? = nil,
        pid: Int? = nil,
        ppid: Int? = nil
    ) {
        self.serviceName = serviceName
        self.agent = agent
        self.session = session
        self.model = model
        self.user = user
        self.pid = pid.map(String.init)
        self.ppid = ppid.map(String.init)
    }

    private func connection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let c = _connection { return c }
        let c = NSXPCConnection(serviceName: serviceName)
        c.remoteObjectInterface = NSXPCInterface(with: ChronosSinkProtocol.self)
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self._connection = nil; self.lock.unlock()
        }
        c.resume()
        _connection = c
        return c
    }

    @discardableResult
    public func emit(_ event: Event) -> Bool {
        guard
            let data = Chronos.encode(
                event, agent: agent, session: session, model: model, user: user,
                pid: pid, ppid: ppid)
        else { return false }
        let proxy =
            connection().remoteObjectProxyWithErrorHandler { _ in
                // Swallowed: a down service must never surface as an app error.
            } as? ChronosSinkProtocol
        guard let proxy else { return false }
        proxy.emit(data)
        return true
    }

    /// Ledger path + public key for a "view audit log" UI.
    public func ledgerInfo() async -> (path: String, publicKeyHex: String)? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy =
                connection().remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
                as? ChronosSinkProtocol
            guard let proxy else { return once.resume(nil) }
            proxy.ledgerInfo { path, pub in once.resume((path, pub)) }
        }
    }

    /// Verify the chain + signatures (the service does the crypto).
    public func verifyLedger() async -> LedgerVerdict? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy =
                connection().remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
                as? ChronosSinkProtocol
            guard let proxy else { return once.resume(nil) }
            proxy.verifyLedger { data in
                once.resume(try? JSONDecoder().decode(LedgerVerdict.self, from: data))
            }
        }
    }
}

/// Guards a CheckedContinuation against double/zero resume across the XPC reply
/// and error-handler paths (exactly one fires, but we make resume idempotent).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let cont: CheckedContinuation<T?, Never>
    private var done = false
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T?, Never>) { self.cont = cont }
    func resume(_ value: T?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
#endif
