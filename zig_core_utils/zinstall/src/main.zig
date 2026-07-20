//! zinstall - Copy files and set attributes
//!
//! A Zig implementation of install.
//! Copy files while setting mode bits, ownership, and optionally creating directories.
//!
//! Usage: zinstall [OPTION]... SOURCE DEST
//!        zinstall [OPTION]... SOURCE... DIRECTORY
//!        zinstall -d [OPTION]... DIRECTORY...

const std = @import("std");
const builtin = @import("builtin");

const VERSION = "1.0.0";

// Use the platform-correct `struct stat` layout from std, rather than a
// hand-rolled Linux/x86_64 layout that reads garbage bytes on macOS/BSD.
// std.c.Stat switches on the target OS and exposes .mode/.size/.uid/.gid
// plus .atime()/.mtime() helpers returning a timespec.
const Stat = std.c.Stat;

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;
extern "c" fn chown(path: [*:0]const u8, owner: c_uint, group: c_uint) c_int;
extern "c" fn fchown(fd: c_int, owner: c_uint, group: c_uint) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn getpwnam(name: [*:0]const u8) ?*const Passwd;
extern "c" fn getgrnam(name: [*:0]const u8) ?*const Group;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getgid() c_uint;
extern "c" fn utimensat(dirfd: c_int, pathname: [*:0]const u8, times: *const TimeSpec, flags: c_int) c_int;
extern "c" fn futimens(fd: c_int, times: *const TimeSpec) c_int;

const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const AT_FDCWD: c_int = -100;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

// open(2) flags are ABI values that differ between Linux and Darwin/BSD.
// The previous hardcoded octal values were the Linux numbers and silently
// meant something else on macOS (e.g. Linux O_TRUNC 0o1000 == Darwin O_CREAT).
const is_darwin = builtin.target.os.tag.isDarwin();
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = if (is_darwin) 0x0200 else 0o100;
const O_TRUNC: c_int = if (is_darwin) 0x0400 else 0o1000;
const O_EXCL: c_int = if (is_darwin) 0x0800 else 0o200;
const O_NOFOLLOW: c_int = if (is_darwin) 0x0100 else 0o400000;

const Passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: c_uint,
    pw_gid: c_uint,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

