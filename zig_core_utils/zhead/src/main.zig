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

fn headFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, print_header: bool) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();

    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &write_buf);

    // Print header if needed
    if (print_header) {
        writer.interface.print("==> {s} <==\n", .{path}) catch {};
    }

    // Handle stdin
    if (std.mem.eql(u8, path, "-")) {
        try headStdin(allocator, io, &writer, config);
        writer.interface.flush() catch {};
        return;
    }

    // Open file
    const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
        std.debug.print("zhead: cannot open '{s}' for reading: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    // Handle negative byte count (all but last N bytes)
    if (config.bytes) |num_bytes| {
        if (config.negative_bytes) {
            // Read entire file, output all but last N bytes
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = file.readStreaming(io, &.{&buf}) catch break;
                if (bytes_read == 0) break;
                try content.appendSlice(allocator, buf[0..bytes_read]);
            }

            if (content.items.len > num_bytes) {
                writer.interface.writeAll(content.items[0 .. content.items.len - @as(usize, @intCast(num_bytes))]) catch {};
            }
        } else {
            // Positive byte mode - output first N bytes
            var remaining = num_bytes;
            var buf: [8192]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, buf.len);
                const bytes_read = file.readStreaming(io, &.{buf[0..to_read]}) catch break;
                if (bytes_read == 0) break;
                writer.interface.writeAll(buf[0..bytes_read]) catch {};
                remaining -= bytes_read;
            }
        }
    } else if (config.lines) |num_lines| {
        if (config.negative_lines) {
            // Read entire file, output all but last N lines
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = file.readStreaming(io, &.{&buf}) catch break;
                if (bytes_read == 0) break;
                try content.appendSlice(allocator, buf[0..bytes_read]);
            }

            // Count total lines and find position to stop
            var total_lines: u64 = 0;
            for (content.items) |byte| {
                if (byte == '\n') total_lines += 1;
            }

            // Output all but last N lines
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

                writer.interface.writeAll(content.items[0..pos]) catch {};
            }
        } else {
            // Positive line mode - output first N lines
            var lines_printed: u64 = 0;
            var buf: [8192]u8 = undefined;

            while (lines_printed < num_lines) {
                const bytes_read = file.readStreaming(io, &.{&buf}) catch break;
                if (bytes_read == 0) break;

                var start: usize = 0;
                for (buf[0..bytes_read], 0..) |byte, i| {
                    if (byte == '\n') {
                        writer.interface.writeAll(buf[start .. i + 1]) catch {};
                        start = i + 1;
                        lines_printed += 1;
                        if (lines_printed >= num_lines) break;
                    }
                }

                // Write remaining partial line if we haven't hit the limit
                if (start < bytes_read and lines_printed < num_lines) {
                    writer.interface.writeAll(buf[start..bytes_read]) catch {};
                }
            }
        }
    }

    writer.interface.flush() catch {};
}

fn headStdin(allocator: std.mem.Allocator, io: Io, writer: anytype, config: *const Config) !void {
    const stdin = Io.File.stdin();

    if (config.bytes) |num_bytes| {
        if (config.negative_bytes) {
            // Read all stdin, output all but last N bytes
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = stdin.readStreaming(io, &.{&buf}) catch break;
                if (bytes_read == 0) break;
                try content.appendSlice(allocator, buf[0..bytes_read]);
            }

            if (content.items.len > num_bytes) {
                writer.interface.writeAll(content.items[0 .. content.items.len - @as(usize, @intCast(num_bytes))]) catch {};
            }
        } else {
            var remaining = num_bytes;
            var buf: [8192]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, buf.len);
                const bytes_read = stdin.readStreaming(io, &.{buf[0..to_read]}) catch break;
                if (bytes_read == 0) break;
                writer.interface.writeAll(buf[0..bytes_read]) catch {};
                remaining -= bytes_read;
            }
        }
    } else if (config.lines) |num_lines| {
        if (config.negative_lines) {
            // Read all stdin, output all but last N lines
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(allocator);

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = stdin.readStreaming(io, &.{&buf}) catch break;
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

                writer.interface.writeAll(content.items[0..pos]) catch {};
            }
        } else {
            var lines_printed: u64 = 0;
            var buf: [8192]u8 = undefined;

            while (lines_printed < num_lines) {
                const bytes_read = stdin.readStreaming(io, &.{&buf}) catch break;
                if (bytes_read == 0) break;

                var start: usize = 0;
                for (buf[0..bytes_read], 0..) |byte, i| {
                    if (byte == '\n') {
                        writer.interface.writeAll(buf[start .. i + 1]) catch {};
                        start = i + 1;
                        lines_printed += 1;
                        if (lines_printed >= num_lines) break;
                    }
                }

                if (start < bytes_read and lines_printed < num_lines) {
                    writer.interface.writeAll(buf[start..bytes_read]) catch {};
                }
            }
        }
    }
}

