const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn chroot(path: [*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setgroups(size: c_uint, list: [*]const u32) c_int;

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn parseUid(s: []const u8) ?u32 {
    // Try parsing as number first
    if (std.fmt.parseInt(u32, s, 10)) |uid| {
        return uid;
    } else |_| {}

    // Would need to read /etc/passwd for name lookup
    // For simplicity, only support numeric IDs
    return null;
}

fn parseGid(s: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, s, 10)) |gid| {
        return gid;
    } else |_| {}
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var newroot: ?[]const u8 = null;
    var userspec: ?[]const u8 = null;
    var groups: ?[]const u8 = null;
    var skip_chdir = false;
    var cmd_args = std.ArrayListUnmanaged([]const u8).empty;
    defer cmd_args.deinit(allocator);
    var parsing_opts = true;

    while (args.next()) |arg| {
        if (parsing_opts) {
            if (std.mem.eql(u8, arg, "--help")) {
                const help =
                    \\Usage: zchroot [OPTION]... NEWROOT [COMMAND [ARG]...]
                    \\Run COMMAND with root directory set to NEWROOT.
                    \\
                    \\      --groups=G_LIST        specify supplementary groups as g1,g2,..,gN
                    \\      --userspec=USER:GROUP  specify user and group (ID or name) to use
                    \\      --skip-chdir           do not change working directory to '/'
                    \\      --help                 display this help and exit
                    \\
                    \\If no command is given, run '/bin/sh -i'.
                    \\
                ;
                _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
                return;
            } else if (std.mem.eql(u8, arg, "--skip-chdir")) {
                skip_chdir = true;
            } else if (std.mem.startsWith(u8, arg, "--userspec=")) {
                userspec = arg[11..];
            } else if (std.mem.startsWith(u8, arg, "--groups=")) {
                groups = arg[9..];
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_opts = false;
            } else if (arg.len > 0 and arg[0] == '-') {
                writeErr("zchroot: invalid option '");
                writeErr(arg);
                writeErr("'\n");
                std.process.exit(125);
            } else {
                if (newroot == null) {
                    newroot = arg;
                } else {
                    try cmd_args.append(allocator, arg);
                }
                parsing_opts = false;
            }
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    if (newroot == null) {
        writeErr("zchroot: missing operand\n");
        std.process.exit(125);
    }

    const root = newroot.?;

    // Null-terminate the path
    var root_buf: [4096]u8 = undefined;
    if (root.len >= root_buf.len) {
        writeErr("zchroot: path too long\n");
        std.process.exit(125);
    }
    @memcpy(root_buf[0..root.len], root);
    root_buf[root.len] = 0;

    // Perform chroot
    if (chroot(@ptrCast(&root_buf)) != 0) {
        writeErr("zchroot: cannot chroot to '");
        writeErr(root);
        writeErr("': Operation not permitted\n");
        std.process.exit(125);
    }

    // Change to / unless --skip-chdir
    if (!skip_chdir) {
        if (chdir("/") != 0) {
            writeErr("zchroot: cannot chdir to '/'\n");
            std.process.exit(125);
        }
    }

    // Handle --groups
    if (groups) |g| {
        var gids: [64]u32 = undefined;
        var gid_count: usize = 0;

        var iter = std.mem.splitScalar(u8, g, ',');
        while (iter.next()) |gid_str| {
            if (parseGid(gid_str)) |gid| {
                if (gid_count < gids.len) {
                    gids[gid_count] = gid;
                    gid_count += 1;
                }
            }
        }

        if (gid_count > 0) {
            _ = setgroups(@intCast(gid_count), &gids);
        }
    }

    // Handle --userspec=USER:GROUP
    if (userspec) |spec| {
        var uid: ?u32 = null;
        var gid: ?u32 = null;

        if (std.mem.indexOf(u8, spec, ":")) |colon| {
            uid = parseUid(spec[0..colon]);
            gid = parseGid(spec[colon + 1 ..]);
        } else {
            uid = parseUid(spec);
        }

        if (gid) |g| {
            _ = libc.setgid(g);
        }
        if (uid) |u| {
            _ = libc.setuid(u);
        }
    }

    // Default command is /bin/sh -i
    if (cmd_args.items.len == 0) {
        try cmd_args.append(allocator, "/bin/sh");
        try cmd_args.append(allocator, "-i");
    }

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
    writeErr("zchroot: failed to run command '");
    writeErr(cmd_args.items[0]);
    writeErr("'\n");

    var cmd_path_buf: [4096]u8 = undefined;
    @memcpy(cmd_path_buf[0..cmd_args.items[0].len], cmd_args.items[0]);
    cmd_path_buf[cmd_args.items[0].len] = 0;

    var stat_buf: [256]u8 align(8) = undefined;
    const rc = lstat(@ptrCast(&cmd_path_buf), &stat_buf);
    if (rc != 0) {
        std.process.exit(127);
    } else {
        std.process.exit(126);
    }
}
