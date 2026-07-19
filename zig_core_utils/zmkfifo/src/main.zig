//! zmkfifo - Create named pipes (FIFOs)
//!
//! A Zig implementation of GNU coreutils `mkfifo`:
//!   zmkfifo [OPTION]... NAME...
//!
//! Faithful to mkfifo(1) semantics (anchored against GNU coreutils 9.10):
//!   - default mode is 0666 modified by the process umask (the kernel
//!     applies it — we pass 0666);
//!   - `-m`/`--mode` sets the mode EXACTLY (umask is cleared first),
//!     accepting both octal and chmod-style symbolic modes with a point
//!     of departure of a=rw (0666);
//!   - modes carrying non-permission bits (setuid/setgid/sticky) are
//!     rejected: "mode must specify only file permission bits";
//!   - unknown options are rejected, `--` ends option parsing, options
//!     are honored even after operands (getopt permutation);
//!   - `-Z`/`--context` are accepted as no-ops (matches GNU on kernels
//!     without SELinux/SMACK; `--context=CTX` prints GNU's warning);
//!   - every failed create reports strerror(errno) and exit status 1,
//!     but remaining operands are still attempted.

const std = @import("std");

const VERSION = "2.0.0";

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn umask(mask: c_uint) c_uint;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

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
        writeFull(fd, "zmkfifo: (diagnostic too long to display)\n");
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
    writeStderr("Try 'zmkfifo --help' for more information.\n", .{});
    std.process.exit(1);
}

fn printUsage() void {
    const usage =
        \\Usage: zmkfifo [OPTION]... NAME...
        \\Create named pipes (FIFOs) with the given NAMEs.
        \\
        \\Mandatory arguments to long options are mandatory for short options too.
        \\  -m, --mode=MODE    set file permission bits to MODE, not a=rw - umask;
        \\                     MODE is octal or symbolic as in chmod(1)
        \\  -Z                 accepted for GNU compatibility (SELinux; ignored)
        \\      --context[=CTX]  likewise ignored on this platform
        \\      --help         display this help and exit
        \\      --version      output version information and exit
        \\
    ;
    writeStdout(usage, .{});
}

fn printVersion() void {
    writeStdout("zmkfifo {s}\n", .{VERSION});
}

// ---------------------------------------------------------------------------
// Mode parsing (GNU gnulib mode_compile/mode_adjust semantics, restricted to
// what mkfifo needs: point of departure 0666, non-directory, no existing mode)
// ---------------------------------------------------------------------------

const ModeError = error{InvalidMode};

const all_mode_bits: u32 = 0o7777;
const perm_bits: u32 = 0o777;

/// Parse MODE (octal or symbolic) into a full 12-bit mode, starting from
/// 0o666 for symbolic clauses. `umask_value` masks clauses with no explicit
/// "who" (GNU mode_adjust). The caller checks for non-permission bits.
fn parseMode(s: []const u8, umask_value: u32) ModeError!u32 {
    if (s.len == 0) return error.InvalidMode;

    // Numeric (octal) mode: GNU mode_compile takes the numeric path when the
    // string begins with a digit; any non-octal digit or a value beyond
    // 0o7777 is "invalid mode" (e.g. "999", "7777777777777777777777").
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
    var mode: u32 = 0o666; // mkfifo's point of departure: a=rw
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
                        // X: execute only if some execute bit is already set
                        // (never a directory here).
                        'X' => {
                            if (mode & 0o111 != 0) value |= 0o111;
                        },
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
// FIFO creation
// ---------------------------------------------------------------------------

fn createFifo(name: []const u8, mode: u32) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{name}) catch {
        // Same shape/reason the syscall itself would produce (ENAMETOOLONG).
        writeStderr("zmkfifo: cannot create fifo '{s}': File name too long\n", .{name});
        return false;
    };

    if (mkfifo(path_z, mode) != 0) {
        // Capture errno immediately, before any write() can clobber it.
        const err = std.c._errno().*;
        writeStderr("zmkfifo: cannot create fifo '{s}': {s}\n", .{
            name, std.mem.span(strerror(err)),
        });
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Argument parsing (getopt_long-compatible: permutation, "--", clustering,
// attached "-mMODE", unambiguous long-option abbreviation)
// ---------------------------------------------------------------------------

// Order matches GNU mkfifo's longopts table (drives the "ambiguous" listing).
const long_opts = [_][]const u8{ "context", "mode", "help", "version" };

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

fn ambiguousOptionAndExit(arg: []const u8) noreturn {
    writeStderr(
        "zmkfifo: option '{s}' is ambiguous; possibilities: '--context' '--mode' '--help' '--version'\n",
        .{arg},
    );
    tryHelpAndExit();
}

const context_warning =
    "zmkfifo: warning: ignoring --context; it requires an SELinux/SMACK-enabled kernel\n";

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
                    writeStderr("zmkfifo: unrecognized option '{s}'\n", .{arg});
                    tryHelpAndExit();
                },
                .ambiguous => ambiguousOptionAndExit(arg),
            };

            if (std.mem.eql(u8, canonical, "help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, canonical, "version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, canonical, "mode")) {
                if (attached) |v| {
                    mode_str = v;
                } else if (i + 1 < args.len) {
                    i += 1;
                    mode_str = args[i];
                } else {
                    writeStderr("zmkfifo: option '--mode' requires an argument\n", .{});
                    tryHelpAndExit();
                }
            } else { // context: optional argument, never consumes the next arg
                if (attached != null) writeStderr(context_warning, .{});
                // Silently ignored otherwise (GNU on non-SELinux kernels).
            }
        } else if (!seen_dashdash and arg.len >= 2 and arg[0] == '-') {
            // Short option cluster; lone "-" (len 1) is an operand.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'm' => {
                        if (j + 1 < arg.len) {
                            mode_str = arg[j + 1 ..]; // attached: -m0755
                        } else if (i + 1 < args.len) {
                            i += 1;
                            mode_str = args[i];
                        } else {
                            writeStderr("zmkfifo: option requires an argument -- 'm'\n", .{});
                            tryHelpAndExit();
                        }
                        j = arg.len; // argument consumed the rest
                        break;
                    },
                    'Z' => {}, // ignored (no SELinux/SMACK here), like GNU
                    else => {
                        writeStderr("zmkfifo: invalid option -- '{c}'\n", .{arg[j]});
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
        writeStderr("zmkfifo: missing operand\n", .{});
        tryHelpAndExit();
    }

    const umask_value: u32 = umask(0);
    var mode: u32 = 0o666;
    if (mode_str) |ms| {
        // Leave umask at 0: an explicit mode is set EXACTLY (GNU parity).
        mode = parseMode(ms, umask_value) catch {
            writeStderr("zmkfifo: invalid mode\n", .{});
            std.process.exit(1);
        };
        if (mode & ~perm_bits != 0) {
            writeStderr("zmkfifo: mode must specify only file permission bits\n", .{});
            std.process.exit(1);
        }
    } else {
        // No -m: restore the umask and let the kernel apply it to 0666.
        _ = umask(umask_value);
    }

    var exit_code: u8 = 0;
    for (operands.items) |name| {
        if (!createFifo(name, mode)) exit_code = 1;
    }
    if (exit_code != 0) std.process.exit(exit_code);
}

