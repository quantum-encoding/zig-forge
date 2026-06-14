//! Detection engine: replays a ledger event stream in order and raises findings.
//! Shared by the qai proxy (via C-ABI), the app session-end verifier, and the
//! `ledger-verify` CLI — one audited implementation, not three.
//!
//! Two layers:
//!   1. Integrity — every event must chain (monotonic `seq`, `prev` == previous
//!      `this`, body hashes to `this`) and every milestone signature must verify
//!      against the published key. A gap/fork/forgery is a finding, because in
//!      the threat model a missing or altered event is itself the signal.
//!   2. Behaviour — domain-segmented taint (Addition 2): untrusted input taints
//!      the session; thereafter egress is confined to a pinned allowlist. A
//!      tainted session egressing to an unlisted host is the exfil signal —
//!      escalated to EXFIL_CHAIN when a sensitive read preceded it. This is the
//!      `read maliciousfile → search creds → send evildomain` pattern.
//!
//! The detector DETECTS; it does not block. Enforcement is Guardian Shield / the
//! proxy egress chokepoint. The detector only needs the fields the emit-client
//! stamps: `kind`, `act.source_trust`, `act.path`, and the egress host.

const std = @import("std");
const ledger = @import("ledger.zig");

pub const PK_LEN = ledger.PK_LEN;

pub const Severity = enum { info, low, medium, high, critical };

pub const Finding = struct {
    seq: u64,
    rule: []const u8, // INTEGRITY | TAINT | SENSITIVE_READ | EGRESS_VIOLATION | EXFIL_CHAIN
    severity: Severity,
    detail: []const u8,
};

/// Default credential/secret path fragments. Matched as case-sensitive
/// substrings of `act.path` — deliberately broad; false positives are cheap
/// (info/medium), the miss is what costs you.
pub const default_sensitive = [_][]const u8{
    "/.ssh/",         "id_rsa",       "id_ed25519",  ".aws/credentials",
    "/.aws/",         ".env",         ".pem",        ".key",
    "/etc/shadow",    "Keychains/",   ".kube/config", ".netrc",
    ".npmrc",         "secret",       "credential",  "private_key",
    ".git-credentials",
};

pub const Config = struct {
    /// Pinned egress hosts permitted even for a tainted session (model API host,
    /// api.github.com, the configured DB, …). Exact or subdomain match.
    allowlist: []const []const u8 = &.{},
    sensitive_patterns: []const []const u8 = &default_sensitive,
};

