//! zstat - Display file status
//!
//! High-performance stat implementation in Zig.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
        pub fn ctime(self: @This()) libc.timespec { return self.ctim; }
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
        pub fn ctime(self: @This()) libc.timespec { return self.ctim; }
    },
    else => libc.Stat,
};

extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;

const Group = extern struct {
    gr_name: ?[*:0]const u8,
    gr_passwd: ?[*:0]const u8,
    gr_gid: u32,
    gr_mem: ?[*]?[*:0]const u8,
};

const Passwd = extern struct {
    pw_name: ?[*:0]const u8,
    pw_passwd: ?[*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: ?[*:0]const u8,
    pw_dir: ?[*:0]const u8,
    pw_shell: ?[*:0]const u8,
};

extern "c" fn getgrgid(gid: u32) ?*Group;
extern "c" fn getpwuid(uid: u32) ?*Passwd;

fn getGroupName(gid: u32, buf: *[64]u8) []const u8 {
    if (getgrgid(gid)) |grp| {
        if (grp.gr_name) |name| {
            const name_slice = std.mem.sliceTo(name, 0);
            return name_slice;
        }
    }
    // Fall back to numeric GID
    const s = std.fmt.bufPrint(buf, "{d}", .{gid}) catch return "?";
    return s;
}

fn getUserName(uid: u32, buf: *[64]u8) []const u8 {
    if (getpwuid(uid)) |pw| {
        if (pw.pw_name) |name| {
            const name_slice = std.mem.sliceTo(name, 0);
            return name_slice;
        }
    }
    // Fall back to numeric UID
    const s = std.fmt.bufPrint(buf, "{d}", .{uid}) catch return "?";
    return s;
}

const Config = struct {
    format: ?[]const u8 = null,
    is_printf: bool = false,
    terse: bool = false,
    dereference: bool = false,
    files: [256][]const u8 = undefined,
    file_count: usize = 0,
};

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }

    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.write(s);
    }
};

fn getFileType(mode: u32, size: i64) []const u8 {
    const fmt = mode & 0o170000;
    return switch (fmt) {
        0o140000 => "socket",
        0o120000 => "symbolic link",
        0o100000 => if (size == 0) "regular empty file" else "regular file",
        0o060000 => "block special file",
        0o040000 => "directory",
        0o020000 => "character special file",
        0o010000 => "fifo",
        else => "unknown",
    };
}

fn formatMode(mode: u32, buf: *[10]u8) void {
    const fmt = mode & 0o170000;
    buf[0] = switch (fmt) {
        0o140000 => 's',
        0o120000 => 'l',
        0o100000 => '-',
        0o060000 => 'b',
        0o040000 => 'd',
        0o020000 => 'c',
        0o010000 => 'p',
        else => '?',
    };
    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o100 != 0) (if (mode & 0o4000 != 0) 's' else 'x') else (if (mode & 0o4000 != 0) 'S' else '-');
    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o010 != 0) (if (mode & 0o2000 != 0) 's' else 'x') else (if (mode & 0o2000 != 0) 'S' else '-');
    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o001 != 0) (if (mode & 0o1000 != 0) 't' else 'x') else (if (mode & 0o1000 != 0) 'T' else '-');
}

fn formatTime(secs: i64, nsecs: i64, buf: *[32]u8) []const u8 {
    var days: i64 = @divFloor(secs, 86400);
    const day_secs: i64 = @mod(secs, 86400);
    const hours: i64 = @divFloor(day_secs, 3600);
    const mins: i64 = @divFloor(@mod(day_secs, 3600), 60);
    const seconds: i64 = @mod(day_secs, 60);

    var year: i64 = 1970;
    while (days >= 0) {
        const is_leap = (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0));
        const days_in_year: i64 = if (is_leap) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const is_leap = (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0));
    const month_days = [_]i64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: usize = 0;
    while (month < 12) : (month += 1) {
        if (days < month_days[month]) break;
        days -= month_days[month];
    }

    const day: i64 = days + 1;
    const ns9 = @divFloor(nsecs, 1);

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        @as(u32, @intCast(year)),
        @as(u32, @intCast(month + 1)),
        @as(u32, @intCast(day)),
        @as(u32, @intCast(hours)),
        @as(u32, @intCast(mins)),
        @as(u32, @intCast(seconds)),
        @as(u32, @intCast(ns9)),
    }) catch return "????-??-?? ??:??:??.?????????";

    return buf[0..29];
}

