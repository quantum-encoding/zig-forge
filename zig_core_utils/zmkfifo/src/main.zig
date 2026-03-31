//! zmkfifo - Create named pipes (FIFOs)
//!
//! High-performance mkfifo implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn umask(mask: c_uint) c_uint;

const Config = struct {
    mode: c_uint = 0o666,
    names: [64][]const u8 = undefined,
    name_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zmkfifo [OPTION]... NAME...
        \\Create named pipes (FIFOs) with the given NAMEs.
        \\
        \\Options:
        \\  -m, --mode=MODE   Set file permission bits (default: 0666 minus umask)
        \\      --help        Display this help and exit
        \\      --version     Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zmkfifo " ++ VERSION ++ "\n");
}

fn parseOctal(s: []const u8) ?c_uint {
    var result: c_uint = 0;
    for (s) |c| {
        if (c >= '0' and c <= '7') {
            result = result * 8 + (c - '0');
        } else {
            return null;
        }
    }
    return result;
}

fn createFifo(name: []const u8, mode: c_uint) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{name}) catch {
        writeStderr("zmkfifo: path too long: ");
        writeStderr(name);
        writeStderr("\n");
        return false;
    };

    if (mkfifo(path_z, mode) != 0) {
        writeStderr("zmkfifo: cannot create fifo '");
        writeStderr(name);
        writeStderr("'");

        const errno = std.c._errno().*;
        if (errno == 17) { // EEXIST
            writeStderr(": File exists\n");
        } else if (errno == 2) { // ENOENT
            writeStderr(": No such file or directory\n");
        } else if (errno == 13) { // EACCES
            writeStderr(": Permission denied\n");
        } else if (errno == 28) { // ENOSPC
            writeStderr(": No space left on device\n");
        } else {
            writeStderr("\n");
        }
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-m")) {
            if (args_iter.next()) |mode_arg| {
                if (parseOctal(mode_arg)) |m| {
                    cfg.mode = m;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            if (parseOctal(arg[7..])) |m| {
                cfg.mode = m;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.name_count < cfg.names.len) {
                cfg.names[cfg.name_count] = arg;
                cfg.name_count += 1;
            }
        }
    }

    if (cfg.name_count == 0) {
        writeStderr("zmkfifo: missing operand\n");
        writeStderr("Try 'zmkfifo --help' for more information.\n");
        std.process.exit(1);
    }

    // Get current umask
    const old_umask = umask(0);
    _ = umask(old_umask);

    const effective_mode = cfg.mode & ~old_umask;

    var exit_code: u8 = 0;
    for (cfg.names[0..cfg.name_count]) |name| {
        if (!createFifo(name, effective_mode)) {
            exit_code = 1;
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