const Group = extern struct {
    gr_name: ?[*:0]const u8,
    gr_passwd: ?[*:0]const u8,
    gr_gid: c_uint,
    gr_mem: ?[*]?[*:0]const u8,
};

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn toNullTerminated(path: []const u8, buf: *[4097]u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
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

    // Options
    var mode: c_uint = 0o755;
    var owner: ?c_uint = null;
    var group: ?c_uint = null;
    var create_dirs = false; // -d: create directories
    var create_leading = false; // -D: create leading directories
    var strip_binary = false;
    var backup = false;
    var compare = false;
    var verbose = false;
    var target_dir: ?[]const u8 = null;
    var no_target_dir = false;
    var preserve_timestamps = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zinstall {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--directory")) {
            create_dirs = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strip")) {
            strip_binary = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backup")) {
            backup = true;
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--compare")) {
            compare = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--preserve-timestamps")) {
            preserve_timestamps = true;
        } else if (std.mem.eql(u8, arg, "-D")) {
            create_leading = true;
        } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--no-target-directory")) {
            no_target_dir = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zinstall: option requires an argument -- 'm'\n", .{});
                std.process.exit(1);
            }
            mode = parseMode(args[i]) orelse {
                writeStderr("zinstall: invalid mode: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = parseMode(arg[7..]) orelse {
                writeStderr("zinstall: invalid mode: '{s}'\n", .{arg[7..]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--owner")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zinstall: option requires an argument -- 'o'\n", .{});
                std.process.exit(1);
            }
            owner = resolveUser(args[i]);
            if (owner == null) {
                writeStderr("zinstall: invalid user: '{s}'\n", .{args[i]});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--owner=")) {
            owner = resolveUser(arg[8..]);
            if (owner == null) {
                writeStderr("zinstall: invalid user: '{s}'\n", .{arg[8..]});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--group")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zinstall: option requires an argument -- 'g'\n", .{});
                std.process.exit(1);
            }
            group = resolveGroup(args[i]);
            if (group == null) {
                writeStderr("zinstall: invalid group: '{s}'\n", .{args[i]});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--group=")) {
            group = resolveGroup(arg[8..]);
            if (group == null) {
                writeStderr("zinstall: invalid group: '{s}'\n", .{arg[8..]});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target-directory")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zinstall: option requires an argument -- 't'\n", .{});
                std.process.exit(1);
            }
            target_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--target-directory=")) {
            target_dir = arg[19..];
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options. Value-taking options (m/o/g/t) consume the
            // rest of the cluster as their argument (GNU: `-m755`), or the next
            // argv element if the cluster ends right after the letter (`-m 755`).
            var j: usize = 1;
            cluster: while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'd' => create_dirs = true,
                    'D' => create_leading = true,
                    's' => strip_binary = true,
                    'b' => backup = true,
                    'C' => compare = true,
                    'v' => verbose = true,
                    'p' => preserve_timestamps = true,
                    'T' => no_target_dir = true,
                    'm', 'o', 'g', 't' => {
                        // The argument is the rest of the cluster, or the next argv.
                        var val: []const u8 = arg[j + 1 ..];
                        if (val.len == 0) {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zinstall: option requires an argument -- '{c}'\n", .{ch});
                                std.process.exit(1);
                            }
                            val = args[i];
                        }
                        switch (ch) {
                            'm' => mode = parseMode(val) orelse {
                                writeStderr("zinstall: invalid mode: '{s}'\n", .{val});
                                std.process.exit(1);
                            },
                            'o' => {
                                owner = resolveUser(val);
                                if (owner == null) {
                                    writeStderr("zinstall: invalid user: '{s}'\n", .{val});
                                    std.process.exit(1);
                                }
                            },
                            'g' => {
                                group = resolveGroup(val);
                                if (group == null) {
                                    writeStderr("zinstall: invalid group: '{s}'\n", .{val});
                                    std.process.exit(1);
                                }
                            },
                            't' => target_dir = val,
                            else => unreachable,
                        }
                        break :cluster;
                    },
                    else => {
                        writeStderr("zinstall: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(allocator, args[i]);
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Note: strip, compare, preserve_timestamps are implemented in copyFile

    if (files.items.len == 0) {
        writeStderr("zinstall: missing file operand\n", .{});
        std.process.exit(1);
    }

    // Directory creation mode
    if (create_dirs and target_dir == null and files.items.len >= 1) {
        // Check if last arg looks like a destination or if -d was used
        const last = files.items[files.items.len - 1];
        var st: Stat = undefined;
        var last_z: [4097]u8 = undefined;
        const last_ptr = toNullTerminated(last, &last_z) orelse {
            writeStderr("zinstall: path too long\n", .{});
            std.process.exit(1);
        };

        if (stat(last_ptr, &st) == 0 and (st.mode & 0o170000) == 0o040000) {
            // Last arg is existing directory - use as target
            target_dir = last;
            _ = files.pop();
        }
    }

    // -d mode: create directories
    if (create_dirs and target_dir == null) {
        for (files.items) |dir| {
            if (createDirectoryPath(dir, mode, verbose)) {
                if (owner != null or group != null) {
                    var dir_z: [4097]u8 = undefined;
                    if (toNullTerminated(dir, &dir_z)) |ptr| {
                        const uid = owner orelse @as(c_uint, @bitCast(@as(i32, -1)));
                        const gid = group orelse @as(c_uint, @bitCast(@as(i32, -1)));
                        _ = chown(ptr, uid, gid);
                    }
                }
            } else {
                std.process.exit(1);
            }
        }
        return;
    }

    // Need at least source and destination
    if (files.items.len < 2 and target_dir == null) {
        writeStderr("zinstall: missing destination file operand after '{s}'\n", .{files.items[0]});
        std.process.exit(1);
    }

    // Determine destination
    var dest: []const u8 = undefined;
    var sources: []const []const u8 = undefined;

    if (target_dir) |td| {
        dest = td;
        sources = files.items;
    } else {
        dest = files.items[files.items.len - 1];
        sources = files.items[0 .. files.items.len - 1];
    }

    // Check if dest is directory
    var dest_is_dir = false;
    var dest_z: [4097]u8 = undefined;
    if (toNullTerminated(dest, &dest_z)) |dest_ptr| {
        var st: Stat = undefined;
        if (stat(dest_ptr, &st) == 0) {
            dest_is_dir = (st.mode & 0o170000) == 0o040000;
        }
    }

    if (sources.len > 1 and !dest_is_dir) {
        writeStderr("zinstall: target '{s}' is not a directory\n", .{dest});
        std.process.exit(1);
    }

    if (no_target_dir and dest_is_dir and sources.len == 1) {
        dest_is_dir = false;
    }

    // Install files
    for (sources) |src| {
        var final_dest: []const u8 = undefined;
        var dest_buf: [8192]u8 = undefined;

        if (dest_is_dir) {
            // Extract basename
            const basename = getBasename(src);
            const len = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dest, basename }) catch {
                writeStderr("zinstall: path too long\n", .{});
                std.process.exit(1);
            };
            final_dest = len;
        } else {
            final_dest = dest;
        }

        // Create parent directories if -D
        if (create_leading) {
            createParentDirs(final_dest, 0o755);
        }

        // Backup if requested
        if (backup) {
            var backup_buf: [8192]u8 = undefined;
            const backup_path = std.fmt.bufPrint(&backup_buf, "{s}~", .{final_dest}) catch continue;
            var final_z: [4097]u8 = undefined;
            var backup_z: [4097]u8 = undefined;
            if (toNullTerminated(final_dest, &final_z)) |fp| {
                if (toNullTerminated(backup_path, &backup_z)) |bp| {
                    _ = rename(fp, bp);
                }
            }
        }

        // Copy file (mode + ownership + timestamps applied on the open fd)
        if (!copyFile(src, final_dest, mode, owner, group, compare, preserve_timestamps)) {
            std.process.exit(1);
        }

        // Strip the installed binary if requested (-s). GNU install execs
        // strip(1); we do the same via argv-mode Child (no shell).
        if (strip_binary) {
            if (!stripFile(init.io, final_dest)) {
                std.process.exit(1);
            }
        }

        if (verbose) {
            writeStdout("'{s}' -> '{s}'\n", .{ src, final_dest });
        }
    }
}

