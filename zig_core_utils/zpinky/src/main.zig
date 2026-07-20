//! zpinky - Lightweight finger utility
//!
//! Show user information for logged in users. Mirrors GNU coreutils `pinky`.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn time(t: ?*i64) i64;

// ---------------------------------------------------------------------------
// utmp / utmpx record access
//
// On macOS/BSD the login database is /var/run/utmpx and is best read through
// the libc getutxent(3) family — the on-disk struct layout is platform
// specific and must never be hand-parsed with fixed offsets. On Linux glibc
// the legacy /var/run/utmp file is read directly.
// ---------------------------------------------------------------------------

const UT_USER_PROCESS: i16 = 7; // USER_PROCESS (same value on Linux and macOS)

// Linux glibc utmp constants (only used on the Linux read path).
const LINUX_UTMP_SIZE: usize = 384;
const UT_NAMESIZE: usize = 32;
const UT_LINESIZE: usize = 32;
const UT_HOSTSIZE: usize = 256;

// macOS/BSD struct utmpx (verified layout: sizeof == 640).
const Timeval = extern struct {
    tv_sec: i64, // __darwin_time_t (long)
    tv_usec: i32, // __darwin_suseconds_t (int)
};

const Utmpx = extern struct {
    ut_user: [256]u8, // offset 0
    ut_id: [4]u8, // offset 256
    ut_line: [32]u8, // offset 260
    ut_pid: i32, // offset 292
    ut_type: i16, // offset 296
    ut_tv: Timeval, // offset 304 (8-byte aligned)
    ut_host: [256]u8, // offset 320
    ut_pad: [16]u32, // offset 576 .. 640
};

extern "c" fn setutxent() void;
extern "c" fn endutxent() void;
extern "c" fn getutxent() ?*Utmpx;

// localtime_r / strftime for GNU-compatible local "YYYY-MM-DD HH:MM" timestamps.
const Tm = extern struct {
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
extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;
extern "c" fn strftime(buf: [*]u8, maxsize: usize, format: [*:0]const u8, timeptr: *const Tm) usize;

// fstatat(2) for terminal idle time (matches how GNU pinky stats /dev/<line>).
const AT_FDCWD: c_int = -2;
extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *libc.Stat, flag: u32) c_int;

// getpwnam(3) — the account database lookup GNU pinky uses (consults Directory
// Services on macOS, not just /etc/passwd). macOS/BSD struct passwd layout.
const Passwd = extern struct {
    pw_name: ?[*:0]u8, // 0
    pw_passwd: ?[*:0]u8, // 8
    pw_uid: u32, // 16
    pw_gid: u32, // 20
    pw_change: i64, // 24 (time_t)
    pw_class: ?[*:0]u8, // 32
    pw_gecos: ?[*:0]u8, // 40
    pw_dir: ?[*:0]u8, // 48
    pw_shell: ?[*:0]u8, // 56
    pw_expire: i64, // 64 (sizeof == 72)
};
extern "c" fn getpwnam(name: [*:0]const u8) ?*Passwd;

const use_utmpx = builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd or
    builtin.os.tag == .dragonfly;

const Config = struct {
    long_format: bool = false,
    omit_heading: bool = false,
    omit_fullname: bool = false,
    omit_host: bool = false,
    omit_idle: bool = false,
    omit_home_shell: bool = false,
    omit_project: bool = false,
    omit_plan: bool = false,
    do_lookup: bool = false,
    users: [256][]const u8 = undefined,
    user_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    // GNU writes --help/--version to STDOUT and exits 0.
    const usage =
        \\Usage: zpinky [OPTION]... [USER]...
        \\Print user information. With no USER, print all logged in users.
        \\
        \\Options:
        \\  -l              Long format output for the specified USERs
        \\  -b              Omit home directory and shell in long format
        \\  -h              Omit the user's project file in long format
        \\  -p              Omit the user's plan file in long format
        \\  -s              Short format output (default)
        \\  -f              Omit column headings in short format
        \\  -w              Omit full name in short format
        \\  -i              Omit full name and remote host in short format
        \\  -q              Omit full name, remote host, and idle time in short format
        \\      --lookup    Attempt to canonicalize hostnames via DNS
        \\      --help      Display this help and exit
        \\      --version   Output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zpinky " ++ VERSION ++ "\n");
}

