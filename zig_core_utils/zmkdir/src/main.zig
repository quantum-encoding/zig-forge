//! zmkdir - Create directories
//!
//! A Zig implementation of GNU coreutils `mkdir`:
//!   zmkdir [OPTION]... DIRECTORY...
//!
//! Faithful to mkdir(1) semantics (anchored against GNU coreutils 9.10):
//!   - default mode is 0777 modified by the process umask;
//!   - `-m`/`--mode` sets the final directory's mode EXACTLY (never
//!     narrowed by the umask), accepting both octal and chmod-style
//!     symbolic modes with a point of departure of a=rwx (0777);
//!     setuid/setgid/sticky bits are allowed and applied via chmod;
//!   - `-p`/`--parents`: no error if the directory exists (and IS a
//!     directory), ancestors are created left-to-right with mode
//!     (0777 & ~umask) | u+wx so they are traversable even under a
//!     restrictive umask; a concurrent creator winning the race is
//!     benign (EEXIST-on-a-directory is tolerated, never an error);
//!   - `-v`/`--verbose` prints "created directory 'X'" per created dir;
//!   - unknown options are rejected, `--` ends option parsing, options
//!     are honored even after operands (getopt permutation), long
//!     options may be abbreviated when unambiguous;
//!   - `-Z`/`--context` are accepted as no-ops (matches GNU on kernels
//!     without SELinux/SMACK; `--context=CTX` prints GNU's warning);
//!   - every failed create reports strerror(errno) and exit status 1,
//!     but remaining operands are still attempted.

const std = @import("std");

const VERSION = "2.0.0";

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn umask(mask: c_uint) c_uint;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

/// Write the whole slice, retrying on partial writes and EINTR.
fn writeFull(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return; // nothing more we can do about a failing stdout/stderr
        }
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

fn writeFmt(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096 + 512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        writeFull(fd, "zmkdir: (diagnostic too long to display)\n");
        return;
    };
    writeFull(fd, msg);
}

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    writeFmt(2, fmt, args);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    writeFmt(1, fmt, args);
}

fn tryHelpAndExit() noreturn {
    writeStderr("Try 'zmkdir --help' for more information.\n", .{});
    std.process.exit(1);
}

fn printUsage() void {
    const usage =
        \\Usage: zmkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\Mandatory arguments to long options are mandatory for short options too.
        \\  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask
        \\  -p, --parents     no error if existing, make parent directories as needed,
        \\                    with their file modes unaffected by any -m option
        \\  -v, --verbose     print a message for each created directory
        \\  -Z                accepted for GNU compatibility (SELinux; ignored)
        \\      --context[=CTX]  likewise ignored on this platform
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
    ;
    writeStdout(usage, .{});
}

fn printVersion() void {
    writeStdout("zmkdir {s}\n", .{VERSION});
}

// ---------------------------------------------------------------------------
// Mode parsing (GNU gnulib mode_compile/mode_adjust semantics, restricted to
// what mkdir needs: point of departure 0777, target IS a directory)
// ---------------------------------------------------------------------------

const ModeError = error{InvalidMode};

const all_mode_bits: u32 = 0o7777;

