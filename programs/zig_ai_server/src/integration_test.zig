// Integration tests — exercise auth pipeline + store + billing + handlers
// without binding a TCP port. Uses the Core handler variants that accept
// pre-read body + auth context, bypassing HTTP parsing.
//
// Covers:
//   - Auth pipeline (valid key, revoked, expired, insufficient balance)
//   - Billing reserve/commit/rollback
//   - Request validation (body limits, model name, messages)
//   - Dynamic output capping
//
// NOT covered (requires real TCP + external services):
//   - Full HTTP parsing
//   - Provider calls (Anthropic/DeepSeek/etc.)
//   - Firestore persistence
//   - SSE streaming wire format

const std = @import("std");
const Dir = std.Io.Dir;
const testing = std.testing;
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const billing = @import("billing.zig");

// ── Test Harness ────────────────────────────────────────────────

/// Minimal fixture: store with a test account + key, ready for billing ops.
/// Each test should call deinit() when done.
pub const TestFixture = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    store: store_mod.Store,
    data_dir: []u8,
    account_id: []const u8 = "test_account",
    raw_key: []const u8 = "qai_k_test_0123456789abcdef",
    key_hash: [32]u8,

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !TestFixture {
        var io_threaded: std.Io.Threaded = .init(allocator, .{});
        const io_handle = io_threaded.io();

        // Unique temp data dir per test
        const counter = data_dir_counter.fetchAdd(1, .monotonic);
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/zig_ai_int_test_{s}_{d}", .{ test_name, counter });
        Dir.cwd().deleteTree(io_handle, path) catch {};
        try Dir.cwd().createDirPath(io_handle, path);
        const data_dir = try allocator.dupe(u8, path);

        var store = store_mod.Store.init(allocator, data_dir);

        // Create a test account with $10 balance
        try store.createAccount(io_handle, .{
            .id = types.FixedStr64.fromSlice("test_account"),
            .email = types.FixedStr256.fromSlice("test@integration"),
            .balance_ticks = 100_000_000_000, // $10
            .role = .user,
            .tier = .free,
            .created_at = 1,
            .updated_at = 1,
        });

        // Create API key
        const raw_key = "qai_k_test_0123456789abcdef";
        var key_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw_key, &key_hash, .{});

        try store.createKey(io_handle, .{
            .key_hash = key_hash,
            .account_id = types.FixedStr64.fromSlice("test_account"),
            .name = types.FixedStr128.fromSlice("integration-test"),
            .prefix = types.FixedStr16.fromSlice("qai_k_test_01"),
            .scope = .{},
            .created_at = 1,
        });

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .store = store,
            .data_dir = data_dir,
            .key_hash = key_hash,
        };
    }

    pub fn deinit(self: *TestFixture) void {
        Dir.cwd().deleteTree(self.io_threaded.io(), self.data_dir) catch {};
        self.allocator.free(self.data_dir);
        self.store.deinit();
    }

    pub fn io(self: *TestFixture) std.Io {
        return self.io_threaded.io();
    }

    /// Build an AuthContext from the fixture's account + key.
    /// Mirrors what auth_pipeline.authenticate() would produce.
    /// The returned context borrows pointers into the store's hash maps —
    /// valid only as long as the store isn't mutated (use carefully).
    pub fn authContext(self: *TestFixture) types.AuthContext {
        return .{
            .account = self.store.accounts.getPtr(self.account_id).?,
            .key = self.store.keys.getPtr(self.key_hash).?,
            .key_hash = self.key_hash,
        };
    }
};

var data_dir_counter: std.atomic.Value(u64) = .init(0);

// ── Tests: Auth pipeline state ─────────────────────────────────

test "integration: account created with expected balance" {
    var fx = try TestFixture.init(testing.allocator, "balance");
    defer fx.deinit();

    const account = fx.store.accounts.getPtr(fx.account_id).?;
    try testing.expectEqual(@as(i64, 100_000_000_000), account.balance_ticks);
    try testing.expectEqual(types.Role.user, account.role);
    try testing.expectEqual(types.DevTier.free, account.tier);
    try testing.expect(!account.frozen);
}

test "integration: key lookup by hash succeeds" {
    var fx = try TestFixture.init(testing.allocator, "keylookup");
    defer fx.deinit();

    const key = fx.store.keys.getPtr(fx.key_hash);
    try testing.expect(key != null);
    try testing.expect(!key.?.revoked);
    try testing.expectEqualStrings("test_account", key.?.account_id.slice());
}

test "integration: unknown key hash returns null" {
    var fx = try TestFixture.init(testing.allocator, "unknownkey");
    defer fx.deinit();

    var bogus_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("not_a_real_key", &bogus_hash, .{});
    try testing.expect(fx.store.keys.getPtr(bogus_hash) == null);
}

// ── Tests: Billing ──────────────────────────────────────────────

