//! ML-DSA-65 (FIPS 204) post-quantum tamper-seal for PDFs.
//!
//! ⚠ This is a PROPRIETARY seal, NOT a standard PDF digital signature. No PDF
//! viewer validates ML-DSA (it is post-quantum; standard PDF signatures are
//! RSA/ECDSA in a PKCS#7/CMS blob). The seal is verified by THIS tool (a
//! `cl_verify`-style path), giving a "cryptographically sealed invoice/contract"
//! for the Quantum-Encoding ecosystem — tamper-evident and key-attributable.
//!
//! It mirrors the standard signature *technique* (ISO 32000 §12.8) so it is
//! robust and findable: the seal is an appended incremental-update revision
//! holding a `/Type /QESeal` dict with a `/ByteRange` that brackets a
//! zero-filled `/Contents` hole. The ML-DSA signature covers the two ByteRange
//! spans (everything except the hole) — so any later edit to the document body
//! breaks verification. The signer's public key is embedded; a verifier can
//! additionally pin it to a known business key for authenticity.
//!
//! Determinism: keyGen takes a 32-byte seed (the business's persistent key) and
//! signing is deterministic (FIPS 204 Sign_internal, rnd=0), so the same
//! document + key yields the same seal — testable byte-for-byte. The primitive
//! is the repo's audited ML-DSA-65 (ACVP-anchored in ml_dsa_tier1_anchors.zig).

const std = @import("std");
const ml_dsa = @import("ml_dsa");

pub const PK_BYTES = ml_dsa.PUBLIC_KEY_SIZE; // 1952
pub const SIG_BYTES = ml_dsa.SIGNATURE_SIZE; // 3309
const PK_HEX = PK_BYTES * 2; // 3904
const SIG_HEX = SIG_BYTES * 2; // 6618

pub const SealError = error{ OutOfMemory, MalformedPdf, SignFailed };

// =============================================================================
// Sealing
// =============================================================================

/// Append an ML-DSA-65 tamper-seal to `pdf` as an incremental-update revision.
/// `key_seed` is the signer's 32-byte ML-DSA seed (persistent business key).
/// Returns the sealed PDF (caller owns).
pub fn seal(allocator: std.mem.Allocator, pdf: []const u8, key_seed: [32]u8) SealError![]u8 {
    const kp = ml_dsa.keyGen(&key_seed) catch return error.SignFailed;

    // Original document facts for a valid incremental update.
    const prev_xref = lastIntAfter(pdf, "startxref") orelse return error.MalformedPdf;
    const size = lastIntAfter(pdf, "/Size ") orelse return error.MalformedPdf;
    const root_ref = lastRootRef(pdf); // e.g. "1 0 R"
    const obj_id: u64 = size;

    const lead: []const u8 = if (pdf.len > 0 and pdf[pdf.len - 1] == '\n') "" else "\n";
    const obj_start = pdf.len + lead.len;

    // Build the seal object with a placeholder ByteRange (10-digit fields) and a
    // zero-filled /Contents hole — fixed widths keep all byte offsets stable.
    var obj: std.ArrayListUnmanaged(u8) = .empty;
    defer obj.deinit(allocator);
    var hdr: [64]u8 = undefined;
    try obj.appendSlice(allocator, std.fmt.bufPrint(&hdr, "{d} 0 obj\n", .{obj_id}) catch return error.MalformedPdf);
    try obj.appendSlice(allocator, "<< /Type /QESeal /Filter /QE.MLDSA65 /ByteRange [0 0000000000 0000000000 0000000000] /PubKey <");
    try appendHex(allocator, &obj, &kp.pk.data);
    try obj.appendSlice(allocator, "> /Contents <");
    try obj.appendNTimes(allocator, '0', SIG_HEX);
    try obj.appendSlice(allocator, "> >>\nendobj\n");

    const xref_start = obj_start + obj.items.len;

    // xref + trailer (incremental: a single new object, /Prev to the old xref).
    var tail: std.ArrayListUnmanaged(u8) = .empty;
    defer tail.deinit(allocator);
    var tb: [256]u8 = undefined;
    try tail.appendSlice(allocator, std.fmt.bufPrint(&tb, "xref\n0 1\n0000000000 65535 f \n{d} 1\n{d:0>10} 00000 n \ntrailer\n<< /Size {d} /Root {s} /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{
        obj_id, obj_start, obj_id + 1, root_ref, prev_xref, xref_start,
    }) catch return error.MalformedPdf);

    // Assemble the full sealed buffer.
    var full: std.ArrayListUnmanaged(u8) = .empty;
    errdefer full.deinit(allocator);
    try full.appendSlice(allocator, pdf);
    try full.appendSlice(allocator, lead);
    try full.appendSlice(allocator, obj.items);
    try full.appendSlice(allocator, tail.items);
    const buf = full.items;

    // Locate the /Contents hole and set the ByteRange to bracket it.
    const c_lt = (std.mem.indexOfPos(u8, buf, obj_start, "/Contents <") orelse return error.MalformedPdf) + "/Contents <".len;
    const len1 = c_lt; // span1 = [0, '<'+1)  (includes the '<')
    const off2 = c_lt + SIG_HEX; // position of '>'
    const len2 = buf.len - off2; // span2 = ['>', EOF)
    try patchByteRange(buf, obj_start, len1, off2, len2);

    // Sign the two ByteRange spans (everything except the hole), deterministically.
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, buf[0..len1]);
    try msg.appendSlice(allocator, buf[off2 .. off2 + len2]);
    const sig = ml_dsa.sign(&kp.sk, msg.items, false) catch return error.SignFailed;

    // Backfill the signature hex into the hole (fixed width → offsets unchanged).
    writeHex(buf[c_lt .. c_lt + SIG_HEX], &sig.data);

    return full.toOwnedSlice(allocator);
}