/// Parse MODE (octal or symbolic) into a full 12-bit mode, starting from
/// 0o777 (a=rwx) for symbolic clauses. `umask_value` masks clauses with no
/// explicit "who" (GNU mode_adjust). Because the target is a directory,
/// 'X' always grants execute. Special bits (setuid/setgid/sticky) are
/// legal for mkdir and kept.
fn parseMode(s: []const u8, umask_value: u32) ModeError!u32 {
    if (s.len == 0) return error.InvalidMode;

    // Numeric (octal) mode: GNU mode_compile takes the numeric path when the
    // string begins with a digit; any non-octal digit or a value beyond
    // 0o7777 is "invalid mode" (e.g. "999", "77777777777777"). The early
    // bound check also prevents the u32-overflow panic the old parser had.
    if (s[0] >= '0' and s[0] <= '9') {
        var v: u32 = 0;
        for (s) |c| {
            if (c < '0' or c > '7') return error.InvalidMode;
            v = v * 8 + (c - '0'); // cannot overflow: v is capped below
            if (v > all_mode_bits) return error.InvalidMode;
        }
        return v;
    }

    // Symbolic mode: comma-separated clauses of [ugoa]*([+-=]([ugo]|[rwxXst]*))+
    var mode: u32 = 0o777; // mkdir's point of departure: a=rwx
    var i: usize = 0;
    while (true) {
        // Parse the "who" letters for this clause.
        var who: u32 = 0;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= all_mode_bits,
                else => break,
            }
        }
        const explicit_who = who != 0;

        // At least one op ('+', '-', '=') must follow.
        if (i >= s.len or (s[i] != '+' and s[i] != '-' and s[i] != '=')) {
            return error.InvalidMode;
        }
        while (i < s.len and (s[i] == '+' or s[i] == '-' or s[i] == '=')) {
            const op = s[i];
            i += 1;

            var value: u32 = 0;
            // Copy form: exactly one of [ugo] followed by clause end/next op.
            if (i < s.len and (s[i] == 'u' or s[i] == 'g' or s[i] == 'o') and
                (i + 1 == s.len or s[i + 1] == ',' or s[i + 1] == '+' or
                    s[i + 1] == '-' or s[i + 1] == '='))
            {
                const triad: u32 = switch (s[i]) {
                    'u' => (mode >> 6) & 7,
                    'g' => (mode >> 3) & 7,
                    else => mode & 7,
                };
                value = triad << 6 | triad << 3 | triad;
                i += 1;
            } else {
                while (i < s.len) : (i += 1) {
                    switch (s[i]) {
                        'r' => value |= 0o444,
                        'w' => value |= 0o222,
                        'x' => value |= 0o111,
                        // X: the target of mkdir is always a directory, so
                        // conditional execute always applies (GNU mode_adjust
                        // with dir=true).
                        'X' => value |= 0o111,
                        's' => value |= 0o6000,
                        't' => value |= 0o1000,
                        else => break,
                    }
                }
            }

            const affected: u32 = if (explicit_who) who else all_mode_bits;
            value &= affected;
            if (!explicit_who) value &= ~umask_value;

            switch (op) {
                '+' => mode |= value,
                '-' => mode &= ~value,
                '=' => mode = (mode & ~affected) | value,
                else => unreachable,
            }
        }

        if (i == s.len) break;
        if (s[i] != ',') return error.InvalidMode;
        i += 1;
        if (i == s.len) return error.InvalidMode; // trailing comma
    }
    return mode;
}

// ---------------------------------------------------------------------------
// Directory creation
// ---------------------------------------------------------------------------

/// mkdir(2) on `path`; returns 0 on success or the captured errno.
fn mkdirOne(path: []const u8, mode: u32) c_int {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch
        return @intFromEnum(std.c.E.NAMETOOLONG);
    if (mkdir(path_z, @intCast(mode & 0o777)) != 0) {
        // Capture errno immediately, before any write() can clobber it.
        return std.c._errno().*;
    }
    return 0;
}

/// Does `path` resolve (following symlinks, like GNU's stat-based check
/// in make_dir_parents) to a directory?
fn isDirectory(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    var st: std.c.Stat = undefined;
    if (stat(path_z, &st) != 0) return false;
    return st.mode & std.c.S.IFMT == std.c.S.IFDIR;
}

fn cannotCreate(path: []const u8, err: c_int) void {
    writeStderr("zmkdir: cannot create directory '{s}': {s}\n", .{
        path, std.mem.span(strerror(err)),
    });
}

/// Create one operand. `final_mode` is the full 12-bit mode for the target
/// itself; `inter_mode` the permission bits for `-p` ancestors. The process
/// umask is 0 while this runs, so modes are applied exactly.
fn makeDir(path: []const u8, final_mode: u32, inter_mode: u32, parents: bool, verbose: bool) bool {
    if (parents) {
        // Trailing slashes belong to the final component, not an ancestor.
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;

        var i: usize = 1;
        while (i < end) : (i += 1) {
            if (path[i] != '/' or path[i - 1] == '/') continue;
            const prefix = path[0..i];
            const err = mkdirOne(prefix, inter_mode);
            if (err == 0) {
                if (verbose) writeStdout("zmkdir: created directory '{s}'\n", .{prefix});
            } else if (err == @intFromEnum(std.c.E.EXIST)) {
                if (!isDirectory(prefix)) {
                    // GNU names the offending ancestor with ENOTDIR text.
                    cannotCreate(prefix, @intFromEnum(std.c.E.NOTDIR));
                    return false;
                }
            } else {
                cannotCreate(prefix, err);
                return false;
            }
        }
    }

    const err = mkdirOne(path, final_mode);
    if (err != 0) {
        // -p tolerates an existing directory — including one that appeared
        // between our mkdirs (concurrent `mkdir -p` race is benign, as in GNU).
        if (parents and err == @intFromEnum(std.c.E.EXIST) and isDirectory(path)) {
            return true;
        }
        cannotCreate(path, err);
        return false;
    }

    // -m modes beyond the 0o777 the kernel accepts (setuid/setgid/sticky)
    // are applied exactly, GNU-style, with a follow-up chmod.
    if (final_mode & ~@as(u32, 0o777) != 0) {
        var path_buf: [4096]u8 = undefined;
        if (std.fmt.bufPrintZ(&path_buf, "{s}", .{path})) |path_z| {
            if (chmod(path_z, @intCast(final_mode & all_mode_bits)) != 0) {
                const cerr = std.c._errno().*;
                writeStderr("zmkdir: cannot set permissions '{s}': {s}\n", .{
                    path, std.mem.span(strerror(cerr)),
                });
                return false;
            }
        } else |_| {}
    }

    if (verbose) writeStdout("zmkdir: created directory '{s}'\n", .{path});
    return true;
}

