//! zcat - Concatenate files and print to stdout
//!
//! Compatible with GNU cat:
//! - Concatenate FILE(s) to standard output
//! - -n, --number: number all output lines
//! - -b, --number-nonblank: number nonempty output lines
//! - -s, --squeeze-blank: suppress repeated empty lines
//! - -E, --show-ends: display $ at end of each line
//! - -T, --show-tabs: display TAB characters as ^I
//! - -A, --show-all: equivalent to -vET

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const posix = std.posix;

const Config = struct {
    number_lines: bool = false,
    number_nonblank: bool = false,
    squeeze_blank: bool = false,
    show_ends: bool = false,
    show_tabs: bool = false,
    show_nonprinting: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

const OutputState = struct {
    line_number: u64 = 1,
    prev_blank: bool = false,
    at_line_start: bool = true,
};

fn catFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, state: *OutputState) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();

    // Handle stdin
    if (std.mem.eql(u8, path, "-")) {
        try catStdin(config, state);
        return;
    }

    // Open file
    const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
        printErrorFmt("cannot open '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);

    // Fast path: no special processing needed
    if (!config.number_lines and !config.number_nonblank and !config.squeeze_blank and
        !config.show_ends and !config.show_tabs and !config.show_nonprinting)
    {
        try catFileFast(io, file, stdout);
        return;
    }

    // Slow path: line-by-line processing
    try catFileProcessed(allocator, io, file, stdout, config, state);
}

fn catFileFast(io: Io, file: Io.File, stdout: Io.File) !void {
    // Use sendFile for zero-copy transfer to stdout
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    var reader = file.reader(io, &read_buf);
    var writer = stdout.writerStreaming(io, &write_buf);

    while (true) {
        const n = writer.interface.sendFile(&reader, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Unimplemented => {
                // Fallback
                try catFileFallback(io, file, stdout);
                break;
            },
            else => return err,
        };
        if (n == 0) break;
    }

    writer.interface.flush() catch {};
}

fn catFileFallback(io: Io, file: Io.File, stdout: Io.File) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = file.readStreaming(io, &.{&buf}) catch |err| {
            return err;
        };
        if (bytes_read == 0) break;
        stdout.writeStreamingAll(io, buf[0..bytes_read]) catch |err| {
            return err;
        };
    }
}

fn catFileProcessed(allocator: std.mem.Allocator, io: Io, file: Io.File, stdout: Io.File, config: *const Config, state: *OutputState) !void {
    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &write_buf);

    var read_buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const bytes_read = file.readStreaming(io, &.{&read_buf}) catch break;
        if (bytes_read == 0) break;

        for (read_buf[0..bytes_read]) |byte| {
            if (byte == '\n') {
                // Process complete line
                const line = line_buf.items;
                const is_blank = line.len == 0;

                // Squeeze blank lines
                if (config.squeeze_blank and is_blank and state.prev_blank) {
                    line_buf.clearRetainingCapacity();
                    continue;
                }

                // Line numbering
                if (config.number_lines or (config.number_nonblank and !is_blank)) {
                    writer.interface.print("{d:>6}\t", .{state.line_number}) catch {};
                    state.line_number += 1;
                }

                // Output line content
                if (config.show_tabs or config.show_nonprinting) {
                    for (line) |c| {
                        try outputChar(&writer, c, config);
                    }
                } else {
                    writer.interface.writeAll(line) catch {};
                }

                // Show line end
                if (config.show_ends) {
                    writer.interface.writeAll("$") catch {};
                }
                writer.interface.writeAll("\n") catch {};

                state.prev_blank = is_blank;
                state.at_line_start = true;
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        const line = line_buf.items;
        if (config.number_lines or config.number_nonblank) {
            writer.interface.print("{d:>6}\t", .{state.line_number}) catch {};
            state.line_number += 1;
        }
        if (config.show_tabs or config.show_nonprinting) {
            for (line) |c| {
                try outputChar(&writer, c, config);
            }
        } else {
            writer.interface.writeAll(line) catch {};
        }
    }

    writer.interface.flush() catch {};
}

