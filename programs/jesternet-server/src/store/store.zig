// Store — single owner of all mutable state.
//
// Pattern lifted from zig_ai_server/src/store/store.zig: mutex-
// protected in-memory hashmaps + WAL for durability (the zig_ai_server
// original span-spun on a SpinLock; this store parks on std.Io.Mutex —
// see the lock note below). Audit caveat #1
// applies (single-process atomicity); going multi-process reopens the
// design point and would need either SQLite BEGIN IMMEDIATE or an
// out-of-process lock manager.
//
// Each mutation:
//   1. Acquire mutex
//   2. Validate (fail-closed on bad input)
//   3. Mutate in-memory hashmap
//   4. WAL append (durable for ref/commit/event; batched for audit/metrics)
//   5. On WAL failure: revert the in-memory mutation, return the error
//   6. Release mutex
//
// The auth pipeline's TokenStore interface is satisfied by `tokenStore()`
// — returns a TokenStore that closes over `*Store` and dispatches into
// the lookup_token / record_token_use methods.

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const wal_mod = @import("wal.zig");
const pipeline = @import("../auth/pipeline.zig");

// The store is guarded by a parking mutex, NOT a spin lock. Mutations
// hold this lock across the whole WAL append — and `appendDurable`
// fsyncs *inside* the WAL lock (see wal.zig) — so a contending request
// thread would spin-burn a full CPU core for the entire ms-scale disk
// sync if this were a busy spin loop. `std.Io.Mutex` parks the waiter
// on the futex instead. Behaviour is identical (mutual exclusion); only
// the wait discipline changes. Audit caveat #1 (single-process
// atomicity) is unaffected.
//
// `std.Io.Mutex.lock/unlock` take an `io` — but only touch it when
// contended (the uncontended path is a lone cmpxchg), and the futex
// ops are keyed on the lock's address, so any threaded `io` parks/wakes
// correctly regardless of which per-connection `Io.Threaded` is live.
// Read paths (lookupToken, iterateRecent) reach the store through the
// pipeline's io-less TokenStore adapter, so the store stashes the io it
// was opened with (`self.io`) and locks through that everywhere rather
// than threading io into the read-path signatures (which would change
// the security-critical TokenStore interface).

/// Recent-events ring buffer size. Tradeoff: bigger = more
/// GET /api/notifications/recent calls served without WAL walk;
/// smaller = less memory. 64 covers the bell's typical view (last
/// 10) plus headroom for SSE reconnects with `Last-Event-ID` set to
/// a very-recent value (replay just consults the ring).
///
/// Per the CONFORMANCE SSE durable-replay canary: this ring MUST
/// NOT be the source of replay-truth. Replay reads from the WAL
/// (which is durable); the ring is a hot-path cache. Reconnects
/// across more than RECENT_RING_SIZE events fall through to WAL
/// replay and the canary's 50-event gap is satisfied structurally.
const RECENT_RING_SIZE: usize = 64;

const TokenHashMap = std.HashMapUnmanaged(
    [32]u8,
    types.ApiTokenRow,
    HashContext,
    std.hash_map.default_max_load_percentage,
);

