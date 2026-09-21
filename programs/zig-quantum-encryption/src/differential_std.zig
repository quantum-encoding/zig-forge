//! Differential tests against Zig's standard library.
//!
//! `std.crypto.kem.ml_kem` and `std.crypto.sign.mldsa` are independent implementations of FIPS 203
//! and FIPS 204. Driving both with the same seeds and demanding byte-for-byte agreement checks
//! far more of the input space than the handful of ACVP anchors in `*_tier1_anchors.zig`, and it
//! is what caught the framing difference between `ml_dsa.sign` and the standard `ML-DSA.Sign`.
//!
//! std is a TEST-ONLY dependency: the library proper does not import either module.

const std = @import("std");
const kem = @import("ml_kem_api.zig");
const dsa = @import("ml_dsa.zig");

const StdKem = std.crypto.kem.ml_kem.MLKem768;
const StdDsa = std.crypto.sign.mldsa.MLDSA65;

test "ML-KEM-768 agrees with std on keys, ciphertexts, secrets, cross-decaps and implicit rejection" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    for (0..150) |_| {
        var d: [32]u8 = undefined;
        var z: [32]u8 = undefined;
        var m: [32]u8 = undefined;
        r.bytes(&d);
        r.bytes(&z);
        r.bytes(&m);

        const mine = try kem.keyGenInternal768(&d, &z);
        const theirs = try StdKem.KeyPair.generateDeterministic(d ++ z);
        try std.testing.expectEqualSlices(u8, &theirs.public_key.toBytes(), &mine.ek.data);
        try std.testing.expectEqualSlices(u8, &theirs.secret_key.toBytes(), &mine.dk.data);
        try std.testing.expect(kem.validateDecapsulationKey768(&mine.dk));

        const my_enc = try kem.encapsInternal768(&mine.ek, &m);
        const their_enc = theirs.public_key.encapsDeterministic(&m);
        try std.testing.expectEqualSlices(u8, &their_enc.ciphertext, &my_enc.c.data);
        try std.testing.expectEqualSlices(u8, &their_enc.shared_secret, &my_enc.K);

        // each side opens the other's ciphertext
        const opened = try kem.decaps768Checked(&mine.dk, &kem.Ciphertext768{ .data = their_enc.ciphertext });
        try std.testing.expectEqualSlices(u8, &their_enc.shared_secret, &opened);
        try std.testing.expectEqualSlices(u8, &my_enc.K, &(try theirs.secret_key.decaps(&my_enc.c.data)));

        // a damaged ciphertext must yield the SAME pseudorandom secret on both sides (K-bar = J(z ‖ c))
        var bad = my_enc.c.data;
        bad[r.uintLessThan(usize, bad.len)] ^= @as(u8, 1) << r.int(u3);
        const rejected = kem.decaps768(&mine.dk, &kem.Ciphertext768{ .data = bad });
        try std.testing.expectEqualSlices(u8, &(try theirs.secret_key.decaps(&bad)), &rejected);
        try std.testing.expect(!std.mem.eql(u8, &rejected, &my_enc.K));
    }
}

test "ML-KEM-768: both reject a non-canonical encapsulation key" {
    const d: [32]u8 = @splat(1);
    const z: [32]u8 = @splat(2);
    var kp = try kem.keyGenInternal768(&d, &z);
    kp.ek.data[0] = 0xFF;
    kp.ek.data[1] |= 0x0F; // first coefficient = 4095 >= q
    try std.testing.expectError(error.NonCanonical, StdKem.PublicKey.fromBytes(&kp.ek.data));
    try std.testing.expect(!kem.validateEncapsulationKey768(&kp.ek));
    const m: [32]u8 = @splat(3);
    try std.testing.expectError(error.InvalidEncapsulationKey, kem.encapsInternal768(&kp.ek, &m));
}

