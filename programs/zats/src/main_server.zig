//! zats-server — NATS-compatible message broker
//!
//! Usage: zats-server [--port PORT] [--name NAME] [--jetstream]

const std = @import("std");
const zats = @import("zats");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Parse args
    var config = zats.ServerConfig{};
    var enable_jetstream = false;
    var store_dir: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            config.port = std.fmt.parseInt(u16, args[i], 10) catch 4222;
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            config.server_name = args[i];
        } else if (std.mem.eql(u8, arg, "--token") and i + 1 < args.len) {
            i += 1;
            config.auth_token = args[i];
        } else if (std.mem.eql(u8, arg, "--store-dir") and i + 1 < args.len) {
            i += 1;
            store_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--jetstream") or std.mem.eql(u8, arg, "-js")) {
            enable_jetstream = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("zats-server — NATS-compatible message broker\n\n", .{});
            try stdout.print("Usage: zats-server [OPTIONS]\n\n", .{});
            try stdout.print("Options:\n", .{});
            try stdout.print("  --port PORT   Listen port (default: 4222)\n", .{});
            try stdout.print("  --name NAME   Server name (default: zats)\n", .{});
            try stdout.print("  --token TOKEN Auth token\n", .{});
            try stdout.print("  --jetstream   Enable JetStream\n", .{});
            try stdout.print("  --store-dir D JetStream file store directory\n", .{});
            try stdout.print("  -h, --help    Show this help\n", .{});
            try stdout.flush();
            return;
        }
    }

    try stdout.print("\n", .{});
    try stdout.print("  zats v1.0.0 — NATS-Compatible Message Broker\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("  Server name: {s}\n", .{config.server_name});
    try stdout.print("  Listening on: {s}:{d}\n", .{ config.host, config.port });
    try stdout.print("  Max payload: {d} bytes\n", .{config.max_payload});
    try stdout.print("  Auth: {s}\n", .{if (config.auth_token != null) "token" else "none"});
    try stdout.print("  JetStream: {s}\n", .{if (enable_jetstream) "enabled" else "disabled"});
    if (store_dir) |dir| {
        try stdout.print("  Store dir: {s}\n", .{dir});
    }
    try stdout.print("\n", .{});
    try stdout.flush();

    var server = try zats.NatsServer.init(arena, config);
    defer server.deinit();

    if (enable_jetstream) {
        try server.enableJetStream(.{ .store_dir = store_dir });
    }

    try server.listen();

    try stdout.print("  Ready for connections.\n\n", .{});
    try stdout.flush();

    try server.run();
}