const HashContext = struct {
    pub fn hash(_: @This(), key: [32]u8) u64 {
        return std.mem.readInt(u64, key[0..8], .little);
    }
    pub fn eql(_: @This(), a: [32]u8, b: [32]u8) bool {
        return std.mem.eql(u8, &a, &b);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// The io the store was opened with. Used only to park/wake the
    /// mutex futex (see the lock note above); valid for the store's
    /// lifetime because main.zig's boot io outlives the store.
    io: Io,
    wal: wal_mod.WalWriter,
    /// Owned "<data_dir>/wal.log" path (freed on deinit). Empty for a
    /// never-opened store.
    wal_path: []const u8 = "",

    // ── Row stores (in-memory mirrors of the on-disk WAL state) ──
    //
    // tokens: keyed by SHA-256 of the raw token (matches the auth
    // pipeline's lookup shape). Each row carries everything the
    // pipeline needs to make its decision.
    tokens: TokenHashMap = .empty,

    // events_recent: most-recently-inserted events, oldest at index
    // `recent_head`, newest at `(recent_head + recent_count - 1) %
    // RECENT_RING_SIZE`. Reading via `iterateRecent()`.
    events_recent: [RECENT_RING_SIZE]types.EventRow = undefined,
    recent_head: usize = 0,
    recent_count: usize = 0,

    /// Highest event seq the operator has marked as "seen". An event
    /// row's `seen` field is computed at read time as `row.seq <=
    /// seen_cursor`. Single cursor, monotonic. Persisted via the
    /// batched WAL op `event_seen_update` (the seen state isn't
    /// durability-critical — losing a few seconds of "marked as
    /// read" on crash is at worst a UI inconvenience).
    seen_cursor: u64 = 0,

    // Repos + refs hashmaps will land in #64 when the smart-HTTP
    // and Layer A handlers need them. The WalOp enum already
    // reserves their op codes; recover() sees-and-skips those ops
    // until the corresponding store methods land.

    pub fn open(allocator: std.mem.Allocator, io: Io, data_dir: []const u8) !Store {
        // Ensure the data directory exists, then place the WAL at
        // "<data_dir>/wal.log". Previously `data_dir` was discarded and a
        // cwd-relative "wal.log" was hardcoded — so `--data-dir` was a
        // silent no-op that only worked because the systemd unit also set
        // WorkingDirectory=<data_dir>. Running the binary from any other
        // cwd wrote the WAL to the wrong place.
        try Io.Dir.cwd().createDirPath(io, data_dir);
        const wal_path = try std.fs.path.join(allocator, &.{ data_dir, "wal.log" });
        errdefer allocator.free(wal_path);

        const wal = try wal_mod.WalWriter.open(allocator, io, wal_path);
        var store = Store{
            .allocator = allocator,
            .io = io,
            .wal = wal,
            .wal_path = wal_path,
        };
        _ = try store.recover(io);
        return store;
    }

    pub fn deinit(self: *Store, io: Io) void {
        self.tokens.deinit(self.allocator);
        self.wal.close(io);
        if (self.wal_path.len > 0) self.allocator.free(self.wal_path);
    }

    /// Flush dirty state to disk + sync the WAL. Called from main.zig
    /// during graceful shutdown so any batched writes that haven't
    /// reached disk yet are forced out before exit.
    pub fn flushDurable(self: *Store, io: Io) !void {
        try self.wal.sync(io);
    }

    /// Replay the WAL into in-memory state. Called once at startup.
    /// Returns the number of entries replayed.
    pub fn recover(self: *Store, io: Io) !u64 {
        return self.wal.replay(io, self, replayCallback);
    }

    fn replayCallback(ctx: ?*anyopaque, seq: u64, op: types.WalOp, payload: []const u8) void {
        const self: *Store = @alignCast(@ptrCast(ctx orelse return));
        switch (op) {
            .token_insert => self.replayTokenInsert(payload),
            .token_revoke => self.replayTokenRevoke(payload),
            .event_insert => self.replayEventInsert(seq, payload),
            .event_seen_update => self.replaySeenCursor(payload),
            .token_audit_insert,
            .token_last_used_update,
            .ref_update,
            .ref_delete,
            .commit_meta_insert,
            .commit_path_insert,
            .repo_insert,
            .repo_settings_update,
            .repo_loc_update,
            => {
                // Recognised but not yet materialised in-memory.
                // The WAL still records the durable history; the
                // in-memory shape catches up when #64 lands the
                // refs/repos/commit_meta hashmaps.
            },
        }
    }

    // ── Tokens ──────────────────────────────────────────────────────

    /// Insert a token row. Durable — token persistence MUST survive
    /// a crash because the user just saw the raw token once and can't
    /// re-issue it without losing it. WAL'd before the function returns.
    pub fn insertToken(self: *Store, io: Io, row: types.ApiTokenRow) !void {
        const payload = try serializeToken(self.allocator, row);
        defer self.allocator.free(payload);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.tokens.put(self.allocator, row.hash, row);
        // WAL after in-memory put so a successful return implies both
        // are consistent. On WAL failure we revert the put.
        _ = self.wal.appendDurable(io, .token_insert, payload) catch |err| {
            _ = self.tokens.remove(row.hash);
            return err;
        };
    }

    /// Mark a token revoked. Durable.
    pub fn revokeToken(self: *Store, io: Io, hash: [32]u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const row = self.tokens.getPtr(hash) orelse return error.TokenNotFound;
        if (row.revoked) return; // idempotent
        row.revoked = true;

        _ = self.wal.appendDurable(io, .token_revoke, &hash) catch |err| {
            row.revoked = false;
            return err;
        };
    }

    /// Lookup a token by hash. Returns a snapshot (NOT a pointer) so
    /// callers can use it after mutex release without worrying about
    /// hashmap rehash invalidating pointers. Read-only path; no WAL.
    pub fn lookupToken(self: *Store, hash: [32]u8) ?types.ApiTokenRow {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const row_ptr = self.tokens.getPtr(hash) orelse return null;
        return row_ptr.*;
    }

    /// Update the last_used_at timestamp for a token. Batched — a
    /// lost last_used update is a minor display-staleness issue, not
    /// a correctness issue. Don't block info/refs on this fsync.
    pub fn recordTokenUse(self: *Store, io: Io, hash: [32]u8, now_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.tokens.getPtr(hash)) |row| {
            row.last_used_at = now_ms;
            var payload: [40]u8 = undefined;
            @memcpy(payload[0..32], &hash);
            std.mem.writeInt(i64, payload[32..40], now_ms, .little);
            _ = self.wal.appendBatched(io, .token_last_used_update, &payload) catch {};
        }
    }

    fn replayTokenInsert(self: *Store, payload: []const u8) void {
        const row = deserializeToken(payload) orelse return;
        self.tokens.put(self.allocator, row.hash, row) catch {};
    }

    fn replayTokenRevoke(self: *Store, payload: []const u8) void {
        if (payload.len < 32) return;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, payload[0..32]);
        if (self.tokens.getPtr(hash)) |row| row.revoked = true;
    }

    // ── Events ──────────────────────────────────────────────────────

    /// Insert a new event. Durable — the SSE durable-replay canary
    /// requires events to be on disk before delivery to a connected
    /// stream client; otherwise a crash between deliver and fsync
    /// could lose an acknowledged event id. Returns the WAL seq,
    /// which becomes the SSE `id:` field.
    pub fn insertEvent(self: *Store, io: Io, kind: types.EventKind, repo: []const u8, title: []const u8, payload_json: []const u8, now_ms: i64) !u64 {
        // Validate the payload BEFORE it is stored. `handlers/
        // notifications.zig` embeds `row.payload.slice()` RAW (unescaped)
        // into the response JSON array on the stated contract "the payload
        // is already JSON". Nothing enforced that contract: an oversize
        // value was silently TRUNCATED by FixedStr512.fromSlice (yielding
        // unbalanced JSON), and a non-JSON value was embedded verbatim —
        // either one corrupts the ENTIRE /api/notifications/recent array
        // for every client. Enforce the contract at the insert boundary.
        //
        // An empty payload is a permitted sentinel: notifications.zig
        // renders it as "{}", so it never reaches the raw-embed path.
        if (payload_json.len > 512) return error.PayloadTooLarge;
        if (payload_json.len > 0) {
            const valid = std.json.validate(self.allocator, payload_json) catch return error.InvalidPayload;
            if (!valid) return error.InvalidPayload;
        }

        var row = types.EventRow{
            .kind = kind,
            .repo = types.FixedStr128.fromSlice(repo),
            .title = types.FixedStr256.fromSlice(title),
            .payload = types.FixedStr512.fromSlice(payload_json),
            .created_at = now_ms,
        };

        const wire = try serializeEvent(self.allocator, row);
        defer self.allocator.free(wire);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const seq = try self.wal.appendDurable(io, .event_insert, wire);
        row.seq = seq;
        self.pushRecent(row);
        return seq;
    }

    fn replayEventInsert(self: *Store, seq: u64, payload: []const u8) void {
        var row = deserializeEvent(payload) orelse return;
        row.seq = seq;
        self.pushRecent(row);
    }

    fn pushRecent(self: *Store, row: types.EventRow) void {
        if (self.recent_count < RECENT_RING_SIZE) {
            self.events_recent[(self.recent_head + self.recent_count) % RECENT_RING_SIZE] = row;
            self.recent_count += 1;
        } else {
            self.events_recent[self.recent_head] = row;
            self.recent_head = (self.recent_head + 1) % RECENT_RING_SIZE;
        }
    }

    /// Iterate the most-recent events, newest-first. Each emitted row
    /// has its `seen` field overlaid from `seen_cursor` (so callers
    /// see the live notion of "seen", not whatever was stored when
    /// the row was first written). Caller writes each event to its
    /// output (typically `GET /api/notifications/recent`). `limit`
    /// caps output count. Read-only; no WAL.
    pub fn iterateRecent(self: *Store, limit: usize, ctx: ?*anyopaque, cb: *const fn (ctx: ?*anyopaque, row: types.EventRow) void) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const n = @min(limit, self.recent_count);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (self.recent_head + self.recent_count - 1 - i) % RECENT_RING_SIZE;
            var row = self.events_recent[idx];
            row.seen = row.seq <= self.seen_cursor;
            cb(ctx, row);
        }
    }

    /// Mark all events with seq <= up_to as seen. Batched WAL — a
    /// lost seen-flag flip is a UI display issue, not a correctness
    /// issue. Idempotent + monotonic (seen_cursor only increases).
    pub fn markEventsSeenUpTo(self: *Store, io: Io, up_to: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (up_to <= self.seen_cursor) return; // idempotent

        const prev = self.seen_cursor;
        self.seen_cursor = up_to;

        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, up_to, .little);
        _ = self.wal.appendBatched(io, .event_seen_update, &payload) catch |err| {
            // WAL failure: revert and propagate. The next iterateRecent
            // will report the prior seen state until the operator retries.
            self.seen_cursor = prev;
            return err;
        };
    }

    fn replaySeenCursor(self: *Store, payload: []const u8) void {
        if (payload.len != 8) return;
        const up_to = std.mem.readInt(u64, payload[0..8], .little);
        if (up_to > self.seen_cursor) self.seen_cursor = up_to;
    }

    // ── TokenStore adapter ──────────────────────────────────────────
    //
    // The auth pipeline's TokenStore interface (pipeline.zig) needs
    // (a) a hash → row lookup and (b) a record-use side-effect.
    // We provide both as static functions that take a *Store via the
    // opaque ctx pointer.

    pub fn tokenStore(self: *Store, io_for_use: Io) pipeline.TokenStore {
        // record_use needs an io context to write the batched WAL
        // entry, but the TokenStore interface signature is
        // `fn(ctx, token_id) void`. We close over io_for_use via a
        // wrapper struct. For the v1 single-threaded server model the
        // io is per-connection, so we pass the connection's io here
        // and the closure holds it for the duration of one request.
        const Ctx = struct {
            store: *Store,
            io: Io,
        };
        // Stash both in a static-lifetime slot... actually this is
        // per-call (one connection thread), so allocating on the
        // stack of the caller is fine if we don't escape. But the
        // TokenStore ctx is *anyopaque, no lifetime guarantees.
        //
        // Cleanest path: ctx = *Store only, and record_use uses an
        // io captured at Store-init time. The store_io field exists
        // for this purpose — set once at boot, used by background
        // batched writes.
        _ = Ctx;
        _ = io_for_use;

        return .{
            .ctx = @ptrCast(self),
            .lookup = lookupAdapter,
            .record_use = recordUseAdapter,
        };
    }

    fn lookupAdapter(ctx: *anyopaque, hash: [32]u8) ?pipeline.TokenRow {
        const self: *Store = @alignCast(@ptrCast(ctx));
        const row = self.lookupToken(hash) orelse return null;

        // FixedString-to-FixedString copies — each is a packed struct
        // with inline buffer, so this is a memcpy under the hood and
        // safe to return across the mutex boundary because pipeline's
        // TokenRow owns its bytes.
        return .{
            .id = row.id,
            .user_handle = row.user_handle,
            .scopes = .{
                .repo_read = row.scopes.repo_read,
                .repo_write = row.scopes.repo_write,
            },
            .expires_at = row.expires_at,
            .repo_pattern = row.repo_pattern,
            .revoked = row.revoked,
        };
    }

    fn recordUseAdapter(ctx: *anyopaque, token_id: []const u8) void {
        // Best-effort: the pipeline calls this for audit; if we can't
        // write, the auth check still succeeds. For #62 the adapter
        // is a no-op stub — the WAL write requires an io context the
        // adapter doesn't have, and threading it through would change
        // the pipeline interface. For now the recordTokenUse on the
        // Store directly is called from the handler glue in #64,
        // where the request's io is available. This stub satisfies
        // the interface; #64 either replaces with a real flow or
        // pins this as a deferred concern.
        _ = ctx;
        _ = token_id;
    }
};