// ---------------------------------------------------------------------------
// Argument parsing (getopt_long-compatible: permutation, "--", clustering,
// attached "-mMODE", unambiguous long-option abbreviation)
// ---------------------------------------------------------------------------

// Order matches GNU mkdir's longopts table (drives the "ambiguous" listing).
const long_opts = [_][]const u8{ "context", "mode", "parents", "verbose", "help", "version" };

fn matchLongOpt(name: []const u8) union(enum) { match: []const u8, none, ambiguous } {
    var found: ?[]const u8 = null;
    var n_found: usize = 0;
    for (long_opts) |cand| {
        if (std.mem.startsWith(u8, cand, name)) {
            if (cand.len == name.len) return .{ .match = cand }; // exact
            found = cand;
            n_found += 1;
        }
    }
    if (n_found == 1) return .{ .match = found.? };
    if (n_found == 0) return .none;
    return .ambiguous;
}

fn ambiguousOptionAndExit(arg: []const u8, name: []const u8) noreturn {
    var buf: [768]u8 = undefined;
    var len: usize = 0;
    if (std.fmt.bufPrint(buf[len..], "zmkdir: option '{s}' is ambiguous; possibilities:", .{arg})) |head| {
        len += head.len;
    } else |_| {}
    for (long_opts) |cand| {
        if (!std.mem.startsWith(u8, cand, name)) continue;
        if (std.fmt.bufPrint(buf[len..], " '--{s}'", .{cand})) |piece| {
            len += piece.len;
        } else |_| break;
    }
    if (len < buf.len) {
        buf[len] = '\n';
        len += 1;
    }
    writeFull(2, buf[0..len]);
    tryHelpAndExit();
}

