//! Stable C-ABI for the Go proxy and Swift desktop app (Guardrail 2).
//!
//! The underlying Zig API takes a `std.mem.Allocator`; this thin C layer uses
//! `std.heap.c_allocator` so C callers don't manage one. All heap returned to
//! the caller (the shipped event JSON) is released with `cl_free`.
//!
//! Callers build the event body as ordinary JSON (any key order); the library
//! canonicalises it per RFC 8785 before hashing, so Go/Swift/Zig all agree on
//! the bytes. Floats and >i64 numbers are rejected (CL_ERR_FLOAT/NUMBER) to keep
//! the chain hash deterministic across languages — send large magnitudes and
//! timestamps as decimal strings.

const std = @import("std");
const ledger = @import("ledger.zig");
const canonical = @import("canonical.zig");
const emit_client = @import("emit_client.zig");

const ca = std.heap.c_allocator;

// Return codes (mirror include/chronos_ledger.h).
pub const CL_OK: c_int = 0;
pub const CL_ERR_ALLOC: c_int = -1;
pub const CL_ERR_FLOAT: c_int = -2;
pub const CL_ERR_NUMBER: c_int = -3;
pub const CL_ERR_RESERVED: c_int = -4;
pub const CL_ERR_NO_KEY: c_int = -5;
pub const CL_ERR_SIGN: c_int = -6;
pub const CL_ERR_PARSE: c_int = -7;
pub const CL_ERR_ARG: c_int = -8;
pub const CL_ERR_EMIT_UNAVAIL: c_int = -9;
pub const CL_ERR_EMIT_WOULDBLOCK: c_int = -10;

/// Generate an ML-DSA-65 keypair. `seed_ptr` (32 bytes) → deterministic; null → system RNG.
/// `out_pk` must hold PK_LEN (1952), `out_sk` SK_LEN (4032).
export fn cl_generate_keypair(seed_ptr: ?[*]const u8, out_pk: [*]u8, out_sk: [*]u8) c_int {
    const kp = blk: {
        if (seed_ptr) |p| {
            break :blk ledger.generateKeypair(@ptrCast(p));
        } else {
            break :blk ledger.generateKeypair(null);
        }
    } catch return CL_ERR_SIGN;
    @memcpy(out_pk[0..ledger.PK_LEN], &kp.pk);
    @memcpy(out_sk[0..ledger.SK_LEN], &kp.sk);
    return CL_OK;
}

/// Create a client-side chain (no signing key). Returns null on OOM.
export fn cl_chain_create() ?*ledger.Chain {
    const c = ca.create(ledger.Chain) catch return null;
    c.* = ledger.Chain.init(ca);
    return c;
}

/// Create a sink-side chain that signs milestone heads. `sk`=SK_LEN, `pk`=PK_LEN.
export fn cl_chain_create_signing(sk: [*]const u8, pk: [*]const u8) ?*ledger.Chain {
    const c = ca.create(ledger.Chain) catch return null;
    c.* = ledger.Chain.initSigning(ca, @ptrCast(sk), @ptrCast(pk));
    return c;
}

export fn cl_chain_destroy(c: ?*ledger.Chain) void {
    if (c) |p| ca.destroy(p);
}

/// Current chain head as 64 lowercase hex chars (genesis = 64 zeros).
export fn cl_chain_head_hex(c: ?*ledger.Chain, out_head_hex: [*]u8) c_int {
    const chain = c orelse return CL_ERR_ARG;
    const hh = std.fmt.bytesToHex(chain.head, .lower);
    @memcpy(out_head_hex[0..64], &hh);
    return CL_OK;
}

/// Append one event. `content_json` is the caller's event body (JSON object,
/// any key order, no reserved keys). On success, `*out_json`/`*out_len` receive
/// a freshly-allocated canonical shipped event (free with `cl_free`), and
/// `out_head_hex` (64 bytes) the new chain head.
export fn cl_append(
    c: ?*ledger.Chain,
    content_json: [*]const u8,
    content_len: usize,
    milestone: c_int,
    out_json: *?[*]u8,
    out_len: *usize,
    out_head_hex: [*]u8,
) c_int {
    const chain = c orelse return CL_ERR_ARG;
    out_json.* = null;
    out_len.* = 0;

    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, content_json[0..content_len], .{}) catch return CL_ERR_PARSE;
    defer parsed.deinit();
    if (parsed.value != .object) return CL_ERR_PARSE;

    var members: std.ArrayList(canonical.Member) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const val = ledger.toCanonical(a, entry.value_ptr.*) catch |e| return mapErr(e);
        members.append(a, .{ .key = entry.key_ptr.*, .value = val }) catch return CL_ERR_ALLOC;
    }

    const res = chain.append(members.items, milestone != 0) catch |e| return mapErr(e);
    // res.json was allocated with the chain's allocator (ca) → caller owns it.
    out_json.* = res.json.ptr;
    out_len.* = res.json.len;
    const hh = std.fmt.bytesToHex(res.head, .lower);
    @memcpy(out_head_hex[0..64], &hh);
    return CL_OK;
}

