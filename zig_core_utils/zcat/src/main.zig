//! zcat - Concatenate files and print to stdout
//!
//! Compatible with GNU cat (coreutils 9.x):
//! - Concatenate FILE(s) to standard output
//! - -n, --number: number all output lines
//! - -b, --number-nonblank: number nonempty output lines (overrides -n)
//! - -s, --squeeze-blank: suppress repeated empty lines
//! - -E, --show-ends: display $ at end of each line (CRLF shown as ^M$)
//! - -T, --show-tabs: display TAB characters as ^I
//! - -v, --show-nonprinting: use ^ and M- notation
//! - -A, --show-all: equivalent to -vET
//! - -e: equivalent to -vE; -t: equivalent to -vT
//! - -u: ignored (POSIX compatibility)

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

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

    /// True when the plain byte-copy fast path can be used.
    fn needsProcessing(self: *const Config) bool {
        return self.number_lines or self.number_nonblank or self.squeeze_blank or
            self.show_ends or self.show_tabs or self.show_nonprinting;
    }
};

/// Streaming output state. Shared across all input files: GNU cat treats the
/// inputs as one concatenated stream (line numbers continue, squeeze state and
/// a pending CR carry over file boundaries — verified against coreutils 9.10).
const OutputState = struct {
    line_number: u64 = 1,
    prev_blank: bool = false,
    at_line_start: bool = true,
    /// -E only (without -v): a '\r' has been seen and is held back one byte so
    /// that CRLF can be rendered as "^M$" (coreutils >= 9.4 behavior). A lone
    /// CR is emitted raw once the following byte proves it is not '\n'.
    pending_cr: bool = false,
};

/// Map error names to POSIX strerror-style text, matching GNU cat's messages.
fn errMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.InputOutput => "Input/output error",
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disc quota exceeded",
        error.FileTooBig => "File too large",
        error.BrokenPipe => "Broken pipe",
        error.SystemResources => "Cannot allocate memory",
        error.DeviceBusy => "Resource busy",
        error.NoDevice => "Operation not supported by device",
        error.FileBusy => "Text file busy",
        else => @errorName(err),
    };
}

fn catFile(io: Io, path: []const u8, config: *const Config, state: *OutputState, writer: *Io.File.Writer) !void {
    const is_stdin = std.mem.eql(u8, path, "-");

    const file = if (is_stdin)
        Io.File.stdin()
    else
        Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
            printErrorFmt("{s}: {s}", .{ path, errMsg(err) });
            return err;
        };
    defer if (!is_stdin) file.close(io);

    // GNU cat refuses directory operands: "cat: DIR: Is a directory", exit 1.
    // (On macOS open() succeeds on a directory; the read would fail EISDIR.)
    if (!is_stdin) {
        if (file.stat(io)) |st| {
            if (st.kind == .directory) {
                printErrorFmt("{s}: Is a directory", .{path});
                return error.IsDir;
            }
        } else |_| {}
    }

    if (config.needsProcessing()) {
        try catProcessed(io, file, path, config, state, writer);
    } else {
        try catFast(io, file, path, writer);
    }
}

/// Fast path: plain byte copy through the shared buffered writer.
/// Read errors are reported with the file name and propagated (never treated
/// as EOF); write errors propagate as error.WriteFailed for main to report.
fn catFast(io: Io, file: Io.File, path: []const u8, writer: *Io.File.Writer) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                printErrorFmt("{s}: {s}", .{ path, errMsg(err) });
                return err;
            },
        };
        if (n == 0) continue;
        try writer.interface.writeAll(buf[0..n]);
    }
}

/// Slow path: byte-at-a-time state machine, O(buffer) memory regardless of
/// line length (no whole-line accumulation).
fn catProcessed(io: Io, file: Io.File, path: []const u8, config: *const Config, state: *OutputState, writer: *Io.File.Writer) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                printErrorFmt("{s}: {s}", .{ path, errMsg(err) });
                return err;
            },
        };
        if (n == 0) continue;
        try processChunk(&writer.interface, buf[0..n], config, state);
    }
}

