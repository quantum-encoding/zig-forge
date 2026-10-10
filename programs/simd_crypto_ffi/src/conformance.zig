//! Standards conformance for the quantum_* C ABI (libquantum_crypto.a): every primitive the
//! wallets call, driven through the exported functions, against vectors someone else published
//! and against independent reference implementations.
//!
//! External vector sets (testdata/, provenance and SHA-256s in testdata/SOURCES.md):
//!   NIST CAVP SHAVS byte-oriented SHA-256 / SHA-512 Short, Long and Monte Carlo; NIST CAVP HMAC
//!   (L=32, L=64); RFC 4231; RFC 7914 section 11; BIP-0039 (Trezor vectors.json); BLAKE3 team
//!   test_vectors.json; RFC 8439 2.4.2, A.1, A.2; RIPEMD-160 designers' page; BIP-0032 vectors
//!   1-4; BIP-0350 valid addresses; tiny-secp256k1 ecdsa.json.
//! Differential corpus (testdata/differential/rust_reference.txt): outputs of the Rust crates
//! walletcore links (sha2, hmac, pbkdf2, blake3, chacha20, ripemd, bitcoin/libsecp256k1, k256)
//! on SplitMix64-expanded inputs, written by tools/crypto-refgen.
//!
//! `zig build test` compiles this file twice: for the host CPU (hardware SHA-2, NEON/AVX2
//! ChaCha20 and BLAKE3 lanes) and for the same CPU with those features removed (portable
//! scalar code). Both runs must match the same expected bytes, which is the SIMD-vs-scalar
//! agreement check; `build_options.scalar_only` and the "paths" test below prove the two
//! builds really took different code paths.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const ffi = @import("ffi-grok.zig");
const bip32 = @import("bitcoin/bip32.zig");
const records = @import("test_records.zig");

