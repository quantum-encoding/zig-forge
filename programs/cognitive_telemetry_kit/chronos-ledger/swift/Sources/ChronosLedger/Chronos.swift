import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Embeddable emit-client for the **Chronos accountability ledger** — the Swift
/// twin of the Rust crate, for CosmicDuckOS and any AppKit/SwiftUI app.
///
/// Same contract as the Rust/Zig clients: the app holds **no key and does no
/// crypto**. It serializes the event body and fires it at the privileged sink
/// (`ledger-daemon` / Guardian Shield) over an `AF_UNIX` datagram socket; the
/// sink canonicalizes (RFC 8785), hash-chains, and ML-DSA-65-signs. `emit` is
/// non-blocking and best-effort — safe to call from the main thread.
public struct Chronos: Sendable {
    public let socketPath: String
    public let agent: String
    public var session: String?
    public var model: String?
    public var user: String?
    /// Firing process pid/ppid — the join key to Guardian Shield's kernel ES view.
    /// Carried as decimal strings to match the float-free wire schema (and the Zig
    /// hook's `agent.pid`/`ppid`). For an in-app emitter set the spawned agent's pid.
    public var pid: String?
    public var ppid: String?

    /// Default sink socket if `$CHRONOS_LEDGER_SOCKET` is unset.
    public static let defaultSocket = "/tmp/chronos-ledger.sock"

    /// Emitter for `agent` (e.g. `"CosmicDuckOS"`). Socket from
    /// `$CHRONOS_LEDGER_SOCKET`, else an explicit `socketPath`, else the default.
    public init(agent: String, socketPath: String? = nil) {
        self.agent = agent
        self.socketPath =
            socketPath
            ?? ProcessInfo.processInfo.environment["CHRONOS_LEDGER_SOCKET"]
            ?? Self.defaultSocket
    }

    public func session(_ v: String) -> Chronos { var c = self; c.session = v; return c }
    public func model(_ v: String) -> Chronos { var c = self; c.model = v; return c }
    public func user(_ v: String) -> Chronos { var c = self; c.user = v; return c }
    /// Set the firing process pid (and optional ppid). Accepts an Int for ergonomics.
    public func pid(_ v: Int, ppid: Int? = nil) -> Chronos {
        var c = self; c.pid = String(v); c.ppid = ppid.map(String.init); return c
    }

    /// Fire one event at the sink. Non-blocking, best-effort: returns `true` if
    /// the datagram reached the kernel, `false` if the sink was unavailable/busy
    /// (the event is then dropped — a gap in the ledger's `seq` is itself the
    /// signal). Never blocks, never throws.
    @discardableResult
    public func emit(_ event: Event) -> Bool {
        guard
            let data = Self.encode(
                event, agent: agent, session: session, model: model, user: user,
                pid: pid, ppid: ppid)
        else { return false }
        return Self.send(data, to: socketPath)
    }

    /// Build the wire body (internal — exposed for tests). Float-free; carries no
    /// `seq`/`prev`/`this`/`sig`/`v` (the sink injects those).
    static func encode(
        _ event: Event, agent: String, session: String?, model: String?, user: String?,
        pid: String? = nil, ppid: String? = nil
    ) -> Data? {
        let body = WireBody(
            agent: WireAgent(
                id: agent, session: session, model: model, user: user, pid: pid, ppid: ppid),
            kind: event.kind,
            state: event.state,
            act: event.act,
            t_wall_ms: String(Int64(Date().timeIntervalSince1970 * 1000))
        )
        return try? JSONEncoder().encode(body)
    }

    static func send(_ data: Data, to socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if socketPath.utf8.count >= capacity { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                socketPath.withCString { src in strncpy(dst, src, capacity - 1) }
            }
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let sent = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                data.withUnsafeBytes { buf in
                    sendto(
                        fd, buf.baseAddress, buf.count, Int32(MSG_DONTWAIT),
                        saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        return sent == data.count
    }
}

// ── wire body: matches chronos-hook / the Rust crate; sink injects seq/prev/this ──

struct WireBody: Encodable {
    let agent: WireAgent
    let kind: Kind
    let state: String?
    let act: Act
    /// Wall-clock ms as a STRING — display only; the sink's `seq` is the order
    /// of record, and a string stays out of the float/`>2^53` hazard zone.
    let t_wall_ms: String
}

struct WireAgent: Encodable {
    let id: String
    let session: String?
    let model: String?
    let user: String?
    /// Decimal-string pid/ppid (omitted from the wire when nil — synthesized
    /// `encodeIfPresent`). Matches the Zig hook's `agent.pid`/`ppid`.
    var pid: String? = nil
    var ppid: String? = nil
}
