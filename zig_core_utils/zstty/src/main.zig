//! zstty - Change and print terminal line settings
//!
//! A Zig implementation of stty.
//! Print or change terminal characteristics.
//!
//! Usage: zstty [OPTIONS] [SETTING]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;

// Termios structure (Linux x86_64)
const cc_t = u8;
const speed_t = u32;
const tcflag_t = u32;

const NCCS = 32;

const termios = extern struct {
    c_iflag: tcflag_t,
    c_oflag: tcflag_t,
    c_cflag: tcflag_t,
    c_lflag: tcflag_t,
    c_line: cc_t,
    c_cc: [NCCS]cc_t,
    c_ispeed: speed_t,
    c_ospeed: speed_t,
};

extern "c" fn tcgetattr(fd: c_int, termios_p: *termios) c_int;
extern "c" fn tcsetattr(fd: c_int, optional_actions: c_int, termios_p: *const termios) c_int;

// Terminal size
const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const TIOCGWINSZ: c_ulong = 0x5413;
const TIOCSWINSZ: c_ulong = 0x5414;

const TCSANOW: c_int = 0;
const TCSADRAIN: c_int = 1;
const TCSAFLUSH: c_int = 2;

// Input flags (c_iflag)
const IGNBRK: tcflag_t = 0o000001;
const BRKINT: tcflag_t = 0o000002;
const IGNPAR: tcflag_t = 0o000004;
const PARMRK: tcflag_t = 0o000010;
const INPCK: tcflag_t = 0o000020;
const ISTRIP: tcflag_t = 0o000040;
const INLCR: tcflag_t = 0o000100;
const IGNCR: tcflag_t = 0o000200;
const ICRNL: tcflag_t = 0o000400;
const IUCLC: tcflag_t = 0o001000;
const IXON: tcflag_t = 0o002000;
const IXANY: tcflag_t = 0o004000;
const IXOFF: tcflag_t = 0o010000;
const IMAXBEL: tcflag_t = 0o020000;
const IUTF8: tcflag_t = 0o040000;

// Output flags (c_oflag)
const OPOST: tcflag_t = 0o000001;
const OLCUC: tcflag_t = 0o000002;
const ONLCR: tcflag_t = 0o000004;
const OCRNL: tcflag_t = 0o000010;
const ONOCR: tcflag_t = 0o000020;
const ONLRET: tcflag_t = 0o000040;
const OFILL: tcflag_t = 0o000100;
const OFDEL: tcflag_t = 0o000200;

// Control flags (c_cflag)
const CSIZE: tcflag_t = 0o000060;
const CS5: tcflag_t = 0o000000;
const CS6: tcflag_t = 0o000020;
const CS7: tcflag_t = 0o000040;
const CS8: tcflag_t = 0o000060;
const CSTOPB: tcflag_t = 0o000100;
const CREAD: tcflag_t = 0o000200;
const PARENB: tcflag_t = 0o000400;
const PARODD: tcflag_t = 0o001000;
const HUPCL: tcflag_t = 0o002000;
const CLOCAL: tcflag_t = 0o004000;

// Local flags (c_lflag)
const ISIG: tcflag_t = 0o000001;
const ICANON: tcflag_t = 0o000002;
const XCASE: tcflag_t = 0o000004;
const ECHO: tcflag_t = 0o000010;
const ECHOE: tcflag_t = 0o000020;
const ECHOK: tcflag_t = 0o000040;
const ECHONL: tcflag_t = 0o000100;
const NOFLSH: tcflag_t = 0o000200;
const TOSTOP: tcflag_t = 0o000400;
const ECHOCTL: tcflag_t = 0o001000;
const ECHOPRT: tcflag_t = 0o002000;
const ECHOKE: tcflag_t = 0o004000;
const FLUSHO: tcflag_t = 0o010000;
const PENDIN: tcflag_t = 0o040000;
const IEXTEN: tcflag_t = 0o100000;

// Control character indices
const VINTR = 0;
const VQUIT = 1;
const VERASE = 2;
const VKILL = 3;
const VEOF = 4;
const VTIME = 5;
const VMIN = 6;
const VSWTC = 7;
const VSTART = 8;
const VSTOP = 9;
const VSUSP = 10;
const VEOL = 11;
const VREPRINT = 12;
const VDISCARD = 13;
const VWERASE = 14;
const VLNEXT = 15;
const VEOL2 = 16;

