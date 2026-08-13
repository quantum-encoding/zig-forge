//! Standard PDF encryption — AES-256, `/V 5 /R 6` (ISO 32000-2:2020 §7.6.4).
//!
//! This is the only non-deprecated scheme in ISO 32000-2 and the one qpdf writes
//! without `--allow-insecure`. It is interoperable: every modern viewer opens the
//! result with the password.
//!
//! Primitives come from `std.crypto` (vetted AES-128/256 block + SHA-256/384/512);
//! this module only assembles them per the spec's algorithms:
//!   - Algorithm 2.B  `hashV5`     — the R6 hardened iterated password hash
//!   - Algorithm 8/9  `/U`,`/UE`   — user validation hash + wrapped file key
//!   - Algorithm 9    `/O`,`/OE`   — owner validation hash + wrapped file key
//!   - §7.6.4.4.9     `/Perms`     — encrypted permissions (the /P tamper guard)
//!   - AESV3 object encryption     — 16-byte random IV ‖ AES-256-CBC(PKCS#7)
//!
//! Correctness is anchored EXTERNALLY: the produced /Encrypt dict + encrypted
//! streams are validated by qpdf and pikepdf (see the test suite). The unit tests
//! here cover the self-consistent round-trip (recover the file key from /U+/UE,
//! decrypt(encrypt(x))) and byte-layout invariants; the cross-implementation
//! acceptance is the binding check per the repo's golden rule.

const std = @import("std");
const Aes256 = std.crypto.core.aes.Aes256;
const Aes128 = std.crypto.core.aes.Aes128;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;

pub const FileKey = [32]u8;

pub const CryptError = error{ OutOfMemory, BadCiphertextLength, BadPadding };

// =============================================================================
// AES modes (built on the std.crypto single-block primitive)
// =============================================================================

/// AES-256-CBC with PKCS#7 padding. Returns ciphertext (caller owns). Used for
/// AESV3 stream/string objects (the IV is prepended by the caller).
fn aes256CbcEncryptPad(allocator: std.mem.Allocator, key: [32]u8, iv: [16]u8, plaintext: []const u8) CryptError![]u8 {
    const pad: u8 = @intCast(16 - (plaintext.len % 16)); // 1..16 (full block if aligned)
    const out_len = plaintext.len + pad;
    var out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const ctx = Aes256.initEnc(key);
    var prev = iv;
    var off: usize = 0;
    while (off < out_len) : (off += 16) {
        var block: [16]u8 = undefined;
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            const src: u8 = if (off + j < plaintext.len) plaintext[off + j] else pad;
            block[j] = src ^ prev[j];
        }
        var enc: [16]u8 = undefined;
        ctx.encrypt(&enc, &block);
        @memcpy(out[off .. off + 16], &enc);
        prev = enc;
    }
    return out;
}

/// AES-256-CBC decrypt + strip PKCS#7. Inverse of `aes256CbcEncryptPad`.
fn aes256CbcDecryptPad(allocator: std.mem.Allocator, key: [32]u8, iv: [16]u8, ciphertext: []const u8) CryptError![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.BadCiphertextLength;
    var buf = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(buf);

    const ctx = Aes256.initDec(key);
    var prev = iv;
    var off: usize = 0;
    while (off < ciphertext.len) : (off += 16) {
        var ct: [16]u8 = undefined;
        @memcpy(&ct, ciphertext[off .. off + 16]);
        var dec: [16]u8 = undefined;
        ctx.decrypt(&dec, &ct);
        var j: usize = 0;
        while (j < 16) : (j += 1) buf[off + j] = dec[j] ^ prev[j];
        prev = ct;
    }
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or pad > buf.len) return error.BadPadding;
    return allocator.realloc(buf, buf.len - pad) catch buf[0 .. buf.len - pad];
}

