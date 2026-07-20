//! zid - Display user and group information
//!
//! Print user and group IDs for the current user or specified user.
//!
//! Usage: zid [OPTION]... [USER]...

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
    // Collected USER operands (GNU 9.x prints a block per operand).
    usernames: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Robust write(2): loops until all bytes are written, retrying on EINTR and
/// honoring short writes on slow/full pipes. Returns false on a real error.
fn writeAll(fd: c_int, msg: []const u8) bool {
    var off: usize = 0;
    while (off < msg.len) {
        const n = libc.write(fd, msg.ptr + off, msg.len - off);
        if (n < 0) {
            // Retry on EINTR; treat EAGAIN as a transient retry as well.
            const errno = std.c._errno().*;
            if (errno == @intFromEnum(std.c.E.INTR) or errno == @intFromEnum(std.c.E.AGAIN)) continue;
            return false;
        }
        if (n == 0) return false; // no progress
        off += @intCast(n);
    }
    return true;
}

fn writeStdout(msg: []const u8) void {
    _ = writeAll(libc.STDOUT_FILENO, msg);
}

fn writeStderr(msg: []const u8) void {
    _ = writeAll(libc.STDERR_FILENO, msg);
}

// GNU `id --help` text is written to STDOUT (verified against coreutils 9.10).
fn printUsage() void {
    const usage =
        \\Usage: zid [OPTION]... [USER]...
        \\
        \\Print user and group information for each specified USER,
        \\or (when USER omitted) for the current process.
        \\
        \\Options:
        \\  -a             Ignore, for compatibility with other versions
        \\  -Z, --context  Print only the security context (SELinux only)
        \\  -g, --group    Print only the effective group ID
        \\  -G, --groups   Print all group IDs
        \\  -n, --name     Print a name instead of a number, for -ugG
        \\  -r, --real     Print the real ID instead of the effective ID, for -ugG
        \\  -u, --user     Print only the effective user ID
        \\  -z, --zero     Delimit entries with NUL characters, not whitespace;
        \\                   not permitted in default format
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
    writeStdout(usage);
}

// GNU `id --version` text is written to STDOUT (verified against coreutils 9.10).
fn printVersion() void {
    writeStdout("zid (zig coreutils) " ++ VERSION ++ "\n");
}

fn parseArgs(config: *Config, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
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
            } else if (std.mem.eql(u8, arg, "-Z") or std.mem.eql(u8, arg, "--context")) {
                config.context = true;
            } else if (std.mem.eql(u8, arg, "-a")) {
                // Ignored for compatibility
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (arg[1] != '-') {
                // Combined short options like -un, -gn, -Gn, -ugG
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'u' => config.show_user = true,
                        'g' => config.show_group = true,
                        'G' => config.show_groups = true,
                        'n' => config.show_name = true,
                        'r' => config.show_real = true,
                        'z' => config.show_zero = true,
                        'Z' => config.context = true,
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
            // Operand (a bare "-" or a USER name).
            try config.usernames.append(allocator, arg);
        }
    }
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
            return;
        }
    }
    const s = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch return;
    writeStdout(s);
}

fn printGid(gid: u32, show_name: bool) void {
    var buf: [64]u8 = undefined;
    if (show_name) {
        if (getGroupname(gid)) |name| {
            writeStdout(name);
            return;
        }
    }
    const s = std.fmt.bufPrint(&buf, "{d}", .{gid}) catch return;
    writeStdout(s);
}

/// Fetch the caller-visible group list. Returns a heap slice the caller owns
/// (free via `allocator.free`). Grows dynamically instead of overflowing a
/// fixed stack buffer — the pre-fix code ignored getgrouplist's -1 return and
/// looped over an attacker/environment-controlled `ngroups` past a [64]u32
/// array (stack OOB read for any account in >64 supplementary groups).
fn getUserGroups(allocator: std.mem.Allocator, target_user: ?[*:0]const u8, target_gid: u32) ![]u32 {
    if (target_user) |user| {
        var cap: usize = 64;
        while (true) {
            const buf = try allocator.alloc(u32, cap);
            var ngroups: c_int = @intCast(cap);
            const rc = getgrouplist(user, target_gid, buf.ptr, &ngroups);
            if (rc >= 0) {
                // Success: `ngroups` holds the actual count written (<= cap).
                const n: usize = if (ngroups > 0) @min(@as(usize, @intCast(ngroups)), cap) else 0;
                return allocator.realloc(buf, n) catch buf[0..n];
            }
            // Overflow: buffer too small. On glibc `ngroups` is set to the total
            // needed; on macOS it may not grow, so double as a fallback. Free and
            // retry with a strictly larger buffer.
            allocator.free(buf);
            const needed: usize = if (ngroups > 0 and @as(usize, @intCast(ngroups)) > cap)
                @intCast(ngroups)
            else
                cap * 2;
            if (needed <= cap) {
                cap = cap * 2;
            } else {
                cap = needed;
            }
            if (cap > (1 << 20)) return error.TooManyGroups;
        }
    } else {
        // Current process: query the count first (size 0), then size the buffer.
        var dummy: [1]u32 = undefined;
        const count = getgroups(0, &dummy);
        const n: usize = if (count > 0) @intCast(count) else 0;
        const buf = try allocator.alloc(u32, if (n == 0) 1 else n);
        if (n == 0) return allocator.realloc(buf, 0) catch buf[0..0];
        const got = getgroups(@intCast(n), buf.ptr);
        const actual: usize = if (got > 0) @min(@as(usize, @intCast(got)), n) else 0;
        return allocator.realloc(buf, actual) catch buf[0..actual];
    }
}

