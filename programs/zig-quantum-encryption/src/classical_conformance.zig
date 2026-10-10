//! Conformance of the hybrid KEM's classical half (src/hybrid.zig): X25519, SHA3-256,
//! HMAC-SHA3-256 / HKDF-SHA3-256 and the v1/v2 shared-secret combiners.
//!
//! hybrid.zig calls `std.crypto.dh.X25519`, `std.crypto.hash.sha3.Sha3_256` and
//! `Hkdf(Hmac(Sha3_256))`; these tests drive exactly those types and the combiners themselves.
//!   * RFC 7748 sections 5.2 (incl. 1 and 1000 iterations) and 6.1 (testdata/rfc7748/)
//!   * Wycheproof x25519_test.json, all 518 cases (testdata/wycheproof/, verbatim)
//!   * NIST ACVP SHA3-256 AFT (byte-aligned) + MCT, HMAC-SHA3-256 AFT (testdata/acvp/)
//!   * Rust differential corpus: x25519-dalek, sha3, hkdf (testdata/differential/)
//! Sources and SHA-256s: testdata/acvp/SOURCES.md.

const std = @import("std");
const records = @import("test_records.zig");
const hybrid = @import("hybrid.zig");

const testing = std.testing;
const a = testing.allocator;
const X25519 = std.crypto.dh.X25519;
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
const HmacSha3_256 = std.crypto.auth.hmac.Hmac(Sha3_256);

test "RFC 7748 X25519: 5.2 vectors, 1 and 1000 iterations, 6.1 Diffie-Hellman" {
    var it = records.iterate(@embedFile("rfc7748_x25519"));
    var n: usize = 0;
    while (it.next()) |r| : (n += 1) {
        const kind = r.str("kind");
        if (std.mem.eql(u8, kind, "vector")) {
            try testing.expectEqualSlices(u8, &try r.fixed(32, "out"), &try X25519.scalarmult(try r.fixed(32, "scalar"), try r.fixed(32, "u")));
        } else if (std.mem.eql(u8, kind, "iterate")) {
            var k = [_]u8{9} ++ [_]u8{0} ** 31;
            var u = k;
            for (0..try std.fmt.parseInt(usize, r.str("iterations"), 10)) |_| {
                const next = try X25519.scalarmult(k, u);
                u = k;
                k = next;
            }
            try testing.expectEqualSlices(u8, &try r.fixed(32, "out"), &k);
        } else {
            const ask = try r.fixed(32, "alice_sk");
            const bsk = try r.fixed(32, "bob_sk");
            try testing.expectEqualSlices(u8, &try r.fixed(32, "alice_pk"), &try X25519.recoverPublicKey(ask));
            try testing.expectEqualSlices(u8, &try r.fixed(32, "bob_pk"), &try X25519.recoverPublicKey(bsk));
            try testing.expectEqualSlices(u8, &try r.fixed(32, "shared"), &try X25519.scalarmult(ask, try r.fixed(32, "bob_pk")));
            try testing.expectEqualSlices(u8, &try r.fixed(32, "shared"), &try X25519.scalarmult(bsk, try r.fixed(32, "alice_pk")));
        }
    }
    try testing.expectEqual(@as(usize, 5), n);
}

const Wycheproof = struct {
    testGroups: []const struct {
        tests: []const struct { tcId: u32, public: []const u8, private: []const u8, shared: []const u8, result: []const u8 },
    },
};

