// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-cron: Lightweight task scheduler
//!
//! Reads a config file with one task per line: `<interval> <command>`.
//! Runs commands on their intervals in a continuous loop.
//!
//! Intervals: 5s, 1m, 30m, 1h, 2h30m, 1d

const std = @import("std");

extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

const SIGTERM = 15;
const SIGINT = 2;

const Task = struct {
    interval_secs: u64,
    command: []const u8,
    command_z: [:0]const u8,
    last_run: c_long,
    failure_count: u32,
    last_exit_code: c_int,
    last_failure_time: c_long,
};

var should_shutdown = std.atomic.Value(bool).init(false);

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    should_shutdown.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Setup signal handlers for graceful shutdown
    _ = signal(SIGTERM, signalHandler);
    _ = signal(SIGINT, signalHandler);

    // Parse command line args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const args = args_list.items;

    if (args.len < 2 or hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printHelp();
        return;
    }

    const config_path = args[1];

    // Read and parse config
    const file_data = readFile(allocator, config_path) orelse {
        std.debug.print("Error: cannot open config file '{s}'\n", .{config_path});
        return;
    };
    defer allocator.free(file_data);

    var tasks: std.ArrayListUnmanaged(Task) = .empty;
    defer {
        for (tasks.items) |t| {
            allocator.free(t.command_z);
        }
        tasks.deinit(allocator);
    }

    // Parse config lines
    var line_start: usize = 0;
    var line_num: usize = 0;
    for (file_data, 0..) |c, i| {
        if (c == '\n' or i == file_data.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            line_num += 1;
            const line = std.mem.trim(u8, file_data[line_start..line_end], &[_]u8{ ' ', '\t', '\r' });
            line_start = i + 1;

            // Skip empty lines and comments
            if (line.len == 0 or line[0] == '#') continue;

            // Find first space separating interval from command
            const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse {
                std.debug.print("Warning: line {d}: no command after interval, skipping\n", .{line_num});
                continue;
            };

            const interval_str = line[0..space_idx];
            const command = std.mem.trim(u8, line[space_idx + 1 ..], &[_]u8{ ' ', '\t' });

            if (command.len == 0) {
                std.debug.print("Warning: line {d}: empty command, skipping\n", .{line_num});
                continue;
            }

            const interval = parseInterval(interval_str) orelse {
                std.debug.print("Warning: line {d}: invalid interval '{s}', skipping\n", .{ line_num, interval_str });
                continue;
            };

            // Create null-terminated command for system()
            const cmd_z = allocator.allocSentinel(u8, command.len, 0) catch continue;
            @memcpy(cmd_z, command);

            try tasks.append(allocator, .{
                .interval_secs = interval,
                .command = command,
                .command_z = cmd_z,
                .last_run = 0,
                .failure_count = 0,
                .last_exit_code = 0,
                .last_failure_time = 0,
            });
        }
    }

    if (tasks.items.len == 0) {
        std.debug.print("Error: no valid tasks found in '{s}'\n", .{config_path});
        return;
    }

    std.debug.print("[zig-cron] loaded {d} task(s) from {s}\n", .{ tasks.items.len, config_path });
    for (tasks.items, 0..) |t, idx| {
        const ival = formatInterval(t.interval_secs);
        std.debug.print("  [{d}] every {s} -> {s}\n", .{ idx + 1, ival.slice(), t.command });
    }

    // Main loop
    const one_sec = std.c.timespec{ .sec = 1, .nsec = 0 };

    while (!should_shutdown.load(.acquire)) {
        const now = time(null);

        for (tasks.items) |*t| {
            if (now - t.last_run >= @as(c_long, @intCast(t.interval_secs))) {
                // Print timestamp
                const day_secs: u64 = @intCast(@mod(now, 86400));
                const hours = day_secs / 3600;
                const minutes = (day_secs % 3600) / 60;
                const seconds = day_secs % 60;
                std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] running: {s}\n", .{ hours, minutes, seconds, t.command });

                const ret = system(t.command_z.ptr);
                if (ret != 0) {
                    std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] exit code: {d}\n", .{ hours, minutes, seconds, ret });
                    t.failure_count += 1;
                    t.last_exit_code = ret;
                    t.last_failure_time = now;
                    std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] task failure #{d}: {s}\n", .{ hours, minutes, seconds, t.failure_count, t.command });
                } else {
                    if (t.failure_count > 0) {
                        std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] task recovered after {d} failure(s)\n", .{ hours, minutes, seconds, t.failure_count });
                        t.failure_count = 0;
                    }
                }

                t.last_run = now;
            }
        }

        _ = nanosleep(&one_sec, null);
    }

    std.debug.print("\n[zig-cron] shutting down gracefully\n", .{});
}

