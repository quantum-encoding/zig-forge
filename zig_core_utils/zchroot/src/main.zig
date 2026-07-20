const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *anyopaque) c_int;
extern "c" fn chroot(path: [*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setgroups(size: c_uint, list: [*]const u32) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn getpwnam(name: [*:0]const u8) ?*anyopaque;
extern "c" fn getgrnam(name: [*:0]const u8) ?*anyopaque;

fn writeOut(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeErr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

/// GNU coreutils appends this line after most usage/option errors.
fn tryHelp() void {
    writeErr("Try 'zchroot --help' for more information.\n");
}

fn errnoValue() c_int {
    return std.c._errno().*;
}

fn strerrorSlice(e: c_int) []const u8 {
    return std.mem.span(strerror(e));
}

// struct passwd / struct group share the same first-fields layout across
// macOS and glibc: two `char *` pointers (16 bytes on LP64) precede the id.
//   passwd: pw_name(0) pw_passwd(8) pw_uid(16) pw_gid(20)
//   group : gr_name(0) gr_passwd(8) gr_gid(16)
fn pwUid(pw: *anyopaque) u32 {
    const base: [*]const u8 = @ptrCast(pw);
    return @as(*align(1) const u32, @ptrCast(base + 16)).*;
}
fn pwGid(pw: *anyopaque) u32 {
    const base: [*]const u8 = @ptrCast(pw);
    return @as(*align(1) const u32, @ptrCast(base + 20)).*;
}
fn grGid(gr: *anyopaque) u32 {
    const base: [*]const u8 = @ptrCast(gr);
    return @as(*align(1) const u32, @ptrCast(base + 16)).*;
}

const Resolved = union(enum) {
    id: u32,
    /// numeric parse failed AND the name is unknown to the host database.
    not_found,
};

/// Resolve a user spec token to a uid: numeric first, then getpwnam.
/// Also yields the user's primary gid when the token was a name (for the
/// GNU default-group behavior).
const UserResult = struct { res: Resolved, primary_gid: ?u32 = null };

fn resolveUser(allocator: std.mem.Allocator, s: []const u8) UserResult {
    if (std.fmt.parseInt(u32, s, 10)) |uid| {
        return .{ .res = .{ .id = uid } };
    } else |_| {}
    const z = allocator.dupeZ(u8, s) catch return .{ .res = .not_found };
    if (getpwnam(z.ptr)) |pw| {
        return .{ .res = .{ .id = pwUid(pw) }, .primary_gid = pwGid(pw) };
    }
    return .{ .res = .not_found };
}

fn resolveGroup(allocator: std.mem.Allocator, s: []const u8) Resolved {
    if (std.fmt.parseInt(u32, s, 10)) |gid| {
        return .{ .id = gid };
    } else |_| {}
    const z = allocator.dupeZ(u8, s) catch return .not_found;
    if (getgrnam(z.ptr)) |gr| {
        return .{ .id = grGid(gr) };
    }
    return .not_found;
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
                    \\      --version              output version information and exit
                    \\
                    \\If no command is given, run '"$SHELL" -i' (default: '/bin/sh -i').
                    \\
                ;
                writeOut(help);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                // GNU parity: --version prints version info and exits 0.
                writeOut("zchroot (zig_core_utils) 1.0\n");
                return;
            } else if (std.mem.eql(u8, arg, "--skip-chdir")) {
                skip_chdir = true;
            } else if (std.mem.startsWith(u8, arg, "--userspec=")) {
                userspec = arg[11..];
            } else if (std.mem.startsWith(u8, arg, "--groups=")) {
                groups = arg[9..];
            } else if (std.mem.eql(u8, arg, "--")) {
                // End of options. The NEXT operand is still NEWROOT — do not
                // let `--` swallow it (GNU treats `chroot -- NEWROOT CMD` as
                // valid). Fall through to operand handling below.
                parsing_opts = false;
                continue;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                writeErr("zchroot: unrecognized option '");
                writeErr(arg);
                writeErr("'\n");
                tryHelp();
                std.process.exit(125);
            } else if (arg.len > 1 and arg[0] == '-') {
                // GNU getopt reports the first offending short-option char.
                writeErr("zchroot: invalid option -- '");
                writeErr(arg[1..2]);
                writeErr("'\n");
                tryHelp();
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
            if (newroot == null) {
                newroot = arg;
            } else {
                try cmd_args.append(allocator, arg);
            }
        }
    }

    if (newroot == null) {
        writeErr("zchroot: missing operand\n");
        tryHelp();
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

    // Perform chroot. On failure print the REAL errno (GNU uses strerror),
    // matching GNU wording "cannot change root directory to '...'".
    if (chroot(@ptrCast(&root_buf)) != 0) {
        const e = errnoValue();
        writeErr("zchroot: cannot change root directory to '");
        writeErr(root);
        writeErr("': ");
        writeErr(strerrorSlice(e));
        writeErr("\n");
        std.process.exit(125);
    }

    // Change to / unless --skip-chdir
    if (!skip_chdir) {
        if (chdir("/") != 0) {
            const e = errnoValue();
            writeErr("zchroot: cannot chdir to root directory: ");
            writeErr(strerrorSlice(e));
            writeErr("\n");
            std.process.exit(125);
        }
    }

    // --- Drop privileges (after chroot, before exec) ---------------------
    // GNU applies, in order: supplementary groups, then gid, then uid, and
    // ABORTS (exit 125) if any of the three syscalls fails. A silently
    // ignored failure would leave the command running as root.
    var empty_groups: [1]u32 = undefined; // valid pointer for setgroups(0, .)
    var have_explicit_groups = false;

    if (groups) |g| {
        have_explicit_groups = true;
        var gids = std.ArrayListUnmanaged(u32).empty;
        defer gids.deinit(allocator);

        if (g.len > 0) {
            var iter = std.mem.splitScalar(u8, g, ',');
            while (iter.next()) |gid_str| {
                switch (resolveGroup(allocator, gid_str)) {
                    .id => |gid| try gids.append(allocator, gid),
                    .not_found => {
                        writeErr("zchroot: invalid group '");
                        writeErr(gid_str);
                        writeErr("'\n");
                        std.process.exit(125);
                    },
                }
            }
        }

        const list_ptr: [*]const u32 = if (gids.items.len > 0) gids.items.ptr else &empty_groups;
        if (setgroups(@intCast(gids.items.len), list_ptr) != 0) {
            const e = errnoValue();
            writeErr("zchroot: failed to set supplemental groups: ");
            writeErr(strerrorSlice(e));
            writeErr("\n");
            std.process.exit(125);
        }
    }

    if (userspec) |spec| {
        if (spec.len > 0) {
            var uid: ?u32 = null;
            var gid: ?u32 = null;

            const colon = std.mem.indexOfScalar(u8, spec, ':');
            const user_part = if (colon) |c| spec[0..c] else spec;
            const group_part: ?[]const u8 = if (colon) |c| spec[c + 1 ..] else null;

            if (user_part.len > 0) {
                const ur = resolveUser(allocator, user_part);
                switch (ur.res) {
                    .id => |u| uid = u,
                    .not_found => {
                        writeErr("zchroot: invalid user '");
                        writeErr(user_part);
                        writeErr("'\n");
                        std.process.exit(125);
                    },
                }
                // A username with no explicit group defaults to its primary gid.
                if (group_part == null or group_part.?.len == 0) {
                    gid = ur.primary_gid;
                }
            }

            if (group_part) |gp| {
                if (gp.len > 0) {
                    switch (resolveGroup(allocator, gp)) {
                        .id => |gval| gid = gval,
                        .not_found => {
                            writeErr("zchroot: invalid group '");
                            writeErr(gp);
                            writeErr("'\n");
                            std.process.exit(125);
                        },
                    }
                }
            }

            // Clear root's inherited supplementary groups when dropping the
            // uid without an explicit --groups list (GNU never leaves root's
            // groups on the target process). setgroups MUST run before setuid.
            if (!have_explicit_groups) {
                const rc = if (gid) |gg| blk: {
                    var one = [_]u32{gg};
                    break :blk setgroups(1, &one);
                } else setgroups(0, &empty_groups);
                if (rc != 0) {
                    const e = errnoValue();
                    writeErr("zchroot: failed to set supplemental groups: ");
                    writeErr(strerrorSlice(e));
                    writeErr("\n");
                    std.process.exit(125);
                }
            }

            if (gid) |gg| {
                if (libc.setgid(gg) != 0) {
                    const e = errnoValue();
                    writeErr("zchroot: failed to set group-ID: ");
                    writeErr(strerrorSlice(e));
                    writeErr("\n");
                    std.process.exit(125);
                }
            }
            if (uid) |uu| {
                if (libc.setuid(uu) != 0) {
                    const e = errnoValue();
                    writeErr("zchroot: failed to set user-ID: ");
                    writeErr(strerrorSlice(e));
                    writeErr("\n");
                    std.process.exit(125);
                }
            }
        }
    }

    // Default command: honor $SHELL, falling back to /bin/sh (GNU parity).
    if (cmd_args.items.len == 0) {
        const shell: []const u8 = if (libc.getenv("SHELL")) |s| std.mem.span(s) else "/bin/sh";
        try cmd_args.append(allocator, shell);
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

    // Use the already-NUL-terminated heap copy (cmd_z) for the stat probe —
    // no fixed stack buffer, so an oversized argv[0] can't overflow.
    var stat_buf: [256]u8 align(8) = undefined;
    const rc = lstat(cmd_z.ptr, &stat_buf);
    if (rc != 0) {
        std.process.exit(127);
    } else {
        std.process.exit(126);
    }
}
