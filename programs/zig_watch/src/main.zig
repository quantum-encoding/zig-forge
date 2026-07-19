// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-watch: File change watcher
//!
//! Watches a file or directory for changes and runs a command when files change.
//! Uses polling with configurable interval.
//!
//! Usage:
//!   zig-watch <path> [options] -- <command...>

const std = @import("std");
const Watcher = @import("watcher.zig").Watcher;

const Opts = struct {
    watch_path: []const u8,
    extensions: ?[]const []const u8,
    ignore_patterns: ?[]const []const u8,
    interval_ms: u64,
    debounce_ms: u64,
    command: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const io = init.io;

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

    const opts = parseArgs(allocator, args) orelse return;
    defer allocator.free(opts.command);
    defer if (opts.extensions) |exts| allocator.free(exts);
    defer if (opts.ignore_patterns) |patterns| allocator.free(patterns);

    // Init watcher
    var watcher = Watcher.init(allocator, opts.extensions);
    _ = watcher.withIgnorePatterns(opts.ignore_patterns);
    _ = watcher.withDebounce(opts.debounce_ms);
    defer watcher.deinit();

    // Initial scan (silent — establishes baseline)
    watcher.baseline(opts.watch_path) catch {
        std.debug.print("Error: cannot scan '{s}'\n", .{opts.watch_path});
        return;
    };

    std.debug.print("[watching: {s}]", .{opts.watch_path});
    if (opts.extensions) |exts| {
        std.debug.print(" (ext:", .{});
        for (exts) |ext| {
            std.debug.print(" {s}", .{ext});
        }
        std.debug.print(")", .{});
    }
    std.debug.print(" every {d}ms\n", .{opts.interval_ms});

    // Main loop. The interval is milliseconds, so the poll period lands in both
    // fields of the timespec (the old code was seconds-only with `.nsec = 0`,
    // which silently floored every sub-second interval to zero).
    const sleep_req = std.c.timespec{
        .sec = @intCast(opts.interval_ms / std.time.ms_per_s),
        .nsec = @intCast((opts.interval_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };

    while (true) {
        _ = std.c.nanosleep(&sleep_req, null);

        const changed = watcher.scan(opts.watch_path) catch continue;
        defer {
            for (changed) |p| allocator.free(p);
            allocator.free(changed);
        }

        if (changed.len > 0) {
            // Print changed files
            std.debug.print("[changed:", .{});
            const max_show: usize = 5;
            const show = @min(changed.len, max_show);
            for (changed[0..show]) |p| {
                std.debug.print(" {s}", .{p});
            }
            if (changed.len > max_show) {
                std.debug.print(" (+{d} more)", .{changed.len - max_show});
            }
            std.debug.print("]\n", .{});

            // zig-watch's contract is "evaluate a user-supplied shell command
            // when the watched path changes." Shell semantics (pipes,
            // redirects, env expansion) are the feature, so we invoke
            // /bin/sh EXPLICITLY via argv-mode spawn — no libc system(3)
            // backdoor. The operator owns the command string by
            // construction (it's the trailing argv after `--`).
            // zig-lens-ignore: SHELL-CHILD zig-watch's contract is to run user-supplied shell commands; the operator owns the command string via the trailing `-- <cmd>` argv.
            const argv = [_][]const u8{ "/bin/sh", "-c", opts.command };
            var child = std.process.spawn(io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch |err| {
                std.debug.print("[spawn failed: {s}]\n", .{@errorName(err)});
                continue;
            };
            const term = child.wait(io) catch |err| {
                std.debug.print("[wait failed: {s}]\n", .{@errorName(err)});
                continue;
            };
            const exit_code: c_int = switch (term) {
                .exited => |code| @intCast(code),
                else => -1,
            };
            if (exit_code != 0) {
                std.debug.print("[exit code: {d}]\n", .{exit_code});
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ?Opts {
    var watch_path: ?[]const u8 = null;
    var extensions: ?[]const []const u8 = null;
    var ignore_patterns: ?[]const []const u8 = null;
    var interval_ms: u64 = std.time.ms_per_s;
    var debounce_ms: u64 = 0;
    var separator_idx: ?usize = null;

    // Find the -- separator
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--") and i > 0) {
            separator_idx = i;
            break;
        }
    }

    if (separator_idx == null) {
        std.debug.print("Error: missing '--' separator before command\n", .{});
        std.debug.print("Usage: zig-watch <path> [options] -- <command...>\n", .{});
        return null;
    }

    const sep = separator_idx.?;

    // Parse options before --
    var i: usize = 1;
    while (i < sep) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--ext")) {
            i += 1;
            if (i >= sep) {
                std.debug.print("Error: --ext requires a value\n", .{});
                return null;
            }
            extensions = parseExtensions(allocator, args[i]) orelse {
                std.debug.print("Error: invalid --ext value\n", .{});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--ignore")) {
            i += 1;
            if (i >= sep) {
                std.debug.print("Error: --ignore requires a value\n", .{});
                return null;
            }
            ignore_patterns = parseExtensions(allocator, args[i]) orelse {
                std.debug.print("Error: invalid --ignore value\n", .{});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--debounce")) {
            i += 1;
            if (i >= sep) {
                std.debug.print("Error: --debounce requires a value\n", .{});
                return null;
            }
            debounce_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: invalid debounce value '{s}'\n", .{args[i]});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= sep) {
                std.debug.print("Error: --interval requires a value\n", .{});
                return null;
            }
            interval_ms = parseInterval(args[i]) orelse {
                std.debug.print("Error: invalid interval '{s}'\n", .{args[i]});
                return null;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            watch_path = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        }
    }

    if (watch_path == null) {
        std.debug.print("Error: no watch path specified\n", .{});
        return null;
    }

    // Build command from everything after --
    if (sep + 1 >= args.len) {
        std.debug.print("Error: no command specified after '--'\n", .{});
        return null;
    }

    const cmd = buildCommand(allocator, args[sep + 1 ..]) orelse {
        std.debug.print("Error: failed to build command string\n", .{});
        return null;
    };

    return .{
        .watch_path = watch_path.?,
        .extensions = extensions,
        .ignore_patterns = ignore_patterns,
        .interval_ms = interval_ms,
        .debounce_ms = debounce_ms,
        .command = cmd,
    };
}

fn buildCommand(allocator: std.mem.Allocator, parts: []const []const u8) ?[]const u8 {
    if (parts.len == 0) return null;

    // Calculate total length
    var total: usize = 0;
    for (parts, 0..) |part, idx| {
        total += part.len;
        if (idx < parts.len - 1) total += 1; // space
    }

    const buf = allocator.alloc(u8, total) catch return null;
    var pos: usize = 0;
    for (parts, 0..) |part, idx| {
        @memcpy(buf[pos .. pos + part.len], part);
        pos += part.len;
        if (idx < parts.len - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }

    return buf;
}

fn parseExtensions(allocator: std.mem.Allocator, value: []const u8) ?[]const []const u8 {
    // Count commas to know how many extensions
    var count: usize = 1;
    for (value) |c| {
        if (c == ',') count += 1;
    }

    const exts = allocator.alloc([]const u8, count) catch return null;
    var idx: usize = 0;
    var start: usize = 0;
    for (value, 0..) |c, i| {
        if (c == ',') {
            exts[idx] = value[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    exts[idx] = value[start..];

    return exts;
}

/// Parse a poll interval into milliseconds.
///
/// Accepts a sequence of `<digits><unit>` groups (`"90s"`, `"1m30s"`) where the
/// unit is `ms`, `s`, `m`, `h`, or `d`; a trailing group with no unit is read as
/// seconds (`"2"` == `"2s"`). `ms` is a real two-character unit — the previous
/// parser consumed `m` as *minutes* and then choked on the trailing `s`, so
/// `"500ms"` (advertised in `--help`) was rejected outright.
///
/// Every accumulation is overflow-checked: the old `current * 10 + digit` panicked
/// in safe builds on a long digit string.
fn parseInterval(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    var total: u64 = 0;
    var current: u64 = 0;
    var has_digits = false;
    var i: usize = 0;

    while (i < s.len) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            current = std.math.mul(u64, current, 10) catch return null;
            current = std.math.add(u64, current, c - '0') catch return null;
            has_digits = true;
            i += 1;
            continue;
        }

        if (!has_digits) return null;

        // Longest-match unit: "ms" before "m".
        var multiplier: u64 = undefined;
        if (c == 'm' and i + 1 < s.len and s[i + 1] == 's') {
            multiplier = 1;
            i += 2;
        } else {
            multiplier = switch (c) {
                's' => std.time.ms_per_s,
                'm' => std.time.ms_per_min,
                'h' => std.time.ms_per_hour,
                'd' => std.time.ms_per_day,
                else => return null,
            };
            i += 1;
        }

        const scaled = std.math.mul(u64, current, multiplier) catch return null;
        total = std.math.add(u64, total, scaled) catch return null;
        current = 0;
        has_digits = false;
    }

    // A trailing unit-less group means seconds.
    if (has_digits) {
        const scaled = std.math.mul(u64, current, std.time.ms_per_s) catch return null;
        total = std.math.add(u64, total, scaled) catch return null;
    }

    if (total == 0) return null;
    return total;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn printHelp() void {
    const help =
        \\zig-watch - File change watcher
        \\
        \\Usage:
        \\  zig-watch <path> [options] -- <command...>
        \\
        \\Options:
        \\  --ext <exts>        Filter by extensions (comma-separated, e.g. .zig,.json)
        \\  --ignore <patterns> Ignore patterns (comma-separated, e.g. .git,node_modules,*.swp)
        \\  --debounce <ms>     Coalesce a burst of changes into one run (default: 0, off).
        \\                      The first change fires immediately; further changes within
        \\                      the window are coalesced and fire once when it elapses.
        \\  --interval <time>   Poll interval (default: 1s). Units: ms, s, m, h, d —
        \\                      e.g. 500ms, 2s, 1m30s. A bare number means seconds.
        \\  -h, --help          Show this help
        \\
        \\Notes:
        \\  Hidden entries (names starting with '.') are skipped at every depth, as are
        \\  symlinks, which are neither followed nor watched.
        \\
        \\Examples:
        \\  zig-watch src --ext .zig -- zig build test
        \\  zig-watch . --ext .zig,.json --interval 2s -- echo "files changed"
        \\  zig-watch . --ignore .git,node_modules,*.swp -- npm run build
        \\  zig-watch src --debounce 500 -- zig build
        \\
    ;
    std.debug.print("{s}", .{help});
}

// ============================================================
// Tests
// ============================================================
//
// The CLI parsers had no test target at all before this; the `500ms` help-text
// contradiction (advertised, but rejected by parseInterval) survived precisely
// because nothing exercised them.

test "parseInterval: units and combinations" {
    try std.testing.expectEqual(@as(?u64, 1000), parseInterval("1s"));
    try std.testing.expectEqual(@as(?u64, 2000), parseInterval("2s"));
    try std.testing.expectEqual(@as(?u64, 60_000), parseInterval("1m"));
    try std.testing.expectEqual(@as(?u64, 90_000), parseInterval("1m30s"));
    try std.testing.expectEqual(@as(?u64, 3_600_000), parseInterval("1h"));
    try std.testing.expectEqual(@as(?u64, 86_400_000), parseInterval("1d"));
    // A bare number is seconds, preserving the old behaviour.
    try std.testing.expectEqual(@as(?u64, 5000), parseInterval("5"));
    // "ms" is a real unit now: `m` must not be eaten as minutes.
    try std.testing.expectEqual(@as(?u64, 500), parseInterval("500ms"));
    try std.testing.expectEqual(@as(?u64, 1), parseInterval("1ms"));
    try std.testing.expectEqual(@as(?u64, 61_500), parseInterval("1m1s500ms"));
}

test "parseInterval: rejects malformed input instead of overflowing" {
    try std.testing.expectEqual(@as(?u64, null), parseInterval(""));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("s"));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("abc"));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("1x"));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("0"));
    try std.testing.expectEqual(@as(?u64, null), parseInterval("0s"));
    // Overflow used to panic in safe builds (`current * 10 + digit`, unchecked).
    try std.testing.expectEqual(@as(?u64, null), parseInterval("999999999999999999999"));
    // Overflow in the unit multiply, not the digit accumulate.
    try std.testing.expectEqual(@as(?u64, null), parseInterval("18446744073709551615d"));
}

test "parseExtensions splits on commas" {
    const allocator = std.testing.allocator;

    const one = parseExtensions(allocator, ".zig").?;
    defer allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings(".zig", one[0]);

    const many = parseExtensions(allocator, ".zig,.json,.md").?;
    defer allocator.free(many);
    try std.testing.expectEqual(@as(usize, 3), many.len);
    try std.testing.expectEqualStrings(".zig", many[0]);
    try std.testing.expectEqualStrings(".json", many[1]);
    try std.testing.expectEqualStrings(".md", many[2]);

    // A trailing comma yields an empty final element rather than dropping it.
    const trailing = parseExtensions(allocator, ".zig,").?;
    defer allocator.free(trailing);
    try std.testing.expectEqual(@as(usize, 2), trailing.len);
    try std.testing.expectEqualStrings("", trailing[1]);
}

test "buildCommand joins argv with single spaces" {
    const allocator = std.testing.allocator;

    const cmd = buildCommand(allocator, &.{ "zig", "build", "test" }).?;
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings("zig build test", cmd);

    const one = buildCommand(allocator, &.{"make"}).?;
    defer allocator.free(one);
    try std.testing.expectEqualStrings("make", one);

    try std.testing.expect(buildCommand(allocator, &.{}) == null);
}

test "parseArgs: full option set" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{
        "zig-watch",  "src",         "--ext",   ".zig,.json",
        "--ignore",   ".git",        "--interval", "500ms",
        "--debounce", "250",         "--",      "zig",
        "build",      "test",
    };

    const opts = parseArgs(allocator, &argv).?;
    defer allocator.free(opts.command);
    defer if (opts.extensions) |e| allocator.free(e);
    defer if (opts.ignore_patterns) |p| allocator.free(p);

    try std.testing.expectEqualStrings("src", opts.watch_path);
    try std.testing.expectEqual(@as(u64, 500), opts.interval_ms);
    try std.testing.expectEqual(@as(u64, 250), opts.debounce_ms);
    try std.testing.expectEqual(@as(usize, 2), opts.extensions.?.len);
    try std.testing.expectEqualStrings(".json", opts.extensions.?[1]);
    try std.testing.expectEqual(@as(usize, 1), opts.ignore_patterns.?.len);
    try std.testing.expectEqualStrings("zig build test", opts.command);
}

test "parseArgs: interval defaults to 1s when unspecified" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "zig-watch", "src", "--", "make" };

    const opts = parseArgs(allocator, &argv).?;
    defer allocator.free(opts.command);
    try std.testing.expectEqual(@as(u64, 1000), opts.interval_ms);
    try std.testing.expectEqual(@as(u64, 0), opts.debounce_ms);
    try std.testing.expectEqualStrings("make", opts.command);
}

test "parseArgs: rejects a missing separator, path, or command" {
    const allocator = std.testing.allocator;
    // No `--` separator.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src" }) == null);
    // Separator present but no command after it.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src", "--" }) == null);
    // No watch path.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "--", "make" }) == null);
    // Unknown option.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src", "--nope", "--", "make" }) == null);
    // Option value missing before the separator.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src", "--ext", "--", "make" }) == null);
    // Unparseable interval / debounce.
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src", "--interval", "nope", "--", "make" }) == null);
    try std.testing.expect(parseArgs(allocator, &.{ "zig-watch", "src", "--debounce", "nope", "--", "make" }) == null);
}
