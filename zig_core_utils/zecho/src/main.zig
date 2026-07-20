//! zecho - Display a line of text
//!
//! Compatible with GNU echo (coreutils 9.10):
//! - -n: do not output trailing newline
//! - -e: enable interpretation of backslash escapes
//! - -E: disable interpretation of backslash escapes (default)
//! - --help / --version: honored only when the sole argument and
//!   POSIXLY_CORRECT is unset (matches coreutils echo.c argc==2 guard).

const std = @import("std");
const Io = std.Io;

const Config = struct {
    newline: bool = true,
    interpret_escapes: bool = false,
};

/// Result of processing backslash escapes in a single argument.
/// `stop` is set when a `\c` escape is encountered: the caller must emit
/// `bytes`, then stop emitting any further arguments and suppress the
/// trailing newline (GNU echo semantics).
const EscapeResult = struct {
    bytes: []u8,
    stop: bool = false,
};

fn processEscapes(allocator: std.mem.Allocator, input: []const u8) !EscapeResult {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 1;
                },
                'a' => {
                    try result.append(allocator, '\x07'); // alert/bell
                    i += 1;
                },
                'b' => {
                    try result.append(allocator, '\x08'); // backspace
                    i += 1;
                },
                'c' => {
                    // Produce no further output.
                    return .{ .bytes = try allocator.dupe(u8, result.items), .stop = true };
                },
                'e' => {
                    try result.append(allocator, '\x1b'); // escape
                    i += 1;
                },
                'f' => {
                    try result.append(allocator, '\x0c'); // form feed
                    i += 1;
                },
                'n' => {
                    try result.append(allocator, '\n');
                    i += 1;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 1;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 1;
                },
                'v' => {
                    try result.append(allocator, '\x0b'); // vertical tab
                    i += 1;
                },
                '0'...'7' => {
                    // Octal escape. GNU accepts both `\0NNN` (leading zero is a
                    // marker, up to 3 further octal digits) and `\NNN` (first
                    // digit 1-7, up to 3 octal digits total). Values wider than
                    // a byte wrap to the low byte (e.g. \0400 -> 0x00).
                    var val: u16 = 0;
                    var digits: usize = 0;
                    if (input[i] == '0') i += 1; // consume the \0 marker
                    while (i < input.len and digits < 3 and input[i] >= '0' and input[i] <= '7') {
                        val = val * 8 + (input[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    try result.append(allocator, @truncate(val));
                },
                'x' => {
                    // Hex escape \xH or \xHH: 1 or 2 hex digits, greedy.
                    i += 1; // consume the 'x'
                    var val: u8 = 0;
                    var n: usize = 0;
                    while (i < input.len and n < 2) {
                        const d = hexDigit(input[i]) orelse break;
                        val = val * 16 + d;
                        i += 1;
                        n += 1;
                    }
                    if (n == 0) {
                        // No hex digits followed: emit the literal "\x".
                        try result.append(allocator, '\\');
                        try result.append(allocator, 'x');
                    } else {
                        try result.append(allocator, val);
                    }
                },
                else => {
                    // Unknown escape: keep the backslash and the char literal.
                    try result.append(allocator, '\\');
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return .{ .bytes = try allocator.dupe(u8, result.items), .stop = false };
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

const help_text =
    \\Usage: zecho [SHORT-OPTION]... [STRING]...
    \\  or:  zecho LONG-OPTION
    \\Echo the STRING(s) to standard output.
    \\
    \\  -n             do not output the trailing newline
    \\  -e             enable interpretation of backslash escapes
    \\  -E             disable interpretation of backslash escapes (default)
    \\      --help     display this help and exit
    \\      --version  output version information and exit
    \\
    \\If -e is in effect, the following sequences are recognized:
    \\
    \\  \\      backslash
    \\  \a      alert (BEL)
    \\  \b      backspace
    \\  \c      produce no further output
    \\  \e      escape
    \\  \f      form feed
    \\  \n      new line
    \\  \r      carriage return
    \\  \t      horizontal tab
    \\  \v      vertical tab
    \\  \0NNN   byte with octal value NNN (1 to 3 digits)
    \\  \xHH    byte with hexadecimal value HH (1 to 2 digits)
    \\
;

const version_text =
    \\zecho (zig_core_utils) 1.0
    \\GNU echo compatible.
    \\
;

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

    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &buf);

    // GNU echo honors --help/--version only when it is the sole operand
    // and POSIXLY_CORRECT is unset (coreutils echo.c: argc == 2 guard).
    if (args.len == 2 and !posixlyCorrect(init)) {
        if (std.mem.eql(u8, args[1], "--help")) {
            writer.interface.writeAll(help_text) catch {};
            writer.interface.flush() catch {};
            std.process.exit(0);
        }
        if (std.mem.eql(u8, args[1], "--version")) {
            writer.interface.writeAll(version_text) catch {};
            writer.interface.flush() catch {};
            std.process.exit(0);
        }
    }

    var config = Config{};
    var start_idx: usize = 1;

    // Parse options (only at the beginning, before any non-option args).
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

    var first = true;
    var stopped = false;
    for (args[start_idx..]) |arg| {
        if (!first) {
            writer.interface.writeAll(" ") catch {};
        }
        first = false;

        if (config.interpret_escapes) {
            const res = processEscapes(allocator, arg) catch {
                writer.interface.writeAll(arg) catch {};
                continue;
            };
            defer allocator.free(res.bytes);
            writer.interface.writeAll(res.bytes) catch {};
            if (res.stop) {
                // \c: stop all further output and suppress the newline.
                stopped = true;
                break;
            }
        } else {
            writer.interface.writeAll(arg) catch {};
        }
    }

    if (config.newline and !stopped) {
        writer.interface.writeAll("\n") catch {};
    }

    writer.interface.flush() catch {};
}

fn posixlyCorrect(init: std.process.Init) bool {
    // GNU echo suppresses --help/--version handling when POSIXLY_CORRECT is
    // set (to any value); it checks presence via getenv, not the value.
    return init.minimal.environ.containsConstant("POSIXLY_CORRECT");
}