// Baud rates
const B0: speed_t = 0o000000;
const B50: speed_t = 0o000001;
const B75: speed_t = 0o000002;
const B110: speed_t = 0o000003;
const B134: speed_t = 0o000004;
const B150: speed_t = 0o000005;
const B200: speed_t = 0o000006;
const B300: speed_t = 0o000007;
const B600: speed_t = 0o000010;
const B1200: speed_t = 0o000011;
const B1800: speed_t = 0o000012;
const B2400: speed_t = 0o000013;
const B4800: speed_t = 0o000014;
const B9600: speed_t = 0o000015;
const B19200: speed_t = 0o000016;
const B38400: speed_t = 0o000017;
const B57600: speed_t = 0o010001;
const B115200: speed_t = 0o010002;
const B230400: speed_t = 0o010003;

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

    const fd: c_int = 0; // stdin by default
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
            // Would need to open the file - simplified for now
            writeStderr("zstty: -F not yet implemented\n", .{});
            std.process.exit(1);
        } else {
            try settings.append(allocator, arg);
        }
    }

    // Check if stdin is a terminal
    if (isatty(fd) == 0) {
        writeStderr("zstty: standard input: not a tty\n", .{});
        std.process.exit(1);
    }

    // Get current terminal settings
    var tio: termios = undefined;
    if (tcgetattr(fd, &tio) != 0) {
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
    while (i < settings.items.len) : (i += 1) {
        const setting = settings.items[i];

        if (applySetting(&tio, setting, fd)) {
            modified = true;
        } else if (setting.len > 0 and setting[0] == '-') {
            // Check for negated flag
            if (applyNegatedSetting(&tio, setting[1..])) {
                modified = true;
            } else {
                writeStderr("zstty: invalid argument '{s}'\n", .{setting});
                std.process.exit(1);
            }
        } else {
            writeStderr("zstty: invalid argument '{s}'\n", .{setting});
            std.process.exit(1);
        }
    }

    if (modified) {
        if (tcsetattr(fd, TCSADRAIN, &tio) != 0) {
            writeStderr("zstty: cannot set terminal attributes\n", .{});
            std.process.exit(1);
        }
    }
}

