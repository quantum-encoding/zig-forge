//! zls - List directory contents
//!
//! Compatible with GNU ls:
//! - -1: one entry per line
//! - -l: long format
//! - -a: show all (including . and ..)
//! - -A: show almost all (exclude . and ..)
//! - -h: human readable sizes
//! - -S: sort by size
//! - -t: sort by time
//! - -r: reverse sort
//! - -R: recursive
//! - -F: file type indicators
//! - -i: show inode
//! - -d: directory only (don't list contents)
//! - --color: colorize output

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    else => libc.Stat,
};

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const white = "\x1b[37m";
    const bold_blue = "\x1b[1;34m";
    const bold_green = "\x1b[1;32m";
    const bold_cyan = "\x1b[1;36m";
    const bold_red = "\x1b[1;31m";
    const bold_yellow = "\x1b[1;33m";
    const bg_red = "\x1b[41m";
};

const ColorMode = enum { never, auto, always };

const SortMode = enum { name, size, time, none, extension };

const TimeStyle = enum { default, long_iso, full_iso, iso };

const Config = struct {
    one_per_line: bool = false,
    long_format: bool = false,
    show_all: bool = false,
    show_almost_all: bool = false,
    human_readable: bool = false,
    sort_mode: SortMode = .name,
    reverse_sort: bool = false,
    recursive: bool = false,
    show_indicators: bool = false,
    show_inode: bool = false,
    directory_only: bool = false,
    color_mode: ColorMode = .auto,
    columnar: bool = false, // -C explicit columnar output
    time_style: TimeStyle = .default,
    show_size: bool = false, // -s: show allocated size in blocks
    numeric_ids: bool = false, // -n: show numeric UID/GID
    hide_owner: bool = false, // -g: don't show owner
    hide_group: bool = false, // -o / -G: don't show group
    show_dir_indicator: bool = false, // -p: append / to directories
    comma_separated: bool = false, // -m: comma-separated output
    sort_across: bool = false, // -x: sort across rows instead of down columns
    group_directories_first: bool = false, // --group-directories-first
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.paths.items) |item| {
            allocator.free(item);
        }
        self.paths.deinit(allocator);
    }

    fn useColors(self: *const Config) bool {
        return switch (self.color_mode) {
            .always => true,
            .never => false,
            .auto => isatty(1) != 0,
        };
    }
};

extern "c" fn isatty(fd: c_int) c_int;

const FileEntry = struct {
    name: []const u8,
    name_owned: bool,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    size: u64,
    blocks: i64,
    mtime: i64,
    inode: u64,
    is_link: bool,
    link_target: ?[]const u8,

    fn deinit(self: *FileEntry, allocator: std.mem.Allocator) void {
        if (self.name_owned) {
            allocator.free(self.name);
        }
        if (self.link_target) |target| {
            allocator.free(target);
        }
    }

    fn isDir(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o40000;
    }

    fn isExecutable(self: *const FileEntry) bool {
        return (self.mode & 0o111) != 0;
    }

    fn isSymlink(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o120000;
    }

    fn isPipe(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o10000;
    }

    fn isSocket(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o140000;
    }

    fn isBlockDevice(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o60000;
    }

    fn isCharDevice(self: *const FileEntry) bool {
        return (self.mode & 0o170000) == 0o20000;
    }

    fn getColor(self: *const FileEntry) []const u8 {
        if (self.isSymlink()) {
            return Color.bold_cyan;
        } else if (self.isDir()) {
            return Color.bold_blue;
        } else if (self.isExecutable()) {
            return Color.bold_green;
        } else if (self.isPipe() or self.isSocket()) {
            return Color.bold_yellow;
        } else if (self.isBlockDevice() or self.isCharDevice()) {
            return Color.bold_yellow;
        }
        return "";
    }

    fn getIndicator(self: *const FileEntry) u8 {
        if (self.isDir()) return '/';
        if (self.isSymlink()) return '@';
        if (self.isExecutable()) return '*';
        if (self.isPipe()) return '|';
        if (self.isSocket()) return '=';
        return 0;
    }
};

// Custom structs for libc functions (workaround for Zig std lib layout issues)
const CPasswd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: libc.uid_t,
    pw_gid: libc.gid_t,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
};

const CGroup = extern struct {
    gr_name: [*:0]const u8,
    gr_passwd: [*:0]const u8,
    gr_gid: libc.gid_t,
    gr_mem: [*:null]?[*:0]const u8,
};

