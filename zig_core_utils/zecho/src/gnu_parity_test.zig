//! Externally-anchored parity tests for zecho.
//!
//! ANCHOR: every expectation is diffed byte-for-byte against the real GNU
//! coreutils `echo` binary (coreutils 9.10) discovered on this machine. The
//! expected output is NOT written by us — it is whatever the reference binary
//! emits for the same argv. This is a true external anchor per zig-forge
//! CLAUDE.md golden rule (not a roundtrip, not a self-hash).
//!
//! Each case runs `zecho <argv>` and `gecho <argv>` as child processes and
//! asserts their stdout is byte-identical. If no GNU echo binary is present
//! the test errors (we refuse to silently pass with no anchor).
//!
//! The `zecho` path and the GNU binary path are injected by build.zig via
//! the generated `build_options` module.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/echo",
    "/opt/homebrew/bin/gecho",
    "/usr/local/opt/coreutils/libexec/gnubin/echo",
    "/usr/local/bin/gecho",
};

fn findGnu() ?[]const u8 {
    if (build_options.gnu_path.len > 0) {
        if (fileExists(build_options.gnu_path)) return build_options.gnu_path;
    }
    for (gnu_candidates) |c| {
        if (fileExists(c)) return c;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    // The global single-threaded Io uses a failing allocator; syscalls that
    // allocate need a real one, so stand up a Threaded backed by the test alloc.
    var t = Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    Io.Dir.cwd().access(t.io(), path, .{}) catch return false;
    return true;
}

fn runCapture(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var t = Io.Threaded.init(allocator, .{});
    defer t.deinit();
    const io = t.io();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    for (args) |a| try argv.append(allocator, a);

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    allocator.free(result.stderr);
    return result.stdout;
}

/// Run the same argv through both binaries and assert byte-identical stdout.
fn expectParity(args: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse {
        std.debug.print("no GNU echo binary found; cannot anchor\n", .{});
        return error.NoGnuReference;
    };

    const zout = try runCapture(allocator, build_options.zecho_path, args);
    defer allocator.free(zout);
    const gout = try runCapture(allocator, gnu, args);
    defer allocator.free(gout);

    if (!std.mem.eql(u8, zout, gout)) {
        std.debug.print("PARITY MISMATCH for argv {any}\n  zecho: {any}\n  gnu:   {any}\n", .{ args, zout, gout });
        return error.ParityMismatch;
    }
}

test "octal escape value > 0377 wraps to low byte (no overflow panic)" {
    // GNU: \0400 -> 0x00, \0777 -> 0xFF (regression: used to panic on u8 overflow)
    try expectParity(&.{ "-e", "\\0400" });
    try expectParity(&.{ "-e", "\\0777" });
    try expectParity(&.{ "-e", "\\0500" });
}

test "backslash-c stops all output and suppresses trailing newline" {
    try expectParity(&.{ "-e", "a\\cb", "more", "args" });
    try expectParity(&.{ "-e", "hello\\c" });
    try expectParity(&.{ "-e", "x", "\\cy", "z" });
    try expectParity(&.{ "-e", "pre\\cpost" });
}

test "hex escape accepts 1 or 2 digits" {
    try expectParity(&.{ "-e", "\\x4" });
    try expectParity(&.{ "-e", "\\x41\\x42" });
    try expectParity(&.{ "-e", "\\x41ZZ" });
    try expectParity(&.{ "-e", "q\\x" }); // no hex digits -> literal
    try expectParity(&.{ "-e", "\\xGG" }); // invalid -> literal
}

test "octal escape without leading zero (backslash-NNN)" {
    try expectParity(&.{ "-e", "\\101" }); // -> A
    try expectParity(&.{ "-e", "\\7" }); // -> BEL
    try expectParity(&.{ "-e", "\\41" }); // -> !
    try expectParity(&.{ "-e", "\\1011" }); // -> A then literal 1
    try expectParity(&.{ "-e", "\\0" }); // -> NUL
    try expectParity(&.{ "-e", "\\0101" }); // -> A
}

test "named escape sequences" {
    try expectParity(&.{ "-e", "\\a\\b\\f\\v" });
    try expectParity(&.{ "-e", "a\\tb\\nc\\rd" });
    try expectParity(&.{ "-e", "\\e" });
    try expectParity(&.{ "-e", "\\\\" });
    try expectParity(&.{ "-e", "\\z" }); // unknown -> literal
    try expectParity(&.{ "-e", "abc\\" }); // trailing backslash -> literal
}

test "flag parsing: -n, -e, -E and combinations" {
    try expectParity(&.{ "-n", "hi" });
    try expectParity(&.{ "-neE", "\\t" }); // last E wins -> literal, no newline
    try expectParity(&.{ "-en", "\\ta" });
    try expectParity(&.{"-E"});
}

test "escapes are NOT interpreted without -e (default)" {
    try expectParity(&.{"\\t"});
    try expectParity(&.{ "hello", "\\n", "world" });
}

test "non-option and passthrough arguments" {
    try expectParity(&.{ "-x", "foo" }); // unknown flag -> literal
    try expectParity(&.{ "--", "foo" }); // echo has no -- handling
    try expectParity(&.{}); // empty -> just newline
    try expectParity(&.{ "hello", "world" });
}

test "long-option handling matches GNU (single-operand guard)" {
    // --version with a trailing operand is NOT honored (argc != 2) -> literal.
    try expectParity(&.{ "--version", "foo" });
    // --help as a non-first operand is literal.
    try expectParity(&.{ "-n", "--help" });
}