pub const Detector = struct {
    arena: std.heap.ArenaAllocator,
    cfg: Config,
    pk: [PK_LEN]u8,

    expected_seq: u64 = 0,
    have_prev: bool = false,
    prev_hex: [64]u8 = undefined,
    tainted: bool = false,
    saw_sensitive_read: bool = false,
    findings: std.ArrayList(Finding) = .empty,

    pub fn init(child_allocator: std.mem.Allocator, cfg: Config, pk: *const [PK_LEN]u8) Detector {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator), .cfg = cfg, .pk = pk.* };
    }

    pub fn deinit(self: *Detector) void {
        self.arena.deinit();
    }

    /// Feed one shipped event (canonical JSON). Order matters — feed in `seq`
    /// order. Findings accumulate in `self.findings` (valid until `deinit`).
    pub fn feed(self: *Detector, shipped_json: []const u8) !void {
        const a = self.arena.allocator();

        const v = std.json.parseFromSliceLeaky(std.json.Value, a, shipped_json, .{}) catch {
            try self.add(self.expected_seq, "INTEGRITY", .high, "unparseable event");
            return;
        };
        if (v != .object) {
            try self.add(self.expected_seq, "INTEGRITY", .high, "event is not a JSON object");
            return;
        }
        const obj = v.object;
        const seq = parseU64(getStr(obj, "seq")) orelse {
            try self.add(self.expected_seq, "INTEGRITY", .high, "missing/invalid seq");
            return;
        };
        const prev = getStr(obj, "prev") orelse "";
        const this = getStr(obj, "this") orelse "";

        // ── Integrity ──────────────────────────────────────────────────────
        if (seq != self.expected_seq) {
            try self.add(seq, "INTEGRITY", .high, try std.fmt.allocPrint(a, "seq gap/reorder: got {d}, expected {d}", .{ seq, self.expected_seq }));
        }
        if (self.have_prev and !std.mem.eql(u8, prev, &self.prev_hex)) {
            try self.add(seq, "INTEGRITY", .high, "broken prev link (chain fork or dropped event)");
        }
        const verdict = ledger.verifyEvent(a, &self.pk, shipped_json) catch ledger.Verdict{ .chain_ok = false, .sig_present = false, .sig_ok = false };
        if (!verdict.chain_ok) {
            try self.add(seq, "INTEGRITY", .critical, "body does not hash to `this` (tampered)");
        }
        if (verdict.sig_present and !verdict.sig_ok) {
            try self.add(seq, "INTEGRITY", .critical, "milestone signature does not verify (forged)");
        }
        if (this.len == 64) {
            @memcpy(&self.prev_hex, this[0..64]);
            self.have_prev = true;
        }
        self.expected_seq = seq + 1;

        // ── Behaviour ──────────────────────────────────────────────────────
        const kind = getStr(obj, "kind") orelse "other";
        const act: ?std.json.ObjectMap = if (obj.get("act")) |av| (if (av == .object) av.object else null) else null;
        const source_trust = if (act) |ac| getStr(ac, "source_trust") else null;
        const path = if (act) |ac| getStr(ac, "path") orelse getStr(ac, "detail") else null;

        // Untrusted input taints the session.
        if (source_trust) |st| {
            if (std.mem.eql(u8, st, "web") or std.mem.eql(u8, st, "external")) {
                if (!self.tainted) {
                    self.tainted = true;
                    try self.add(seq, "TAINT", .low, try std.fmt.allocPrint(a, "session tainted by {s} input ({s})", .{ st, kind }));
                }
            }
        }

        // Sensitive resource access.
        if (path) |p| {
            if (self.matchesSensitive(p)) {
                self.saw_sensitive_read = true;
                const sev: Severity = if (self.tainted) .high else .medium;
                try self.add(seq, "SENSITIVE_READ", sev, try std.fmt.allocPrint(a, "{s} of sensitive path: {s}", .{ kind, p }));
            }
        }

        // Egress: domain-segmented allowlist once tainted.
        if (std.mem.eql(u8, kind, "net")) {
            const host = self.egressHost(act);
            if (host.len != 0 and !self.hostAllowed(host)) {
                if (self.tainted) {
                    try self.add(seq, "EGRESS_VIOLATION", .critical, try std.fmt.allocPrint(a, "tainted session egress to non-allowlisted host: {s}", .{host}));
                    if (self.saw_sensitive_read) {
                        try self.add(seq, "EXFIL_CHAIN", .critical, try std.fmt.allocPrint(a, "exfil pattern: sensitive read + tainted egress to {s}", .{host}));
                    }
                } else {
                    try self.add(seq, "EGRESS_VIOLATION", .low, try std.fmt.allocPrint(a, "egress to non-allowlisted host (untainted): {s}", .{host}));
                }
            }
        }
    }

    /// Highest severity seen (for an overall verdict / process exit code).
    pub fn worst(self: *const Detector) Severity {
        var w: Severity = .info;
        for (self.findings.items) |f| {
            if (@intFromEnum(f.severity) > @intFromEnum(w)) w = f.severity;
        }
        return w;
    }

    fn add(self: *Detector, seq: u64, rule: []const u8, sev: Severity, detail: []const u8) !void {
        const a = self.arena.allocator();
        try self.findings.append(a, .{ .seq = seq, .rule = rule, .severity = sev, .detail = try a.dupe(u8, detail) });
    }

    fn matchesSensitive(self: *const Detector, p: []const u8) bool {
        for (self.cfg.sensitive_patterns) |pat| {
            if (std.mem.indexOf(u8, p, pat) != null) return true;
        }
        return false;
    }

    fn egressHost(self: *const Detector, act: ?std.json.ObjectMap) []const u8 {
        _ = self;
        const ac = act orelse return "";
        if (getStr(ac, "dest_host")) |h| return h;
        if (getStr(ac, "url")) |u| return parseHost(u);
        if (getStr(ac, "detail")) |d| return parseHost(d);
        return "";
    }

    fn hostAllowed(self: *const Detector, host: []const u8) bool {
        for (self.cfg.allowlist) |e| {
            if (std.mem.eql(u8, host, e)) return true;
            // subdomain: foo.github.com matches github.com
            if (host.len > e.len + 1 and std.mem.endsWith(u8, host, e) and host[host.len - e.len - 1] == '.') return true;
        }
        return false;
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn parseU64(s: ?[]const u8) ?u64 {
    const str = s orelse return null;
    return std.fmt.parseInt(u64, str, 10) catch null;
}

/// Extract the host from a URL-ish string: strip scheme, optional userinfo,
/// stop at the first '/', ':', '?' or '#'. Bare hosts pass through.
fn parseHost(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[at + 1 ..];
    var end: usize = s.len;
    for (s, 0..) |ch, i| {
        if (ch == '/' or ch == ':' or ch == '?' or ch == '#') {
            end = i;
            break;
        }
    }
    return s[0..end];
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn seed7() [32]u8 {
    var s: [32]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i +% 7);
    return s;
}

// Build the exfil-shape stream the way the daemon would, then audit it.
test "detects the read→search→egress exfil chain; allowlisted egress is clean" {
    const seed = seed7();
    const kp = try ledger.generateKeypair(&seed);

    var chain = ledger.Chain.initSigning(testing.allocator, &kp.sk, &kp.pk);
    var events: std.ArrayList([]u8) = .empty;
    defer {
        for (events.items) |e| testing.allocator.free(e);
        events.deinit(testing.allocator);
    }
    const bodies = [_][]const u8{
        \\{"kind":"read","act":{"path":"/Users/x/.ssh/id_rsa","source_trust":"external"}}
        ,
        \\{"kind":"search","act":{"source_trust":"web"}}
        ,
        \\{"kind":"net","act":{"url":"https://evildomain.example/exfil","source_trust":"web"}}
        ,
    };
    for (bodies) |b| {
        const milestone = std.mem.indexOf(u8, b, "\"net\"") != null;
        const r = try chain.appendJson(b, milestone);
        try events.append(testing.allocator, r.json);
    }

    const allow = [_][]const u8{ "api.quantumencoding.ai", "api.github.com" };
    var det = Detector.init(testing.allocator, .{ .allowlist = &allow }, &kp.pk);
    defer det.deinit();
    for (events.items) |e| try det.feed(e);

    // Expect: taint (read external), sensitive read (id_rsa), egress violation +
    // exfil chain (tainted egress to evildomain after a sensitive read).
    try testing.expect(hasRule(&det, "SENSITIVE_READ"));
    try testing.expect(hasRule(&det, "EGRESS_VIOLATION"));
    try testing.expect(hasRule(&det, "EXFIL_CHAIN"));
    try testing.expectEqual(Severity.critical, det.worst());
}

test "tainted egress to an allowlisted host raises no violation" {
    const seed = seed7();
    const kp = try ledger.generateKeypair(&seed);
    var chain = ledger.Chain.initSigning(testing.allocator, &kp.sk, &kp.pk);

    const r0 = try chain.appendJson("{\"kind\":\"search\",\"act\":{\"source_trust\":\"web\"}}", false);
    defer testing.allocator.free(r0.json);
    const r1 = try chain.appendJson("{\"kind\":\"net\",\"act\":{\"url\":\"https://api.github.com/repos\",\"source_trust\":\"web\"}}", true);
    defer testing.allocator.free(r1.json);

    const allow = [_][]const u8{ "api.quantumencoding.ai", "github.com" }; // api.github.com matches via subdomain
    var det = Detector.init(testing.allocator, .{ .allowlist = &allow }, &kp.pk);
    defer det.deinit();
    try det.feed(r0.json);
    try det.feed(r1.json);

    try testing.expect(!hasRule(&det, "EGRESS_VIOLATION"));
    try testing.expect(!hasRule(&det, "EXFIL_CHAIN"));
}

test "integrity: a tampered body is flagged" {
    const seed = seed7();
    const kp = try ledger.generateKeypair(&seed);
    var chain = ledger.Chain.initSigning(testing.allocator, &kp.sk, &kp.pk);
    const r = try chain.appendJson("{\"kind\":\"net\",\"act\":{\"url\":\"https://x.example\"}}", true);
    defer testing.allocator.free(r.json);

    const tampered = try testing.allocator.dupe(u8, r.json);
    defer testing.allocator.free(tampered);
    tampered[std.mem.indexOf(u8, tampered, "x.example").?] = 'Z';

    var det = Detector.init(testing.allocator, .{}, &kp.pk);
    defer det.deinit();
    try det.feed(tampered);
    try testing.expect(hasRule(&det, "INTEGRITY"));
    try testing.expectEqual(Severity.critical, det.worst());
}

test "parseHost extracts host from assorted URLs" {
    try testing.expectEqualStrings("evil.example", parseHost("https://evil.example/path?q=1"));
    try testing.expectEqualStrings("evil.example", parseHost("http://user@evil.example:8443/x"));
    try testing.expectEqualStrings("bare.host", parseHost("bare.host"));
}

fn hasRule(det: *const Detector, rule: []const u8) bool {
    for (det.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, rule)) return true;
    }
    return false;
}
