//! zstty - Change and print terminal line settings
//!
//! A Zig implementation of stty (GNU coreutils `stty`).
//! Print or change terminal characteristics.
//!
//! Usage: zstty [OPTIONS] [SETTING]...
//!
//! Portability: the termios struct layout, flag bit positions, NCCS, control-
//! character indices and the baud-rate encoding all differ between Linux and the
//! BSD/Darwin family. Rather than hard-coding one ABI, this file consumes Zig's
//! target-aware `std.c.termios` (whose flag words are POSIX-named packed structs)
//! and only picks the small handful of constants std.c does not expose
//! (V* cc indices, TIOC*WINSZ ioctl numbers, _POSIX_VDISABLE) per-target below.

const std = @import("std");
const builtin = @import("builtin");

const VERSION = "1.0.0";

const os_tag = builtin.os.tag;
const is_darwin = os_tag.isDarwin();

// Target-aware termios types (correct field offsets, widths and NCCS per OS).
const termios = std.c.termios;
const speed_t = std.c.speed_t;
const NCCS = std.c.NCCS;

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn cfgetospeed(t: *const termios) speed_t;
extern "c" fn cfgetispeed(t: *const termios) speed_t;
extern "c" fn cfsetospeed(t: *termios, speed: speed_t) c_int;
extern "c" fn cfsetispeed(t: *termios, speed: speed_t) c_int;

// Terminal size ioctls. The request numbers are OS-specific.
const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const TIOCGWINSZ: c_ulong = if (is_darwin) 0x40087468 else 0x5413;
const TIOCSWINSZ: c_ulong = if (is_darwin) 0x80087467 else 0x5414;

// _POSIX_VDISABLE: the byte GNU stty writes to disable a control char.
// 0xff on the BSD/Darwin family, 0 on Linux.
const VDISABLE: u8 = if (is_darwin) 0xff else 0;

