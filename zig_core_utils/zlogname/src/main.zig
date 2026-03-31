//! zlogname - Print the user's login name
//!
//! High-performance logname implementation in Zig.

const std = @import("std");
const libc = std.c;

extern "c" fn getlogin() ?[*:0]const u8;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help = "Usage: zlogname\nPrint the user's login name.\n";
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        }
    }

    // Use POSIX getlogin() - works on both Linux and macOS
    if (getlogin()) |name| {
        const name_slice = std.mem.span(name);
        _ = libc.write(libc.STDOUT_FILENO, name_slice.ptr, name_slice.len);
        _ = libc.write(libc.STDOUT_FILENO, "\n", 1);
        return;
    }

    _ = libc.write(libc.STDERR_FILENO, "zlogname: no login name\n", 24);
    std.process.exit(1);
}