fn applySetting(tio: *termios, setting: []const u8, fd: c_int) bool {
    // Special modes
    if (std.mem.eql(u8, setting, "raw")) {
        // Raw mode: no processing
        tio.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
        tio.c_oflag &= ~OPOST;
        tio.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
        tio.c_cflag &= ~(CSIZE | PARENB);
        tio.c_cflag |= CS8;
        return true;
    } else if (std.mem.eql(u8, setting, "cooked") or std.mem.eql(u8, setting, "sane")) {
        // Cooked/sane mode: normal processing
        tio.c_iflag |= BRKINT | ICRNL | IMAXBEL | IXON | IUTF8;
        tio.c_oflag |= OPOST | ONLCR;
        tio.c_lflag |= ISIG | ICANON | IEXTEN | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE;
        tio.c_cflag |= CREAD;
        return true;
    }

    // Input flags
    if (std.mem.eql(u8, setting, "ignbrk")) { tio.c_iflag |= IGNBRK; return true; }
    if (std.mem.eql(u8, setting, "brkint")) { tio.c_iflag |= BRKINT; return true; }
    if (std.mem.eql(u8, setting, "ignpar")) { tio.c_iflag |= IGNPAR; return true; }
    if (std.mem.eql(u8, setting, "parmrk")) { tio.c_iflag |= PARMRK; return true; }
    if (std.mem.eql(u8, setting, "inpck")) { tio.c_iflag |= INPCK; return true; }
    if (std.mem.eql(u8, setting, "istrip")) { tio.c_iflag |= ISTRIP; return true; }
    if (std.mem.eql(u8, setting, "inlcr")) { tio.c_iflag |= INLCR; return true; }
    if (std.mem.eql(u8, setting, "igncr")) { tio.c_iflag |= IGNCR; return true; }
    if (std.mem.eql(u8, setting, "icrnl")) { tio.c_iflag |= ICRNL; return true; }
    if (std.mem.eql(u8, setting, "ixon")) { tio.c_iflag |= IXON; return true; }
    if (std.mem.eql(u8, setting, "ixoff")) { tio.c_iflag |= IXOFF; return true; }
    if (std.mem.eql(u8, setting, "ixany")) { tio.c_iflag |= IXANY; return true; }
    if (std.mem.eql(u8, setting, "imaxbel")) { tio.c_iflag |= IMAXBEL; return true; }
    if (std.mem.eql(u8, setting, "iutf8")) { tio.c_iflag |= IUTF8; return true; }

    // Output flags
    if (std.mem.eql(u8, setting, "opost")) { tio.c_oflag |= OPOST; return true; }
    if (std.mem.eql(u8, setting, "onlcr")) { tio.c_oflag |= ONLCR; return true; }
    if (std.mem.eql(u8, setting, "ocrnl")) { tio.c_oflag |= OCRNL; return true; }
    if (std.mem.eql(u8, setting, "onocr")) { tio.c_oflag |= ONOCR; return true; }
    if (std.mem.eql(u8, setting, "onlret")) { tio.c_oflag |= ONLRET; return true; }

    // Local flags
    if (std.mem.eql(u8, setting, "isig")) { tio.c_lflag |= ISIG; return true; }
    if (std.mem.eql(u8, setting, "icanon")) { tio.c_lflag |= ICANON; return true; }
    if (std.mem.eql(u8, setting, "echo")) { tio.c_lflag |= ECHO; return true; }
    if (std.mem.eql(u8, setting, "echoe")) { tio.c_lflag |= ECHOE; return true; }
    if (std.mem.eql(u8, setting, "echok")) { tio.c_lflag |= ECHOK; return true; }
    if (std.mem.eql(u8, setting, "echonl")) { tio.c_lflag |= ECHONL; return true; }
    if (std.mem.eql(u8, setting, "noflsh")) { tio.c_lflag |= NOFLSH; return true; }
    if (std.mem.eql(u8, setting, "tostop")) { tio.c_lflag |= TOSTOP; return true; }
    if (std.mem.eql(u8, setting, "echoctl")) { tio.c_lflag |= ECHOCTL; return true; }
    if (std.mem.eql(u8, setting, "echoprt")) { tio.c_lflag |= ECHOPRT; return true; }
    if (std.mem.eql(u8, setting, "echoke")) { tio.c_lflag |= ECHOKE; return true; }
    if (std.mem.eql(u8, setting, "iexten")) { tio.c_lflag |= IEXTEN; return true; }

    // Control flags
    if (std.mem.eql(u8, setting, "cread")) { tio.c_cflag |= CREAD; return true; }
    if (std.mem.eql(u8, setting, "clocal")) { tio.c_cflag |= CLOCAL; return true; }
    if (std.mem.eql(u8, setting, "hupcl")) { tio.c_cflag |= HUPCL; return true; }
    if (std.mem.eql(u8, setting, "cstopb")) { tio.c_cflag |= CSTOPB; return true; }
    if (std.mem.eql(u8, setting, "parenb")) { tio.c_cflag |= PARENB; return true; }
    if (std.mem.eql(u8, setting, "parodd")) { tio.c_cflag |= PARODD; return true; }

    // Character size
    if (std.mem.eql(u8, setting, "cs5")) { tio.c_cflag = (tio.c_cflag & ~CSIZE) | CS5; return true; }
    if (std.mem.eql(u8, setting, "cs6")) { tio.c_cflag = (tio.c_cflag & ~CSIZE) | CS6; return true; }
    if (std.mem.eql(u8, setting, "cs7")) { tio.c_cflag = (tio.c_cflag & ~CSIZE) | CS7; return true; }
    if (std.mem.eql(u8, setting, "cs8")) { tio.c_cflag = (tio.c_cflag & ~CSIZE) | CS8; return true; }

    // Size settings
    if (std.mem.startsWith(u8, setting, "rows")) {
        if (setting.len > 4 and setting[4] == ' ') {
            const val = std.fmt.parseInt(u16, setting[5..], 10) catch return false;
            setRows(fd, val);
            return true;
        }
    }
    if (std.mem.startsWith(u8, setting, "cols") or std.mem.startsWith(u8, setting, "columns")) {
        const prefix_len: usize = if (std.mem.startsWith(u8, setting, "columns")) 7 else 4;
        if (setting.len > prefix_len and setting[prefix_len] == ' ') {
            const val = std.fmt.parseInt(u16, setting[prefix_len + 1 ..], 10) catch return false;
            setCols(fd, val);
            return true;
        }
    }

    return false;
}

