//! Chronos Ledger core: append-only hash chain + ML-DSA-65 milestone signatures.
//!
//! Each event is canonicalised (RFC 8785) and folded into a rolling chain head:
//!
//!     Hᵢ = SHA-256( canonical( eventᵢ \ {this, sig} ) )
//!
//! where the event already carries `prev` = Hᵢ₋₁, so each head transitively
//! commits to the entire history before it. The shipped event additionally
//! carries `this` = Hᵢ and, on milestones, a `sig` over `this`. Modifying any
//! past event changes every later head, so a single signed head anchors the
//! whole prefix — which is why we sign only at milestones (outbound net, file
//! write, session boundaries) instead of per event (Addition 3).
//!
//! The signing key lives ONLY in this struct, which by design runs in the
//! privileged sink — never in the audited agent (Addition 1). A client-side
//! chain (`init`, no key) can still build/forward events; it just can't sign.

const std = @import("std");
const canonical = @import("canonical.zig");
const ml_dsa = @import("ml_dsa");

pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HEAD_LEN: usize = Sha256.digest_length; // 32
pub const PK_LEN: usize = ml_dsa.PUBLIC_KEY_SIZE; // 1952
pub const SK_LEN: usize = ml_dsa.SECRET_KEY_SIZE; // 4032
pub const SIG_LEN: usize = ml_dsa.SIGNATURE_SIZE; // 3309

pub const SCHEMA_VERSION: i64 = 1;
pub const SIG_ALG = "ML-DSA-65";

pub const Error = error{
    FloatNotAllowed, // JSON floats break cross-language determinism (see canonical.zig)
    NumberTooLarge, // integers that don't fit i64 must be sent as decimal strings
    ReservedKey, // caller supplied a key the chain owns (v/seq/prev/this/sig)
    SigningKeyMissing,
    SignFailed,
} || std.mem.Allocator.Error;

const reserved_keys = [_][]const u8{ "v", "seq", "prev", "this", "sig" };

fn isReserved(key: []const u8) bool {
    for (reserved_keys) |r| {
        if (std.mem.eql(u8, key, r)) return true;
    }
    return false;
}

pub const KeyPairBytes = struct {
    pk: [PK_LEN]u8,
    sk: [SK_LEN]u8,
};

/// Generate an ML-DSA-65 keypair. `seed` (32 bytes) makes it deterministic
/// (test vectors / reproducible cloud attestation); null uses the system RNG.
pub fn generateKeypair(seed: ?*const [32]u8) Error!KeyPairBytes {
    const kp = ml_dsa.keyGen(seed) catch return error.SignFailed;
    return .{ .pk = kp.pk.data, .sk = kp.sk.data };
}

pub const Appended = struct {
    seq: u64,
    head: [HEAD_LEN]u8,
    signed: bool,
    /// Canonical shipped event (includes `this`, and `sig` if signed). Owned by
    /// the Chain's allocator — caller frees with `allocator.free`.
    json: []u8,
};