fn dieInvalidOption(ch: u8) noreturn {
    writeStderr("zpinky: invalid option -- '");
    const c = [_]u8{ch};
    writeStderr(&c);
    writeStderr("'\nTry 'zpinky --help' for more information.\n");
    std.process.exit(1);
}

fn dieUnrecognizedOption(arg: []const u8) noreturn {
    writeStderr("zpinky: unrecognized option '");
    writeStderr(arg);
    writeStderr("'\nTry 'zpinky --help' for more information.\n");
    std.process.exit(1);
}

fn dieNoUsername() noreturn {
    writeStderr("zpinky: no username specified; at least one must be specified when using -l\n");
    writeStderr("Try 'zpinky --help' for more information.\n");
    std.process.exit(1);
}

fn extractString(data: []const u8, max_len: usize) []const u8 {
    var len: usize = 0;
    while (len < max_len and len < data.len and data[len] != 0) : (len += 1) {}
    return data[0..len];
}

const PasswdInfo = struct {
    username: []const u8,
    fullname: []const u8,
    home: []const u8,
    shell: []const u8,
};

pub fn parsePasswdLine(line: []const u8, buf: *[1024]u8) ?PasswdInfo {
    var info = PasswdInfo{
        .username = "",
        .fullname = "",
        .home = "",
        .shell = "",
    };

    var field: usize = 0;
    var start: usize = 0;
    var buf_pos: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ':' or i == line.len - 1) {
            const end = if (c == ':') i else i + 1;
            const value = line[start..end];

            const copy_start = buf_pos;
            for (value) |v| {
                if (buf_pos < buf.len) {
                    buf[buf_pos] = v;
                    buf_pos += 1;
                }
            }

            switch (field) {
                0 => info.username = buf[copy_start..buf_pos],
                4 => {
                    // GECOS field - extract first part (full name)
                    var name_end = copy_start;
                    while (name_end < buf_pos and buf[name_end] != ',') : (name_end += 1) {}
                    info.fullname = buf[copy_start..name_end];
                },
                5 => info.home = buf[copy_start..buf_pos],
                6 => info.shell = buf[copy_start..buf_pos],
                else => {},
            }

            field += 1;
            start = i + 1;
        }
    }

    if (info.username.len > 0) return info;
    return null;
}

fn getUserInfo(username: []const u8, buf: *[1024]u8) ?PasswdInfo {
    if (use_utmpx) return getUserInfoPwnam(username);
    return getUserInfoPasswdFile(username, buf);
}

fn getUserInfoPwnam(username: []const u8) ?PasswdInfo {
    var name_buf: [256]u8 = undefined;
    if (username.len == 0 or username.len >= name_buf.len) return null;
    @memcpy(name_buf[0..username.len], username);
    name_buf[username.len] = 0;

    const pw = getpwnam(@ptrCast(&name_buf)) orelse return null;
    const gecos: []const u8 = if (pw.pw_gecos) |g| std.mem.span(g) else "";
    // GNU takes the GECOS field up to the first comma as the full name.
    var fullname: []const u8 = gecos;
    if (std.mem.indexOfScalar(u8, gecos, ',')) |idx| fullname = gecos[0..idx];

    return PasswdInfo{
        .username = username,
        .fullname = fullname,
        .home = if (pw.pw_dir) |d| std.mem.span(d) else "",
        .shell = if (pw.pw_shell) |s| std.mem.span(s) else "",
    };
}