/// The exports under test, called through their C symbols exactly as walletcore declares them
/// (tauri_packages/walletcore/src/quantum_crypto.rs), not through Zig-level names.
const c = struct {
    const u8p = [*c]const u8;
    const CKey = ffi.CExtendedKey;
    extern fn quantum_sha256(in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_sha256d(in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_sha512(in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_sha256d_batch(ins: [*c]const u8p, len: usize, outs: [*c][*c]u8, count: usize) c_int;
    extern fn quantum_sha256d_batch_size() usize;
    extern fn quantum_blake3(in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_blake3_variable(in: u8p, len: usize, out: [*c]u8, out_len: usize) c_int;
    extern fn quantum_ripemd160(in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_hmac_sha256(key: u8p, key_len: usize, msg: u8p, msg_len: usize, out: [*c]u8) c_int;
    extern fn quantum_hmac_sha512(key: u8p, key_len: usize, msg: u8p, msg_len: usize, out: [*c]u8) c_int;
    extern fn quantum_pbkdf2_sha256(pw: u8p, pw_len: usize, salt: u8p, salt_len: usize, iterations: u32, out: [*c]u8, out_len: usize) c_int;
    extern fn quantum_pbkdf2_sha512(pw: u8p, pw_len: usize, salt: u8p, salt_len: usize, iterations: u32, out: [*c]u8, out_len: usize) c_int;
    extern fn quantum_chacha20_encrypt(key: u8p, nonce: u8p, counter: u32, in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_chacha20_decrypt(key: u8p, nonce: u8p, counter: u32, in: u8p, len: usize, out: [*c]u8) c_int;
    extern fn quantum_secure_compare(x: u8p, y: u8p, len: usize) c_int;
    extern fn quantum_ecdsa_sign(hash: u8p, sk: u8p, sig_out: [*c]u8, sig_len: *usize) c_int;
    extern fn quantum_derive_pubkey(sk: u8p, pk_out: [*c]u8) c_int;
    extern fn quantum_bip32_from_seed(seed: u8p, seed_len: usize, out: *CKey) c_int;
    extern fn quantum_bip32_derive_path(master: *const CKey, path: u8p, path_len: usize, out: *CKey) c_int;
    extern fn quantum_bip32_neuter(key: *const CKey, out: *CKey) c_int;
    extern fn quantum_bip32_serialize(key: *const CKey, mainnet: c_int, out: [*c]u8) c_int;
    extern fn quantum_bip32_p2wpkh_address(pk: u8p, mainnet: c_int, out: [*c]u8) c_int;
    extern fn quantum_bip32_hash160(pk: u8p, out: [*c]u8) c_int;
};

const testing = std.testing;
const a = testing.allocator;

// ---------------------------------------------------------------------------------------------
// Which implementation std.crypto compiled in. These mirror the selection logic in
// lib/std/crypto/{sha2,chacha20,blake3}.zig of Zig 0.16.
// ---------------------------------------------------------------------------------------------

const sha2_accelerated = switch (builtin.cpu.arch) {
    .aarch64 => builtin.cpu.has(.aarch64, .sha2),
    .x86_64 => builtin.cpu.hasAll(.x86, &.{ .sha, .avx2 }),
    else => false,
};
const chacha_vectorised = switch (builtin.cpu.arch) {
    .aarch64 => builtin.cpu.has(.aarch64, .neon),
    .x86_64 => true, // ChaChaVecImpl(…, 1) even without AVX2; degree 2/4 with AVX2/AVX-512
    else => false,
};
const blake3_simd_degree = std.simd.suggestVectorLength(u32) orelse 1;

test "paths: the scalar build has no SIMD/crypto-extension path, the native build has them" {
    std.debug.print("\n[conformance] cpu={s} scalar_only={} sha2_hw={} chacha_vec={} blake3_simd_degree={}\n", .{
        builtin.cpu.model.name, build_options.scalar_only, sha2_accelerated, chacha_vectorised, blake3_simd_degree,
    });
    if (build_options.scalar_only) {
        try testing.expect(!sha2_accelerated);
        if (builtin.cpu.arch == .aarch64) try testing.expect(!chacha_vectorised);
        try testing.expect(blake3_simd_degree <= 2);
    } else if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) {
        // Every Apple-silicon Mac has the ARMv8 SHA-2 extension and NEON.
        try testing.expect(sha2_accelerated and chacha_vectorised and blake3_simd_degree >= 4);
    }
}

fn hexEq(expected_hex: []const u8, actual: []const u8) !void {
    const e = try a.alloc(u8, expected_hex.len / 2);
    defer a.free(e);
    _ = try std.fmt.hexToBytes(e, expected_hex);
    try testing.expectEqualSlices(u8, e, actual);
}

// ---------------------------------------------------------------------------------------------
// NIST CAVP SHAVS (byte-oriented), FIPS 180-4
// ---------------------------------------------------------------------------------------------

fn shavsMsg(r: records.Record) ![]u8 {
    const bits = r.int(usize, "Len");
    const m = try r.bytes(a, "Msg");
    if (bits == 0) {
        a.free(m);
        return a.alloc(u8, 0); // NIST writes the empty message as "Msg = 00"
    }
    try testing.expectEqual(bits / 8, m.len);
    return m;
}

fn runShavs(comptime digest_len: usize, comptime f: anytype, text: []const u8, expected_count: usize) !void {
    var it = records.iterate(text);
    var n: usize = 0;
    while (it.next()) |r| {
        const m = try shavsMsg(r);
        defer a.free(m);
        var out: [digest_len]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), f(m.ptr, m.len, &out));
        try testing.expectEqualSlices(u8, &try r.fixed(digest_len, "MD"), &out);
        n += 1;
    }
    try testing.expectEqual(expected_count, n);
}

test "NIST SHAVS SHA-256 ShortMsg (65) and LongMsg (64) via quantum_sha256" {
    try runShavs(32, c.quantum_sha256, @embedFile("SHA256ShortMsg"), 65);
    try runShavs(32, c.quantum_sha256, @embedFile("SHA256LongMsg"), 64);
}

test "NIST SHAVS SHA-512 ShortMsg (129) and LongMsg (128) via quantum_sha512" {
    try runShavs(64, c.quantum_sha512, @embedFile("SHA512ShortMsg"), 129);
    try runShavs(64, c.quantum_sha512, @embedFile("SHA512LongMsg"), 128);
}

/// SHAVS Monte Carlo (byte-oriented): MD_i = H(MD_{i-3} || MD_{i-2} || MD_{i-1}), 1000 rounds
/// per checkpoint, 100 checkpoints, each seeding the next.
fn runShavsMonte(comptime n: usize, comptime f: anytype, text: []const u8) !void {
    var it = records.iterate(text);
    const seed_rec = it.next().?;
    var seed = try seed_rec.fixed(n, "Seed");
    var checkpoints: usize = 0;
    while (it.next()) |r| {
        var md: [3][n]u8 = .{ seed, seed, seed };
        for (0..1000) |_| {
            var msg: [3 * n]u8 = undefined;
            @memcpy(msg[0..n], &md[0]);
            @memcpy(msg[n .. 2 * n], &md[1]);
            @memcpy(msg[2 * n ..], &md[2]);
            var next: [n]u8 = undefined;
            try testing.expectEqual(@as(c_int, 0), f(&msg, msg.len, &next));
            md = .{ md[1], md[2], next };
        }
        try testing.expectEqual(checkpoints, r.int(usize, "COUNT"));
        try testing.expectEqualSlices(u8, &try r.fixed(n, "MD"), &md[2]);
        seed = md[2];
        checkpoints += 1;
    }
    try testing.expectEqual(@as(usize, 100), checkpoints);
}

test "NIST SHAVS SHA-256 Monte Carlo (100 checkpoints x 1000) via quantum_sha256" {
    try runShavsMonte(32, c.quantum_sha256, @embedFile("SHA256Monte"));
}

test "NIST SHAVS SHA-512 Monte Carlo (100 checkpoints x 1000) via quantum_sha512" {
    try runShavsMonte(64, c.quantum_sha512, @embedFile("SHA512Monte"));
}

// ---------------------------------------------------------------------------------------------
// HMAC: NIST CAVP HMAC.rsp, RFC 4231
// ---------------------------------------------------------------------------------------------

test "NIST CAVP HMAC-SHA-256 (L=32, 225 cases) and HMAC-SHA-512 (L=64, 375 cases), truncated tags" {
    var it = records.iterate(@embedFile("HMAC"));
    var n256: usize = 0;
    var n512: usize = 0;
    while (it.next()) |r| {
        const is256 = std.mem.eql(u8, r.section, "L=32");
        const is512 = std.mem.eql(u8, r.section, "L=64");
        if (!is256 and !is512) continue;
        const key = try r.bytes(a, "Key");
        defer a.free(key);
        const msg = try r.bytes(a, "Msg");
        defer a.free(msg);
        const tag = try r.bytes(a, "Mac");
        defer a.free(tag);
        try testing.expectEqual(r.int(usize, "Klen"), key.len);
        try testing.expectEqual(r.int(usize, "Tlen"), tag.len);
        var out: [64]u8 = undefined;
        const rc = if (is256)
            c.quantum_hmac_sha256(key.ptr, key.len, msg.ptr, msg.len, &out)
        else
            c.quantum_hmac_sha512(key.ptr, key.len, msg.ptr, msg.len, &out);
        try testing.expectEqual(@as(c_int, 0), rc);
        try testing.expectEqualSlices(u8, tag, out[0..tag.len]);
        if (is256) n256 += 1 else n512 += 1;
    }
    try testing.expectEqual(@as(usize, 225), n256);
    try testing.expectEqual(@as(usize, 375), n512);
}

test "RFC 4231 test cases 1-7, HMAC-SHA-256 and HMAC-SHA-512 (incl. 131-byte keys, 128-bit truncation)" {
    var it = records.iterate(@embedFile("rfc4231_hmac"));
    var n: usize = 0;
    while (it.next()) |r| {
        const key = try r.bytes(a, "key");
        defer a.free(key);
        const data = try r.bytes(a, "data");
        defer a.free(data);
        const trunc = r.int(usize, "truncate_bits") / 8;
        var o256: [32]u8 = undefined;
        var o512: [64]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_hmac_sha256(key.ptr, key.len, data.ptr, data.len, &o256));
        try testing.expectEqual(@as(c_int, 0), c.quantum_hmac_sha512(key.ptr, key.len, data.ptr, data.len, &o512));
        try hexEq(r.str("sha256"), o256[0 .. if (trunc != 0) trunc else 32]);
        try hexEq(r.str("sha512"), o512[0 .. if (trunc != 0) trunc else 64]);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 7), n);
}

// ---------------------------------------------------------------------------------------------
// PBKDF2: RFC 7914 section 11 (HMAC-SHA-256); BIP-0039 (HMAC-SHA-512, 2048 rounds)
// ---------------------------------------------------------------------------------------------

test "RFC 7914 section 11 PBKDF2-HMAC-SHA-256 (c=1 and c=80000) via quantum_pbkdf2_sha256" {
    var it = records.iterate(@embedFile("rfc7914_pbkdf2_sha256"));
    var n: usize = 0;
    while (it.next()) |r| {
        const pw = try r.bytes(a, "password");
        defer a.free(pw);
        const salt = try r.bytes(a, "salt");
        defer a.free(salt);
        const dk = try r.bytes(a, "dk");
        defer a.free(dk);
        const out = try a.alloc(u8, dk.len);
        defer a.free(out);
        try testing.expectEqual(@as(c_int, 0), c.quantum_pbkdf2_sha256(pw.ptr, pw.len, salt.ptr, salt.len, r.int(u32, "iterations"), out.ptr, out.len));
        try testing.expectEqualSlices(u8, dk, out);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
}

const Bip39Vectors = struct { english: []const [4][]const u8 };

test "BIP-0039 English vectors (24): mnemonic -> seed (PBKDF2-HMAC-SHA512, 'TREZOR') -> BIP-0032 master xprv" {
    const parsed = try std.json.parseFromSlice(Bip39Vectors, a, @embedFile("bip39_vectors"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 24), parsed.value.english.len);
    for (parsed.value.english) |v| {
        const mnemonic = v[1];
        const salt = "mnemonicTREZOR";
        var seed: [64]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_pbkdf2_sha512(mnemonic.ptr, mnemonic.len, salt.ptr, salt.len, 2048, &seed, 64));
        try hexEq(v[2], &seed);

        var master: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_from_seed(&seed, seed.len, &master));
        var ser: [82]u8 = undefined;
        try testing.expectEqual(@as(c_int, 82), c.quantum_bip32_serialize(&master, 1, &ser));
        var buf: [90]u8 = undefined;
        try testing.expectEqualSlices(u8, try records.base58Decode(&buf, v[3]), &ser);
    }
}

