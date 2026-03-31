const std = @import("std");
const libc = std.c;

extern "c" fn gethostname(name: [*]u8, len: usize) c_int;
extern "c" fn sethostname(name: [*]const u8, len: usize) c_int;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var short_name = false;
    var new_hostname: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zhostname [OPTION]... [NAME]
                \\Print or set the system hostname.
                \\
                \\  -s, --short    short hostname (up to first dot)
                \\      --help     display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--short")) {
            short_name = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            new_hostname = arg;
        }
    }

    if (new_hostname) |name| {
        // Set hostname (requires root)
        if (sethostname(name.ptr, name.len) != 0) {
            const msg = "zhostname: cannot set hostname (permission denied?)\n";
            _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        }
        return;
    }

    // Get hostname
    var buf: [256]u8 = undefined;
    if (gethostname(&buf, buf.len) != 0) {
        const msg = "zhostname: cannot get hostname\n";
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    }

    const name = std.mem.sliceTo(&buf, 0);
    var output = name;
    if (short_name) {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            output = name[0..dot];
        }
    }

    _ = libc.write(libc.STDOUT_FILENO, output.ptr, output.len);
    const newline = "\n";
    _ = libc.write(libc.STDOUT_FILENO, newline.ptr, newline.len);
}
