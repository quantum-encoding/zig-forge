//! zpaste - Paste clipboard to stdout
//!
//! Usage:
//!   zpaste                         Print clipboard contents
//!   zpaste > file.txt              Save clipboard to file
//!   zpaste -p                      Paste from primary selection (X11)
//!   zpaste | command               Pipe clipboard to command
//!
//! Options:
//!   -p, --primary    Use PRIMARY selection instead of CLIPBOARD
//!   -n, --no-newline Don't add trailing newline
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
    add_newline: bool = true,
};

fn printHelp(writer: *Writer) void {
    writer.write(
        \\zpaste - Paste clipboard to stdout
        \\
        \\Usage: zpaste [options]
        \\       zpaste [options] > file
        \\       zpaste [options] | command
        \\
        \\Options:
        \\  -p, --primary    Use PRIMARY selection (X11 middle-click)
        \\  -n, --no-newline Don't add trailing newline
        \\  -h, --help       Show this help message
        \\  --version        Show version
        \\
        \\Examples:
        \\  zpaste                      Print clipboard
        \\  zpaste > output.txt         Save clipboard to file
        \\  zpaste | grep pattern       Search clipboard contents
        \\  zpaste -p                   Paste from primary selection
        \\
    );
}

fn printVersion(writer: *Writer) void {
    writer.print("zpaste {s}\n", .{VERSION});
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
            config.add_newline = false;
        } else {
            var writer = Writer.stderr();
            writer.print("zpaste: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Check backend availability
    const backend = clipboard.detectBackend(allocator);
    if (backend == .none) {
        var writer = Writer.stderr();
        writer.write("zpaste: no clipboard backend available\n");
        writer.write("Install wl-copy (Wayland) or xclip/xsel (X11)\n");
        std.process.exit(1);
    }

    // Paste from clipboard
    const data = clipboard.paste(allocator, config.selection) catch |err| {
        var writer = Writer.stderr();
        switch (err) {
            error.NoBackendAvailable => writer.write("zpaste: no clipboard backend\n"),
            error.BackendFailed => writer.write("zpaste: clipboard backend failed\n"),
            error.ReadError => writer.write("zpaste: failed to read from clipboard\n"),
            else => writer.print("zpaste: error: {}\n", .{err}),
        }
        std.process.exit(1);
    };
    defer allocator.free(data);

    // Write to stdout
    var writer = Writer.stdout();
    writer.write(data);

    // Add newline if needed (and data doesn't already end with one)
    if (config.add_newline and data.len > 0 and data[data.len - 1] != '\n') {
        writer.write("\n");
    }
}
