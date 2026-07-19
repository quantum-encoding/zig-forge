//! zlink - call the link function to create a hard link
//!
//! A Zig implementation of GNU coreutils `link`:
//!   link FILE1 FILE2  — create a link named FILE2 to an existing FILE1.
//!
//! Faithful to link(1) semantics: exactly two file operands, no options
//! besides --help/--version, a bare link() call — it never unlinks,
//! never follows "DEST is a directory" logic, and treats "-" as a
//! filename. (Earlier revisions implemented ln-style options under this
//! name; that identity confusion — including a data-destroying
//! `-f same-file` unlink — was removed per the repo Golden Rule.)
//!
//! Usage: zlink FILE1 FILE2

const std = @import("std");

const VERSION = "2.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

/// Write the whole slice, retrying on partial writes and EINTR.
/// (The previous helper ignored the write() result entirely.)
fn writeFull(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return; // nothing more we can do about a failing stderr/stdout
        }
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

/// Format buffer sized for a diagnostic carrying two PATH_MAX paths.
/// On overflow we emit a truncated-diagnostic marker instead of
/// silently dropping the message (previous behavior).
fn writeFmt(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [2 * 4096 + 256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        writeFull(fd, "zlink: (diagnostic too long to display)\n");
        return;
    };
    writeFull(fd, msg);
}

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    writeFmt(2, fmt, args);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    writeFmt(1, fmt, args);
}

fn tryHelpAndExit() noreturn {
    writeStderr("Try 'zlink --help' for more information.\n", .{});
    std.process.exit(1);
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

    // GNU link recognizes only --help / --version (getopt_long permutes,
    // so options are honored even after operands, until "--").
    // A lone "-" is a filename, not an option.
    var operands: [2][]const u8 = undefined;
    var n_operands: usize = 0;
    var extra_operand: ?[]const u8 = null;
    var seen_dashdash = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!seen_dashdash and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            if (arg.len == 2) {
                seen_dashdash = true;
                continue;
            }
            const opt = arg[2..];
            // getopt_long-style unambiguous abbreviation ("--h", "--vers", ...).
            if (std.mem.startsWith(u8, "help", opt)) {
                printHelp();
                return;
            }
            if (std.mem.startsWith(u8, "version", opt)) {
                writeStdout("zlink {s}\n", .{VERSION});
                return;
            }
            writeStderr("zlink: unrecognized option '{s}'\n", .{arg});
            tryHelpAndExit();
        } else if (!seen_dashdash and arg.len >= 2 and arg[0] == '-') {
            // No short options exist in link(1).
            writeStderr("zlink: invalid option -- '{c}'\n", .{arg[1]});
            tryHelpAndExit();
        } else {
            // Operand: includes "-", "" and anything after "--".
            if (n_operands < 2) {
                operands[n_operands] = arg;
                n_operands += 1;
            } else if (extra_operand == null) {
                extra_operand = arg;
            }
        }
    }

    if (n_operands < 2) {
        if (n_operands == 1) {
            writeStderr("zlink: missing operand after '{s}'\n", .{operands[0]});
        } else {
            writeStderr("zlink: missing operand\n", .{});
        }
        tryHelpAndExit();
    }

    if (extra_operand) |extra| {
        writeStderr("zlink: extra operand '{s}'\n", .{extra});
        tryHelpAndExit();
    }

    const file1 = operands[0];
    const file2 = operands[1];

    const file1_z = try allocator.dupeZ(u8, file1);
    defer allocator.free(file1_z);
    const file2_z = try allocator.dupeZ(u8, file2);
    defer allocator.free(file2_z);

    if (link(file1_z, file2_z) != 0) {
        const err = std.c._errno().*;
        writeStderr("zlink: cannot create link '{s}' to '{s}': {s}\n", .{
            file2,
            file1,
            std.mem.span(strerror(err)),
        });
        std.process.exit(1);
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zlink FILE1 FILE2
        \\  or:  zlink OPTION
        \\Call the link function to create a link named FILE2 to an existing FILE1.
        \\
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    , .{});
}