/// AES-256-CBC, NO padding, into a caller buffer (len must be a multiple of 16).
/// Used to wrap/unwrap the 32-byte file key in /UE and /OE (zero IV).
fn aes256CbcNoPad(comptime mode: enum { enc, dec }, key: [32]u8, iv: [16]u8, data: []const u8, out: []u8) void {
    std.debug.assert(data.len % 16 == 0 and out.len == data.len);
    var prev = iv;
    var off: usize = 0;
    if (mode == .enc) {
        const ctx = Aes256.initEnc(key);
        while (off < data.len) : (off += 16) {
            var block: [16]u8 = undefined;
            for (0..16) |j| block[j] = data[off + j] ^ prev[j];
            var enc: [16]u8 = undefined;
            ctx.encrypt(&enc, &block);
            @memcpy(out[off .. off + 16], &enc);
            prev = enc;
        }
    } else {
        const ctx = Aes256.initDec(key);
        while (off < data.len) : (off += 16) {
            var ct: [16]u8 = undefined;
            @memcpy(&ct, data[off .. off + 16]);
            var dec: [16]u8 = undefined;
            ctx.decrypt(&dec, &ct);
            for (0..16) |j| out[off + j] = dec[j] ^ prev[j];
            prev = ct;
        }
    }
}

/// AES-128-CBC, NO padding, in place — the inner cipher of the R6 hash loop.
fn aes128CbcNoPadInPlace(key: [16]u8, iv: [16]u8, data: []u8) void {
    std.debug.assert(data.len % 16 == 0);
    const ctx = Aes128.initEnc(key);
    var prev = iv;
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |j| block[j] = data[off + j] ^ prev[j];
        var enc: [16]u8 = undefined;
        ctx.encrypt(&enc, &block);
        @memcpy(data[off .. off + 16], &enc);
        prev = enc;
    }
}

// =============================================================================
// Algorithm 2.B — R6 hardened password hash (hash_V5)
// =============================================================================

/// ISO 32000-2 §7.6.4.3.4. `password` is UTF-8 (caller pre-normalizes/truncates
/// to ≤127 bytes), `salt` is 8 bytes, `udata` is "" for /U and the 48-byte /U for
/// /O. Returns the 32-byte hash.
pub fn hashV5(allocator: std.mem.Allocator, password: []const u8, salt: [8]u8, udata: []const u8) CryptError![32]u8 {
    // K := SHA-256(password ‖ salt ‖ udata)
    var k_buf: [64]u8 = undefined; // holds up to SHA-512 output
    var k_len: usize = 32;
    {
        var h = Sha256.init(.{});
        h.update(password);
        h.update(&salt);
        h.update(udata);
        var d: [32]u8 = undefined;
        h.final(&d);
        @memcpy(k_buf[0..32], &d);
    }

    var round: usize = 0;
    while (true) {
        round += 1;
        const k = k_buf[0..k_len];

        // K1 := (password ‖ K ‖ udata) repeated 64×
        const unit_len = password.len + k_len + udata.len;
        const k1_len = unit_len * 64;
        var k1 = try allocator.alloc(u8, k1_len);
        defer allocator.free(k1);
        {
            var p: usize = 0;
            @memcpy(k1[p .. p + password.len], password);
            p += password.len;
            @memcpy(k1[p .. p + k_len], k);
            p += k_len;
            @memcpy(k1[p .. p + udata.len], udata);
            // replicate the first unit 63 more times
            var r: usize = 1;
            while (r < 64) : (r += 1) {
                @memcpy(k1[r * unit_len .. r * unit_len + unit_len], k1[0..unit_len]);
            }
        }

        // E := AES-128-CBC(key=K[0..16], IV=K[16..32], K1) — no padding, in place
        var aes_key: [16]u8 = undefined;
        var aes_iv: [16]u8 = undefined;
        @memcpy(&aes_key, k[0..16]);
        @memcpy(&aes_iv, k[16..32]);
        aes128CbcNoPadInPlace(aes_key, aes_iv, k1);
        const e = k1; // K1 buffer now holds E

        // mod := (Σ E[0..16]) % 3  → choose SHA-256/384/512
        var sum: u32 = 0;
        for (e[0..16]) |b| sum += b;
        const sel = sum % 3;
        switch (sel) {
            0 => {
                var d: [32]u8 = undefined;
                Sha256.hash(e, &d, .{});
                @memcpy(k_buf[0..32], &d);
                k_len = 32;
            },
            1 => {
                var d: [48]u8 = undefined;
                Sha384.hash(e, &d, .{});
                @memcpy(k_buf[0..48], &d);
                k_len = 48;
            },
            else => {
                var d: [64]u8 = undefined;
                Sha512.hash(e, &d, .{});
                @memcpy(k_buf[0..64], &d);
                k_len = 64;
            },
        }

        // Termination: ≥64 rounds AND last byte of E ≤ round−32.
        if (round >= 64 and e[e.len - 1] <= round - 32) break;
    }

    var result: [32]u8 = undefined;
    @memcpy(&result, k_buf[0..32]);
    return result;
}

