//! zvdir - List directory contents in long format with escape sequences
//!
//! A Zig implementation of vdir (equivalent to ls -lb).
//! Lists files in long format, escaping non-printable characters.
//!
//! Usage: zvdir [OPTIONS] [FILE]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

const stat_t = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: i64,
    st_atime_nsec: i64,
    st_mtime: i64,
    st_mtime_nsec: i64,
    st_ctime: i64,
    st_ctime_nsec: i64,
    __unused: [3]i64,
};

extern "c" fn stat(path: [*:0]const u8, buf: *stat_t) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *stat_t) c_int;

const DIR = opaque {};
const dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
extern "c" fn closedir(dirp: *DIR) c_int;

const passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

const group = extern struct {
    gr_name: ?[*:0]const u8,
    gr_passwd: ?[*:0]const u8,
    gr_gid: u32,
    gr_mem: ?[*]?[*:0]const u8,
};

extern "c" fn getpwuid(uid: u32) ?*const passwd;
extern "c" fn getgrgid(gid: u32) ?*const group;

// File type masks
const S_IFMT: u32 = 0o170000;
const S_IFSOCK: u32 = 0o140000;
const S_IFLNK: u32 = 0o120000;
const S_IFREG: u32 = 0o100000;
const S_IFBLK: u32 = 0o060000;
const S_IFDIR: u32 = 0o040000;
const S_IFCHR: u32 = 0o020000;
const S_IFIFO: u32 = 0o010000;

// Permission bits
const S_ISUID: u32 = 0o4000;
const S_ISGID: u32 = 0o2000;
const S_ISVTX: u32 = 0o1000;
const S_IRUSR: u32 = 0o0400;
const S_IWUSR: u32 = 0o0200;
const S_IXUSR: u32 = 0o0100;
const S_IRGRP: u32 = 0o0040;
const S_IWGRP: u32 = 0o0020;
const S_IXGRP: u32 = 0o0010;
const S_IROTH: u32 = 0o0004;
const S_IWOTH: u32 = 0o0002;
const S_IXOTH: u32 = 0o0001;

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

fn writeStdoutRaw(data: []const u8) void {
    _ = write(1, data.ptr, data.len);
}

