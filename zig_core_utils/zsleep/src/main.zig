//! zsleep - Delay for a specified amount of time
//!
//! Compatible with GNU sleep:
//! - NUMBER: seconds to sleep (integer or floating-point, GNU strtod grammar:
//!   decimal, scientific notation `1e3`, hex float `0x10`, leading `+`,
//!   `inf`/`infinity`)
//! - Supports s (seconds), m (minutes), h (hours), d (days) suffixes
//! - Multiple arguments are summed; `inf` makes the total sleep forever
//! - Overflow / huge inputs saturate instead of crashing (matches GNU, which
//!   clamps rather than aborting)

const std = @import("std");
const Io = std.Io;

// Darwin/POSIX nanosleep for sleep functionality
const timespec = extern struct {
    sec: isize,
    nsec: isize,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

const ParsedDuration = union(enum) {
    /// Total nanoseconds (already saturated to u64 range).
    finite: u64,
    /// `inf` / `infinity` — sleep until killed.
    infinite,
};

/// Parse one GNU-`sleep` interval token: a strtod-compatible number followed by
/// an optional single s/m/h/d suffix. Returns null for any token GNU rejects
/// (garbage, NaN, negative, empty). Never panics — the numeric math is done in
/// f64 (as GNU does with `double`) and saturates to the u64 nanosecond range.
fn parseDuration(s: []const u8) ?ParsedDuration {
    if (s.len == 0) return null;

    var num_end: usize = s.len;
    var mult_secs: f64 = 1; // seconds-per-unit

    switch (s[s.len - 1]) {
        's' => num_end = s.len - 1,
        'm' => {
            mult_secs = 60;
            num_end = s.len - 1;
        },
        'h' => {
            mult_secs = 60 * 60;
            num_end = s.len - 1;
        },
        'd' => {
            mult_secs = 24 * 60 * 60;
            num_end = s.len - 1;
        },
        else => {},
    }

    if (num_end == 0) return null; // suffix with no number, e.g. "s"

    const num_str = s[0..num_end];

    // GNU parses the numeric part with strtod: this accepts decimals,
    // scientific notation, hex floats, leading '+', and inf/infinity. Zig's
    // parseFloat implements the same grammar and, unlike a hand-rolled digit
    // loop, errors (rather than overflow-panicking) on out-of-range input.
    const v = std.fmt.parseFloat(f64, num_str) catch return null;

    if (std.math.isNan(v)) return null; // GNU rejects "nan"
    if (v < 0) return null; // GNU rejects negative intervals
    if (std.math.isInf(v)) return .infinite;

    const ns_f = v * mult_secs * 1_000_000_000.0;

    // Saturate to u64 range instead of overflowing (GNU clamps huge values to a
    // very long sleep rather than crashing or wrapping).
    const max_u64_f: f64 = @floatFromInt(std.math.maxInt(u64));
    if (ns_f >= max_u64_f) return .{ .finite = std.math.maxInt(u64) };
    return .{ .finite = @intFromFloat(ns_f) };
}

fn isOption(arg: []const u8) bool {
    return arg.len >= 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-");
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

    // Single left-to-right pass matching GNU getopt(3) semantics:
    //   * options are processed in order, wherever they appear;
    //   * `--help` / `--version` act immediately (before operands are even
    //     validated — GNU prints help for `sleep abc --help`);
    //   * unknown options error out; `--` ends option processing;
    //   * everything else is collected as an operand and validated afterwards.
    var operands: std.ArrayListUnmanaged([]const u8) = .empty;
    defer operands.deinit(allocator);
    var end_of_options = false;

    for (args[1..]) |arg| {
        if (end_of_options) {
            operands.append(allocator, arg) catch std.process.exit(1);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        }
        if (isOption(arg)) {
            if (arg.len >= 2 and arg[1] == '-') {
                std.debug.print("zsleep: unrecognized option '{s}'\n", .{arg});
            } else {
                // Short-option cluster like `-5`; GNU reports the first char.
                std.debug.print("zsleep: invalid option -- '{c}'\n", .{arg[1]});
            }
            std.debug.print("Try 'zsleep --help' for more information.\n", .{});
            std.process.exit(1);
        }
        operands.append(allocator, arg) catch std.process.exit(1);
    }

    if (operands.items.len == 0) {
        std.debug.print("zsleep: missing operand\n", .{});
        std.debug.print("Try 'zsleep --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Validate & sum every operand BEFORE sleeping (GNU rejects a bad token
    // even when an earlier `inf`/valid token precedes it — no partial sleep).
    var total_ns: u64 = 0;
    var infinite = false;
    for (operands.items) |arg| {
        const duration = parseDuration(arg) orelse {
            std.debug.print("zsleep: invalid time interval '{s}'\n", .{arg});
            std.debug.print("Try 'zsleep --help' for more information.\n", .{});
            std.process.exit(1);
        };
        switch (duration) {
            .infinite => infinite = true,
            .finite => |ns| total_ns +|= ns, // saturating add
        }
    }

    if (infinite) sleepForever();
    if (total_ns == 0) return;
    sleepNanos(total_ns);
}

fn sleepNanos(total_ns: u64) void {
    const seconds = total_ns / 1_000_000_000;
    const nanoseconds = total_ns % 1_000_000_000;
    const ts = timespec{
        .sec = @intCast(seconds),
        .nsec = @intCast(nanoseconds),
    };
    _ = nanosleep(&ts, null);
}

fn sleepForever() noreturn {
    // GNU sleeps until a signal terminates the process. Loop over large chunks
    // (a single huge tv_sec can trip EINVAL on some platforms).
    const chunk = timespec{ .sec = 1 << 30, .nsec = 0 }; // ~34 years/chunk
    while (true) {
        _ = nanosleep(&chunk, null);
    }
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
        \\NUMBER may be a decimal (e.g., 0.5 for half a second) and may use
        \\scientific/hex notation. 'inf' sleeps forever.
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

// ---------------------------------------------------------------------------
// Unit tests for parseDuration. Expected values are anchored to documented GNU
// `sleep` behavior (integer or floating-point seconds, s/m/h/d suffixes where
// 1m=60s, 1h=3600s, 1d=86400s; `inf` sleeps forever; garbage/negative/NaN are
// rejected). External binary-diff anchoring lives in src/gnu_parity_test.zig.
// ---------------------------------------------------------------------------

fn expectFinite(s: []const u8, ns: u64) !void {
    const d = parseDuration(s) orelse return error.TestUnexpectedInvalid;
    try std.testing.expectEqual(ParsedDuration{ .finite = ns }, d);
}

test "integer seconds" {
    try expectFinite("5", 5_000_000_000);
    try expectFinite("0", 0);
    try expectFinite("5s", 5_000_000_000);
}

test "suffix scaling" {
    try expectFinite("1m", 60_000_000_000);
    try expectFinite("1h", 3_600_000_000_000);
    try expectFinite("1d", 86_400_000_000_000);
}

test "fractional with suffix does not overflow (regression: 0.5m/0.5h/0.5d)" {
    // Pre-fix these panicked with u64 overflow at the scaling multiply.
    try expectFinite("0.5m", 30_000_000_000); // 30s
    try expectFinite("0.5h", 1_800_000_000_000); // 30min
    try expectFinite("0.5d", 43_200_000_000_000); // 12h
}

test "fractional seconds" {
    try expectFinite("0.5", 500_000_000);
    try expectFinite(".5", 500_000_000);
    try expectFinite("0.1", 100_000_000);
}

test "strtod grammar GNU accepts" {
    try expectFinite("1e3", 1_000_000_000_000); // 1000s
    try expectFinite("0x10", 16_000_000_000); // 16s
    try expectFinite("+5", 5_000_000_000);
}

test "inf / infinity" {
    try std.testing.expectEqual(ParsedDuration.infinite, parseDuration("inf").?);
    try std.testing.expectEqual(ParsedDuration.infinite, parseDuration("infinity").?);
    try std.testing.expectEqual(ParsedDuration.infinite, parseDuration("INF").?);
}

test "huge input saturates instead of crashing (regression)" {
    // Pre-fix: integer digit-loop / multiply panicked (SIGABRT).
    try expectFinite("99999999999999999999999999", std.math.maxInt(u64));
    try expectFinite("999999999999d", std.math.maxInt(u64));
}

test "invalid tokens rejected" {
    try std.testing.expect(parseDuration("") == null);
    try std.testing.expect(parseDuration("abc") == null);
    try std.testing.expect(parseDuration("5x") == null);
    try std.testing.expect(parseDuration("5s5") == null);
    try std.testing.expect(parseDuration("nan") == null);
    try std.testing.expect(parseDuration("-5") == null); // negative
    try std.testing.expect(parseDuration("s") == null);
}