pub const Chain = struct {
    allocator: std.mem.Allocator,
    seq: u64 = 0,
    head: [HEAD_LEN]u8 = [_]u8{0} ** HEAD_LEN, // genesis = 32 zero bytes
    sk: ?ml_dsa.SecretKey = null,
    key_id_hex: [32]u8 = [_]u8{'0'} ** 32, // hex of SHA-256(pk)[0..16]

    /// Client-side chain: forwards/builds events but cannot sign (no key).
    pub fn init(allocator: std.mem.Allocator) Chain {
        return .{ .allocator = allocator };
    }

    /// Sink-side chain: owns the ML-DSA secret key and signs milestone heads.
    pub fn initSigning(allocator: std.mem.Allocator, sk_bytes: *const [SK_LEN]u8, pk_bytes: *const [PK_LEN]u8) Chain {
        var pk_digest: [HEAD_LEN]u8 = undefined;
        Sha256.hash(pk_bytes, &pk_digest, .{});
        return .{
            .allocator = allocator,
            .sk = .{ .data = sk_bytes.* },
            .key_id_hex = std.fmt.bytesToHex(pk_digest[0..16].*, .lower),
        };
    }

    /// Append one event. `content` is the caller's semantic members (kind, act,
    /// agent, timestamps, taint) WITHOUT any reserved key — the chain injects
    /// `v`/`seq`/`prev`, computes `this`, and (on a milestone, if a key is held)
    /// `sig`. Returns the canonical shipped JSON + the new head.
    pub fn append(self: *Chain, content: []const canonical.Member, milestone: bool) Error!Appended {
        for (content) |m| {
            if (isReserved(m.key)) return error.ReservedKey;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const prev_hex = std.fmt.bytesToHex(self.head, .lower); // [64]u8
        var seq_buf: [24]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{self.seq}) catch unreachable;

        // Core members (everything that is hashed): caller content + v/seq/prev.
        var core: std.ArrayList(canonical.Member) = .empty;
        try core.appendSlice(a, content);
        try core.append(a, .{ .key = "v", .value = .{ .int = SCHEMA_VERSION } });
        try core.append(a, .{ .key = "seq", .value = .{ .string = seq_str } });
        try core.append(a, .{ .key = "prev", .value = .{ .string = &prev_hex } });

        const hashed = canonical.encodeAlloc(a, .{ .object = core.items }) catch |e| return mapEnc(e);

        var this: [HEAD_LEN]u8 = undefined;
        Sha256.hash(hashed, &this, .{});
        const this_hex = std.fmt.bytesToHex(this, .lower);

        // Shipped members = core + this (+ sig on a signed milestone).
        var shipped: std.ArrayList(canonical.Member) = .empty;
        try shipped.appendSlice(a, core.items);
        try shipped.append(a, .{ .key = "this", .value = .{ .string = &this_hex } });

        var signed = false;
        if (milestone) {
            if (self.sk == null) return error.SigningKeyMissing;
            const sig = ml_dsa.sign(&self.sk.?, this[0..], false) catch return error.SignFailed;
            const enc = std.base64.standard.Encoder;
            const b64 = try a.alloc(u8, enc.calcSize(sig.data.len));
            _ = enc.encode(b64, &sig.data);
            const sig_obj = canonical.Value{ .object = &[_]canonical.Member{
                .{ .key = "alg", .value = .{ .string = SIG_ALG } },
                .{ .key = "over", .value = .{ .string = "this" } },
                .{ .key = "key_id", .value = .{ .string = &self.key_id_hex } },
                .{ .key = "value", .value = .{ .string = b64 } },
            } };
            try shipped.append(a, .{ .key = "sig", .value = sig_obj });
            signed = true;
        }

        const json = canonical.encodeAlloc(self.allocator, .{ .object = shipped.items }) catch |e| return mapEnc(e);

        self.head = this;
        const used_seq = self.seq;
        self.seq += 1;
        return .{ .seq = used_seq, .head = this, .signed = signed, .json = json };
    }
};

fn mapEnc(e: anytype) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.OutOfMemory, // validated content never hits this; fold defensively
    };
}

// ───────────────────────── verification ─────────────────────────

pub const Verdict = struct {
    chain_ok: bool, // recomputed SHA-256 == claimed `this`
    sig_present: bool,
    sig_ok: bool, // ML-DSA verify over `this` (false if absent)
};

