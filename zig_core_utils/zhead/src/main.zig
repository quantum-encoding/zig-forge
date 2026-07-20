//! zhead - Output the first part of files
//!
//! Compatible with GNU head:
//! - -n, --lines=NUM: print first NUM lines (default 10)
//! - -c, --bytes=NUM: print first NUM bytes
//! - -q, --quiet: never print headers
//! - -v, --verbose: always print headers

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const maxU64 = std.math.maxInt(u64);

const Config = struct {
    lines: ?u64 = 10,
    bytes: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    negative_lines: bool = false, // -n -5 means all but last 5 lines
    negative_bytes: bool = false, // -c -5 means all but last 5 bytes
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

/// Map a Zig error to GNU-style strerror text so diagnostics match the
/// reference `head` output (e.g. `error.FileNotFound` -> "No such file or
/// directory", `error.IsDir` -> "Is a directory").
fn errString(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.AccessDenied => "Permission denied",
        error.InputOutput => "Input/output error",
        error.NotDir => "Not a directory",
        else => @errorName(err),
    };
}

fn reportReadError(name: []const u8, err: anyerror) void {
    std.debug.print("zhead: error reading '{s}': {s}\n", .{ name, errString(err) });
}

/// Read into `dst`, returning 0 at end-of-stream and propagating any real
/// read error. `readStreaming` signals EOF via `error.EndOfStream`, so we must
/// distinguish it from genuine I/O failures (e.g. reading a directory) instead
/// of swallowing every error as the old `catch break` did.
fn readSome(io: Io, file: Io.File, dst: []u8) !usize {
    return file.readStreaming(io, &.{dst}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

fn headFile(
    io: Io,
    w: *Io.File.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
    config: *const Config,
    print_header: bool,
) !void {
    const is_stdin = std.mem.eql(u8, path, "-");
    // GNU labels the stdin header "standard input", not "-".
    const display = if (is_stdin) "standard input" else path;

    // Print header if needed
    if (print_header) {
        try w.interface.print("==> {s} <==\n", .{display});
    }

    // Handle stdin
    if (is_stdin) {
        return headStdin(io, w, allocator, config);
    }

    // Open file
    const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
        std.debug.print("zhead: cannot open '{s}' for reading: {s}\n", .{ path, errString(err) });
        return err;
    };
    defer file.close(io);

    try headReader(io, w, allocator, file, path, config);
}

fn headStdin(
    io: Io,
    w: *Io.File.Writer,
    allocator: std.mem.Allocator,
    config: *const Config,
) !void {
    const stdin = Io.File.stdin();
    try headReader(io, w, allocator, stdin, "standard input", config);
}

/// Core read/emit loop shared by file and stdin sources. `name` is the display
/// name used in read-error diagnostics.
fn headReader(
    io: Io,
    w: *Io.File.Writer,
    allocator: std.mem.Allocator,
    file: Io.File,
    name: []const u8,
    config: *const Config,
) !void {
    if (config.bytes) |num_bytes| {
        if (config.negative_bytes) {
            // Read entire input, output all but last N bytes
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = readSome(io, file, &buf) catch |err| {
                    reportReadError(name, err);
                    return err;
                };
                if (bytes_read == 0) break;
                try content.appendSlice(allocator, buf[0..bytes_read]);
            }

            if (content.items.len > num_bytes) {
                try w.interface.writeAll(content.items[0 .. content.items.len - @as(usize, @intCast(num_bytes))]);
            }
        } else {
            // Positive byte mode - output first N bytes
            var remaining = num_bytes;
            var buf: [8192]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, buf.len);
                const bytes_read = readSome(io, file, buf[0..to_read]) catch |err| {
                    reportReadError(name, err);
                    return err;
                };
                if (bytes_read == 0) break;
                try w.interface.writeAll(buf[0..bytes_read]);
                remaining -= bytes_read;
            }
        }
    } else if (config.lines) |num_lines| {
        if (config.negative_lines) {
            // Read entire input, output all but last N lines
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = readSome(io, file, &buf) catch |err| {
                    reportReadError(name, err);
                    return err;
                };
                if (bytes_read == 0) break;
                try content.appendSlice(allocator, buf[0..bytes_read]);
            }

            var total_lines: u64 = 0;
            for (content.items) |byte| {
                if (byte == '\n') total_lines += 1;
            }

            if (total_lines > num_lines) {
                const target_lines = total_lines - num_lines;
                var lines_output: u64 = 0;
                var pos: usize = 0;

                for (content.items, 0..) |byte, idx| {
                    if (byte == '\n') {
                        lines_output += 1;
                        if (lines_output >= target_lines) {
                            pos = idx + 1;
                            break;
                        }
                    }
                }

                try w.interface.writeAll(content.items[0..pos]);
            }
        } else {
            // Positive line mode - output first N lines
            var lines_printed: u64 = 0;
            var buf: [8192]u8 = undefined;

            while (lines_printed < num_lines) {
                const bytes_read = readSome(io, file, &buf) catch |err| {
                    reportReadError(name, err);
                    return err;
                };
                if (bytes_read == 0) break;

                var start: usize = 0;
                for (buf[0..bytes_read], 0..) |byte, i| {
                    if (byte == '\n') {
                        try w.interface.writeAll(buf[start .. i + 1]);
                        start = i + 1;
                        lines_printed += 1;
                        if (lines_printed >= num_lines) break;
                    }
                }

                // Write remaining partial line if we haven't hit the limit
                if (start < bytes_read and lines_printed < num_lines) {
                    try w.interface.writeAll(buf[start..bytes_read]);
                }
            }
        }
    }
}