pub fn parseMode(mode_str: []const u8) ?c_uint {
    // Try octal first
    if (std.fmt.parseInt(c_uint, mode_str, 8)) |m| {
        return m;
    } else |_| {}

    // Symbolic mode. GNU install compiles the symbolic string against a base
    // mode of 0 with a umask of 0 (the -m mode is absolute, not umask-masked),
    // so we start from result=0 and never substitute a 0o755 fallback.
    //
    // The `who` mask must carry the special bits alongside the ordinary
    // permission triads, otherwise `perm &= who` clears setuid/setgid/sticky:
    //   u -> user perms 0o700 + setuid  0o4000
    //   g -> group perms 0o070 + setgid 0o2000
    //   o -> other perms 0o007 + sticky 0o1000
    //   a -> everything 0o7777
    // An unspecified who defaults to `a` (install umask is 0).
    var result: c_uint = 0;
    var idx: usize = 0;

    while (idx < mode_str.len) {
        // Parse who
        var who: c_uint = 0;
        var who_given = false;
        while (idx < mode_str.len) {
            switch (mode_str[idx]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= 0o7777,
                else => break,
            }
            who_given = true;
            idx += 1;
        }
        if (!who_given) who = 0o7777;

        if (idx >= mode_str.len) break;

        // Parse operator
        const op = mode_str[idx];
        if (op != '+' and op != '-' and op != '=') return null;
        idx += 1;

        // Parse permission
        var perm: c_uint = 0;
        while (idx < mode_str.len and mode_str[idx] != ',') {
            switch (mode_str[idx]) {
                'r' => perm |= 0o444,
                'w' => perm |= 0o222,
                'x' => perm |= 0o111,
                'X' => perm |= 0o111, // simplified
                's' => perm |= 0o6000, // setuid + setgid; masked by `who`
                't' => perm |= 0o1000, // sticky
                else => {},
            }
            idx += 1;
        }

        perm &= who;

        switch (op) {
            '+' => result |= perm,
            '-' => result &= ~perm,
            '=' => {
                result &= ~who;
                result |= perm;
            },
            else => {},
        }

        if (idx < mode_str.len and mode_str[idx] == ',') idx += 1;
    }

    return result;
}

// Strip the installed binary with strip(1). Uses argv-mode spawn (never a
// shell) so a hostile file name cannot inject a command.
fn stripFile(io: std.Io, dest: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "strip", dest },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch {
        writeStderr("zinstall: strip: failed to run strip on '{s}'\n", .{dest});
        return false;
    };
    const term = child.wait(io) catch {
        writeStderr("zinstall: strip: wait failed on '{s}'\n", .{dest});
        return false;
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                writeStderr("zinstall: strip failed on '{s}'\n", .{dest});
                return false;
            }
        },
        else => {
            writeStderr("zinstall: strip terminated abnormally on '{s}'\n", .{dest});
            return false;
        },
    }
    return true;
}