// Control-character array indices. POSIX gives names, not values; the numeric
// slot each name occupies is ABI-defined and differs between Linux and Darwin.
const CC = if (is_darwin) struct {
    const EOF = 0;
    const EOL = 1;
    const EOL2 = 2;
    const ERASE = 3;
    const WERASE = 4;
    const KILL = 5;
    const REPRINT = 6;
    const INTR = 8;
    const QUIT = 9;
    const SUSP = 10;
    const DSUSP = 11;
    const START = 12;
    const STOP = 13;
    const LNEXT = 14;
    const DISCARD = 15;
    const MIN = 16;
    const TIME = 17;
    const STATUS = 18;
} else struct {
    const INTR = 0;
    const QUIT = 1;
    const ERASE = 2;
    const KILL = 3;
    const EOF = 4;
    const TIME = 5;
    const MIN = 6;
    const SWTC = 7;
    const START = 8;
    const STOP = 9;
    const SUSP = 10;
    const EOL = 11;
    const REPRINT = 12;
    const DISCARD = 13;
    const WERASE = 14;
    const LNEXT = 15;
    const EOL2 = 16;
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

    var device: ?[]const u8 = null;
    var show_all = false;
    var show_settings = false;
    var settings: std.ArrayListUnmanaged([]const u8) = .empty;
    defer settings.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zstty {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--save")) {
            show_settings = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zstty: option requires an argument -- 'F'\n", .{});
                std.process.exit(1);
            }
            device = args[i];
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            device = arg["--file=".len..];
        } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-F")) {
            device = arg[2..];
        } else {
            try settings.append(allocator, arg);
        }
    }

    // GNU: "when specifying an output style, modes may not be set".
    if ((show_all or show_settings) and settings.items.len > 0) {
        writeStderr("zstty: when specifying an output style, modes may not be set\n", .{});
        std.process.exit(1);
    }

    // Choose the fd: a named device (-F) or stdin.
    var fd: c_int = 0;
    if (device) |dev| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (dev.len >= path_buf.len) {
            writeStderr("zstty: {s}: file name too long\n", .{dev});
            std.process.exit(1);
        }
        @memcpy(path_buf[0..dev.len], dev);
        path_buf[dev.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..dev.len :0];
        // O_NONBLOCK|O_NOCTTY so opening a tty device never blocks on carrier and
        // never steals a controlling terminal.
        const opened = std.c.open(path_z, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .NOCTTY = true });
        if (opened < 0) {
            writeStderr("zstty: {s}: No such file or directory\n", .{dev});
            std.process.exit(1);
        }
        fd = opened;
    }

    // Check that the fd is a terminal
    if (isatty(fd) == 0) {
        if (device) |dev| {
            writeStderr("zstty: {s}: Inappropriate ioctl for device\n", .{dev});
        } else {
            writeStderr("zstty: standard input: not a tty\n", .{});
        }
        std.process.exit(1);
    }

    // Get current terminal settings
    var tio: termios = undefined;
    if (std.c.tcgetattr(fd, &tio) != 0) {
        writeStderr("zstty: cannot get terminal attributes\n", .{});
        std.process.exit(1);
    }

    // If no settings, display current
    if (settings.items.len == 0) {
        if (show_settings) {
            printSaveFormat(&tio);
        } else {
            printSettings(&tio, fd, show_all);
        }
        return;
    }

    // Apply settings
    var modified = false;
    i = 0;
    while (i < settings.items.len) {
        const s = settings.items[i];

        switch (tryValueSetting(&tio, settings.items, &i, fd)) {
            .set => {
                modified = true;
                i += 1;
                continue;
            },
            .query => {
                i += 1;
                continue;
            },
            .err => std.process.exit(1),
            .no => {},
        }

        if (applySetting(&tio, s)) {
            modified = true;
        } else if (s.len > 0 and s[0] == '-' and applyFlagSetting(&tio, s[1..], false)) {
            modified = true;
        } else {
            writeStderr("zstty: invalid argument '{s}'\n", .{s});
            std.process.exit(1);
        }
        i += 1;
    }

    if (modified) {
        if (std.c.tcsetattr(fd, .DRAIN, &tio) != 0) {
            writeStderr("zstty: cannot set terminal attributes\n", .{});
            std.process.exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Flag tables: (setting-name -> packed-struct field). Driving set/clear/read
// off these tables keeps the Linux and Darwin field names (which are identical,
// POSIX-standard) working from one source.
// ---------------------------------------------------------------------------

const FlagName = struct { name: []const u8, field: []const u8 };

const iflags = [_]FlagName{
    .{ .name = "ignbrk", .field = "IGNBRK" },
    .{ .name = "brkint", .field = "BRKINT" },
    .{ .name = "ignpar", .field = "IGNPAR" },
    .{ .name = "parmrk", .field = "PARMRK" },
    .{ .name = "inpck", .field = "INPCK" },
    .{ .name = "istrip", .field = "ISTRIP" },
    .{ .name = "inlcr", .field = "INLCR" },
    .{ .name = "igncr", .field = "IGNCR" },
    .{ .name = "icrnl", .field = "ICRNL" },
    .{ .name = "ixon", .field = "IXON" },
    .{ .name = "ixoff", .field = "IXOFF" },
    .{ .name = "ixany", .field = "IXANY" },
    .{ .name = "imaxbel", .field = "IMAXBEL" },
    .{ .name = "iutf8", .field = "IUTF8" },
};

const oflags = [_]FlagName{
    .{ .name = "opost", .field = "OPOST" },
    .{ .name = "onlcr", .field = "ONLCR" },
    .{ .name = "ocrnl", .field = "OCRNL" },
    .{ .name = "onocr", .field = "ONOCR" },
    .{ .name = "onlret", .field = "ONLRET" },
};

const cflags = [_]FlagName{
    .{ .name = "cstopb", .field = "CSTOPB" },
    .{ .name = "cread", .field = "CREAD" },
    .{ .name = "parenb", .field = "PARENB" },
    .{ .name = "parodd", .field = "PARODD" },
    .{ .name = "hupcl", .field = "HUPCL" },
    .{ .name = "clocal", .field = "CLOCAL" },
};

const lflags = [_]FlagName{
    .{ .name = "isig", .field = "ISIG" },
    .{ .name = "icanon", .field = "ICANON" },
    .{ .name = "echo", .field = "ECHO" },
    .{ .name = "echoe", .field = "ECHOE" },
    .{ .name = "echok", .field = "ECHOK" },
    .{ .name = "echonl", .field = "ECHONL" },
    .{ .name = "noflsh", .field = "NOFLSH" },
    .{ .name = "tostop", .field = "TOSTOP" },
    .{ .name = "echoctl", .field = "ECHOCTL" },
    .{ .name = "echoprt", .field = "ECHOPRT" },
    .{ .name = "echoke", .field = "ECHOKE" },
    .{ .name = "iexten", .field = "IEXTEN" },
};

/// Set or clear a single boolean flag by its stty name across all four flag
/// words. Returns true if the name matched a known flag.
fn applyFlagSetting(tio: *termios, name: []const u8, val: bool) bool {
    inline for (iflags) |e| {
        if (std.mem.eql(u8, name, e.name)) {
            @field(tio.iflag, e.field) = val;
            return true;
        }
    }
    inline for (oflags) |e| {
        if (std.mem.eql(u8, name, e.name)) {
            @field(tio.oflag, e.field) = val;
            return true;
        }
    }
    inline for (cflags) |e| {
        if (std.mem.eql(u8, name, e.name)) {
            @field(tio.cflag, e.field) = val;
            return true;
        }
    }
    inline for (lflags) |e| {
        if (std.mem.eql(u8, name, e.name)) {
            @field(tio.lflag, e.field) = val;
            return true;
        }
    }
    return false;
}

fn applySetting(tio: *termios, setting: []const u8) bool {
    // Special / combination modes
    if (std.mem.eql(u8, setting, "raw")) {
        // GNU raw: no input processing, no output post-processing, no canonical
        // input / signals. Matches GNU coreutils `stty raw` (verified byte-exact
        // against gstty -g on Darwin): iflag cleared, OPOST off, ISIG+ICANON off,
        // cs8/-parenb, VMIN=1/VTIME=0. Echo and IEXTEN are intentionally left
        // untouched, mirroring GNU.
        tio.iflag = .{};
        tio.oflag.OPOST = false;
        tio.lflag.ISIG = false;
        tio.lflag.ICANON = false;
        tio.cflag.PARENB = false;
        tio.cflag.CSIZE = .CS8;
        tio.cc[CC.MIN] = 1;
        tio.cc[CC.TIME] = 0;
        return true;
    } else if (std.mem.eql(u8, setting, "cooked")) {
        // GNU `cooked` == `-raw`: OR the cooked-mode bits back on, without the
        // full reset `sane` performs (verified byte-exact against gstty -g).
        tio.iflag.BRKINT = true;
        tio.iflag.IGNPAR = true;
        tio.iflag.ISTRIP = true;
        tio.iflag.ICRNL = true;
        tio.iflag.IXON = true;
        tio.oflag.OPOST = true;
        tio.lflag.ISIG = true;
        tio.lflag.ICANON = true;
        tio.lflag.IEXTEN = true;
        return true;
    } else if (std.mem.eql(u8, setting, "sane")) {
        // GNU sane: reset the flag words to the canonical baseline (verified
        // byte-exact against gstty -g on Darwin).
        tio.iflag = .{ .BRKINT = true, .ICRNL = true, .IXON = true, .IMAXBEL = true };
        tio.oflag = .{ .OPOST = true, .ONLCR = true };
        tio.lflag = .{
            .ECHOKE = true,
            .ECHOE = true,
            .ECHOK = true,
            .ECHO = true,
            .ECHOCTL = true,
            .ISIG = true,
            .ICANON = true,
            .IEXTEN = true,
        };
        tio.cflag.CREAD = true;
        return true;
    }

    // Character size
    if (std.mem.eql(u8, setting, "cs5")) {
        tio.cflag.CSIZE = .CS5;
        return true;
    }
    if (std.mem.eql(u8, setting, "cs6")) {
        tio.cflag.CSIZE = .CS6;
        return true;
    }
    if (std.mem.eql(u8, setting, "cs7")) {
        tio.cflag.CSIZE = .CS7;
        return true;
    }
    if (std.mem.eql(u8, setting, "cs8")) {
        tio.cflag.CSIZE = .CS8;
        return true;
    }

    // Plain boolean flags
    return applyFlagSetting(tio, setting, true);
}

// ---------------------------------------------------------------------------
// Value settings: those that consume a following argument (or are themselves a
// number). rows/cols/columns, min/time, ispeed/ospeed, a bare baud number, the
// `speed` query, and control-character assignments (intr, erase, ...).
// ---------------------------------------------------------------------------

const ValueResult = enum { no, set, query, err };

const CcName = struct { name: []const u8, idx: usize };

const cc_names = if (is_darwin) [_]CcName{
    .{ .name = "intr", .idx = CC.INTR },
    .{ .name = "quit", .idx = CC.QUIT },
    .{ .name = "erase", .idx = CC.ERASE },
    .{ .name = "kill", .idx = CC.KILL },
    .{ .name = "eof", .idx = CC.EOF },
    .{ .name = "eol", .idx = CC.EOL },
    .{ .name = "eol2", .idx = CC.EOL2 },
    .{ .name = "start", .idx = CC.START },
    .{ .name = "stop", .idx = CC.STOP },
    .{ .name = "susp", .idx = CC.SUSP },
    .{ .name = "dsusp", .idx = CC.DSUSP },
    .{ .name = "rprnt", .idx = CC.REPRINT },
    .{ .name = "werase", .idx = CC.WERASE },
    .{ .name = "lnext", .idx = CC.LNEXT },
    .{ .name = "discard", .idx = CC.DISCARD },
    .{ .name = "status", .idx = CC.STATUS },
} else [_]CcName{
    .{ .name = "intr", .idx = CC.INTR },
    .{ .name = "quit", .idx = CC.QUIT },
    .{ .name = "erase", .idx = CC.ERASE },
    .{ .name = "kill", .idx = CC.KILL },
    .{ .name = "eof", .idx = CC.EOF },
    .{ .name = "eol", .idx = CC.EOL },
    .{ .name = "eol2", .idx = CC.EOL2 },
    .{ .name = "start", .idx = CC.START },
    .{ .name = "stop", .idx = CC.STOP },
    .{ .name = "susp", .idx = CC.SUSP },
    .{ .name = "rprnt", .idx = CC.REPRINT },
    .{ .name = "werase", .idx = CC.WERASE },
    .{ .name = "lnext", .idx = CC.LNEXT },
    .{ .name = "discard", .idx = CC.DISCARD },
    .{ .name = "swtch", .idx = CC.SWTC },
};

/// Consume `settings[*i]` (and possibly the following token) if it names a
/// value setting. On success `*i` is left pointing at the last token consumed.
fn tryValueSetting(tio: *termios, settings: []const []const u8, i: *usize, fd: c_int) ValueResult {
    const s = settings[i.*];

    // `speed` query: print the output speed, like GNU `stty speed`.
    if (std.mem.eql(u8, s, "speed")) {
        writeStdout("{d}\n", .{ospeedNum(tio)});
        return .query;
    }

    // rows / cols / columns N
    if (std.mem.eql(u8, s, "rows") or std.mem.eql(u8, s, "cols") or std.mem.eql(u8, s, "columns")) {
        const v = nextInt(u16, settings, i) orelse return valueErr(s);
        if (std.mem.eql(u8, s, "rows")) setWinsize(fd, v, null) else setWinsize(fd, null, v);
        return .set;
    }

    // min / time N (VMIN / VTIME are counts, not chars)
    if (std.mem.eql(u8, s, "min")) {
        const v = nextInt(u8, settings, i) orelse return valueErr(s);
        tio.cc[CC.MIN] = v;
        return .set;
    }
    if (std.mem.eql(u8, s, "time")) {
        const v = nextInt(u8, settings, i) orelse return valueErr(s);
        tio.cc[CC.TIME] = v;
        return .set;
    }

    // ispeed / ospeed N
    if (std.mem.eql(u8, s, "ispeed")) {
        const v = nextInt(u32, settings, i) orelse return valueErr(s);
        if (numToSpeed(v)) |sp| {
            _ = cfsetispeed(tio, sp);
            return .set;
        }
        return valueErr(s);
    }
    if (std.mem.eql(u8, s, "ospeed")) {
        const v = nextInt(u32, settings, i) orelse return valueErr(s);
        if (numToSpeed(v)) |sp| {
            _ = cfsetospeed(tio, sp);
            return .set;
        }
        return valueErr(s);
    }

    // Control-character assignment: `intr ^C`, `erase ^H`, `eof undef`, ...
    inline for (cc_names) |e| {
        if (std.mem.eql(u8, s, e.name)) {
            if (i.* + 1 >= settings.len) return valueErr(s);
            const val = parseCcValue(settings[i.* + 1]) orelse {
                writeStderr("zstty: invalid integer argument '{s}'\n", .{settings[i.* + 1]});
                return .err;
            };
            tio.cc[e.idx] = val;
            i.* += 1;
            return .set;
        }
    }

    // A bare baud number sets both input and output speed.
    if (s.len > 0 and allDigits(s)) {
        const v = std.fmt.parseInt(u32, s, 10) catch return valueErr(s);
        if (numToSpeed(v)) |sp| {
            _ = cfsetispeed(tio, sp);
            _ = cfsetospeed(tio, sp);
            return .set;
        }
        return valueErr(s);
    }

    return .no;
}

fn valueErr(name: []const u8) ValueResult {
    writeStderr("zstty: invalid argument '{s}'\n", .{name});
    return .err;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Read the integer token following settings[*i]; advance *i past it on success.
fn nextInt(comptime T: type, settings: []const []const u8, i: *usize) ?T {
    if (i.* + 1 >= settings.len) return null;
    const tok = settings[i.* + 1];
    const v = std.fmt.parseInt(T, tok, 10) catch return null;
    i.* += 1;
    return v;
}

/// Parse a control-character value the way GNU stty does:
///   ^C / ^?  -> control char           undef / ^-  -> _POSIX_VDISABLE
///   single char -> that byte           otherwise   -> integer (base 0)
fn parseCcValue(s: []const u8) ?u8 {
    if (std.mem.eql(u8, s, "undef") or std.mem.eql(u8, s, "^-")) return VDISABLE;
    if (s.len >= 2 and s[0] == '^') {
        if (s[1] == '?') return 0x7f;
        return s[1] & 0x1f;
    }
    if (s.len == 1) return s[0];
    const v = std.fmt.parseInt(u16, s, 0) catch return null;
    if (v > 0xff) return null;
    return @intCast(v);
}

// ---------------------------------------------------------------------------
// Speed helpers
// ---------------------------------------------------------------------------

/// The numeric output baud. On Darwin/BSD speed_t's value *is* the baud; on
/// Linux it is a Bxxxx code that must be decoded.
fn ospeedNum(tio: *const termios) u32 {
    return speedToNum(cfgetospeed(tio));
}

fn speedToNum(sp: speed_t) u32 {
    if (is_darwin) return @intCast(@intFromEnum(sp));
    // Linux: speed_t is the Bxxxx octal code.
    return switch (@intFromEnum(sp)) {
        0o0 => 0,
        0o1 => 50,
        0o2 => 75,
        0o3 => 110,
        0o4 => 134,
        0o5 => 150,
        0o6 => 200,
        0o7 => 300,
        0o10 => 600,
        0o11 => 1200,
        0o12 => 1800,
        0o13 => 2400,
        0o14 => 4800,
        0o15 => 9600,
        0o16 => 19200,
        0o17 => 38400,
        0o10001 => 57600,
        0o10002 => 115200,
        0o10003 => 230400,
        else => 0,
    };
}

const known_bauds = [_]u32{ 0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400 };

fn numToSpeed(n: u32) ?speed_t {
    if (is_darwin) {
        // Darwin speed_t's enum values equal the baud rate.
        for (known_bauds) |b| {
            if (b == n) return @enumFromInt(n);
        }
        // Darwin also has 7200/14400/28800/76800.
        switch (n) {
            7200, 14400, 28800, 76800 => return @enumFromInt(n),
            else => return null,
        }
    }
    const code: u32 = switch (n) {
        0 => 0o0,
        50 => 0o1,
        75 => 0o2,
        110 => 0o3,
        134 => 0o4,
        150 => 0o5,
        200 => 0o6,
        300 => 0o7,
        600 => 0o10,
        1200 => 0o11,
        1800 => 0o12,
        2400 => 0o13,
        4800 => 0o14,
        9600 => 0o15,
        19200 => 0o16,
        38400 => 0o17,
        57600 => 0o10001,
        115200 => 0o10002,
        230400 => 0o10003,
        else => return null,
    };
    return @enumFromInt(code);
}

// ---------------------------------------------------------------------------
// Window size
// ---------------------------------------------------------------------------

fn setWinsize(fd: c_int, rows: ?u16, cols: ?u16) void {
    var ws: winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        if (rows) |r| ws.ws_row = r;
        if (cols) |c| ws.ws_col = c;
        _ = ioctl(fd, TIOCSWINSZ, &ws);
    }
}

// ---------------------------------------------------------------------------
// Bit extraction for -g / -a
// ---------------------------------------------------------------------------

fn flagBits(v: anytype) u64 {
    const B = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(v)));
    return @as(B, @bitCast(v));
}

