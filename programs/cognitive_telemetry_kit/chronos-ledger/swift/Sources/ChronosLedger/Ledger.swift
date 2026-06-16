import Foundation

/// Result of re-walking the ledger: did every event chain, and did every
/// milestone signature verify. Computed by the sink service (it has the key +
/// the C-ABI `cl_verify`) and shipped to the app as JSON.
public struct LedgerVerdict: Codable, Sendable {
    public var events: Int
    public var signed: Int
    public var chainOk: Bool       // every event's body hashes to its `this`
    public var sigsOk: Bool        // every present signature verifies
    public var firstBadSeq: Int?   // first failing event, if any

    public init(events: Int, signed: Int, chainOk: Bool, sigsOk: Bool, firstBadSeq: Int?) {
        self.events = events
        self.signed = signed
        self.chainOk = chainOk
        self.sigsOk = sigsOk
        self.firstBadSeq = firstBadSeq
    }

    /// Trustworthy only when the chain is intact AND all signatures verify.
    public var isValid: Bool { chainOk && sigsOk }
}

/// One human-readable row parsed from a shipped ledger line (display only — the
/// cryptographic truth is `LedgerVerdict`).
public struct LedgerEntry: Identifiable, Sendable {
    public let id: Int
    public let seq: Int
    public let kind: String
    public let agent: String
    public let tool: String?
    public let detail: String?   // path / detail / url / dest_host, whichever is present
    public let trust: String?
    public let signed: Bool
    public let wallMs: Int64?

    /// Parse an NDJSON ledger blob into display rows (skips unparseable lines).
    public static func parse(ndjson: Data) -> [LedgerEntry] {
        let text = String(decoding: ndjson, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let seqStr = obj["seq"] as? String, let seq = Int(seqStr)
            else { return nil }
            let act = obj["act"] as? [String: Any] ?? [:]
            let detail = (act["path"] ?? act["detail"] ?? act["url"] ?? act["dest_host"]) as? String
            return LedgerEntry(
                id: seq,
                seq: seq,
                kind: obj["kind"] as? String ?? "other",
                agent: (obj["agent"] as? [String: Any])?["id"] as? String ?? "?",
                tool: act["tool"] as? String,
                detail: detail,
                trust: act["source_trust"] as? String,
                signed: obj["sig"] != nil,
                wallMs: (obj["t_wall_ms"] as? String).flatMap { Int64($0) }
            )
        }
    }
}
