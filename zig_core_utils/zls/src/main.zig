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

// Cross-platform Stat structure.
// NOTE: struct stat layout differs per (OS, arch); the hand-rolled layouts
// below are gated per-arch. Anything unlisted falls back to std.c.Stat.
const Stat = switch (builtin.os.tag) {
    .linux => switch (builtin.cpu.arch) {
        // x86_64 glibc layout
        .x86_64 => extern struct {
            dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
            __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
            atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
            __unused: [3]i64 = .{ 0, 0, 0 },
            pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
        },
        // aarch64 glibc layout (generic asm-generic stat): st_nlink is u32 and
        // sits AFTER st_mode; padding differs from x86_64.
        .aarch64 => extern struct {
            dev: u64, ino: u64, mode: u32, nlink: u32, uid: u32, gid: u32,
            rdev: u64, __pad1: u64 = 0, size: i64, blksize: i32, __pad2: i32 = 0,
            blocks: i64,
            atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
            __unused: [2]u32 = .{ 0, 0 },
            pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
        },
        else => libc.Stat,
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

const TimeStyle = enum { default, long_iso, full_iso, iso, custom };

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
    // -q / --hide-control-chars: null = auto (on when stdout is a tty),
    // matching GNU ls's default of hiding control characters on terminals.
    hide_control_chars: ?bool = null,
    time_format: ?[]const u8 = null, // --time-style=+FORMAT (strftime)
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.paths.items) |item| {
            allocator.free(item);
        }
        self.paths.deinit(allocator);
        if (self.time_format) |tf| allocator.free(tf);
    }

    fn useColors(self: *const Config) bool {
        return switch (self.color_mode) {
            .always => true,
            .never => false,
            .auto => isatty(1) != 0,
        };
    }

    /// GNU ls hides control characters (prints '?') when stdout is a tty
    /// unless overridden; this prevents terminal escape injection from
    /// hostile filenames.
    fn hideControls(self: *const Config) bool {
        return self.hide_control_chars orelse (isatty(1) != 0);
    }
};

extern "c" fn isatty(fd: c_int) c_int;

const FileEntry = struct {
    // NUL-terminated so strcoll can use it directly (no per-comparison copy).
    name: [:0]const u8,
    name_owned: bool,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    size: u64,
    blocks: i64,
    mtime: i64,
    mtime_nsec: i64,
    inode: u64,
    is_link: bool,
    link_target: ?[]const u8,
    // Mode of the symlink's resolved target (populated only when needed for
    // -lF, where GNU classifies the TARGET, not the link name).
    target_mode: ?u32 = null,
    // Symlink resolves to a directory (GNU groups such links with the
    // directories under --group-directories-first).
    resolves_dir: bool = false,
    // lstat failed for this entry: metadata fields are zero/unknown.
    stat_failed: bool = false,

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
        return modeIndicator(self.mode);
    }
};

fn modeIndicator(mode: u32) u8 {
    const fmt = mode & 0o170000;
    if (fmt == 0o40000) return '/';
    if (fmt == 0o120000) return '@';
    if ((mode & 0o111) != 0 and fmt == 0o100000) return '*';
    if (fmt == 0o10000) return '|';
    if (fmt == 0o140000) return '=';
    return 0;
}

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

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getTerminalWidth() u16 {
    // GNU ls precedence: start at 80, let $COLUMNS override, then let the
    // TIOCGWINSZ ioctl override that when stdout is a real terminal. On a
    // pipe the ioctl fails, so $COLUMNS is what wins (matches GNU behavior
    // for `COLUMNS=20 ls -C | cat`).
    var width: u16 = 80;
    if (getenv("COLUMNS")) |c| {
        const s = std.mem.span(c);
        if (std.fmt.parseInt(u16, s, 10)) |v| {
            if (v > 0) width = v;
        } else |_| {}
    }
    var ws: libc.winsize = undefined;
    const result = libc.ioctl(1, libc.T.IOCGWINSZ, &ws);
    if (result == 0 and ws.col > 0) {
        width = ws.col;
    }
    return width;
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

    // GNU ls -h rounds UP (human_ceiling): 10444 bytes -> "11K", not "10K".
    const units = [_][]const u8{ "", "K", "M", "G", "T", "P" };
    var s: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (s >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{size}) catch "?";
    }

    // Round up to one decimal; if that pushes us to >= 1024, bump the unit.
    var scaled = @ceil(s * 10) / 10;
    if (scaled >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
        scaled = @ceil(s * 10) / 10;
    }

    if (scaled < 10) {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ scaled, units[unit_idx] }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ @ceil(s), units[unit_idx] }) catch "?";
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
extern "c" fn strftime(buf: [*]u8, maxsize: usize, format: [*:0]const u8, tm: *const CTm) usize;

