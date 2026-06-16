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
}