// ---------------------------------------------------------------------------------------------
// BLAKE3 (official test_vectors.json, hash mode; keyed_hash/derive_key are not exported)
// ---------------------------------------------------------------------------------------------

const Blake3Vectors = struct { cases: []const struct { input_len: usize, hash: []const u8 } };

test "BLAKE3 official vectors, all 35 lengths: 32-byte hash and the full 131-byte XOF output" {
    const parsed = try std.json.parseFromSlice(Blake3Vectors, a, @embedFile("blake3_vectors"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 35), parsed.value.cases.len);
    for (parsed.value.cases) |case| {
        const input = try a.alloc(u8, case.input_len);
        defer a.free(input);
        for (input, 0..) |*b, i| b.* = @intCast(i % 251);
        var h32: [32]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_blake3(input.ptr, input.len, &h32));
        try hexEq(case.hash[0..64], &h32);
        const xof = try a.alloc(u8, case.hash.len / 2);
        defer a.free(xof);
        try testing.expectEqual(@as(c_int, 0), c.quantum_blake3_variable(input.ptr, input.len, xof.ptr, xof.len));
        try hexEq(case.hash, xof);
    }
}

// ---------------------------------------------------------------------------------------------
// ChaCha20, RFC 8439
// ---------------------------------------------------------------------------------------------