fn applyNegatedSetting(tio: *termios, setting: []const u8) bool {
    // Input flags
    if (std.mem.eql(u8, setting, "ignbrk")) { tio.c_iflag &= ~IGNBRK; return true; }
    if (std.mem.eql(u8, setting, "brkint")) { tio.c_iflag &= ~BRKINT; return true; }
    if (std.mem.eql(u8, setting, "ignpar")) { tio.c_iflag &= ~IGNPAR; return true; }
    if (std.mem.eql(u8, setting, "parmrk")) { tio.c_iflag &= ~PARMRK; return true; }
    if (std.mem.eql(u8, setting, "inpck")) { tio.c_iflag &= ~INPCK; return true; }
    if (std.mem.eql(u8, setting, "istrip")) { tio.c_iflag &= ~ISTRIP; return true; }
    if (std.mem.eql(u8, setting, "inlcr")) { tio.c_iflag &= ~INLCR; return true; }
    if (std.mem.eql(u8, setting, "igncr")) { tio.c_iflag &= ~IGNCR; return true; }
    if (std.mem.eql(u8, setting, "icrnl")) { tio.c_iflag &= ~ICRNL; return true; }
    if (std.mem.eql(u8, setting, "ixon")) { tio.c_iflag &= ~IXON; return true; }
    if (std.mem.eql(u8, setting, "ixoff")) { tio.c_iflag &= ~IXOFF; return true; }
    if (std.mem.eql(u8, setting, "ixany")) { tio.c_iflag &= ~IXANY; return true; }
    if (std.mem.eql(u8, setting, "imaxbel")) { tio.c_iflag &= ~IMAXBEL; return true; }
    if (std.mem.eql(u8, setting, "iutf8")) { tio.c_iflag &= ~IUTF8; return true; }

    // Output flags
    if (std.mem.eql(u8, setting, "opost")) { tio.c_oflag &= ~OPOST; return true; }
    if (std.mem.eql(u8, setting, "onlcr")) { tio.c_oflag &= ~ONLCR; return true; }
    if (std.mem.eql(u8, setting, "ocrnl")) { tio.c_oflag &= ~OCRNL; return true; }
    if (std.mem.eql(u8, setting, "onocr")) { tio.c_oflag &= ~ONOCR; return true; }
    if (std.mem.eql(u8, setting, "onlret")) { tio.c_oflag &= ~ONLRET; return true; }

    // Local flags
    if (std.mem.eql(u8, setting, "isig")) { tio.c_lflag &= ~ISIG; return true; }
    if (std.mem.eql(u8, setting, "icanon")) { tio.c_lflag &= ~ICANON; return true; }
    if (std.mem.eql(u8, setting, "echo")) { tio.c_lflag &= ~ECHO; return true; }
    if (std.mem.eql(u8, setting, "echoe")) { tio.c_lflag &= ~ECHOE; return true; }
    if (std.mem.eql(u8, setting, "echok")) { tio.c_lflag &= ~ECHOK; return true; }
    if (std.mem.eql(u8, setting, "echonl")) { tio.c_lflag &= ~ECHONL; return true; }
    if (std.mem.eql(u8, setting, "noflsh")) { tio.c_lflag &= ~NOFLSH; return true; }
    if (std.mem.eql(u8, setting, "tostop")) { tio.c_lflag &= ~TOSTOP; return true; }
    if (std.mem.eql(u8, setting, "echoctl")) { tio.c_lflag &= ~ECHOCTL; return true; }
    if (std.mem.eql(u8, setting, "echoprt")) { tio.c_lflag &= ~ECHOPRT; return true; }
    if (std.mem.eql(u8, setting, "echoke")) { tio.c_lflag &= ~ECHOKE; return true; }
    if (std.mem.eql(u8, setting, "iexten")) { tio.c_lflag &= ~IEXTEN; return true; }

    // Control flags
    if (std.mem.eql(u8, setting, "cread")) { tio.c_cflag &= ~CREAD; return true; }
    if (std.mem.eql(u8, setting, "clocal")) { tio.c_cflag &= ~CLOCAL; return true; }
    if (std.mem.eql(u8, setting, "hupcl")) { tio.c_cflag &= ~HUPCL; return true; }
    if (std.mem.eql(u8, setting, "cstopb")) { tio.c_cflag &= ~CSTOPB; return true; }
    if (std.mem.eql(u8, setting, "parenb")) { tio.c_cflag &= ~PARENB; return true; }
    if (std.mem.eql(u8, setting, "parodd")) { tio.c_cflag &= ~PARODD; return true; }

    return false;
}

