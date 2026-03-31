//! zats-pub — NATS publisher CLI
//!
//! Usage: zats-pub [--server HOST:PORT] SUBJECT MESSAGE

const std = @import("std");
const zats = @import("zats");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Parse args
    var config = zats.ClientConfig{};
    var subject: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--server") or std.mem.eql(u8, arg, "-s")) and i + 1 < args.len) {
            i += 1;
            const server_str = args[i];
            if (std.mem.indexOf(u8, server_str, ":")) |colon| {
                config.host = server_str[0..colon];
                config.port = std.fmt.parseInt(u16, server_str[colon + 1 ..], 10) catch 4222;
            } else {
                config.host = server_str;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("zats-pub — NATS publisher\n\n", .{});
            try stdout.print("Usage: zats-pub [OPTIONS] SUBJECT MESSAGE\n\n", .{});
            try stdout.print("Options:\n", .{});
            try stdout.print("  -s, --server HOST:PORT  Server address (default: 127.0.0.1:4222)\n", .{});
            try stdout.print("  -h, --help              Show this help\n", .{});
            try stdout.flush();
            return;
        } else if (subject == null) {
            subject = arg;
        } else if (message == null) {
            message = arg;
        }
    }

    const subj = subject orelse {
        try stderr.print("Error: subject required\nUsage: zats-pub SUBJECT MESSAGE\n", .{});
        try stderr.flush();
        return;
    };

    const msg = message orelse {
        try stderr.print("Error: message required\nUsage: zats-pub SUBJECT MESSAGE\n", .{});
        try stderr.flush();
        return;
    };

    var client = try zats.NatsClient.init(arena, config);
    defer client.deinit();

    client.connect() catch |err| {
        try stderr.print("Error: failed to connect to {s}:{d} ({any})\n", .{ config.host, config.port, err });
        try stderr.flush();
        return;
    };

    try client.publish(subj, msg);

    try stdout.print("Published [{s}]: {s}\n", .{ subj, msg });
    try stdout.flush();

    client.close();
}
