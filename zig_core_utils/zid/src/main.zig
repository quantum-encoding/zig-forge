//! zid - Display user and group information
//!
//! Print user and group IDs for the current user or specified user.
//!
//! Usage: zid [OPTION]... [USER]

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// C functions for user/group lookup
extern "c" fn getuid() u32;
extern "c" fn geteuid() u32;
extern "c" fn getgid() u32;
extern "c" fn getegid() u32;
extern "c" fn getgroups(size: c_int, list: [*]u32) c_int;
extern "c" fn getgrouplist(user: [*:0]const u8, group: u32, groups: [*]u32, ngroups: *c_int) c_int;
extern "c" fn getpwuid(uid: u32) ?*Passwd;
extern "c" fn getpwnam(name: [*:0]const u8) ?*Passwd;
extern "c" fn getgrgid(gid: u32) ?*Group;
extern "c" fn getgrnam(name: [*:0]const u8) ?*Group;

const Passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

const Group = extern struct {
    gr_name: ?[*:0]const u8,
    gr_passwd: ?[*:0]const u8,
    gr_gid: u32,
    gr_mem: ?[*]?[*:0]const u8,
};

const Config = struct {
    show_user: bool = false,
    show_group: bool = false,
    show_groups: bool = false,
    show_name: bool = false,
    show_real: bool = false,
    show_zero: bool = false,
    context: bool = false,
    username: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zid [OPTION]... [USER]
        \\
        \\Print user and group information for USER, or the current user.
        \\
        \\Options:
        \\  -a             Ignored for compatibility
        \\  -g, --group    Print only the effective group ID
        \\  -G, --groups   Print all group IDs
        \\  -n, --name     Print name instead of number (with -ugG)
        \\  -r, --real     Print real ID instead of effective (with -ugG)
        \\  -u, --user     Print only the effective user ID
        \\  -z, --zero     Delimit entries with NUL, not whitespace
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
        \\Examples:
        \\  zid                  # Full info for current user
        \\  zid -u               # Effective user ID only
        \\  zid -g               # Effective group ID only
        \\  zid -G               # All group IDs
        \\  zid -un              # Effective username
        \\  zid -gn              # Effective group name
        \\  zid root             # Info for user 'root'
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zid " ++ VERSION ++ " - User/group information utility\n");
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
                config.show_user = true;
            } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--group")) {
                config.show_group = true;
            } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--groups")) {
                config.show_groups = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
                config.show_name = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--real")) {
                config.show_real = true;
            } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero")) {
                config.show_zero = true;
            } else if (std.mem.eql(u8, arg, "-a")) {
                // Ignored for compatibility
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (arg.len > 1 and arg[1] != '-') {
                // Combined short options like -un, -gn, -Gn
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'u' => config.show_user = true,
                        'g' => config.show_group = true,
                        'G' => config.show_groups = true,
                        'n' => config.show_name = true,
                        'r' => config.show_real = true,
                        'z' => config.show_zero = true,
                        'a' => {},
                        else => {
                            var err_buf: [64]u8 = undefined;
                            const err_msg = std.fmt.bufPrint(&err_buf, "zid: invalid option -- '{c}'\n", .{ch}) catch "zid: invalid option\n";
                            writeStderr(err_msg);
                            return error.InvalidOption;
                        },
                    }
                }
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zid: unrecognized option '{s}'\n", .{arg}) catch "zid: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else {
            config.username = arg;
        }
    }

    return config;
}

fn getUsername(uid: u32) ?[]const u8 {
    const pw = getpwuid(uid);
    if (pw) |p| {
        if (p.pw_name) |name| {
            return std.mem.span(name);
        }
    }
    return null;
}

fn getGroupname(gid: u32) ?[]const u8 {
    const gr = getgrgid(gid);
    if (gr) |g| {
        if (g.gr_name) |name| {
            return std.mem.span(name);
        }
    }
    return null;
}

fn printUid(uid: u32, show_name: bool) void {
    var buf: [64]u8 = undefined;
    if (show_name) {
        if (getUsername(uid)) |name| {
            writeStdout(name);
        } else {
            const s = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch return;
            writeStdout(s);
        }
    } else {
        const s = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch return;
        writeStdout(s);
    }
}

