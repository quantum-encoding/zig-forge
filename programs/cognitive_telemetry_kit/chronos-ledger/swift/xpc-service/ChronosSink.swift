import Foundation

// Requires the C-ABI from libchronos_ledger.a, exposed via the XPC target's
// bridging header (`#include "chronos_ledger.h"`). This file is compiled into the
// XPC Service target, NOT the SwiftPM package — the sink (and the signing key) run
// only inside the bundled, sandboxed helper process.

/// In-process Chronos sink: chains + ML-DSA-65-signs event bodies and appends the
/// signed NDJSON to the app's sandbox container. The signing key never leaves this
/// process. This is the same Zig core as `ledger-daemon`, driven by XPC instead of
/// a Unix datagram socket.
public final class ChronosSink {
    public enum SinkError: Error { case keygen, chain, ledger }

    private let chain: OpaquePointer
    private let pk: [UInt8]
    private let ledgerURL: URL
    private let handle: FileHandle

    /// - Parameters:
    ///   - keyURL: persisted `pk||sk` keyfile (generated 0600 on first launch).
    ///   - ledgerURL: append-only signed NDJSON ledger; a `<ledger>.pub` sidecar
    ///     is written alongside so the app/user can verify.
    public init(keyURL: URL, ledgerURL: URL) throws {
        var pk = [UInt8](repeating: 0, count: Int(CL_PK_LEN))
        var sk = [UInt8](repeating: 0, count: Int(CL_SK_LEN))

        let keyLen = Int(CL_PK_LEN) + Int(CL_SK_LEN)
        if let both = try? Data(contentsOf: keyURL), both.count == keyLen {
            pk = [UInt8](both[both.startIndex ..< both.startIndex + Int(CL_PK_LEN)])
            sk = [UInt8](both[both.startIndex + Int(CL_PK_LEN) ..< both.endIndex])
        } else {
            guard cl_generate_keypair(nil, &pk, &sk) == CL_OK else { throw SinkError.keygen }
            var blob = Data(pk)
            blob.append(contentsOf: sk)
            try? blob.write(to: keyURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }

        guard let c = cl_chain_create_signing(&sk, &pk) else { throw SinkError.chain }
        self.chain = c
        self.pk = pk
        self.ledgerURL = ledgerURL

        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            FileManager.default.createFile(atPath: ledgerURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: ledgerURL) else { throw SinkError.ledger }
        h.seekToEndOfFile()
        self.handle = h

        // Publish the public key so the app / user can verify the chain.
        let pubHex = pk.map { String(format: "%02x", $0) }.joined()
        try? (pubHex + "\n").data(using: .utf8)?
            .write(to: ledgerURL.appendingPathExtension("pub"))
    }

    deinit { cl_chain_destroy(chain) }

    /// Chain + sign one event body (UTF-8 JSON) and append it to the ledger.
    /// Milestone (→ signed) is derived from the event `kind`, so a compromised
    /// caller cannot opt out of signing a security-relevant action.
    @discardableResult
    public func ingest(_ body: Data) -> Bool {
        let milestone = Self.isMilestone(body)
        var outJson: UnsafeMutablePointer<UInt8>? = nil
        var outLen = 0
        var head = [UInt8](repeating: 0, count: Int(CL_HEAD_HEX_LEN))

        let rc = body.withUnsafeBytes { raw -> Int32 in
            cl_append(
                chain, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                Int32(milestone ? 1 : 0), &outJson, &outLen, &head)
        }
        guard rc == CL_OK, let out = outJson else { return false }
        defer { cl_free(out, outLen) }

        var line = Data(bytes: out, count: outLen)
        line.append(0x0A)
        handle.write(line)
        if milestone { try? handle.synchronize() }  // durably persist signed heads
        return true
    }

    public var ledgerPath: String { ledgerURL.path }
    public var publicKeyHex: String { pk.map { String(format: "%02x", $0) }.joined() }

    /// Plain result of `verify()` — kept package-free so this file links with just
    /// Foundation + the C-ABI. `main.swift` maps it to the package's `LedgerVerdict`.
    public struct VerifyResult {
        public let events: Int
        public let signed: Int
        public let chainOk: Bool
        public let sigsOk: Bool
        public let firstBadSeq: Int?
    }

    /// Re-walk the persisted ledger and verify every event (chain + signature)
    /// against our public key via the C-ABI `cl_verify`.
    public func verify() -> VerifyResult {
        var pkCopy = pk
        var events = 0, signed = 0, firstBad: Int? = nil
        var chainOk = true, sigsOk = true
        guard let data = try? Data(contentsOf: ledgerURL) else {
            return VerifyResult(events: 0, signed: 0, chainOk: true, sigsOk: true, firstBadSeq: nil)
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let bytes = Array(line.utf8)
            if bytes.isEmpty { continue }
            events += 1
            var cOk: Int32 = 0, sPresent: Int32 = 0, sOk: Int32 = 0
            _ = cl_verify(&pkCopy, bytes, bytes.count, &cOk, &sPresent, &sOk)
            if sPresent == 1 { signed += 1 }
            let ok = cOk == 1 && (sPresent == 0 || sOk == 1)
            if !ok {
                if cOk != 1 { chainOk = false }
                if sPresent == 1 && sOk != 1 { sigsOk = false }
                if firstBad == nil {
                    let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
                    firstBad = (obj?["seq"] as? String).flatMap { Int($0) } ?? (events - 1)
                }
            }
        }
        return VerifyResult(
            events: events, signed: signed, chainOk: chainOk, sigsOk: sigsOk, firstBadSeq: firstBad)
    }

    static func isMilestone(_ body: Data) -> Bool {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let kind = obj["kind"] as? String
        else { return false }
        return kind == "net" || kind == "write" || kind == "session_end"
    }
}