fn getUserInfoPasswdFile(username: []const u8, buf: *[1024]u8) ?PasswdInfo {
    const fd = libc.open("/etc/passwd", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);

    var file_buf: [8192]u8 = undefined;
    var line_buf: [1024]u8 = undefined;
    var line_len: usize = 0;
    var overflow = false;
    var file_pos: usize = 0;
    var file_len: usize = 0;

    while (true) {
        // Read more if needed
        if (file_pos >= file_len) {
            const n = libc.read(fd, &file_buf, file_buf.len);
            if (n <= 0) break;
            file_len = @intCast(n);
            file_pos = 0;
        }

        const c = file_buf[file_pos];
        file_pos += 1;

        if (c == '\n') {
            // Skip lines that overflowed the buffer rather than misparse a
            // truncated record (which would drop the shell/home fields).
            if (line_len > 0 and !overflow) {
                if (parsePasswdLine(line_buf[0..line_len], buf)) |info| {
                    if (std.mem.eql(u8, info.username, username)) {
                        return info;
                    }
                }
            }
            line_len = 0;
            overflow = false;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            } else {
                overflow = true;
            }
        }
    }

    return null;
}

fn formatTime(timestamp: i64, buf: []u8) []const u8 {
    // GNU pinky formats "When" as local time "YYYY-MM-DD HH:MM".
    var ts = timestamp;
    var tmv: Tm = undefined;
    if (localtime_r(&ts, &tmv) == null) return "";
    var out: [64]u8 = undefined;
    const n = strftime(&out, out.len, "%Y-%m-%d %H:%M", &tmv);
    if (n == 0 or n > buf.len) return "";
    @memcpy(buf[0..n], out[0..n]);
    return buf[0..n];
}

pub fn formatIdle(idle_secs: i64, buf: []u8) []const u8 {
    // Matches GNU pinky idle_string: blank under a minute, HH:MM under a day,
    // then whole days as "<n>d".
    if (idle_secs < 60) {
        return "";
    } else if (idle_secs < 86400) {
        // GNU format: "%02d:%02d" (hours:minutes).
        const hours: u64 = @intCast(@divFloor(idle_secs, 3600));
        const mins: u64 = @intCast(@divFloor(@mod(idle_secs, 3600), 60));
        if (buf.len < 5) return "";
        buf[0] = '0' + @as(u8, @intCast((hours / 10) % 10));
        buf[1] = '0' + @as(u8, @intCast(hours % 10));
        buf[2] = ':';
        buf[3] = '0' + @as(u8, @intCast((mins / 10) % 10));
        buf[4] = '0' + @as(u8, @intCast(mins % 10));
        return buf[0..5];
    } else {
        const days = @divFloor(idle_secs, 86400);
        return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
    }
}

fn getIdleSeconds(line: []const u8) i64 {
    if (line.len == 0) return 0;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/{s}", .{line}) catch return 0;
    var st: libc.Stat = undefined;
    if (fstatat(AT_FDCWD, path.ptr, &st, 0) != 0) return 0;
    const atime_s: i64 = @intCast(st.atimespec.sec);
    const now = time(null);
    const idle = now - atime_s;
    return if (idle < 0) 0 else idle;
}

// ---------------------------------------------------------------------------
// Short format
// ---------------------------------------------------------------------------

// Column model, reverse-engineered byte-exact from GNU coreutils 9.10 pinky:
//   Login  : "%-8.8s"        (no leading space)
//   Name   : " %-19.19s"     (1 leading space) — omitted with -w/-i/-q
//   TTY    : "  %-8.8s"      (2 leading spaces)
//   Idle   : " %-6s"         (1 leading space) — omitted with -q
//   When   : " %-16s"        (1 leading space)
//   Where  : " %s"           (1 leading space) — omitted with -i/-q, and in a
//                             data row only emitted when the host is non-empty.
fn writeCol(lead: usize, s: []const u8, width: usize) void {
    const spaces = "  ";
    if (lead > 0) writeStdout(spaces[0..lead]);
    const shown = if (s.len > width) s[0..width] else s;
    writeStdout(shown);
    if (shown.len < width) {
        var pad: [32]u8 = undefined;
        const n = width - shown.len;
        @memset(pad[0..n], ' ');
        writeStdout(pad[0..n]);
    }
}

