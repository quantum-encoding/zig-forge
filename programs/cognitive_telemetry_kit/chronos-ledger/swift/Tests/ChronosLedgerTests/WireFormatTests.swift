import XCTest

@testable import ChronosLedger

final class WireFormatTests: XCTestCase {
    func testEncodedShapeMatchesSink() throws {
        let data = Chronos.encode(
            Event.exec("cargo test").trust(.repo).tool("run_command"),
            agent: "CosmicDuckOS", session: "s1", model: "m1", user: nil)!
        let v = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(v["kind"] as? String, "exec")
        let act = v["act"] as! [String: Any]
        XCTAssertEqual(act["detail"] as? String, "cargo test")
        XCTAssertEqual(act["source_trust"] as? String, "repo")
        XCTAssertEqual(act["tool"] as? String, "run_command")
        let agent = v["agent"] as! [String: Any]
        XCTAssertEqual(agent["id"] as? String, "CosmicDuckOS")
        XCTAssertEqual(agent["session"] as? String, "s1")
        XCTAssertNil(agent["user"], "nil optional must be omitted, not null")
        XCTAssertTrue(v["t_wall_ms"] is String, "t_wall_ms must be a string")
        // The sink owns these — they must NOT come from the client.
        for k in ["seq", "prev", "this", "sig", "v"] {
            XCTAssertNil(v[k], "reserved key \(k) leaked")
        }
    }

    func testNetDerivesHost() {
        let e = Event.net("https://user@evil.example:8443/exfil?q=1")
        XCTAssertEqual(e.act.destHost, "evil.example")
        XCTAssertEqual(e.act.url, "https://user@evil.example:8443/exfil?q=1")
    }

    func testEmitFailFastWhenSinkAbsent() {
        let c = Chronos(agent: "x", socketPath: "/tmp/chronos-swift-nonexistent.sock")
        XCTAssertFalse(c.emit(Event.read("/etc/hosts")))
    }

    func testPidPresentWhenSetOmittedWhenNil() throws {
        // Set: pid/ppid appear as decimal strings (matches the Zig hook's agent.pid).
        let withPid = Chronos.encode(
            Event.read("/x"), agent: "a", session: nil, model: nil, user: nil,
            pid: "222110", ppid: "222109")!
        let agent = try JSONSerialization.jsonObject(with: withPid) as! [String: Any]
        let a = agent["agent"] as! [String: Any]
        XCTAssertEqual(a["pid"] as? String, "222110")
        XCTAssertEqual(a["ppid"] as? String, "222109")

        // Unset: omitted entirely (no null) — keeps the wire shape unchanged.
        let noPid = Chronos.encode(
            Event.read("/x"), agent: "a", session: nil, model: nil, user: nil)!
        let a2 = (try JSONSerialization.jsonObject(with: noPid) as! [String: Any])["agent"] as! [String: Any]
        XCTAssertNil(a2["pid"], "nil pid must be omitted, not null")
        XCTAssertNil(a2["ppid"], "nil ppid must be omitted, not null")
    }

    func testUDSListenerReceivesDatagram() {
        // A short /tmp path stays well under the sun_path limit.
        let path = "/tmp/chronos-uds-test-\(getpid()).sock"
        let exp = expectation(description: "datagram received")
        let payload = Data(#"{"agent":{"id":"claude","pid":"4242"},"kind":"read"}"#.utf8)

        // Lock-guarded box so the @Sendable receive closure can capture it (Swift 6).
        let received = Box<Data?>(nil)
        let listener = UDSLedgerListener(socketPath: path) { data in
            received.set(data)
            exp.fulfill()
        }
        XCTAssertTrue(listener.start(), "listener should bind the socket")
        defer { listener.stop() }

        // Send via the SAME wire the chronos-hook uses (Chronos.send → AF_UNIX dgram).
        XCTAssertTrue(Chronos.send(payload, to: path))
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(received.value, payload, "listener must deliver the exact bytes")
    }

    /// Minimal lock-guarded box so a `@Sendable` closure can stash a value (Swift 6).
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ newValue: T) { lock.lock(); v = newValue; lock.unlock() }
    }

    func testUDSListenerRejectsOverlongPath() {
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let listener = UDSLedgerListener(socketPath: tooLong) { _ in }
        XCTAssertFalse(listener.start(), "a path over sun_path must fail closed, not crash")
    }
}
