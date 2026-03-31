//! zgroups - Print group memberships
//!
//! Print the groups a user belongs to.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn getuid() u32;
extern "c" fn getgid() u32;
extern "c" fn getpwnam(name: [*:0]const u8) ?*Passwd;
extern "c" fn getpwuid(uid: u32) ?*Passwd;
extern "c" fn getgrgid(gid: u32) ?*Group;
extern "c" fn getgrouplist(user: [*:0]const u8, group: u32, groups: [*]u32, ngroups: *c_int) c_int;
extern "c" fn getgroups(size: c_int, list: [*]u32) c_int;

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

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zgroups [OPTION]... [USERNAME]...
        \\Print group memberships for each USERNAME or, if no USERNAME is specified,
        \\for the current process.
        \\
        \\Options:
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zgroups " ++ VERSION ++ "\n");
}

fn getGroupName(gid: u32, buf: []u8) []const u8 {
    if (getgrgid(gid)) |grp| {
        if (grp.gr_name) |name| {
            return std.mem.span(name);
        }
    }
    // Fallback to numeric
    return std.fmt.bufPrint(buf, "{d}", .{gid}) catch "?";
}

fn printGroups(username: ?[]const u8) bool {
    var name_buf: [256]u8 = undefined;
    var name_z: [*:0]const u8 = undefined;
    var primary_gid: u32 = undefined;

    if (username) |user| {
        const user_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{user}) catch {
            writeStderr("zgroups: user name too long\n");
            return false;
        };
        name_z = user_z;

        const pw = getpwnam(user_z) orelse {
            writeStderr("zgroups: '");
            writeStderr(user);
            writeStderr("': no such user\n");
            return false;
        };
        primary_gid = pw.pw_gid;
    } else {
        // Current user
        const uid = getuid();
        const pw = getpwuid(uid) orelse {
            writeStderr("zgroups: cannot find current user\n");
            return false;
        };
        if (pw.pw_name) |name| {
            name_z = name;
        } else {
            writeStderr("zgroups: cannot find current user\n");
            return false;
        }
        primary_gid = pw.pw_gid;
    }

    // Get group list
    var groups: [128]u32 = undefined;
    var ngroups: c_int = undefined;

    if (username == null) {
        // For current user, use getgroups() to match GNU ordering
        ngroups = getgroups(128, &groups);
        if (ngroups < 0) {
            writeStderr("zgroups: cannot get group list\n");
            return false;
        }
        // primary_gid used in print loop below
    } else {
        ngroups = 128;
        if (getgrouplist(name_z, primary_gid, &groups, &ngroups) < 0) {
            writeStderr("zgroups: cannot get group list\n");
            return false;
        }
    }

    // Print username if specified
    if (username) |user| {
        writeStdout(user);
        writeStdout(" : ");
    }

    // Print groups - primary group first, then supplementary in getgroups() order
    var gid_buf: [16]u8 = undefined;
    writeStdout(getGroupName(primary_gid, &gid_buf));
    var i: usize = 0;
    while (i < @as(usize, @intCast(ngroups))) : (i += 1) {
        if (groups[i] == primary_gid) continue;
        writeStdout(" ");
        writeStdout(getGroupName(groups[i], &gid_buf));
    }
    writeStdout("\n");

    return true;
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var users_found = false;
    var exit_code: u8 = 0;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (arg.len > 0 and arg[0] != '-') {
            users_found = true;
            if (!printGroups(arg)) {
                exit_code = 1;
            }
        }
    }

    if (!users_found) {
        if (!printGroups(null)) {
            exit_code = 1;
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