fn outputFormatted(path: []const u8, st: *const Stat, format: []const u8, is_printf: bool, out: *OutputBuffer) void {
    const mode: u32 = st.mode;
    const atime = st.atime();
    const mtime = st.mtime();
    const ctime = st.ctime();

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            switch (format[i]) {
                '%' => out.writeByte('%'),
                'a' => out.print("{o}", .{mode & 0o7777}), // Access rights octal
                'A' => { // Access rights human readable
                    var mode_str: [10]u8 = undefined;
                    formatMode(mode, &mode_str);
                    out.write(&mode_str);
                },
                'b' => out.print("{d}", .{@as(u64, @intCast(st.blocks))}), // Blocks
                'B' => out.print("{d}", .{@as(u64, 512)}), // Block size (always 512 for blocks)
                'd' => out.print("{d}", .{@as(u64, @intCast(st.dev))}), // Device decimal
                'D' => out.print("{x}", .{@as(u64, @intCast(st.dev))}), // Device hex
                'f' => out.print("{x}", .{mode}), // Raw mode hex
                'F' => out.write(getFileType(mode, st.size)), // File type
                'g' => out.print("{d}", .{st.gid}), // Group ID
                'G' => { // Group name
                    var grp_buf: [64]u8 = undefined;
                    out.write(getGroupName(st.gid, &grp_buf));
                },
                'h' => out.print("{d}", .{@as(u64, @intCast(st.nlink))}), // Hard links
                'i' => out.print("{d}", .{st.ino}), // Inode
                'm' => out.write("?"), // Mount point
                'n' => out.write(path), // File name
                'N' => { // Quoted file name
                    out.writeByte('\'');
                    out.write(path);
                    out.writeByte('\'');
                },
                'o' => out.print("{d}", .{@as(u64, @intCast(st.blksize))}), // Optimal I/O size
                's' => out.print("{d}", .{@as(u64, @intCast(st.size))}), // Size
                't' => out.print("{x}", .{(@as(u64, @intCast(st.rdev)) >> 8) & 0xfff}), // Major device hex
                'T' => out.print("{x}", .{@as(u64, @intCast(st.rdev)) & 0xff}), // Minor device hex
                'u' => out.print("{d}", .{st.uid}), // User ID
                'U' => { // User name
                    var usr_buf: [64]u8 = undefined;
                    out.write(getUserName(st.uid, &usr_buf));
                },
                'w' => out.write("-"), // Birth time (not available)
                'W' => out.write("0"), // Birth time seconds
                'x' => { // Access time
                    var time_buf: [32]u8 = undefined;
                    out.write(formatTime(atime.sec, atime.nsec, &time_buf));
                },
                'X' => out.print("{d}", .{@as(u64, @intCast(atime.sec))}), // Access time seconds
                'y' => { // Modify time
                    var time_buf: [32]u8 = undefined;
                    out.write(formatTime(mtime.sec, mtime.nsec, &time_buf));
                },
                'Y' => out.print("{d}", .{@as(u64, @intCast(mtime.sec))}), // Modify time seconds
                'z' => { // Change time
                    var time_buf: [32]u8 = undefined;
                    out.write(formatTime(ctime.sec, ctime.nsec, &time_buf));
                },
                'Z' => out.print("{d}", .{@as(u64, @intCast(ctime.sec))}), // Change time seconds
                else => {
                    out.writeByte('%');
                    out.writeByte(format[i]);
                },
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            i += 1;
            switch (format[i]) {
                'n' => out.writeByte('\n'),
                't' => out.writeByte('\t'),
                '\\' => out.writeByte('\\'),
                else => {
                    out.writeByte('\\');
                    out.writeByte(format[i]);
                },
            }
        } else {
            out.writeByte(format[i]);
        }
        i += 1;
    }
    if (!is_printf) {
        out.writeByte('\n');
    }
}