const ParsedNumber = struct {
    value: u64,
    negative: bool,
};

/// Multiply, clamping to u64 max on overflow (GNU clamps oversized counts and
/// still exits 0 rather than aborting).
fn clampMul(a: u64, b: u64) u64 {
    const m = @mulWithOverflow(a, b);
    return if (m[1] != 0) maxU64 else m[0];
}

/// base**power, clamped to u64 max on overflow.
fn clampPow(base: u64, power: u6) u64 {
    var r: u64 = 1;
    var p = power;
    while (p > 0) : (p -= 1) r = clampMul(r, base);
    return r;
}

/// Return the GNU unit power for a suffix letter, or null if unrecognized.
/// Uppercase letters cover K/M/G/T/P/E/Z/Y; lowercase k and m are also
/// accepted (matching GNU coreutils 9.x observed behavior).
fn unitPower(c: u8) ?u6 {
    return switch (c) {
        'k', 'K' => 1,
        'm', 'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        else => null,
    };
}

/// Parse a GNU head numeric argument.
///
/// Returns null on an invalid number (caller must emit "invalid number of
/// lines/bytes" and exit 1). On numeric overflow the value is clamped to u64
/// max instead of aborting, matching GNU (which prints the whole file, exit 0).
///
/// Supported suffixes (GNU parity):
///   b  = 512
///   kB/MB/GB/... (decimal, 1000-based)
///   K/M/G/T/P/E/Z/Y and KiB/MiB/... (binary, 1024-based)
fn parseNumber(s: []const u8) ?ParsedNumber {
    if (s.len == 0) return null;

    var num_str = s;
    var negative = false;

    // Leading minus: -n -N means "all but the last N".
    if (num_str[0] == '-') {
        negative = true;
        num_str = num_str[1..];
        if (num_str.len == 0) return null;
    }

    // Suffix handling.
    var multiplier: u64 = 1;
    if (num_str.len > 0) {
        if (num_str[num_str.len - 1] == 'b') {
            // Plain 'b' == 512 bytes.
            multiplier = 512;
            num_str = num_str[0 .. num_str.len - 1];
        } else {
            var base: u64 = 1024;
            // Trailing 'B' selects decimal (1000-based); 'iB' stays binary.
            if (num_str.len >= 1 and num_str[num_str.len - 1] == 'B') {
                if (num_str.len >= 2 and num_str[num_str.len - 2] == 'i') {
                    num_str = num_str[0 .. num_str.len - 2]; // drop "iB"
                } else {
                    base = 1000;
                    num_str = num_str[0 .. num_str.len - 1]; // drop "B"
                }
            }
            // Trailing unit letter.
            if (num_str.len > 0) {
                if (unitPower(num_str[num_str.len - 1])) |power| {
                    multiplier = clampPow(base, power);
                    num_str = num_str[0 .. num_str.len - 1];
                } else if (base == 1000) {
                    // A stray 'B' with no unit letter (e.g. "10B") -> ignore
                    // multiplier; nothing to do.
                }
            }
        }
    }

    if (num_str.len == 0) return null;

    var val: u64 = 0;
    var overflow = false;
    for (num_str) |c| {
        if (c < '0' or c > '9') return null;
        if (!overflow) {
            const m = @mulWithOverflow(val, 10);
            if (m[1] != 0) {
                overflow = true;
            } else {
                const a = @addWithOverflow(m[0], @as(u64, c - '0'));
                if (a[1] != 0) overflow = true else val = a[0];
            }
        }
    }
    if (overflow) val = maxU64;

    return .{ .value = clampMul(val, multiplier), .negative = negative };
}