/// Verify a shipped event against `pk` (PK_LEN). Outputs are 0/1.
export fn cl_verify(
    pk: [*]const u8,
    shipped_json: [*]const u8,
    json_len: usize,
    out_chain_ok: *c_int,
    out_sig_present: *c_int,
    out_sig_ok: *c_int,
) c_int {
    const v = ledger.verifyEvent(ca, @ptrCast(pk), shipped_json[0..json_len]) catch return CL_ERR_PARSE;
    out_chain_ok.* = @intFromBool(v.chain_ok);
    out_sig_present.* = @intFromBool(v.sig_present);
    out_sig_ok.* = @intFromBool(v.sig_ok);
    return CL_OK;
}

/// Free a buffer returned by `cl_append`.
export fn cl_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| ca.free(p[0..len]);
}

/// Non-blocking fire-and-forget send of `payload` to the sink UDS at `socket_path`.
export fn cl_emit(socket_path: [*]const u8, path_len: usize, payload: [*]const u8, payload_len: usize) c_int {
    emit_client.emit(socket_path[0..path_len], payload[0..payload_len]) catch |e| return switch (e) {
        error.WouldBlock => CL_ERR_EMIT_WOULDBLOCK,
        else => CL_ERR_EMIT_UNAVAIL,
    };
    return CL_OK;
}

fn mapErr(e: ledger.Error) c_int {
    return switch (e) {
        error.FloatNotAllowed => CL_ERR_FLOAT,
        error.NumberTooLarge => CL_ERR_NUMBER,
        error.ReservedKey => CL_ERR_RESERVED,
        error.SigningKeyMissing => CL_ERR_NO_KEY,
        error.SignFailed => CL_ERR_SIGN,
        error.OutOfMemory => CL_ERR_ALLOC,
    };
}

// ───────────────────────────── tests ─────────────────────────────

test "C-ABI: keygen → signing chain → append milestone → verify" {
    const t = std.testing;
    var pk: [ledger.PK_LEN]u8 = undefined;
    var sk: [ledger.SK_LEN]u8 = undefined;
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i);
    try t.expectEqual(CL_OK, cl_generate_keypair(&seed, &pk, &sk));

    const chain = cl_chain_create_signing(&sk, &pk) orelse return error.TestUnexpectedResult;
    defer cl_chain_destroy(chain);

    const body =
        \\{"kind":"net","act":{"method":"POST","dest_host":"evildomain.example","req_bytes":"4096"},"t_mono_ns":"12950034901","t_wall_ms":"1750000000000"}
    ;
    var out_json: ?[*]u8 = null;
    var out_len: usize = 0;
    var head_hex: [64]u8 = undefined;
    try t.expectEqual(CL_OK, cl_append(chain, body.ptr, body.len, 1, &out_json, &out_len, &head_hex));
    defer cl_free(out_json, out_len);
    const shipped = out_json.?[0..out_len];
    try t.expect(std.mem.indexOf(u8, shipped, "\"sig\":") != null);

    var chain_ok: c_int = 0;
    var sig_present: c_int = 0;
    var sig_ok: c_int = 0;
    try t.expectEqual(CL_OK, cl_verify(&pk, shipped.ptr, shipped.len, &chain_ok, &sig_present, &sig_ok));
    try t.expectEqual(@as(c_int, 1), chain_ok);
    try t.expectEqual(@as(c_int, 1), sig_present);
    try t.expectEqual(@as(c_int, 1), sig_ok);
}

test "C-ABI: floats are rejected at the boundary" {
    const t = std.testing;
    const chain = cl_chain_create() orelse return error.TestUnexpectedResult;
    defer cl_chain_destroy(chain);
    const body = "{\"kind\":\"think\",\"score\":1.5}";
    var out_json: ?[*]u8 = null;
    var out_len: usize = 0;
    var head_hex: [64]u8 = undefined;
    try t.expectEqual(CL_ERR_FLOAT, cl_append(chain, body.ptr, body.len, 0, &out_json, &out_len, &head_hex));
}