fn printShortHeading(cfg: *const Config) void {
    if (cfg.omit_heading) return;
    writeCol(0, "Login", 8);
    if (!cfg.omit_fullname) writeCol(1, "Name", 19);
    writeCol(2, "TTY", 8);
    if (!cfg.omit_idle) writeCol(1, "Idle", 6);
    writeCol(1, "When", 16);
    if (!cfg.omit_host) writeStdout(" Where");
    writeStdout("\n");
}

fn matchesUser(cfg: *const Config, username: []const u8) bool {
    if (cfg.user_count == 0) return true;
    for (cfg.users[0..cfg.user_count]) |u| {
        if (std.mem.eql(u8, u, username)) return true;
    }
    return false;
}

fn printShortRow(cfg: *const Config, username: []const u8, tty: []const u8, host: []const u8, login_time: i64) void {
    var passwd_buf: [1024]u8 = undefined;
    const user_info = getUserInfo(username, &passwd_buf);

    writeCol(0, username, 8);

    if (!cfg.omit_fullname) {
        const fullname = if (user_info) |info| info.fullname else "";
        writeCol(1, fullname, 19);
    }

    writeCol(2, tty, 8);

    if (!cfg.omit_idle) {
        var idle_buf: [16]u8 = undefined;
        const idle = formatIdle(getIdleSeconds(tty), &idle_buf);
        writeCol(1, idle, 6);
    }

    var time_buf: [16]u8 = undefined;
    writeCol(1, formatTime(login_time, &time_buf), 16);

    if (!cfg.omit_host and host.len > 0) {
        writeStdout(" ");
        writeStdout(host);
    }

    writeStdout("\n");
}

fn printShortFormat(cfg: *const Config) void {
    if (use_utmpx) {
        printShortHeading(cfg);
        setutxent();
        defer endutxent();
        while (getutxent()) |ent| {
            if (ent.ut_type != UT_USER_PROCESS) continue;
            const username = extractString(ent.ut_user[0..], ent.ut_user.len);
            if (!matchesUser(cfg, username)) continue;
            const tty = extractString(ent.ut_line[0..], ent.ut_line.len);
            const host = extractString(ent.ut_host[0..], ent.ut_host.len);
            printShortRow(cfg, username, tty, host, ent.ut_tv.tv_sec);
        }
    } else {
        // Linux glibc /var/run/utmp path. Open before printing the heading so
        // a failure errors out cleanly (exit 1, no heading) like GNU.
        const fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            writeStderr("zpinky: cannot open /var/run/utmp\n");
            std.process.exit(1);
        }
        defer _ = libc.close(fd);

        printShortHeading(cfg);

        var entry: [LINUX_UTMP_SIZE]u8 = undefined;
        while (true) {
            const n = libc.read(fd, &entry, entry.len);
            if (n < LINUX_UTMP_SIZE) break;

            const ut_type = std.mem.readInt(i16, entry[0..2], .little);
            if (ut_type != UT_USER_PROCESS) continue;

            const username = extractString(entry[44 .. 44 + UT_NAMESIZE], UT_NAMESIZE);
            if (!matchesUser(cfg, username)) continue;
            const tty = extractString(entry[8 .. 8 + UT_LINESIZE], UT_LINESIZE);
            const host = extractString(entry[76 .. 76 + UT_HOSTSIZE], UT_HOSTSIZE);
            const login_time = std.mem.readInt(i32, entry[340..344], .little);

            printShortRow(cfg, username, tty, host, login_time);
        }
    }
}

// ---------------------------------------------------------------------------
// Long format
// ---------------------------------------------------------------------------