/// Emit the GNU "invalid number of lines/bytes" diagnostic and exit 1.
fn invalidNumber(kind: []const u8, arg: []const u8) noreturn {
    std.debug.print("zhead: invalid number of {s}: '{s}'\n", .{ kind, arg });
    std.process.exit(1);
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.startsWith(u8, arg, "--lines=")) {
                    const parsed = parseNumber(arg[8..]) orelse invalidNumber("lines", arg[8..]);
                    config.lines = parsed.value;
                    config.negative_lines = parsed.negative;
                    config.bytes = null;
                } else if (std.mem.eql(u8, arg, "--lines")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zhead: option '--lines' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    const parsed = parseNumber(args[i]) orelse invalidNumber("lines", args[i]);
                    config.lines = parsed.value;
                    config.negative_lines = parsed.negative;
                    config.bytes = null;
                } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
                    const parsed = parseNumber(arg[8..]) orelse invalidNumber("bytes", arg[8..]);
                    config.bytes = parsed.value;
                    config.negative_bytes = parsed.negative;
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zhead: option '--bytes' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    const parsed = parseNumber(args[i]) orelse invalidNumber("bytes", args[i]);
                    config.bytes = parsed.value;
                    config.negative_bytes = parsed.negative;
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                    // Last of -q/-v wins (GNU semantics).
                    config.quiet = true;
                    config.verbose = false;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                    config.quiet = false;
                } else {
                    std.debug.print("zhead: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                // Short options
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'n' => {
                            if (j + 1 < arg.len) {
                                const parsed = parseNumber(arg[j + 1 ..]) orelse invalidNumber("lines", arg[j + 1 ..]);
                                config.lines = parsed.value;
                                config.negative_lines = parsed.negative;
                                config.bytes = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    std.debug.print("zhead: option requires an argument -- 'n'\n", .{});
                                    std.process.exit(1);
                                }
                                const parsed = parseNumber(args[i]) orelse invalidNumber("lines", args[i]);
                                config.lines = parsed.value;
                                config.negative_lines = parsed.negative;
                                config.bytes = null;
                            }
                        },
                        'c' => {
                            if (j + 1 < arg.len) {
                                const parsed = parseNumber(arg[j + 1 ..]) orelse invalidNumber("bytes", arg[j + 1 ..]);
                                config.bytes = parsed.value;
                                config.negative_bytes = parsed.negative;
                                config.lines = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    std.debug.print("zhead: option requires an argument -- 'c'\n", .{});
                                    std.process.exit(1);
                                }
                                const parsed = parseNumber(args[i]) orelse invalidNumber("bytes", args[i]);
                                config.bytes = parsed.value;
                                config.negative_bytes = parsed.negative;
                                config.lines = null;
                            }
                        },
                        'q' => {
                            config.quiet = true;
                            config.verbose = false;
                        },
                        'v' => {
                            config.verbose = true;
                            config.quiet = false;
                        },
                        '0'...'9' => {
                            // -NUM format
                            const parsed = parseNumber(arg[j..]) orelse invalidNumber("lines", arg[j..]);
                            config.lines = parsed.value;
                            config.negative_lines = parsed.negative;
                            config.bytes = null;
                            break;
                        },
                        else => {
                            std.debug.print("zhead: invalid option -- '{c}'\n", .{arg[j]});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [1024]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zhead [OPTION]... [FILE]...
        \\Print the first 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\  -c, --bytes=NUM    print the first NUM bytes
        \\  -n, --lines=NUM    print the first NUM lines (default 10)
        \\  -q, --quiet        never print headers
        \\  -v, --verbose      always print headers
        \\      --help         display this help and exit
        \\      --version      output version information and exit
        \\
        \\NUM may have a multiplier suffix: b (512), kB (1000), K (1024),
        \\MB (1000*1000), M (1024*1024), and so on for G, T, P, E, Z, Y.
        \\
        \\zhead - High-performance head utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zhead 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zhead: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const multiple_files = config.files.items.len > 1;
    var error_occurred = false;
    var first = true;

    // A single writer over stdout, shared across every file and separator.
    // Constructing a fresh writer per call gave each its own offset tracking
    // over a seekable (redirected) stdout, so the second file's separator
    // clobbered the first byte at offset 0. One writer, flushed once, fixes it.
    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &write_buf);

    for (config.files.items) |file| {
        const print_header = (config.verbose or (multiple_files and !config.quiet));

        if (!first and print_header) {
            writer.interface.writeAll("\n") catch {
                error_occurred = true;
            };
        }
        headFile(io, &writer, allocator, file, &config, print_header) catch {
            error_occurred = true;
        };
        first = false;
    }

    writer.interface.flush() catch {
        error_occurred = true;
    };

    if (error_occurred) {
        std.process.exit(1);
    }
}
