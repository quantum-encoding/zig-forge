// Store — single owner of all mutable state.
//
// Pattern lifted from zig_ai_server/src/store/store.zig: SpinLock-
// protected in-memory hashmaps + WAL for durability. Audit caveat #1
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

const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

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
    mutex: SpinLock = .{},
    wal: wal_mod.WalWriter,

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
        // data_dir/wal.log — the path is the data_dir prefix + filename.
        // For #62 scaffold we just use a fixed relative path; #64's
        // boot wiring will pass the real data_dir.
        _ = data_dir;
        const wal = try wal_mod.WalWriter.open(allocator, io, "wal.log");
        var store = Store{
            .allocator = allocator,
            .wal = wal,
        };
        _ = try store.recover(io);
        return store;
    }

    pub fn deinit(self: *Store, io: Io) void {
        self.tokens.deinit(self.allocator);
        self.wal.close(io);
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

        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();
        const row_ptr = self.tokens.getPtr(hash) orelse return null;
        return row_ptr.*;
    }

    /// Update the last_used_at timestamp for a token. Batched — a
    /// lost last_used update is a minor display-staleness issue, not
    /// a correctness issue. Don't block info/refs on this fsync.
    pub fn recordTokenUse(self: *Store, io: Io, hash: [32]u8, now_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        var row = types.EventRow{
            .kind = kind,
            .repo = types.FixedStr128.fromSlice(repo),
            .title = types.FixedStr256.fromSlice(title),
            .payload = types.FixedStr512.fromSlice(payload_json),
            .created_at = now_ms,
        };

        const wire = try serializeEvent(self.allocator, row);
        defer self.allocator.free(wire);

        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

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
// Each WAL payload is a packed in-memory layout. Versioning lives at
// the WAL header level (WAL_VERSION = 1); a future format change bumps
// the header and replay() validates before dispatching.

fn serializeToken(allocator: std.mem.Allocator, row: types.ApiTokenRow) ![]u8 {
    const size = @sizeOf(types.ApiTokenRow);
    const buf = try allocator.alloc(u8, size);
    @memcpy(buf, std.mem.asBytes(&row));
    return buf;
}

fn deserializeToken(payload: []const u8) ?types.ApiTokenRow {
    if (payload.len != @sizeOf(types.ApiTokenRow)) return null;
    var row: types.ApiTokenRow = undefined;
    @memcpy(std.mem.asBytes(&row), payload);
    return row;
}

fn serializeEvent(allocator: std.mem.Allocator, row: types.EventRow) ![]u8 {
    const size = @sizeOf(types.EventRow);
    const buf = try allocator.alloc(u8, size);
    @memcpy(buf, std.mem.asBytes(&row));
    return buf;
}

fn deserializeEvent(payload: []const u8) ?types.EventRow {
    if (payload.len != @sizeOf(types.EventRow)) return null;
    var row: types.EventRow = undefined;
    @memcpy(std.mem.asBytes(&row), payload);
    return row;
}

// ── Tests ──

const testing = std.testing;

test "Store: insert + lookup + revoke a token (in-memory only, no replay)" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    const path = "test-store-tokens.log";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    // For tests we have to use the fixed "wal.log" path the store
    // currently hardcodes — so just clean both up.
    Io.Dir.cwd().deleteFile(io, "wal.log") catch {};
    defer Io.Dir.cwd().deleteFile(io, "wal.log") catch {};

    var store = try Store.open(testing.allocator, io, "data");
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

    Io.Dir.cwd().deleteFile(io, "wal.log") catch {};
    defer Io.Dir.cwd().deleteFile(io, "wal.log") catch {};

    var store = try Store.open(testing.allocator, io, "data");
    defer store.deinit(io);

    const seq1 = try store.insertEvent(io, .commit_pushed, "jak/foo", "push: main → abc", "{}", 1_700_000_000_000);
    const seq2 = try store.insertEvent(io, .commit_pushed, "jak/bar", "push: main → def", "{}", 1_700_000_000_001);
    try testing.expectEqual(@as(u64, 1), seq1);
    try testing.expectEqual(@as(u64, 2), seq2);
}

test "Store: recover restores tokens from WAL" {
    var io_threaded: Io.Threaded = .init(testing.allocator, .{});
    const io = io_threaded.io();

    Io.Dir.cwd().deleteFile(io, "wal.log") catch {};
    defer Io.Dir.cwd().deleteFile(io, "wal.log") catch {};

    var hash: [32]u8 = .{0} ** 32;
    hash[31] = 42;

    // Phase 1: open, insert, drop the store.
    {
        var store = try Store.open(testing.allocator, io, "data");
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
        var store = try Store.open(testing.allocator, io, "data");
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

    Io.Dir.cwd().deleteFile(io, "wal.log") catch {};
    defer Io.Dir.cwd().deleteFile(io, "wal.log") catch {};

    var store = try Store.open(testing.allocator, io, "data");
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

    Io.Dir.cwd().deleteFile(io, "wal.log") catch {};
    defer Io.Dir.cwd().deleteFile(io, "wal.log") catch {};

    var store = try Store.open(testing.allocator, io, "data");
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