test "Wycheproof X25519 (all 518: twist, non-canonical and low-order points, edge-case scalars)" {
    const parsed = try std.json.parseFromSlice(Wycheproof, a, @embedFile("wycheproof_x25519"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var n: usize = 0;
    var zero_shared: usize = 0;
    for (parsed.value.testGroups) |g| for (g.tests) |t| {
        try testing.expect(!std.mem.eql(u8, t.result, "invalid")); // none in this file
        var sk: [32]u8 = undefined;
        var pk: [32]u8 = undefined;
        var shared: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sk, t.private);
        _ = try std.fmt.hexToBytes(&pk, t.public);
        _ = try std.fmt.hexToBytes(&shared, t.shared);
        if (std.mem.allEqual(u8, &shared, 0)) {
            // Low-order public key. std refuses with IdentityElement; hybrid.decaps maps that to an
            // all-zero ss_X and still binds ct_X/pk_X under v2 (hybrid.zig, docs/HYBRID-V2.md).
            try testing.expectError(error.IdentityElement, X25519.scalarmult(sk, pk));
            zero_shared += 1;
        } else {
            try testing.expectEqualSlices(u8, &shared, &try X25519.scalarmult(sk, pk));
        }
        n += 1;
    };
    try testing.expectEqual(@as(usize, 518), n);
    try testing.expect(zero_shared > 0);
}

test "ACVP SHA3-256 AFT, every byte-aligned message (151, 0-65536 bits)" {
    var it = records.iterate(@embedFile("acvp_sha3_256_aft"));
    var n: usize = 0;
    while (it.next()) |r| : (n += 1) {
        const msg = try r.bytes(a, "msg");
        defer a.free(msg);
        try testing.expectEqual(try std.fmt.parseInt(usize, r.str("len"), 10), msg.len * 8);
        var out: [32]u8 = undefined;
        Sha3_256.hash(msg, &out, .{});
        try testing.expectEqualSlices(u8, &try r.fixed(32, "md"), &out);
    }
    try testing.expectEqual(@as(usize, 151), n);
}

test "ACVP SHA3-256 Monte Carlo (standard: 100 checkpoints x 1000 chained hashes)" {
    var it = records.iterate(@embedFile("acvp_sha3_256_mct"));
    var md = try it.next().?.fixed(32, "seed");
    var n: usize = 0;
    while (it.next()) |r| : (n += 1) {
        for (0..1000) |_| Sha3_256.hash(&md, &md, .{});
        try testing.expectEqualSlices(u8, &try r.fixed(32, "md"), &md);
    }
    try testing.expectEqual(@as(usize, 100), n);
}

test "ACVP HMAC-SHA3-256 AFT, all 150 (keys 1-256 bytes, truncated tags)" {
    var it = records.iterate(@embedFile("acvp_hmac_sha3_256"));
    var n: usize = 0;
    while (it.next()) |r| : (n += 1) {
        const key = try r.bytes(a, "key");
        defer a.free(key);
        const msg = try r.bytes(a, "msg");
        defer a.free(msg);
        const mac = try r.bytes(a, "mac");
        defer a.free(mac);
        var out: [32]u8 = undefined;
        HmacSha3_256.create(&out, msg, key);
        try testing.expectEqualSlices(u8, mac, out[0..mac.len]);
    }
    try testing.expectEqual(@as(usize, 150), n);
}

test "differential: X25519 (100 random scalars and u-coordinates) vs x25519-dalek" {
    var it = records.iterate(@embedFile("rust_reference"));
    var n: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.str("kind"), "x25519")) continue;
        const scalar = try r.fixed(32, "scalar");
        try testing.expectEqualSlices(u8, &try r.fixed(32, "shared"), &try X25519.scalarmult(scalar, try r.fixed(32, "u")));
        try testing.expectEqualSlices(u8, &try r.fixed(32, "public"), &try X25519.recoverPublicKey(scalar));
        n += 1;
    }
    try testing.expectEqual(@as(usize, 100), n);
}

test "differential: hybrid combiners v1 (SHA3-256) and v2 (HKDF-SHA3-256) vs RustCrypto sha3 + hkdf" {
    var it = records.iterate(@embedFile("rust_reference"));
    var n: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.str("kind"), "combiner")) continue;
        const ss_m = try r.fixed(32, "ss_m");
        const ss_x = try r.fixed(32, "ss_x");
        const ct_x = try r.fixed(32, "ct_x");
        const pk_x = try r.fixed(32, "pk_x");
        try testing.expectEqualSlices(u8, &try r.fixed(32, "v1"), &hybrid.combineSecretsV1(&ss_m, &ss_x));
        try testing.expectEqualSlices(u8, &try r.fixed(32, "v2"), &hybrid.combineSecretsV2(&ss_m, &ss_x, &ct_x, &pk_x));
        n += 1;
    }
    try testing.expectEqual(@as(usize, 100), n);
}
