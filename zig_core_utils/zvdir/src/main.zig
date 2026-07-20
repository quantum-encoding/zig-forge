//! zvdir - List directory contents in long format with escape sequences
//!
//! A Zig implementation of vdir (equivalent to ls -lb).
//! Lists files in long format, escaping non-printable characters.
//!
//! Usage: zvdir [OPTIONS] [FILE]...

const std = @import("std");
const builtin = @import("builtin");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

// Target-aware libc structs / calls come from std.c so the ABI matches the
// host libc on any platform (the previous hand-rolled Linux-x86_64 structs
// decoded to garbage on macOS/arm64).
const Stat = std.c.Stat;
const passwd = std.c.passwd;
const group = std.c.group;
const DIR = std.c.DIR;
const dirent = std.c.dirent;
const opendir = std.c.opendir;
const readdir = std.c.readdir;
const closedir = std.c.closedir;

extern "c" fn getpwuid(uid: std.c.uid_t) ?*passwd;
extern "c" fn getgrgid(gid: std.c.gid_t) ?*group;

// Broken-down local time (struct tm). We only read the leading fields, which
// share an identical layout across glibc/musl/BSD/macOS; the trailing
// tm_gmtoff / tm_zone are included so the struct size is correct.
const tm = extern struct {
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
extern "c" fn localtime_r(timep: *const i64, result: *tm) ?*tm;
extern "c" fn time(t: ?*i64) i64;

fn lstatPath(path_z: [*:0]const u8) ?Stat {
    var st: Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return st;
}

// mode_t is u16 on Darwin, u32 on Linux; widen for uniform bit tests.
fn modeOf(st: *const Stat) u32 {
    return @as(u32, st.mode);
}

fn mtimeSec(st: *const Stat) i64 {
    return @intCast(st.mtime().sec);
}

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
    stat_buf: Stat,
    link_target: ?[]const u8 = null,
};

// Resolve a symlink target (raw, owned by allocator) or null on failure.
fn readLinkAlloc(allocator: std.mem.Allocator, path_z: [*:0]const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = readlink(path_z, &buf, buf.len);
    if (n <= 0) return null;
    return allocator.dupe(u8, buf[0..@intCast(n)]) catch null;
}

const Options = struct {
    human_readable: bool,
    numeric_ids: bool,
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
                    // vdir is `ls -lb`; -l and -b are redundant no-ops but
                    // accepted so callers may pass them (as GNU vdir does).
                    'l', 'b' => {},
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

    const opts = Options{ .human_readable = human_readable, .numeric_ids = numeric_ids };

    var first = true;
    var errors: u32 = 0;

    for (paths.items) |path| {
        if (paths.items.len > 1) {
            if (!first) writeStdout("\n", .{});
            writeStdout("{s}:\n", .{path});
        }
        first = false;

        // Null-terminate the path for libc calls.
        var path_z: [4097]u8 = undefined;
        if (path.len >= path_z.len) {
            writeStderr("zvdir: path too long: {s}\n", .{path});
            errors += 1;
            continue;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const path_stat = lstatPath(@ptrCast(&path_z)) orelse {
            writeStderr("zvdir: cannot access '{s}': No such file or directory\n", .{path});
            errors += 1;
            continue;
        };

        if ((modeOf(&path_stat) & S_IFMT) != S_IFDIR) {
            // It's a file; list it directly (single-element listing).
            var link_target: ?[]const u8 = null;
            if ((modeOf(&path_stat) & S_IFMT) == S_IFLNK) {
                link_target = readLinkAlloc(allocator, @ptrCast(&path_z));
            }
            defer if (link_target) |t| allocator.free(t);
            var single = [_]FileEntry{.{
                .name = std.fs.path.basename(path),
                .stat_buf = path_stat,
                .link_target = link_target,
            }};
            printListing(allocator, single[0..], opts);
            continue;
        }

        // Open directory (target-aware libc opendir/readdir via std.c).
        const dir = opendir(@ptrCast(&path_z)) orelse {
            writeStderr("zvdir: cannot open directory '{s}'\n", .{path});
            errors += 1;
            continue;
        };
        defer _ = closedir(dir);

        // Collect entries
        var entries: std.ArrayListUnmanaged(FileEntry) = .empty;
        defer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
                if (entry.link_target) |t| allocator.free(t);
            }
            entries.deinit(allocator);
        }

        var total_blocks: i64 = 0;

        while (readdir(dir)) |entry| {
            // dirent field names differ per OS; the name is NUL-terminated on
            // every platform, so scan for it rather than rely on d_namlen.
            const name_len = std.mem.indexOfScalar(u8, &entry.name, 0) orelse entry.name.len;
            const name = entry.name[0..name_len];

            // Skip . and .. unless -a
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                if (!show_all) continue;
            } else if (name.len > 0 and name[0] == '.') {
                // Hidden file
                if (!show_all and !show_almost_all) continue;
            }

            // Build the NUL-terminated full path bounds-safely: we need room
            // for path + '/' + name + NUL.
            var full_path_buf: [8192]u8 = undefined;
            if (path.len + 1 + name.len + 1 > full_path_buf.len) continue;
            @memcpy(full_path_buf[0..path.len], path);
            full_path_buf[path.len] = '/';
            @memcpy(full_path_buf[path.len + 1 ..][0..name.len], name);
            full_path_buf[path.len + 1 + name.len] = 0;
            const full_path_z: [*:0]const u8 = @ptrCast(&full_path_buf);

            const entry_stat = lstatPath(full_path_z) orelse continue;

            total_blocks += entry_stat.blocks;

            var link_target: ?[]const u8 = null;
            if ((modeOf(&entry_stat) & S_IFMT) == S_IFLNK) {
                link_target = readLinkAlloc(allocator, full_path_z);
            }

            const name_copy = try allocator.dupe(u8, name);
            try entries.append(allocator, .{
                .name = name_copy,
                .stat_buf = entry_stat,
                .link_target = link_target,
            });
        }

        // Sort entries
        if (!no_sort) {
            sortEntries(entries.items, reverse, sort_by_time, sort_by_size);
        }

        // Print total (GNU reports 1 KiB blocks; st_blocks is in 512-byte units).
        writeStdout("total {d}\n", .{@divTrunc(total_blocks, 2)});

        printListing(allocator, entries.items, opts);
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

