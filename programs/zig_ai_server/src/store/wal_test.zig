// WAL replay integration tests
// Exercises the full write → crash → replay → verify cycle.

const std = @import("std");
const Dir = std.Io.Dir;
const testing = std.testing;
const store_mod = @import("store.zig");
const types = @import("types.zig");

// Each test uses a unique data dir under /tmp to avoid collisions.
var test_counter: std.atomic.Value(u64) = .init(0);

fn uniqueDataDir(io: std.Io, name: []const u8) ![]u8 {
    const n = test_counter.fetchAdd(1, .monotonic);
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/zig_ai_wal_test_{s}_{d}", .{ name, n });
    Dir.cwd().deleteTree(io, path) catch {};
    try Dir.cwd().createDirPath(io, path);
    return try std.heap.c_allocator.dupe(u8, path);
}

fn cleanup(io: std.Io, path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch {};
    std.heap.c_allocator.free(path);
}

test "WAL replay: account survives restart" {
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = io_threaded.io();
    const data_dir = try uniqueDataDir(io, "account");
    defer cleanup(io, data_dir);

    // Phase 1: Create store, write an account, "crash" by dropping the store
    {
        var store = store_mod.Store.init(std.heap.c_allocator, data_dir);
        defer store.deinit();

        try store.createAccount(io, .{
            .id = types.FixedStr64.fromSlice("test_user_1"),
            .email = types.FixedStr256.fromSlice("test@example.com"),
            .balance_ticks = 50_000_000_000,
            .role = .user,
            .tier = .pro,
            .created_at = 1000,
            .updated_at = 1000,
        });
    } // store goes out of scope — simulates crash

    // Phase 2: Fresh store, same data dir, recover from WAL
    var store2 = store_mod.Store.init(std.heap.c_allocator, data_dir);
    defer store2.deinit();

    const replayed = store2.recover(io);
    try testing.expect(replayed >= 1);

    // Verify the account is restored
    const acct = store2.getAccountLocked("test_user_1") orelse {
        std.debug.print("FAIL: account not restored from WAL\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("test@example.com", acct.email.slice());
    try testing.expectEqual(@as(i64, 50_000_000_000), acct.balance_ticks);
    try testing.expectEqual(types.Role.user, acct.role);
    try testing.expectEqual(types.DevTier.pro, acct.tier);
}

test "WAL replay: multiple accounts + keys" {
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = io_threaded.io();
    const data_dir = try uniqueDataDir(io, "multi");
    defer cleanup(io, data_dir);

    {
        var store = store_mod.Store.init(std.heap.c_allocator, data_dir);
        defer store.deinit();

        try store.createAccount(io, .{
            .id = types.FixedStr64.fromSlice("alice"),
            .email = types.FixedStr256.fromSlice("alice@test"),
            .balance_ticks = 10_000_000_000,
            .role = .user,
            .tier = .free,
            .created_at = 100,
            .updated_at = 100,
        });
        try store.createAccount(io, .{
            .id = types.FixedStr64.fromSlice("bob"),
            .email = types.FixedStr256.fromSlice("bob@test"),
            .balance_ticks = 20_000_000_000,
            .role = .admin,
            .tier = .enterprise,
            .created_at = 200,
            .updated_at = 200,
        });

        var key_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("alice_key_raw", &key_hash, .{});
        try store.createKey(io, .{
            .key_hash = key_hash,
            .account_id = types.FixedStr64.fromSlice("alice"),
            .name = types.FixedStr128.fromSlice("alice-laptop"),
            .prefix = types.FixedStr16.fromSlice("qai_k_abc"),
            .scope = .{},
            .created_at = 150,
        });
    }

    // Recover
    var store2 = store_mod.Store.init(std.heap.c_allocator, data_dir);
    defer store2.deinit();
    const replayed = store2.recover(io);
    try testing.expectEqual(@as(u64, 3), replayed); // 2 accounts + 1 key

    // Both accounts present
    try testing.expect(store2.getAccountLocked("alice") != null);
    try testing.expect(store2.getAccountLocked("bob") != null);

    const alice = store2.getAccountLocked("alice").?;
    try testing.expectEqual(types.DevTier.free, alice.tier);
    try testing.expectEqual(@as(i64, 10_000_000_000), alice.balance_ticks);

    const bob = store2.getAccountLocked("bob").?;
    try testing.expectEqual(types.Role.admin, bob.role);
    try testing.expectEqual(types.DevTier.enterprise, bob.tier);

    // Key is present
    var alice_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("alice_key_raw", &alice_hash, .{});
    try testing.expect(store2.keys.get(alice_hash) != null);
}

test "WAL replay: empty WAL returns 0 entries" {
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = io_threaded.io();
    const data_dir = try uniqueDataDir(io, "empty");
    defer cleanup(io, data_dir);

    var store = store_mod.Store.init(std.heap.c_allocator, data_dir);
    defer store.deinit();

    const replayed = store.recover(io);
    try testing.expectEqual(@as(u64, 0), replayed);
    try testing.expectEqual(@as(usize, 0), store.accounts.count());
}

test "WAL replay: corrupted entry stops replay" {
    var io_threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = io_threaded.io();
    const data_dir = try uniqueDataDir(io, "corrupt");
    defer cleanup(io, data_dir);

    {
        var store = store_mod.Store.init(std.heap.c_allocator, data_dir);
        defer store.deinit();

        try store.createAccount(io, .{
            .id = types.FixedStr64.fromSlice("first"),
            .email = types.FixedStr256.fromSlice("f@test"),
            .balance_ticks = 1000,
            .role = .user,
            .tier = .free,
            .created_at = 1,
            .updated_at = 1,
        });
    }

    // Corrupt the WAL by appending a bogus header + payload.
    // Read existing WAL, append garbage, write back.
    var wal_path_buf: [256]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}/wal.log", .{data_dir});

    const existing = Dir.cwd().readFileAlloc(io, wal_path, std.heap.c_allocator, .unlimited) catch "";
    defer if (existing.len > 0) std.heap.c_allocator.free(existing);

    var corrupted: std.ArrayListUnmanaged(u8) = .empty;
    defer corrupted.deinit(std.heap.c_allocator);
    try corrupted.appendSlice(std.heap.c_allocator, existing);

    // Append a WAL entry with header claiming payload_len=16 but bad CRC
    // [op=0x01][len=16 LE][crc=0xDEADBEEF LE][16 zero bytes]
    const bad_header = [_]u8{ 0x01, 0x10, 0x00, 0x00, 0x00, 0xEF, 0xBE, 0xAD, 0xDE };
    try corrupted.appendSlice(std.heap.c_allocator, &bad_header);
    try corrupted.appendSlice(std.heap.c_allocator, &([_]u8{0x00} ** 16));

    try Dir.cwd().writeFile(io, .{ .sub_path = wal_path, .data = corrupted.items });

    // Recovery should succeed at entry 1, stop at corrupted entry 2
    var store2 = store_mod.Store.init(std.heap.c_allocator, data_dir);
    defer store2.deinit();

    const replayed = store2.recover(io);
    try testing.expectEqual(@as(u64, 1), replayed);
    try testing.expect(store2.getAccountLocked("first") != null);
}