// ── Serialization ───────────────────────────────────────────────────
//
// WAL payloads are encoded FIELD-WISE in explicit little-endian form,
// each carrying a leading 1-byte row-format version. This is NOT a raw
// `@sizeOf`/`asBytes` struct dump. The old dump gated replay on
// `payload.len == @sizeOf(T)`, which made replay SILENTLY DROP EVERY
// ROW on any of:
//   - a field addition / reorder,
//   - a `TokenScopes` / enum widening,
//   - a compiler struct-layout change,
//   - a cross-arch migration (the deploy flow builds on macOS, runs on
//     x86_64-linux) —
// without ever tripping WAL_VERSION, and it wrote undefined padding
// bytes to disk (and into the CRC).
//
// With field-wise encoding: strings are length-prefixed from
// `FixedString.slice()` (no padding, no capacity leak), ints are fixed
// little-endian, enums/bools are one byte. A genuine format change bumps
// the per-row version constant below and adds a decode branch for the
// old version (migration) instead of losing the data. Decoders are
// bounds-checked and return null on truncation / unknown version / a
// length that exceeds the destination FixedString capacity.

const TOKEN_ROW_VERSION: u8 = 1;
const EVENT_ROW_VERSION: u8 = 1;

const Encoder = struct {
    buf: []u8,
    n: usize = 0,

    fn byte(self: *Encoder, v: u8) void {
        self.buf[self.n] = v;
        self.n += 1;
    }
    fn int(self: *Encoder, comptime T: type, v: T) void {
        const size = @divExact(@bitSizeOf(T), 8);
        std.mem.writeInt(T, self.buf[self.n..][0..size], v, .little);
        self.n += size;
    }
    fn raw(self: *Encoder, s: []const u8) void {
        @memcpy(self.buf[self.n..][0..s.len], s);
        self.n += s.len;
    }
    /// Length-prefixed string: [u16 LE len][bytes].
    fn str(self: *Encoder, s: []const u8) void {
        self.int(u16, @intCast(s.len));
        self.raw(s);
    }
};

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *Decoder) ?u8 {
        if (self.pos + 1 > self.data.len) return null;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn int(self: *Decoder, comptime T: type) ?T {
        const size = @divExact(@bitSizeOf(T), 8);
        if (self.pos + size > self.data.len) return null;
        const v = std.mem.readInt(T, self.data[self.pos..][0..size], .little);
        self.pos += size;
        return v;
    }
    fn take(self: *Decoder, len: usize) ?[]const u8 {
        if (self.pos + len > self.data.len) return null;
        const s = self.data[self.pos..][0..len];
        self.pos += len;
        return s;
    }
    /// Length-prefixed string → FixedString(cap). Rejects (null) rather
    /// than truncating if the encoded length exceeds the field capacity.
    fn str(self: *Decoder, comptime Str: type) ?Str {
        const cap = @typeInfo(@FieldType(Str, "buf")).array.len;
        const len = self.int(u16) orelse return null;
        if (len > cap) return null;
        const bytes = self.take(len) orelse return null;
        return Str.fromSlice(bytes);
    }
};