extern "c" fn getpwuid(uid: libc.uid_t) ?*CPasswd;
extern "c" fn getgrgid(gid: libc.gid_t) ?*CGroup;

fn getTerminalWidth() u16 {
    var ws: libc.winsize = undefined;
    const result = libc.ioctl(1, libc.T.IOCGWINSZ, &ws);
    if (result == 0 and ws.col > 0) {
        return ws.col;
    }
    return 80; // default
}

fn getUserName(uid: u32) []const u8 {
    const pw = getpwuid(uid) orelse return "?";
    return std.mem.span(pw.pw_name);
}

fn getGroupName(gid: u32) []const u8 {
    const gr = getgrgid(gid) orelse return "?";
    return std.mem.span(gr.gr_name);
}

fn formatSize(size: u64, human: bool, buf: []u8) []const u8 {
    if (!human) {
        return std.fmt.bufPrint(buf, "{d}", .{size}) catch "?";
    }

    const units = [_][]const u8{ "", "K", "M", "G", "T", "P" };
    var s: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (s >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{size}) catch "?";
    } else if (s < 10) {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ s, units[unit_idx] }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ s, units[unit_idx] }) catch "?";
    }
}

fn formatMode(mode: u32, buf: []u8) []const u8 {
    const file_type: u8 = switch (mode & 0o170000) {
        0o140000 => 's', // socket
        0o120000 => 'l', // symlink
        0o100000 => '-', // regular
        0o60000 => 'b', // block device
        0o40000 => 'd', // directory
        0o20000 => 'c', // char device
        0o10000 => 'p', // pipe
        else => '?',
    };

    const perms = "rwxrwxrwx";
    buf[0] = file_type;
    for (0..9) |i| {
        buf[i + 1] = if ((mode & (@as(u32, 1) << @intCast(8 - i))) != 0) perms[i] else '-';
    }

    // Handle special bits
    if ((mode & 0o4000) != 0) { // setuid
        buf[3] = if (buf[3] == 'x') 's' else 'S';
    }
    if ((mode & 0o2000) != 0) { // setgid
        buf[6] = if (buf[6] == 'x') 's' else 'S';
    }
    if ((mode & 0o1000) != 0) { // sticky
        buf[9] = if (buf[9] == 'x') 't' else 'T';
    }

    return buf[0..10];
}

// libc time struct
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const i64, result: *CTm) ?*CTm;

fn formatTime(mtime: i64, buf: []u8, time_style: TimeStyle) []const u8 {
    const secs_per_day: i64 = 86400;

    // Get current time to decide format
    var now_ts: libc.timespec = undefined;
    _ = libc.clock_gettime(libc.CLOCK.REALTIME, &now_ts);
    const now = now_ts.sec;

    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    // Use localtime_r for proper timezone handling
    var tm: CTm = undefined;
    _ = localtime_r(&mtime, &tm);

    const day = tm.tm_mday;
    const month: usize = @intCast(tm.tm_mon);
    const year = tm.tm_year + 1900;
    const hours = tm.tm_hour;
    const mins = tm.tm_min;
    const secs = tm.tm_sec;

    switch (time_style) {
        .long_iso => {
            // YYYY-MM-DD HH:MM - use manual padding
            const mon: u32 = @intCast(month + 1);
            const d: u32 = @intCast(day);
            const h: u32 = @intCast(hours);
            const m: u32 = @intCast(mins);
            return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
                year, mon, d, h, m,
            }) catch "?";
        },
        .full_iso => {
            // YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ
            const mon: u32 = @intCast(month + 1);
            const d: u32 = @intCast(day);
            const h: u32 = @intCast(hours);
            const m: u32 = @intCast(mins);
            const s: u32 = @intCast(secs);
            return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.000000000", .{
                year, mon, d, h, m, s,
            }) catch "?";
        },
        .iso => {
            // MM-DD HH:MM or YYYY-MM-DD
            const six_months_ago = now - (180 * secs_per_day);
            const mon: u32 = @intCast(month + 1);
            const d: u32 = @intCast(day);
            const h: u32 = @intCast(hours);
            const m: u32 = @intCast(mins);
            if (mtime < six_months_ago or mtime > now) {
                return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ year, mon, d }) catch "?";
            } else {
                return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ mon, d, h, m }) catch "?";
            }
        },
        .default => {
            const six_months_ago = now - (180 * secs_per_day);

            // Manual padding to avoid Zig 0.16 format issues
            const day_pad: []const u8 = if (day < 10) " " else "";
            const hour_pad: []const u8 = if (hours < 10) "0" else "";
            const min_pad: []const u8 = if (mins < 10) "0" else "";

            if (mtime < six_months_ago or mtime > now) {
                // Show year instead of time
                return std.fmt.bufPrint(buf, "{s} {s}{d}  {d}", .{ months[month], day_pad, day, year }) catch "?";
            } else {
                // Show time
                return std.fmt.bufPrint(buf, "{s} {s}{d} {s}{d}:{s}{d}", .{ months[month], day_pad, day, hour_pad, hours, min_pad, mins }) catch "?";
            }
        },
    }
}

