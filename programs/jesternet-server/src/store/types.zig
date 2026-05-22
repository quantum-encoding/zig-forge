// Row types + WAL op codes.
//
// Mirrors the schema in jesternet-astro/scripts/schema.sql with one
// deliberate departure: fixed-size strings via FixedString instead of
// heap-allocated. The store keeps everything in-memory under a mutex;
// heap allocation per row would multiply work for no gain at our scale
// (~thousands of refs, hundreds of repos, low-millions of events).
//
// FixedString sizing follows the schema's stated maxima where the
// schema documents one, and 64/128/256 otherwise. Hashes are stored
// as their raw 32-byte form (NOT hex) since the lookup table keys on
// the raw bytes for O(1) match.

const std = @import("std");
const strings = @import("../strings.zig");

// Re-export the FixedString family so existing store-internal code
// can `types.FixedStr64` without a separate import.
pub const FixedString = strings.FixedString;
pub const FixedStr16 = strings.FixedStr16;
pub const FixedStr32 = strings.FixedStr32;
pub const FixedStr64 = strings.FixedStr64;
pub const FixedStr128 = strings.FixedStr128;
pub const FixedStr256 = strings.FixedStr256;
pub const FixedStr512 = strings.FixedStr512;

// ── Hex helper ──────────────────────────────────────────────────────

