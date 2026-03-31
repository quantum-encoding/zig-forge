//! zprintenv - Print environment variables
//!
//! High-performance printenv implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" var environ: [*:null]?[*:0]u8;

const VERSION = "1.0.0";

const Config = struct {
    null_terminate: bool = false,
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
        \\Usage: zprintenv [OPTION]... [VARIABLE]...
        \\Print the values of the specified environment VARIABLE(s).
        \\If no VARIABLE is specified, print name and value pairs for them all.
        \\
        \\Options:
        \\  -0, --null     End each output line with NUL, not newline
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zprintenv " ++ VERSION ++ "\n");
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--null")) {
            cfg.null_terminate = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.name_count < cfg.names.len) {
                cfg.names[cfg.name_count] = arg;
                cfg.name_count += 1;
            }
        }
    }

    const terminator: []const u8 = if (cfg.null_terminate) "\x00" else "\n";

    if (cfg.name_count > 0) {
        // Print specific variables
        var exit_code: u8 = 0;
        for (cfg.names[0..cfg.name_count]) |name| {
            var name_buf: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch continue;

            if (getenv(name_z)) |value| {
                writeStdout(std.mem.span(value));
                writeStdout(terminator);
            } else {
                exit_code = 1;
            }
        }
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
    } else {
        // Print all environment variables
        var idx: usize = 0;
        while (environ[idx]) |env_var| : (idx += 1) {
            writeStdout(std.mem.span(env_var));
            writeStdout(terminator);
        }
    }
}
