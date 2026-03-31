//! Distributed KV Client CLI
//!
//! Command-line client for interacting with the distributed KV store.
//!
//! Usage:
//!   kv-client --nodes 127.0.0.1:8000,127.0.0.1:8001 get <key>
//!   kv-client --nodes 127.0.0.1:8000 set <key> <value> [--ttl <ms>]
//!   kv-client --nodes 127.0.0.1:8000 delete <key>
//!   kv-client --nodes 127.0.0.1:8000 cas <key> <version> <value>
//!   kv-client --nodes 127.0.0.1:8000 list [prefix] [--limit <n>]

const std = @import("std");
const lib = @import("lib.zig");

const VERSION = "1.0.0";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printHelp();
        return;
    }

    var nodes: []const u8 = "127.0.0.1:8000";
    var command: ?[]const u8 = null;
    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);
    var ttl_ms: ?u64 = null;
    var limit: u32 = 100;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("kv-client {s}\n", .{VERSION});
            return;
        }

        if (std.mem.eql(u8, arg, "--nodes") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --nodes requires a value\n", .{});
                return;
            }
            nodes = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--ttl")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --ttl requires a value\n", .{});
                return;
            }
            ttl_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid TTL value\n", .{});
                return;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --limit requires a value\n", .{});
                return;
            }
            limit = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid limit value\n", .{});
                return;
            };
            continue;
        }

        // First non-option argument is the command
        if (command == null) {
            command = arg;
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    const cmd = command orelse {
        std.debug.print("Error: No command specified\n", .{});
        printHelp();
        return;
    };

    // Parse node addresses
    var node_list = std.ArrayListUnmanaged([]const u8).empty;
    defer node_list.deinit(allocator);

    var iter = std.mem.splitScalar(u8, nodes, ',');
    while (iter.next()) |addr| {
        if (addr.len > 0) {
            try node_list.append(allocator, addr);
        }
    }

    if (node_list.items.len == 0) {
        std.debug.print("Error: No valid node addresses\n", .{});
        return;
    }

    // Create client
    var client = lib.Client.init(allocator, node_list.items) catch |err| {
        std.debug.print("Error: Failed to create client: {}\n", .{err});
        return;
    };
    defer client.deinit();

    // Execute command
    if (std.mem.eql(u8, cmd, "get")) {
        if (cmd_args.items.len < 1) {
            std.debug.print("Error: get requires a key\n", .{});
            return;
        }
        executeGet(&client, cmd_args.items[0]);
    } else if (std.mem.eql(u8, cmd, "set")) {
        if (cmd_args.items.len < 2) {
            std.debug.print("Error: set requires key and value\n", .{});
            return;
        }
        executeSet(&client, cmd_args.items[0], cmd_args.items[1], ttl_ms);
    } else if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "del")) {
        if (cmd_args.items.len < 1) {
            std.debug.print("Error: delete requires a key\n", .{});
            return;
        }
        executeDelete(&client, cmd_args.items[0]);
    } else if (std.mem.eql(u8, cmd, "cas")) {
        if (cmd_args.items.len < 3) {
            std.debug.print("Error: cas requires key, version, and value\n", .{});
            return;
        }
        const version = std.fmt.parseInt(u64, cmd_args.items[1], 10) catch {
            std.debug.print("Error: Invalid version number\n", .{});
            return;
        };
        executeCas(&client, cmd_args.items[0], version, cmd_args.items[2], ttl_ms);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "keys")) {
        const prefix = if (cmd_args.items.len > 0) cmd_args.items[0] else "";
        executeList(allocator, &client, prefix, limit);
    } else if (std.mem.eql(u8, cmd, "exists")) {
        if (cmd_args.items.len < 1) {
            std.debug.print("Error: exists requires a key\n", .{});
            return;
        }
        executeExists(&client, cmd_args.items[0]);
    } else {
        std.debug.print("Error: Unknown command: {s}\n", .{cmd});
        printHelp();
    }
}

fn executeGet(client: *lib.Client, key: []const u8) void {
    var response = client.get(key) catch |err| {
        switch (err) {
            lib.ClientError.KeyNotFound => {
                std.debug.print("(nil)\n", .{});
                return;
            },
            lib.ClientError.NoLeader => {
                std.debug.print("Error: No leader available\n", .{});
                return;
            },
            lib.ClientError.AllNodesFailed => {
                std.debug.print("Error: All nodes unreachable\n", .{});
                return;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return;
            },
        }
    };
    defer response.deinit(client.allocator);

    std.debug.print("{s}\n", .{response.value});
    std.debug.print("(version: {d})\n", .{response.version});
}

