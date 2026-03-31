//! zbase58 - Base58 Encoding CLI Tool
//!
//! Usage:
//!   zbase58 encode <data>       Encode data to Base58
//!   zbase58 decode <data>       Decode Base58 string
//!   zbase58 check-encode <data> Encode with Base58Check checksum
//!   zbase58 check-decode <data> Decode and verify Base58Check
//!   zbase58 <data>              Shortcut for encode

const std = @import("std");
const Io = std.Io;
const base58 = @import("base58");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        try stdout.print("zbase58 1.0.0\n", .{});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "encode")) {
        if (args.len < 3) {
            try stderr.print("Error: encode requires data argument\n", .{});
            try stderr.flush();
            return;
        }
        const data = args[2];
        const encoded = try base58.encode(arena, data);
        try stdout.print("{s}\n", .{encoded});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "decode")) {
        if (args.len < 3) {
            try stderr.print("Error: decode requires data argument\n", .{});
            try stderr.flush();
            return;
        }
        const encoded = args[2];
        const decoded = base58.decode(arena, encoded) catch |err| {
            try stderr.print("Error: failed to decode: {}\n", .{err});
            try stderr.flush();
            return;
        };
        try stdout.print("{s}\n", .{decoded});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "check-encode")) {
        if (args.len < 3) {
            try stderr.print("Error: check-encode requires data argument\n", .{});
            try stderr.flush();
            return;
        }
        const data = args[2];
        const encoded = try base58.encodeCheck(arena, data);
        try stdout.print("{s}\n", .{encoded});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command, "check-decode")) {
        if (args.len < 3) {
            try stderr.print("Error: check-decode requires data argument\n", .{});
            try stderr.flush();
            return;
        }
        const encoded = args[2];
        const decoded = base58.decodeCheck(arena, encoded) catch |err| {
            try stderr.print("Error: checksum verification failed: {}\n", .{err});
            try stderr.flush();
            return;
        };
        try stdout.print("{s}\n", .{decoded});
        try stdout.flush();
        return;
    }

    // Default: treat as data to encode
    const data = command;
    const encoded = try base58.encode(arena, data);
    try stdout.print("{s}\n", .{encoded});
    try stdout.flush();
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\zbase58 - Bitcoin-style Base58 Encoding Tool
        \\
        \\Usage: zbase58 [command] [data]
        \\
        \\Commands:
        \\  encode <data>        Encode data to Base58
        \\  decode <data>        Decode Base58 string
        \\  check-encode <data>  Encode with Base58Check (SHA256 checksum)
        \\  check-decode <data>  Decode and verify Base58Check
        \\  <data>               Shortcut for encode command
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -v, --version        Show version
        \\
        \\Examples:
        \\  zbase58 "Hello World"
        \\  zbase58 encode "Bitcoin"
        \\  zbase58 decode "9Ajdvzr"
        \\  zbase58 check-encode "Payment data"
        \\  zbase58 check-decode "KL8n4CoJj6xC61VL5CqQ9gY"
        \\
    );
}
