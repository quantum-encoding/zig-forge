//! zmknod - Create special files
//!
//! Create block/character special files and FIFOs.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn mknod(path: [*:0]const u8, mode: c_uint, dev: u64) c_int;
extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn umask(mask: c_uint) c_uint;

// File type bits
const S_IFBLK: c_uint = 0o060000; // Block special
const S_IFCHR: c_uint = 0o020000; // Character special
const S_IFIFO: c_uint = 0o010000; // FIFO

const NodeType = enum { block, char, fifo };

const Config = struct {
    node_type: ?NodeType = null,
    mode: c_uint = 0o666,
    name: ?[]const u8 = null,
    major: ?u32 = null,
    minor: ?u32 = null,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zmknod [OPTION]... NAME TYPE [MAJOR MINOR]
        \\Create the special file NAME of the given TYPE.
        \\
        \\TYPE is one of:
        \\  b      Create a block special file
        \\  c, u   Create a character special file
        \\  p      Create a FIFO (named pipe)
        \\
        \\MAJOR and MINOR are required for block and character devices.
        \\
        \\Options:
        \\  -m, --mode=MODE   Set file permission bits (as in chmod)
        \\      --help        Display this help and exit
        \\      --version     Output version information and exit
        \\
        \\Examples:
        \\  zmknod myfifo p              Create a named pipe
        \\  zmknod /dev/null c 1 3       Create character device (requires root)
        \\  zmknod -m 600 mydev b 8 0    Create block device with mode 600
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zmknod " ++ VERSION ++ "\n");
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

fn parseDecimal(s: []const u8) ?u32 {
    var result: u32 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            result = result * 10 + (c - '0');
        } else {
            return null;
        }
    }
    return result;
}

fn makedev(major: u32, minor: u32) u64 {
    // Linux makedev macro
    return (@as(u64, major & 0xfff) << 8) |
        (@as(u64, major & 0xfffff000) << 32) |
        @as(u64, minor & 0xff) |
        (@as(u64, minor & 0xffffff00) << 12);
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    var positional: usize = 0;

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
            switch (positional) {
                0 => cfg.name = arg,
                1 => {
                    if (arg.len > 0) {
                        cfg.node_type = switch (arg[0]) {
                            'b' => .block,
                            'c', 'u' => .char,
                            'p' => .fifo,
                            else => null,
                        };
                    }
                },
                2 => cfg.major = parseDecimal(arg),
                3 => cfg.minor = parseDecimal(arg),
                else => {},
            }
            positional += 1;
        }
    }

    // Validate arguments
    if (cfg.name == null) {
        writeStderr("zmknod: missing operand\n");
        writeStderr("Try 'zmknod --help' for more information.\n");
        std.process.exit(1);
    }

    if (cfg.node_type == null) {
        writeStderr("zmknod: missing file type\n");
        std.process.exit(1);
    }

    const node_type = cfg.node_type.?;

    // Block and char devices require major/minor
    if (node_type == .block or node_type == .char) {
        if (cfg.major == null or cfg.minor == null) {
            writeStderr("zmknod: ");
            if (node_type == .block) {
                writeStderr("block");
            } else {
                writeStderr("character");
            }
            writeStderr(" special files require major and minor device numbers\n");
            std.process.exit(1);
        }
    }

    // Create the node
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{cfg.name.?}) catch {
        writeStderr("zmknod: path too long\n");
        std.process.exit(1);
    };

    // Get current umask and restore it
    const old_umask = umask(0);
    _ = umask(old_umask);

    const effective_mode = cfg.mode & ~old_umask;

    const result: c_int = switch (node_type) {
        .fifo => mkfifo(path_z, effective_mode),
        .block => mknod(path_z, S_IFBLK | effective_mode, makedev(cfg.major.?, cfg.minor.?)),
        .char => mknod(path_z, S_IFCHR | effective_mode, makedev(cfg.major.?, cfg.minor.?)),
    };

    if (result != 0) {
        writeStderr("zmknod: cannot create '");
        writeStderr(cfg.name.?);
        writeStderr("'");

        // Common error messages
        const errno = std.c._errno().*;
        if (errno == 1) { // EPERM
            writeStderr(": Operation not permitted (requires root for device nodes)\n");
        } else if (errno == 17) { // EEXIST
            writeStderr(": File exists\n");
        } else if (errno == 2) { // ENOENT
            writeStderr(": No such file or directory\n");
        } else {
            writeStderr("\n");
        }
        std.process.exit(1);
    }
}
