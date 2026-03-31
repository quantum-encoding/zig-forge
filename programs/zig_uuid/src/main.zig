//! zuuid - UUID Generation CLI Tool
//!
//! Usage:
//!   zuuid              Generate a v4 UUID
//!   zuuid v1           Generate a v1 UUID (time-based)
//!   zuuid v4           Generate a v4 UUID (random)
//!   zuuid v7           Generate a v7 UUID (timestamp, sortable)
//!   zuuid -n 10        Generate 10 UUIDs
//!   zuuid -n 10 v7     Generate 10 v7 UUIDs
//!   zuuid parse <uuid> Parse and inspect a UUID

const std = @import("std");
const Io = std.Io;
const uuid = @import("uuid");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    var count: usize = 1;
    var version: enum { v1, v3, v4, v5, v7 } = .v4;
    var parse_mode = false;
    var parse_input: ?[]const u8 = null;
    var v3_v5_namespace: ?uuid.UUID = null;
    var v3_v5_name: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: -n requires a number\n", .{});
                try stdout.flush();
                return;
            }
            count = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "v1")) {
            version = .v1;
        } else if (std.mem.eql(u8, arg, "v3")) {
            version = .v3;
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: v3 requires namespace and name\n", .{});
                try stdout.flush();
                return;
            }
            const ns_arg = args[i];
            v3_v5_namespace = try parseNamespace(ns_arg);
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: v3 requires name argument\n", .{});
                try stdout.flush();
                return;
            }
            v3_v5_name = args[i];
        } else if (std.mem.eql(u8, arg, "v4")) {
            version = .v4;
        } else if (std.mem.eql(u8, arg, "v5")) {
            version = .v5;
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: v5 requires namespace and name\n", .{});
                try stdout.flush();
                return;
            }
            const ns_arg = args[i];
            v3_v5_namespace = try parseNamespace(ns_arg);
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: v5 requires name argument\n", .{});
                try stdout.flush();
                return;
            }
            v3_v5_name = args[i];
        } else if (std.mem.eql(u8, arg, "v7")) {
            version = .v7;
        } else if (std.mem.eql(u8, arg, "parse")) {
            parse_mode = true;
            i += 1;
            if (i >= args.len) {
                try stdout.print("Error: parse requires a UUID string\n", .{});
                try stdout.flush();
                return;
            }
            parse_input = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout);
            try stdout.flush();
            return;
        }
    }

    if (parse_mode) {
        if (parse_input) |input| {
            try parseAndInspect(stdout, input);
        }
        try stdout.flush();
        return;
    }

    // Generate UUIDs
    for (0..count) |_| {
        const id = switch (version) {
            .v1 => uuid.v1(),
            .v3 => blk: {
                if (v3_v5_namespace) |ns| {
                    if (v3_v5_name) |name| {
                        break :blk uuid.v3(ns, name);
                    }
                }
                try stdout.print("Error: v3 namespace or name missing\n", .{});
                try stdout.flush();
                return;
            },
            .v4 => uuid.v4(),
            .v5 => blk: {
                if (v3_v5_namespace) |ns| {
                    if (v3_v5_name) |name| {
                        break :blk uuid.v5(ns, name);
                    }
                }
                try stdout.print("Error: v5 namespace or name missing\n", .{});
                try stdout.flush();
                return;
            },
            .v7 => uuid.v7(),
        };
        try stdout.print("{s}\n", .{id.toString()});
    }
    try stdout.flush();
}

fn parseNamespace(ns_str: []const u8) !uuid.UUID {
    if (std.mem.eql(u8, ns_str, "dns")) {
        return uuid.namespace_dns;
    } else if (std.mem.eql(u8, ns_str, "url")) {
        return uuid.namespace_url;
    } else if (std.mem.eql(u8, ns_str, "oid")) {
        return uuid.namespace_oid;
    } else if (std.mem.eql(u8, ns_str, "x500")) {
        return uuid.namespace_x500;
    } else {
        return try uuid.parse(ns_str);
    }
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\zuuid - UUID Generation Tool
        \\
        \\Usage: zuuid [options] [version]
        \\
        \\Versions:
        \\  v1                    Time-based UUID (with random node)
        \\  v3 <ns> <name>        MD5 hash-based UUID
        \\  v4                    Random UUID (default)
        \\  v5 <ns> <name>        SHA-1 hash-based UUID
        \\  v7                    Unix timestamp UUID (sortable)
        \\
        \\Namespaces (for v3/v5):
        \\  dns                   DNS namespace
        \\  url                   URL namespace
        \\  oid                   ISO OID namespace
        \\  x500                  X.500 DN namespace
        \\  <uuid-string>         Custom UUID as namespace
        \\
        \\Options:
        \\  -n, --count <N>  Generate N UUIDs
        \\  -h, --help       Show this help
        \\
        \\Commands:
        \\  parse <uuid>     Parse and inspect a UUID
        \\
        \\Examples:
        \\  zuuid                       Generate one v4 UUID
        \\  zuuid v7                    Generate one v7 UUID
        \\  zuuid -n 10 v7              Generate 10 v7 UUIDs
        \\  zuuid v3 dns example.com    Generate v3 UUID with DNS namespace
        \\  zuuid v5 url https://example.com  Generate v5 UUID with URL namespace
        \\  zuuid parse 550e8400-e29b-41d4-a716-446655440000
        \\
    );
}

fn parseAndInspect(writer: anytype, input: []const u8) !void {
    const id = uuid.parse(input) catch |err| {
        try writer.print("Error parsing UUID: {}\n", .{err});
        return;
    };

    try writer.print("UUID:      {}\n", .{id});
    try writer.print("Version:   {s}\n", .{@tagName(id.getVersion())});
    try writer.print("Variant:   {s}\n", .{@tagName(id.getVariant())});
    try writer.print("Is Nil:    {}\n", .{id.isNil()});

    if (id.getTimestamp()) |ts| {
        if (id.getVersion() == .v7) {
            const unix_ms = ts / 1_000_000;
            try writer.print("Timestamp: {} ms (Unix epoch)\n", .{unix_ms});
        } else {
            try writer.print("Timestamp: {} (100ns intervals since 1582)\n", .{ts});
        }
    }

    try writer.print("URN:       {s}\n", .{id.toUrn()});
    try writer.print("Bytes:     ", .{});
    for (id.bytes) |b| {
        try writer.print("{x:0>2} ", .{b});
    }
    try writer.print("\n", .{});
}
