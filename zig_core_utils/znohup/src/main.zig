const std = @import("std");
const posix = std.posix;
const libc = std.c;

const SIGHUP: c_int = 1;

const SigHandler = ?*align(1) const fn (c_int) callconv(.c) void;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn signal(sig: c_int, handler: SigHandler) SigHandler;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);

    while (args.next()) |arg| {
        if (cmd_args.items.len == 0) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: znohup COMMAND [ARG]...
                    \\  or:  znohup OPTION
                    \\Run COMMAND, ignoring hangup signals.
                    \\
                    \\      --help     display this help and exit
                    \\
                    \\If standard input is a terminal, redirect it from an unreadable file.
                    \\If standard output is a terminal, append output to 'nohup.out' if possible,
                    \\'$HOME/nohup.out' otherwise.
                    \\If standard error is a terminal, redirect it to standard output.
                    \\
                ;
                _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
                return;
            }
        }
        try cmd_args.append(allocator, arg);
    }

    if (cmd_args.items.len == 0) {
        writeErr("znohup: missing operand\n");
        std.process.exit(125);
    }

    // Ignore SIGHUP using signal(SIGHUP, SIG_IGN)
    const SIG_IGN: SigHandler = @ptrFromInt(1);
    _ = signal(SIGHUP, SIG_IGN);

    // Handle stdin - redirect from /dev/null if it's a terminal
    if (isatty(posix.STDIN_FILENO) != 0) {
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
        var fd = libc.open("nohup.out", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(libc.mode_t, 0o600));
        if (fd < 0) {
            // Try $HOME/nohup.out - get HOME from environment
            const home = std.c.getenv("HOME");
            if (home) |h| {
                const home_span = std.mem.span(h);
                var path_buf: [4096]u8 = undefined;
                if (home_span.len + 11 < path_buf.len) {
                    @memcpy(path_buf[0..home_span.len], home_span);
                    @memcpy(path_buf[home_span.len..][0..11], "/nohup.out\x00");
                    fd = libc.open(@ptrCast(&path_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(libc.mode_t, 0o600));
                    if (fd >= 0) {
                        writeErr("znohup: appending output to '");
                        writeErr(home_span);
                        writeErr("/nohup.out'\n");
                    }
                }
            }
        } else {
            writeErr("znohup: appending output to 'nohup.out'\n");
        }

        if (fd >= 0) {
            _ = dup2(fd, posix.STDOUT_FILENO);
            _ = libc.close(fd);
            stdout_redirected = true;
        } else {
            writeErr("znohup: failed to open nohup.out\n");
            std.process.exit(125);
        }
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

    // exec failed
    writeErr("znohup: failed to run command '");
    writeErr(cmd_args.items[0]);
    writeErr("'\n");

    // Check if command exists
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..cmd_args.items[0].len], cmd_args.items[0]);
    path_buf[cmd_args.items[0].len] = 0;

    var stat_buf: [256]u8 align(8) = undefined;
    const rc = lstat(@ptrCast(&path_buf), &stat_buf);
    if (rc != 0) {
        std.process.exit(127); // Command not found
    } else {
        std.process.exit(126); // Found but cannot invoke
    }
}