/// Parse an interval string like "5s", "1m", "2h30m", "1d" into seconds.
fn parseInterval(s: []const u8) ?u64 {
    var total: u64 = 0;
    var current: u64 = 0;
    var has_digits = false;

    for (s) |c| {
        if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            has_digits = true;
        } else {
            if (!has_digits) return null;
            const multiplier: u64 = switch (c) {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                'd' => 86400,
                else => return null,
            };
            total += current * multiplier;
            current = 0;
            has_digits = false;
        }
    }

    // Handle bare number (default to seconds)
    if (has_digits) {
        total += current;
    }

    if (total == 0) return null;
    return total;
}

/// Format seconds as a human-readable interval string.
/// Returns a slice into the provided buffer.
fn formatInterval(secs: u64) FormatResult {
    var result: FormatResult = .{ .buf = undefined, .len = 0 };
    var remaining = secs;

    if (remaining >= 86400) {
        const d = remaining / 86400;
        result.len += writeFmt(&result.buf, result.len, d, 'd');
        remaining %= 86400;
    }
    if (remaining >= 3600) {
        const h = remaining / 3600;
        result.len += writeFmt(&result.buf, result.len, h, 'h');
        remaining %= 3600;
    }
    if (remaining >= 60) {
        const m = remaining / 60;
        result.len += writeFmt(&result.buf, result.len, m, 'm');
        remaining %= 60;
    }
    if (remaining > 0 or result.len == 0) {
        result.len += writeFmt(&result.buf, result.len, remaining, 's');
    }

    return result;
}

const FormatResult = struct {
    buf: [32]u8,
    len: usize,

    pub fn slice(self: *const FormatResult) []const u8 {
        return self.buf[0..self.len];
    }
};

fn writeFmt(buf: []u8, pos: usize, value: u64, suffix: u8) usize {
    // Write digits
    var tmp: [20]u8 = undefined;
    var v = value;
    var tmp_len: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        tmp_len = 1;
    } else {
        while (v > 0) : (tmp_len += 1) {
            tmp[tmp_len] = @intCast(v % 10 + '0');
            v /= 10;
        }
    }
    // Reverse and copy
    var written: usize = 0;
    var i: usize = tmp_len;
    while (i > 0) {
        i -= 1;
        buf[pos + written] = tmp[i];
        written += 1;
    }
    buf[pos + written] = suffix;
    return written + 1;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return null;
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const file = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    _ = fseek(file, 0, 2); // SEEK_END
    const size_long = ftell(file);
    if (size_long <= 0) return null;
    const size: usize = @intCast(size_long);
    _ = fseek(file, 0, 0); // SEEK_SET

    const buf = allocator.alloc(u8, size) catch return null;
    const read = std.c.fread(buf.ptr, 1, size, file);
    if (read != size) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn printHelp() void {
    const help =
        \\zig-cron - Lightweight task scheduler
        \\
        \\Usage:
        \\  zig-cron <config_file>
        \\
        \\Config format (one task per line):
        \\  <interval> <command>
        \\
        \\Intervals:
        \\  5s        Every 5 seconds
        \\  1m        Every minute
        \\  30m       Every 30 minutes
        \\  1h        Every hour
        \\  2h30m     Every 2 hours 30 minutes
        \\  1d        Every day
        \\
        \\Config example:
        \\  # Pull latest code every 30 minutes
        \\  30m git pull
        \\
        \\  # Disk space check hourly
        \\  1h df -h >> /tmp/disk.log
        \\
        \\  # Heartbeat every 5 seconds
        \\  5s echo heartbeat
        \\
        \\Options:
        \\  -h, --help    Show this help
        \\
    ;
    std.debug.print("{s}", .{help});
}

// ============================================================
// Tests
// ============================================================

test "parseInterval basic units" {
    try std.testing.expectEqual(@as(?u64, 5), parseInterval("5s"));
    try std.testing.expectEqual(@as(?u64, 60), parseInterval("1m"));
    try std.testing.expectEqual(@as(?u64, 1800), parseInterval("30m"));
    try std.testing.expectEqual(@as(?u64, 3600), parseInterval("1h"));
    try std.testing.expectEqual(@as(?u64, 86400), parseInterval("1d"));
}