fn readDirEntries(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !std.ArrayListUnmanaged(FileEntry) {
    var entries: std.ArrayListUnmanaged(FileEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const dir = libc.opendir(path_z.ptr) orelse {
        return error.CannotOpenDirectory;
    };
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        // Filter hidden files
        if (name.len > 0 and name[0] == '.') {
            if (!config.show_all and !config.show_almost_all) continue;
            if (config.show_almost_all) {
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            }
        }

        // Get file stats
        const full_path_slice = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(full_path_slice);
        const full_path = try allocator.dupeZ(u8, full_path_slice);
        defer allocator.free(full_path);

        var stat_buf: Stat = undefined;
        const stat_result = lstat(full_path.ptr, &stat_buf);

        if (stat_result != 0) continue;

        const mtime = stat_buf.mtime();
        var file_entry = FileEntry{
            .name = try allocator.dupe(u8, name),
            .name_owned = true,
            .mode = stat_buf.mode,
            .nlink = @intCast(stat_buf.nlink),
            .uid = stat_buf.uid,
            .gid = stat_buf.gid,
            .size = @intCast(stat_buf.size),
            .blocks = stat_buf.blocks,
            .mtime = mtime.sec,
            .inode = stat_buf.ino,
            .is_link = (stat_buf.mode & 0o170000) == 0o120000,
            .link_target = null,
        };

        // Read symlink target
        if (file_entry.is_link) {
            var link_buf: [4096]u8 = undefined;
            const link_len = libc.readlink(full_path.ptr, &link_buf, link_buf.len);
            if (link_len > 0) {
                file_entry.link_target = try allocator.dupe(u8, link_buf[0..@intCast(link_len)]);
            }
        }

        try entries.append(allocator, file_entry);
    }

    return entries;
}

fn getExtension(name: []const u8) []const u8 {
    // Find last dot that's not at the start
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            if (i == 0) return ""; // Hidden file, no extension
            return name[i..];
        }
    }
    return "";
}

extern "c" fn strcoll(s1: [*:0]const u8, s2: [*:0]const u8) c_int;
extern "c" fn setlocale(category: c_int, locale: ?[*:0]const u8) ?[*:0]const u8;

fn nameCmp(a_name: []const u8, b_name: []const u8) bool {
    // Use strcoll for locale-aware comparison matching GNU ls behavior.
    // We need null-terminated strings. Since FileEntry names come from readdir
    // and are duped, we can construct them on stack for small names.
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    if (a_name.len < a_buf.len and b_name.len < b_buf.len) {
        @memcpy(a_buf[0..a_name.len], a_name);
        a_buf[a_name.len] = 0;
        @memcpy(b_buf[0..b_name.len], b_name);
        b_buf[b_name.len] = 0;
        const result = strcoll(@ptrCast(a_buf[0..a_name.len :0]), @ptrCast(b_buf[0..b_name.len :0]));
        if (result != 0) return result < 0;
    }
    // Fallback: byte comparison
    return std.mem.order(u8, a_name, b_name) == .lt;
}

