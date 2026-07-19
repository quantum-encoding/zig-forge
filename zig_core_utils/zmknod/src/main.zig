//! zmknod - Create special files
//!
//! Create block/character special files and FIFOs.
//!
//! Behavior (diagnostics, exit codes, mode semantics, device-number
//! parsing) is anchored against GNU coreutils 9.10 `mknod` — see
//! src/gnu_parity_test.zig, which diffs this binary live against the
//! real GNU binary.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

const is_darwin = builtin.os.tag.isDarwin();

/// Darwin dev_t is i32; Linux glibc mknod takes a 64-bit dev_t.
const DevT = if (is_darwin) i32 else u64;

extern "c" fn mknod(path: [*:0]const u8, mode: c_uint, dev: DevT) c_int;
extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn umask(mask: c_uint) c_uint;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

// File type bits (identical values on Darwin and Linux)
const S_IFBLK: c_uint = 0o060000; // Block special
const S_IFCHR: c_uint = 0o020000; // Character special

const NodeType = enum { block, char, fifo };

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn tryHelp() void {
    writeStderr("Try 'zmknod --help' for more information.\n");
}

fn printUsage() void {
    const usage =
        \\Usage: zmknod [OPTION]... NAME TYPE [MAJOR MINOR]
        \\Create the special file NAME of the given TYPE.
        \\
        \\TYPE is one of:
        \\  b      Create a block special file
        \\  c, u   Create a character special file
        \\  p      Create a FIFO (named pipe)
        \\
        \\MAJOR and MINOR are required for block and character devices
        \\(and must not be given for FIFOs).
        \\
        \\Options:
        \\  -m, --mode=MODE   Set file permission bits to MODE (as in chmod),
        \\                    not a=rw - umask; octal or symbolic
        \\      --help        Display this help and exit
        \\      --version     Output version information and exit
        \\
        \\Examples:
        \\  zmknod myfifo p              Create a named pipe
        \\  zmknod /dev/null c 1 3       Create character device (requires root)
        \\  zmknod -m 600 mydev b 8 0    Create block device with mode 600
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zmknod " ++ VERSION ++ "\n");
}

/// Parse a MODE argument the way GNU/gnulib mode_compile + mode_adjust do
/// for mknod: octal (<= 0o7777) applied exactly, or symbolic clauses
/// applied to `base` (0666 for mknod) with `umask_val` limiting clauses
/// that name no who. Returns null on any syntax error (GNU: "invalid mode").
///
/// Semantics verified against GNU coreutils 9.10 mknod (macOS, LC_ALL=C,
/// 2026-07-19); see the unit tests below for the observed vectors.
fn parseMode(s: []const u8, base: c_uint, umask_val: c_uint) ?c_uint {
    if (s.len == 0) return null;

    if (s[0] >= '0' and s[0] <= '9') {
        // Octal: every char must be 0-7, value must fit in 12 bits.
        var v: c_uint = 0;
        for (s) |c| {
            if (c < '0' or c > '7') return null;
            v = v * 8 + (c - '0');
            if (v > 0o7777) return null;
        }
        return v;
    }

    // Symbolic: comma-separated clauses of [ugoa]*([+-=](perms|copy))+
    var mode = base;
    var i: usize = 0;
    while (true) {
        var who: c_uint = 0;
        var saw_who = false;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= 0o7777,
                else => break,
            }
            saw_who = true;
        }

        if (i >= s.len or (s[i] != '+' and s[i] != '-' and s[i] != '=')) return null;

        while (i < s.len and (s[i] == '+' or s[i] == '-' or s[i] == '=')) {
            const op = s[i];
            i += 1;
            var value: c_uint = 0;
            if (i < s.len and (s[i] == 'u' or s[i] == 'g' or s[i] == 'o') and
                (i + 1 >= s.len or s[i + 1] == ',' or s[i + 1] == '+' or
                    s[i + 1] == '-' or s[i + 1] == '='))
            {
                // Copy permissions from another class (e.g. "o=g").
                const bits: c_uint = switch (s[i]) {
                    'u' => (mode >> 6) & 7,
                    'g' => (mode >> 3) & 7,
                    else => mode & 7,
                };
                value = bits * 0o111;
                i += 1;
            } else {
                while (i < s.len) : (i += 1) {
                    switch (s[i]) {
                        'r' => value |= 0o444,
                        'w' => value |= 0o222,
                        'x' => value |= 0o111,
                        // X: execute only if some x bit is already set
                        'X' => {
                            if (mode & 0o111 != 0) value |= 0o111;
                        },
                        's' => value |= 0o6000,
                        't' => value |= 0o1000,
                        else => break,
                    }
                }
            }

            // Clauses without an explicit who are limited by the umask.
            const set_mask: c_uint = if (saw_who) who else (0o7777 & ~umask_val);
            const clear_mask: c_uint = if (saw_who) who else 0o7777;
            switch (op) {
                '+' => mode |= value & set_mask,
                '-' => mode &= ~(value & set_mask),
                '=' => mode = (mode & ~clear_mask) | (value & set_mask),
                else => unreachable,
            }
        }

        if (i >= s.len) return mode;
        if (s[i] != ',') return null;
        i += 1;
        if (i >= s.len) return null; // trailing comma
    }
}