test "RFC 8439 ChaCha20: 2.4.2, A.1 #1-#5 (keystreams), A.2 #1-#3, encrypt and decrypt" {
    var it = records.iterate(@embedFile("rfc8439_chacha20"));
    var n: usize = 0;
    while (it.next()) |r| {
        const key = try r.fixed(32, "key");
        const nonce = try r.fixed(12, "nonce");
        const pt = try r.bytes(a, "plaintext");
        defer a.free(pt);
        const ct = try r.bytes(a, "ciphertext");
        defer a.free(ct);
        const out = try a.alloc(u8, pt.len);
        defer a.free(out);
        try testing.expectEqual(@as(c_int, 0), c.quantum_chacha20_encrypt(&key, &nonce, r.int(u32, "counter"), pt.ptr, pt.len, out.ptr));
        try testing.expectEqualSlices(u8, ct, out);
        try testing.expectEqual(@as(c_int, 0), c.quantum_chacha20_decrypt(&key, &nonce, r.int(u32, "counter"), ct.ptr, ct.len, out.ptr));
        try testing.expectEqualSlices(u8, pt, out);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 9), n);
}

// ---------------------------------------------------------------------------------------------
// RIPEMD-160 (hand-written in bitcoin/bip32.zig, so it gets the designers' full set)
// ---------------------------------------------------------------------------------------------

