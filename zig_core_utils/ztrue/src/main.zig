//! ztrue - do nothing, successfully
//!
//! GNU-compatible `true` (coreutils 9.10):
//!   - Always exits with status 0, regardless of arguments.
//!   - --help / --version are honored ONLY when they are the sole command-line
//!     argument (coreutils true.c: the `argc == 2` guard). In every other case
//!     (including `--help extra`, `extra --help`, `--hel`, `--help=x`, `-h`)
//!     the arguments are ignored and nothing is printed.
//!   - The exit status is 0 in every case (unlike `false`, which exits 1),
//!     including after printing --help/--version.
const std = @import("std");
const Io = std.Io;

const help_text =
    \\Usage: ztrue [ignored command line arguments]
    \\  or:  ztrue OPTION
    \\Exit with a status code indicating success.
    \\
    \\      --help        display this help and exit
    \\      --version     output version information and exit
    \\
    \\Your shell may have its own version of true, which usually supersedes
    \\the version described here.  Please refer to your shell's documentation
    \\for details about the options it supports.
    \\
;

const version_text =
    \\ztrue (zig_core_utils) 1.0
    \\GNU true compatible.
    \\
;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args into a slice.
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        // On OOM, fall through to the always-success exit; `true` never
        // depends on its arguments for its exit status.
        args_list.append(allocator, arg) catch break;
    }
    const args = args_list.items;

    // GNU honors --help/--version only when it is the SOLE operand
    // (coreutils true.c: the `argc == 2` guard). Anything else is ignored.
    if (args.len == 2) {
        const only = args[1];
        if (std.mem.eql(u8, only, "--help") or std.mem.eql(u8, only, "--version")) {
            const io = Io.Threaded.global_single_threaded.io();
            const stdout = Io.File.stdout();
            var buf: [4096]u8 = undefined;
            var writer = stdout.writerStreaming(io, &buf);
            const text = if (only[2] == 'h') help_text else version_text;
            writer.interface.writeAll(text) catch {};
            writer.interface.flush() catch {};
        }
    }

    // `true` ALWAYS succeeds — including after printing --help/--version.
    std.process.exit(0);
}