fn resolveUser(name: []const u8) ?c_uint {
    // Try numeric first
    if (std.fmt.parseInt(c_uint, name, 10)) |uid| {
        return uid;
    } else |_| {}

    // Try name lookup
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    if (getpwnam(@ptrCast(&name_z))) |pw| {
        return pw.pw_uid;
    }
    return null;
}

fn resolveGroup(name: []const u8) ?c_uint {
    // Try numeric first
    if (std.fmt.parseInt(c_uint, name, 10)) |gid| {
        return gid;
    } else |_| {}

    // Try name lookup
    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    if (getgrnam(@ptrCast(&name_z))) |gr| {
        return gr.gr_gid;
    }
    return null;
}

fn createDirectoryPath(path: []const u8, mode: c_uint, verbose: bool) bool {
    var path_z: [4097]u8 = undefined;

    // Create each component
    var i: usize = 0;
    while (i < path.len) {
        // Skip leading slashes
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;

        // Find next slash
        while (i < path.len and path[i] != '/') i += 1;

        // Create this component
        const component = path[0..i];
        if (toNullTerminated(component, &path_z)) |ptr| {
            var st: Stat = undefined;
            if (stat(ptr, &st) != 0) {
                if (mkdir(ptr, mode) != 0) {
                    writeStderr("zinstall: cannot create directory '{s}'\n", .{component});
                    return false;
                }
                if (verbose) {
                    writeStdout("zinstall: creating directory '{s}'\n", .{component});
                }
            }
        }
    }

    return true;
}

fn createParentDirs(path: []const u8, mode: c_uint) void {
    // Find last slash
    var last_slash: ?usize = null;
    for (path, 0..) |ch, idx| {
        if (ch == '/') last_slash = idx;
    }

    if (last_slash) |ls| {
        if (ls > 0) {
            _ = createDirectoryPath(path[0..ls], mode, false);
        }
    }
}

fn getBasename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return path;

    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;

    return path[start..end];
}

// Read into `buf` until it is full or EOF/error. Returns the number of bytes
// read (< buf.len only at EOF), or -1 on error. This normalizes away the fact
// that a single read() may legally return fewer bytes than requested.
fn readFull(fd: c_int, buf: []u8) isize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = c_read(fd, buf[total..].ptr, buf.len - total);
        if (n < 0) return -1;
        if (n == 0) break;
        total += @intCast(n);
    }
    return @intCast(total);
}