fn sortEntries(entries: []FileEntry, config: *const Config) void {
    const lessThan = struct {
        fn dirFirst(ctx: *const Config, a: FileEntry, b: FileEntry, inner_result: bool) bool {
            if (ctx.group_directories_first) {
                const a_dir = a.isDir();
                const b_dir = b.isDir();
                if (a_dir and !b_dir) return true;
                if (!a_dir and b_dir) return false;
            }
            return inner_result;
        }

        fn byName(ctx: *const Config, a: FileEntry, b: FileEntry) bool {
            const result = nameCmp(a.name, b.name);
            const final = if (ctx.reverse_sort) !result else result;
            return dirFirst(ctx, a, b, final);
        }

        fn bySize(ctx: *const Config, a: FileEntry, b: FileEntry) bool {
            const result = a.size > b.size; // Largest first
            const final = if (ctx.reverse_sort) !result else result;
            return dirFirst(ctx, a, b, final);
        }

        fn byTime(ctx: *const Config, a: FileEntry, b: FileEntry) bool {
            const result = a.mtime > b.mtime; // Newest first
            const final = if (ctx.reverse_sort) !result else result;
            return dirFirst(ctx, a, b, final);
        }

        fn byExtension(ctx: *const Config, a: FileEntry, b: FileEntry) bool {
            const ext_a = getExtension(a.name);
            const ext_b = getExtension(b.name);
            const cmp = std.mem.order(u8, ext_a, ext_b);
            const result = if (cmp == .eq)
                nameCmp(a.name, b.name)
            else
                cmp == .lt;
            const final = if (ctx.reverse_sort) !result else result;
            return dirFirst(ctx, a, b, final);
        }
    };

    switch (config.sort_mode) {
        .name => std.mem.sort(FileEntry, entries, config, lessThan.byName),
        .size => std.mem.sort(FileEntry, entries, config, lessThan.bySize),
        .time => std.mem.sort(FileEntry, entries, config, lessThan.byTime),
        .extension => std.mem.sort(FileEntry, entries, config, lessThan.byExtension),
        .none => {},
    }
}