fn writeMinWidth(s: []const u8, width: usize) void {
    writeStdout(s);
    if (s.len < width) {
        var pad: [64]u8 = undefined;
        var remaining = width - s.len;
        while (remaining > 0) {
            const n = if (remaining > pad.len) pad.len else remaining;
            @memset(pad[0..n], ' ');
            writeStdout(pad[0..n]);
            remaining -= n;
        }
    }
}

fn catUserFile(home: []const u8, name: []const u8, header: []const u8) void {
    if (home.len == 0) return;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ home, name }) catch return;
    const fd = libc.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return;
    defer _ = libc.close(fd);
    writeStdout(header);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) break;
        writeStdout(buf[0..@intCast(n)]);
    }
}

fn printLongEntry(cfg: *const Config, name: []const u8) void {
    var passwd_buf: [1024]u8 = undefined;
    const user_info = getUserInfo(name, &passwd_buf);

    // Line 1: "Login name: " + name in a 28-wide field + "In real life:  " + fullname
    writeStdout("Login name: ");
    writeMinWidth(name, 28);
    writeStdout("In real life:  ");
    if (user_info) |info| {
        if (info.fullname.len > 0) {
            writeStdout(info.fullname);
        } else {
            writeStdout("???");
        }
    } else {
        // Unknown user: no directory/shell line and no trailing blank line.
        writeStdout("???\n");
        return;
    }
    writeStdout("\n");

    if (!cfg.omit_home_shell) {
        const info = user_info.?;
        writeStdout("Directory: ");
        writeMinWidth(info.home, 29);
        writeStdout("Shell:  ");
        writeStdout(info.shell);
        writeStdout("\n");
    }

    if (!cfg.omit_project) {
        catUserFile(user_info.?.home, ".project", "Project: ");
    }
    if (!cfg.omit_plan) {
        catUserFile(user_info.?.home, ".plan", "Plan:\n");
    }

    writeStdout("\n");
}

fn printLongFormat(cfg: *const Config) void {
    // GNU pinky long format ignores utmp entirely: it prints getpwnam info for
    // each USER named on the command line, and requires at least one.
    if (cfg.user_count == 0) dieNoUsername();
    for (cfg.users[0..cfg.user_count]) |name| {
        printLongEntry(cfg, name);
    }
}

// ---------------------------------------------------------------------------

fn applyShortFlag(cfg: *Config, ch: u8) void {
    switch (ch) {
        'l' => cfg.long_format = true,
        's' => cfg.long_format = false,
        'f' => cfg.omit_heading = true,
        'w' => cfg.omit_fullname = true,
        'i' => {
            cfg.omit_fullname = true;
            cfg.omit_host = true;
        },
        'q' => {
            cfg.omit_fullname = true;
            cfg.omit_host = true;
            cfg.omit_idle = true;
        },
        'b' => cfg.omit_home_shell = true,
        'h' => cfg.omit_project = true,
        'p' => cfg.omit_plan = true,
        else => dieInvalidOption(ch),
    }
}

fn addUser(cfg: *Config, arg: []const u8) void {
    if (cfg.user_count < cfg.users.len) {
        cfg.users[cfg.user_count] = arg;
        cfg.user_count += 1;
    }
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Collect args into array
    var args_storage: [512][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (args_count < args_storage.len) {
            args_storage[args_count] = arg;
            args_count += 1;
        }
    }
    const args = args_storage[0..args_count];

    var only_users = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (only_users) {
            addUser(&cfg, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            only_users = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "--lookup")) {
            cfg.do_lookup = true;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Unknown long option.
            dieUnrecognizedOption(arg);
        } else if (arg.len > 1 and arg[0] == '-') {
            // Bundled short flags, e.g. "-lb".
            for (arg[1..]) |ch| applyShortFlag(&cfg, ch);
        } else {
            // Operand (USER), including a lone "-".
            addUser(&cfg, arg);
        }
    }

    if (cfg.long_format) {
        printLongFormat(&cfg);
    } else {
        printShortFormat(&cfg);
    }
}