// =============================================================================
// Verification
// =============================================================================

pub const Verdict = struct {
    valid: bool,
    reason: []const u8,
    /// Hex of the signer's public key (when a seal was found) — pin this to a
    /// known business key for authenticity. Empty if no seal.
    public_key_hex: [PK_HEX]u8 = [_]u8{0} ** PK_HEX,
    has_seal: bool = false,
};

/// Verify the tamper-seal: recompute the ByteRange digest and ML-DSA-verify it
/// against the embedded public key. A single changed byte in the covered body
/// makes this fail.
pub fn verify(allocator: std.mem.Allocator, sealed: []const u8) SealError!Verdict {
    const seal_pos = std.mem.lastIndexOf(u8, sealed, "/Type /QESeal") orelse
        return .{ .valid = false, .reason = "no QESeal found" };

    // /ByteRange [0 L1 O2 L2]
    const br = std.mem.indexOfPos(u8, sealed, seal_pos, "/ByteRange [") orelse return error.MalformedPdf;
    var it = std.mem.tokenizeAny(u8, sealed[br + "/ByteRange [".len ..], " ]");
    _ = it.next() orelse return error.MalformedPdf; // first field is 0
    const len1 = parseU64(it.next()) orelse return error.MalformedPdf;
    const off2 = parseU64(it.next()) orelse return error.MalformedPdf;
    const len2 = parseU64(it.next()) orelse return error.MalformedPdf;
    if (len1 + len2 > sealed.len or off2 + len2 > sealed.len) return error.MalformedPdf;

    var verdict = Verdict{ .valid = false, .reason = "verification failed", .has_seal = true };

    // /PubKey <hex>
    const pk_lt = (std.mem.indexOfPos(u8, sealed, seal_pos, "/PubKey <") orelse return error.MalformedPdf) + "/PubKey <".len;
    if (pk_lt + PK_HEX > sealed.len) return error.MalformedPdf;
    @memcpy(&verdict.public_key_hex, sealed[pk_lt .. pk_lt + PK_HEX]);
    var pk: ml_dsa.PublicKey = undefined;
    if (!readHex(&pk.data, sealed[pk_lt .. pk_lt + PK_HEX])) return error.MalformedPdf;

    // /Contents <hex>
    const c_lt = (std.mem.indexOfPos(u8, sealed, seal_pos, "/Contents <") orelse return error.MalformedPdf) + "/Contents <".len;
    if (c_lt + SIG_HEX > sealed.len) return error.MalformedPdf;
    var sig: ml_dsa.Signature = undefined;
    if (!readHex(&sig.data, sealed[c_lt .. c_lt + SIG_HEX])) return error.MalformedPdf;

    // Reconstruct the signed message from the two ByteRange spans.
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, sealed[0..len1]);
    try msg.appendSlice(allocator, sealed[off2 .. off2 + len2]);

    if (ml_dsa.verify(&pk, msg.items, &sig)) {
        verdict.valid = true;
        verdict.reason = "seal valid — document unmodified since sealing";
    } else {
        verdict.valid = false;
        verdict.reason = "seal INVALID — document modified or wrong key";
    }
    return verdict;
}

// =============================================================================
// Helpers
// =============================================================================

fn appendHex(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        try buf.append(allocator, hex[b >> 4]);
        try buf.append(allocator, hex[b & 0x0F]);
    }
}

