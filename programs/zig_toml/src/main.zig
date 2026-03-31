const std = @import("std");
const zig_toml = @import("zig_toml");
const Allocator = std.mem.Allocator;

/// Custom Timer implementation for Zig 0.16+ compatibility.
/// Uses libc clock_gettime with CLOCK_MONOTONIC for high-resolution timing.
const Timer = struct {
    start_time: std.c.timespec,

    const Self = @This();

    pub fn start() error{}!Self {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return Self{ .start_time = ts };
    }

    pub fn read(self: *Self) u64 {
        var end_time: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &end_time);

        const start_ns: u64 = @as(u64, @intCast(self.start_time.sec)) * 1_000_000_000 + @as(u64, @intCast(self.start_time.nsec));
        const end_ns: u64 = @as(u64, @intCast(end_time.sec)) * 1_000_000_000 + @as(u64, @intCast(end_time.nsec));
        return end_ns - start_ns;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.flush() catch {};
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try stdout.print("Usage: zig_toml_demo <toml_file>\n", .{});
        return;
    }

    const filename = args[1];

    // Read the file
    const cwd_handle = std.Io.Dir.cwd();
    const content = cwd_handle.readFileAlloc(init.io, filename, allocator, std.Io.Limit.limited(1024 * 1024 * 10)) catch |err| {
        try stdout.print("Error reading file '{s}': {}\n", .{ filename, err });
        return;
    };
    defer allocator.free(content);

    try stdout.print("Parsing TOML file: {s}\n", .{filename});
    try stdout.print("File size: {} bytes\n\n", .{content.len});

    var timer = try Timer.start();
    var result = zig_toml.parseToml(allocator, content) catch |err| {
        try stdout.print("Parse error: {}\n", .{err});
        return;
    };
    const elapsed = timer.read();

    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        result.deinit();
    }

    try stdout.print("Parse completed in {} ns\n", .{elapsed});
    try stdout.print("Parsed {} top-level entries\n\n", .{result.count()});

    var iter = result.iterator();
    while (iter.next()) |entry| {
        try stdout.print("Key: {s}\n", .{entry.key_ptr.*});
        try printValue(stdout, entry.value_ptr.*, 2);
        try stdout.print("\n", .{});
    }
}

fn printValue(writer: anytype, value: zig_toml.Value, indent: usize) !void {
    const indent_str = "  ";
    var i: usize = 0;
    var indent_buf: [256]u8 = undefined;
    var total_indent: usize = 0;

    while (i < indent) : (i += 1) {
        @memcpy(indent_buf[total_indent .. total_indent + indent_str.len], indent_str);
        total_indent += indent_str.len;
    }

    switch (value) {
        .string => |s| try writer.print("{s}String: \"{s}\"\n", .{ indent_buf[0..total_indent], s }),
        .integer => |v| try writer.print("{s}Integer: {}\n", .{ indent_buf[0..total_indent], v }),
        .float => |v| try writer.print("{s}Float: {d}\n", .{ indent_buf[0..total_indent], v }),
        .boolean => |v| try writer.print("{s}Boolean: {}\n", .{ indent_buf[0..total_indent], v }),
        .datetime => |v| try writer.print("{s}DateTime: {s}\n", .{ indent_buf[0..total_indent], v }),
        .array => |arr| {
            try writer.print("{s}Array with {} items:\n", .{ indent_buf[0..total_indent], arr.len });
            for (arr) |item| {
                try printValue(writer, item, indent + 1);
            }
        },
        .table => |tbl| {
            try writer.print("{s}Table with {} keys:\n", .{ indent_buf[0..total_indent], tbl.count() });
            var table_iter = tbl.iterator();
            while (table_iter.next()) |entry| {
                try writer.print("{s}{s}: ", .{ indent_buf[0 .. total_indent + 2], entry.key_ptr.* });
                try printValue(writer, entry.value_ptr.*, indent + 1);
            }
        },
    }
}