fn outputTerse(path: []const u8, st: *const Stat, out: *OutputBuffer) void {
    // Terse format: %n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o
    const mode: u32 = st.mode;
    const atime = st.atime();
    const mtime = st.mtime();
    const ctime = st.ctime();

    out.write(path);
    out.print(" {d} {d} {x} {d} {d} {x} {d} {d} {x} {x} {d} {d} {d} 0 {d}\n", .{
        @as(u64, @intCast(st.size)),
        @as(u64, @intCast(st.blocks)),
        mode,
        st.uid,
        st.gid,
        @as(u64, @intCast(st.dev)),
        st.ino,
        @as(u64, @intCast(st.nlink)),
        (@as(u64, @intCast(st.rdev)) >> 8) & 0xfff,
        @as(u64, @intCast(st.rdev)) & 0xff,
        @as(u64, @intCast(atime.sec)),
        @as(u64, @intCast(mtime.sec)),
        @as(u64, @intCast(ctime.sec)),
        @as(u64, @intCast(st.blksize)),
    });
}

fn outputStat(path: []const u8, st: *const Stat, out: *OutputBuffer) bool {
    const mode: u32 = st.mode;
    const atime = st.atime();
    const mtime = st.mtime();
    const ctime = st.ctime();

    var mode_str: [10]u8 = undefined;
    formatMode(mode, &mode_str);

    out.write("  File: ");
    out.write(path);
    out.writeByte('\n');

    out.print("  Size: {d:<10}\tBlocks: {d:<10} IO Block: {d:<6} {s}\n", .{
        @as(u64, @intCast(st.size)),
        @as(u64, @intCast(st.blocks)),
        @as(u64, @intCast(st.blksize)),
        getFileType(mode, st.size),
    });

    const dev: u64 = @intCast(st.dev);
    const dev_major = (dev >> 8) & 0xfff;
    const dev_minor = dev & 0xff;
    out.print("Device: {x}h/{d}d\tInode: {d:<12} Links: {d}\n", .{ dev, dev_major * 256 + dev_minor, st.ino, @as(u64, @intCast(st.nlink)) });

    var usr_buf: [64]u8 = undefined;
    var grp_buf: [64]u8 = undefined;
    const uname = getUserName(st.uid, &usr_buf);
    const gname = getGroupName(st.gid, &grp_buf);
    out.print("Access: ({o:0>4}/{s})  Uid: ({d:>5}/", .{ mode & 0o7777, mode_str, st.uid });
    out.write(uname);
    out.write(")   Gid: (");
    out.print("{d:>5}/", .{st.gid});
    out.write(gname);
    out.write(")\n");

    var time_buf: [32]u8 = undefined;
    out.write("Access: ");
    out.write(formatTime(atime.sec, atime.nsec, &time_buf));
    out.writeByte('\n');

    out.write("Modify: ");
    out.write(formatTime(mtime.sec, mtime.nsec, &time_buf));
    out.writeByte('\n');

    out.write("Change: ");
    out.write(formatTime(ctime.sec, ctime.nsec, &time_buf));
    out.writeByte('\n');

    out.write(" Birth: -\n");

    return true;
}