test "parseInterval combined" {
    try std.testing.expectEqual(@as(?u64, 9000), parseInterval("2h30m"));
    try std.testing.expectEqual(@as(?u64, 3661), parseInterval("1h1m1s"));
    try std.testing.expectEqual(@as(?u64, 90000), parseInterval("1d1h"));
}

test "parseInterval bare number" {
    try std.testing.expectEqual(@as(?u64, 10), parseInterval("10"));
}

test "parseInterval invalid" {
    try std.testing.expectEqual(@as(?u64, null), parseInterval(""));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("abc"));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("0s"));
}

test "formatInterval basic" {
    var fr = formatInterval(5);
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "5s"));

    fr = formatInterval(60);
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "1m"));

    fr = formatInterval(3600);
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "1h"));

    fr = formatInterval(86400);
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "1d"));
}

test "formatInterval combined" {
    var fr = formatInterval(9000); // 2h30m
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "2h30m"));

    fr = formatInterval(3661); // 1h1m1s
    try std.testing.expect(std.mem.eql(u8, fr.slice(), "1h1m1s"));
}

test "formatInterval roundtrip" {
    const intervals = [_]u64{ 5, 60, 3600, 86400, 90, 3661, 9000 };
    for (intervals) |interval| {
        const formatted = formatInterval(interval);
        const parsed = parseInterval(formatted.slice()).?;
        try std.testing.expectEqual(interval, parsed);
    }
}

test "config file parsing" {
    const allocator = std.testing.allocator;
    const config_content =
        \\# Test config
        \\5s echo test
        \\1m sleep 1
        \\30m git pull
    ;

    // Create temp file
    const temp_path = "/tmp/test_cron_config.txt";
    const temp_path_z = "/tmp/test_cron_config.txt\x00";

    {
        const file = std.c.fopen(@as([*:0]const u8, @ptrCast(temp_path_z.ptr)), "w") orelse {
            return error.CannotOpenFile;
        };
        _ = std.c.fwrite(config_content.ptr, 1, config_content.len, file);
        _ = std.c.fclose(file); // Close/flush before reading
    }

    // Test parsing (simplified version)
    var tasks: std.ArrayListUnmanaged(Task) = .empty;
    defer {
        for (tasks.items) |t| {
            allocator.free(t.command_z);
        }
        tasks.deinit(allocator);
    }

    // Read and parse
    const file_data = readFile(allocator, temp_path) orelse return error.CannotReadFile;
    defer allocator.free(file_data);

    var line_start: usize = 0;
    var line_num: usize = 0;
    for (file_data, 0..) |c, i| {
        if (c == '\n' or i == file_data.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            line_num += 1;
            const line = std.mem.trim(u8, file_data[line_start..line_end], &[_]u8{ ' ', '\t', '\r' });
            line_start = i + 1;

            if (line.len == 0 or line[0] == '#') continue;

            const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const interval_str = line[0..space_idx];
            const command = std.mem.trim(u8, line[space_idx + 1 ..], &[_]u8{ ' ', '\t' });

            if (command.len == 0) continue;

            if (parseInterval(interval_str)) |interval| {
                const cmd_z = try allocator.allocSentinel(u8, command.len, 0);
                @memcpy(cmd_z, command);
                try tasks.append(allocator, .{
                    .interval_secs = interval,
                    .command = command,
                    .command_z = cmd_z,
                    .last_run = 0,
                    .failure_count = 0,
                    .last_exit_code = 0,
                    .last_failure_time = 0,
                });
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 3), tasks.items.len);

    // Cleanup
    _ = std.c.unlink(@as([*:0]const u8, @ptrCast(temp_path_z.ptr)));
}

test "task interval edge cases" {
    // Test "0s" (should be invalid)
    try std.testing.expectEqual(@as(?u64, null), parseInterval("0s"));

    // Test very large value
    const large = parseInterval("365d");
    try std.testing.expect(large != null);
    try std.testing.expectEqual(@as(u64, 31536000), large.?);

    // Test empty string
    try std.testing.expectEqual(@as(?u64, null), parseInterval(""));
}

test "multiple combined intervals" {
    try std.testing.expectEqual(@as(?u64, 93784), parseInterval("1d2h3m4s"));
    try std.testing.expectEqual(@as(?u64, 86461), parseInterval("1d1m1s")); // 86400+60+1
    try std.testing.expectEqual(@as(?u64, 86401), parseInterval("1d1s")); // 86400+1
}