fn printGid(gid: u32, show_name: bool) void {
    var buf: [64]u8 = undefined;
    if (show_name) {
        if (getGroupname(gid)) |name| {
            writeStdout(name);
        } else {
            const s = std.fmt.bufPrint(&buf, "{d}", .{gid}) catch return;
            writeStdout(s);
        }
    } else {
        const s = std.fmt.bufPrint(&buf, "{d}", .{gid}) catch return;
        writeStdout(s);
    }
}

fn getUserGroups(target_user: ?[*:0]const u8, target_gid: u32, groups: *[64]u32) usize {
    if (target_user) |user| {
        var ngroups: c_int = 64;
        _ = getgrouplist(user, target_gid, groups, &ngroups);
        return if (ngroups > 0) @intCast(ngroups) else 0;
    } else {
        const n = getgroups(64, groups);
        return if (n > 0) @intCast(n) else 0;
    }
}

fn printFullInfo(uid: u32, gid: u32, target_user: ?[*:0]const u8) void {
    var buf: [1024]u8 = undefined;

    // uid=1000(username)
    const username = getUsername(uid);
    var pos: usize = 0;

    if (username) |name| {
        const s = std.fmt.bufPrint(&buf, "uid={d}({s}) ", .{ uid, name }) catch return;
        pos = s.len;
    } else {
        const s = std.fmt.bufPrint(&buf, "uid={d} ", .{uid}) catch return;
        pos = s.len;
    }
    writeStdout(buf[0..pos]);

    // gid=1000(groupname)
    const groupname = getGroupname(gid);
    if (groupname) |name| {
        const s = std.fmt.bufPrint(&buf, "gid={d}({s})", .{ gid, name }) catch return;
        writeStdout(s);
    } else {
        const s = std.fmt.bufPrint(&buf, "gid={d}", .{gid}) catch return;
        writeStdout(s);
    }

    // groups=...
    var groups: [64]u32 = undefined;
    const ngroups = getUserGroups(target_user, gid, &groups);

    if (ngroups > 0) {
        writeStdout(" groups=");
        var i: usize = 0;
        while (i < ngroups) : (i += 1) {
            if (i > 0) writeStdout(",");
            const g = groups[i];
            const gname = getGroupname(g);
            if (gname) |name| {
                const s = std.fmt.bufPrint(&buf, "{d}({s})", .{ g, name }) catch continue;
                writeStdout(s);
            } else {
                const s = std.fmt.bufPrint(&buf, "{d}", .{g}) catch continue;
                writeStdout(s);
            }
        }
    }

    writeStdout("\n");
}

fn printGroups(show_name: bool, delimiter: []const u8, target_user: ?[*:0]const u8, target_gid: u32) void {
    var groups: [64]u32 = undefined;
    const ngroups = getUserGroups(target_user, target_gid, &groups);

    if (ngroups > 0) {
        var i: usize = 0;
        while (i < ngroups) : (i += 1) {
            if (i > 0) writeStdout(delimiter);
            printGid(groups[i], show_name);
        }
    }
    if (delimiter[0] != 0) {
        writeStdout("\n");
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const config = parseArgs(args[1..]) catch {
        std.process.exit(1);
    };

    // Get user info
    var uid: u32 = undefined;
    var gid: u32 = undefined;

    var target_user_z: ?[*:0]const u8 = null;
    var name_buf: [256]u8 = undefined;

    if (config.username) |name| {
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch {
            writeStderr("zid: username too long\n");
            std.process.exit(1);
        };

        const pw = getpwnam(name_z.ptr);
        if (pw == null) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zid: '{s}': no such user\n", .{name}) catch "zid: no such user\n";
            writeStderr(err_msg);
            std.process.exit(1);
        }
        uid = pw.?.pw_uid;
        gid = pw.?.pw_gid;
        target_user_z = name_z.ptr;
    } else {
        uid = if (config.show_real) getuid() else geteuid();
        gid = if (config.show_real) getgid() else getegid();
    }

    const delimiter: []const u8 = if (config.show_zero) "\x00" else " ";

    // Determine output mode
    if (config.show_user) {
        printUid(uid, config.show_name);
        if (!config.show_zero) writeStdout("\n");
    } else if (config.show_group) {
        printGid(gid, config.show_name);
        if (!config.show_zero) writeStdout("\n");
    } else if (config.show_groups) {
        printGroups(config.show_name, delimiter, target_user_z, gid);
    } else {
        // Full output
        printFullInfo(uid, gid, target_user_z);
    }
}