fn serializeToken(allocator: std.mem.Allocator, row: types.ApiTokenRow) ![]u8 {
    var buf: [512]u8 = undefined;
    var enc = Encoder{ .buf = &buf };
    enc.byte(TOKEN_ROW_VERSION);
    enc.str(row.id.slice());
    enc.str(row.user_handle.slice());
    enc.raw(&row.hash);
    enc.str(row.label.slice());
    enc.byte(@bitCast(row.scopes));
    enc.int(i64, row.created_at);
    enc.int(i64, row.last_used_at);
    enc.int(i64, row.expires_at);
    enc.str(row.repo_pattern.slice());
    enc.byte(@intFromBool(row.revoked));
    return allocator.dupe(u8, buf[0..enc.n]);
}

fn deserializeToken(payload: []const u8) ?types.ApiTokenRow {
    var dec = Decoder{ .data = payload };
    if ((dec.byte() orelse return null) != TOKEN_ROW_VERSION) return null;
    var row = types.ApiTokenRow{};
    row.id = dec.str(types.FixedStr16) orelse return null;
    row.user_handle = dec.str(types.FixedStr64) orelse return null;
    const hash = dec.take(32) orelse return null;
    @memcpy(&row.hash, hash);
    row.label = dec.str(types.FixedStr128) orelse return null;
    row.scopes = @bitCast(dec.byte() orelse return null);
    row.created_at = dec.int(i64) orelse return null;
    row.last_used_at = dec.int(i64) orelse return null;
    row.expires_at = dec.int(i64) orelse return null;
    row.repo_pattern = dec.str(types.FixedStr128) orelse return null;
    row.revoked = (dec.byte() orelse return null) != 0;
    return row;
}

