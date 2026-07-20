//! zfalse - do nothing, unsuccessfully
//!
//! GNU-compatible `false` (coreutils 9.10):
//!   - Always exits with status 1, regardless of arguments.
//!   - --help / --version are honored ONLY when they are the sole command-line
//!     argument (coreutils true.c/false.c: the `argc == 2` guard). In every
//!     other case (including `--help extra`, `extra --help`, `--hel`,
//!     `--help=x`, `-h`) the arguments are ignored and nothing is printed.
//!   - Even for --help/--version, `false` still exits 1 (unlike `true`, which
//!     exits 0). This is deliberate GNU behavior, verified against gfalse.
const std = @import("std");
const Io = std.Io;

const help_text =
    \\Usage: zfalse [ignored command line arguments]
    \\  or:  zfalse OPTION
    \\Exit with a status code indicating failure.
    \\
    \\      --help        display this help and exit
    \\      --version     output version information and exit
    \\
    \\Your shell may have its own version of false, which usually supersedes
    \\the version described here.  Please refer to your shell's documentation
    \\for details about the options it supports.
    \\
;

const version_text =
    \\zfalse (zig_core_utils) 1.0
    \\GNU false compatible.
    \\
;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    // Collect args into a slice.
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        // On OOM, fall through to the always-failure exit; `false` never
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

    // `false` ALWAYS fails — including after printing --help/--version.
    std.process.exit(1);
}