fn writeHex(dst: []u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        dst[i * 2] = hex[b >> 4];
        dst[i * 2 + 1] = hex[b & 0x0F];
    }
}

fn readHex(dst: []u8, hex: []const u8) bool {
    if (hex.len != dst.len * 2) return false;
    for (dst, 0..) |*d, i| {
        const hi = hexVal(hex[i * 2]) orelse return false;
        const lo = hexVal(hex[i * 2 + 1]) orelse return false;
        d.* = (hi << 4) | lo;
    }
    return true;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Overwrite the three 10-digit ByteRange placeholder fields in place.
fn patchByteRange(buf: []u8, search_from: usize, len1: usize, off2: usize, len2: usize) !void {
    const br = std.mem.indexOfPos(u8, buf, search_from, "/ByteRange [0 ") orelse return error.MalformedPdf;
    const p = br + "/ByteRange [0 ".len;
    writeU10(buf[p .. p + 10], len1);
    writeU10(buf[p + 11 .. p + 21], off2);
    writeU10(buf[p + 22 .. p + 32], len2);
}

fn writeU10(dst: []u8, v: u64) void {
    var n = v;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

fn parseU64(tok: ?[]const u8) ?u64 {
    const t = tok orelse return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

/// The integer on the line following the LAST occurrence of `marker`.
fn lastIntAfter(s: []const u8, marker: []const u8) ?u64 {
    const at = std.mem.lastIndexOf(u8, s, marker) orelse return null;
    var i = at + marker.len;
    while (i < s.len and (s[i] == ' ' or s[i] == '\r' or s[i] == '\n')) i += 1;
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, s[start..i], 10) catch null;
}

/// The "N 0 R" object reference after the last "/Root " (defaults to "1 0 R").
fn lastRootRef(s: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, s, "/Root ") orelse return "1 0 R";
    const start = at + "/Root ".len;
    const end = std.mem.indexOfPos(u8, s, start, " R") orelse return "1 0 R";
    return s[start .. end + 2];
}

// =============================================================================
// Tests — primitive is ACVP-anchored elsewhere; here we test the SEAL behaviour:
// valid round-trip, single-byte tamper detection, and wrong-key rejection.
// =============================================================================

const testing = std.testing;

// A minimal but structurally-valid PDF to seal.
const SAMPLE_PDF =
    "%PDF-1.4\n" ++
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n" ++
    "xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \n" ++
    "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n190\n%%EOF\n";

test "seal then verify: valid" {
    const a = testing.allocator;
    const seed = [_]u8{0x07} ** 32;
    const sealed = try seal(a, SAMPLE_PDF, seed);
    defer a.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "/Type /QESeal") != null);
    const v = try verify(a, sealed);
    try testing.expect(v.has_seal);
    try testing.expect(v.valid);
}

test "seal is deterministic for the same document + key" {
    const a = testing.allocator;
    const seed = [_]u8{0x07} ** 32;
    const s1 = try seal(a, SAMPLE_PDF, seed);
    defer a.free(s1);
    const s2 = try seal(a, SAMPLE_PDF, seed);
    defer a.free(s2);
    try testing.expectEqualSlices(u8, s1, s2);
}

test "single-byte tamper in the body breaks verification" {
    const a = testing.allocator;
    const seed = [_]u8{0x07} ** 32;
    const sealed = try seal(a, SAMPLE_PDF, seed);
    defer a.free(sealed);
    // Flip a byte inside the original content (covered by ByteRange span1).
    const pos = std.mem.indexOf(u8, sealed, "/MediaBox").?;
    sealed[pos + 2] ^= 0x01;
    const v = try verify(a, sealed);
    try testing.expect(v.has_seal);
    try testing.expect(!v.valid);
}

test "wrong key rejected (verify uses embedded pubkey; swap it)" {
    const a = testing.allocator;
    const sealed = try seal(a, SAMPLE_PDF, [_]u8{0x07} ** 32);
    defer a.free(sealed);
    // Corrupt one byte of the embedded /PubKey hex → pubkey no longer matches
    // the signing key → verification must fail.
    const pk_lt = (std.mem.indexOf(u8, sealed, "/PubKey <").?) + "/PubKey <".len;
    sealed[pk_lt] = if (sealed[pk_lt] == 'a') 'b' else 'a';
    const v = try verify(a, sealed);
    try testing.expect(!v.valid);
}

test "verify reports no seal on an unsealed PDF" {
    const a = testing.allocator;
    const v = try verify(a, SAMPLE_PDF);
    try testing.expect(!v.has_seal);
    try testing.expect(!v.valid);
}