fn setRows(fd: c_int, rows: u16) void {
    var ws: winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        ws.ws_row = rows;
        _ = ioctl(fd, TIOCSWINSZ, &ws);
    }
}

fn setCols(fd: c_int, cols: u16) void {
    var ws: winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        ws.ws_col = cols;
        _ = ioctl(fd, TIOCSWINSZ, &ws);
    }
}

fn printSettings(tio: *const termios, fd: c_int, show_all: bool) void {
    // Speed
    const speed = baudToNum(tio.c_ospeed);
    writeStdout("speed {d} baud; ", .{speed});

    // Terminal size
    var ws: winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        writeStdout("rows {d}; columns {d};\n", .{ ws.ws_row, ws.ws_col });
    } else {
        writeStdout("\n", .{});
    }

    if (!show_all) {
        // Brief output - show only non-default settings
        return;
    }

    // Control characters
    writeStdout("intr = {s}; quit = {s}; erase = {s}; kill = {s};\n", .{
        formatCC(tio.c_cc[VINTR]),
        formatCC(tio.c_cc[VQUIT]),
        formatCC(tio.c_cc[VERASE]),
        formatCC(tio.c_cc[VKILL]),
    });
    writeStdout("eof = {s}; start = {s}; stop = {s}; susp = {s};\n", .{
        formatCC(tio.c_cc[VEOF]),
        formatCC(tio.c_cc[VSTART]),
        formatCC(tio.c_cc[VSTOP]),
        formatCC(tio.c_cc[VSUSP]),
    });

    // Input flags
    writeStdout("{s}ignbrk {s}brkint {s}ignpar {s}parmrk {s}inpck {s}istrip\n", .{
        flagPrefix(tio.c_iflag, IGNBRK),
        flagPrefix(tio.c_iflag, BRKINT),
        flagPrefix(tio.c_iflag, IGNPAR),
        flagPrefix(tio.c_iflag, PARMRK),
        flagPrefix(tio.c_iflag, INPCK),
        flagPrefix(tio.c_iflag, ISTRIP),
    });
    writeStdout("{s}inlcr {s}igncr {s}icrnl {s}ixon {s}ixoff {s}iutf8\n", .{
        flagPrefix(tio.c_iflag, INLCR),
        flagPrefix(tio.c_iflag, IGNCR),
        flagPrefix(tio.c_iflag, ICRNL),
        flagPrefix(tio.c_iflag, IXON),
        flagPrefix(tio.c_iflag, IXOFF),
        flagPrefix(tio.c_iflag, IUTF8),
    });

    // Output flags
    writeStdout("{s}opost {s}onlcr {s}ocrnl {s}onocr {s}onlret\n", .{
        flagPrefix(tio.c_oflag, OPOST),
        flagPrefix(tio.c_oflag, ONLCR),
        flagPrefix(tio.c_oflag, OCRNL),
        flagPrefix(tio.c_oflag, ONOCR),
        flagPrefix(tio.c_oflag, ONLRET),
    });

    // Control flags
    const cs = switch (tio.c_cflag & CSIZE) {
        CS5 => "cs5",
        CS6 => "cs6",
        CS7 => "cs7",
        CS8 => "cs8",
        else => "cs?",
    };
    writeStdout("{s} {s}cstopb {s}cread {s}parenb {s}parodd {s}hupcl {s}clocal\n", .{
        cs,
        flagPrefix(tio.c_cflag, CSTOPB),
        flagPrefix(tio.c_cflag, CREAD),
        flagPrefix(tio.c_cflag, PARENB),
        flagPrefix(tio.c_cflag, PARODD),
        flagPrefix(tio.c_cflag, HUPCL),
        flagPrefix(tio.c_cflag, CLOCAL),
    });

    // Local flags
    writeStdout("{s}isig {s}icanon {s}echo {s}echoe {s}echok {s}echonl\n", .{
        flagPrefix(tio.c_lflag, ISIG),
        flagPrefix(tio.c_lflag, ICANON),
        flagPrefix(tio.c_lflag, ECHO),
        flagPrefix(tio.c_lflag, ECHOE),
        flagPrefix(tio.c_lflag, ECHOK),
        flagPrefix(tio.c_lflag, ECHONL),
    });
    writeStdout("{s}noflsh {s}tostop {s}echoctl {s}echoprt {s}echoke {s}iexten\n", .{
        flagPrefix(tio.c_lflag, NOFLSH),
        flagPrefix(tio.c_lflag, TOSTOP),
        flagPrefix(tio.c_lflag, ECHOCTL),
        flagPrefix(tio.c_lflag, ECHOPRT),
        flagPrefix(tio.c_lflag, ECHOKE),
        flagPrefix(tio.c_lflag, IEXTEN),
    });
}