fn statFile(path: []const u8, config: *const Config, out: *OutputBuffer) bool {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var stat_buf: Stat = undefined;

    // Use stat or lstat based on dereference option
    const result = if (config.dereference) stat(path_z, &stat_buf) else lstat(path_z, &stat_buf);
    if (result != 0) {
        _ = libc.write(libc.STDERR_FILENO, "zstat: cannot stat '", 20);
        _ = libc.write(libc.STDERR_FILENO, path.ptr, path.len);
        _ = libc.write(libc.STDERR_FILENO, "'\n", 2);
        return false;
    }

    if (config.format) |fmt| {
        outputFormatted(path, &stat_buf, fmt, config.is_printf, out);
        return true;
    } else if (config.terse) {
        outputTerse(path, &stat_buf, out);
        return true;
    }

    return outputStat(path, &stat_buf, out);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

pub fn main(init: std.process.Init) void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var config = Config{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                \\Usage: zstat [OPTION]... FILE...
                \\Display file status.
                \\
                \\  -L, --dereference     follow links
                \\  -c, --format=FORMAT   use the specified FORMAT instead of the default
                \\      --printf=FORMAT   like --format, but interpret backslash escapes,
                \\                          and do not output a mandatory trailing newline
                \\  -t, --terse           print information in terse form
                \\      --help            display this help and exit
                \\
                \\FORMAT sequences:
                \\  %a   access rights in octal
                \\  %A   access rights in human readable form
                \\  %b   number of blocks allocated
                \\  %B   block size (512)
                \\  %d   device number in decimal
                \\  %D   device number in hex
                \\  %f   raw mode in hex
                \\  %F   file type
                \\  %g   group ID
                \\  %G   group name
                \\  %h   number of hard links
                \\  %i   inode number
                \\  %n   file name
                \\  %N   quoted file name
                \\  %o   optimal I/O transfer size
                \\  %s   total size in bytes
                \\  %t   major device type in hex
                \\  %T   minor device type in hex
                \\  %u   user ID
                \\  %U   user name
                \\  %x   time of last access
                \\  %X   time of last access as seconds
                \\  %y   time of last modification
                \\  %Y   time of last modification as seconds
                \\  %z   time of last change
                \\  %Z   time of last change as seconds
                \\
            ;
            writeStderr(help);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStderr("zstat 1.0.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--dereference")) {
            config.dereference = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--terse")) {
            config.terse = true;
        } else if (std.mem.startsWith(u8, arg, "--printf=")) {
            config.format = arg[9..];
            config.is_printf = true;
        } else if (std.mem.eql(u8, arg, "--printf")) {
            if (args.next()) |fmt| {
                config.format = fmt;
                config.is_printf = true;
            } else {
                writeStderr("zstat: option '--printf' requires an argument\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            config.format = arg[9..];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--format")) {
            if (args.next()) |fmt| {
                config.format = fmt;
            } else {
                writeStderr("zstat: option '-c' requires an argument\n");
                std.process.exit(1);
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            // Handle short combined options
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                switch (arg[i]) {
                    'L' => config.dereference = true,
                    't' => config.terse = true,
                    'c' => {
                        if (i + 1 < arg.len) {
                            config.format = arg[i + 1 ..];
                            break;
                        } else if (args.next()) |fmt| {
                            config.format = fmt;
                        } else {
                            writeStderr("zstat: option '-c' requires an argument\n");
                            std.process.exit(1);
                        }
                    },
                    else => {
                        writeStderr("zstat: invalid option -- '");
                        var char_buf = [_]u8{arg[i]};
                        _ = libc.write(libc.STDERR_FILENO, &char_buf, 1);
                        writeStderr("'\n");
                        std.process.exit(1);
                    },
                }
            }
        } else {
            if (config.file_count < config.files.len) {
                config.files[config.file_count] = arg;
                config.file_count += 1;
            }
        }
    }

    if (config.file_count == 0) {
        writeStderr("zstat: missing operand\n");
        std.process.exit(1);
    }

    var out = OutputBuffer{};
    var had_error = false;

    for (config.files[0..config.file_count]) |path| {
        if (!statFile(path, &config, &out)) {
            had_error = true;
        }
    }

    out.flush();

    if (had_error) {
        std.process.exit(1);
    }
}
