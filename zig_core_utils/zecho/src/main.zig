//! zecho - Display a line of text
//!
//! Compatible with GNU echo:
//! - -n: do not output trailing newline
//! - -e: enable interpretation of backslash escapes
//! - -E: disable interpretation of backslash escapes (default)

const std = @import("std");
const Io = std.Io;

const Config = struct {
    newline: bool = true,
    interpret_escapes: bool = false,
};

fn processEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '\\' => try result.append(allocator, '\\'),
                'a' => try result.append(allocator, '\x07'), // alert/bell
                'b' => try result.append(allocator, '\x08'), // backspace
                'c' => return try allocator.dupe(u8, result.items), // stop output
                'e' => try result.append(allocator, '\x1b'), // escape
                'f' => try result.append(allocator, '\x0c'), // form feed
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                'v' => try result.append(allocator, '\x0b'), // vertical tab
                '0' => {
                    // Octal escape \0nnn
                    var val: u8 = 0;
                    var digits: usize = 0;
                    i += 1;
                    while (i < input.len and digits < 3 and input[i] >= '0' and input[i] <= '7') {
                        val = val * 8 + (input[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    try result.append(allocator, val);
                    continue;
                },
                'x' => {
                    // Hex escape \xHH
                    if (i + 2 < input.len) {
                        const hi = hexDigit(input[i + 1]);
                        const lo = hexDigit(input[i + 2]);
                        if (hi != null and lo != null) {
                            try result.append(allocator, hi.? * 16 + lo.?);
                            i += 3;
                            continue;
                        }
                    }
                    try result.append(allocator, '\\');
                    try result.append(allocator, 'x');
                },
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, input[i]);
                },
            }
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try allocator.dupe(u8, result.items);
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("zecho: failed to get arguments\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    var config = Config{};
    var start_idx: usize = 1;

    // Parse options (only at the beginning, before any non-option args)
    while (start_idx < args.len) {
        const arg = args[start_idx];
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            var all_valid = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'n', 'e', 'E' => {},
                    else => {
                        all_valid = false;
                        break;
                    },
                }
            }
            if (all_valid) {
                for (arg[1..]) |c| {
                    switch (c) {
                        'n' => config.newline = false,
                        'e' => config.interpret_escapes = true,
                        'E' => config.interpret_escapes = false,
                        else => {},
                    }
                }
                start_idx += 1;
                continue;
            }
        }
        break;
    }

    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &buf);

    var first = true;
    for (args[start_idx..]) |arg| {
        if (!first) {
            writer.interface.writeAll(" ") catch {};
        }
        first = false;

        if (config.interpret_escapes) {
            const processed = processEscapes(allocator, arg) catch {
                writer.interface.writeAll(arg) catch {};
                continue;
            };
            defer allocator.free(processed);
            writer.interface.writeAll(processed) catch {};
        } else {
            writer.interface.writeAll(arg) catch {};
        }
    }

    if (config.newline) {
        writer.interface.writeAll("\n") catch {};
    }

    writer.interface.flush() catch {};
}