test "RIPEMD-160 designers' vectors (8 strings + one million 'a') via quantum_ripemd160" {
    var it = records.iterate(@embedFile("ripemd160_vectors"));
    var n: usize = 0;
    while (it.next()) |r| {
        const msg = if (r.get("message")) |_| try r.bytes(a, "message") else blk: {
            const m = try a.alloc(u8, r.int(usize, "count"));
            @memset(m, r.str("repeat")[0]);
            break :blk m;
        };
        defer a.free(msg);
        var out: [20]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_ripemd160(msg.ptr, msg.len, &out));
        try testing.expectEqualSlices(u8, &try r.fixed(20, "digest"), &out);
        // Incremental updates in odd-sized pieces must agree with the one-shot hash.
        var h = bip32.Ripemd160.init();
        var off: usize = 0;
        var step: usize = 1;
        while (off < msg.len) : (step = step * 3 % 131 + 1) {
            const e = @min(msg.len, off + step);
            h.update(msg[off..e]);
            off = e;
        }
        var inc: [20]u8 = undefined;
        h.final(&inc);
        try testing.expectEqualSlices(u8, &out, &inc);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 9), n);
}

// ---------------------------------------------------------------------------------------------
// BIP-0032 vectors 1-4 through the C ABI; BIP-0350 addresses through the encoder
// ---------------------------------------------------------------------------------------------

test "BIP-0032 test vectors 1-4: every chain's xprv and xpub (17 nodes) via quantum_bip32_*" {
    var it = records.iterate(@embedFile("bip32_vectors"));
    var n: usize = 0;
    while (it.next()) |r| {
        const seed = try r.bytes(a, "seed");
        defer a.free(seed);
        var master: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_from_seed(seed.ptr, seed.len, &master));
        const chain = r.str("chain");
        var node = master;
        if (!std.mem.eql(u8, chain, "m"))
            try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_derive_path(&master, chain.ptr, chain.len, &node));
        var pubnode: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_neuter(&node, &pubnode));
        var buf: [90]u8 = undefined;
        var ser: [82]u8 = undefined;
        try testing.expectEqual(@as(c_int, 82), c.quantum_bip32_serialize(&node, 1, &ser));
        try testing.expectEqualSlices(u8, try records.base58Decode(&buf, r.str("xprv")), &ser);
        try testing.expectEqual(@as(c_int, 82), c.quantum_bip32_serialize(&pubnode, 1, &ser));
        try testing.expectEqualSlices(u8, try records.base58Decode(&buf, r.str("xpub")), &ser);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 17), n);
}

test "BIP-0350 valid segwit addresses (v0 bech32, v1-v16 bech32m): scriptPubKey -> address" {
    var it = records.iterate(@embedFile("bech32_valid"));
    var n: usize = 0;
    while (it.next()) |r| {
        const script = try r.bytes(a, "script");
        defer a.free(script);
        const version: u8 = if (script[0] == 0) 0 else script[0] - 0x50;
        try testing.expectEqual(script.len - 2, script[1]);
        var lower: [100]u8 = undefined;
        const addr = std.ascii.lowerString(&lower, r.str("address"));
        const sep = std.mem.lastIndexOfScalar(u8, addr, '1').?;
        var out: [100]u8 = undefined;
        const len = bip32.encodeBech32Address(script[2..], version, addr[0..sep], &out);
        try testing.expectEqualStrings(addr, out[0..len]);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 8), n);
}

// ---------------------------------------------------------------------------------------------
// secp256k1: public keys, Hash160, P2WPKH, ECDSA
// ---------------------------------------------------------------------------------------------

const TinyEcdsa = struct { valid: []const struct { d: []const u8, m: []const u8, signature: []const u8 } };

/// The half-order n/2 of secp256k1, big-endian; a canonical (BIP-62/146) S is <= this.
const half_n = [32]u8{
    0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D, 0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
};

