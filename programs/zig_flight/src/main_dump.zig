//! zig-flight-dump — Raw X-Plane dataref dumper
//!
//! Subscribes to all known datarefs and prints raw ID:name=value pairs.
//! Useful for debugging and discovering dataref behavior.
//!
//! Usage: zig-flight-dump [--host HOST] [--port PORT]

const std = @import("std");
const Io = std.Io;
const flight = @import("zig-flight");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Parse args
    var host: []const u8 = "localhost";
    var port: u16 = 8086;
    const args = try init.minimal.args.toSlice(arena);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 8086;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print(
                \\zig-flight-dump — X-Plane 12 dataref dumper
                \\
                \\Subscribes to all known datarefs and prints raw updates.
                \\
                \\Usage: zig-flight-dump [OPTIONS]
                \\
                \\Options:
                \\  --host HOST  X-Plane host (default: localhost)
                \\  --port PORT  X-Plane API port (default: 8086)
                \\  -h, --help   Show this help
                \\
            , .{});
            try stdout.flush();
            return;
        }
    }

    try stdout.print("zig-flight-dump — Connecting to {s}:{d}...\n", .{ host, port });
    try stdout.flush();

    var client = flight.XPlaneClient.init(arena, host, port) catch |err| {
        try stderr.print("Error: failed to init client: {any}\n", .{err});
        try stderr.flush();
        return;
    };
    defer client.deinit();

    // Resolve all dataref sets
    var registry = flight.DatarefRegistry.init();
    registry.resolveAll(&client) catch |err| {
        try stderr.print("Error: failed to resolve datarefs: {any}\n", .{err});
        try stderr.print("Is X-Plane 12 running with the Web API enabled on port {d}?\n", .{port});
        try stderr.flush();
        return;
    };

    try stdout.print("Resolved {d} datarefs. Connecting WebSocket...\n", .{registry.count});
    try stdout.flush();

    client.connectWebSocket() catch |err| {
        try stderr.print("Error: WebSocket connect failed: {any}\n", .{err});
        try stderr.flush();
        return;
    };

    registry.subscribeAll(&client) catch |err| {
        try stderr.print("Error: subscribe failed: {any}\n", .{err});
        try stderr.flush();
        return;
    };

    try stdout.print("Streaming raw datarefs (Ctrl+C to stop):\n\n", .{});
    try stdout.flush();

    // Dump loop — print every update with name resolution
    var msg_count: u64 = 0;
    while (client.isConnected()) {
        if (client.poll()) |maybe_batch| {
            if (maybe_batch) |batch| {
                msg_count += 1;
                try stdout.print("--- msg {d} ({d} updates) ---\n", .{ msg_count, batch.count });
                for (0..batch.count) |idx| {
                    const update = batch.updates[idx];
                    const name = registry.lookupName(update.id) orelse "???";
                    try stdout.print("  [{d}] {s} = {d:.6}\n", .{
                        update.id, name, update.value,
                    });
                }
                try stdout.flush();
            }
        } else |_| {
            try stderr.print("Connection lost. Reconnecting...\n", .{});
            try stderr.flush();
            client.reconnect() catch {
                try stderr.print("Reconnect failed. Retrying...\n", .{});
                try stderr.flush();
                continue;
            };
            registry.subscribeAll(&client) catch {};
        }

        // poll() is blocking — X-Plane's 10Hz updates pace us naturally
    }

    try stdout.print("\nDisconnected after {d} messages.\n", .{msg_count});
    try stdout.flush();
}