fn copyFile(src: []const u8, dest: []const u8, mode: c_uint, owner: ?c_uint, group: ?c_uint, compare: bool, preserve_timestamps: bool) bool {
    var src_z: [4097]u8 = undefined;
    var dest_z: [4097]u8 = undefined;

    const src_ptr = toNullTerminated(src, &src_z) orelse {
        writeStderr("zinstall: source path too long\n", .{});
        return false;
    };

    const dest_ptr = toNullTerminated(dest, &dest_z) orelse {
        writeStderr("zinstall: destination path too long\n", .{});
        return false;
    };

    // Check if compare flag is set
    if (compare) {
        var src_st: Stat = undefined;
        var dest_st: Stat = undefined;
        if (stat(src_ptr, &src_st) == 0 and stat(dest_ptr, &dest_st) == 0) {
            // If files exist and have same size, compare contents
            if (src_st.size == dest_st.size) {
                const src_fd = open(src_ptr, O_RDONLY, 0);
                if (src_fd < 0) {
                    writeStderr("zinstall: cannot open '{s}'\n", .{src});
                    return false;
                }
                defer _ = close(src_fd);

                const dest_fd = open(dest_ptr, O_RDONLY, 0);
                if (dest_fd < 0) {
                    _ = close(src_fd);
                    writeStderr("zinstall: cannot open '{s}'\n", .{dest});
                    return false;
                }
                defer _ = close(dest_fd);

                // read() may legally return short and at differing offsets for
                // the two fds, so we must NOT assume equal-length reads mean
                // difference. Fill a fixed compare window from each fd, then
                // compare the windows.
                var src_buf: [65536]u8 = undefined;
                var dest_buf: [65536]u8 = undefined;
                var identical = true;

                outer: while (true) {
                    const src_n = readFull(src_fd, &src_buf);
                    const dest_n = readFull(dest_fd, &dest_buf);
                    if (src_n < 0 or dest_n < 0) {
                        identical = false;
                        break;
                    }
                    if (src_n != dest_n) {
                        identical = false;
                        break;
                    }
                    if (src_n == 0) break :outer; // both at EOF, identical so far
                    if (!std.mem.eql(u8, src_buf[0..@intCast(src_n)], dest_buf[0..@intCast(dest_n)])) {
                        identical = false;
                        break;
                    }
                }

                if (identical) {
                    return true;
                }
            }
        }
    }

    // Remove destination first
    _ = unlink(dest_ptr);

    // Open source
    const src_fd = open(src_ptr, O_RDONLY, 0);
    if (src_fd < 0) {
        writeStderr("zinstall: cannot open '{s}'\n", .{src});
        return false;
    }
    defer _ = close(src_fd);

    // Get source stats for timestamp preservation
    var src_stat: Stat = undefined;
    if (preserve_timestamps) {
        if (stat(src_ptr, &src_stat) != 0) {
            writeStderr("zinstall: cannot stat source '{s}'\n", .{src});
            return false;
        }
    }

    // Open destination. O_NOFOLLOW refuses to follow a symlink planted at the
    // destination path (a root-install TOCTOU: an attacker who wins the race
    // after unlink() could otherwise get O_CREAT|O_TRUNC to truncate an
    // arbitrary file the symlink targets).
    const dest_fd = open(dest_ptr, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode);
    if (dest_fd < 0) {
        writeStderr("zinstall: cannot create '{s}'\n", .{dest});
        return false;
    }
    defer _ = close(dest_fd);

    // Copy data
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c_read(src_fd, &buf, buf.len);
        if (n <= 0) break;

        var written: usize = 0;
        while (written < @as(usize, @intCast(n))) {
            const w = write(dest_fd, buf[written..].ptr, @as(usize, @intCast(n)) - written);
            if (w <= 0) {
                writeStderr("zinstall: write error\n", .{});
                return false;
            }
            written += @intCast(w);
        }
    }

    // Apply mode/ownership on the open descriptor (fchmod/fchown) rather than
    // by path, so we cannot be redirected onto another file between open and
    // the metadata change.
    _ = fchmod(dest_fd, mode);

    if (owner != null or group != null) {
        const uid = owner orelse @as(c_uint, @bitCast(@as(i32, -1)));
        const gid = group orelse @as(c_uint, @bitCast(@as(i32, -1)));
        if (fchown(dest_fd, uid, gid) != 0) {
            writeStderr("zinstall: cannot change ownership of '{s}'\n", .{dest});
        }
    }

    // Preserve timestamps if requested
    if (preserve_timestamps) {
        const at = src_stat.atime();
        const mt = src_stat.mtime();
        var times: [2]TimeSpec = undefined;
        times[0].tv_sec = at.sec;
        times[0].tv_nsec = at.nsec;
        times[1].tv_sec = mt.sec;
        times[1].tv_nsec = mt.nsec;
        _ = futimens(dest_fd, &times[0]);
    }

    return true;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zinstall [OPTION]... SOURCE DEST
        \\   or: zinstall [OPTION]... SOURCE... DIRECTORY
        \\   or: zinstall -d [OPTION]... DIRECTORY...
        \\
        \\Copy files and set attributes.
        \\
        \\Options:
        \\  -b, --backup           make backup of each existing destination file
        \\  -C, --compare          compare each pair of source and destination files
        \\  -d, --directory        create all components of specified directories
        \\  -D                     create all leading components of DEST except last,
        \\                         then copy SOURCE to DEST
        \\  -g, --group=GROUP      set group ownership
        \\  -m, --mode=MODE        set permission mode (as in chmod)
        \\  -o, --owner=OWNER      set ownership
        \\  -p, --preserve-timestamps  preserve modification times
        \\  -s, --strip            strip symbol tables
        \\  -t, --target-directory=DIR  copy all SOURCE arguments into DIR
        \\  -T, --no-target-directory  treat DEST as normal file
        \\  -v, --verbose          print name of each file as it is processed
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\Examples:
        \\  zinstall program /usr/bin/           Install to directory
        \\  zinstall -m 755 program /usr/bin/    Install with mode 755
        \\  zinstall -o root -g root prog /bin/  Install with ownership
        \\  zinstall -d /var/log/myapp           Create directory
        \\  zinstall -D prog /usr/local/bin/prog Create parent dirs
        \\  zinstall -bv src dest                Backup and verbose
        \\
    , .{});
}