test "ML-DSA-65 keys agree with std; signWithContext IS the standard ML-DSA.Sign" {
    var prng = std.Random.DefaultPrng.init(0xd5a);
    const r = prng.random();
    const contexts = [_][]const u8{ "", "quantum-vault/v2", "x" ** 255 };
    for (0..24) |i| {
        var xi: [32]u8 = undefined;
        r.bytes(&xi);
        var msg_buf: [300]u8 = undefined;
        const msg = msg_buf[0 .. (i * 13) % 300];
        r.bytes(msg);
        const ctx = contexts[i % contexts.len];

        const mine = try dsa.keyGen(&xi);
        const theirs = try StdDsa.KeyPair.generateDeterministic(xi);
        try std.testing.expectEqualSlices(u8, &theirs.public_key.toBytes(), &mine.pk.data);
        try std.testing.expectEqualSlices(u8, &theirs.secret_key.toBytes(), &mine.sk.data);

        // deterministic signatures are byte-identical
        const my_sig = try dsa.signWithContext(&mine.sk, msg, ctx, false);
        const std_sig = try theirs.signWithContext(msg, null, ctx);
        try std.testing.expectEqualSlices(u8, &std_sig.toBytes(), &my_sig.data);

        // and each verifier accepts the other's signature, hedged included
        try (try StdDsa.Signature.fromBytes(my_sig.data)).verifyWithContext(msg, theirs.public_key, ctx);
        try std.testing.expect(dsa.verifyWithContext(&mine.pk, msg, ctx, &dsa.Signature{ .data = std_sig.toBytes() }));
        const hedged = try dsa.signWithContext(&mine.sk, msg, ctx, true);
        try (try StdDsa.Signature.fromBytes(hedged.data)).verifyWithContext(msg, theirs.public_key, ctx);

        // the context is bound: a different one must not verify, on either side
        try std.testing.expect(!dsa.verifyWithContext(&mine.pk, msg, "other", &my_sig));
        try std.testing.expectError(error.SignatureVerificationFailed, (try StdDsa.Signature.fromBytes(my_sig.data)).verifyWithContext(msg, theirs.public_key, "other"));
    }
}

test "ML-DSA-65: the v1 internal framing is NOT the standard interface (documented, and pinned)" {
    const xi: [32]u8 = @splat(7);
    const mine = try dsa.keyGen(&xi);
    const theirs = try StdDsa.KeyPair.generateDeterministic(xi);
    const msg = "framing";

    const v1 = try dsa.sign(&mine.sk, msg, false);
    try std.testing.expect(dsa.verify(&mine.pk, msg, &v1)); // verifies with its own counterpart ...
    try std.testing.expectError(error.SignatureVerificationFailed, (try StdDsa.Signature.fromBytes(v1.data)).verify(msg, theirs.public_key)); // ... and nowhere else
    try std.testing.expect(!dsa.verifyWithContext(&mine.pk, msg, "", &v1)); // the two framings never cross-verify

    // v1 is Sign_internal, so framing the message by hand reproduces the standard signature exactly
    const framed = [_]u8{ 0, 0 } ++ msg.*;
    const by_hand = try dsa.sign(&mine.sk, &framed, false);
    try std.testing.expectEqualSlices(u8, &(try theirs.sign(msg, null)).toBytes(), &by_hand.data);
}

test "ML-DSA-65: both verifiers reach the same verdict on 2000 mutated signatures" {
    var prng = std.Random.DefaultPrng.init(0xbad51);
    const r = prng.random();
    const xi: [32]u8 = @splat(9);
    const mine = try dsa.keyGen(&xi);
    const theirs = try StdDsa.KeyPair.generateDeterministic(xi);
    const good = try dsa.signWithContext(&mine.sk, "strictness", "ctx", false);
    for (0..2000) |t| {
        var s = good.data;
        // half the mutations land in the hint region at the tail, where the canonical-encoding
        // rules that make ML-DSA strongly unforgeable live
        const pos = if (t % 2 == 0) r.uintLessThan(usize, s.len) else s.len - 1 - r.uintLessThan(usize, 61);
        s[pos] ^= @as(u8, 1) << r.int(u3);
        const ours = dsa.verifyWithContext(&mine.pk, "strictness", "ctx", &dsa.Signature{ .data = s });
        const std_verdict = blk: {
            const parsed = StdDsa.Signature.fromBytes(s) catch break :blk false;
            parsed.verifyWithContext("strictness", theirs.public_key, "ctx") catch break :blk false;
            break :blk true;
        };
        try std.testing.expectEqual(std_verdict, ours);
    }
}

test "context longer than 255 bytes is refused, not truncated" {
    const xi: [32]u8 = @splat(5);
    const kp = try dsa.keyGen(&xi);
    const long = "c" ** 256;
    try std.testing.expectError(error.ContextTooLong, dsa.signWithContext(&kp.sk, "m", long, false));
    const sig = try dsa.signWithContext(&kp.sk, "m", long[0..255], false);
    try std.testing.expect(!dsa.verifyWithContext(&kp.pk, "m", long, &sig));
}