/// Parse a strict DER ECDSA signature into r || s (32 bytes each).
fn derToCompact(der: []const u8) ![64]u8 {
    if (der.len < 8 or der[0] != 0x30 or der[1] != der.len - 2) return error.BadDer;
    var out = [_]u8{0} ** 64;
    var p: usize = 2;
    for (0..2) |i| {
        if (der[p] != 0x02) return error.BadDer;
        const l = der[p + 1];
        var v = der[p + 2 .. p + 2 + l];
        if (v.len > 1 and v[0] == 0 and v[1] & 0x80 == 0) return error.BadDer; // non-minimal
        if (v[0] & 0x80 != 0) return error.BadDer; // negative
        if (v.len == 33) v = v[1..];
        if (v.len > 32) return error.BadDer;
        @memcpy(out[i * 32 + 32 - v.len .. i * 32 + 32], v);
        p += 2 + l;
    }
    if (p != der.len) return error.BadDer;
    return out;
}

/// quantum_ecdsa_sign's DER output, decoded; checks it verifies under `pubkey` and is low-S.
fn signAndCheck(sk: *const [32]u8, digest: *const [32]u8, pubkey: *const [33]u8) ![64]u8 {
    var der: [72]u8 = undefined;
    var der_len: usize = 0;
    try testing.expectEqual(@as(c_int, 0), c.quantum_ecdsa_sign(digest, sk, &der, &der_len));
    const compact = try derToCompact(der[0..der_len]);
    try testing.expect(std.mem.order(u8, compact[32..], &half_n) != .gt);
    try verifyEcdsa(digest, &compact, pubkey);
    return compact;
}

/// Textbook ECDSA verification (SEC 1 4.1.4) over secp256k1, written out because std's
/// `verifyPrehashed` refuses a zero digest, which the tiny-secp256k1 fixtures include.
fn verifyEcdsa(digest: *const [32]u8, sig: *const [64]u8, pubkey: *const [33]u8) !void {
    const Curve = std.crypto.ecc.Secp256k1;
    const Scalar = Curve.scalar.Scalar;
    const r = try Scalar.fromBytes(sig[0..32].*, .big);
    const s = try Scalar.fromBytes(sig[32..64].*, .big);
    if (r.isZero() or s.isZero()) return error.SignatureVerificationFailed;
    const z = Scalar.fromBytes48([_]u8{0} ** 16 ++ digest.*, .big); // bits2int, then mod n
    const w = s.invert();
    const k1 = z.mul(w);
    const k2 = r.mul(w);
    const q = try Curve.fromSec1(pubkey);
    const p = if (k1.isZero())
        try q.mulPublic(k2.toBytes(.big), .big)
    else
        try Curve.mulDoubleBasePublic(Curve.basePoint, k1.toBytes(.big), q, k2.toBytes(.big), .big);
    const x = Scalar.fromBytes48([_]u8{0} ** 16 ++ p.affineCoordinates().x.toBytes(.big), .big);
    if (!x.equivalent(r)) return error.SignatureVerificationFailed;
}

test "tiny-secp256k1 ecdsa.json (all valid fixtures): quantum_ecdsa_sign verifies and is low-S" {
    const parsed = try std.json.parseFromSlice(TinyEcdsa, a, @embedFile("tiny_ecdsa"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.valid.len >= 1000);
    for (parsed.value.valid) |v| {
        var sk: [32]u8 = undefined;
        var digest: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sk, v.d);
        _ = try std.fmt.hexToBytes(&digest, v.m);
        var pubkey: [33]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_derive_pubkey(&sk, &pubkey));
        _ = try signAndCheck(&sk, &digest, &pubkey);
    }
}

// ---------------------------------------------------------------------------------------------
// Differential corpus against the Rust reference crates
// ---------------------------------------------------------------------------------------------

const corpus = @embedFile("rust_reference");

fn seeded(r: records.Record, seed_key: []const u8, len_key: []const u8) ![]u8 {
    return records.expand(a, r.int(u64, seed_key), r.int(usize, len_key));
}