// =============================================================================
// Seed material
// =============================================================================

/// 32 bytes of random material for an encryption seed — the file key, the four
/// salts and the object IVs all derive from it. Native targets draw it from the
/// OS CSPRNG; WASM has no in-module CSPRNG, so it returns zeros and the engine's
/// all-zero refusal (see `document.PdfDocument.enableEncryption`) forces a WASM
/// caller onto the host-seeded export.
///
/// Entropy failure is reported the same way: the seed stays all-zero rather than
/// partially filled, so it trips that refusal instead of silently producing a
/// PDF encrypted under a low-entropy key. Panicking here is not an option — this
/// path is reachable through the C ABI, where an unhandled panic is UB.
pub fn osSeed() [32]u8 {
    var s: [32]u8 = [_]u8{0} ** 32;
    if (!fillOsRandom(&s)) s = [_]u8{0} ** 32;
    return s;
}

/// Fill `buf` from the OS CSPRNG; false if no entropy was obtained.
///
/// Zig 0.16 removed the `std.crypto.random` global and does not declare
/// `arc4random_buf` for every libc — on glibc `std.c.arc4random_buf` is `void`,
/// so calling it unconditionally breaks the x86_64-linux-gnu build. Select the
/// same way `std.Io.Threaded.randomSecure` does: prefer the fork-safe,
/// no-seed-required `arc4random_buf` wherever the libc declares it (Apple/BSD,
/// glibc >= 2.36), then `getrandom(2)` — through libc when it wraps the syscall
/// (glibc >= 2.25, musl, Android >= 28), otherwise raw.
fn fillOsRandom(buf: []u8) bool {
    const builtin = @import("builtin");
    if (buf.len == 0) return true;
    if (comptime builtin.target.cpu.arch.isWasm()) return false;

    if (comptime @TypeOf(std.c.arc4random_buf) != void) {
        std.c.arc4random_buf(buf.ptr, buf.len);
        return true;
    } else if (comptime @TypeOf(std.posix.system.getrandom) != void) {
        // `errno` must come from the same namespace as the call: raw syscalls
        // encode the error in the return value, the libc wrapper in `errno`.
        var off: usize = 0;
        while (off < buf.len) {
            const rc = std.posix.system.getrandom(buf.ptr + off, buf.len - off, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => continue,
                else => return false,
            }
        }
        return true;
    } else if (comptime builtin.os.tag == .linux) {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = std.os.linux.getrandom(buf.ptr + off, buf.len - off, 0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return false,
            }
        }
        return true;
    } else {
        @compileError("no cryptographically secure OS RNG available for this target");
    }
}

// =============================================================================
// /Encrypt dictionary entries (V5/R6)
// =============================================================================

/// The random material the caller supplies (production: derived from `osSeed`;
/// tests: fixed for reproducibility).
pub const Randomness = struct {
    file_key: FileKey,
    u_val_salt: [8]u8,
    u_key_salt: [8]u8,
    o_val_salt: [8]u8,
    o_key_salt: [8]u8,
    perms_rand: [4]u8,
};

pub const EncryptDict = struct {
    u: [48]u8,
    o: [48]u8,
    ue: [32]u8,
    oe: [32]u8,
    perms: [16]u8,
    p: i32,
    file_key: FileKey,
};