/// Lowercase-hex encode `bytes` into `out`. `out.len` must be 2*bytes.len.
pub fn hexEncode(bytes: []const u8, out: []u8) void {
    std.debug.assert(out.len == bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

// ── api_tokens ──────────────────────────────────────────────────────
//
// Mirrors the TS reference's TokenRow (api-tokens.ts:27-39). The
// pipeline's TokenStore interface reads these fields.

pub const ApiTokenRow = struct {
    /// 'jak_XXXXXXXX' style; the public id surfaced in audit logs.
    id: FixedStr16 = .{},
    /// Account/owner handle. Set from issueToken's userHandle arg.
    user_handle: FixedStr64 = .{},
    /// SHA-256 of the whole raw token (not hex; raw bytes). The lookup
    /// table keys on this.
    hash: [32]u8 = .{0} ** 32,
    /// Free-form label users set at issue time.
    label: FixedStr128 = .{},
    /// Scope flags. Mirrors the TS reference's `scopes: string[]`
    /// JSON array (typically `['repo:read', 'repo:write']`).
    scopes: TokenScopes = .{},
    /// epoch-ms.
    created_at: i64 = 0,
    /// epoch-ms; 0 = never used yet.
    last_used_at: i64 = 0,
    /// epoch-ms; 0 = never expires.
    expires_at: i64 = 0,
    /// '*' = all repos, 'owner/*' = owner-scoped, 'owner/name' = exact.
    repo_pattern: FixedStr128 = .{},
    revoked: bool = false,
};

pub const TokenScopes = packed struct(u8) {
    repo_read: bool = false,
    repo_write: bool = false,
    _reserved: u6 = 0,
};

// ── token_audit ─────────────────────────────────────────────────────

pub const TokenAuditKind = enum(u8) {
    issue = 1,
    use = 2,
    revoke = 3,
    delete = 4,
};

pub const TokenAuditRow = struct {
    seq: u64 = 0,
    token_id: FixedStr16 = .{},
    user_handle: FixedStr64 = .{},
    kind: TokenAuditKind = .use,
    ip: FixedStr64 = .{},
    ua: FixedStr256 = .{},
    /// JSON-encoded meta blob (label, scopes, etc.).
    meta: FixedStr512 = .{},
    /// epoch-ms.
    at: i64 = 0,
};

// ── repos ───────────────────────────────────────────────────────────

pub const RepoRow = struct {
    owner: FixedStr64 = .{},
    name: FixedStr64 = .{},
    description: FixedStr512 = .{},
    language: FixedStr32 = .{},
    loc: u64 = 0,
    default_branch: FixedStr64 = .{},
    is_private: bool = false,
    allow_force_push: bool = false,
    /// JSON array string ("[\"tag1\",\"tag2\"]").
    topics: FixedStr512 = .{},
    head_sha: FixedStr64 = .{},  // 40-char hex, plus headroom
    head_message: FixedStr256 = .{},
    head_author: FixedStr128 = .{},
    /// epoch-ms.
    head_date: i64 = 0,
    /// epoch-ms.
    updated_at: i64 = 0,
    /// epoch-ms.
    created_at: i64 = 0,
};

// ── refs ────────────────────────────────────────────────────────────

pub const RefRow = struct {
    owner: FixedStr64 = .{},
    name: FixedStr64 = .{},
    /// Full ref form: 'refs/heads/main', 'refs/tags/v1.0', etc.
    ref_name: FixedStr256 = .{},
    /// 40-char hex SHA-1 OID (or 64-char SHA-256 if/when that lands).
    oid: FixedStr64 = .{},
    /// epoch-ms.
    updated_at: i64 = 0,
};

// ── commit_meta ─────────────────────────────────────────────────────

pub const CommitMetaRow = struct {
    owner: FixedStr64 = .{},
    name: FixedStr64 = .{},
    sha: FixedStr64 = .{},
    /// Space-separated parent SHAs (one per parent; merge commits have 2+).
    parents: FixedStr256 = .{},
    tree_sha: FixedStr64 = .{},
    author: FixedStr128 = .{},
    message: FixedStr512 = .{},
    /// epoch-ms.
    date: i64 = 0,
};

// ── commit_paths ────────────────────────────────────────────────────

pub const PathChangeKind = enum(u8) {
    add = 1,
    modify = 2,
    delete = 3,
    rename = 4,
};

pub const CommitPathRow = struct {
    owner: FixedStr64 = .{},
    name: FixedStr64 = .{},
    sha: FixedStr64 = .{},
    path: FixedStr512 = .{},
    change: PathChangeKind = .add,
};

// ── events ──────────────────────────────────────────────────────────
//
// The events log mounts on the WAL primitive (see events.zig). The
// `seq` field is the WAL sequence number, which is what the SSE
// durable-replay canary's Last-Event-ID header carries. CRITICAL:
// this MUST be the durable WAL seq, not an in-memory id — the canary
// will catch any backend that delivers an event id before the WAL
// entry is fsync'd to disk (a crash between deliver and fsync would
// lose the event on reconnect).

pub const EventKind = enum(u8) {
    commit_pushed = 1,
    build_success = 2,
    build_failure = 3,
    deploy_success = 4,
    deploy_failure = 5,
    pr_opened = 6,
    pr_closed = 7,
    pr_merged = 8,
    pr_commented = 9,
};

pub const EventRow = struct {
    /// Durable WAL sequence number — becomes the SSE `id:` field.
    seq: u64 = 0,
    kind: EventKind = .commit_pushed,
    /// "owner/name" — the affected repo.
    repo: FixedStr128 = .{},
    /// Human-readable title surfaced in the bell.
    title: FixedStr256 = .{},
    /// JSON-encoded payload.
    payload: FixedStr512 = .{},
    seen: bool = false,
    /// epoch-ms.
    created_at: i64 = 0,
};

// ── WalOp enum ──────────────────────────────────────────────────────
//
// Every mutation that goes through the WAL has an op code. The op
// determines (a) how to deserialise the payload on replay, and (b)
// whether the write is DURABLE (fsync-before-ack) or BATCHED
// (best-effort, background fsync).
//
// Durability classification — see ZIG_PORT_AUDIT.md caveat #2 and the
// principal architect's note on #62:
//
//   DURABLE: ref_update, commit_meta_insert, commit_path_insert,
//            event_insert (esp. commit.pushed for the SSE canary).
//            These MUST be on disk before any 200 OK is returned to a
//            git-receive-pack client.
//
//   BATCHED: token_audit_insert, token_last_used_update, repo_loc_update.
//            Lazy-flush is acceptable; a small loss window on crash
//            doesn't compromise correctness (audit gap, stale 'last
//            used' display, slightly out-of-date LOC count). These
//            must NOT block read-heavy paths like info/refs.
//
// The WAL writer keys off this classification automatically — see
// `WalOp.isDurable()`.

pub const WalOp = enum(u8) {
    // Durable ops (fsync-before-ack).
    ref_update = 0x10,
    ref_delete = 0x11,
    commit_meta_insert = 0x12,
    commit_path_insert = 0x13,
    event_insert = 0x14,
    repo_insert = 0x15,
    repo_settings_update = 0x16,
    token_insert = 0x17,
    token_revoke = 0x18,

    // Batched ops (background fsync OK).
    token_audit_insert = 0x80,
    token_last_used_update = 0x81,
    repo_loc_update = 0x82,
    event_seen_update = 0x83,

    pub fn isDurable(self: WalOp) bool {
        return @intFromEnum(self) < 0x80;
    }
};

// ── Tests ──

test "FixedString round-trip" {
    var s = FixedStr64.fromSlice("hello world");
    try std.testing.expectEqualStrings("hello world", s.slice());
    try std.testing.expect(s.eql("hello world"));
    try std.testing.expect(!s.eql("hello"));
}

test "FixedString truncation on too-long input" {
    const too_long = "x" ** 100;
    var s = FixedStr64.fromSlice(too_long);
    try std.testing.expectEqual(@as(usize, 64), s.slice().len);
}

test "hexEncode produces lowercase hex" {
    var out: [8]u8 = undefined;
    hexEncode(&.{ 0x0a, 0xb1, 0xc2, 0xff }, &out);
    try std.testing.expectEqualStrings("0ab1c2ff", &out);
}

test "WalOp.isDurable classification" {
    // Durable ops (op code < 0x80).
    try std.testing.expect(WalOp.ref_update.isDurable());
    try std.testing.expect(WalOp.commit_meta_insert.isDurable());
    try std.testing.expect(WalOp.commit_path_insert.isDurable());
    try std.testing.expect(WalOp.event_insert.isDurable());

    // Batched ops (op code >= 0x80).
    try std.testing.expect(!WalOp.token_audit_insert.isDurable());
    try std.testing.expect(!WalOp.token_last_used_update.isDurable());
    try std.testing.expect(!WalOp.repo_loc_update.isDurable());
}

test "TokenScopes is one byte and packs the two scope bits" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(TokenScopes));
    const both: TokenScopes = .{ .repo_read = true, .repo_write = true };
    const read_only: TokenScopes = .{ .repo_read = true };
    try std.testing.expect(both.repo_read and both.repo_write);
    try std.testing.expect(read_only.repo_read and !read_only.repo_write);
}
