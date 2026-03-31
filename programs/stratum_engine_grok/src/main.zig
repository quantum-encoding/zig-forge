const std = @import("std");
const client_mod = @import("stratum/client.zig");
const types = @import("stratum/types.zig");
const dispatcher_mod = @import("miner/dispatcher.zig");
const stats_mod = @import("metrics/stats.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using Args.Iterator for Zig 0.16.2187+
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 5) {
        std.debug.print("Usage: {s} <host> <port> <username> <password>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const host = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const username = args[3];
    const password = args[4];

    // Init stats
    var stats = stats_mod.Stats.init(allocator);
    defer stats.deinit();

    // Init client
    var client = try client_mod.Client.init(allocator, host, port);
    defer client.deinit();

    // Subscribe
    try client.subscribe();

    // Authorize
    try client.authorize(username, password);
    // Subscribe
    try client.subscribe();

    // Authorize
    try client.authorize(username, password);

    // Init dispatcher
    var dispatcher = try dispatcher_mod.Dispatcher.init(allocator);
    defer dispatcher.deinit();

    try dispatcher.startMiners();

    // Main loop
    while (true) {
        if (try client.receiveMessage()) |msg| {
            switch (msg) {
                .notification => |notif| {
                    if (std.mem.eql(u8, notif.method, "mining.notify")) {
                        // Parse job
                        const params = notif.params.array.items;
                        var job = types.Job{
                            .id = try allocator.dupe(u8, params[0].string),
                            .prevhash = undefined,
                            .coinbase1 = try allocator.dupe(u8, params[2].string),
                            .coinbase2 = try allocator.dupe(u8, params[3].string),
                            .merkle_branches = try std.ArrayList([32]u8).initCapacity(allocator, 0),
                            .version = @as(u32, @intCast(params[5].integer)),
                            .nbits = @as(u32, @intCast(params[6].integer)),
                            .ntime = @as(u32, @intCast(params[7].integer)),
                            .clean_jobs = params[8].bool,
                        };

                        // Parse prevhash (hex string)
                        _ = try std.fmt.hexToBytes(&job.prevhash, params[1].string);

                        // Actually, mining.notify params: job_id, prevhash, coinbase1, coinbase2, merkle_branches, version, nbits, ntime, clean_jobs
                        _ = try std.fmt.hexToBytes(&job.prevhash, params[1].string);

                        // Merkle branches
                        const branches = params[4].array.items;
                        for (branches) |branch| {
                            var branch_bytes: [32]u8 = undefined;
                            _ = try std.fmt.hexToBytes(&branch_bytes, branch.string);
                            try job.merkle_branches.append(allocator, branch_bytes);
                        }

                        // Distribute job
                        try dispatcher.distributeJob(job);
                    }
                },
                .response => |resp| {
                    if (resp.@"error") |_| {
                        std.debug.print("Error response: {}\n", .{resp});
                    } else {
                        std.debug.print("Response: {}\n", .{resp});
                    }
                },
                else => {},
            }
        }

        // Print stats every 10 seconds
        const uptime = stats.getUptime();
        if (@mod(@as(u64, @intFromFloat(uptime)), 10) == 0) {
            stats.printStats();
        }

        // std.time.sleep(100000000); // 100ms
    }
}