fn executeSet(client: *lib.Client, key: []const u8, value: []const u8, ttl_ms: ?u64) void {
    const response = client.set(key, value, ttl_ms) catch |err| {
        switch (err) {
            lib.ClientError.NoLeader => {
                std.debug.print("Error: No leader available\n", .{});
                return;
            },
            lib.ClientError.AllNodesFailed => {
                std.debug.print("Error: All nodes unreachable\n", .{});
                return;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return;
            },
        }
    };

    std.debug.print("OK (version: {d})\n", .{response.version});
}

fn executeDelete(client: *lib.Client, key: []const u8) void {
    const response = client.delete(key) catch |err| {
        switch (err) {
            lib.ClientError.NoLeader => {
                std.debug.print("Error: No leader available\n", .{});
                return;
            },
            lib.ClientError.AllNodesFailed => {
                std.debug.print("Error: All nodes unreachable\n", .{});
                return;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return;
            },
        }
    };

    if (response.deleted) {
        std.debug.print("OK (deleted)\n", .{});
    } else {
        std.debug.print("OK (not found)\n", .{});
    }
}

fn executeCas(client: *lib.Client, key: []const u8, version: u64, value: []const u8, ttl_ms: ?u64) void {
    const response = client.cas(key, version, value, ttl_ms) catch |err| {
        switch (err) {
            lib.ClientError.NoLeader => {
                std.debug.print("Error: No leader available\n", .{});
                return;
            },
            lib.ClientError.AllNodesFailed => {
                std.debug.print("Error: All nodes unreachable\n", .{});
                return;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return;
            },
        }
    };

    if (response.success) {
        std.debug.print("OK (new version: {d})\n", .{response.new_version});
    } else {
        std.debug.print("FAILED (version mismatch)\n", .{});
    }
}

fn executeList(allocator: std.mem.Allocator, client: *lib.Client, prefix: []const u8, limit: u32) void {
    const keys = client.listKeys(prefix, limit) catch |err| {
        switch (err) {
            lib.ClientError.NoLeader => {
                std.debug.print("Error: No leader available\n", .{});
                return;
            },
            lib.ClientError.AllNodesFailed => {
                std.debug.print("Error: All nodes unreachable\n", .{});
                return;
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                return;
            },
        }
    };
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    if (keys.len == 0) {
        std.debug.print("(empty)\n", .{});
        return;
    }

    for (keys, 1..) |key, i| {
        std.debug.print("{d}) {s}\n", .{ i, key });
    }
}

fn executeExists(client: *lib.Client, key: []const u8) void {
    const exists = client.exists(key) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };

    if (exists) {
        std.debug.print("(true)\n", .{});
    } else {
        std.debug.print("(false)\n", .{});
    }
}

fn printHelp() void {
    std.debug.print(
        \\Distributed KV Client v{s}
        \\
        \\Usage: kv-client [OPTIONS] <COMMAND> [ARGS]
        \\
        \\Options:
        \\  --nodes <addrs>    Comma-separated node addresses (default: 127.0.0.1:8000)
        \\  --ttl <ms>         TTL in milliseconds for set/cas commands
        \\  --limit <n>        Maximum keys for list command (default: 100)
        \\  --help             Show this help
        \\  --version          Show version
        \\
        \\Commands:
        \\  get <key>                    Get value by key
        \\  set <key> <value>            Set key-value pair
        \\  delete <key>                 Delete a key
        \\  cas <key> <version> <value>  Compare-and-swap
        \\  list [prefix]                List keys with optional prefix
        \\  exists <key>                 Check if key exists
        \\
        \\Examples:
        \\  kv-client --nodes 127.0.0.1:8000,127.0.0.1:8001 set mykey myvalue
        \\  kv-client --nodes 127.0.0.1:8000 get mykey
        \\  kv-client set mykey myvalue --ttl 60000
        \\  kv-client delete mykey
        \\  kv-client list user:
        \\  kv-client cas mykey 5 newvalue
        \\
    , .{VERSION});
}