const ParsedNumber = struct {
    value: u64,
    negative: bool,
};

fn parseNumber(s: []const u8) ?ParsedNumber {
    if (s.len == 0) return null;

    var val: u64 = 0;
    var multiplier: u64 = 1;
    var num_str = s;
    var negative = false;

    // Check for leading minus (negative = all but last N)
    if (num_str[0] == '-') {
        negative = true;
        num_str = num_str[1..];
        if (num_str.len == 0) return null;
    }

    // Check for suffix
    if (num_str.len > 0) {
        const last = num_str[num_str.len - 1];
        switch (last) {
            'k', 'K' => {
                multiplier = 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            'm', 'M' => {
                multiplier = 1024 * 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            'g', 'G' => {
                multiplier = 1024 * 1024 * 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            else => {},
        }
    }

    for (num_str) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }

    return .{ .value = val * multiplier, .negative = negative };
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
                    if (parseNumber(arg[8..])) |parsed| {
                        config.lines = parsed.value;
                        config.negative_lines = parsed.negative;
                    }
                    config.bytes = null;
                } else if (std.mem.eql(u8, arg, "--lines")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zhead: option '--lines' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseNumber(args[i])) |parsed| {
                        config.lines = parsed.value;
                        config.negative_lines = parsed.negative;
                    }
                    config.bytes = null;
                } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
                    if (parseNumber(arg[8..])) |parsed| {
                        config.bytes = parsed.value;
                        config.negative_bytes = parsed.negative;
                    }
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("zhead: option '--bytes' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseNumber(args[i])) |parsed| {
                        config.bytes = parsed.value;
                        config.negative_bytes = parsed.negative;
                    }
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
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
                                if (parseNumber(arg[j + 1 ..])) |parsed| {
                                    config.lines = parsed.value;
                                    config.negative_lines = parsed.negative;
                                }
                                config.bytes = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    std.debug.print("zhead: option requires an argument -- 'n'\n", .{});
                                    std.process.exit(1);
                                }
                                if (parseNumber(args[i])) |parsed| {
                                    config.lines = parsed.value;
                                    config.negative_lines = parsed.negative;
                                }
                                config.bytes = null;
                            }
                        },
                        'c' => {
                            if (j + 1 < arg.len) {
                                if (parseNumber(arg[j + 1 ..])) |parsed| {
                                    config.bytes = parsed.value;
                                    config.negative_bytes = parsed.negative;
                                }
                                config.lines = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    std.debug.print("zhead: option requires an argument -- 'c'\n", .{});
                                    std.process.exit(1);
                                }
                                if (parseNumber(args[i])) |parsed| {
                                    config.bytes = parsed.value;
                                    config.negative_bytes = parsed.negative;
                                }
                                config.lines = null;
                            }
                        },
                        'q' => config.quiet = true,
                        'v' => config.verbose = true,
                        '0'...'9' => {
                            // -NUM format
                            if (parseNumber(arg[j..])) |parsed| {
                                config.lines = parsed.value;
                                config.negative_lines = parsed.negative;
                            }
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
        \\NUM may have a multiplier suffix: k (1024), M (1024*1024), G (1024^3)
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

    for (config.files.items) |file| {
        const print_header = (config.verbose or (multiple_files and !config.quiet));

        if (!first and print_header) {
            const io = Io.Threaded.global_single_threaded.io();
            var buf: [64]u8 = undefined;
            const stdout = Io.File.stdout();
            var writer = stdout.writer(io, &buf);
            writer.interface.writeAll("\n") catch {};
            writer.interface.flush() catch {};
        }
        headFile(allocator, file, &config, print_header) catch {
            error_occurred = true;
        };
        first = false;
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