fn printFullInfo(allocator: std.mem.Allocator, uid: u32, gid: u32, target_user: ?[*:0]const u8) void {
    var buf: [1024]u8 = undefined;

    // uid=1000(username)
    const username = getUsername(uid);
    if (username) |name| {
        const s = std.fmt.bufPrint(&buf, "uid={d}({s}) ", .{ uid, name }) catch return;
        writeStdout(s);
    } else {
        const s = std.fmt.bufPrint(&buf, "uid={d} ", .{uid}) catch return;
        writeStdout(s);
    }

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
    const groups = getUserGroups(allocator, target_user, gid) catch &[_]u32{};
    defer allocator.free(groups);

    if (groups.len > 0) {
        writeStdout(" groups=");
        for (groups, 0..) |g, i| {
            if (i > 0) writeStdout(",");
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

fn printGroups(allocator: std.mem.Allocator, show_name: bool, zero: bool, target_user: ?[*:0]const u8, target_gid: u32) void {
    const groups = getUserGroups(allocator, target_user, target_gid) catch &[_]u32{};
    defer allocator.free(groups);

    for (groups, 0..) |g, i| {
        if (zero) {
            // GNU -z: NUL is a *terminator* — emitted after every entry,
            // including the last, and no trailing newline.
            printGid(g, show_name);
            writeStdout("\x00");
        } else {
            if (i > 0) writeStdout(" ");
            printGid(g, show_name);
        }
    }
    if (!zero) writeStdout("\n");
}

/// Validate mutually-exclusive / dependent flag combinations exactly as GNU id
/// does. Returns error (caller exits 1) after emitting the GNU diagnostic.
fn validateFlags(config: *const Config) !void {
    const selectors: u8 = @as(u8, @intFromBool(config.show_user)) +
        @as(u8, @intFromBool(config.show_group)) +
        @as(u8, @intFromBool(config.show_groups));

    if (selectors > 1) {
        writeStderr("zid: cannot print \"only\" of more than one choice\n");
        return error.BadUsage;
    }

    const default_format = selectors == 0;
    if (default_format and (config.show_name or config.show_real)) {
        writeStderr("zid: printing only names or real IDs requires -u, -g, or -G\n");
        return error.BadUsage;
    }
    if (default_format and config.show_zero) {
        writeStderr("zid: option --zero not permitted in default format\n");
        return error.BadUsage;
    }
}

/// Emit output for a single subject (a named USER, or the current process when
/// `username` is null). Returns false if the named user could not be resolved.
fn emitFor(allocator: std.mem.Allocator, config: *const Config, username: ?[]const u8) bool {
    var uid: u32 = undefined;
    var gid: u32 = undefined;
    var target_user_z: ?[*:0]const u8 = null;
    var name_buf: [256]u8 = undefined;

    if (username) |name| {
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch {
            writeStderr("zid: username too long\n");
            return false;
        };
        const pw = getpwnam(name_z.ptr);
        if (pw == null) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zid: '{s}': no such user\n", .{name}) catch "zid: no such user\n";
            writeStderr(err_msg);
            return false;
        }
        uid = pw.?.pw_uid;
        gid = pw.?.pw_gid;
        target_user_z = name_z.ptr;
    } else {
        uid = if (config.show_real) getuid() else geteuid();
        gid = if (config.show_real) getgid() else getegid();
    }

    if (config.show_user) {
        printUid(uid, config.show_name);
        writeStdout(if (config.show_zero) "\x00" else "\n");
    } else if (config.show_group) {
        printGid(gid, config.show_name);
        writeStdout(if (config.show_zero) "\x00" else "\n");
    } else if (config.show_groups) {
        printGroups(allocator, config.show_name, config.show_zero, target_user_z, gid);
    } else {
        printFullInfo(allocator, uid, gid, target_user_z);
    }
    return true;
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

    var config = Config{};
    defer config.usernames.deinit(allocator);
    parseArgs(&config, allocator, args[1..]) catch {
        std.process.exit(1);
    };

    // GNU -Z on a non-SELinux kernel is an error, not a silent no-op.
    if (config.context) {
        writeStderr("zid: --context (-Z) works only on an SELinux-enabled kernel\n");
        std.process.exit(1);
    }

    validateFlags(&config) catch {
        std.process.exit(1);
    };

    var had_error = false;
    if (config.usernames.items.len == 0) {
        if (!emitFor(allocator, &config, null)) had_error = true;
    } else {
        for (config.usernames.items) |name| {
            if (!emitFor(allocator, &config, name)) had_error = true;
        }
    }

    if (had_error) std.process.exit(1);
}
