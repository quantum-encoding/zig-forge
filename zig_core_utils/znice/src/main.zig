const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn getpriority(which: c_int, who: c_uint) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

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

    var adjustment: i32 = 10; // Default adjustment
    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);
    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: znice [OPTION] [COMMAND [ARG]...]
                    \\Run COMMAND with an adjusted niceness, which affects process scheduling.
                    \\With no COMMAND, print the current niceness.  Niceness values range from
                    \\-20 (most favorable to the process) to 19 (least favorable to the process).
                    \\
                    \\  -n, --adjustment=N   add integer N to the niceness (default 10)
                    \\      --help           display this help and exit
                    \\
                ;
                writeOut(help);
                return;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else if (std.mem.eql(u8, arg, "-n")) {
                if (args.next()) |val| {
                    adjustment = std.fmt.parseInt(i32, val, 10) catch 10;
                }
            } else if (std.mem.startsWith(u8, arg, "-n")) {
                adjustment = std.fmt.parseInt(i32, arg[2..], 10) catch 10;
            } else if (std.mem.startsWith(u8, arg, "--adjustment=")) {
                adjustment = std.fmt.parseInt(i32, arg[13..], 10) catch 10;
            } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
                // Check if it's a negative number like "-5"
                if (std.fmt.parseInt(i32, arg, 10)) |val| {
                    adjustment = val;
                } else |_| {
                    writeErr("znice: invalid option '");
                    writeErr(arg);
                    writeErr("'\n");
                    std.process.exit(125);
                }
            } else {
                try cmd_args.append(allocator, arg);
                parsing_opts = false;
            }
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    const PRIO_PROCESS: c_int = 0;

    // No command - just print current niceness
    if (cmd_args.items.len == 0) {
        const nice_val = getpriority(PRIO_PROCESS, 0);
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{nice_val}) catch return;
        writeOut(s);
        return;
    }

    // Get current niceness and apply adjustment
    const current_nice = getpriority(PRIO_PROCESS, 0);
    var new_nice = current_nice + adjustment;
    // Clamp to valid range
    if (new_nice < -20) new_nice = -20;
    if (new_nice > 19) new_nice = 19;

    // setpriority(PRIO_PROCESS, pid=0 (self), niceval)
    _ = setpriority(PRIO_PROCESS, 0, new_nice);

    // Build argv for exec
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
    writeErr("znice: '");
    writeErr(cmd_args.items[0]);
    writeErr("': ");

    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..cmd_args.items[0].len], cmd_args.items[0]);
    path_buf[cmd_args.items[0].len] = 0;

    var stat_buf: [256]u8 align(8) = undefined;
    const rc = lstat(@ptrCast(&path_buf), &stat_buf);
    if (rc != 0) {
        writeErr("No such file or directory\n");
        std.process.exit(127);
    } else {
        writeErr("Permission denied\n");
        std.process.exit(126);
    }
}