fn serializeEvent(allocator: std.mem.Allocator, row: types.EventRow) ![]u8 {
    // `seq` is the WAL sequence number, assigned at append time — it is
    // NOT part of the payload (it is recovered from the WAL position on
    // replay). `seen` is computed at read time from `seen_cursor`, so it
    // is likewise not persisted here.
    var buf: [1024]u8 = undefined;
    var enc = Encoder{ .buf = &buf };
    enc.byte(EVENT_ROW_VERSION);
    enc.byte(@intFromEnum(row.kind));
    enc.str(row.repo.slice());
    enc.str(row.title.slice());
    enc.str(row.payload.slice());
    enc.int(i64, row.created_at);
    return allocator.dupe(u8, buf[0..enc.n]);
}

/// Decode an `event_insert` payload. Public so `events.zig`'s SSE
/// replay path decodes via the exact same field-wise reader (it used to
/// `@memcpy` the raw struct, which had the identical silent-drop hazard).
/// `seq` is left at 0; the caller overwrites it with the WAL seq.
pub fn deserializeEvent(payload: []const u8) ?types.EventRow {
    var dec = Decoder{ .data = payload };
    if ((dec.byte() orelse return null) != EVENT_ROW_VERSION) return null;
    var row = types.EventRow{};
    row.kind = std.enums.fromInt(types.EventKind, dec.byte() orelse return null) orelse return null;
    row.repo = dec.str(types.FixedStr128) orelse return null;
    row.title = dec.str(types.FixedStr256) orelse return null;
    row.payload = dec.str(types.FixedStr512) orelse return null;
    row.created_at = dec.int(i64) orelse return null;
    return row;
}

