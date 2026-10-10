//! NIST ACVP known-answer tests for ML-KEM-768 (FIPS 203) and ML-DSA-65 (FIPS 204): every
//! ML-KEM-768 / ML-DSA-65 test case in the ACVP-Server gen-val set that this library's interface
//! can express, not a sample.
//!
//! Data: testdata/acvp/*.txt, extracted verbatim by tools/extract_acvp.py from
//! https://github.com/usnistgov/ACVP-Server/tree/975de31eb83d87039ec88934fdc47d8c312b892d/gen-val/json-files
//! (ML-KEM-keyGen-FIPS203, ML-KEM-encapDecap-FIPS203, ML-DSA-keyGen-FIPS204,
//! ML-DSA-sigGen-FIPS204, ML-DSA-sigVer-FIPS204; `internalProjection.json` of each). Inputs AND
//! expected outputs are NIST's; no value here was produced by this code.
//!
//! Not covered, because the library does not implement them (docs/CRYPTO-CONFORMANCE.md):
//! ML-KEM-512/1024, ML-DSA-44/87, HashML-DSA (preHash groups), externalMu groups.

const std = @import("std");
const records = @import("test_records.zig");
const mlkem = @import("ml_kem_api.zig");
const ml_dsa = @import("ml_dsa.zig");

const testing = std.testing;

const kem_keygen = @embedFile("acvp_mlkem768_keygen");
const kem_encaps = @embedFile("acvp_mlkem768_encaps");
const kem_decaps = @embedFile("acvp_mlkem768_decaps");
const kem_dkcheck = @embedFile("acvp_mlkem768_dkcheck");
const kem_ekcheck = @embedFile("acvp_mlkem768_ekcheck");
const dsa_keygen = @embedFile("acvp_mldsa65_keygen");
const dsa_siggen = @embedFile("acvp_mldsa65_siggen");
const dsa_sigver = @embedFile("acvp_mldsa65_sigver");

const EK = @sizeOf(mlkem.EncapsulationKey768);
const DK = @sizeOf(mlkem.DecapsulationKey768);
const CT = @sizeOf(mlkem.Ciphertext768);

test "ACVP ML-KEM-768 keyGen: all 25 AFT cases (d, z -> ek, dk)" {
    try testing.expectEqual(@as(usize, 25), records.count(kem_keygen));
    var it = records.iterate(kem_keygen);
    while (it.next()) |r| {
        const kp = try mlkem.keyGenInternal768(&try r.fixed(32, "d"), &try r.fixed(32, "z"));
        try testing.expectEqualSlices(u8, &try r.fixed(EK, "ek"), &kp.ek.data);
        try testing.expectEqualSlices(u8, &try r.fixed(DK, "dk"), &kp.dk.data);
    }
}

test "ACVP ML-KEM-768 encapsulation: all 25 AFT cases (ek, m -> c, K)" {
    try testing.expectEqual(@as(usize, 25), records.count(kem_encaps));
    var it = records.iterate(kem_encaps);
    while (it.next()) |r| {
        const ek = mlkem.EncapsulationKey768{ .data = try r.fixed(EK, "ek") };
        const res = try mlkem.encapsInternal768(&ek, &try r.fixed(32, "m"));
        try testing.expectEqualSlices(u8, &try r.fixed(CT, "c"), &res.c.data);
        try testing.expectEqualSlices(u8, &try r.fixed(32, "k"), &res.K);
    }
}

test "ACVP ML-KEM-768 decapsulation: all 10 VAL cases, valid and implicit-rejection (dk, c -> K)" {
    try testing.expectEqual(@as(usize, 10), records.count(kem_decaps));
    var it = records.iterate(kem_decaps);
    var rejected: usize = 0;
    while (it.next()) |r| {
        const dk = mlkem.DecapsulationKey768{ .data = try r.fixed(DK, "dk") };
        const c = mlkem.Ciphertext768{ .data = try r.fixed(CT, "c") };
        // For "modified ciphertext" cases NIST's K is the implicit-rejection secret J(z || c).
        try testing.expectEqualSlices(u8, &try r.fixed(32, "k"), &mlkem.decaps768(&dk, &c));
        try testing.expectEqualSlices(u8, &try r.fixed(32, "k"), &try mlkem.decaps768Checked(&dk, &c));
        if (std.mem.eql(u8, r.str("reason"), "modified ciphertext")) rejected += 1;
    }
    try testing.expect(rejected > 0);
}

test "ACVP ML-KEM-768 decapsulationKeyCheck: all 10 VAL cases" {
    try testing.expectEqual(@as(usize, 10), records.count(kem_dkcheck));
    var it = records.iterate(kem_dkcheck);
    var failing: usize = 0;
    while (it.next()) |r| {
        const dk = mlkem.DecapsulationKey768{ .data = try r.fixed(DK, "dk") };
        try testing.expectEqual(r.flag("passed"), mlkem.validateDecapsulationKey768(&dk));
        if (!r.flag("passed")) failing += 1;
    }
    try testing.expect(failing > 0);
}

