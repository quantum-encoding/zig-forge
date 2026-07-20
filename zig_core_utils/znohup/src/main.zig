const std = @import("std");
const posix = std.posix;
const libc = std.c;

const SIGHUP: c_int = 1;

const SigHandler = ?*align(1) const fn (c_int) callconv(.c) void;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn signal(sig: c_int, handler: SigHandler) SigHandler;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeOut(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);

    // Options are only recognized before the command; a leading `--` ends
    // option processing (GNU getopt "+" / POSIXLY_CORRECT semantics).
    var end_of_options = false;
    while (args.next()) |arg| {
        if (cmd_args.items.len == 0 and !end_of_options) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: znohup COMMAND [ARG]...
                    \\  or:  znohup OPTION
                    \\Run COMMAND, ignoring hangup signals.
                    \\
                    \\      --help     display this help and exit
                    \\      --version  output version information and exit
                    \\
                    \\If standard input is a terminal, redirect it from an unreadable file.
                    \\If standard output is a terminal, append output to 'nohup.out' if possible,
                    \\'$HOME/nohup.out' otherwise.
                    \\If standard error is a terminal, redirect it to standard output.
                    \\
                ;
                writeOut(help);
                return;
            }
            if (std.mem.eql(u8, arg, "--version")) {
                writeOut("znohup (zig-forge coreutils) 0.1.0\n");
                return;
            }
            if (std.mem.eql(u8, arg, "--")) {
                end_of_options = true;
                continue;
            }
        }
        try cmd_args.append(allocator, arg);
    }

    if (cmd_args.items.len == 0) {
        writeErr("znohup: missing operand\n");
        writeErr("Try 'znohup --help' for more information.\n");
        std.process.exit(125);
    }

    // Ignore SIGHUP using signal(SIGHUP, SIG_IGN)
    const SIG_IGN: SigHandler = @ptrFromInt(1);
    _ = signal(SIGHUP, SIG_IGN);

    // Handle stdin - redirect from /dev/null if it's a terminal
    var stdin_was_tty = false;
    if (isatty(posix.STDIN_FILENO) != 0) {
        stdin_was_tty = true;
        const fd = libc.open("/dev/null", .{}, @as(libc.mode_t, 0));
        if (fd >= 0) {
            _ = dup2(fd, posix.STDIN_FILENO);
            _ = libc.close(fd);
        }
    }

    // Handle stdout - redirect to nohup.out if it's a terminal
    var stdout_redirected = false;
    if (isatty(posix.STDOUT_FILENO) != 0) {
        // Try nohup.out in current directory first
        var used_home = false;
        var home_span: []const u8 = &.{};
        var path_buf: [4096]u8 = undefined;

        var fd = libc.open("nohup.out", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) {
            // Try $HOME/nohup.out - get HOME from environment
            const home = std.c.getenv("HOME");
            if (home) |h| {
                home_span = std.mem.span(h);
                if (home_span.len + 11 < path_buf.len) {
                    @memcpy(path_buf[0..home_span.len], home_span);
                    @memcpy(path_buf[home_span.len..][0..11], "/nohup.out\x00");
                    fd = libc.open(@ptrCast(&path_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(libc.mode_t, 0o600));
                    if (fd >= 0) used_home = true;
                }
            }
        }

        if (fd >= 0) {
            // GNU nohup diagnostic: "ignoring input and " prefix only when
            // stdin was also a terminal (coreutils src/nohup.c).
            writeErr("znohup: ");
            if (stdin_was_tty) {
                writeErr("ignoring input and appending output to '");
            } else {
                writeErr("appending output to '");
            }
            if (used_home) {
                writeErr(home_span);
                writeErr("/nohup.out'\n");
            } else {
                writeErr("nohup.out'\n");
            }
            _ = dup2(fd, posix.STDOUT_FILENO);
            _ = libc.close(fd);
            stdout_redirected = true;
        } else {
            writeErr("znohup: failed to open nohup.out\n");
            std.process.exit(125);
        }
    } else if (stdin_was_tty) {
        // stdin redirected but stdout is not a terminal: GNU still reports it.
        writeErr("znohup: ignoring input\n");
    }

    // Handle stderr - redirect to stdout if it's a terminal
    if (isatty(posix.STDERR_FILENO) != 0) {
        _ = dup2(posix.STDOUT_FILENO, posix.STDERR_FILENO);
        if (stdout_redirected) {
            // Message already shown
        }
    }

    // Build argv for execvp
    var argv_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv_buf.deinit(allocator);

    for (cmd_args.items) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);
    const cmd_z = try allocator.dupeZ(u8, cmd_args.items[0]);

    _ = execvp(cmd_z.ptr, argv);

    // exec failed: capture errno immediately so nothing below clobbers it.
    const err = libc._errno().*;

    // GNU emits: "nohup: failed to run command 'X': <strerror>\n"
    writeErr("znohup: failed to run command '");
    writeErr(cmd_args.items[0]);
    writeErr("': ");
    writeErr(std.mem.span(strerror(err)));
    writeErr("\n");

    // Exit status keys off the execvp errno exactly like GNU nohup:
    // ENOENT -> 127 (not found), anything else -> 126 (found, not invocable).
    if (err == @intFromEnum(std.c.E.NOENT)) {
        std.process.exit(127);
    } else {
        std.process.exit(126);
    }
}