// ---------------------------------------------------------------------------
// Unit tests for the mode parser. Expected values were captured from GNU
// coreutils 9.10 mkfifo (macOS, LC_ALL=C, 2026-07-19) — see
// gnu_parity_test.zig for the live diff harness against the real binary.
// ---------------------------------------------------------------------------

test "octal modes parse exactly" {
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("777", 0o022));
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("00777", 0o022));
    try std.testing.expectEqual(@as(u32, 0), try parseMode("0", 0o022));
    try std.testing.expectEqual(@as(u32, 0o4755), try parseMode("4755", 0o022));
}

test "invalid octal modes rejected without overflow panic" {
    try std.testing.expectError(error.InvalidMode, parseMode("999", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("777777", 0));
    // Regression: this input used to crash with an integer-overflow panic.
    try std.testing.expectError(error.InvalidMode, parseMode("7777777777777777777777", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("", 0));
    try std.testing.expectError(error.InvalidMode, parseMode("0x1", 0));
}

test "symbolic modes match GNU mkfifo observed results" {
    // GNU: -m a=rw -> 0666; -m +x (umask 022) -> 0777; -m +x (umask 077) -> 0766
    try std.testing.expectEqual(@as(u32, 0o666), try parseMode("a=rw", 0o022));
    try std.testing.expectEqual(@as(u32, 0o777), try parseMode("+x", 0o022));
    try std.testing.expectEqual(@as(u32, 0o766), try parseMode("+x", 0o077));
    // GNU: -m =rwx (umask 077) -> 0700
    try std.testing.expectEqual(@as(u32, 0o700), try parseMode("=rwx", 0o077));
    // GNU: -m u+x,g-r (umask 077) -> 0726
    try std.testing.expectEqual(@as(u32, 0o726), try parseMode("u+x,g-r", 0o077));
    // GNU: -m u= -> 0066; -m g=u -> 0666; -m +X -> 0666; -m u+x+X -> 0766
    try std.testing.expectEqual(@as(u32, 0o066), try parseMode("u=", 0o022));
    try std.testing.expectEqual(@as(u32, 0o666), try parseMode("g=u", 0o022));
    try std.testing.expectEqual(@as(u32, 0o666), try parseMode("+X", 0o022));
    try std.testing.expectEqual(@as(u32, 0o766), try parseMode("u+x+X", 0o022));
}

test "symbolic modes carrying non-permission bits surface those bits" {
    // main() rejects these with "mode must specify only file permission bits"
    try std.testing.expect((try parseMode("o+t", 0o022)) & ~perm_bits != 0);
    try std.testing.expect((try parseMode("u+s", 0o022)) & ~perm_bits != 0);
}

test "malformed symbolic modes rejected" {
    try std.testing.expectError(error.InvalidMode, parseMode("rw", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("a=rw,", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("u", 0o022));
    try std.testing.expectError(error.InvalidMode, parseMode("a=rw,q", 0o022));
}
