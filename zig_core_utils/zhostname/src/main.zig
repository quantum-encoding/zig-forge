const std = @import("std");
const libc = std.c;

extern "c" fn gethostname(name: [*]u8, len: usize) c_int;
extern "c" fn sethostname(name: [*]const u8, len: usize) c_int;

fn writeErr(s: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, s.ptr, s.len);
}

fn writeOut(s: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, s.ptr, s.len);
}

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
                \\      --version  output version information and exit
                \\
            ;
            writeOut(help);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const version = "zhostname (zig_core_utils) 1.0\n";
            writeOut(version);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--short")) {
            short_name = true;
        } else if (arg.len > 0 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            // Unknown option: GNU hostname rejects it and exits 1 rather than
            // silently ignoring it. A bare "-" is not an option (treated below
            // as a positional, matching getopt convention).
            writeErr("zhostname: unrecognized option '");
            writeErr(arg);
            writeErr("'\nTry 'zhostname --help' for more information.\n");
            std.process.exit(1);
        } else {
            // Positional NAME operand. GNU hostname accepts at most one; extra
            // operands are an error (it does NOT silently use the last).
            if (new_hostname != null) {
                writeErr("zhostname: too many arguments\n");
                std.process.exit(1);
            }
            new_hostname = arg;
        }
    }

    if (new_hostname) |name| {
        // Set hostname (requires root)
        if (sethostname(name.ptr, name.len) != 0) {
            const msg = "zhostname: cannot set hostname (permission denied?)\n";
            writeErr(msg);
            std.process.exit(1);
        }
        return;
    }

    // Get hostname.
    //
    // POSIX/BSD gethostname may silently truncate and NOT NUL-terminate when
    // the hostname is >= len. Zero-initialize the buffer and reserve the final
    // byte as a guaranteed terminator (pass buf.len - 1), so std.mem.sliceTo
    // can never scan past the buffer into adjacent stack memory.
    var buf: [257]u8 = [_]u8{0} ** 257;
    if (gethostname(&buf, buf.len - 1) != 0) {
        const msg = "zhostname: cannot get hostname\n";
        writeErr(msg);
        std.process.exit(1);
    }
    buf[buf.len - 1] = 0; // belt-and-braces terminator

    const name = std.mem.sliceTo(&buf, 0);
    var output = name;
    if (short_name) {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            output = name[0..dot];
        }
    }

    writeOut(output);
    writeOut("\n");
}