/// Parse a MAJOR/MINOR operand like GNU's xstrtoumax(s, NULL, 0, ...):
/// 0x/0X prefix = hex, leading 0 = octal, else decimal; must fit in u32.
/// Returns null on empty string, bad digit, or overflow.
fn parseDeviceNum(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    // Zig's parser accepts '_' digit separators; C's strtoumax does not.
    for (s) |c| {
        if (c == '_') return null;
    }
    var body = s;
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16;
        body = s[2..];
        if (body.len == 0) return null;
    } else if (s[0] == '0') {
        base = 8;
    }
    return std.fmt.parseUnsigned(u32, body, base) catch null;
}

pub fn main(init: std.process.Init) void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var mode_str: ?[]const u8 = null;
    var positionals: [5][]const u8 = undefined;
    var npos: usize = 0;
    var after_dashdash = false;

    while (args_iter.next()) |arg| {
        if (!after_dashdash and arg.len >= 2 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                after_dashdash = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, arg, "-m")) {
                mode_str = args_iter.next() orelse {
                    writeStderr("zmknod: option requires an argument -- 'm'\n");
                    tryHelp();
                    std.process.exit(1);
                };
            } else if (std.mem.startsWith(u8, arg, "-m")) {
                // Attached form: -m600, -mu+rw
                mode_str = arg[2..];
            } else if (std.mem.eql(u8, arg, "--mode")) {
                mode_str = args_iter.next() orelse {
                    writeStderr("zmknod: option '--mode' requires an argument\n");
                    tryHelp();
                    std.process.exit(1);
                };
            } else if (std.mem.startsWith(u8, arg, "--mode=")) {
                mode_str = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--")) {
                writeStderr("zmknod: unrecognized option '");
                writeStderr(arg);
                writeStderr("'\n");
                tryHelp();
                std.process.exit(1);
            } else {
                writeStderr("zmknod: invalid option -- '");
                writeStderr(arg[1..2]);
                writeStderr("'\n");
                tryHelp();
                std.process.exit(1);
            }
        } else {
            // "-" alone, "" and everything after "--" are operands.
            if (npos < positionals.len) positionals[npos] = arg;
            npos += 1;
        }
    }

    // Mode is validated before operand-count checks, matching GNU
    // (`mknod -m bogus` with no operands prints "invalid mode").
    var newmode: c_uint = 0o666;
    if (mode_str) |ms| {
        // GNU zeroes the umask when -m is given so the exact mode is
        // applied; the old umask still limits who-less symbolic clauses.
        const old_umask = umask(0);
        newmode = parseMode(ms, 0o666, old_umask) orelse {
            writeStderr("zmknod: invalid mode\n");
            std.process.exit(1);
        };
        if ((newmode & ~@as(c_uint, 0o777)) != 0) {
            writeStderr("zmknod: mode must specify only file permission bits\n");
            std.process.exit(1);
        }
    }

    // Operand-count validation, GNU-style: FIFOs take 2 operands,
    // devices take 4. The expected count is decided by the first char
    // of the TYPE operand ('p' = FIFO).
    const expected: usize =
        if (npos <= 1 or (positionals[1].len > 0 and positionals[1][0] == 'p')) 2 else 4;

    if (npos < expected) {
        if (npos == 0) {
            writeStderr("zmknod: missing operand\n");
        } else {
            writeStderr("zmknod: missing operand after '");
            writeStderr(positionals[npos - 1]);
            writeStderr("'\n");
        }
        if (expected == 4 and npos == 2)
            writeStderr("Special files require major and minor device numbers.\n");
        tryHelp();
        std.process.exit(1);
    }
    if (npos > expected) {
        writeStderr("zmknod: extra operand '");
        writeStderr(positionals[expected]);
        writeStderr("'\n");
        if (expected == 2 and npos == 4)
            writeStderr("Fifos do not have major and minor device numbers.\n");
        tryHelp();
        std.process.exit(1);
    }

    const name = positionals[0];
    const type_str = positionals[1];

    // Like GNU, only the first character of TYPE is examined.
    const node_type: NodeType = blk: {
        if (type_str.len > 0) switch (type_str[0]) {
            'b' => break :blk .block,
            'c', 'u' => break :blk .char,
            'p' => break :blk .fifo,
            else => {},
        };
        writeStderr("zmknod: invalid device type '");
        writeStderr(type_str);
        writeStderr("'\n");
        tryHelp();
        std.process.exit(1);
    };

    var dev: DevT = 0;
    if (node_type != .fifo) {
        const major = parseDeviceNum(positionals[2]) orelse {
            writeStderr("zmknod: invalid major device number '");
            writeStderr(positionals[2]);
            writeStderr("'\n");
            std.process.exit(1);
        };
        const minor = parseDeviceNum(positionals[3]) orelse {
            writeStderr("zmknod: invalid minor device number '");
            writeStderr(positionals[3]);
            writeStderr("'\n");
            std.process.exit(1);
        };
        if (is_darwin) {
            // Darwin makedev: (major << 24) | minor, as a 32-bit dev_t.
            const dev_u: u32 = @as(u32, @truncate(@as(u64, major) << 24)) | minor;
            if (dev_u == 0xFFFF_FFFF) {
                // NODEV — GNU: "invalid device MAJOR MINOR" (unquoted)
                writeStderr("zmknod: invalid device ");
                writeStderr(positionals[2]);
                writeStderr(" ");
                writeStderr(positionals[3]);
                writeStderr("\n");
                std.process.exit(1);
            }
            dev = @bitCast(dev_u);
        } else {
            // Linux (glibc) makedev bit layout.
            dev = (@as(u64, major & 0xfff) << 8) |
                (@as(u64, major & 0xfffff000) << 32) |
                @as(u64, minor & 0xff) |
                (@as(u64, minor & 0xffffff00) << 12);
        }
    }

    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{name}) catch {
        // Same shape as the syscall failing with ENAMETOOLONG.
        writeStderr("zmknod: ");
        writeStderr(name);
        writeStderr(": File name too long\n");
        std.process.exit(1);
    };

    // No -m: the process umask applies naturally in the syscall.
    // With -m: umask was already zeroed above, so newmode is exact.
    const result: c_int = switch (node_type) {
        .fifo => mkfifo(path_z, newmode),
        .block => mknod(path_z, S_IFBLK | newmode, dev),
        .char => mknod(path_z, S_IFCHR | newmode, dev),
    };

    if (result != 0) {
        const errno = std.c._errno().*;
        writeStderr("zmknod: ");
        writeStderr(name);
        writeStderr(": ");
        writeStderr(std.mem.span(strerror(errno)));
        writeStderr("\n");
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Unit tests. Every expected value below was captured from GNU coreutils
// 9.10 `mknod` (Homebrew gnubin, macOS, LC_ALL=C, 2026-07-19) by creating
// FIFOs with the given -m argument under the given umask and reading the
// resulting permission bits — NOT derived from this implementation.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseMode octal: exact, umask ignored (gmknod -m 600 under umask 022 -> 600)" {
    try testing.expectEqual(@as(?c_uint, 0o600), parseMode("600", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, 0o644), parseMode("00644", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, 0), parseMode("0", 0o666, 0o022));
    // gmknod accepts setuid octal in mode_compile; main() then rejects it
    // with "mode must specify only file permission bits".
    try testing.expectEqual(@as(?c_uint, 0o4755), parseMode("4755", 0o666, 0o022));
}