const context_warning =
    "zmkdir: warning: ignoring --context; it requires an SELinux/SMACK-enabled kernel\n";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var mode_str: ?[]const u8 = null;
    var parents = false;
    var verbose = false;
    var operands: std.ArrayListUnmanaged([]const u8) = .empty;
    defer operands.deinit(allocator);
    var seen_dashdash = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!seen_dashdash and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            if (arg.len == 2) {
                seen_dashdash = true;
                continue;
            }
            // Long option, possibly "--name=value", possibly abbreviated.
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            const canonical = switch (matchLongOpt(name)) {
                .match => |m| m,
                .none => {
                    writeStderr("zmkdir: unrecognized option '{s}'\n", .{arg});
                    tryHelpAndExit();
                },
                .ambiguous => ambiguousOptionAndExit(arg, name),
            };

            if (std.mem.eql(u8, canonical, "mode")) {
                if (attached) |v| {
                    mode_str = v;
                } else if (i + 1 < args.len) {
                    i += 1;
                    mode_str = args[i];
                } else {
                    writeStderr("zmkdir: option '--mode' requires an argument\n", .{});
                    tryHelpAndExit();
                }
            } else if (std.mem.eql(u8, canonical, "context")) {
                // Optional argument, never consumes the next arg. Silently
                // ignored without a value (GNU on non-SELinux kernels).
                if (attached != null) writeStderr(context_warning, .{});
            } else {
                // No-argument long options reject "=value" (getopt_long).
                if (attached != null) {
                    writeStderr("zmkdir: option '--{s}' doesn't allow an argument\n", .{canonical});
                    tryHelpAndExit();
                }
                if (std.mem.eql(u8, canonical, "help")) {
                    printUsage();
                    return;
                } else if (std.mem.eql(u8, canonical, "version")) {
                    printVersion();
                    return;
                } else if (std.mem.eql(u8, canonical, "parents")) {
                    parents = true;
                } else { // verbose
                    verbose = true;
                }
            }
        } else if (!seen_dashdash and arg.len >= 2 and arg[0] == '-') {
            // Short option cluster; lone "-" (len 1) is an operand.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'p' => parents = true,
                    'v' => verbose = true,
                    'Z' => {}, // ignored (no SELinux/SMACK here), like GNU
                    'm' => {
                        if (j + 1 < arg.len) {
                            mode_str = arg[j + 1 ..]; // attached: -m0755
                        } else if (i + 1 < args.len) {
                            i += 1;
                            mode_str = args[i];
                        } else {
                            writeStderr("zmkdir: option requires an argument -- 'm'\n", .{});
                            tryHelpAndExit();
                        }
                        j = arg.len; // argument consumed the rest
                        break;
                    },
                    else => {
                        writeStderr("zmkdir: invalid option -- '{c}'\n", .{arg[j]});
                        tryHelpAndExit();
                    },
                }
            }
        } else {
            // Operand: includes "-", "" and anything after "--".
            try operands.append(allocator, arg);
        }
    }

    // GNU checks for operands before validating the mode string.
    if (operands.items.len == 0) {
        writeStderr("zmkdir: missing operand\n", .{});
        tryHelpAndExit();
    }

    // Clear the umask for the whole run and apply modes explicitly: an
    // explicit -m mode is set EXACTLY, the default mode is 0777 & ~umask,
    // and -p ancestors get (0777 & ~umask) | u+wx so they stay traversable
    // even under a restrictive umask (all three are GNU-parity fixes).
    const umask_value: u32 = umask(0);
    const default_mode: u32 = 0o777 & ~umask_value;
    var final_mode: u32 = default_mode;
    if (mode_str) |ms| {
        final_mode = parseMode(ms, umask_value) catch {
            writeStderr("zmkdir: invalid mode '{s}'\n", .{ms});
            std.process.exit(1);
        };
    }
    const inter_mode: u32 = default_mode | 0o300;

    var exit_code: u8 = 0;
    for (operands.items) |name| {
        if (!makeDir(name, final_mode, inter_mode, parents, verbose)) exit_code = 1;
    }
    if (exit_code != 0) std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Unit tests for the mode parser. Expected values were captured from GNU
// coreutils 9.10 mkdir (macOS, LC_ALL=C, 2026-07-19) by creating real
// directories and reading the resulting permission bits — see
// gnu_parity_test.zig for the live diff harness against the real binary.
// ---------------------------------------------------------------------------

test "octal modes parse exactly" {
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("777", 0o022));
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("00777", 0o022));
    try std.testing.expectEqual(@as(u32, 0), try parseMode("0", 0o022));
    try std.testing.expectEqual(@as(u32, 0o4755), try parseMode("4755", 0o022));
    try std.testing.expectEqual(@as(u32, 0o1777), try parseMode("1777", 0o022));
}

test "invalid octal modes rejected without overflow panic" {
    try std.testing.expectError(error.InvalidMode, parseMode("999", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("777777", 0));
    // Regression: this input used to crash with an integer-overflow panic.
    try std.testing.expectError(error.InvalidMode, parseMode("77777777777777", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("0x1", 0));
}

test "symbolic modes match GNU mkdir observed results" {
    // GNU: -m u=rwx,go=rx -> 0755; -m g=u -> 0777 (start is a=rwx)
    try std.testing.expectEqual(@as(u32, 0o755), try parseMode("u=rwx,go=rx", 0o022));
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("g=u", 0o022));
    // GNU: -m u=,+x umask 022 -> 0177 (no-who clause masked by umask)
    try std.testing.expectEqual(@as(u32, 0o177), try parseMode("u=,+x", 0o022));
    try std.testing.expectEqual(@as(u32, 0o177), try parseMode("u=,+x", 0o077));
    // GNU: -m u=,u+X -> 0177: X always applies, the target is a directory
    try std.testing.expectEqual(@as(u32, 0o177), try parseMode("u=,u+X", 0o022));
    // GNU: -m u+w,go-r umask 022 -> 0733
    try std.testing.expectEqual(@as(u32, 0o733), try parseMode("u+w,go-r", 0o022));
    // GNU: -m +x umask 077 -> 0777 (already rwx everywhere)
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("+x", 0o077));
    // Special bits are legal for mkdir: -m u+s,o+t -> 04777|01000
    try std.testing.expectEqual(@as(u32, 0o5777), try parseMode("u+s,o+t", 0o022));
}

test "malformed symbolic modes rejected" {
    try std.testing.expectError(error.InvalidMode, parseMode("rw", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("a=rw,", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("u", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("a=rw,q", 0o022));
}
