import XCTest

@testable import ChronosLedger

final class LedgerTests: XCTestCase {
    func testLedgerEntryParse() {
        let ndjson = Data(
            """
            {"seq":"0","kind":"read","agent":{"id":"CosmicDuckOS"},"act":{"path":"/etc/hosts","source_trust":"external","tool":"read_file"},"this":"ab","t_wall_ms":"100"}
            {"seq":"1","kind":"net","agent":{"id":"CosmicDuckOS"},"act":{"url":"https://evil.example"},"this":"cd","sig":{"alg":"ML-DSA-65"},"t_wall_ms":"200"}
            this line is not json
            """.utf8)

        let entries = LedgerEntry.parse(ndjson: ndjson)
        XCTAssertEqual(entries.count, 2, "unparseable line is skipped")

        XCTAssertEqual(entries[0].seq, 0)
        XCTAssertEqual(entries[0].kind, "read")
        XCTAssertEqual(entries[0].agent, "CosmicDuckOS")
        XCTAssertEqual(entries[0].detail, "/etc/hosts")
        XCTAssertEqual(entries[0].trust, "external")
        XCTAssertEqual(entries[0].tool, "read_file")
        XCTAssertFalse(entries[0].signed)

        XCTAssertEqual(entries[1].seq, 1)
        XCTAssertEqual(entries[1].detail, "https://evil.example")  // url used when no path/detail
        XCTAssertTrue(entries[1].signed)  // has sig
        XCTAssertEqual(entries[1].wallMs, 200)
    }

    func testVerdictCodableRoundTrip() throws {
        let v = LedgerVerdict(events: 7, signed: 3, chainOk: false, sigsOk: true, firstBadSeq: 4)
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(LedgerVerdict.self, from: data)
        XCTAssertEqual(back.events, 7)
        XCTAssertEqual(back.firstBadSeq, 4)
        XCTAssertFalse(back.isValid)  // chain failed
    }
}