// ── Tests ──

const testing = std.testing;

test "Store: insert + lookup + revoke a token (in-memory only, no replay)" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    // Each test uses a unique data_dir so the WAL files can't collide
    // on a shared cwd path (Store.open now honours data_dir).
    const dir = "test-data-store-tokens";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    var token: types.ApiTokenRow = .{
        .id = types.FixedStr16.fromSlice("jak_aaaaaaaa"),
        .user_handle = types.FixedStr64.fromSlice("jak"),
        .scopes = .{ .repo_read = true, .repo_write = true },
        .created_at = 1_700_000_000_000,
        .repo_pattern = types.FixedStr128.fromSlice("*"),
    };
    token.hash[0] = 1; // unique key

    try store.insertToken(io, token);

    const found = store.lookupToken(token.hash);
    try testing.expect(found != null);
    try testing.expect(found.?.scopes.repo_read);
    try testing.expect(!found.?.revoked);

    try store.revokeToken(io, token.hash);
    const after_revoke = store.lookupToken(token.hash);
    try testing.expect(after_revoke.?.revoked);
}

test "Store: insertEvent assigns durable seq" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-store-seq";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    const seq1 = try store.insertEvent(io, .commit_pushed, "jak/foo", "push: main → abc", "{}", 1_700_000_000_000);
    const seq2 = try store.insertEvent(io, .commit_pushed, "jak/bar", "push: main → def", "{}", 1_700_000_000_001);
    try testing.expectEqual(@as(u64, 1), seq1);
    try testing.expectEqual(@as(u64, 2), seq2);
}