test "differential: SHA-256, SHA-256d (single and batched), SHA-512, RIPEMD-160, BLAKE3 XOF vs sha2/ripemd/blake3" {
    var it = records.iterate(corpus);
    var counts = [_]usize{0} ** 5;
    while (it.next()) |r| {
        const kind = r.str("kind");
        const which: usize = if (std.mem.eql(u8, kind, "sha256")) 0 else if (std.mem.eql(u8, kind, "sha256d")) 1 else if (std.mem.eql(u8, kind, "sha512")) 2 else if (std.mem.eql(u8, kind, "ripemd160")) 3 else if (std.mem.eql(u8, kind, "blake3")) 4 else continue;
        const m = try seeded(r, "seed", "len");
        defer a.free(m);
        var out: [64]u8 = undefined;
        switch (which) {
            0 => {
                try testing.expectEqual(@as(c_int, 0), c.quantum_sha256(m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..32]);
            },
            1 => {
                try testing.expectEqual(@as(c_int, 0), c.quantum_sha256d(m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..32]);
                // The batch entry point, with this input in every slot position among fillers.
                const slot = counts[1] % c.quantum_sha256d_batch_size();
                var fillers: [16][]u8 = undefined;
                var ins: [16][*c]const u8 = undefined;
                var outs_buf: [16][32]u8 = undefined;
                var outs: [16][*c]u8 = undefined;
                for (0..16) |j| {
                    fillers[j] = if (j == slot) m else try records.expand(a, r.int(u64, "seed") +% j +% 1, m.len);
                    ins[j] = fillers[j].ptr;
                    outs[j] = &outs_buf[j];
                }
                defer for (0..16) |j| if (j != slot) a.free(fillers[j]);
                try testing.expectEqual(@as(c_int, 0), c.quantum_sha256d_batch(&ins, m.len, &outs, 16));
                try hexEq(r.str("out"), &outs_buf[slot]);
                for (0..16) |j| {
                    var single: [32]u8 = undefined;
                    _ = c.quantum_sha256d(fillers[j].ptr, fillers[j].len, &single);
                    try testing.expectEqualSlices(u8, &single, &outs_buf[j]);
                }
            },
            2 => {
                try testing.expectEqual(@as(c_int, 0), c.quantum_sha512(m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..64]);
            },
            3 => {
                try testing.expectEqual(@as(c_int, 0), c.quantum_ripemd160(m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..20]);
            },
            4 => {
                const x = try a.alloc(u8, r.int(usize, "outlen"));
                defer a.free(x);
                try testing.expectEqual(@as(c_int, 0), c.quantum_blake3_variable(m.ptr, m.len, x.ptr, x.len));
                try hexEq(r.str("out"), x);
                if (x.len == 32) {
                    try testing.expectEqual(@as(c_int, 0), c.quantum_blake3(m.ptr, m.len, &out));
                    try testing.expectEqualSlices(u8, x, out[0..32]);
                }
            },
            else => unreachable,
        }
        counts[which] += 1;
    }
    for (counts) |n| try testing.expect(n >= 100);
}

test "differential: HMAC-SHA-256/512 (keys 0-259 bytes) and PBKDF2-HMAC-SHA-256/512 vs hmac/pbkdf2" {
    var it = records.iterate(corpus);
    var nh: usize = 0;
    var np: usize = 0;
    while (it.next()) |r| {
        const kind = r.str("kind");
        if (std.mem.startsWith(u8, kind, "hmac_")) {
            const k = try seeded(r, "kseed", "klen");
            defer a.free(k);
            const m = try seeded(r, "mseed", "mlen");
            defer a.free(m);
            var out: [64]u8 = undefined;
            if (std.mem.eql(u8, kind, "hmac_sha256")) {
                try testing.expectEqual(@as(c_int, 0), c.quantum_hmac_sha256(k.ptr, k.len, m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..32]);
            } else {
                try testing.expectEqual(@as(c_int, 0), c.quantum_hmac_sha512(k.ptr, k.len, m.ptr, m.len, &out));
                try hexEq(r.str("out"), out[0..64]);
            }
            nh += 1;
        } else if (std.mem.startsWith(u8, kind, "pbkdf2_")) {
            const p = try seeded(r, "pseed", "plen");
            defer a.free(p);
            const s = try seeded(r, "sseed", "slen");
            defer a.free(s);
            const dk = try a.alloc(u8, r.int(usize, "dklen"));
            defer a.free(dk);
            const f = if (std.mem.eql(u8, kind, "pbkdf2_sha256")) &c.quantum_pbkdf2_sha256 else &c.quantum_pbkdf2_sha512;
            try testing.expectEqual(@as(c_int, 0), f(p.ptr, p.len, s.ptr, s.len, r.int(u32, "iterations"), dk.ptr, dk.len));
            try hexEq(r.str("out"), dk);
            np += 1;
        }
    }
    try testing.expectEqual(@as(usize, 240), nh);
    try testing.expectEqual(@as(usize, 80), np);
}

