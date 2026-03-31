//! Worker - Brute-Force Swarm Drone
//!
//! Usage: worker [options]
//!   --queen <host>    Queen host (default: 127.0.0.1)
//!   --port <port>     Queen port (default: 7777)
//!   --threads <n>     Worker threads (default: auto)

const std = @import("std");
const posix = std.posix;
const Worker = @import("worker").Worker;
const WorkerConfig = @import("worker").WorkerConfig;
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  🐝 WORKER - Brute-Force Swarm Drone                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Parse args
    var queen_host: []const u8 = "127.0.0.1";
    var queen_port: u16 = protocol.DEFAULT_PORT;
    var num_threads: ?usize = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--queen")) {
            if (args.next()) |host| {
                queen_host = host;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                queen_port = try std.fmt.parseInt(u16, port_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |threads_str| {
                num_threads = try std.fmt.parseInt(usize, threads_str, 10);
            }
        }
    }

    const cpu_count = try std.Thread.getCpuCount();
    const actual_threads = num_threads orelse cpu_count;

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Queen: {s}:{}\n", .{ queen_host, queen_port });
    std.debug.print("  Threads: {} (detected {} cores)\n", .{ actual_threads, cpu_count });
    std.debug.print("\n", .{});

    // Create Worker
    const config = WorkerConfig{
        .queen_host = queen_host,
        .queen_port = queen_port,
        .num_threads = num_threads,
    };

    const worker = try Worker.init(allocator, config);
    defer worker.deinit();

    // Connect to Queen
    std.debug.print("Connecting to Queen...\n", .{});
    try worker.connect();
    std.debug.print("✓ Connected\n", .{});
    std.debug.print("\n", .{});

    // Start worker
    std.debug.print("Starting work loop...\n", .{});
    std.debug.print("\n", .{});

    try worker.start();

    // Final stats
    const final_stats = worker.getStats();
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Final Statistics                                        ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tasks processed: {d:<39}║\n", .{final_stats.tasks_processed});
    std.debug.print("║  Tasks succeeded: {d:<39}║\n", .{final_stats.tasks_succeeded});
    std.debug.print("║  Uptime: {} seconds{s: <38}║\n", .{ final_stats.uptime_secs, "" });
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