test "Store: recover restores tokens from WAL" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-store-recover";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var hash: [32]u8 = .{0} ** 32;
    hash[31] = 42;

    // Phase 1: open, insert, drop the store.
    {
        var store = try Store.open(testing.allocator, io, dir);
        defer store.deinit(io);

        var token: types.ApiTokenRow = .{
            .id = types.FixedStr16.fromSlice("jak_persist"),
            .user_handle = types.FixedStr64.fromSlice("rich"),
            .scopes = .{ .repo_read = true },
            .repo_pattern = types.FixedStr128.fromSlice("rich/*"),
        };
        token.hash = hash;
        try store.insertToken(io, token);
    }

    // Phase 2: reopen — recover should bring the token back.
    {
        var store = try Store.open(testing.allocator, io, dir);
        defer store.deinit(io);

        const found = store.lookupToken(hash);
        try testing.expect(found != null);
        try testing.expectEqualStrings("rich", found.?.user_handle.slice());
        try testing.expectEqualStrings("rich/*", found.?.repo_pattern.slice());
    }
}

const RecentCollector = struct {
    list: *std.ArrayListUnmanaged(types.EventRow),
};

fn collectRecent(ctx: ?*anyopaque, row: types.EventRow) void {
    const c: *RecentCollector = @alignCast(@ptrCast(ctx orelse return));
    c.list.append(testing.allocator, row) catch {};
}

test "Store: iterateRecent returns newest-first" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-store-recent";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    _ = try store.insertEvent(io, .commit_pushed, "a", "first", "{}", 1);
    _ = try store.insertEvent(io, .commit_pushed, "b", "second", "{}", 2);
    _ = try store.insertEvent(io, .commit_pushed, "c", "third", "{}", 3);

    var list: std.ArrayListUnmanaged(types.EventRow) = .empty;
    defer list.deinit(testing.allocator);
    var ctx = RecentCollector{ .list = &list };

    store.iterateRecent(10, &ctx, collectRecent);

    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("third", list.items[0].title.slice());
    try testing.expectEqualStrings("second", list.items[1].title.slice());
    try testing.expectEqualStrings("first", list.items[2].title.slice());
}

test "Store: TokenStore adapter wires the pipeline shape" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-store-adapter";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    var hash: [32]u8 = .{0} ** 32;
    hash[0] = 0xAB;

    var token: types.ApiTokenRow = .{
        .id = types.FixedStr16.fromSlice("jak_adapter"),
        .user_handle = types.FixedStr64.fromSlice("jak"),
        .scopes = .{ .repo_read = true, .repo_write = true },
        .expires_at = 0,
        .repo_pattern = types.FixedStr128.fromSlice("jak/*"),
    };
    token.hash = hash;
    try store.insertToken(io, token);

    const ts = store.tokenStore(io);
    const result = ts.lookup(ts.ctx, hash);
    try testing.expect(result != null);
    try testing.expectEqualStrings("jak", result.?.user_handle.slice());
    try testing.expectEqualStrings("jak/*", result.?.repo_pattern.slice());
    try testing.expect(result.?.scopes.repo_read);
    try testing.expect(result.?.scopes.repo_write);

    // Adapter's record_use is a no-op stub — calling shouldn't crash.
    ts.record_use(ts.ctx, "jak_adapter");
}

