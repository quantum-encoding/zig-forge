// Store — single owner of all mutable state
// Protected by RwLock. WAL-first writes for crash safety.
// In-memory hash maps for O(1) lookups.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("types.zig");
const wal_mod = @import("wal.zig");
const firestore = @import("../firestore.zig");
const gcp_mod = @import("../gcp.zig");

/// Atomic spinlock — no io, no libc, works on Zigix
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

pub const Store = struct {
    allocator: std.mem.Allocator,

    // Thread safety — atomic spinlock (no io needed, works on Zigix)
    mutex: SpinLock = .{},

    // In-memory indices
    accounts: std.StringHashMapUnmanaged(types.Account) = .empty,
    keys: KeyHashMap = .empty,
    reservations: std.AutoHashMapUnmanaged(u64, types.Reservation) = .empty,

    // Persistence
    wal: wal_mod.WalWriter,
    data_dir: []const u8,

    // Firestore write-through (optional — nil when no GCP context)
    gcp_ctx: ?*gcp_mod.GcpContext = null,
    // Track dirty accounts for background balance flush (avoids Firestore 1-write/sec contention)
    dirty_accounts: std.StringHashMapUnmanaged(void) = .empty,

    // Monotonic counters
    next_reservation_id: u64 = 1,
    next_ledger_seq: u64 = 1,

    const KeyHashMap = std.HashMapUnmanaged([32]u8, types.ApiKey, KeyHashContext, std.hash_map.default_max_load_percentage);

    const KeyHashContext = struct {
        pub fn hash(_: @This(), key: [32]u8) u64 {
            return std.mem.readInt(u64, key[0..8], .little);
        }
        pub fn eql(_: @This(), a: [32]u8, b: [32]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) Store {
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .wal = .{
                .allocator = allocator,
                .file_path = std.fmt.allocPrint(allocator, "{s}/wal.log", .{data_dir}) catch "data/wal.log",
                .entry_count = 0,
            },
        };
    }

    /// Load snapshot and replay WAL. Call once at startup.
    /// Returns number of WAL entries replayed (0 on fresh start).
    pub fn recover(self: *Store, io: Io) u64 {
        // Ensure data directory exists
        Dir.cwd().createDirPath(io, self.data_dir) catch {};

        // Load snapshot (brings store to the last checkpointed state)
        self.loadSnapshot(io);

        // Replay WAL entries written AFTER the last snapshot
        const replayed = self.wal.replay(io, self.allocator, self, &replayCallback) catch 0;
        return replayed;
    }

    /// Called by wal.replay for each valid entry. Applies the op to in-memory state.
    /// Skips Firestore writes (recovery is local-only; Firestore state loaded via loadFromFirestore).
    fn replayCallback(ctx: ?*anyopaque, op: types.WalOp, payload: []const u8) void {
        const self: *Store = @alignCast(@ptrCast(ctx orelse return));
        switch (op) {
            .create_account => {
                // Payload is JSON-serialized account
                const parsed = std.json.parseFromSlice(AccountJson, self.allocator, payload, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch return;
                defer parsed.deinit();
                const a = parsed.value;
                var account = types.Account{};
                account.id = types.FixedStr64.fromSlice(a.id);
                account.email = types.FixedStr256.fromSlice(a.email);
                account.balance_ticks = a.balance_ticks;
                account.role = std.meta.stringToEnum(types.Role, a.role) orelse .user;
                account.tier = std.meta.stringToEnum(types.DevTier, a.tier) orelse .free;
                account.created_at = a.created_at;
                account.updated_at = a.created_at;
                const key_copy = self.allocator.dupe(u8, account.id.slice()) catch return;
                self.accounts.put(self.allocator, key_copy, account) catch return;
            },
            .create_key => {
                const parsed = std.json.parseFromSlice(KeyJson, self.allocator, payload, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch return;
                defer parsed.deinit();
                const k = parsed.value;
                var key = types.ApiKey{};
                if (k.key_hash.len == 64) {
                    _ = std.fmt.hexToBytes(&key.key_hash, k.key_hash) catch return;
                } else return;
                key.account_id = types.FixedStr64.fromSlice(k.account_id);
                key.name = types.FixedStr128.fromSlice(k.name);
                key.prefix = types.FixedStr16.fromSlice(k.prefix);
                key.spent_ticks = k.spent_ticks;
                key.revoked = k.revoked;
                key.created_at = k.created_at;
                key.expires_at = k.expires_at;
                self.keys.put(self.allocator, key.key_hash, key) catch return;
            },
            .update_balance => {
                // Format: "{account_id}:{delta}"
                const colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return;
                const account_id = payload[0..colon];
                const delta = std.fmt.parseInt(i64, payload[colon + 1 ..], 10) catch return;
                if (self.accounts.getPtr(account_id)) |account| {
                    account.balance_ticks += delta;
                }
            },
            .revoke_key => {
                // Payload is hex-encoded key hash
                if (payload.len != 64) return;
                var key_hash: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key_hash, payload) catch return;
                if (self.keys.getPtr(key_hash)) |key| {
                    key.revoked = true;
                }
            },
            .reserve => {
                // Reservations are ephemeral — skip on replay (they would have been
                // committed or rolled back if the server completed the request).
            },
            .commit_reservation, .rollback_reservation => {
                // Balance effects are already captured by update_balance entries.
            },
            .update_key_spend, .update_account => {
                // Not currently written by the store; reserved for future use.
            },
        }
    }

    pub fn setGcpContext(self: *Store, ctx: *gcp_mod.GcpContext) void {
        self.gcp_ctx = ctx;
    }

    /// Load state from Firestore on cold start. Replaces file-based snapshot.
    pub fn loadFromFirestore(self: *Store) void {
        const ctx = self.gcp_ctx orelse return;

        // Load accounts
        const accounts_list = firestore.loadAllAccounts(ctx, self.allocator) catch return;
        defer self.allocator.free(accounts_list);
        for (accounts_list) |account| {
            const key_copy = self.allocator.dupe(u8, account.id.slice()) catch continue;
            self.accounts.put(self.allocator, key_copy, account) catch continue;
        }

        // Load keys
        const keys_list = firestore.loadAllKeys(ctx, self.allocator) catch return;
        defer self.allocator.free(keys_list);
        for (keys_list) |key| {
            self.keys.put(self.allocator, key.key_hash, key) catch continue;
        }

        std.debug.print("  Loaded {d} accounts, {d} keys from Firestore\n", .{
            self.accounts.count(), self.keys.count(),
        });
    }

    /// Flush all dirty account balances to Firestore. Call periodically + on shutdown.
    pub fn flushDirtyAccounts(self: *Store) void {
        const ctx = self.gcp_ctx orelse return;

        self.mutex.lock();
        // Snapshot dirty set + current balances
        var to_flush: std.ArrayListUnmanaged(struct { id: []const u8, balance: i64 }) = .empty;
        defer to_flush.deinit(self.allocator);

        var iter = self.dirty_accounts.iterator();
        while (iter.next()) |entry| {
            if (self.accounts.get(entry.key_ptr.*)) |account| {
                to_flush.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .balance = account.balance_ticks,
                }) catch continue;
            }
        }
        self.dirty_accounts.clearRetainingCapacity();
        self.mutex.unlock();

        // Write outside the lock (no contention with request handling)
        for (to_flush.items) |item| {
            firestore.updateAccountBalance(ctx, item.id, item.balance) catch {};
        }
    }

    pub fn deinit(self: *Store) void {
        // Free duped account ID strings (the keys of the accounts map)
        var acct_iter = self.accounts.iterator();
        while (acct_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.accounts.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.reservations.deinit(self.allocator);
        self.dirty_accounts.deinit(self.allocator);
        // Free the WAL file path allocated in init()
        self.allocator.free(self.wal.file_path);
    }

    // ── Account Operations ──────────────────────────────────

    pub fn createAccount(self: *Store, io: Io, account: types.Account) !void {
        // Phase 1: WAL + in-memory write under the mutex (fast path)
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const payload = try self.serializeAccount(account);
            defer self.allocator.free(payload);
            try self.wal.append(io, .create_account, payload);

            const key_copy = try self.allocator.dupe(u8, account.id.slice());
            try self.accounts.put(self.allocator, key_copy, account);
        }

        // Phase 2: Firestore write OUTSIDE the mutex so other requests
        // aren't blocked during the ~50-100ms network round-trip.
        if (self.gcp_ctx) |ctx| {
            firestore.saveAccount(ctx, account) catch {};
        }
    }

    pub fn getAccount(self: *Store, account_id: []const u8) ?*types.Account {
        // No lock needed for reads if we document that callers hold the lock
        return self.accounts.getPtr(account_id);
    }

    pub fn getAccountLocked(self: *Store, account_id: []const u8) ?types.Account {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.accounts.getPtr(account_id) orelse return null;
        return ptr.*;
    }

    // ── API Key Operations ──────────────────────────────────

    pub fn createKey(self: *Store, io: Io, key: types.ApiKey) !void {
        // Phase 1: WAL + in-memory (fast, under mutex)
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const payload = try self.serializeKey(key);
            defer self.allocator.free(payload);
            try self.wal.append(io, .create_key, payload);

            try self.keys.put(self.allocator, key.key_hash, key);
        }

        // Phase 2: Firestore write outside the mutex (slow, network)
        if (self.gcp_ctx) |ctx| {
            firestore.saveKey(ctx, key) catch {};
        }
    }

    pub fn getKey(self: *Store, key_hash: [32]u8) ?*types.ApiKey {
        return self.keys.getPtr(key_hash);
    }

    pub fn revokeKey(self: *Store, io: Io, key_hash: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.keys.getPtr(key_hash)) |key| {
            key.revoked = true;
            // WAL write with hex-encoded hash
            var hash_hex: [64]u8 = undefined;
            types.hexEncode(&key_hash, &hash_hex);
            self.wal.append(io, .revoke_key, &hash_hex) catch {};

            // Write-through to Firestore (revocation must be durable immediately)
            if (self.gcp_ctx) |ctx| {
                firestore.updateKeyRevoked(ctx, key.*) catch {};
            }
        }
    }

    // ── Billing Operations ──────────────────────────────────

    /// Reserve balance before calling a provider. Returns reservation ID.
    /// FAIL-CLOSED: returns error if balance insufficient or WAL write fails.
    pub fn reserve(self: *Store, io: Io, account_id: []const u8, key_hash: [32]u8, amount_ticks: i64, endpoint: []const u8, model: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const account = self.accounts.getPtr(account_id) orelse return error.AccountNotFound;

        // FAIL-CLOSED: insufficient balance
        if (account.balance_ticks < amount_ticks) return error.InsufficientBalance;

        // Deduct hold
        account.balance_ticks -= amount_ticks;

        const res_id = self.next_reservation_id;
        self.next_reservation_id += 1;

        const reservation = types.Reservation{
            .id = res_id,
            .account_id = types.FixedStr64.fromSlice(account_id),
            .key_hash = key_hash,
            .amount_ticks = amount_ticks,
            .endpoint = types.FixedStr64.fromSlice(endpoint),
            .model = types.FixedStr128.fromSlice(model),
            .created_at = types.nowMs(),
        };

        // WAL write — if this fails, we need to refund
        const payload = try self.serializeReservation(reservation);
        defer self.allocator.free(payload);
        self.wal.append(io, .reserve, payload) catch |err| {
            // Refund on WAL failure (FAIL-CLOSED)
            account.balance_ticks += amount_ticks;
            return err;
        };

        try self.reservations.put(self.allocator, res_id, reservation);

        // Mark account dirty for background Firestore flush
        self.dirty_accounts.put(self.allocator, account_id, {}) catch {};

        return res_id;
    }

    /// Commit a reservation after successful provider call.
    /// Refunds the difference between reserved and actual cost.
    pub fn commitReservation(self: *Store, io: Io, reservation_id: u64, actual_ticks: i64, margin_ticks: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const reservation = self.reservations.get(reservation_id) orelse return error.ReservationNotFound;

        const account = self.accounts.getPtr(reservation.account_id.slice()) orelse return error.AccountNotFound;

        // Settle: refund excess hold, or deduct undercharge
        const total_cost = actual_ticks + margin_ticks;
        const delta = reservation.amount_ticks - total_cost;
        // delta > 0: we reserved too much → refund the excess
        // delta < 0: provider charged more than reserved → deduct the shortfall
        // delta = 0: exact match, no adjustment needed
        account.balance_ticks += delta;

        // Update key spend
        if (self.keys.getPtr(reservation.key_hash)) |key| {
            key.spent_ticks += total_cost;
            key.last_used_at = types.nowMs();
        }

        // WAL write (best-effort on commit — reservation already holds are conservative)
        const seq_buf = std.fmt.allocPrint(self.allocator, "{d}:{d}:{d}", .{ reservation_id, actual_ticks, margin_ticks }) catch "";
        defer if (seq_buf.len > 0) self.allocator.free(seq_buf);
        self.wal.append(io, .commit_reservation, seq_buf) catch {};

        // Mark dirty
        self.dirty_accounts.put(self.allocator, reservation.account_id.slice(), {}) catch {};

        _ = self.reservations.remove(reservation_id);
    }

    /// Rollback a reservation (provider call failed). Full refund.
    pub fn rollbackReservation(self: *Store, io: Io, reservation_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const reservation = self.reservations.get(reservation_id) orelse return;

        if (self.accounts.getPtr(reservation.account_id.slice())) |account| {
            account.balance_ticks += reservation.amount_ticks;
        }

        const seq_buf = std.fmt.allocPrint(self.allocator, "{d}", .{reservation_id}) catch "";
        defer if (seq_buf.len > 0) self.allocator.free(seq_buf);
        self.wal.append(io, .rollback_reservation, seq_buf) catch {};

        _ = self.reservations.remove(reservation_id);
    }

    /// Add credit to an account (admin operation)
    pub fn creditAccount(self: *Store, io: Io, account_id: []const u8, amount_ticks: i64) !void {
        // Phase 1: WAL + in-memory update under mutex, capture new balance
        var new_balance: i64 = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const account = self.accounts.getPtr(account_id) orelse return error.AccountNotFound;
            account.balance_ticks += amount_ticks;
            account.updated_at = types.nowMs();
            new_balance = account.balance_ticks;

            const payload = std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ account_id, amount_ticks }) catch return error.OutOfMemory;
            defer self.allocator.free(payload);
            try self.wal.append(io, .update_balance, payload);
        }

        // Phase 2: Firestore write outside the mutex
        if (self.gcp_ctx) |ctx| {
            firestore.updateAccountBalance(ctx, account_id, new_balance) catch {};
        }
    }

    // ── Snapshot / Recovery ─────────────────────────────────

    pub fn snapshot(self: *Store, io: Io) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"accounts\":[");

        // Serialize accounts
        var first = true;
        var acct_iter = self.accounts.iterator();
        while (acct_iter.next()) |entry| {
            if (!first) try buf.append(self.allocator, ',');
            first = false;
            const json = try self.serializeAccount(entry.value_ptr.*);
            defer self.allocator.free(json);
            try buf.appendSlice(self.allocator, json);
        }

        try buf.appendSlice(self.allocator, "],\"keys\":[");

        // Serialize keys
        first = true;
        var key_iter = self.keys.iterator();
        while (key_iter.next()) |entry| {
            if (!first) try buf.append(self.allocator, ',');
            first = false;
            const json = try self.serializeKey(entry.value_ptr.*);
            defer self.allocator.free(json);
            try buf.appendSlice(self.allocator, json);
        }

        try buf.appendSlice(self.allocator, "]}");

        const path = try std.fmt.allocPrint(self.allocator, "{s}/snapshot.json", .{self.data_dir});
        defer self.allocator.free(path);

        Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = buf.items,
        }) catch |err| return err;

        // Truncate WAL after successful snapshot
        self.wal.truncate(io);
    }

    fn loadSnapshot(self: *Store, io: Io) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/snapshot.json", .{self.data_dir}) catch return;
        defer self.allocator.free(path);

        const data = Dir.cwd().readFileAlloc(io, path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(data);

        // Parse snapshot JSON
        const parsed = std.json.parseFromSlice(SnapshotFormat, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        defer parsed.deinit();

        // Load accounts
        for (parsed.value.accounts) |acct_json| {
            var account = types.Account{};
            account.id = types.FixedStr64.fromSlice(acct_json.id);
            account.email = types.FixedStr256.fromSlice(acct_json.email);
            account.balance_ticks = acct_json.balance_ticks;
            account.role = std.meta.stringToEnum(types.Role, acct_json.role) orelse .user;
            account.tier = std.meta.stringToEnum(types.DevTier, acct_json.tier) orelse .free;
            account.created_at = acct_json.created_at;
            const key_copy = self.allocator.dupe(u8, account.id.slice()) catch continue;
            self.accounts.put(self.allocator, key_copy, account) catch continue;
        }

        // Load keys
        for (parsed.value.keys) |key_json| {
            var key = types.ApiKey{};
            // Decode hex hash
            if (key_json.key_hash.len == 64) {
                _ = std.fmt.hexToBytes(&key.key_hash, key_json.key_hash) catch continue;
            }
            key.account_id = types.FixedStr64.fromSlice(key_json.account_id);
            key.name = types.FixedStr128.fromSlice(key_json.name);
            key.prefix = types.FixedStr16.fromSlice(key_json.prefix);
            key.spent_ticks = key_json.spent_ticks;
            key.revoked = key_json.revoked;
            key.created_at = key_json.created_at;
            key.expires_at = key_json.expires_at;
            if (key_json.spend_cap_ticks) |cap| key.scope.spend_cap_ticks = cap;
            if (key_json.rate_limit_rpm) |rpm| key.scope.rate_limit_rpm = rpm;
            if (key_json.endpoints) |ep| key.scope.endpoints = ep;
            self.keys.put(self.allocator, key.key_hash, key) catch continue;
        }
    }

    // ── Serialization Helpers ───────────────────────────────

    fn serializeAccount(self: *Store, account: types.Account) ![]u8 {
        return std.fmt.allocPrint(self.allocator,
            \\{{"id":"{s}","email":"{s}","balance_ticks":{d},"role":"{s}","tier":"{s}","created_at":{d}}}
        , .{
            account.id.slice(),
            account.email.slice(),
            account.balance_ticks,
            account.role.toString(),
            account.tier.toString(),
            account.created_at,
        });
    }

    fn serializeKey(self: *Store, key: types.ApiKey) ![]u8 {
        var hash_hex: [64]u8 = undefined;
        types.hexEncode(&key.key_hash, &hash_hex);

        return std.fmt.allocPrint(self.allocator,
            \\{{"key_hash":"{s}","account_id":"{s}","name":"{s}","prefix":"{s}","spent_ticks":{d},"revoked":{s},"created_at":{d},"expires_at":{d},"spend_cap_ticks":{d},"rate_limit_rpm":{d},"endpoints":{d}}}
        , .{
            &hash_hex,
            key.account_id.slice(),
            key.name.slice(),
            key.prefix.slice(),
            key.spent_ticks,
            if (key.revoked) "true" else "false",
            key.created_at,
            key.expires_at,
            key.scope.spend_cap_ticks,
            key.scope.rate_limit_rpm,
            key.scope.endpoints,
        });
    }

    fn serializeReservation(self: *Store, res: types.Reservation) ![]u8 {
        return std.fmt.allocPrint(self.allocator,
            \\{{"id":{d},"account_id":"{s}","amount_ticks":{d},"created_at":{d}}}
        , .{ res.id, res.account_id.slice(), res.amount_ticks, res.created_at });
    }
};

// ── Snapshot JSON format ────────────────────────────────────

const SnapshotFormat = struct {
    accounts: []const AccountJson = &.{},
    keys: []const KeyJson = &.{},
};

const AccountJson = struct {
    id: []const u8 = "",
    email: []const u8 = "",
    balance_ticks: i64 = 0,
    role: []const u8 = "user",
    tier: []const u8 = "free",
    created_at: i64 = 0,
};

const KeyJson = struct {
    key_hash: []const u8 = "",
    account_id: []const u8 = "",
    name: []const u8 = "",
    prefix: []const u8 = "",
    spent_ticks: i64 = 0,
    revoked: bool = false,
    created_at: i64 = 0,
    expires_at: i64 = 0,
    spend_cap_ticks: ?i64 = null,
    rate_limit_rpm: ?u32 = null,
    endpoints: ?u64 = null,
};
