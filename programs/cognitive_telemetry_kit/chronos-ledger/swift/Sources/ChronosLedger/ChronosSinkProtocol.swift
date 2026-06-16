import Foundation

/// XPC contract between the CosmicDuckOS app and its bundled sink service.
///
/// The app sends a fully-formed event **body** (the same JSON the UDS `Chronos`
/// emitter produces); the privileged service chains + ML-DSA-signs it and writes
/// the signed NDJSON into the app's sandbox container. The signing key lives only
/// in the service process, so a compromised agent in the main app cannot read it.
///
/// `emit` is one-way (no reply) — fire-and-forget, never blocks the app.
@objc public protocol ChronosSinkProtocol {
    /// Ingest one event body (UTF-8 JSON). The service decides the milestone from
    /// the event `kind`, chains, signs, and persists.
    func emit(_ eventJSON: Data)

    /// Ask the service for the current ledger location + public key so the app can
    /// surface "view audit log" / hand the signed bundle to the user.
    func ledgerInfo(withReply reply: @escaping (_ ledgerPath: String, _ publicKeyHex: String) -> Void)

    /// Re-walk the ledger and verify the chain + signatures, returning a
    /// JSON-encoded `LedgerVerdict`. Done in the service because only it has the
    /// key and the C-ABI verifier.
    func verifyLedger(withReply reply: @escaping (_ verdictJSON: Data) -> Void)
}

/// Common surface for the two transports so app code can hold `any ChronosEmitting`
/// and not care whether it's the in-app XPC sink or a separate UDS daemon.
public protocol ChronosEmitting {
    @discardableResult
    func emit(_ event: Event) -> Bool
}

extension Chronos: ChronosEmitting {}