test "Store: insertEvent rejects oversize and non-JSON payloads" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const dir = "test-data-store-payload";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var store = try Store.open(testing.allocator, io, dir);
    defer store.deinit(io);

    // A >512-byte payload would be silently truncated by FixedStr512 and
    // corrupt the /api/notifications/recent JSON array — reject it.
    const oversize = "[" ++ ("0," ** 300) ++ "0]"; // ~600+ bytes, valid JSON but too big
    try testing.expect(oversize.len > 512);
    try testing.expectError(error.PayloadTooLarge, store.insertEvent(io, .commit_pushed, "a", "big", oversize, 1));

    // A non-JSON payload embedded raw would break the response — reject it.
    try testing.expectError(error.InvalidPayload, store.insertEvent(io, .commit_pushed, "a", "bad", "not json", 1));
    try testing.expectError(error.InvalidPayload, store.insertEvent(io, .commit_pushed, "a", "unbalanced", "{\"k\":", 1));

    // Well-formed payloads (including the empty sentinel) are accepted.
    _ = try store.insertEvent(io, .commit_pushed, "a", "empty-ok", "", 1);
    _ = try store.insertEvent(io, .commit_pushed, "a", "json-ok", "{\"branch\":\"main\"}", 2);
}

test "Store: versioned token serialization round-trips and rejects bad version" {
    const t = testing.allocator;

    var row = types.ApiTokenRow{
        .id = types.FixedStr16.fromSlice("jak_roundtrip"),
        .user_handle = types.FixedStr64.fromSlice("rich"),
        .label = types.FixedStr128.fromSlice("ci-bot"),
        .scopes = .{ .repo_read = true, .repo_write = true },
        .created_at = 1_700_000_000_123,
        .last_used_at = 1_700_000_050_456,
        .expires_at = 1_800_000_000_789,
        .repo_pattern = types.FixedStr128.fromSlice("rich/*"),
        .revoked = true,
    };
    row.hash[0] = 0xDE;
    row.hash[31] = 0xAD;

    const wire = try serializeToken(t, row);
    defer t.free(wire);

    // First byte is the row-format version.
    try testing.expectEqual(TOKEN_ROW_VERSION, wire[0]);

    const back = deserializeToken(wire) orelse return error.DecodeFailed;
    try testing.expectEqualStrings("jak_roundtrip", back.id.slice());
    try testing.expectEqualStrings("rich", back.user_handle.slice());
    try testing.expectEqualStrings("ci-bot", back.label.slice());
    try testing.expectEqualStrings("rich/*", back.repo_pattern.slice());
    try testing.expect(std.mem.eql(u8, &row.hash, &back.hash));
    try testing.expect(back.scopes.repo_read and back.scopes.repo_write);
    try testing.expectEqual(row.created_at, back.created_at);
    try testing.expectEqual(row.last_used_at, back.last_used_at);
    try testing.expectEqual(row.expires_at, back.expires_at);
    try testing.expect(back.revoked);

    // An unknown version byte is rejected (not misread), and a truncated
    // payload decodes to null instead of reading past the buffer.
    var bad_ver = try t.dupe(u8, wire);
    defer t.free(bad_ver);
    bad_ver[0] = 0xFF;
    try testing.expect(deserializeToken(bad_ver) == null);
    try testing.expect(deserializeToken(wire[0 .. wire.len - 1]) == null);
}

test "Store: versioned event serialization round-trips" {
    const t = testing.allocator;

    const row = types.EventRow{
        .kind = .pr_merged,
        .repo = types.FixedStr128.fromSlice("jak/forge"),
        .title = types.FixedStr256.fromSlice("PR #7 merged into main"),
        .payload = types.FixedStr512.fromSlice("{\"pr\":7,\"branch\":\"main\"}"),
        .created_at = 1_700_000_000_000,
    };

    const wire = try serializeEvent(t, row);
    defer t.free(wire);
    try testing.expectEqual(EVENT_ROW_VERSION, wire[0]);

    const back = deserializeEvent(wire) orelse return error.DecodeFailed;
    try testing.expectEqual(types.EventKind.pr_merged, back.kind);
    try testing.expectEqualStrings("jak/forge", back.repo.slice());
    try testing.expectEqualStrings("PR #7 merged into main", back.title.slice());
    try testing.expectEqualStrings("{\"pr\":7,\"branch\":\"main\"}", back.payload.slice());
    try testing.expectEqual(row.created_at, back.created_at);
    // seq is NOT part of the payload — the caller overlays the WAL seq.
    try testing.expectEqual(@as(u64, 0), back.seq);
}