fn printSaveFormat(tio: *const termios) void {
    // GNU emits minimal-width hex for the four flag words, then one hex value per
    // control char at the platform's NCCS count, colon-separated.
    writeStdout("{x}:{x}:{x}:{x}", .{
        flagBits(tio.iflag),
        flagBits(tio.oflag),
        flagBits(tio.cflag),
        flagBits(tio.lflag),
    });
    for (tio.cc, 0..) |cc, idx| {
        _ = idx;
        writeStdout(":{x}", .{cc});
    }
    writeStdout("\n", .{});
}

fn printSettings(tio: *const termios, fd: c_int, show_all: bool) void {
    // Speed
    writeStdout("speed {d} baud; ", .{ospeedNum(tio)});

    // Terminal size
    var ws: winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        writeStdout("rows {d}; columns {d};\n", .{ ws.ws_row, ws.ws_col });
    } else {
        writeStdout("\n", .{});
    }

    if (!show_all) {
        // Brief output. (GNU additionally prints settings differing from `sane`;
        // that diff is not reproduced here.)
        return;
    }

    // Distinct buffers: formatCC may return a slice into its buffer, so each
    // argument in a single writeStdout needs its own (else they all alias).
    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    var b3: [8]u8 = undefined;

    // Control characters
    writeStdout("intr = {s}; quit = {s}; erase = {s}; kill = {s};\n", .{
        formatCC(&b0, tio.cc[CC.INTR]),
        formatCC(&b1, tio.cc[CC.QUIT]),
        formatCC(&b2, tio.cc[CC.ERASE]),
        formatCC(&b3, tio.cc[CC.KILL]),
    });
    writeStdout("eof = {s}; start = {s}; stop = {s}; susp = {s};\n", .{
        formatCC(&b0, tio.cc[CC.EOF]),
        formatCC(&b1, tio.cc[CC.START]),
        formatCC(&b2, tio.cc[CC.STOP]),
        formatCC(&b3, tio.cc[CC.SUSP]),
    });
    writeStdout("min = {d}; time = {d};\n", .{ tio.cc[CC.MIN], tio.cc[CC.TIME] });

    // Input flags
    writeStdout("{s}ignbrk {s}brkint {s}ignpar {s}parmrk {s}inpck {s}istrip\n", .{
        pfx(tio.iflag.IGNBRK), pfx(tio.iflag.BRKINT), pfx(tio.iflag.IGNPAR),
        pfx(tio.iflag.PARMRK), pfx(tio.iflag.INPCK),  pfx(tio.iflag.ISTRIP),
    });
    writeStdout("{s}inlcr {s}igncr {s}icrnl {s}ixon {s}ixoff {s}ixany {s}imaxbel {s}iutf8\n", .{
        pfx(tio.iflag.INLCR), pfx(tio.iflag.IGNCR),   pfx(tio.iflag.ICRNL),
        pfx(tio.iflag.IXON),  pfx(tio.iflag.IXOFF),   pfx(tio.iflag.IXANY),
        pfx(tio.iflag.IMAXBEL), pfx(tio.iflag.IUTF8),
    });

    // Output flags
    writeStdout("{s}opost {s}onlcr {s}ocrnl {s}onocr {s}onlret\n", .{
        pfx(tio.oflag.OPOST),  pfx(tio.oflag.ONLCR), pfx(tio.oflag.OCRNL),
        pfx(tio.oflag.ONOCR),  pfx(tio.oflag.ONLRET),
    });

    // Control flags
    const cs = switch (tio.cflag.CSIZE) {
        .CS5 => "cs5",
        .CS6 => "cs6",
        .CS7 => "cs7",
        .CS8 => "cs8",
    };
    writeStdout("{s} {s}cstopb {s}cread {s}parenb {s}parodd {s}hupcl {s}clocal\n", .{
        cs,
        pfx(tio.cflag.CSTOPB), pfx(tio.cflag.CREAD),  pfx(tio.cflag.PARENB),
        pfx(tio.cflag.PARODD), pfx(tio.cflag.HUPCL),  pfx(tio.cflag.CLOCAL),
    });

    // Local flags
    writeStdout("{s}isig {s}icanon {s}echo {s}echoe {s}echok {s}echonl\n", .{
        pfx(tio.lflag.ISIG),  pfx(tio.lflag.ICANON), pfx(tio.lflag.ECHO),
        pfx(tio.lflag.ECHOE), pfx(tio.lflag.ECHOK),  pfx(tio.lflag.ECHONL),
    });
    writeStdout("{s}noflsh {s}tostop {s}echoctl {s}echoprt {s}echoke {s}iexten\n", .{
        pfx(tio.lflag.NOFLSH),  pfx(tio.lflag.TOSTOP),  pfx(tio.lflag.ECHOCTL),
        pfx(tio.lflag.ECHOPRT), pfx(tio.lflag.ECHOKE),  pfx(tio.lflag.IEXTEN),
    });
}

