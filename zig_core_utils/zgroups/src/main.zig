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

/// Set when any write to stdout/stderr fails (short write, EPIPE, ...) so the
/// process can exit non-zero the way GNU coreutils does on write errors.
var write_failed: bool = false;

/// Write all bytes, looping over partial writes and retrying on EINTR. On error
/// (e.g. EPIPE from a closed pipe) set `write_failed` so main() can surface a
/// non-zero exit code the way GNU coreutils does.
fn writeAll(fd: libc.fd_t, data: []const u8) void {
    var index: usize = 0;
    while (index < data.len) {
        const n = libc.write(fd, data.ptr + index, data.len - index);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            write_failed = true;
            return;
        }
        if (n == 0) {
            write_failed = true;
            return;
        }
        index += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
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
    // GNU coreutils writes --help / --version to stdout with exit status 0.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU coreutils writes --version to stdout with exit status 0.
    writeStdout("zgroups " ++ VERSION ++ "\n");
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

    // Group list. Use a stack buffer for the common case; grow onto the heap if
    // the user belongs to more groups than fit (large LDAP/AD environments).
    var stack_groups: [128]u32 = undefined;
    var groups: []u32 = &stack_groups;
    var heap_groups: ?[]u32 = null;
    defer if (heap_groups) |hg| std.heap.page_allocator.free(hg);
    var ngroups: c_int = undefined;

    if (username == null) {
        // For current user, use getgroups() to match GNU ordering. Grow the
        // buffer if getgroups reports more entries than we have room for.
        while (true) {
            ngroups = getgroups(@intCast(groups.len), groups.ptr);
            if (ngroups >= 0) break;
            // -1: the caller's array is too small. Query the required count.
            const needed = getgroups(0, groups.ptr);
            const new_len: usize = if (needed > 0) @as(usize, @intCast(needed)) else groups.len * 2;
            if (new_len <= groups.len) {
                writeStderr("zgroups: cannot get group list\n");
                return false;
            }
            if (heap_groups) |hg| std.heap.page_allocator.free(hg);
            heap_groups = std.heap.page_allocator.alloc(u32, new_len) catch {
                writeStderr("zgroups: cannot get group list\n");
                return false;
            };
            groups = heap_groups.?;
        }
    } else {
        // getgrouplist: on overflow it returns -1 and (on this platform) writes
        // the required count back into ngroups. Retry with a grown buffer.
        while (true) {
            ngroups = @intCast(groups.len);
            if (getgrouplist(name_z, primary_gid, groups.ptr, &ngroups) >= 0) break;
            const new_len: usize = if (ngroups > @as(c_int, @intCast(groups.len)))
                @as(usize, @intCast(ngroups))
            else
                groups.len * 2;
            if (new_len <= groups.len) {
                writeStderr("zgroups: cannot get group list\n");
                return false;
            }
            if (heap_groups) |hg| std.heap.page_allocator.free(hg);
            heap_groups = std.heap.page_allocator.alloc(u32, new_len) catch {
                writeStderr("zgroups: cannot get group list\n");
                return false;
            };
            groups = heap_groups.?;
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

/// Emit a GNU-style diagnostic for an unusable option and exit(1). Mirrors
/// getopt's two shapes: "invalid option -- 'x'" for a bad short option and
/// "unrecognized option '--foo'" for a bad long option, each followed by the
/// "Try '<prog> --help'" hint.
fn rejectOption(arg: []const u8) noreturn {
    if (arg.len >= 2 and arg[1] == '-') {
        // Long option: unrecognized option '--foo'
        writeStderr("zgroups: unrecognized option '");
        writeStderr(arg);
        writeStderr("'\n");
    } else {
        // Short option: invalid option -- 'x' (first offending char)
        writeStderr("zgroups: invalid option -- '");
        writeStderr(arg[1..2]);
        writeStderr("'\n");
    }
    writeStderr("Try 'zgroups --help' for more information.\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var users_found = false;
    var exit_code: u8 = 0;
    var seen_double_dash = false;

    while (args_iter.next()) |arg| {
        if (!seen_double_dash) {
            if (std.mem.eql(u8, arg, "--")) {
                // End-of-options separator: everything after is a username.
                seen_double_dash = true;
                continue;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                if (write_failed) std.process.exit(1);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                if (write_failed) std.process.exit(1);
                return;
            } else if (arg.len > 1 and arg[0] == '-') {
                // Unknown option (a bare "-" is treated as a username, so
                // require len > 1 here). GNU errors and exits 1.
                rejectOption(arg);
            }
        }

        // Non-option argument (or anything after "--"): a username.
        users_found = true;
        if (!printGroups(arg)) {
            exit_code = 1;
        }
    }

    if (!users_found) {
        if (!printGroups(null)) {
            exit_code = 1;
        }
    }

    if (write_failed and exit_code == 0) {
        exit_code = 1;
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
