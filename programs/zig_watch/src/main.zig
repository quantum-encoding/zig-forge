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

extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;

const Opts = struct {
    watch_path: []const u8,
    extensions: ?[]const []const u8,
    ignore_patterns: ?[]const []const u8,
    interval_secs: u64,
    debounce_ms: u64,
    command: [:0]const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

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
    std.debug.print(" every {d}s\n", .{opts.interval_secs});

    // Main loop
    const sleep_req = std.c.timespec{
        .sec = @intCast(opts.interval_secs),
        .nsec = 0,
    };

    while (true) {
        _ = nanosleep(&sleep_req, null);

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

            // Run command
            const ret = system(opts.command.ptr);
            if (ret != 0) {
                std.debug.print("[exit code: {d}]\n", .{ret});
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ?Opts {
    var watch_path: ?[]const u8 = null;
    var extensions: ?[]const []const u8 = null;
    var ignore_patterns: ?[]const []const u8 = null;
    var interval_secs: u64 = 1;
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
            interval_secs = parseInterval(args[i]) orelse {
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
        .interval_secs = interval_secs,
        .debounce_ms = debounce_ms,
        .command = cmd,
    };
}

fn buildCommand(allocator: std.mem.Allocator, parts: []const []const u8) ?[:0]const u8 {
    if (parts.len == 0) return null;

    // Calculate total length
    var total: usize = 0;
    for (parts, 0..) |part, idx| {
        total += part.len;
        if (idx < parts.len - 1) total += 1; // space
    }

    const buf = allocator.allocSentinel(u8, total, 0) catch return null;
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

    if (has_digits) {
        total += current;
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
        \\  --debounce <ms>     Debounce time in milliseconds (default: 0, no debounce)
        \\  --interval <time>   Poll interval (default: 1s). Supports: 1s, 500ms, 2s, etc.
        \\  -h, --help          Show this help
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
