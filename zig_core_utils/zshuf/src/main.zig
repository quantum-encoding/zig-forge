//! zshuf - Shuffle lines of text
//!
//! A Zig implementation of shuf.
//! Generate random permutations of input lines.
//!
//! Usage: zshuf [OPTIONS] [FILE]
//!        zshuf -e [OPTIONS] [ARG]...
//!        zshuf -i LO-HI [OPTIONS]

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn arc4random() u32;

const Range = struct { lo: i64, hi: i64 };

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn writeFd(fd: c_int, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(fd, data.ptr + written, data.len - written);
        if (result <= 0) break;
        written += @intCast(result);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Options
    var echo_mode = false;
    var input_range: ?Range = null;
    var head_count: ?usize = null;
    var repeat_mode = false;
    var zero_terminated = false;
    var output_file: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var extra_operand: ?[]const u8 = null;
    var echo_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer echo_args.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zshuf {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--echo")) {
            echo_mode = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--repeat")) {
            repeat_mode = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero-terminated")) {
            zero_terminated = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--head-count")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zshuf: option requires an argument -- 'n'\n", .{});
                std.process.exit(1);
            }
            head_count = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zshuf: invalid line count: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--head-count=")) {
            const val = arg[13..];
            head_count = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zshuf: invalid line count: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zshuf: option requires an argument -- 'o'\n", .{});
                std.process.exit(1);
            }
            output_file = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_file = arg[9..];
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input-range")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zshuf: option requires an argument -- 'i'\n", .{});
                std.process.exit(1);
            }
            input_range = parseRange(args[i]) orelse {
                writeStderr("zshuf: invalid input range: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--input-range=")) {
            const val = arg[14..];
            input_range = parseRange(val) orelse {
                writeStderr("zshuf: invalid input range: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'e' => echo_mode = true,
                    'r' => repeat_mode = true,
                    'z' => zero_terminated = true,
                    'n' => {
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            head_count = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zshuf: invalid line count: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zshuf: option requires an argument -- 'n'\n", .{});
                                std.process.exit(1);
                            }
                            head_count = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zshuf: invalid line count: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'o' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("zshuf: option requires an argument -- 'o'\n", .{});
                            std.process.exit(1);
                        }
                        output_file = args[i];
                        break;
                    },
                    'i' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("zshuf: option requires an argument -- 'i'\n", .{});
                            std.process.exit(1);
                        }
                        input_range = parseRange(args[i]) orelse {
                            writeStderr("zshuf: invalid input range: '{s}'\n", .{args[i]});
                            std.process.exit(1);
                        };
                        break;
                    },
                    else => {
                        writeStderr("zshuf: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                if (echo_mode) {
                    try echo_args.append(allocator, args[i]);
                } else if (input_file == null) {
                    input_file = args[i];
                } else {
                    extra_operand = args[i];
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            if (echo_mode) {
                try echo_args.append(allocator, arg);
            } else if (input_file == null) {
                input_file = arg;
            } else {
                extra_operand = arg;
            }
        } else if (std.mem.eql(u8, arg, "-")) {
            // A bare `-` is a literal input line in echo mode; otherwise it is
            // the stdin filename.
            if (echo_mode) {
                try echo_args.append(allocator, arg);
            } else if (input_file == null) {
                input_file = "-";
            } else {
                extra_operand = arg;
            }
        } else {
            writeStderr("zshuf: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Validate options
    if (echo_mode and input_range != null) {
        writeStderr("zshuf: cannot combine -e and -i options\n", .{});
        std.process.exit(1);
    }

    if (repeat_mode and head_count == null) {
        writeStderr("zshuf: --repeat requires --head-count\n", .{});
        std.process.exit(1);
    }

    // A file operand alongside -i is an extra operand (the range is the input,
    // not the file). GNU: `shuf -i 1-3 somefile` → "extra operand", rc 1.
    if (input_range != null and input_file != null) {
        extra_operand = input_file;
    }
    if (extra_operand) |op| {
        writeStderr("zshuf: extra operand '{s}'\n", .{op});
        writeStderr("Try 'zshuf --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Open output file if specified. std.posix.open computes the correct
    // O_CREAT/O_TRUNC constants per-platform (Darwin and Linux differ), so the
    // file is always truncated — otherwise a shorter new output leaves stale
    // trailing bytes from the previous contents.
    var out_fd: std.posix.fd_t = 1; // stdout
    if (output_file) |of| {
        out_fd = std.posix.openat(std.posix.AT.FDCWD, of, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch {
            writeStderr("zshuf: cannot create '{s}'\n", .{of});
            std.process.exit(1);
        };
    }
    defer {
        if (out_fd != 1) _ = close(out_fd);
    }

    const terminator: u8 = if (zero_terminated) 0 else '\n';

    // Collect lines
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (lines.items) |line| {
            allocator.free(line);
        }
        lines.deinit(allocator);
    }

    if (input_range) |range| {
        // Generate numbers in range. lo == hi + 1 is a valid empty range
        // (produces no output, matching GNU), handled by the lo <= hi guard.
        // The break-before-increment form avoids an i64 overflow panic when
        // hi == maxInt(i64).
        if (range.lo <= range.hi) {
            var num = range.lo;
            while (true) {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{num}) catch break;
                const copy = try allocator.dupe(u8, str);
                try lines.append(allocator, copy);
                if (num == range.hi) break;
                num += 1;
            }
        }
    } else if (echo_mode) {
        // Use command line arguments
        for (echo_args.items) |arg| {
            const copy = try allocator.dupe(u8, arg);
            try lines.append(allocator, copy);
        }
    } else {
        // Read from file or stdin
        try readLines(allocator, input_file, &lines, terminator);
    }

    if (lines.items.len == 0) {
        return;
    }

    // Initialize RNG
    var prng = std.Random.DefaultPrng.init(blk: {
        // Use arc4random for seed
        const low: u64 = arc4random();
        const high: u64 = arc4random();
        break :blk (high << 32) | low;
    });
    const random = prng.random();

    if (repeat_mode) {
        // Output with replacement
        const count = head_count orelse lines.items.len;
        var output_count: usize = 0;
        while (output_count < count) : (output_count += 1) {
            const idx = random.intRangeLessThan(usize, 0, lines.items.len);
            writeFd(out_fd, lines.items[idx]);
            writeFd(out_fd, &[_]u8{terminator});
        }
    } else {
        // Fisher-Yates shuffle
        var idx = lines.items.len;
        while (idx > 1) {
            idx -= 1;
            const j = random.intRangeLessThan(usize, 0, idx + 1);
            const tmp = lines.items[idx];
            lines.items[idx] = lines.items[j];
            lines.items[j] = tmp;
        }

        // Output shuffled lines
        const count = if (head_count) |hc| @min(hc, lines.items.len) else lines.items.len;
        for (lines.items[0..count]) |line| {
            writeFd(out_fd, line);
            writeFd(out_fd, &[_]u8{terminator});
        }
    }
}

fn parseRange(s: []const u8) ?Range {
    // GNU shuf -i takes non-negative integers only, so a leading '-' (negative
    // LO) is an invalid input range, not a hidden second dash to skip past.
    if (s.len == 0 or s[0] == '-') return null;

    const dash_pos = std.mem.indexOf(u8, s, "-") orelse return null;

    const lo_str = s[0..dash_pos];
    const hi_str = s[dash_pos + 1 ..];

    // Reject a negative HI ("5--3") too.
    const lo = std.fmt.parseInt(i64, lo_str, 10) catch return null;
    const hi = std.fmt.parseInt(i64, hi_str, 10) catch return null;
    if (lo < 0 or hi < 0) return null;

    // lo == hi + 1 is a valid empty range in GNU (`shuf -i 5-4` → no output,
    // rc 0); only lo > hi + 1 is genuinely invalid. lo,hi >= 0 so lo - hi
    // cannot overflow.
    if (lo > hi and lo - hi > 1) return null;

    return .{ .lo = lo, .hi = hi };
}

fn readLines(allocator: std.mem.Allocator, path: ?[]const u8, lines: *std.ArrayListUnmanaged([]const u8), terminator: u8) !void {
    var fd: std.posix.fd_t = 0; // stdin

    if (path) |p| {
        if (!std.mem.eql(u8, p, "-")) {
            fd = std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .RDONLY }, 0) catch {
                writeStderr("zshuf: {s}: No such file or directory\n", .{p});
                return error.FileNotFound;
            };
        }
    }
    defer {
        if (fd != 0) _ = close(fd);
    }

    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const n = std.posix.read(fd, &buf) catch break;
        if (n == 0) break;

        const data = buf[0..n];
        for (data) |byte| {
            if (byte == terminator) {
                // Emit the line on EVERY terminator, even an empty segment —
                // blank lines are real input lines (GNU keeps them). The
                // trailing-empty case (input ends with a terminator) leaves
                // line_buf empty, so no phantom final line is emitted below.
                const copy = try allocator.dupe(u8, line_buf.items);
                try lines.append(allocator, copy);
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle a final line not followed by a terminator.
    if (line_buf.items.len > 0) {
        const copy = try allocator.dupe(u8, line_buf.items);
        try lines.append(allocator, copy);
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zshuf [OPTION]... [FILE]
        \\   or: zshuf -e [OPTION]... [ARG]...
        \\   or: zshuf -i LO-HI [OPTION]...
        \\Write a random permutation of the input lines to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -e, --echo             treat each ARG as an input line
        \\  -i, --input-range=LO-HI  generate integers from LO to HI
        \\  -n, --head-count=COUNT output at most COUNT lines
        \\  -o, --output=FILE      write output to FILE instead of stdout
        \\  -r, --repeat           output lines can be repeated (requires -n)
        \\  -z, --zero-terminated  line delimiter is NUL, not newline
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\Examples:
        \\  zshuf file.txt           Shuffle lines of file
        \\  zshuf -e a b c d         Shuffle arguments
        \\  zshuf -i 1-100           Shuffle numbers 1-100
        \\  zshuf -n 5 file.txt      Output 5 random lines
        \\  zshuf -rn 10 -e yes no   Pick 10 random yes/no
        \\
    , .{});
}