fn pfx(on: bool) []const u8 {
    return if (on) "" else "-";
}

/// Render a control character the way GNU stty does. `buf` must be >= 3 bytes.
fn formatCC(buf: []u8, cc: u8) []const u8 {
    if (cc == VDISABLE) return "<undef>";
    if (cc == 0x7f) return "^?";
    if (cc < 32) {
        buf[0] = '^';
        buf[1] = cc + 0x40;
        return buf[0..2];
    }
    // Printable byte (0x20..0x7e): echo the literal character, as GNU does.
    if (cc < 0x7f) {
        buf[0] = cc;
        return buf[0..1];
    }
    // Any remaining high byte that is not the disable sentinel.
    return std.fmt.bufPrint(buf, "\\{o}", .{cc}) catch "?";
}

fn printHelp() void {
    writeStdout(
        \\Usage: zstty [OPTION]... [SETTING]...
        \\Print or change terminal line settings.
        \\
        \\Options:
        \\  -a, --all       print all current settings in human-readable form
        \\  -g, --save      print all current settings in a stty-readable form
        \\  -F, --file DEV  open and use the specified device instead of stdin
        \\      --help      display this help and exit
        \\      --version   output version information and exit
        \\
        \\Settings:
        \\  Special:
        \\    raw           same as -ignbrk -brkint -parmrk -istrip -inlcr
        \\                  -igncr -icrnl -ixon -opost -echo -icanon -isig cs8
        \\    cooked/sane   set reasonable terminal settings
        \\
        \\  Values:
        \\    rows N / cols N       set window rows / columns
        \\    N / ispeed N/ospeed N set line speed (baud)
        \\    intr/erase/eof/... C  set a control character (e.g. `intr ^C`, `eof undef`)
        \\    min N / time N        set VMIN / VTIME
        \\    speed                 print the terminal output speed
        \\
        \\  Input:   [-]ignbrk [-]brkint [-]icrnl [-]ixon [-]iutf8 ...
        \\  Output:  [-]opost [-]onlcr ...
        \\  Local:   [-]echo [-]icanon [-]isig ...
        \\  Control: cs5/cs6/cs7/cs8 [-]cread [-]parenb ...
        \\
        \\Examples:
        \\  zstty -a              Show all settings
        \\  zstty raw             Set raw mode
        \\  zstty sane            Reset to sane defaults
        \\  zstty -echo           Disable echo
        \\  zstty rows 40 cols 100
        \\  zstty intr ^C
        \\
    , .{});
}