fn formatTime(mtime: i64, mtime_nsec: i64, buf: []u8, config: *const Config) []const u8 {
    const time_style = config.time_style;

    // Get current time to decide format
    var now_ts: libc.timespec = undefined;
    _ = libc.clock_gettime(libc.CLOCK.REALTIME, &now_ts);
    const now = now_ts.sec;

    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    // Use localtime_r for proper timezone handling. On failure (extreme or
    // hostile mtime values) fall back to printing the raw epoch seconds
    // instead of reading an uninitialized struct.
    var tm: CTm = undefined;
    if (localtime_r(&mtime, &tm) == null) {
        return std.fmt.bufPrint(buf, "{d}", .{mtime}) catch "?";
    }

    const day = tm.tm_mday;
    // Clamp: never index months[] with out-of-range libc output.
    const month: usize = @intCast(std.math.clamp(tm.tm_mon, 0, 11));
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
            // YYYY-MM-DD HH:MM:SS.NNNNNNNNN +ZZZZ (GNU full-iso includes
            // nanoseconds and the UTC offset)
            const mon: u32 = @intCast(month + 1);
            const d: u32 = @intCast(day);
            const h: u32 = @intCast(hours);
            const m: u32 = @intCast(mins);
            const s: u32 = @intCast(secs);
            const nsec: u32 = @intCast(std.math.clamp(mtime_nsec, 0, 999_999_999));
            const off_min = @divTrunc(tm.tm_gmtoff, 60);
            const off_sign: u8 = if (off_min < 0) '-' else '+';
            const off_abs: u32 = @intCast(@abs(off_min));
            return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9} {c}{d:0>2}{d:0>2}", .{
                year, mon, d, h, m, s, nsec, off_sign, off_abs / 60, off_abs % 60,
            }) catch "?";
        },
        .custom => {
            // --time-style=+FORMAT via libc strftime
            const fmt = config.time_format orelse return "?";
            var fmt_buf: [256]u8 = undefined;
            if (fmt.len >= fmt_buf.len) return "?";
            @memcpy(fmt_buf[0..fmt.len], fmt);
            fmt_buf[fmt.len] = 0;
            const n = strftime(buf.ptr, buf.len, fmt_buf[0..fmt.len :0], &tm);
            if (n == 0 and fmt.len != 0) return "?";
            return buf[0..n];
        },
        .iso => {
            // MM-DD HH:MM or YYYY-MM-DD
            // GNU: half a Gregorian year (31556952/2 seconds)
            const six_months_ago = now - 15778476;
            const mon: u32 = @intCast(month + 1);
            const d: u32 = @intCast(day);
            const h: u32 = @intCast(hours);
            const m: u32 = @intCast(mins);
            if (mtime < six_months_ago or mtime > now) {
                // GNU's iso old-file format is "%Y-%m-%d " — note the
                // trailing blank that keeps the column 11 wide.
                return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} ", .{ year, mon, d }) catch "?";
            } else {
                return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ mon, d, h, m }) catch "?";
            }
        },
        .default => {
            // GNU: half a Gregorian year (31556952/2 seconds)
            const six_months_ago = now - 15778476;

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

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn errnoText() []const u8 {
    return std.mem.span(strerror(std.c._errno().*));
}

// GNU ls exit status: 1 = minor problems (e.g. cannot access a subdirectory
// or a directory entry), 2 = serious trouble (cannot access a command-line
// argument, invalid option). Single-threaded program: plain globals.
var exit_minor: bool = false;
var exit_serious: bool = false;

/// Build a FileEntry from a stat buffer, with saturating casts so hostile
/// filesystem values (negative st_size, huge nlink) cannot panic or wrap.
fn entryFromStat(name: [:0]const u8, name_owned: bool, stat_buf: *const Stat) FileEntry {
    const mtime = stat_buf.mtime();
    return .{
        .name = name,
        .name_owned = name_owned,
        .mode = stat_buf.mode,
        .nlink = std.math.lossyCast(u32, stat_buf.nlink),
        .uid = stat_buf.uid,
        .gid = stat_buf.gid,
        .size = @intCast(@max(0, stat_buf.size)),
        .blocks = stat_buf.blocks,
        .mtime = mtime.sec,
        .mtime_nsec = mtime.nsec,
        .inode = stat_buf.ino,
        .is_link = (stat_buf.mode & 0o170000) == 0o120000,
        .link_target = null,
    };
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
        std.debug.print("zls: cannot open directory '{s}': {s}\n", .{ path, errnoText() });
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
        const full_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ path, name }, 0);
        defer allocator.free(full_path);

        var stat_buf: Stat = undefined;
        const stat_result = lstat(full_path.ptr, &stat_buf);

        const owned_name = try allocator.dupeZ(u8, name);
        var file_entry: FileEntry = if (stat_result == 0)
            entryFromStat(owned_name, true, &stat_buf)
        else blk: {
            // GNU still lists the entry (with unknown metadata) and warns.
            std.debug.print("zls: cannot access '{s}': {s}\n", .{ full_path, errnoText() });
            exit_minor = true;
            break :blk .{
                .name = owned_name,
                .name_owned = true,
                .mode = 0,
                .nlink = 0,
                .uid = 0,
                .gid = 0,
                .size = 0,
                .blocks = 0,
                .mtime = 0,
                .mtime_nsec = 0,
                .inode = 0,
                .is_link = false,
                .link_target = null,
                .stat_failed = true,
            };
        };
        errdefer file_entry.deinit(allocator);

        // Read symlink target
        if (file_entry.is_link) {
            var link_buf: [4096]u8 = undefined;
            const link_len = libc.readlink(full_path.ptr, &link_buf, link_buf.len);
            if (link_len > 0) {
                if (@as(usize, @intCast(link_len)) == link_buf.len) {
                    // Truncated target: warn rather than print a wrong target.
                    std.debug.print("zls: cannot read symbolic link '{s}': name too long\n", .{full_path});
                    exit_minor = true;
                } else {
                    file_entry.link_target = try allocator.dupe(u8, link_buf[0..@intCast(link_len)]);
                }
            }
            // -lF classifies the resolved target, and
            // --group-directories-first groups dir-targeting symlinks with
            // the directories; only stat when needed.
            if ((config.show_indicators and config.long_format) or config.group_directories_first) {
                var target_stat: Stat = undefined;
                if (stat(full_path.ptr, &target_stat) == 0) {
                    file_entry.target_mode = target_stat.mode;
                    file_entry.resolves_dir = (target_stat.mode & 0o170000) == 0o40000;
                }
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

/// True when the active locale is the POSIX/C locale (approximates GNU's
/// hard_locale(LC_TIME) check used for posix-* time styles).
fn localeIsPosix() bool {
    const cur = setlocale(LC_ALL, null) orelse return true;
    const s = std.mem.span(cur);
    return std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX");
}

fn nameCmp(a_name: [:0]const u8, b_name: [:0]const u8) bool {
    // Locale-aware comparison matching GNU ls (xstrcoll). Names are stored
    // NUL-terminated in FileEntry, so no per-comparison copy is needed.
    return strcoll(a_name.ptr, b_name.ptr) < 0;
}

// Sorting matches GNU coreutils ls.c:
// - -r swaps the comparator's OPERANDS (GNU's rev_* comparators call
//   compare(b, a)); it never negates the result. Negating `!lessThan(a,b)`
//   makes lessThan(a,b) and lessThan(b,a) both true for equal keys, which
//   violates strict weak ordering and aborts std.sort (`zls -ltr` panic).
// - -t / -S tie-break on the collated name (GNU cmp_mtime/cmp_size fall
//   back to the name comparator).
// - --group-directories-first applies OUTSIDE the reversal (GNU's *_df
//   wrappers), so directories stay first even under -r.
fn sortEntries(entries: []FileEntry, config: *const Config) void {
    const cmp = struct {
        fn keyLess(ctx: *const Config, a: *const FileEntry, b: *const FileEntry) bool {
            switch (ctx.sort_mode) {
                .name => return nameCmp(a.name, b.name),
                .size => {
                    if (a.size != b.size) return a.size > b.size; // largest first
                    return nameCmp(a.name, b.name);
                },
                .time => {
                    if (a.mtime != b.mtime) return a.mtime > b.mtime; // newest first
                    if (a.mtime_nsec != b.mtime_nsec) return a.mtime_nsec > b.mtime_nsec;
                    return nameCmp(a.name, b.name);
                },
                .extension => {
                    const order = std.mem.order(u8, getExtension(a.name), getExtension(b.name));
                    if (order != .eq) return order == .lt;
                    return nameCmp(a.name, b.name);
                },
                .none => unreachable,
            }
        }

        fn lessThan(ctx: *const Config, a: FileEntry, b: FileEntry) bool {
            if (ctx.group_directories_first) {
                const a_dir = a.isDir() or a.resolves_dir;
                const b_dir = b.isDir() or b.resolves_dir;
                if (a_dir != b_dir) return a_dir;
            }
            if (ctx.reverse_sort) return keyLess(ctx, &b, &a);
            return keyLess(ctx, &a, &b);
        }
    };

    if (config.sort_mode == .none) return;
    std.mem.sort(FileEntry, entries, config, cmp.lessThan);
}

/// Write a file name, replacing control characters with '?' when the config
/// says to hide them (GNU -q, on by default when stdout is a tty). Prevents
/// terminal escape injection / fake-listing-line spoofing from hostile names.
fn writeName(writer: anytype, name: []const u8, config: *const Config) void {
    if (!config.hideControls()) {
        writer.interface.writeAll(name) catch {};
        return;
    }
    for (name) |c| {
        const out: u8 = if (c < 0x20 or c == 0x7f) '?' else c;
        writer.interface.writeByte(out) catch {};
    }
}

fn printLongFormat(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    const use_colors = config.useColors();

    // Calculate column widths
    var max_nlink: u32 = 0;
    var max_user_len: usize = 0;
    var max_group_len: usize = 0;
    var max_inode: u64 = 0;
    var max_blocks_width: usize = 0;
    var max_uid_len: usize = 0;
    var max_gid_len: usize = 0;

    for (entries) |entry| {
        if (entry.nlink > max_nlink) max_nlink = entry.nlink;
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
            const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    // Calculate width for size column: widest FORMATTED size (with -h the
    // largest size does not always format widest, e.g. "999" vs "1.0K").
    var size_width: usize = 0;
    for (entries) |entry| {
        var size_buf: [32]u8 = undefined;
        const s = formatSize(entry.size, config.human_readable, &size_buf);
        if (s.len > size_width) size_width = s.len;
    }

    // Calculate widths for numeric columns
    const nlink_width = std.fmt.count("{d}", .{max_nlink});
    const inode_width = if (config.show_inode) std.fmt.count("{d}", .{max_inode}) else 0;

    // For numeric IDs, use the calculated widths; for names, use name lengths
    const owner_width = if (config.numeric_ids) max_uid_len else max_user_len;
    const group_width = if (config.numeric_ids) max_gid_len else max_group_len;

    for (entries) |entry| {
        var mode_buf: [11]u8 = undefined;
        var sz_buf: [32]u8 = undefined;
        var time_buf: [128]u8 = undefined;

        const mode_str = formatMode(entry.mode, &mode_buf);
        const size_str = formatSize(entry.size, config.human_readable, &sz_buf);
        const time_str = formatTime(entry.mtime, entry.mtime_nsec, &time_buf, config);

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
            const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
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
                writer.interface.writeAll(color) catch {};
                writeName(writer, entry.name, config);
                writer.interface.writeAll(Color.reset) catch {};
            } else {
                writeName(writer, entry.name, config);
            }
        } else {
            writeName(writer, entry.name, config);
        }

        // Print indicator (-F or -p). GNU long format never marks the link
        // NAME with '@'; with -F the indicator classifies the TARGET.
        if (config.show_indicators) {
            if (!entry.is_link) {
                const indicator = entry.getIndicator();
                if (indicator != 0) {
                    writer.interface.print("{c}", .{indicator}) catch {};
                }
            }
        } else if (config.show_dir_indicator) {
            if (entry.isDir()) {
                writer.interface.writeAll("/") catch {};
            }
        }

        // Print symlink target
        if (entry.is_link) {
            if (entry.link_target) |target| {
                writer.interface.writeAll(" -> ") catch {};
                writeName(writer, target, config);
                if (config.show_indicators) {
                    if (entry.target_mode) |tm| {
                        const ti = modeIndicator(tm);
                        if (ti != 0) writer.interface.print("{c}", .{ti}) catch {};
                    }
                }
            }
        }

        writer.interface.writeAll("\n") catch {};
    }
}

/// Full printed width of one entry cell: optional inode + block-size prefixes
/// plus the name and any -F/-p indicator. Must stay byte-for-byte in sync with
/// printColumnCell so the column layout math matches what is emitted.
fn entryDisplayWidth(entry: FileEntry, config: *const Config, max_blocks_width: usize) usize {
    var w: usize = entry.name.len;
    if (config.show_indicators) {
        if (entry.getIndicator() != 0) w += 1;
    } else if (config.show_dir_indicator) {
        if (entry.isDir()) w += 1;
    }
    if (config.show_inode) {
        const iw = std.fmt.count("{d}", .{entry.inode});
        w += @max(@as(usize, 8), iw) + 1; // "{d:>8} "
    }
    if (config.show_size) w += max_blocks_width + 1;
    return w;
}

/// Emit one entry cell (prefixes + name + indicator) and return the number of
/// columns written — identical to entryDisplayWidth for the same entry.
fn printColumnCell(writer: anytype, entry: FileEntry, use_colors: bool, config: *const Config, max_blocks_width: usize) usize {
    var printed: usize = 0;
    if (config.show_inode) {
        writer.interface.print("{d:>8} ", .{entry.inode}) catch {};
        printed += @max(@as(usize, 8), std.fmt.count("{d}", .{entry.inode})) + 1;
    }
    if (config.show_size) {
        const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
        const bw = std.fmt.count("{d}", .{display_blocks});
        var bpad: usize = 0;
        while (bpad + bw < max_blocks_width) : (bpad += 1) {
            writer.interface.writeAll(" ") catch {};
        }
        writer.interface.print("{d} ", .{display_blocks}) catch {};
        printed += max_blocks_width + 1;
    }
    printEntryName(writer, entry, use_colors, config);
    printed += entry.name.len;
    printed += printEntryIndicator(writer, entry, config);
    return printed;
}

/// Advance the output column from `from` to `to`, emitting a tab whenever it
/// lands past the next tab stop and a space otherwise. Mirrors GNU coreutils
/// ls.c indent() with the default tabsize of 8 (so column padding is
/// byte-identical to GNU, which prefers tabs over runs of spaces).
fn indent(writer: anytype, from_col: usize, to_col: usize) void {
    const tabsize: usize = 8;
    var from = from_col;
    while (from < to_col) {
        if (to_col / tabsize > (from + 1) / tabsize) {
            writer.interface.writeAll("\t") catch {};
            from += tabsize - from % tabsize;
        } else {
            writer.interface.writeAll(" ") catch {};
            from += 1;
        }
    }
}

/// Fallback used when the column-layout allocation fails: one entry per line.
fn printColumnFallback(writer: anytype, entries: []const FileEntry, config: *const Config, use_colors: bool, max_blocks_width: usize) void {
    for (entries) |entry| {
        _ = printColumnCell(writer, entry, use_colors, config, max_blocks_width);
        writer.interface.writeAll("\n") catch {};
    }
}

/// Multi-column layout (-C, -x, and the default terminal format). This is a
/// faithful port of GNU coreutils 9.10 ls.c: calculate_columns() +
/// print_many_per_line() / print_horizontal(). Column widths are per-column
/// (not a single uniform width), padding uses tabs via indent(), and the fit
/// test replicates GNU's MIN_COLUMN_WIDTH seeding and strict `<` comparison —
/// so the byte output matches GNU across varied-width filename sets and the
/// $COLUMNS width. See the anchored parity tests in gnu_parity_test.zig.
fn printColumnFormat(allocator: std.mem.Allocator, writer: anytype, entries: []const FileEntry, config: *const Config) void {
    if (entries.len == 0) return;

    const use_colors = config.useColors();
    const line_length: usize = @intCast(getTerminalWidth());
    const n = entries.len;
    const across = config.sort_across;
    const MIN_COLUMN_WIDTH: usize = 3;

    // -s block-count column width (shared across all entries).
    var max_blocks_width: usize = 0;
    if (config.show_size) {
        for (entries) |entry| {
            const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    // Per-entry display widths (name + optional inode/size frills + indicator).
    const widths = allocator.alloc(usize, n) catch
        return printColumnFallback(writer, entries, config, use_colors, max_blocks_width);
    defer allocator.free(widths);
    for (entries, 0..) |entry, i| widths[i] = entryDisplayWidth(entry, config, max_blocks_width);

    // GNU: max_idx = line_length / MIN + (line_length % MIN != 0), then the
    // candidate count is capped by the number of files.
    var max_idx = line_length / MIN_COLUMN_WIDTH;
    if (line_length % MIN_COLUMN_WIDTH != 0) max_idx += 1;
    const max_cols = if (max_idx > 0 and max_idx < n) max_idx else n;

    // column_info: candidate i (0-based) describes an (i+1)-column layout.
    // col_arr is a triangle: candidate i owns entries [i*(i+1)/2 .. +(i+1)).
    const valid = allocator.alloc(bool, max_cols) catch
        return printColumnFallback(writer, entries, config, use_colors, max_blocks_width);
    defer allocator.free(valid);
    const line_len = allocator.alloc(usize, max_cols) catch
        return printColumnFallback(writer, entries, config, use_colors, max_blocks_width);
    defer allocator.free(line_len);
    const col_arr = allocator.alloc(usize, max_cols * (max_cols + 1) / 2) catch
        return printColumnFallback(writer, entries, config, use_colors, max_blocks_width);
    defer allocator.free(col_arr);

    for (0..max_cols) |i| {
        valid[i] = true;
        line_len[i] = (i + 1) * MIN_COLUMN_WIDTH;
        const off = i * (i + 1) / 2;
        for (0..i + 1) |j| col_arr[off + j] = MIN_COLUMN_WIDTH;
    }

    for (0..n) |filesno| {
        const nl = widths[filesno];
        for (0..max_cols) |i| {
            if (!valid[i]) continue;
            const idx = if (across) filesno % (i + 1) else filesno / ((n + i) / (i + 1));
            const real_length = nl + (if (idx == i) @as(usize, 0) else 2);
            const off = i * (i + 1) / 2;
            if (col_arr[off + idx] < real_length) {
                line_len[i] += real_length - col_arr[off + idx];
                col_arr[off + idx] = real_length;
                valid[i] = line_len[i] < line_length;
            }
        }
    }

    var cols: usize = max_cols;
    while (cols > 1 and !valid[cols - 1]) cols -= 1;

    const win = col_arr[(cols - 1) * cols / 2 ..][0..cols];
    const rows = (n + cols - 1) / cols;

    if (across) {
        // print_horizontal: fill left-to-right, top-to-bottom.
        var pos: usize = 0;
        var name_length = printColumnCell(writer, entries[0], use_colors, config, max_blocks_width);
        var max_name_length = win[0];
        var filesno: usize = 1;
        while (filesno < n) : (filesno += 1) {
            const col = filesno % cols;
            if (col == 0) {
                writer.interface.writeAll("\n") catch {};
                pos = 0;
            } else {
                indent(writer, pos + name_length, pos + max_name_length);
                pos += max_name_length;
            }
            name_length = printColumnCell(writer, entries[filesno], use_colors, config, max_blocks_width);
            max_name_length = win[col];
        }
        writer.interface.writeAll("\n") catch {};
    } else {
        // print_many_per_line: fill down columns.
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            var col: usize = 0;
            var filesno: usize = row;
            var pos: usize = 0;
            while (true) {
                const name_length = printColumnCell(writer, entries[filesno], use_colors, config, max_blocks_width);
                const max_name_length = win[col];
                col += 1;
                if (n - rows <= filesno) break;
                filesno += rows;
                indent(writer, pos + name_length, pos + max_name_length);
                pos += max_name_length;
            }
            writer.interface.writeAll("\n") catch {};
        }
    }
}

fn printEntryName(writer: anytype, entry: FileEntry, use_colors: bool, config: *const Config) void {
    if (use_colors) {
        const color = entry.getColor();
        if (color.len > 0) {
            writer.interface.writeAll(color) catch {};
            writeName(writer, entry.name, config);
            writer.interface.writeAll(Color.reset) catch {};
        } else {
            writeName(writer, entry.name, config);
        }
    } else {
        writeName(writer, entry.name, config);
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
            const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
            const bw = std.fmt.count("{d}", .{display_blocks});
            if (bw > max_blocks_width) max_blocks_width = bw;
        }
    }

    for (entries) |entry| {
        // Print allocated size in blocks if -s
        if (config.show_size) {
            const display_blocks: u64 = @intCast(@divTrunc(@max(0, entry.blocks) + 1, 2));
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
        printEntryName(writer, entry, use_colors, config);

        // Print indicator (-F or -p)
        _ = printEntryIndicator(writer, entry, config);

        writer.interface.writeAll("\n") catch {};
    }
}

fn printCommaSeparated(writer: anytype, entries: []const FileEntry, config: *const Config) void {
    // Faithful port of GNU coreutils 9.10 ls.c print_with_separator(','):
    // stay on the current line while `pos + len + 2 < line_length` (strict),
    // otherwise wrap. The comma is always emitted after the previous entry,
    // followed by a space (same line) or newline (wrap).
    const use_colors = config.useColors();
    const line_length: usize = @intCast(getTerminalWidth());
    var pos: usize = 0;

    for (entries, 0..) |entry, filesno| {
        var len = entry.name.len;
        if (config.show_indicators and entry.getIndicator() != 0) len += 1;
        if (config.show_dir_indicator and entry.isDir()) len += 1;

        if (filesno != 0) {
            const same_line = pos + len + 2 < line_length;
            if (same_line) {
                pos += 2;
            } else {
                pos = 0;
            }
            writer.interface.writeAll(",") catch {};
            writer.interface.writeAll(if (same_line) " " else "\n") catch {};
        }

        printEntryName(writer, entry, use_colors, config);
        _ = printEntryIndicator(writer, entry, config);
        pos += len;
    }

    if (entries.len > 0) {
        writer.interface.writeAll("\n") catch {};
    }
}

fn printEntries(allocator: std.mem.Allocator, writer: anytype, entries: []const FileEntry, config: *const Config) void {
    if (config.long_format) {
        printLongFormat(writer, entries, config);
    } else if (config.comma_separated) {
        printCommaSeparated(writer, entries, config);
    } else if (config.one_per_line) {
        printOnePerLine(writer, entries, config);
    } else {
        printColumnFormat(allocator, writer, entries, config);
    }
}

fn listDirectory(allocator: std.mem.Allocator, writer: anytype, path: []const u8, config: *const Config, print_header: bool) !void {
    if (print_header) {
        writeName(writer, path, config);
        writer.interface.writeAll(":\n") catch {};
    }

    // readDirEntries prints the strerror-based diagnostic itself.
    var entries = try readDirEntries(allocator, path, config);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    sortEntries(entries.items, config);

    // Print "total" line for long format or -s. GNU converts the 512-byte
    // block sum through the active size formatting (-h => "total 12K").
    if (config.long_format or config.show_size) {
        var total_blocks: i64 = 0;
        for (entries.items) |e| {
            total_blocks += e.blocks;
        }
        if (config.human_readable) {
            var tbuf: [32]u8 = undefined;
            const bytes: u64 = @intCast(@max(0, total_blocks) * 512);
            writer.interface.print("total {s}\n", .{formatSize(bytes, true, &tbuf)}) catch {};
        } else {
            writer.interface.print("total {d}\n", .{@divTrunc(@max(0, total_blocks), 2)}) catch {};
        }
    }

    printEntries(allocator, writer, entries.items, config);

    // Recursive listing: failures below the command line are "minor" (GNU
    // exits 1 for these, 2 only for command-line operands).
    if (config.recursive) {
        for (entries.items) |entry| {
            if (entry.isDir() and !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
                const subpath = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
                defer allocator.free(subpath);

                writer.interface.writeAll("\n") catch {};
                listDirectory(allocator, writer, subpath, config, true) catch {
                    exit_minor = true;
                };
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
    // After a bare "--" operand, GNU treats every remaining arg as a path,
    // even if it begins with '-' (POSIX end-of-options idiom: `ls -- -l`).
    var end_of_options = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }

        if (!end_of_options and arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--all")) {
                    config.show_all = true;
                } else if (std.mem.eql(u8, arg, "--almost-all")) {
                    config.show_almost_all = true;
                } else if (std.mem.eql(u8, arg, "--reverse")) {
                    config.reverse_sort = true;
                } else if (std.mem.eql(u8, arg, "--recursive")) {
                    config.recursive = true;
                } else if (std.mem.eql(u8, arg, "--human-readable")) {
                    config.human_readable = true;
                } else if (std.mem.eql(u8, arg, "--inode")) {
                    config.show_inode = true;
                } else if (std.mem.eql(u8, arg, "--directory")) {
                    config.directory_only = true;
                } else if (std.mem.eql(u8, arg, "--classify")) {
                    config.show_indicators = true;
                } else if (std.mem.eql(u8, arg, "--size")) {
                    config.show_size = true;
                } else if (std.mem.eql(u8, arg, "--hide-control-chars")) {
                    config.hide_control_chars = true;
                } else if (std.mem.eql(u8, arg, "--show-control-chars")) {
                    config.hide_control_chars = false;
                } else if (std.mem.eql(u8, arg, "--color")) {
                    config.color_mode = .always;
                } else if (std.mem.startsWith(u8, arg, "--color=")) {
                    const val = arg["--color=".len..];
                    // GNU when_args: always/yes/force, never/no/none, auto/tty/if-tty
                    if (std.mem.eql(u8, val, "always") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "force")) {
                        config.color_mode = .always;
                    } else if (std.mem.eql(u8, val, "never") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "none")) {
                        config.color_mode = .never;
                    } else if (std.mem.eql(u8, val, "auto") or std.mem.eql(u8, val, "tty") or std.mem.eql(u8, val, "if-tty")) {
                        config.color_mode = .auto;
                    } else {
                        // Message + exit status match GNU coreutils 9.10.
                        std.debug.print(
                            "zls: invalid argument '{s}' for '--color'\n" ++
                                "Valid arguments are:\n" ++
                                "  - 'always', 'yes', 'force'\n" ++
                                "  - 'never', 'no', 'none'\n" ++
                                "  - 'auto', 'tty', 'if-tty'\n" ++
                                "Try '{s} --help' for more information.\n",
                            .{ val, args[0] },
                        );
                        std.process.exit(1);
                    }
                } else if (std.mem.startsWith(u8, arg, "--time-style=")) {
                    const raw = arg["--time-style=".len..];
                    if (raw.len > 0 and raw[0] == '+') {
                        // +FORMAT (strftime) — GNU date-style custom format
                        config.time_style = .custom;
                        if (config.time_format) |old| allocator.free(old);
                        config.time_format = try allocator.dupe(u8, raw[1..]);
                    } else {
                        const is_posix_prefixed = std.mem.startsWith(u8, raw, "posix-");
                        const val = if (is_posix_prefixed) raw["posix-".len..] else raw;
                        if (std.mem.eql(u8, val, "long-iso")) {
                            config.time_style = .long_iso;
                        } else if (std.mem.eql(u8, val, "full-iso")) {
                            config.time_style = .full_iso;
                        } else if (std.mem.eql(u8, val, "iso")) {
                            config.time_style = .iso;
                        } else if (std.mem.eql(u8, val, "locale")) {
                            config.time_style = .default;
                        } else {
                            std.debug.print(
                                "zls: invalid argument '{s}' for 'time style'\n" ++
                                    "Valid arguments are:\n" ++
                                    "  - [posix-]full-iso\n" ++
                                    "  - [posix-]long-iso\n" ++
                                    "  - [posix-]iso\n" ++
                                    "  - [posix-]locale\n" ++
                                    "  - +FORMAT (e.g., +%H:%M) for a 'date'-style format\n" ++
                                    "Try '{s} --help' for more information.\n",
                                .{ raw, args[0] },
                            );
                            std.process.exit(2);
                        }
                        // GNU: a posix- prefixed style only takes effect
                        // outside the POSIX/C locale; inside it, the default
                        // locale format is used.
                        if (is_posix_prefixed and localeIsPosix()) {
                            config.time_style = .default;
                        }
                    }
                } else if (std.mem.eql(u8, arg, "--numeric-uid-gid")) {
                    config.numeric_ids = true;
                    config.long_format = true;
                } else if (std.mem.eql(u8, arg, "--no-group")) {
                    config.hide_group = true;
                } else if (std.mem.eql(u8, arg, "--group-directories-first")) {
                    config.group_directories_first = true;
                } else {
                    std.debug.print("{s}: unrecognized option '{s}'\nTry '{s} --help' for more information.\n", .{ args[0], arg, args[0] });
                    std.process.exit(2);
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
                        'U' => config.sort_mode = .none,
                        'f' => {
                            // GNU -f: list all entries in directory order
                            config.show_all = true;
                            config.sort_mode = .none;
                        },
                        'q' => config.hide_control_chars = true,
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
                            std.debug.print("{s}: invalid option -- '{c}'\nTry '{s} --help' for more information.\n", .{ args[0], ch, args[0] });
                            std.process.exit(2);
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
        \\  -d, --directory  list directories themselves, not their contents
        \\  -f             list all entries in directory order
        \\  -F, --classify append indicator (*/=>@|)
        \\  -g             like -l, but do not list owner
        \\  -G, --no-group in long listing, don't print group names
        \\  -h             human readable sizes
        \\  -i             print inode number
        \\  -l             long listing format
        \\  -m             fill width with a comma separated list of entries
        \\  -n, --numeric-uid-gid  like -l, but list numeric user and group IDs
        \\  -o             like -l, but do not list group information
        \\  -p             append / indicator to directories
        \\  -q, --hide-control-chars  print ? instead of nongraphic characters
        \\      --show-control-chars  show nongraphic characters as-is
        \\  -r, --reverse  reverse sort order
        \\  -R, --recursive  list subdirectories recursively
        \\  -s, --size     print the allocated size of each file, in blocks
        \\  -S             sort by size (largest first)
        \\  -t             sort by time (newest first)
        \\  -U             do not sort; list entries in directory order
        \\  -x             list entries by lines instead of by columns
        \\  -X             sort alphabetically by extension
        \\      --color    colorize output (auto/always/never)
        \\      --group-directories-first  group directories before files
        \\      --time-style=STYLE  with -l, show times using style STYLE:
        \\                          full-iso, long-iso, iso, locale, +FORMAT
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

// LC_ALL's numeric value is libc-specific: 6 on glibc/musl, 0 on
// Darwin/BSD (where 6 is LC_MESSAGES — using it left LC_COLLATE unset and
// broke locale-aware sorting on macOS).
const LC_ALL: c_int = switch (builtin.os.tag) {
    .linux => 6,
    else => 0,
};

pub fn main(init: std.process.Init) void {
    // Set locale for strcoll-based sorting to match GNU ls behavior
    _ = setlocale(LC_ALL, ""); // "" = use environment
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.debug.print("zls: failed to parse arguments\n", .{});
        std.process.exit(2);
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

    // Partition operands the way GNU ls does: non-directory operands are
    // printed first as a single sorted group, then each directory operand
    // (also sorted) is listed. Operands that fail to stat are diagnosed
    // first and make the exit status 2 ("serious trouble").
    var file_ops: std.ArrayListUnmanaged(FileEntry) = .empty;
    var dir_ops: std.ArrayListUnmanaged(FileEntry) = .empty;
    defer {
        for (file_ops.items) |*e| e.deinit(allocator);
        file_ops.deinit(allocator);
        for (dir_ops.items) |*e| e.deinit(allocator);
        dir_ops.deinit(allocator);
    }

    for (config.paths.items) |path| {
        const path_z = allocator.dupeZ(u8, path) catch {
            exit_serious = true;
            continue;
        };

        var stat_buf: Stat = undefined;
        if (lstat(path_z.ptr, &stat_buf) != 0) {
            std.debug.print("zls: cannot access '{s}': {s}\n", .{ path, errnoText() });
            exit_serious = true;
            allocator.free(path_z);
            continue;
        }

        var entry = entryFromStat(path_z, true, &stat_buf);

        // GNU dereferences a command-line symlink that points to a directory
        // (and lists its contents) unless -d, -F, or -l was given.
        var treat_as_dir = entry.isDir();
        if (entry.is_link and !config.directory_only and !config.show_indicators and !config.long_format) {
            var target_buf: Stat = undefined;
            if (stat(path_z.ptr, &target_buf) == 0 and (target_buf.mode & 0o170000) == 0o40000) {
                treat_as_dir = true;
            }
        }

        if (entry.is_link and !treat_as_dir) {
            var link_buf: [4096]u8 = undefined;
            const link_len = libc.readlink(path_z.ptr, &link_buf, link_buf.len);
            if (link_len > 0 and @as(usize, @intCast(link_len)) < link_buf.len) {
                entry.link_target = allocator.dupe(u8, link_buf[0..@intCast(link_len)]) catch null;
            }
            if (config.show_indicators and config.long_format) {
                var target_stat: Stat = undefined;
                if (stat(path_z.ptr, &target_stat) == 0) {
                    entry.target_mode = target_stat.mode;
                }
            }
        }

        if (treat_as_dir and !config.directory_only) {
            dir_ops.append(allocator, entry) catch {
                var e = entry;
                e.deinit(allocator);
                exit_serious = true;
            };
        } else {
            file_ops.append(allocator, entry) catch {
                var e = entry;
                e.deinit(allocator);
                exit_serious = true;
            };
        }
    }

    sortEntries(file_ops.items, &config);
    sortEntries(dir_ops.items, &config);

    const print_header = config.paths.items.len > 1 or config.recursive;
    var printed_any = false;

    if (file_ops.items.len > 0) {
        printEntries(allocator, &writer, file_ops.items, &config);
        printed_any = true;
    }

    for (dir_ops.items) |entry| {
        if (printed_any) writer.interface.writeAll("\n") catch {};
        printed_any = true;
        listDirectory(allocator, &writer, entry.name, &config, print_header) catch {
            exit_serious = true;
        };
    }

    // A swallowed write error (ENOSPC/EPIPE) must not exit 0: GNU reports
    // "write error" and exits 2.
    writer.interface.flush() catch {
        std.debug.print("zls: write error\n", .{});
        std.process.exit(2);
    };

    if (exit_serious) std.process.exit(2);
    if (exit_minor) std.process.exit(1);
}