fn printSaveFormat(tio: *const termios) void {
    writeStdout("{x:0>8}:{x:0>8}:{x:0>8}:{x:0>8}:", .{
        tio.c_iflag,
        tio.c_oflag,
        tio.c_cflag,
        tio.c_lflag,
    });
    for (tio.c_cc, 0..) |cc, idx| {
        if (idx > 0) writeStdout(":", .{});
        writeStdout("{x:0>2}", .{cc});
    }
    writeStdout("\n", .{});
}

fn flagPrefix(flags: tcflag_t, flag: tcflag_t) []const u8 {
    return if (flags & flag != 0) "" else "-";
}

fn formatCC(cc: cc_t) []const u8 {
    return switch (cc) {
        0 => "<undef>",
        0x7f => "^?",
        else => if (cc < 32) blk: {
            const chars = "^@^A^B^C^D^E^F^G^H^I^J^K^L^M^N^O^P^Q^R^S^T^U^V^W^X^Y^Z^[^\\^]^^^_";
            break :blk chars[cc * 2 ..][0..2];
        } else "?",
    };
}

fn baudToNum(baud: speed_t) u32 {
    return switch (baud) {
        B0 => 0,
        B50 => 50,
        B75 => 75,
        B110 => 110,
        B134 => 134,
        B150 => 150,
        B200 => 200,
        B300 => 300,
        B600 => 600,
        B1200 => 1200,
        B1800 => 1800,
        B2400 => 2400,
        B4800 => 4800,
        B9600 => 9600,
        B19200 => 19200,
        B38400 => 38400,
        B57600 => 57600,
        B115200 => 115200,
        B230400 => 230400,
        else => 0,
    };
}

fn printHelp() void {
    writeStdout(
        \\Usage: zstty [OPTION]... [SETTING]...
        \\Print or change terminal line settings.
        \\
        \\Options:
        \\  -a, --all       print all current settings in human-readable form
        \\  -g, --save      print all current settings in a stty-readable form
        \\      --help      display this help and exit
        \\      --version   output version information and exit
        \\
        \\Settings:
        \\  Special:
        \\    raw           same as -ignbrk -brkint -parmrk -istrip -inlcr
        \\                  -igncr -icrnl -ixon -opost -echo -icanon -isig cs8
        \\    cooked/sane   set reasonable terminal settings
        \\
        \\  Input settings:
        \\    [-]ignbrk     ignore break characters
        \\    [-]brkint     breaks cause an interrupt signal
        \\    [-]icrnl      translate carriage return to newline
        \\    [-]ixon       enable XON/XOFF flow control
        \\    [-]iutf8      assume input characters are UTF-8 encoded
        \\
        \\  Output settings:
        \\    [-]opost      postprocess output
        \\    [-]onlcr      translate newline to carriage return-newline
        \\
        \\  Local settings:
        \\    [-]echo       echo input characters
        \\    [-]icanon     enable canonical input (line editing)
        \\    [-]isig       enable interrupt, quit, and suspend special chars
        \\
        \\  Control settings:
        \\    cs5/cs6/cs7/cs8  character size
        \\    [-]cread      allow input to be received
        \\    [-]parenb     generate parity bit
        \\
        \\Examples:
        \\  zstty -a              Show all settings
        \\  zstty raw             Set raw mode
        \\  zstty sane            Reset to sane defaults
        \\  zstty -echo           Disable echo
        \\  zstty echo            Enable echo
        \\
    , .{});
}
