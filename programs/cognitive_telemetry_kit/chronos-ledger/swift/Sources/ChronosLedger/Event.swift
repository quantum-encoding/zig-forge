import Foundation

/// The action class. Mirrors the ledger schema `kind`; drives the sink's
/// milestone-signing policy (net/write are signed) and the detector's rules.
public enum Kind: String, Encodable, Sendable {
    case read, write, exec, net, search, think, other
}

/// Trust level of the data a `read`/`net` touched. Reading `external`/`web`
/// content taints the session; the detector then confines egress to a pinned
/// allowlist (domain-segmented taint).
public enum Trust: String, Encodable, Sendable {
    case repo, external, web, user, unknown
}

/// Per-action detail. Provide what's relevant for the kind; nil fields stay off
/// the wire (so the body is minimal and the sink's schema is satisfied).
public struct Act: Encodable, Sendable {
    public var tool: String?
    public var path: String?
    public var detail: String?
    public var url: String?
    public var destHost: String?
    public var sourceTrust: Trust?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case tool, path, detail, url
        case destHost = "dest_host"
        case sourceTrust = "source_trust"
    }
}

/// One ledger event the app constructs and emits. Value-type builder.
public struct Event: Sendable {
    public var kind: Kind
    public var state: String?
    public var act: Act

    public init(_ kind: Kind) {
        self.kind = kind
        self.state = nil
        self.act = Act()
    }

    /// A file read. `path` is the resource read.
    public static func read(_ path: String) -> Event { Event(.read).path(path) }
    /// A file write / edit. `path` is the resource written.
    public static func write(_ path: String) -> Event { Event(.write).path(path) }
    /// A command / shell execution. `command` goes in `detail`.
    public static func exec(_ command: String) -> Event { Event(.exec).detail(command) }
    /// A network egress to `url`. The host is also extracted into `destHost`
    /// so the detector can match it against the egress allowlist directly.
    public static func net(_ url: String) -> Event {
        var e = Event(.net).url(url)
        if let h = hostOf(url) { e.act.destHost = h }
        return e
    }
    /// A search. Provide a hashed/opaque query via `detail` if it may carry secrets.
    public static func search() -> Event { Event(.search) }
    /// A reasoning/thinking marker carrying the cognitive `state`.
    public static func think(_ state: String) -> Event { Event(.think).state(state) }

    public func tool(_ v: String) -> Event { var e = self; e.act.tool = v; return e }
    public func path(_ v: String) -> Event { var e = self; e.act.path = v; return e }
    public func detail(_ v: String) -> Event { var e = self; e.act.detail = v; return e }
    public func url(_ v: String) -> Event { var e = self; e.act.url = v; return e }
    public func destHost(_ v: String) -> Event { var e = self; e.act.destHost = v; return e }
    public func trust(_ v: Trust) -> Event { var e = self; e.act.sourceTrust = v; return e }
    public func state(_ v: String) -> Event { var e = self; e.state = v; return e }
}

/// Extract the host from a URL-ish string: strip scheme + optional userinfo,
/// stop at the first `/ : ? #`. Mirrors the detector's `parseHost`.
func hostOf(_ url: String) -> String? {
    var s = Substring(url)
    if let r = s.range(of: "://") { s = s[r.upperBound...] }
    if let at = s.firstIndex(of: "@") { s = s[s.index(after: at)...] }
    if let end = s.firstIndex(where: { "/:?#".contains($0) }) { s = s[..<end] }
    return s.isEmpty ? nil : String(s)
}