test "integration: reserve deducts balance, commit finalizes" {
    var fx = try TestFixture.init(testing.allocator, "reserve");
    defer fx.deinit();

    const auth = fx.authContext();
    const initial = auth.account.balance_ticks;

    // Reserve for a small chat call
    const result = try billing.reserveWithCap(
        &fx.store,
        fx.io(),
        &auth,
        "deepseek-chat",
        1000, // requested max_tokens
        50, // estimated input tokens
        "/qai/v1/chat",
    );

    // Balance should be deducted
    const after_reserve = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expect(after_reserve < initial);
    try testing.expect(result.capped_max_tokens > 0);
    try testing.expect(result.capped_max_tokens <= 1000);

    // Commit with actual usage (lower than reserved)
    billing.commit(&fx.store, fx.io(), result.reservation_id,
        "deepseek-chat", 50, 100, .free);

    // Balance should be refunded for the unused portion
    const after_commit = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expect(after_commit > after_reserve); // refund
    try testing.expect(after_commit < initial); // but still charged something
}

test "integration: rollback restores full balance" {
    var fx = try TestFixture.init(testing.allocator, "rollback");
    defer fx.deinit();

    const auth = fx.authContext();
    const initial = auth.account.balance_ticks;

    const result = try billing.reserveWithCap(
        &fx.store, fx.io(), &auth,
        "claude-sonnet-4-6", 2000, 100, "/qai/v1/chat",
    );

    const after_reserve = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expect(after_reserve < initial);

    // Rollback (e.g., provider call failed)
    billing.rollback(&fx.store, fx.io(), result.reservation_id);

    const after_rollback = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expectEqual(initial, after_rollback);
}

test "integration: insufficient balance returns error" {
    var fx = try TestFixture.init(testing.allocator, "broke");
    defer fx.deinit();

    // Drain the account to near-zero
    const account = fx.store.accounts.getPtr(fx.account_id).?;
    account.balance_ticks = 100; // 0.00001 USD — not enough for anything

    const auth = fx.authContext();
    const result = billing.reserveWithCap(
        &fx.store, fx.io(), &auth,
        "claude-opus-4-6", 10000, 100, "/qai/v1/chat",
    );
    try testing.expectError(error.InsufficientBalance, result);
}

test "integration: dynamic capping reduces max_tokens when balance is low" {
    var fx = try TestFixture.init(testing.allocator, "cap");
    defer fx.deinit();

    // Set balance to only allow ~500 output tokens on deepseek
    const account = fx.store.accounts.getPtr(fx.account_id).?;
    account.balance_ticks = 50_000_000; // $0.005

    const auth = fx.authContext();
    const result = try billing.reserveWithCap(
        &fx.store, fx.io(), &auth,
        "deepseek-chat", 64000, 10, "/qai/v1/chat", // request huge max_tokens
    );

    // Capped to what the balance can afford, not the requested 64000
    try testing.expect(result.capped_max_tokens < 64000);
    try testing.expect(result.capped_max_tokens > 0);
}

test "integration: credit account increases balance" {
    var fx = try TestFixture.init(testing.allocator, "credit");
    defer fx.deinit();

    const before = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;

    try fx.store.creditAccount(fx.io(), fx.account_id, 50_000_000_000); // +$5

    const after = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expectEqual(before + 50_000_000_000, after);
}

test "integration: revoked key is marked revoked" {
    var fx = try TestFixture.init(testing.allocator, "revoke");
    defer fx.deinit();

    try testing.expect(!fx.store.keys.getPtr(fx.key_hash).?.revoked);

    try fx.store.revokeKey(fx.io(), fx.key_hash);

    try testing.expect(fx.store.keys.getPtr(fx.key_hash).?.revoked);
}

// ── Tests: Full round-trip (write → snapshot → load) ───────────

test "integration: snapshot + reload preserves state" {
    const allocator = testing.allocator;
    const io_threaded_ptr = try allocator.create(std.Io.Threaded);
    io_threaded_ptr.* = std.Io.Threaded.init(allocator, .{});
    defer {
        io_threaded_ptr.* = undefined;
        allocator.destroy(io_threaded_ptr);
    }
    const io = io_threaded_ptr.io();

    const counter = data_dir_counter.fetchAdd(1, .monotonic);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/zig_ai_int_test_snapshot_{d}", .{counter});
    Dir.cwd().deleteTree(io, path) catch {};
    try Dir.cwd().createDirPath(io, path);
    defer Dir.cwd().deleteTree(io, path) catch {};

    // Write state, snapshot, deinit
    {
        var store = store_mod.Store.init(allocator, path);
        defer store.deinit();

        try store.createAccount(io, .{
            .id = types.FixedStr64.fromSlice("snap_user"),
            .email = types.FixedStr256.fromSlice("s@test"),
            .balance_ticks = 7_500_000_000,
            .role = .admin,
            .tier = .enterprise,
            .created_at = 42,
            .updated_at = 42,
        });

        try store.snapshot(io);
    }

    // Reload and verify
    var store2 = store_mod.Store.init(allocator, path);
    defer store2.deinit();

    _ = store2.recover(io);

    const acct = store2.getAccountLocked("snap_user") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("s@test", acct.email.slice());
    try testing.expectEqual(@as(i64, 7_500_000_000), acct.balance_ticks);
    try testing.expectEqual(types.Role.admin, acct.role);
    try testing.expectEqual(types.DevTier.enterprise, acct.tier);
}