/// Verify a shipped event: recompute the chain head from the canonical form of
/// everything except `this`/`sig`, compare to the claimed `this`, and (if a `sig`
/// is present) ML-DSA-verify it against `pk`.
pub fn verifyEvent(allocator: std.mem.Allocator, pk_bytes: *const [PK_LEN]u8, shipped_json: []const u8) Error!Verdict {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, shipped_json, .{}) catch return error.FloatNotAllowed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.FloatNotAllowed;
    const obj = parsed.value.object;

    const this_val = obj.get("this") orelse return .{ .chain_ok = false, .sig_present = false, .sig_ok = false };
    if (this_val != .string) return .{ .chain_ok = false, .sig_present = false, .sig_ok = false };
    var claimed: [HEAD_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&claimed, this_val.string) catch return .{ .chain_ok = false, .sig_present = false, .sig_ok = false };

    // Rebuild canonical core (all members except this/sig).
    var core: std.ArrayList(canonical.Member) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "this") or std.mem.eql(u8, k, "sig")) continue;
        try core.append(a, .{ .key = k, .value = try toCanonical(a, entry.value_ptr.*) });
    }
    const hashed = canonical.encodeAlloc(a, .{ .object = core.items }) catch return error.OutOfMemory;
    var recomputed: [HEAD_LEN]u8 = undefined;
    Sha256.hash(hashed, &recomputed, .{});
    const chain_ok = std.mem.eql(u8, &recomputed, &claimed);

    var verdict = Verdict{ .chain_ok = chain_ok, .sig_present = false, .sig_ok = false };
    if (obj.get("sig")) |sig_val| {
        verdict.sig_present = true;
        if (sig_val == .object) {
            if (sig_val.object.get("value")) |v| {
                if (v == .string) {
                    const dec = std.base64.standard.Decoder;
                    const n = dec.calcSizeForSlice(v.string) catch 0;
                    if (n == SIG_LEN) {
                        var sig: ml_dsa.Signature = undefined;
                        if (dec.decode(&sig.data, v.string)) |_| {
                            const pk = ml_dsa.PublicKey{ .data = pk_bytes.* };
                            verdict.sig_ok = ml_dsa.verify(&pk, claimed[0..], &sig);
                        } else |_| {}
                    }
                }
            }
        }
    }
    return verdict;
}

/// Convert a parsed `std.json.Value` into a `canonical.Value`, REJECTING floats
/// and over-i64 numbers — they must arrive as decimal strings (see canonical.zig).
/// This is the boundary that enforces cross-language determinism for any caller
/// that hands us JSON (the C-ABI append path and verifyEvent both use it).
pub fn toCanonical(a: std.mem.Allocator, jv: std.json.Value) Error!canonical.Value {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .int = n },
        .float => error.FloatNotAllowed,
        .number_string => error.NumberTooLarge,
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const out = try a.alloc(canonical.Value, arr.items.len);
            for (arr.items, 0..) |item, i| out[i] = try toCanonical(a, item);
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            const members = try a.alloc(canonical.Member, o.count());
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                members[i] = .{ .key = entry.key_ptr.*, .value = try toCanonical(a, entry.value_ptr.*) };
            }
            break :blk .{ .object = members };
        },
    };
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn fixedSeed() [32]u8 {
    var s: [32]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i);
    return s;
}

test "chain head is independent of caller member order" {
    var c1 = Chain.init(testing.allocator);
    var c2 = Chain.init(testing.allocator);
    const a1 = try c1.append(&[_]canonical.Member{
        .{ .key = "kind", .value = .{ .string = "read" } },
        .{ .key = "act", .value = .{ .object = &[_]canonical.Member{
            .{ .key = "path", .value = .{ .string = "/etc/hosts" } },
            .{ .key = "source_trust", .value = .{ .string = "repo" } },
        } } },
    }, false);
    defer testing.allocator.free(a1.json);
    const a2 = try c2.append(&[_]canonical.Member{
        .{ .key = "act", .value = .{ .object = &[_]canonical.Member{
            .{ .key = "source_trust", .value = .{ .string = "repo" } },
            .{ .key = "path", .value = .{ .string = "/etc/hosts" } },
        } } },
        .{ .key = "kind", .value = .{ .string = "read" } },
    }, false);
    defer testing.allocator.free(a2.json);
    try testing.expectEqualSlices(u8, &a1.head, &a2.head);
    try testing.expectEqualStrings(a1.json, a2.json);
}

