//! Sink core: the privileged half of the ledger (Addition 1). It owns the
//! ML-DSA signing key and turns each received content datagram into a chained,
//! milestone-signed shipped event. This is the security-critical logic, kept
//! separate from the socket/file plumbing in main.zig so it is unit-testable.
//!
//! The in-agent emit-client (chronos-hook → cl_emit) sends only the event BODY
//! (kind/act/agent/state/timestamps) — never seq/prev/this/sig, never a key. The
//! sink injects the chain fields and decides the milestone, so a compromised
//! agent can neither forge the chain nor suppress a signature.

const std = @import("std");
const cl = @import("chronos_ledger");

pub const Sink = struct {
    chain: cl.Chain,

    pub fn initSigning(
        allocator: std.mem.Allocator,
        sk: *const [cl.SK_LEN]u8,
        pk: *const [cl.PK_LEN]u8,
    ) Sink {
        return .{ .chain = cl.Chain.initSigning(allocator, sk, pk) };
    }

    /// Process one received content datagram → canonical shipped event. The
    /// returned `json` is owned by the sink's allocator (free it). Milestone is
    /// derived from the event `kind`, so the agent cannot opt out of signing a
    /// security-relevant action by lying about a flag.
    pub fn process(self: *Sink, content_json: []const u8) cl.ledger.Error!cl.Appended {
        var arena = std.heap.ArenaAllocator.init(self.chain.allocator);
        defer arena.deinit();
        const members = try cl.ledger.membersFromJson(arena.allocator(), content_json);
        return self.chain.append(members, isMilestone(members));
    }
};

/// Milestone policy: sign on outbound network, file writes, and session
/// boundaries. Everything else (reads, searches, thinking) chains unsigned and
/// is anchored by the next signed head (Addition 3 — O(1) signatures per batch).
pub fn isMilestone(members: []const cl.canonical.Member) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m.key, "kind") and m.value == .string) {
            const k = m.value.string;
            return std.mem.eql(u8, k, "net") or
                std.mem.eql(u8, k, "write") or
                std.mem.eql(u8, k, "session_end");
        }
    }
    return false;
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn fixedSeed() [32]u8 {
    var s: [32]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i +% 7);
    return s;
}

test "read chains unsigned; net is signed; both verify; chain links advance" {
    const seed = fixedSeed();
    const kp = try cl.generateKeypair(&seed);
    var s = Sink.initSigning(testing.allocator, &kp.sk, &kp.pk);

    const r = try s.process(
        \\{"kind":"read","act":{"path":"/etc/hosts","source_trust":"repo"},"t_wall_ms":"1750000000000"}
    );
    defer testing.allocator.free(r.json);
    try testing.expect(!r.signed);
    const rv = try cl.verifyEvent(testing.allocator, &kp.pk, r.json);
    try testing.expect(rv.chain_ok and !rv.sig_present);

    const head_after_read = s.chain.head;

    const n = try s.process(
        \\{"kind":"net","act":{"method":"POST","dest_host":"evildomain.example"},"t_wall_ms":"1750000000001"}
    );
    defer testing.allocator.free(n.json);
    try testing.expect(n.signed);
    const nv = try cl.verifyEvent(testing.allocator, &kp.pk, n.json);
    try testing.expect(nv.chain_ok and nv.sig_present and nv.sig_ok);

    try testing.expectEqual(@as(u64, 0), r.seq);
    try testing.expectEqual(@as(u64, 1), n.seq);
    // The net event's prev is the read's head → heads differ and link forward.
    try testing.expect(!std.mem.eql(u8, &head_after_read, &n.head));
    try testing.expect(std.mem.indexOf(u8, n.json, &std.fmt.bytesToHex(head_after_read, .lower)) != null);
}

test "write and session_end are milestones; search is not" {
    const seed = fixedSeed();
    const kp = try cl.generateKeypair(&seed);
    var s = Sink.initSigning(testing.allocator, &kp.sk, &kp.pk);

    const w = try s.process("{\"kind\":\"write\",\"act\":{\"path\":\"/tmp/x\"}}");
    defer testing.allocator.free(w.json);
    try testing.expect(w.signed);

    const q = try s.process("{\"kind\":\"search\",\"act\":{\"query_sha256\":\"ab\"}}");
    defer testing.allocator.free(q.json);
    try testing.expect(!q.signed);

    const e = try s.process("{\"kind\":\"session_end\"}");
    defer testing.allocator.free(e.json);
    try testing.expect(e.signed);
}

test "malformed datagram is a recoverable error, not a crash" {
    const seed = fixedSeed();
    const kp = try cl.generateKeypair(&seed);
    var s = Sink.initSigning(testing.allocator, &kp.sk, &kp.pk);
    try testing.expectError(error.ParseFailed, s.process("not json"));
    try testing.expectError(error.ParseFailed, s.process("[1,2,3]")); // not an object
    try testing.expectError(error.FloatNotAllowed, s.process("{\"kind\":\"read\",\"x\":1.5}"));
}