const FileEntry = struct {
    name: []const u8,
    stat_buf: stat_t,
    full_path: []const u8,
};

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
    var show_all = false;
    var show_almost_all = false;
    var human_readable = false;
    var reverse = false;
    var sort_by_time = false;
    var sort_by_size = false;
    var no_sort = false;
    var numeric_ids = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zvdir {s}\n", .{VERSION});
            return;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Short options (can be combined)
            for (arg[1..]) |ch| {
                switch (ch) {
                    'a' => show_all = true,
                    'A' => show_almost_all = true,
                    'h' => human_readable = true,
                    'r' => reverse = true,
                    't' => sort_by_time = true,
                    'S' => sort_by_size = true,
                    'U' => no_sort = true,
                    'n' => numeric_ids = true,
                    else => {
                        writeStderr("zvdir: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--all")) {
                show_all = true;
            } else if (std.mem.eql(u8, arg, "--almost-all")) {
                show_almost_all = true;
            } else if (std.mem.eql(u8, arg, "--human-readable")) {
                human_readable = true;
            } else if (std.mem.eql(u8, arg, "--reverse")) {
                reverse = true;
            } else if (std.mem.eql(u8, arg, "--numeric-uid-gid")) {
                numeric_ids = true;
            } else {
                writeStderr("zvdir: unrecognized option '{s}'\n", .{arg});
                std.process.exit(1);
            }
        } else {
            try paths.append(allocator, arg);
        }
    }

    // Default to current directory
    if (paths.items.len == 0) {
        try paths.append(allocator, ".");
    }

    var first = true;
    var errors: u32 = 0;

    for (paths.items) |path| {
        if (paths.items.len > 1) {
            if (!first) writeStdout("\n", .{});
            writeStdout("{s}:\n", .{path});
        }
        first = false;

        // Check if path is a directory
        var path_z: [4097]u8 = undefined;
        if (path.len >= path_z.len) {
            writeStderr("zvdir: path too long: {s}\n", .{path});
            errors += 1;
            continue;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var path_stat: stat_t = undefined;
        if (lstat(@ptrCast(&path_z), &path_stat) != 0) {
            writeStderr("zvdir: cannot access '{s}': No such file or directory\n", .{path});
            errors += 1;
            continue;
        }

        if ((path_stat.st_mode & S_IFMT) != S_IFDIR) {
            // It's a file, list it directly
            printFileEntry(allocator, path, std.fs.path.basename(path), &path_stat, human_readable, numeric_ids);
            continue;
        }

        // Open directory
        const dir = opendir(@ptrCast(&path_z));
        if (dir == null) {
            writeStderr("zvdir: cannot open directory '{s}'\n", .{path});
            errors += 1;
            continue;
        }
        defer _ = closedir(dir.?);

        // Collect entries
        var entries: std.ArrayListUnmanaged(FileEntry) = .empty;
        defer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.full_path);
            }
            entries.deinit(allocator);
        }

        var total_blocks: i64 = 0;

        while (readdir(dir.?)) |entry| {
            const name_len = std.mem.indexOfScalar(u8, &entry.d_name, 0) orelse entry.d_name.len;
            const name = entry.d_name[0..name_len];

            // Skip . and .. unless -a
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                if (!show_all) continue;
            } else if (name.len > 0 and name[0] == '.') {
                // Hidden file
                if (!show_all and !show_almost_all) continue;
            }

            // Build full path
            var full_path_buf: [8192]u8 = undefined;
            const full_path_len = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ path, name }) catch continue;
            const full_path_z = full_path_buf[0 .. full_path_len.len + 1];
            full_path_z[full_path_len.len] = 0;

            var entry_stat: stat_t = undefined;
            if (lstat(@ptrCast(full_path_z.ptr), &entry_stat) != 0) {
                continue;
            }

            total_blocks += entry_stat.st_blocks;

            const name_copy = try allocator.dupe(u8, name);
            const full_path_copy = try allocator.dupe(u8, full_path_len);

            try entries.append(allocator, .{
                .name = name_copy,
                .stat_buf = entry_stat,
                .full_path = full_path_copy,
            });
        }

        // Sort entries
        if (!no_sort) {
            const SortContext = struct {
                reverse_sort: bool,
                by_time: bool,
                by_size: bool,
            };
            const ctx = SortContext{
                .reverse_sort = reverse,
                .by_time = sort_by_time,
                .by_size = sort_by_size,
            };

            std.mem.sort(FileEntry, entries.items, ctx, struct {
                fn lessThan(context: SortContext, a: FileEntry, b: FileEntry) bool {
                    var result: bool = undefined;
                    if (context.by_time) {
                        if (a.stat_buf.st_mtime != b.stat_buf.st_mtime) {
                            result = a.stat_buf.st_mtime > b.stat_buf.st_mtime;
                        } else {
                            result = std.mem.lessThan(u8, a.name, b.name);
                        }
                    } else if (context.by_size) {
                        if (a.stat_buf.st_size != b.stat_buf.st_size) {
                            result = a.stat_buf.st_size > b.stat_buf.st_size;
                        } else {
                            result = std.mem.lessThan(u8, a.name, b.name);
                        }
                    } else {
                        result = std.mem.lessThan(u8, a.name, b.name);
                    }
                    return if (context.reverse_sort) !result else result;
                }
            }.lessThan);
        }

        // Print total
        writeStdout("total {d}\n", .{@divTrunc(total_blocks, 2)});

        // Print entries
        for (entries.items) |entry| {
            printFileEntry(allocator, entry.full_path, entry.name, &entry.stat_buf, human_readable, numeric_ids);
        }
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

