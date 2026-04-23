//! Chronos Stamp - macOS Version
//!
//! Standalone timestamping tool for agent actions on macOS.
//! No D-Bus or eBPF required - generates timestamps locally.
//!
//! Usage: chronos-stamp-macos AGENT-ID [ACTION] [DESCRIPTION]
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! License: Dual License - MIT (Non-Commercial) / Commercial License

const std = @import("std");
const posix = std.posix;
const c = std.c;

/// Default path for persistent tick storage
const DEFAULT_TICK_PATH = "/var/lib/chronos/tick.dat";
/// Fallback path if system path not writable
const FALLBACK_TICK_PATH = "/tmp/chronos-tick.dat";

/// Chronos Clock - maintains sovereign timeline with persistent tick counter
const ChronosClock = struct {
    tick: std.atomic.Value(u64),
    tick_path: []const u8,

    pub fn init(tick_path: ?[]const u8) ChronosClock {
        const path = tick_path orelse blk: {
            // Try system path first, fall back to /tmp
            if (std.c.access(DEFAULT_TICK_PATH, std.c.F_OK) == 0) {
                break :blk DEFAULT_TICK_PATH;
            }
            break :blk FALLBACK_TICK_PATH;
        };

        // Load existing tick from file, or start at 0
        const initial_tick = loadTickFromFile(path) catch 0;

        return ChronosClock{
            .tick = std.atomic.Value(u64).init(initial_tick),
            .tick_path = path,
        };
    }

    /// Increment and return next tick (atomic operation)
    pub fn nextTick(self: *ChronosClock) u64 {
        const new_tick = self.tick.fetchAdd(1, .monotonic) + 1;
        // Persist to disk
        self.persistTick(new_tick) catch {};
        return new_tick;
    }

    /// Get current tick without incrementing
    pub fn getTick(self: *const ChronosClock) u64 {
        return self.tick.load(.monotonic);
    }

    fn persistTick(self: *const ChronosClock, tick: u64) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(self.tick_path)) |dir| {
            // Use mkdir -p equivalent
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{dir}) catch return;
            _ = std.c.mkdir(dir_z.ptr, 0o755);
        }

        // Write tick to file atomically (write to temp, then rename)
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrintZ(&path_buf, "{s}.tmp", .{self.tick_path}) catch return;

        const fd = posix.openatZ(c.AT.FDCWD, tmp_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644) catch return;
        defer _ = std.c.close(fd);

        var buf: [20]u8 = undefined;
        const tick_str = std.fmt.bufPrint(&buf, "{d}", .{tick}) catch return;
        _ = c.write(fd, tick_str.ptr, tick_str.len);

        // Rename temp to actual path
        var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf2, "{s}", .{self.tick_path}) catch return;
        _ = std.c.rename(tmp_path.ptr, path_z.ptr);
    }

    fn loadTickFromFile(path: []const u8) !u64 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.InvalidPath;

        const fd = posix.openatZ(c.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
        defer _ = std.c.close(fd);

        var buf: [20]u8 = undefined;
        const n = posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) return 0;

        const tick_str = std.mem.trim(u8, buf[0..n], " \t\n\r");
        return std.fmt.parseInt(u64, tick_str, 10) catch 0;
    }
};

/// Phi Timestamp - composite multi-dimensional identifier
const PhiTimestamp = struct {
    utc_ns: i128,
    agent_id: []const u8,
    tick: u64,

    /// Format as string: UTC::AGENT-ID::TICK-NNNNNNNNNN
    pub fn format(self: PhiTimestamp, buf: []u8) ![]u8 {
        const seconds: i64 = @intCast(@divFloor(self.utc_ns, std.time.ns_per_s));
        const nanoseconds: u64 = @intCast(@mod(self.utc_ns, std.time.ns_per_s));

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return std.fmt.bufPrint(
            buf,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.+{d:0>9}Z::{s}::TICK-{d:0>10}",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                nanoseconds,
                self.agent_id,
                self.tick,
            },
        );
    }
};

/// Get environment variable as slice
fn getEnv(name: [:0]const u8) ?[]const u8 {
    const val = c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

/// Get current UTC time in nanoseconds
fn getUtcNanoseconds() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn main(init: std.process.Init.Minimal) void {
    // Parse args using iterator (zero allocation)
    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next(); // skip program name

    const agent_id = args_iter.next() orelse {
        std.debug.print("Usage: chronos-stamp-macos AGENT-ID [ACTION] [DESCRIPTION]\n", .{});
        std.debug.print("\nGenerates Phi timestamps for agent actions.\n", .{});
        std.debug.print("Format: UTC::AGENT-ID::TICK-N::[SESSION]::[PWD] → ACTION\n", .{});
        return;
    };

    const action = args_iter.next() orelse "";
    const description = args_iter.next() orelse "";

    // Initialize clock and generate timestamp
    var clock = ChronosClock.init(null);
    const tick = clock.nextTick();

    const phi = PhiTimestamp{
        .utc_ns = getUtcNanoseconds(),
        .agent_id = agent_id,
        .tick = tick,
    };

    var timestamp_buf: [256]u8 = undefined;
    const timestamp = phi.format(&timestamp_buf) catch {
        std.debug.print("Error formatting timestamp\n", .{});
        return;
    };

    // Get session context
    const session = getEnv("CLAUDE_PROJECT_DIR") orelse
        getEnv("PROJECT_ROOT") orelse
        "UNKNOWN-SESSION";

    // Get current working directory
    var pwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pwd: []const u8 = if (c.getcwd(&pwd_buf, pwd_buf.len)) |ptr|
        std.mem.sliceTo(ptr, 0)
    else
        "UNKNOWN-PWD";

    // Output the chronos stamp
    if (description.len > 0) {
        std.debug.print("[CHRONOS] {s}::[{s}]::[{s}] → {s} - {s}\n", .{
            timestamp,
            session,
            pwd,
            action,
            description,
        });
    } else if (action.len > 0) {
        std.debug.print("[CHRONOS] {s}::[{s}]::[{s}] → {s}\n", .{
            timestamp,
            session,
            pwd,
            action,
        });
    } else {
        std.debug.print("[CHRONOS] {s}::[{s}]::[{s}]\n", .{
            timestamp,
            session,
            pwd,
        });
    }
}

// Tests
test "ChronosClock increments" {
    var clock = ChronosClock.init("/tmp/chronos-test-tick.dat");
    const t1 = clock.nextTick();
    const t2 = clock.nextTick();
    const t3 = clock.nextTick();
    try std.testing.expect(t2 == t1 + 1);
    try std.testing.expect(t3 == t2 + 1);
}

test "PhiTimestamp format" {
    const phi = PhiTimestamp{
        .utc_ns = 1736800000000000000, // 2025-01-13 roughly
        .agent_id = "claude-code",
        .tick = 42,
    };

    var buf: [256]u8 = undefined;
    const formatted = try phi.format(&buf);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "::claude-code::") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "::TICK-0000000042") != null);
}