fn processChunk(w: *Io.Writer, chunk: []const u8, config: *const Config, state: *OutputState) !void {
    // -b overrides -n (GNU semantics): with -b, blank lines are never numbered.
    const number_nonblank = config.number_nonblank;
    const number_all = config.number_lines and !number_nonblank;

    for (chunk) |byte| {
        if (state.pending_cr) {
            state.pending_cr = false;
            if (byte == '\n') {
                // CRLF under -E renders as "^M$" (coreutils >= 9.4).
                try w.writeAll("^M$\n");
                state.at_line_start = true;
                state.prev_blank = false;
                continue;
            }
            // Lone CR: emit it raw, then process the current byte normally.
            try w.writeByte('\r');
        }

        if (byte == '\n') {
            if (state.at_line_start) {
                // Blank line.
                if (config.squeeze_blank and state.prev_blank) continue;
                if (number_all) {
                    try w.print("{d:>6}\t", .{state.line_number});
                    state.line_number += 1;
                }
                if (config.show_ends) try w.writeByte('$');
                try w.writeByte('\n');
                state.prev_blank = true;
            } else {
                if (config.show_ends) try w.writeByte('$');
                try w.writeByte('\n');
                state.at_line_start = true;
                state.prev_blank = false;
            }
            continue;
        }

        if (state.at_line_start) {
            state.at_line_start = false;
            if (number_all or number_nonblank) {
                try w.print("{d:>6}\t", .{state.line_number});
                state.line_number += 1;
            }
        }

        if (byte == '\r' and config.show_ends and !config.show_nonprinting) {
            // Hold the CR until the next byte decides CRLF vs lone CR.
            state.pending_cr = true;
            continue;
        }

        try outputChar(w, byte, config);
    }
}

/// Render one non-newline byte per GNU cat's -v/-T notation (cat.c):
///   0x00-0x1f  -> ^@..^_ (tab stays raw unless -T; -T alone shows ^I)
///   0x7f       -> ^?
///   0x80-0x9f  -> M-^@..M-^_
///   0xa0-0xfe  -> M-<char>
///   0xff       -> M-^?
fn outputChar(w: *Io.Writer, c: u8, config: *const Config) !void {
    if (c == '\t') {
        if (config.show_tabs) {
            try w.writeAll("^I");
        } else {
            try w.writeByte('\t');
        }
        return;
    }
    if (!config.show_nonprinting) {
        try w.writeByte(c);
        return;
    }
    if (c >= 128) {
        try w.writeAll("M-");
        const low = c - 128;
        if (low < 32) {
            try w.writeAll(&[_]u8{ '^', low + 64 });
        } else if (low == 127) {
            try w.writeAll("^?");
        } else {
            try w.writeByte(low);
        }
    } else if (c < 32) {
        try w.writeAll(&[_]u8{ '^', c + 64 });
    } else if (c == 127) {
        try w.writeAll("^?");
    } else {
        try w.writeByte(c);
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
                        'u' => {}, // POSIX: accepted and ignored (GNU cat does the same)
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

/// Report a failed stdout write and exit, mirroring GNU cat: "cat: write
/// error: <strerror>", exit 1. A broken pipe exits silently with the
/// conventional 128+SIGPIPE status instead (GNU cat dies from SIGPIPE).
fn writeErrorExit(writer: *Io.File.Writer) noreturn {
    const err: anyerror = writer.err orelse error.Unexpected;
    if (err == error.BrokenPipe) std.process.exit(141);
    printErrorFmt("write error: {s}", .{errMsg(err)});
    std.process.exit(1);
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
        \\  -b, --number-nonblank    number nonempty output lines, overrides -n
        \\  -e                       equivalent to -vE
        \\  -E, --show-ends          display $ at end of each line
        \\  -n, --number             number all output lines
        \\  -s, --squeeze-blank      suppress repeated empty output lines
        \\  -t                       equivalent to -vT
        \\  -T, --show-tabs          display TAB characters as ^I
        \\  -u                       (ignored)
        \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
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
    writer.interface.writeAll("zcat 0.2.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = Io.Threaded.global_single_threaded.io();

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zcat: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var state = OutputState{};
    var error_occurred = false;

    // One shared buffered stdout writer for all files, so processing state
    // (numbering, squeeze, pending CR) flows across file boundaries exactly
    // like GNU cat's single output stream.
    var write_buf: [65536]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &write_buf);

    for (config.files.items) |file| {
        catFile(io, file, &config, &state, &stdout_writer) catch |err| {
            if (err == error.WriteFailed) writeErrorExit(&stdout_writer);
            error_occurred = true;
        };
    }

    // A CR held back at overall EOF (no following LF ever arrived) is
    // emitted raw, matching `printf 'a\r' | cat -E` under GNU cat 9.10.
    if (state.pending_cr) {
        stdout_writer.interface.writeByte('\r') catch writeErrorExit(&stdout_writer);
    }
    stdout_writer.interface.flush() catch writeErrorExit(&stdout_writer);

    if (error_occurred) {
        std.process.exit(1);
    }
}
