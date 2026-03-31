//! zsleep - Delay for a specified amount of time
//!
//! Compatible with GNU sleep:
//! - NUMBER: seconds to sleep
//! - Supports s (seconds), m (minutes), h (hours), d (days) suffixes
//! - Multiple arguments are summed

const std = @import("std");
const Io = std.Io;

// Darwin/POSIX nanosleep for sleep functionality
const timespec = extern struct {
    sec: isize,
    nsec: isize,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    var num_end: usize = s.len;
    var multiplier: u64 = 1_000_000_000; // nanoseconds per second

    // Check for suffix
    const last = s[s.len - 1];
    switch (last) {
        's' => num_end = s.len - 1,
        'm' => {
            multiplier = 60 * 1_000_000_000;
            num_end = s.len - 1;
        },
        'h' => {
            multiplier = 60 * 60 * 1_000_000_000;
            num_end = s.len - 1;
        },
        'd' => {
            multiplier = 24 * 60 * 60 * 1_000_000_000;
            num_end = s.len - 1;
        },
        else => {},
    }

    if (num_end == 0) return null;

    const num_str = s[0..num_end];

    // Check for decimal point
    var integer_part: u64 = 0;
    var fractional_ns: u64 = 0;
    var seen_dot = false;
    var frac_digits: u32 = 0;

    for (num_str) |c| {
        if (c == '.') {
            if (seen_dot) return null; // Multiple dots
            seen_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return null;

        if (seen_dot) {
            // Fractional part - convert to nanoseconds
            if (frac_digits < 9) {
                fractional_ns = fractional_ns * 10 + (c - '0');
                frac_digits += 1;
            }
        } else {
            integer_part = integer_part * 10 + (c - '0');
        }
    }

    // Scale fractional part to nanoseconds
    while (frac_digits < 9) : (frac_digits += 1) {
        fractional_ns *= 10;
    }

    // Apply multiplier to get total nanoseconds
    const integer_ns = integer_part * multiplier;
    const frac_scaled = (fractional_ns * multiplier) / 1_000_000_000;

    return integer_ns + frac_scaled;
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("zsleep: failed to get arguments\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        std.debug.print("zsleep: missing operand\n", .{});
        std.debug.print("Try 'zsleep --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Check for help/version
    if (std.mem.eql(u8, args[1], "--help")) {
        printHelp();
        return;
    } else if (std.mem.eql(u8, args[1], "--version")) {
        printVersion();
        return;
    }

    // Sum all durations
    var total_ns: u64 = 0;
    for (args[1..]) |arg| {
        const duration = parseDuration(arg) orelse {
            std.debug.print("zsleep: invalid time interval '{s}'\n", .{arg});
            std.process.exit(1);
        };
        total_ns += duration;
    }

    if (total_ns == 0) return;

    // Sleep - convert nanoseconds to seconds + remainder
    const seconds = total_ns / 1_000_000_000;
    const nanoseconds = total_ns % 1_000_000_000;
    const ts = timespec{
        .sec = @intCast(seconds),
        .nsec = @intCast(nanoseconds),
    };
    _ = nanosleep(&ts, null);
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zsleep NUMBER[SUFFIX]...
        \\Pause for NUMBER seconds. SUFFIX may be:
        \\  s   seconds (default)
        \\  m   minutes
        \\  h   hours
        \\  d   days
        \\
        \\NUMBER may be a decimal (e.g., 0.5 for half a second).
        \\Multiple arguments are summed together.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
        \\zsleep - High-performance sleep utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zsleep 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}