fn outputChar(writer: anytype, c: u8, config: *const Config) !void {
    if (config.show_tabs and c == '\t') {
        writer.interface.writeAll("^I") catch {};
    } else if (config.show_nonprinting and c < 32 and c != '\t' and c != '\n') {
        writer.interface.print("^{c}", .{c + 64}) catch {};
    } else if (config.show_nonprinting and c == 127) {
        writer.interface.writeAll("^?") catch {};
    } else if (config.show_nonprinting and c > 127) {
        writer.interface.print("M-{c}", .{c - 128}) catch {};
    } else {
        writer.interface.writeAll(&[_]u8{c}) catch {};
    }
}

fn catStdin(config: *const Config, state: *OutputState) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();

    if (!config.number_lines and !config.number_nonblank and !config.squeeze_blank and
        !config.show_ends and !config.show_tabs and !config.show_nonprinting)
    {
        // Fast path
        var buf: [65536]u8 = undefined;
        while (true) {
            const bytes_read = stdin.readStreaming(io, &.{&buf}) catch break;
            if (bytes_read == 0) break;
            stdout.writeStreamingAll(io, buf[0..bytes_read]) catch break;
        }
    } else {
        // Slow path with processing
        var write_buf: [8192]u8 = undefined;
        var writer = stdout.writerStreaming(io, &write_buf);
        var read_buf: [4096]u8 = undefined;
        var line_buf: [65536]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const bytes_read = stdin.readStreaming(io, &.{&read_buf}) catch break;
            if (bytes_read == 0) break;

            for (read_buf[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    const line = line_buf[0..line_len];
                    const is_blank = line_len == 0;

                    if (config.squeeze_blank and is_blank and state.prev_blank) {
                        line_len = 0;
                        continue;
                    }

                    if (config.number_lines or (config.number_nonblank and !is_blank)) {
                        writer.interface.print("{d:>6}\t", .{state.line_number}) catch {};
                        state.line_number += 1;
                    }

                    if (config.show_tabs or config.show_nonprinting) {
                        for (line) |c| {
                            outputChar(&writer, c, config) catch {};
                        }
                    } else {
                        writer.interface.writeAll(line) catch {};
                    }

                    if (config.show_ends) {
                        writer.interface.writeAll("$") catch {};
                    }
                    writer.interface.writeAll("\n") catch {};

                    state.prev_blank = is_blank;
                    line_len = 0;
                } else if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }

        writer.interface.flush() catch {};
    }
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
                } else if (std.mem.eql(u8, arg, "--number")) {
                    config.number_lines = true;
                } else if (std.mem.eql(u8, arg, "--number-nonblank")) {
                    config.number_nonblank = true;
                } else if (std.mem.eql(u8, arg, "--squeeze-blank")) {
                    config.squeeze_blank = true;
                } else if (std.mem.eql(u8, arg, "--show-ends")) {
                    config.show_ends = true;
                } else if (std.mem.eql(u8, arg, "--show-tabs")) {
                    config.show_tabs = true;
                } else if (std.mem.eql(u8, arg, "--show-nonprinting")) {
                    config.show_nonprinting = true;
                } else if (std.mem.eql(u8, arg, "--show-all")) {
                    config.show_nonprinting = true;
                    config.show_ends = true;
                    config.show_tabs = true;
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.files.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(1);
                }
            } else {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'n' => config.number_lines = true,
                        'b' => config.number_nonblank = true,
                        's' => config.squeeze_blank = true,
                        'E' => config.show_ends = true,
                        'T' => config.show_tabs = true,
                        'v' => config.show_nonprinting = true,
                        'A' => {
                            config.show_nonprinting = true;
                            config.show_ends = true;
                            config.show_tabs = true;
                        },
                        'e' => {
                            config.show_nonprinting = true;
                            config.show_ends = true;
                        },
                        't' => {
                            config.show_nonprinting = true;
                            config.show_tabs = true;
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Default to stdin if no files
    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zcat: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zcat [OPTION]... [FILE]...
        \\Concatenate FILE(s) to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -A, --show-all           equivalent to -vET
        \\  -b, --number-nonblank    number nonempty output lines
        \\  -e                       equivalent to -vE
        \\  -E, --show-ends          display $ at end of each line
        \\  -n, --number             number all output lines
        \\  -s, --squeeze-blank      suppress repeated empty output lines
        \\  -t                       equivalent to -vT
        \\  -T, --show-tabs          display TAB characters as ^I
        \\  -v, --show-nonprinting   use ^ and M- notation
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\zcat - High-performance file concatenation utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zcat 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zcat: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var state = OutputState{};
    var error_occurred = false;

    for (config.files.items) |file| {
        catFile(allocator, file, &config, &state) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