test "differential: ChaCha20 (IETF, 0-16385 bytes, random counters) vs RustCrypto chacha20" {
    var it = records.iterate(corpus);
    var n: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.str("kind"), "chacha20")) continue;
        const key = records.expandFixed(32, r.int(u64, "kseed"));
        const nonce = records.expandFixed(12, r.int(u64, "nseed"));
        const pt = try seeded(r, "mseed", "len");
        defer a.free(pt);
        const ct = try a.alloc(u8, pt.len);
        defer a.free(ct);
        try testing.expectEqual(@as(c_int, 0), c.quantum_chacha20_encrypt(&key, &nonce, r.int(u32, "counter"), pt.ptr, pt.len, ct.ptr));
        try hexEq(r.str("out"), ct);
        // Decryption in place of a copy, and in odd-sized pieces with the counter advanced by
        // whole blocks, must give the plaintext back.
        try testing.expectEqual(@as(c_int, 0), c.quantum_chacha20_decrypt(&key, &nonce, r.int(u32, "counter"), ct.ptr, ct.len, ct.ptr));
        try testing.expectEqualSlices(u8, pt, ct);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 81), n);
}

test "differential: secp256k1 pubkey, Hash160, P2WPKH (main/test) and ECDSA validity vs libsecp256k1/k256/bitcoin" {
    var it = records.iterate(corpus);
    var n: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.str("kind"), "secp256k1")) continue;
        const sk = try r.fixed(32, "sk");
        const digest = try r.fixed(32, "digest");
        var pubkey: [33]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_derive_pubkey(&sk, &pubkey));
        try testing.expectEqualSlices(u8, &try r.fixed(33, "pubkey"), &pubkey);
        var h160: [20]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_hash160(&pubkey, &h160));
        try testing.expectEqualSlices(u8, &try r.fixed(20, "hash160"), &h160);
        var addr: [90]u8 = undefined;
        var len = c.quantum_bip32_p2wpkh_address(&pubkey, 1, &addr);
        try testing.expectEqualStrings(r.str("p2wpkh_main"), addr[0..@intCast(len)]);
        len = c.quantum_bip32_p2wpkh_address(&pubkey, 0, &addr);
        try testing.expectEqualStrings(r.str("p2wpkh_test"), addr[0..@intCast(len)]);
        // The reference signature is itself a valid input to our DER/low-S checker, and ours
        // must verify under the reference public key.
        const ref_der = try r.bytes(a, "der");
        defer a.free(ref_der);
        try testing.expectEqualSlices(u8, &try r.fixed(64, "sig"), &try derToCompact(ref_der));
        _ = try signAndCheck(&sk, &digest, &pubkey);
        n += 1;
    }
    try testing.expect(n >= 190);
}

test "differential: BIP-0032 random paths (depth 1-5, hardened and normal, 16/32/64-byte seeds) vs rust-bitcoin" {
    var it = records.iterate(corpus);
    var n: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.str("kind"), "bip32")) continue;
        const seed = try seeded(r, "seed", "seedlen");
        defer a.free(seed);
        var master: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_from_seed(seed.ptr, seed.len, &master));
        const path = r.str("path");
        var node: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_derive_path(&master, path.ptr, path.len, &node));
        var ser: [82]u8 = undefined;
        try testing.expectEqual(@as(c_int, 82), c.quantum_bip32_serialize(&node, 1, &ser));
        try testing.expectEqualSlices(u8, &try r.fixed(78, "xprv"), ser[0..78]);
        var pubnode: c.CKey = undefined;
        try testing.expectEqual(@as(c_int, 0), c.quantum_bip32_neuter(&node, &pubnode));
        try testing.expectEqual(@as(c_int, 82), c.quantum_bip32_serialize(&pubnode, 1, &ser));
        try testing.expectEqualSlices(u8, &try r.fixed(78, "xpub"), ser[0..78]);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 60), n);
}

test "quantum_secure_compare: equal/unequal at every position, and no early exit on length" {
    var x: [97]u8 = undefined;
    for (&x, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    var y = x;
    try testing.expectEqual(@as(c_int, 0), c.quantum_secure_compare(&x, &y, x.len));
    for (0..x.len) |i| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |flip| {
            y[i] ^= flip;
            try testing.expectEqual(@as(c_int, 1), c.quantum_secure_compare(&x, &y, x.len));
            y[i] ^= flip;
        }
    }
}

comptime {
    _ = ffi; // compiles the exports the extern declarations above resolve to
}
