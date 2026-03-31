//! zcopy - Copy stdin to clipboard
//!
//! Usage:
//!   echo "hello" | zcopy           Copy to clipboard
//!   zcopy < file.txt               Copy file contents to clipboard
//!   zcopy -p                       Copy to primary selection (X11)
//!   zcopy --primary                Copy to primary selection
//!   cat file | zcopy -n            Copy without trailing newline
//!
//! Options:
//!   -p, --primary    Use PRIMARY selection instead of CLIPBOARD
//!   -n, --no-newline Remove trailing newline from input
//!   -v, --verbose    Show what was copied
//!   -h, --help       Show help message
//!   --version        Show version

const std = @import("std");
const posix = std.posix;
const clipboard = @import("clipboard");

const VERSION = "1.0.0";

// ============================================================================
// Writer for Zig 0.16
// ============================================================================

const Writer = struct {
    io: std.Io,
    buffer: *[4096]u8,
    file: std.Io.File,

    pub fn stderr() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [4096]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn stdout() Writer {
        const io = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [4096]u8 = undefined;
        };
        return Writer{
            .io = io,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }

    pub fn write(self: *Writer, data: []const u8) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.writeAll(data) catch {};
        writer.interface.flush() catch {};
    }
};

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    selection: clipboard.Selection = .clipboard,
    strip_newline: bool = false,
    verbose: bool = false,
};

fn printHelp(writer: *Writer) void {
    writer.write(
        \\zcopy - Copy stdin to clipboard
        \\
        \\Usage: command | zcopy [options]
        \\       zcopy [options] < file
        \\
        \\Options:
        \\  -p, --primary    Use PRIMARY selection (X11 middle-click)
        \\  -n, --no-newline Strip trailing newline from input
        \\  -v, --verbose    Show what was copied
        \\  -h, --help       Show this help message
        \\  --version        Show version
        \\
        \\Examples:
        \\  echo "hello" | zcopy        Copy "hello" to clipboard
        \\  pwd | zcopy                 Copy current directory
        \\  cat file.txt | zcopy        Copy file contents
        \\  zcopy -p < secret.txt       Copy to primary selection
        \\
    );
}

fn printVersion(writer: *Writer) void {
    writer.print("zcopy {s}\n", .{VERSION});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse arguments
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var writer = Writer.stdout();
            printHelp(&writer);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            var writer = Writer.stdout();
            printVersion(&writer);
            return;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--primary")) {
            config.selection = .primary;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-newline")) {
            config.strip_newline = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else {
            var writer = Writer.stderr();
            writer.print("zcopy: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Check backend availability
    const backend = clipboard.detectBackend(allocator);
    if (backend == .none) {
        var writer = Writer.stderr();
        writer.write("zcopy: no clipboard backend available\n");
        writer.write("Install wl-copy (Wayland) or xclip/xsel (X11)\n");
        std.process.exit(1);
    }

    // Read stdin
    var input = std.ArrayListUnmanaged(u8).empty;
    defer input.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
        if (n == 0) break;
        input.appendSlice(allocator, buf[0..n]) catch break;
    }

    var data = input.items;

    // Strip trailing newline if requested
    if (config.strip_newline) {
        while (data.len > 0 and (data[data.len - 1] == '\n' or data[data.len - 1] == '\r')) {
            data = data[0 .. data.len - 1];
        }
    }

    // Copy to clipboard
    clipboard.copy(allocator, data, config.selection) catch |err| {
        var writer = Writer.stderr();
        switch (err) {
            error.NoBackendAvailable => writer.write("zcopy: no clipboard backend\n"),
            error.BackendFailed => writer.write("zcopy: clipboard backend failed\n"),
            error.WriteError => writer.write("zcopy: failed to write to clipboard\n"),
            else => writer.print("zcopy: error: {}\n", .{err}),
        }
        std.process.exit(1);
    };

    // Verbose output
    if (config.verbose) {
        var writer = Writer.stderr();
        const sel_name = if (config.selection == .primary) "PRIMARY" else "CLIPBOARD";
        writer.print("Copied {d} bytes to {s} ({s})\n", .{
            data.len,
            sel_name,
            clipboard.backendName(backend),
        });
    }
}