fn printFileEntry(allocator: std.mem.Allocator, full_path: []const u8, name: []const u8, st: *const stat_t, human_readable: bool, numeric_ids: bool) void {
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    // File type character
    const file_type: u8 = switch (st.st_mode & S_IFMT) {
        S_IFDIR => 'd',
        S_IFLNK => 'l',
        S_IFCHR => 'c',
        S_IFBLK => 'b',
        S_IFIFO => 'p',
        S_IFSOCK => 's',
        else => '-',
    };
    buf[pos] = file_type;
    pos += 1;

    // Permissions
    buf[pos] = if (st.st_mode & S_IRUSR != 0) 'r' else '-';
    pos += 1;
    buf[pos] = if (st.st_mode & S_IWUSR != 0) 'w' else '-';
    pos += 1;
    if (st.st_mode & S_ISUID != 0) {
        buf[pos] = if (st.st_mode & S_IXUSR != 0) 's' else 'S';
    } else {
        buf[pos] = if (st.st_mode & S_IXUSR != 0) 'x' else '-';
    }
    pos += 1;

    buf[pos] = if (st.st_mode & S_IRGRP != 0) 'r' else '-';
    pos += 1;
    buf[pos] = if (st.st_mode & S_IWGRP != 0) 'w' else '-';
    pos += 1;
    if (st.st_mode & S_ISGID != 0) {
        buf[pos] = if (st.st_mode & S_IXGRP != 0) 's' else 'S';
    } else {
        buf[pos] = if (st.st_mode & S_IXGRP != 0) 'x' else '-';
    }
    pos += 1;

    buf[pos] = if (st.st_mode & S_IROTH != 0) 'r' else '-';
    pos += 1;
    buf[pos] = if (st.st_mode & S_IWOTH != 0) 'w' else '-';
    pos += 1;
    if (st.st_mode & S_ISVTX != 0) {
        buf[pos] = if (st.st_mode & S_IXOTH != 0) 't' else 'T';
    } else {
        buf[pos] = if (st.st_mode & S_IXOTH != 0) 'x' else '-';
    }
    pos += 1;

    buf[pos] = ' ';
    pos += 1;

    // Link count
    const nlink_str = std.fmt.bufPrint(buf[pos..], "{d:>3} ", .{st.st_nlink}) catch return;
    pos += nlink_str.len;

    // Owner
    if (!numeric_ids) {
        if (getpwuid(st.st_uid)) |pw| {
            if (pw.pw_name) |pw_name| {
                var name_len: usize = 0;
                while (pw_name[name_len] != 0) : (name_len += 1) {}
                const owner_str = std.fmt.bufPrint(buf[pos..], "{s:<8} ", .{pw_name[0..name_len]}) catch return;
                pos += owner_str.len;
            } else {
                const owner_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_uid}) catch return;
                pos += owner_str.len;
            }
        } else {
            const owner_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_uid}) catch return;
            pos += owner_str.len;
        }
    } else {
        const owner_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_uid}) catch return;
        pos += owner_str.len;
    }

    // Group
    if (!numeric_ids) {
        if (getgrgid(st.st_gid)) |gr| {
            if (gr.gr_name) |gr_name| {
                var name_len: usize = 0;
                while (gr_name[name_len] != 0) : (name_len += 1) {}
                const group_str = std.fmt.bufPrint(buf[pos..], "{s:<8} ", .{gr_name[0..name_len]}) catch return;
                pos += group_str.len;
            } else {
                const group_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_gid}) catch return;
                pos += group_str.len;
            }
        } else {
            const group_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_gid}) catch return;
            pos += group_str.len;
        }
    } else {
        const group_str = std.fmt.bufPrint(buf[pos..], "{d:<8} ", .{st.st_gid}) catch return;
        pos += group_str.len;
    }

    // Size
    if (human_readable) {
        const size_str = formatHumanSize(buf[pos..], st.st_size);
        pos += size_str.len;
    } else {
        const size_str = std.fmt.bufPrint(buf[pos..], "{d:>8} ", .{st.st_size}) catch return;
        pos += size_str.len;
    }

    // Date
    const date_str = formatDate(buf[pos..], st.st_mtime);
    pos += date_str.len;

    buf[pos] = ' ';
    pos += 1;

    // Output what we have so far
    writeStdoutRaw(buf[0..pos]);

    // Name (with escaping for non-printable characters)
    printEscaped(allocator, name);

    // Symlink target
    if ((st.st_mode & S_IFMT) == S_IFLNK) {
        var path_z: [4097]u8 = undefined;
        if (full_path.len < path_z.len) {
            @memcpy(path_z[0..full_path.len], full_path);
            path_z[full_path.len] = 0;

            var link_target: [4096]u8 = undefined;
            const link_len = readlink(@ptrCast(&path_z), &link_target, link_target.len);
            if (link_len > 0) {
                writeStdout(" -> ", .{});
                printEscaped(allocator, link_target[0..@intCast(link_len)]);
            }
        }
    }

    writeStdout("\n", .{});
}