/// Build the full set of V5/R6 /Encrypt entries from the passwords + random
/// material. `p` is the permissions bit-field; `encrypt_metadata` toggles the
/// /Perms 'T'/'F' flag.
pub fn computeEncryptDict(
    allocator: std.mem.Allocator,
    user_pw: []const u8,
    owner_pw: []const u8,
    p: i32,
    encrypt_metadata: bool,
    rnd: Randomness,
) CryptError!EncryptDict {
    var d = EncryptDict{ .u = undefined, .o = undefined, .ue = undefined, .oe = undefined, .perms = undefined, .p = p, .file_key = rnd.file_key };

    // /U = hashV5(user_pw, U_val_salt, "") ‖ U_val_salt ‖ U_key_salt
    const u_hash = try hashV5(allocator, user_pw, rnd.u_val_salt, "");
    @memcpy(d.u[0..32], &u_hash);
    @memcpy(d.u[32..40], &rnd.u_val_salt);
    @memcpy(d.u[40..48], &rnd.u_key_salt);

    // /UE = AES-256-CBC-no-pad(key=hashV5(user_pw, U_key_salt, ""), IV=0, file_key)
    const u_ikey = try hashV5(allocator, user_pw, rnd.u_key_salt, "");
    aes256CbcNoPad(.enc, u_ikey, [_]u8{0} ** 16, &rnd.file_key, &d.ue);

    // /O = hashV5(owner_pw, O_val_salt, /U[0..48]) ‖ O_val_salt ‖ O_key_salt
    const o_hash = try hashV5(allocator, owner_pw, rnd.o_val_salt, d.u[0..48]);
    @memcpy(d.o[0..32], &o_hash);
    @memcpy(d.o[32..40], &rnd.o_val_salt);
    @memcpy(d.o[40..48], &rnd.o_key_salt);

    // /OE = AES-256-CBC-no-pad(key=hashV5(owner_pw, O_key_salt, /U[0..48]), IV=0, file_key)
    const o_ikey = try hashV5(allocator, owner_pw, rnd.o_key_salt, d.u[0..48]);
    aes256CbcNoPad(.enc, o_ikey, [_]u8{0} ** 16, &rnd.file_key, &d.oe);

    // /Perms = AES-256-ECB(file_key, cleartext)
    var perms_clear: [16]u8 = undefined;
    const pu: u32 = @bitCast(p);
    std.mem.writeInt(u32, perms_clear[0..4], pu, .little);
    @memcpy(perms_clear[4..8], &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });
    perms_clear[8] = if (encrypt_metadata) 'T' else 'F';
    perms_clear[9] = 'a';
    perms_clear[10] = 'd';
    perms_clear[11] = 'b';
    @memcpy(perms_clear[12..16], &rnd.perms_rand);
    const ecb = Aes256.initEnc(rnd.file_key);
    ecb.encrypt(&d.perms, &perms_clear); // single block, no IV, no pad

    return d;
}

// =============================================================================
// Object encryption (AESV3 streams & strings)
// =============================================================================

/// Encrypt one object's bytes (a stream body or a string value): returns
/// `IV(16) ‖ AES-256-CBC(PKCS#7-pad(plaintext))`. For V5/R6 the per-object key
/// IS the file key (no object-number salting, unlike V<5). Caller owns result.
pub fn encryptObject(allocator: std.mem.Allocator, file_key: FileKey, iv: [16]u8, plaintext: []const u8) CryptError![]u8 {
    const body = try aes256CbcEncryptPad(allocator, file_key, iv, plaintext);
    defer allocator.free(body);
    var out = try allocator.alloc(u8, 16 + body.len);
    @memcpy(out[0..16], &iv);
    @memcpy(out[16..], body);
    return out;
}

/// Inverse of `encryptObject` — used by the test suite to prove round-trip.
pub fn decryptObject(allocator: std.mem.Allocator, file_key: FileKey, data: []const u8) CryptError![]u8 {
    if (data.len < 16) return error.BadCiphertextLength;
    var iv: [16]u8 = undefined;
    @memcpy(&iv, data[0..16]);
    return aes256CbcDecryptPad(allocator, file_key, iv, data[16..]);
}

/// Algorithm 2.A (user path): validate `password` against /U and recover the
/// file key from /UE. Returns null if the password is wrong. Used by tests to
/// mirror what qpdf does when opening the file.
pub fn recoverFileKeyUser(allocator: std.mem.Allocator, password: []const u8, u: [48]u8, ue: [32]u8) CryptError!?FileKey {
    var val_salt: [8]u8 = undefined;
    var key_salt: [8]u8 = undefined;
    @memcpy(&val_salt, u[32..40]);
    @memcpy(&key_salt, u[40..48]);

    const check = try hashV5(allocator, password, val_salt, "");
    if (!std.crypto.timing_safe.eql([32]u8, check, u[0..32].*)) return null;

    const ikey = try hashV5(allocator, password, key_salt, "");
    var fk: FileKey = undefined;
    aes256CbcNoPad(.dec, ikey, [_]u8{0} ** 16, &ue, &fk);
    return fk;
}