test "parseMode octal: invalid (gmknod: 'invalid mode', exit 1)" {
    try testing.expectEqual(@as(?c_uint, null), parseMode("999", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("010644", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("7777777777777777777777", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("bogus", 0o666, 0o022));
}

test "parseMode symbolic: observed gmknod results (base 666)" {
    // gmknod -m a=rw   -> prw-rw-rw- (666)
    try testing.expectEqual(@as(?c_uint, 0o666), parseMode("a=rw", 0o666, 0o022));
    // gmknod -m u=r    -> pr--rw-rw- (466)
    try testing.expectEqual(@as(?c_uint, 0o466), parseMode("u=r", 0o666, 0o022));
    // gmknod -m go-w   -> prw-r--r-- (644)
    try testing.expectEqual(@as(?c_uint, 0o644), parseMode("go-w", 0o666, 0o022));
    // gmknod -m a+x    -> prwxrwxrwx (777)
    try testing.expectEqual(@as(?c_uint, 0o777), parseMode("a+x", 0o666, 0o022));
    // gmknod -m u+x    -> prwxrw-rw- (766)
    try testing.expectEqual(@as(?c_uint, 0o766), parseMode("u+x", 0o666, 0o022));
    // gmknod -m o=g    -> prw-rw-rw- (666) — copy group to other
    try testing.expectEqual(@as(?c_uint, 0o666), parseMode("o=g", 0o666, 0o022));
    // gmknod -m u+X    -> prw-rw-rw- (666) — X is a no-op without any x bit
    try testing.expectEqual(@as(?c_uint, 0o666), parseMode("u+X", 0o666, 0o022));
    // gmknod -m u=rw,go= -> prw------- (600)
    try testing.expectEqual(@as(?c_uint, 0o600), parseMode("u=rw,go=", 0o666, 0o022));
    // gmknod -m u=     -> p---rw-rw- (066)
    try testing.expectEqual(@as(?c_uint, 0o066), parseMode("u=", 0o666, 0o022));
    // gmknod -m u=rwx,g=rx,o= -> prwxr-x--- (750)
    try testing.expectEqual(@as(?c_uint, 0o750), parseMode("u=rwx,g=rx,o=", 0o666, 0o022));
    // gmknod -m ug=rw  -> prw-rw-rw- (666)
    try testing.expectEqual(@as(?c_uint, 0o666), parseMode("ug=rw", 0o666, 0o022));
}

test "parseMode symbolic: who-less clauses limited by umask" {
    // umask 022: gmknod -m =r  -> pr--r--r-- (444)
    try testing.expectEqual(@as(?c_uint, 0o444), parseMode("=r", 0o666, 0o022));
    // umask 022: gmknod -m +x  -> prwxrwxrwx (777) — x not in umask
    try testing.expectEqual(@as(?c_uint, 0o777), parseMode("+x", 0o666, 0o022));
    // umask 027: gmknod -m =rx -> pr-xr-x--- (550)
    try testing.expectEqual(@as(?c_uint, 0o550), parseMode("=rx", 0o666, 0o027));
    // umask 022: gmknod -m -w  -> pr--rw-rw- (466) — only u's w removed,
    // g/o w bits are inside the umask so the clause does not touch them
    try testing.expectEqual(@as(?c_uint, 0o466), parseMode("-w", 0o666, 0o022));
}

test "parseMode symbolic: s/t bits parse but land outside 0777 (main rejects)" {
    // gmknod -m u+s -> "mode must specify only file permission bits"
    try testing.expectEqual(@as(?c_uint, 0o4666), parseMode("u+s", 0o666, 0o022));
    // gmknod -m +t  -> same rejection (umask 022 leaves the t bit set)
    try testing.expectEqual(@as(?c_uint, 0o1666), parseMode("+t", 0o666, 0o022));
}

test "parseMode symbolic: syntax errors (gmknod: 'invalid mode')" {
    try testing.expectEqual(@as(?c_uint, null), parseMode("w+r", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("u=rw,", 0o666, 0o022));
    try testing.expectEqual(@as(?c_uint, null), parseMode("u", 0o666, 0o022));
}

test "parseDeviceNum: strtoumax base-0 semantics (verified against gmknod)" {
    // decimal / octal / hex, as accepted by gmknod's major/minor parsing
    try testing.expectEqual(@as(?u32, 10), parseDeviceNum("10"));
    try testing.expectEqual(@as(?u32, 8), parseDeviceNum("010"));
    try testing.expectEqual(@as(?u32, 16), parseDeviceNum("0x10"));
    try testing.expectEqual(@as(?u32, 0), parseDeviceNum("0"));
    // gmknod accepts major 4294967295 and rejects 4294967296
    try testing.expectEqual(@as(?u32, 0xFFFF_FFFF), parseDeviceNum("4294967295"));
    try testing.expectEqual(@as(?u32, null), parseDeviceNum("4294967296"));
    // gmknod: invalid major device number '99999999999999999999' (no panic)
    try testing.expectEqual(@as(?u32, null), parseDeviceNum("99999999999999999999"));
    try testing.expectEqual(@as(?u32, null), parseDeviceNum("abc"));
    // gmknod: invalid major device number '1_0'
    try testing.expectEqual(@as(?u32, null), parseDeviceNum("1_0"));
    try testing.expectEqual(@as(?u32, null), parseDeviceNum(""));
    try testing.expectEqual(@as(?u32, null), parseDeviceNum("0x"));
}