test "prev links: head N+1 depends on head N" {
    var c = Chain.init(testing.allocator);
    const e0 = try c.append(&[_]canonical.Member{.{ .key = "kind", .value = .{ .string = "think" } }}, false);
    defer testing.allocator.free(e0.json);
    const h0 = c.head;
    const e1 = try c.append(&[_]canonical.Member{.{ .key = "kind", .value = .{ .string = "think" } }}, false);
    defer testing.allocator.free(e1.json);
    // Same content, different prev → different head, and seq advanced.
    try testing.expect(!std.mem.eql(u8, &h0, &c.head));
    try testing.expectEqual(@as(u64, 0), e0.seq);
    try testing.expectEqual(@as(u64, 1), e1.seq);
}

test "milestone sign + verify roundtrip, and tamper is detected" {
    const seed = fixedSeed();
    const kp = try generateKeypair(&seed);
    var c = Chain.initSigning(testing.allocator, &kp.sk, &kp.pk);

    const ev = try c.append(&[_]canonical.Member{
        .{ .key = "kind", .value = .{ .string = "net" } },
        .{ .key = "act", .value = .{ .object = &[_]canonical.Member{
            .{ .key = "dest_host", .value = .{ .string = "evildomain.example" } },
            .{ .key = "method", .value = .{ .string = "POST" } },
        } } },
    }, true);
    defer testing.allocator.free(ev.json);
    try testing.expect(ev.signed);

    const ok = try verifyEvent(testing.allocator, &kp.pk, ev.json);
    try testing.expect(ok.chain_ok and ok.sig_present and ok.sig_ok);

    // Tamper 1: flip a byte in the body (dest_host) but leave `this` alone.
    // The signature over the (stale) `this` still verifies — which is exactly
    // why a verifier MUST require chain_ok AND sig_ok: the body no longer hashes
    // to `this`, so chain_ok fails and the event is rejected.
    {
        const tampered = try testing.allocator.dupe(u8, ev.json);
        defer testing.allocator.free(tampered);
        tampered[std.mem.indexOf(u8, tampered, "evildomain").?] = 'X';
        const bad = try verifyEvent(testing.allocator, &kp.pk, tampered);
        try testing.expect(!bad.chain_ok); // body no longer matches `this`
        try testing.expect(!(bad.chain_ok and bad.sig_ok)); // combined verdict rejects
    }

    // Tamper 2: edit the `this` field itself (e.g. to make a tampered body hash
    // match). You can't re-sign without the secret key, so the signature — which
    // is over the ORIGINAL `this` — no longer matches the altered `this`, and
    // sig_ok fails. (chain_ok also fails since the body still hashes to the old
    // value.) Together with Tamper 1 this shows neither the body nor `this` can
    // be moved independently.
    {
        const tampered = try testing.allocator.dupe(u8, ev.json);
        defer testing.allocator.free(tampered);
        const this_at = std.mem.indexOf(u8, tampered, "\"this\":\"").? + "\"this\":\"".len;
        tampered[this_at] = if (tampered[this_at] == 'a') 'b' else 'a'; // flip one hex digit
        const bad = try verifyEvent(testing.allocator, &kp.pk, tampered);
        try testing.expect(!bad.sig_ok); // signature is bound to the original `this`
        try testing.expect(!(bad.chain_ok and bad.sig_ok));
    }
}

test "reserved keys are rejected" {
    var c = Chain.init(testing.allocator);
    try testing.expectError(error.ReservedKey, c.append(&[_]canonical.Member{
        .{ .key = "seq", .value = .{ .int = 99 } },
    }, false));
}

test "non-milestone append without a key still chains" {
    var c = Chain.init(testing.allocator);
    const ev = try c.append(&[_]canonical.Member{.{ .key = "kind", .value = .{ .string = "read" } }}, false);
    defer testing.allocator.free(ev.json);
    try testing.expect(!ev.signed);
    try testing.expect(std.mem.indexOf(u8, ev.json, "\"this\":") != null);
    try testing.expect(std.mem.indexOf(u8, ev.json, "\"sig\":") == null);
}
