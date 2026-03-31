//! zmktemp - Create temporary file or directory
//!
//! Safely create a temporary file or directory with a unique name.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_CREAT: c_int = 0o100;
const O_EXCL: c_int = 0o200;
const O_RDWR: c_int = 0o2;

const Config = struct {
    directory: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    tmpdir: ?[]const u8 = null,
    suffix: []const u8 = "",
    template: []const u8 = "tmp.XXXXXXXXXX",
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zmktemp [OPTION]... [TEMPLATE]
        \\Create a temporary file or directory, safely, and print its name.
        \\
        \\TEMPLATE must contain at least 3 consecutive 'X's in last component.
        \\If TEMPLATE is not specified, tmp.XXXXXXXXXX is used.
        \\
        \\Options:
        \\  -d, --directory     Create a directory, not a file
        \\  -u, --dry-run       Do not create anything; print name only
        \\  -q, --quiet         Suppress diagnostics about errors
        \\  -p DIR, --tmpdir=DIR  Use DIR as prefix (default: $TMPDIR or /tmp)
        \\  -t                  Interpret TEMPLATE relative to $TMPDIR
        \\      --suffix=SUFF   Append SUFF to TEMPLATE
        \\      --help          Display this help and exit
        \\      --version       Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zmktemp " ++ VERSION ++ "\n");
}

fn getRandom(buf: []u8) void {
    arc4random_buf(buf.ptr, buf.len);
}

fn getTmpDir() []const u8 {
    if (getenv("TMPDIR")) |val| {
        return std.mem.span(val);
    }
    return "/tmp";
}

fn generateName(template: []const u8, suffix: []const u8, buf: []u8) ?[]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    // Find X's in template
    var x_start: ?usize = null;
    var x_count: usize = 0;

    for (template, 0..) |c, i| {
        if (c == 'X') {
            if (x_start == null) x_start = i;
            x_count += 1;
        } else {
            if (x_count >= 3) break;
            x_start = null;
            x_count = 0;
        }
    }

    if (x_count < 3) {
        return null; // Need at least 3 X's
    }

    const start = x_start.?;

    // Copy template to buffer
    if (template.len + suffix.len >= buf.len) return null;

    @memcpy(buf[0..template.len], template);

    // Generate random characters for X's
    var rand_buf: [32]u8 = undefined;
    getRandom(rand_buf[0..x_count]);

    for (0..x_count) |i| {
        buf[start + i] = chars[rand_buf[i] % chars.len];
    }

    // Add suffix
    @memcpy(buf[template.len .. template.len + suffix.len], suffix);

    return buf[0 .. template.len + suffix.len];
}

fn createTempFile(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;

    const fd = open(path_z, O_CREAT | O_EXCL | O_RDWR, 0o600);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

fn createTempDir(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;

    return mkdir(path_z, 0o700) == 0;
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};
    var use_tmpdir_prefix = false;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--directory")) {
            cfg.directory = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--dry-run")) {
            cfg.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            cfg.quiet = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            use_tmpdir_prefix = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            if (args_iter.next()) |tmpdir_arg| {
                cfg.tmpdir = tmpdir_arg;
            }
        } else if (std.mem.startsWith(u8, arg, "--tmpdir=")) {
            cfg.tmpdir = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
            cfg.suffix = arg[9..];
        } else if (arg.len > 0 and arg[0] != '-') {
            cfg.template = arg;
        }
    }

    // Determine base directory (default to $TMPDIR or /tmp, like GNU mktemp)
    const base_dir = cfg.tmpdir orelse getTmpDir();

    // Build full template path
    var full_template_buf: [4096]u8 = undefined;
    const full_template = std.fmt.bufPrint(&full_template_buf, "{s}/{s}", .{ base_dir, cfg.template }) catch {
        if (!cfg.quiet) writeStderr("zmktemp: path too long\n");
        std.process.exit(1);
    };

    // Try to create unique file/directory (up to 100 attempts)
    var name_buf: [4096]u8 = undefined;
    var attempts: usize = 0;

    while (attempts < 100) : (attempts += 1) {
        const name = generateName(full_template, cfg.suffix, &name_buf) orelse {
            if (!cfg.quiet) {
                writeStderr("zmktemp: too few X's in template '");
                writeStderr(full_template);
                writeStderr("'\n");
            }
            std.process.exit(1);
        };

        if (cfg.dry_run) {
            writeStdout(name);
            writeStdout("\n");
            return;
        }

        const success = if (cfg.directory)
            createTempDir(name)
        else
            createTempFile(name);

        if (success) {
            writeStdout(name);
            writeStdout("\n");
            return;
        }
    }

    if (!cfg.quiet) {
        writeStderr("zmktemp: failed to create ");
        if (cfg.directory) {
            writeStderr("directory");
        } else {
            writeStderr("file");
        }
        writeStderr(" via template '");
        writeStderr(full_template);
        writeStderr("'\n");
    }
    std.process.exit(1);
}
