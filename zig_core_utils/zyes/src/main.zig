//! zyes - Output a string repeatedly until killed
//!
//! Compatible with GNU yes:
//! - Outputs "y" by default, or specified string
//! - Continues until killed or write fails (broken pipe)
//! - Properly handles SIGPIPE (exits cleanly on broken pipe)

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub fn main(init: std.process.Init) void {
    // Ignore SIGPIPE so we get EPIPE errors instead of being killed
    // This allows us to exit cleanly when pipe reader closes
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    }, null);
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("zyes: failed to get arguments\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    // Check for help/version
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, args[1], "--version")) {
            printVersion();
            return;
        }
    }

    // Build output string - join all args with spaces, or default to "y"
    var output: []u8 = undefined;
    var needs_free = false;

    if (args.len <= 1) {
        output = @constCast("y\n");
    } else {
        // Calculate total length
        var total_len: usize = 0;
        for (args[1..]) |arg| {
            total_len += arg.len + 1; // +1 for space or newline
        }

        output = allocator.alloc(u8, total_len) catch {
            std.debug.print("zyes: allocation failed\n", .{});
            std.process.exit(1);
        };
        needs_free = true;

        var pos: usize = 0;
        for (args[1..], 0..) |arg, i| {
            @memcpy(output[pos..][0..arg.len], arg);
            pos += arg.len;
            if (i < args.len - 2) {
                output[pos] = ' ';
            } else {
                output[pos] = '\n';
            }
            pos += 1;
        }
    }
    defer if (needs_free) allocator.free(output);

    // Use a larger buffer for efficiency - fill it with repeated output
    var buf: [65536]u8 = undefined;
    var buf_len: usize = 0;

    while (buf_len + output.len <= buf.len) {
        @memcpy(buf[buf_len..][0..output.len], output);
        buf_len += output.len;
    }

    // Write repeatedly until error (broken pipe, etc.)
    // Using direct posix write for simplicity and proper error handling
    while (true) {
        const result = std.c.write(std.c.STDOUT_FILENO, buf[0..buf_len].ptr, buf_len);
        if (result < 0) break;
    }
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zyes [STRING]...
        \\Repeatedly output a line with all specified STRING(s), or 'y'.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
        \\zyes - High-performance yes utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zyes 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}