fn sortEntries(items: []FileEntry, reverse: bool, by_time: bool, by_size: bool) void {
    const SortContext = struct {
        reverse_sort: bool,
        by_time: bool,
        by_size: bool,
    };
    const ctx = SortContext{ .reverse_sort = reverse, .by_time = by_time, .by_size = by_size };
    std.mem.sort(FileEntry, items, ctx, struct {
        fn lessThan(context: @TypeOf(ctx), a: FileEntry, b: FileEntry) bool {
            var result: bool = undefined;
            if (context.by_time) {
                // GNU sorts by the full timespec (nanosecond precision), then
                // by name for exact ties.
                const am = a.stat_buf.mtime();
                const bm = b.stat_buf.mtime();
                if (am.sec != bm.sec) {
                    result = am.sec > bm.sec;
                } else if (am.nsec != bm.nsec) {
                    result = am.nsec > bm.nsec;
                } else {
                    result = std.mem.lessThan(u8, a.name, b.name);
                }
            } else if (context.by_size) {
                if (a.stat_buf.size != b.stat_buf.size) {
                    result = a.stat_buf.size > b.stat_buf.size;
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

// A single rendered row: column strings plus raw name/link for escaping.
const Row = struct {
    mode: [10]u8,
    nlink: []const u8,
    owner: []const u8,
    group: []const u8,
    size: []const u8,
    date: [12]u8,
    name: []const u8,
    link_target: ?[]const u8,
};

fn buildMode(st: *const Stat) [10]u8 {
    var m: [10]u8 = undefined;
    const mode = modeOf(st);
    m[0] = switch (mode & S_IFMT) {
        S_IFDIR => 'd',
        S_IFLNK => 'l',
        S_IFCHR => 'c',
        S_IFBLK => 'b',
        S_IFIFO => 'p',
        S_IFSOCK => 's',
        else => '-',
    };
    m[1] = if (mode & S_IRUSR != 0) 'r' else '-';
    m[2] = if (mode & S_IWUSR != 0) 'w' else '-';
    m[3] = if (mode & S_ISUID != 0)
        (if (mode & S_IXUSR != 0) @as(u8, 's') else 'S')
    else
        (if (mode & S_IXUSR != 0) @as(u8, 'x') else '-');
    m[4] = if (mode & S_IRGRP != 0) 'r' else '-';
    m[5] = if (mode & S_IWGRP != 0) 'w' else '-';
    m[6] = if (mode & S_ISGID != 0)
        (if (mode & S_IXGRP != 0) @as(u8, 's') else 'S')
    else
        (if (mode & S_IXGRP != 0) @as(u8, 'x') else '-');
    m[7] = if (mode & S_IROTH != 0) 'r' else '-';
    m[8] = if (mode & S_IWOTH != 0) 'w' else '-';
    m[9] = if (mode & S_ISVTX != 0)
        (if (mode & S_IXOTH != 0) @as(u8, 't') else 'T')
    else
        (if (mode & S_IXOTH != 0) @as(u8, 'x') else '-');
    return m;
}

fn resolveOwner(arena: std.mem.Allocator, st: *const Stat, numeric: bool) []const u8 {
    if (!numeric) {
        if (getpwuid(st.uid)) |pw| {
            if (pw.name) |nm| {
                return arena.dupe(u8, std.mem.span(nm)) catch "?";
            }
        }
    }
    return std.fmt.allocPrint(arena, "{d}", .{st.uid}) catch "?";
}

fn resolveGroup(arena: std.mem.Allocator, st: *const Stat, numeric: bool) []const u8 {
    if (!numeric) {
        if (getgrgid(st.gid)) |gr| {
            if (gr.name) |nm| {
                return arena.dupe(u8, std.mem.span(nm)) catch "?";
            }
        }
    }
    return std.fmt.allocPrint(arena, "{d}", .{st.gid}) catch "?";
}

fn formatSize(arena: std.mem.Allocator, st: *const Stat, human_readable: bool) []const u8 {
    if (human_readable) {
        var buf: [32]u8 = undefined;
        const s = formatHumanSize(&buf, st.size);
        return arena.dupe(u8, s) catch "?";
    }
    return std.fmt.allocPrint(arena, "{d}", .{st.size}) catch "?";
}

// Render entries into aligned rows and print them.
fn printListing(allocator: std.mem.Allocator, entries: []const FileEntry, opts: Options) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = arena.alloc(Row, entries.len) catch return;
    for (entries, 0..) |e, idx| {
        rows[idx] = buildRow(arena, e, opts);
    }

    printRows(rows, opts);
}

fn buildRow(arena: std.mem.Allocator, e: FileEntry, opts: Options) Row {
    return .{
        .mode = buildMode(&e.stat_buf),
        .nlink = std.fmt.allocPrint(arena, "{d}", .{e.stat_buf.nlink}) catch "?",
        .owner = resolveOwner(arena, &e.stat_buf, opts.numeric_ids),
        .group = resolveGroup(arena, &e.stat_buf, opts.numeric_ids),
        .size = formatSize(arena, &e.stat_buf, opts.human_readable),
        .date = formatDate(mtimeSec(&e.stat_buf)),
        .name = e.name,
        .link_target = e.link_target,
    };
}

// Compute per-column widths (GNU aligns each column to the widest value in
// the current listing), then emit each row.
fn printRows(rows: []const Row, opts: Options) void {
    _ = opts;
    var w_nlink: usize = 0;
    var w_owner: usize = 0;
    var w_group: usize = 0;
    var w_size: usize = 0;
    for (rows) |r| {
        w_nlink = @max(w_nlink, r.nlink.len);
        w_owner = @max(w_owner, r.owner.len);
        w_group = @max(w_group, r.group.len);
        w_size = @max(w_size, r.size.len);
    }

    for (rows) |r| {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        // mode + space
        @memcpy(buf[pos .. pos + 10], &r.mode);
        pos += 10;
        buf[pos] = ' ';
        pos += 1;

        // nlink right-justified
        pos += padRight(buf[pos..], r.nlink, w_nlink);
        buf[pos] = ' ';
        pos += 1;

        // owner left-justified
        pos += padLeft(buf[pos..], r.owner, w_owner);
        buf[pos] = ' ';
        pos += 1;

        // group left-justified
        pos += padLeft(buf[pos..], r.group, w_group);
        buf[pos] = ' ';
        pos += 1;

        // size right-justified
        pos += padRight(buf[pos..], r.size, w_size);
        buf[pos] = ' ';
        pos += 1;

        // date (fixed width) + space
        @memcpy(buf[pos .. pos + r.date.len], &r.date);
        pos += r.date.len;
        buf[pos] = ' ';
        pos += 1;

        writeStdoutRaw(buf[0..pos]);

        // name (escaped)
        printEscaped(r.name);

        if (r.link_target) |t| {
            writeStdoutRaw(" -> ");
            printEscaped(t);
        }

        writeStdoutRaw("\n");
    }
}

// Right-justify `s` into `dst` padded to `width`; returns bytes written.
fn padRight(dst: []u8, s: []const u8, width: usize) usize {
    const pad = if (width > s.len) width - s.len else 0;
    var n: usize = 0;
    while (n < pad) : (n += 1) dst[n] = ' ';
    @memcpy(dst[pad .. pad + s.len], s);
    return pad + s.len;
}

// Left-justify `s` into `dst` padded to `width`; returns bytes written.
fn padLeft(dst: []u8, s: []const u8, width: usize) usize {
    @memcpy(dst[0..s.len], s);
    const pad = if (width > s.len) width - s.len else 0;
    var n: usize = 0;
    while (n < pad) : (n += 1) dst[s.len + n] = ' ';
    return s.len + pad;
}

// GNU `-b` (escape quoting style): backslash and space are escaped, common
// control chars use C letter escapes, everything else non-printable is octal.
fn printEscaped(name: []const u8) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (name) |c| {
        if (pos + 4 >= buf.len) {
            writeStdoutRaw(buf[0..pos]);
            pos = 0;
        }

        const letter: ?u8 = switch (c) {
            0x07 => 'a',
            0x08 => 'b',
            0x09 => 't',
            0x0a => 'n',
            0x0b => 'v',
            0x0c => 'f',
            0x0d => 'r',
            '\\' => '\\',
            else => null,
        };

        if (letter) |l| {
            buf[pos] = '\\';
            pos += 1;
            buf[pos] = l;
            pos += 1;
        } else if (c == ' ') {
            buf[pos] = '\\';
            pos += 1;
            buf[pos] = ' ';
            pos += 1;
        } else if (c > 32 and c < 127) {
            buf[pos] = c;
            pos += 1;
        } else {
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
        return std.fmt.bufPrint(buf, "{d}", .{abs_size}) catch "";
    } else if (abs_size < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(abs_size)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{kb}) catch "";
    } else if (abs_size < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(abs_size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1}M", .{mb}) catch "";
    } else {
        const gb = @as(f64, @floatFromInt(abs_size)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1}G", .{gb}) catch "";
    }
}

// GNU date rules: local time; recent files (within the past ~6 months, not in
// the future) show "Mon DD HH:MM", others show "Mon DD  YYYY".
fn formatDate(timestamp: i64) [12]u8 {
    var out: [12]u8 = .{' '} ** 12;

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    var t: tm = undefined;
    const ts = timestamp;
    if (localtime_r(&ts, &t) == null) return out;

    const month_idx: usize = @intCast(@mod(t.tm_mon, 12));
    const day: u32 = @intCast(t.tm_mday);
    const year: u32 = @intCast(@as(i64, t.tm_year) + 1900);

    // Recent window: 31556952/2 seconds (half a Gregorian year), per GNU ls.
    const now = time(null);
    const six_months: i64 = 31556952 / 2;
    const recent = (timestamp > now - six_months) and (timestamp <= now);

    var tail_buf: [8]u8 = undefined;
    const tail = if (recent)
        std.fmt.bufPrint(&tail_buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(t.tm_hour)), @as(u32, @intCast(t.tm_min)) }) catch return out
    else
        std.fmt.bufPrint(&tail_buf, " {d:>4}", .{year}) catch return out;

    // "Mon" + " " + day(space-padded width 2) + " " + tail(width 5) = 12 chars.
    var b: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s} {d:>2} {s}", .{ month_names[month_idx], day, tail }) catch return out;
    // Left-align into the 12-byte field (already 12 wide in practice).
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    return out;
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
        \\Non-printable characters are shown as escapes (e.g., \n for newline,
        \\\NNN octal for other bytes); space and backslash are escaped.
        \\
        \\Examples:
        \\  zvdir                 list current directory
        \\  zvdir -a              show all files including hidden
        \\  zvdir -h /home        human-readable sizes
        \\  zvdir -t              sort by modification time
        \\
    , .{});
}
