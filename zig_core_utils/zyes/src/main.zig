//! zyes - Output a string repeatedly until killed
//!
//! Compatible with GNU yes:
//! - Outputs "y" by default, or the specified STRING(s) joined by spaces
//! - Continues until killed or write fails (broken pipe)
//! - On a broken pipe the default SIGPIPE disposition terminates the process
//!   (exit 141), matching GNU yes. We do NOT ignore SIGPIPE.
//! - Options are parsed GNU-style: `--help`/`--version` recognized anywhere,
//!   `--` ends option processing, any other `-x`/`--x` is a hard error (exit 1).

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub fn main(init: std.process.Init) void {
    // The Zig runtime ignores SIGPIPE by default; GNU yes relies on the
    // DEFAULT disposition so that writing to a broken pipe terminates the
    // process (exit 141). Reset SIGPIPE to SIG_DFL to match that behavior.
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.DFL },
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

    const prog = if (args.len > 0) basename(args[0]) else "zyes";

    // Parse options GNU-style, left to right. The only recognized options
    // (--help/--version) exit immediately; any other option token is a hard
    // error. Everything else (and everything after `--`) is an operand.
    var operands: std.ArrayListUnmanaged([]const u8) = .empty;
    defer operands.deinit(allocator);
    var opts_done = false;
    for (args[1..]) |arg| {
        if (!opts_done) {
            if (std.mem.eql(u8, arg, "--")) {
                opts_done = true;
                continue;
            }
            // An option token starts with '-' and is at least two chars
            // ("-" alone is a normal operand).
            if (arg.len >= 2 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                }
                if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                }
                if (arg[1] == '-') {
                    // Unrecognized long option.
                    std.debug.print("{s}: unrecognized option '{s}'\nTry '{s} --help' for more information.\n", .{ prog, arg, prog });
                } else {
                    // Unrecognized short option; report its first character
                    // (GNU: "invalid option -- 'x'").
                    std.debug.print("{s}: invalid option -- '{c}'\nTry '{s} --help' for more information.\n", .{ prog, arg[1], prog });
                }
                std.process.exit(1);
            }
        }
        operands.append(allocator, arg) catch {
            std.debug.print("zyes: allocation failed\n", .{});
            std.process.exit(1);
        };
    }

    // Build output string - join operands with spaces + trailing newline,
    // or default to "y".
    var output: []const u8 = undefined;
    if (operands.items.len == 0) {
        output = "y\n";
    } else {
        var total_len: usize = 0;
        for (operands.items) |arg| {
            total_len += arg.len + 1; // +1 for space or newline
        }

        const buf = allocator.alloc(u8, total_len) catch {
            std.debug.print("zyes: allocation failed\n", .{});
            std.process.exit(1);
        };

        var pos: usize = 0;
        const n = operands.items.len;
        for (operands.items, 0..) |arg, i| {
            @memcpy(buf[pos..][0..arg.len], arg);
            pos += arg.len;
            buf[pos] = if (i + 1 < n) ' ' else '\n';
            pos += 1;
        }
        output = buf;
    }

    // output.len is always >= 1 (at minimum a single '\n'), so the write
    // chunk below can never be empty.

    // Build the write chunk. For efficiency we fill a stack buffer with as
    // many whole copies of `output` as fit. If a single copy is larger than
    // the buffer, we write directly from `output` instead (the old code left
    // the buffer empty here and busy-looped writing 0 bytes forever).
    var buf: [65536]u8 = undefined;
    var chunk: []const u8 = undefined;
    if (output.len > buf.len) {
        chunk = output;
    } else {
        var filled: usize = 0;
        while (filled + output.len <= buf.len) : (filled += output.len) {
            @memcpy(buf[filled..][0..output.len], output);
        }
        chunk = buf[0..filled];
    }

    // Write repeatedly until a fatal error. Partial/short writes are honored
    // by advancing an offset (full_write semantics); EINTR/EAGAIN retry. A
    // broken pipe raises SIGPIPE (default disposition) and terminates us.
    while (true) {
        if (!writeFull(std.c.STDOUT_FILENO, chunk)) std.process.exit(1);
    }
}

/// Write the entire buffer, honoring short writes and retrying on EINTR/EAGAIN.
/// Returns false on a fatal error.
fn writeFull(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const r = std.c.write(fd, data.ptr + off, data.len - off);
        if (r < 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.c.E.INTR) or e == @intFromEnum(std.c.E.AGAIN)) continue;
            return false;
        }
        if (r == 0) return false; // no progress; avoid a busy spin
        off += @intCast(r);
    }
    return true;
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
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