// =============================================================================
// Tests — round-trip + byte-layout invariants. (External qpdf/pikepdf
// acceptance is the binding correctness anchor, run over a generated file.)
// =============================================================================

const testing = std.testing;

fn testRand() Randomness {
    return .{
        .file_key = [_]u8{0x11} ** 32,
        .u_val_salt = [_]u8{0x22} ** 8,
        .u_key_salt = [_]u8{0x33} ** 8,
        .o_val_salt = [_]u8{0x44} ** 8,
        .o_key_salt = [_]u8{0x55} ** 8,
        .perms_rand = [_]u8{0x66} ** 4,
    };
}

test "AES-256-CBC pad round-trips arbitrary lengths" {
    const a = testing.allocator;
    const key = [_]u8{0xAB} ** 32;
    const iv = [_]u8{0xCD} ** 16;
    for ([_]usize{ 0, 1, 15, 16, 17, 100 }) |n| {
        const pt = try a.alloc(u8, n);
        defer a.free(pt);
        for (pt, 0..) |*b, i| b.* = @intCast(i & 0xFF);
        const ct = try aes256CbcEncryptPad(a, key, iv, pt);
        defer a.free(ct);
        try testing.expect(ct.len % 16 == 0 and ct.len > n);
        const back = try aes256CbcDecryptPad(a, key, iv, ct);
        defer a.free(back);
        try testing.expectEqualSlices(u8, pt, back);
    }
}

test "object encrypt/decrypt round-trips with IV prefix" {
    const a = testing.allocator;
    const fk = [_]u8{0x77} ** 32;
    const iv = [_]u8{0x88} ** 16;
    const msg = "BT /F0 12 Tf (Sealed invoice) Tj ET";
    const enc = try encryptObject(a, fk, iv, msg);
    defer a.free(enc);
    try testing.expect(enc.len >= 16 + 16); // IV + at least one block
    const dec = try decryptObject(a, fk, enc);
    defer a.free(dec);
    try testing.expectEqualSlices(u8, msg, dec);
}

test "R6 key derivation: correct password recovers file key, wrong rejected" {
    const a = testing.allocator;
    const rnd = testRand();
    const dict = try computeEncryptDict(a, "secret", "owner-secret", -44, true, rnd);

    // Byte-layout invariants (sizes are fixed by the spec).
    try testing.expectEqual(@as(usize, 48), dict.u.len);
    try testing.expectEqual(@as(usize, 48), dict.o.len);
    try testing.expectEqual(@as(usize, 32), dict.ue.len);
    try testing.expectEqual(@as(usize, 32), dict.oe.len);
    try testing.expectEqual(@as(usize, 16), dict.perms.len);

    // Algorithm 2.A: the right user password recovers exactly the file key.
    const fk = try recoverFileKeyUser(a, "secret", dict.u, dict.ue);
    try testing.expect(fk != null);
    try testing.expectEqualSlices(u8, &rnd.file_key, &fk.?);

    // Wrong password → validation fails → null.
    const bad = try recoverFileKeyUser(a, "wrong", dict.u, dict.ue);
    try testing.expect(bad == null);
}

test "Perms decrypts to the 'adb' magic and the permission bits" {
    const a = testing.allocator;
    const rnd = testRand();
    const p: i32 = -3904;
    const dict = try computeEncryptDict(a, "u", "o", p, true, rnd);
    // Decrypt /Perms with the file key (AES-256-ECB) and check the guard bytes.
    const dec = Aes256.initDec(rnd.file_key);
    var clear: [16]u8 = undefined;
    dec.decrypt(&clear, &dict.perms);
    try testing.expectEqual(@as(u8, 'a'), clear[9]);
    try testing.expectEqual(@as(u8, 'd'), clear[10]);
    try testing.expectEqual(@as(u8, 'b'), clear[11]);
    const p_back: i32 = @bitCast(std.mem.readInt(u32, clear[0..4], .little));
    try testing.expectEqual(p, p_back);
}