test "ACVP ML-KEM-768 encapsulationKeyCheck: all 10 VAL cases" {
    try testing.expectEqual(@as(usize, 10), records.count(kem_ekcheck));
    var it = records.iterate(kem_ekcheck);
    var failing: usize = 0;
    while (it.next()) |r| {
        const ek = mlkem.EncapsulationKey768{ .data = try r.fixed(EK, "ek") };
        try testing.expectEqual(r.flag("passed"), mlkem.validateEncapsulationKey768(&ek));
        if (!r.flag("passed")) {
            failing += 1;
            // A key that fails the check must also be refused by encapsulation.
            try testing.expectError(error.InvalidEncapsulationKey, mlkem.encapsInternal768(&ek, &([_]u8{0} ** 32)));
        }
    }
    try testing.expect(failing > 0);
}

test "ACVP ML-DSA-65 keyGen: all 25 AFT cases (seed -> pk, sk)" {
    try testing.expectEqual(@as(usize, 25), records.count(dsa_keygen));
    var it = records.iterate(dsa_keygen);
    while (it.next()) |r| {
        const kp = try ml_dsa.keyGen(&try r.fixed(32, "seed"));
        try testing.expectEqualSlices(u8, &try r.fixed(ml_dsa.PUBLIC_KEY_SIZE, "pk"), &kp.pk.data);
        try testing.expectEqualSlices(u8, &try r.fixed(ml_dsa.SECRET_KEY_SIZE, "sk"), &kp.sk.data);
    }
}

test "ACVP ML-DSA-65 sigGen: pure external and internal, deterministic and hedged (60 cases)" {
    const a = testing.allocator;
    try testing.expectEqual(@as(usize, 60), records.count(dsa_siggen));
    var it = records.iterate(dsa_siggen);
    var seen = [_]usize{0} ** 4; // [external det, external hedged, internal det, internal hedged]
    while (it.next()) |r| {
        const sk = ml_dsa.SecretKey{ .data = try r.fixed(ml_dsa.SECRET_KEY_SIZE, "sk") };
        const msg = try r.bytes(a, "message");
        defer a.free(msg);
        const rnd = try r.fixed(32, "rnd");
        const det = r.flag("deterministic");
        if (det) try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &rnd);
        const external = std.mem.eql(u8, r.str("interface"), "external");

        const sig = if (external) blk: {
            const ctx = try r.bytes(a, "context");
            defer a.free(ctx);
            if (det) {
                // The production entry point must agree with the explicit-rnd one.
                const s0 = try ml_dsa.signWithContext(&sk, msg, ctx, false);
                try testing.expectEqualSlices(u8, &try r.fixed(ml_dsa.SIGNATURE_SIZE, "signature"), &s0.data);
            }
            break :blk try ml_dsa.signWithContextRnd(&sk, msg, ctx, &rnd);
        } else blk: {
            if (det) {
                const s0 = try ml_dsa.sign(&sk, msg, false);
                try testing.expectEqualSlices(u8, &try r.fixed(ml_dsa.SIGNATURE_SIZE, "signature"), &s0.data);
            }
            break :blk try ml_dsa.signInternalWithRnd(&sk, msg, &rnd);
        };
        try testing.expectEqualSlices(u8, &try r.fixed(ml_dsa.SIGNATURE_SIZE, "signature"), &sig.data);
        seen[@as(usize, if (external) 0 else 2) + @intFromBool(!det)] += 1;
    }
    for (seen) |n| try testing.expectEqual(@as(usize, 15), n);
}

test "ACVP ML-DSA-65 sigVer: pure external and internal, accept and every reject reason (30 cases)" {
    const a = testing.allocator;
    try testing.expectEqual(@as(usize, 30), records.count(dsa_sigver));
    var it = records.iterate(dsa_sigver);
    var rejects: usize = 0;
    while (it.next()) |r| {
        const pk = ml_dsa.PublicKey{ .data = try r.fixed(ml_dsa.PUBLIC_KEY_SIZE, "pk") };
        const sig = ml_dsa.Signature{ .data = try r.fixed(ml_dsa.SIGNATURE_SIZE, "signature") };
        const msg = try r.bytes(a, "message");
        defer a.free(msg);
        const ok = if (std.mem.eql(u8, r.str("interface"), "external")) blk: {
            const ctx = try r.bytes(a, "context");
            defer a.free(ctx);
            break :blk ml_dsa.verifyWithContext(&pk, msg, ctx, &sig);
        } else ml_dsa.verify(&pk, msg, &sig);
        if (ok != r.flag("passed")) {
            std.debug.print("sigVer tgId={s} tcId={s} reason={s}: expected {}, got {}\n", .{ r.str("tgId"), r.str("tcId"), r.str("reason"), r.flag("passed"), ok });
            return error.TestUnexpectedResult;
        }
        if (!ok) rejects += 1;
    }
    try testing.expect(rejects > 0);
}
