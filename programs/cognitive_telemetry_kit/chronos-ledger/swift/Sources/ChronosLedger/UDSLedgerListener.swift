#if canImport(Darwin)
import Foundation
import Darwin

/// Receives raw Chronos event bodies over an `AF_UNIX` datagram socket and hands
/// each one to a sink. This is how **in-app-spawned CLI agents** reach the SAME
/// ledger as the app's own XPC emits: a spawned `claude`/`codex`/`gemini` runs the
/// `chronos-hook`, which emits its ledger event over UDS to `$CHRONOS_LEDGER_SOCKET`.
/// Point that env var at this listener's path and feed every datagram into the same
/// `ChronosSink.ingest` the XPC path uses — one hash chain, both sources.
///
/// Pure Foundation + POSIX (mirrors `Chronos.send`'s wire), no FFI. `SOCK_DGRAM`
/// messages are self-framed: one `recv` == one complete event, no length prefixes.
///
/// Deployment note (resolve on-device): the socket path must be reachable by BOTH
/// the listener's process and the spawned agent, and short enough for `sun_path`
/// (~104 bytes on macOS — `start()` returns false if exceeded). Under the App
/// Sandbox, an App-Group container path is the natural shared, entitled location;
/// who binds it (the XPC sink directly, vs. the app relaying to the sink over XPC)
/// depends on which process the sandbox lets reach the spawned agent — verify with
/// a real spawn before committing the topology.
public final class UDSLedgerListener: @unchecked Sendable {
    private let socketPath: String
    private let onEvent: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "io.quantumencoding.chronos.uds", qos: .utility)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false

    /// - Parameters:
    ///   - socketPath: filesystem path to bind the datagram socket at.
    ///   - onEvent: called on a background queue with each received event body
    ///     (raw JSON, exactly as the emitter sent it). Wire it to `ChronosSink.ingest`.
    public init(socketPath: String, onEvent: @escaping @Sendable (Data) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    /// Bind the socket and start the receive loop. Returns `false` if the path is
    /// too long for `sun_path` or the socket can't be created/bound. Idempotent.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return true }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { return false }

        // A datagram socket leaves a filesystem node behind; a stale one blocks bind().
        unlink(socketPath)

        let s = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }

        _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                socketPath.withCString { src in strncpy(dst, src, capacity - 1) }
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(s, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else { close(s); return false }

        fd = s
        running = true
        queue.async { [weak self] in self?.loop() }
        return true
    }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock()
            let live = running
            let s = fd
            lock.unlock()
            if !live || s < 0 { return }

            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                onEvent(Data(buf[0..<n]))
            } else if n < 0 {
                if errno == EINTR { continue }
                return  // fd closed by stop(), or a fatal error — end the loop
            }
            // n == 0: empty datagram — ignore and keep receiving.
        }
    }

    /// Stop receiving and remove the socket file. Closing the fd unblocks `recv`.
    public func stop() {
        lock.lock()
        running = false
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { close(s) }
        unlink(socketPath)
    }

    deinit { stop() }
}
#endif