fn printLongFormat(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    const use_colors = config.useColors();

    // Calculate column widths
    var max_nlink: u32 = 0;
    var max_size: u64 = 0;
    var max_user_len: usize = 0;
    var max_group_len: usize = 0;
    var max_inode: u64 = 0;
    var max_blocks_width: usize = 0;
    var max_uid_len: usize = 0;
    var max_gid_len: usize = 0;

    for (entries) |entry| {
        if (entry.nlink > max_nlink) max_nlink = entry.nlink;
        if (entry.size > max_size) max_size = entry.size;
        if (entry.inode > max_inode) max_inode = entry.inode;

        if (config.numeric_ids) {
            const uid_len = std.fmt.count("{d}", .{entry.uid});
            const gid_len = std.fmt.count("{d}", .{entry.gid});
            if (uid_len > max_uid_len) max_uid_len = uid_len;
            if (gid_len > max_gid_len) max_gid_len = gid_len;
        } else {
            const user = getUserName(entry.uid);
            const group = getGroupName(entry.gid);
            if (user.len > max_user_len) max_user_len = user.len;
            if (group.len > max_group_len) max_group_len = group.len;
        }

        if (config.show_size) {
            // blocks are 512-byte blocks, GNU ls shows in 1K blocks by default
            const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    // Calculate width for size column
    var size_buf: [32]u8 = undefined;
    const max_size_str = formatSize(max_size, config.human_readable, &size_buf);
    const size_width = max_size_str.len;

    // Calculate widths for numeric columns
    const nlink_width = std.fmt.count("{d}", .{max_nlink});
    const inode_width = if (config.show_inode) std.fmt.count("{d}", .{max_inode}) else 0;

    // For numeric IDs, use the calculated widths; for names, use name lengths
    const owner_width = if (config.numeric_ids) max_uid_len else max_user_len;
    const group_width = if (config.numeric_ids) max_gid_len else max_group_len;

    for (entries) |entry| {
        var mode_buf: [11]u8 = undefined;
        var sz_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;

        const mode_str = formatMode(entry.mode, &mode_buf);
        const size_str = formatSize(entry.size, config.human_readable, &sz_buf);
        const time_str = formatTime(entry.mtime, &time_buf, config.time_style);

        // Print inode if requested
        if (config.show_inode) {
            // Right-align inode
            const inode_str_len = std.fmt.count("{d}", .{entry.inode});
            var pad: usize = 0;
            while (pad + inode_str_len < inode_width) : (pad += 1) {
                writer.interface.writeAll(" ") catch {};
            }
            writer.interface.print("{d} ", .{entry.inode}) catch {};
        }

        // Print allocated size in blocks if -s
        if (config.show_size) {
            const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            var bpad: usize = 0;
            while (bpad + bw < max_blocks_width) : (bpad += 1) {
                writer.interface.writeAll(" ") catch {};
            }
            writer.interface.print("{d} ", .{display_blocks}) catch {};
        }

        // Print mode
        writer.interface.print("{s} ", .{mode_str}) catch {};

        // Print nlink (right-aligned)
        const nlink_str_len = std.fmt.count("{d}", .{entry.nlink});
        var nlink_pad: usize = 0;
        while (nlink_pad + nlink_str_len < nlink_width) : (nlink_pad += 1) {
            writer.interface.writeAll(" ") catch {};
        }
        writer.interface.print("{d} ", .{entry.nlink}) catch {};

        // Print owner (unless -g / hide_owner)
        if (!config.hide_owner) {
            if (config.numeric_ids) {
                // Right-align numeric UID
                const uid_str_len = std.fmt.count("{d}", .{entry.uid});
                var uid_pad: usize = 0;
                while (uid_pad + uid_str_len < owner_width) : (uid_pad += 1) {
                    writer.interface.writeAll(" ") catch {};
                }
                writer.interface.print("{d} ", .{entry.uid}) catch {};
            } else {
                const user = getUserName(entry.uid);
                writer.interface.writeAll(user) catch {};
                var user_pad: usize = user.len;
                while (user_pad < owner_width + 1) : (user_pad += 1) {
                    writer.interface.writeAll(" ") catch {};
                }
            }
        }

        // Print group (unless -o / -G / hide_group)
        if (!config.hide_group) {
            if (config.numeric_ids) {
                // Right-align numeric GID
                const gid_str_len = std.fmt.count("{d}", .{entry.gid});
                var gid_pad: usize = 0;
                while (gid_pad + gid_str_len < group_width) : (gid_pad += 1) {
                    writer.interface.writeAll(" ") catch {};
                }
                writer.interface.print("{d} ", .{entry.gid}) catch {};
            } else {
                const group = getGroupName(entry.gid);
                writer.interface.writeAll(group) catch {};
                var group_pad: usize = group.len;
                while (group_pad < group_width + 1) : (group_pad += 1) {
                    writer.interface.writeAll(" ") catch {};
                }
            }
        }

        // Print size (right-aligned)
        var size_pad: usize = 0;
        while (size_pad + size_str.len < size_width) : (size_pad += 1) {
            writer.interface.writeAll(" ") catch {};
        }
        writer.interface.print("{s} ", .{size_str}) catch {};

        // Print time and space
        writer.interface.print("{s} ", .{time_str}) catch {};

        // Print name with color
        if (use_colors) {
            const color = entry.getColor();
            if (color.len > 0) {
                writer.interface.print("{s}{s}{s}", .{ color, entry.name, Color.reset }) catch {};
            } else {
                writer.interface.writeAll(entry.name) catch {};
            }
        } else {
            writer.interface.writeAll(entry.name) catch {};
        }

        // Print indicator (-F or -p)
        if (config.show_indicators) {
            const indicator = entry.getIndicator();
            if (indicator != 0) {
                writer.interface.print("{c}", .{indicator}) catch {};
            }
        } else if (config.show_dir_indicator) {
            if (entry.isDir()) {
                writer.interface.writeAll("/") catch {};
            }
        }

        // Print symlink target
        if (entry.is_link) {
            if (entry.link_target) |target| {
                writer.interface.print(" -> {s}", .{target}) catch {};
            }
        }

        writer.interface.writeAll("\n") catch {};
    }
}

fn printColumnFormat(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    if (entries.len == 0) return;

    const use_colors = config.useColors();
    const term_width: usize = @intCast(getTerminalWidth());

    // Calculate max entry display length
    var max_name_len: usize = 0;
    var max_blocks_width: usize = 0;
    for (entries) |entry| {
        var len = entry.name.len;
        if (config.show_indicators and entry.getIndicator() != 0) len += 1;
        if (config.show_dir_indicator and entry.isDir()) len += 1;
        if (config.show_inode) len += 10; // space for inode
        if (len > max_name_len) max_name_len = len;
        if (config.show_size) {
            const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    // Add block size column width to max_name_len for column calculation
    const extra_for_size = if (config.show_size) max_blocks_width + 1 else 0;

    const col_width = max_name_len + extra_for_size + 2; // padding
    const num_cols = @max(@as(usize, 1), term_width / col_width);
    const num_rows = (entries.len + num_cols - 1) / num_cols;

    if (config.sort_across) {
        // -x: fill across rows (left-to-right, top-to-bottom)
        var col: usize = 0;
        for (entries) |entry| {
            var printed_len: usize = 0;

            if (config.show_inode) {
                writer.interface.print("{d:>8} ", .{entry.inode}) catch {};
                printed_len += 9;
            }

            if (config.show_size) {
                const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
                const bw = std.fmt.count("{d}", .{display_blocks});
                var bpad: usize = 0;
                while (bpad + bw < max_blocks_width) : (bpad += 1) {
                    writer.interface.writeAll(" ") catch {};
                    printed_len += 1;
                }
                writer.interface.print("{d} ", .{display_blocks}) catch {};
                printed_len += bw + 1;
            }

            printEntryName(writer, entry, use_colors, config);
            printed_len += entry.name.len;
            printed_len += printEntryIndicator(writer, entry, config);

            col += 1;
            if (col >= num_cols) {
                writer.interface.writeAll("\n") catch {};
                col = 0;
            } else {
                if (col_width > printed_len) {
                    const padding = col_width - printed_len;
                    for (0..padding) |_| {
                        writer.interface.writeAll(" ") catch {};
                    }
                }
            }
        }
        if (col > 0) {
            writer.interface.writeAll("\n") catch {};
        }
    } else {
        // Default -C: fill down columns
        for (0..num_rows) |row| {
            var col: usize = 0;
            while (col < num_cols) : (col += 1) {
                const idx = col * num_rows + row;
                if (idx >= entries.len) break;
                const entry = entries[idx];

                var printed_len: usize = 0;

                if (config.show_inode) {
                    writer.interface.print("{d:>8} ", .{entry.inode}) catch {};
                    printed_len += 9;
                }

                if (config.show_size) {
                    const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
                    const bw = std.fmt.count("{d}", .{display_blocks});
                    var bpad: usize = 0;
                    while (bpad + bw < max_blocks_width) : (bpad += 1) {
                        writer.interface.writeAll(" ") catch {};
                        printed_len += 1;
                    }
                    writer.interface.print("{d} ", .{display_blocks}) catch {};
                    printed_len += bw + 1;
                }

                printEntryName(writer, entry, use_colors, config);
                printed_len += entry.name.len;
                printed_len += printEntryIndicator(writer, entry, config);

                // Check if this is the last column printed in this row
                const next_idx = (col + 1) * num_rows + row;
                if (next_idx < entries.len and col + 1 < num_cols) {
                    if (col_width > printed_len) {
                        const padding = col_width - printed_len;
                        for (0..padding) |_| {
                            writer.interface.writeAll(" ") catch {};
                        }
                    }
                }
            }
            writer.interface.writeAll("\n") catch {};
        }
    }
}

fn printEntryName(writer: anytype, entry: FileEntry, use_colors: bool, config: *const Config) void {
    _ = config;
    if (use_colors) {
        const color = entry.getColor();
        if (color.len > 0) {
            writer.interface.print("{s}{s}{s}", .{ color, entry.name, Color.reset }) catch {};
        } else {
            writer.interface.writeAll(entry.name) catch {};
        }
    } else {
        writer.interface.writeAll(entry.name) catch {};
    }
}

fn printEntryIndicator(writer: anytype, entry: FileEntry, config: *const Config) usize {
    if (config.show_indicators) {
        const indicator = entry.getIndicator();
        if (indicator != 0) {
            writer.interface.print("{c}", .{indicator}) catch {};
            return 1;
        }
    } else if (config.show_dir_indicator) {
        if (entry.isDir()) {
            writer.interface.writeAll("/") catch {};
            return 1;
        }
    }
    return 0;
}

fn printOnePerLine(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    const use_colors = config.useColors();

    // Calculate max block width for -s alignment
    var max_blocks_width: usize = 0;
    if (config.show_size) {
        for (entries) |entry| {
            const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    for (entries) |entry| {
        // Print allocated size in blocks if -s
        if (config.show_size) {
            const display_blocks: u64 = @intCast(@divTrunc(entry.blocks + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            var bpad: usize = 0;
            while (bpad + bw < max_blocks_width) : (bpad += 1) {
                writer.interface.writeAll(" ") catch {};
            }
            writer.interface.print("{d} ", .{display_blocks}) catch {};
        }

        // Print inode if requested
        if (config.show_inode) {
            writer.interface.print("{d:>8} ", .{entry.inode}) catch {};
        }

        // Print name with color
        if (use_colors) {
            const color = entry.getColor();
            if (color.len > 0) {
                writer.interface.print("{s}{s}{s}", .{ color, entry.name, Color.reset }) catch {};
            } else {
                writer.interface.writeAll(entry.name) catch {};
            }
        } else {
            writer.interface.writeAll(entry.name) catch {};
        }

        // Print indicator (-F or -p)
        if (config.show_indicators) {
            const indicator = entry.getIndicator();
            if (indicator != 0) {
                writer.interface.print("{c}", .{indicator}) catch {};
            }
        } else if (config.show_dir_indicator) {
            if (entry.isDir()) {
                writer.interface.writeAll("/") catch {};
            }
        }

        writer.interface.writeAll("\n") catch {};
    }
}

fn printCommaSeparated(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    const use_colors = config.useColors();
    const term_width: usize = @intCast(getTerminalWidth());
    var line_len: usize = 0;

    for (entries, 0..) |entry, idx| {
        // Calculate the length this entry will take
        var entry_len = entry.name.len;
        if (config.show_indicators and entry.getIndicator() != 0) entry_len += 1;
        if (config.show_dir_indicator and entry.isDir()) entry_len += 1;

        // Check if we need a separator
        const sep_len: usize = if (idx > 0) 2 else 0; // ", "

        // Check if we'd exceed terminal width
        if (idx > 0) {
            if (line_len + sep_len + entry_len > term_width) {
                writer.interface.writeAll(",\n") catch {};
                line_len = 0;
            } else {
                writer.interface.writeAll(", ") catch {};
                line_len += 2;
            }
        }

        printEntryName(writer, entry, use_colors, config);
        line_len += entry.name.len;
        line_len += printEntryIndicator(writer, entry, config);
    }

    if (entries.len > 0) {
        writer.interface.writeAll("\n") catch {};
    }
}

fn listPath(allocator: std.mem.Allocator, writer: anytype, path: []const u8, config: *const Config, print_header: bool) !void {
    // Check if path is a file or directory
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat_buf: Stat = undefined;
    const stat_result = lstat(path_z.ptr, &stat_buf);

    if (stat_result != 0) {
        std.debug.print("zls: cannot access '{s}': No such file or directory\n", .{path});
        return error.FileNotFound;
    }

    const is_dir = (stat_buf.mode & 0o170000) == 0o40000;
    const entry_mtime = stat_buf.mtime();

    if (!is_dir or config.directory_only) {
        // Single file - just print it
        var entry = FileEntry{
            .name = path,
            .name_owned = false,
            .mode = stat_buf.mode,
            .nlink = @intCast(stat_buf.nlink),
            .uid = stat_buf.uid,
            .gid = stat_buf.gid,
            .size = @intCast(stat_buf.size),
            .blocks = stat_buf.blocks,
            .mtime = entry_mtime.sec,
            .inode = stat_buf.ino,
            .is_link = (stat_buf.mode & 0o170000) == 0o120000,
            .link_target = null,
        };

        if (entry.is_link) {
            var link_buf: [4096]u8 = undefined;
            const link_len = libc.readlink(path_z.ptr, &link_buf, link_buf.len);
            if (link_len > 0) {
                entry.link_target = try allocator.dupe(u8, link_buf[0..@intCast(link_len)]);
            }
        }
        defer if (entry.link_target) |t| allocator.free(t);

        var entries = [_]FileEntry{entry};
        if (config.long_format) {
            printLongFormat(writer, &entries, config);
        } else if (config.comma_separated) {
            printCommaSeparated(writer, &entries, config);
        } else if (config.one_per_line) {
            printOnePerLine(writer, &entries, config);
        } else {
            printColumnFormat(writer, &entries, config);
        }
        return;
    }

    // Directory listing
    if (print_header) {
        writer.interface.print("{s}:\n", .{path}) catch {};
    }

    var entries = readDirEntries(allocator, path, config) catch |err| {
        std.debug.print("zls: cannot open directory '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    sortEntries(entries.items, config);

    // Print "total" line for long format or -s
    if (config.long_format or config.show_size) {
        var total_blocks: i64 = 0;
        for (entries.items) |e| {
            total_blocks += e.blocks;
        }
        writer.interface.print("total {d}\n", .{@divTrunc(total_blocks, 2)}) catch {};
    }

    if (config.long_format) {
        printLongFormat(writer, entries.items, config);
    } else if (config.comma_separated) {
        printCommaSeparated(writer, entries.items, config);
    } else if (config.one_per_line) {
        printOnePerLine(writer, entries.items, config);
    } else {
        printColumnFormat(writer, entries.items, config);
    }

    // Recursive listing
    if (config.recursive) {
        for (entries.items) |entry| {
            if (entry.isDir() and !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
                const subpath = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
                defer allocator.free(subpath);

                writer.interface.writeAll("\n") catch {};
                listPath(allocator, writer, subpath, config, true) catch {};
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--color=always")) {
                    config.color_mode = .always;
                } else if (std.mem.eql(u8, arg, "--color=never")) {
                    config.color_mode = .never;
                } else if (std.mem.eql(u8, arg, "--color=auto")) {
                    config.color_mode = .auto;
                } else if (std.mem.startsWith(u8, arg, "--color=")) {
                    config.color_mode = .always;
                } else if (std.mem.eql(u8, arg, "--time-style=long-iso")) {
                    config.time_style = .long_iso;
                } else if (std.mem.eql(u8, arg, "--time-style=full-iso")) {
                    config.time_style = .full_iso;
                } else if (std.mem.eql(u8, arg, "--time-style=iso")) {
                    config.time_style = .iso;
                } else if (std.mem.startsWith(u8, arg, "--time-style=")) {
                    config.time_style = .default;
                } else if (std.mem.eql(u8, arg, "--numeric-uid-gid")) {
                    config.numeric_ids = true;
                    config.long_format = true;
                } else if (std.mem.eql(u8, arg, "--no-group")) {
                    config.hide_group = true;
                } else if (std.mem.eql(u8, arg, "--group-directories-first")) {
                    config.group_directories_first = true;
                } else {
                    std.debug.print("zls: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                // Short options
                for (arg[1..]) |ch| {
                    switch (ch) {
                        '1' => config.one_per_line = true,
                        'l' => config.long_format = true,
                        'a' => config.show_all = true,
                        'A' => config.show_almost_all = true,
                        'h' => config.human_readable = true,
                        'S' => config.sort_mode = .size,
                        't' => config.sort_mode = .time,
                        'r' => config.reverse_sort = true,
                        'R' => config.recursive = true,
                        'F' => config.show_indicators = true,
                        'i' => config.show_inode = true,
                        'd' => config.directory_only = true,
                        'C' => config.columnar = true,
                        'X' => config.sort_mode = .extension,
                        's' => config.show_size = true,
                        'n' => {
                            config.numeric_ids = true;
                            config.long_format = true;
                        },
                        'g' => {
                            config.hide_owner = true;
                            config.long_format = true;
                        },
                        'o' => {
                            config.hide_group = true;
                            config.long_format = true;
                        },
                        'G' => config.hide_group = true,
                        'p' => config.show_dir_indicator = true,
                        'm' => config.comma_separated = true,
                        'x' => config.sort_across = true,
                        else => {
                            std.debug.print("zls: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.paths.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Default to current directory
    if (config.paths.items.len == 0) {
        try config.paths.append(allocator, try allocator.dupe(u8, "."));
    }

    return config;
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zls [OPTION]... [FILE]...
        \\List information about the FILEs (the current directory by default).
        \\
        \\  -1             one entry per line
        \\  -a, --all      show all entries including hidden
        \\  -A             show all except . and ..
        \\  -C             list entries in columns
        \\  -d             list directories themselves, not their contents
        \\  -F             append indicator (*/=>@|)
        \\  -g             like -l, but do not list owner
        \\  -G, --no-group in long listing, don't print group names
        \\  -h             human readable sizes
        \\  -i             print inode number
        \\  -l             long listing format
        \\  -m             fill width with a comma separated list of entries
        \\  -n, --numeric-uid-gid  like -l, but list numeric user and group IDs
        \\  -o             like -l, but do not list group information
        \\  -p             append / indicator to directories
        \\  -r             reverse sort order
        \\  -R             list subdirectories recursively
        \\  -s             print the allocated size of each file, in blocks
        \\  -S             sort by size (largest first)
        \\  -t             sort by time (newest first)
        \\  -x             list entries by lines instead of by columns
        \\  -X             sort alphabetically by extension
        \\      --color    colorize output (auto/always/never)
        \\      --group-directories-first  group directories before files
        \\      --time-style=STYLE  with -l, show times using style STYLE:
        \\                          full-iso, long-iso, iso
        \\      --help     display this help
        \\      --version  output version information
        \\
        \\zls - High-performance ls utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zls 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    // Set locale for strcoll-based sorting to match GNU ls behavior
    _ = setlocale(6, ""); // LC_ALL = 6 on Linux, "" = use environment
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zls: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Default to one-per-line when stdout is not a tty (piped)
    if (!config.long_format and !config.one_per_line and !config.columnar and !config.comma_separated and !config.sort_across) {
        if (isatty(1) == 0) {
            config.one_per_line = true;
        }
    }

    const io = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer = stdout.writerStreaming(io, &buf);

    const multiple_paths = config.paths.items.len > 1;
    var first = true;
    var error_occurred = false;

    for (config.paths.items) |path| {
        if (!first) {
            writer.interface.writeAll("\n") catch {};
        }
        first = false;

        listPath(allocator, &writer, path, &config, multiple_paths or config.recursive) catch {
            error_occurred = true;
        };
    }

    writer.interface.flush() catch {};

    if (error_occurred) {
        std.process.exit(1);
    }
}