fn printEscaped(allocator: std.mem.Allocator, name: []const u8) void {
    _ = allocator;
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (name) |c| {
        if (pos + 4 >= buf.len) {
            writeStdoutRaw(buf[0..pos]);
            pos = 0;
        }

        if (c >= 32 and c < 127) {
            // Printable ASCII
            buf[pos] = c;
            pos += 1;
        } else {
            // Escape non-printable
            buf[pos] = '\\';
            pos += 1;
            buf[pos] = '0' + ((c >> 6) & 0o7);
            pos += 1;
            buf[pos] = '0' + ((c >> 3) & 0o7);
            pos += 1;
            buf[pos] = '0' + (c & 0o7);
            pos += 1;
        }
    }

    if (pos > 0) {
        writeStdoutRaw(buf[0..pos]);
    }
}

fn formatHumanSize(buf: []u8, size: i64) []const u8 {
    const abs_size: u64 = if (size < 0) 0 else @intCast(size);

    if (abs_size < 1024) {
        return std.fmt.bufPrint(buf, "{d:>5}  ", .{abs_size}) catch "";
    } else if (abs_size < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(abs_size)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:>5.1}K ", .{kb}) catch "";
    } else if (abs_size < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(abs_size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:>5.1}M ", .{mb}) catch "";
    } else {
        const gb = @as(f64, @floatFromInt(abs_size)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:>5.1}G ", .{gb}) catch "";
    }
}

fn formatDate(buf: []u8, timestamp: i64) []const u8 {
    // Convert Unix timestamp to date components
    const SECS_PER_DAY = 86400;
    const SECS_PER_HOUR = 3600;
    const SECS_PER_MIN = 60;

    var days = @divFloor(timestamp, SECS_PER_DAY);
    var remaining = @mod(timestamp, SECS_PER_DAY);
    if (remaining < 0) {
        remaining += SECS_PER_DAY;
        days -= 1;
    }

    const hour: u32 = @intCast(@divFloor(remaining, SECS_PER_HOUR));
    remaining = @mod(remaining, SECS_PER_HOUR);
    const min: u32 = @intCast(@divFloor(remaining, SECS_PER_MIN));

    // Days since epoch (Jan 1, 1970)
    var year: i32 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_days_leap = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const mdays = if (isLeapYear(year)) &month_days_leap else &month_days;

    var month: u32 = 0;
    while (month < 12) {
        if (days < mdays[month]) break;
        days -= mdays[month];
        month += 1;
    }

    const day: u32 = @intCast(days + 1);
    month += 1;

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    return std.fmt.bufPrint(buf, "{s} {d:>2} {d:0>2}:{d:0>2}", .{
        month_names[month - 1],
        day,
        hour,
        min,
    }) catch "";
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zvdir [OPTION]... [FILE]...
        \\List directory contents in long format with escape sequences.
        \\Equivalent to 'ls -lb'.
        \\
        \\Options:
        \\  -a, --all             show hidden entries (including . and ..)
        \\  -A, --almost-all      show hidden entries (except . and ..)
        \\  -h, --human-readable  print sizes in human readable format (K, M, G)
        \\  -n, --numeric-uid-gid print numeric user and group IDs
        \\  -r, --reverse         reverse order while sorting
        \\  -S                    sort by file size, largest first
        \\  -t                    sort by modification time, newest first
        \\  -U                    do not sort; list entries in directory order
        \\      --help            display this help
        \\      --version         display version
        \\
        \\Non-printable characters are shown as octal escapes (e.g., \012 for newline).
        \\
        \\Examples:
        \\  zvdir                 list current directory
        \\  zvdir -a              show all files including hidden
        \\  zvdir -h /home        human-readable sizes
        \\  zvdir -t              sort by modification time
        \\
    , .{});
}
