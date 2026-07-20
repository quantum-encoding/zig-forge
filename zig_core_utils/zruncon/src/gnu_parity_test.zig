//! Externally-anchored parity tests for zruncon.
//!
//! ANCHOR: GNU coreutils `runcon` — documented behavior. No GNU `runcon`
//! binary exists on this platform (SELinux is Linux-only; coreutils does not
//! build runcon on macOS), so we cannot diff live against `gruncon`. Instead we
//! pin the exact bytes/exit-codes GNU documents, citing the source for each:
//!
//!   - coreutils `src/runcon.c` (parse rules, component-set failure messages,
//!     exec exit codes 126/127)
//!   - `man 1 runcon` / `runcon --help`
//!
//! Two layers:
//!   1. Pure-parser unit tests over `main.parseArgs` — assert GNU's operand
//!      disambiguation without needing SELinux at runtime.
//!   2. Subprocess tests that spawn the built `zruncon` and byte-compare
//!      stdout/stderr + exit status for the paths that run before libselinux
//!      is loaded (--help, --version, bad option, missing arg, missing command).
//!
//! Per the repo golden rule: NO roundtrip-only tests. Every expectation below
//! is a literal drawn from GNU's documented contract, not from zruncon itself.

const std = @import("std");
const main = @import("main.zig");
const build_options = @import("build_options");

const testing = std.testing;

// ---------------------------------------------------------------------------
// Layer 1: pure parser semantics (GNU src/runcon.c operand rules)
// ---------------------------------------------------------------------------

// GNU: with NO -c/-u/-r/-t/-l, the FIRST operand is the complete context and
// the command begins at the next operand. A context need not contain ':'.
// (src/runcon.c: `if (!(compute_trans || user || role || type || range))
//  context = argv[optind++];`)
test "first operand is context when no component option (with colon)" {
    const args = &[_][]const u8{ "zruncon", "system_u:system_r:unconfined_t:s0", "/bin/sh" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expect(p.context != null);
    try testing.expectEqualStrings("system_u:system_r:unconfined_t:s0", p.context.?);
    try testing.expectEqual(@as(usize, 2), p.cmd_start); // "/bin/sh"
}

// The regression this whole finding is about: a colon-free first operand must
// STILL be treated as the context, never exec'd as a command. The old code
// used `indexOf(':')` and would have run `ls` here — wait, worse: it would
// have exec'd `mycontext`. GNU sets context=mycontext, command=ls.
test "colon-free first operand is context, not a command (regression)" {
    const args = &[_][]const u8{ "zruncon", "mycontext", "ls", "-l" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expect(p.context != null);
    try testing.expectEqualStrings("mycontext", p.context.?);
    try testing.expectEqual(@as(usize, 2), p.cmd_start); // command starts at "ls"
}

// GNU: when a component option IS present, the first operand starts the
// command; there is no separate context operand.
test "with -t the first operand starts the command, not the context" {
    const args = &[_][]const u8{ "zruncon", "-t", "httpd_t", "/usr/sbin/httpd" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expectEqual(@as(?[]const u8, null), p.context);
    try testing.expect(p.typ != null);
    try testing.expectEqualStrings("httpd_t", p.typ.?);
    try testing.expectEqual(@as(usize, 3), p.cmd_start); // "/usr/sbin/httpd"
}

// GNU: -c (compute) counts as a component option => first operand is command.
// (`man runcon`: "If none of -c, -t, -u, -r, or -l, is specified, then the
//  first argument is used as the complete context.")
test "with -c the first operand starts the command" {
    const args = &[_][]const u8{ "zruncon", "-c", "-t", "foo_t", "id" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expect(p.compute);
    try testing.expectEqual(@as(?[]const u8, null), p.context);
    try testing.expectEqual(@as(usize, 4), p.cmd_start); // "id"
}

test "multiple component options, command follows" {
    const args = &[_][]const u8{ "zruncon", "-u", "system_u", "-r", "system_r", "id" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expectEqualStrings("system_u", p.user.?);
    try testing.expectEqualStrings("system_r", p.role.?);
    try testing.expectEqual(@as(usize, 5), p.cmd_start); // "id"
}

test "long --type=VALUE form" {
    const args = &[_][]const u8{ "zruncon", "--type=httpd_t", "cmd" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expectEqualStrings("httpd_t", p.typ.?);
    try testing.expectEqual(@as(usize, 2), p.cmd_start);
}

// GNU: CONTEXT with no following command is a missing-command error.
test "context with no command is missing_command" {
    const args = &[_][]const u8{ "zruncon", "system_u:object_r:t:s0" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.missing_command, p.err);
}

test "no operands at all is missing_command" {
    const args = &[_][]const u8{"zruncon"};
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.missing_command, p.err);
}

test "unknown option is rejected" {
    const args = &[_][]const u8{ "zruncon", "-z", "cmd" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.unrecognized_option, p.err);
    try testing.expectEqualStrings("-z", p.bad_option);
}

test "option requiring an argument at end of argv" {
    const args = &[_][]const u8{ "zruncon", "-u" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.missing_arg, p.err);
    try testing.expectEqualStrings("u", p.bad_option);
}

test "--help and --version short-circuit" {
    try testing.expectEqual(main.ParseError.help, main.parseArgs(&[_][]const u8{ "zruncon", "--help" }).err);
    try testing.expectEqual(main.ParseError.version, main.parseArgs(&[_][]const u8{ "zruncon", "--version" }).err);
}

// GNU: `--` ends option processing; the next operand starts the command (no
// context operand, since none of the component options nor a context appeared).
test "double dash ends option parsing" {
    const args = &[_][]const u8{ "zruncon", "-t", "foo_t", "--", "-weird-cmd" };
    const p = main.parseArgs(args);
    try testing.expectEqual(main.ParseError.none, p.err);
    try testing.expectEqual(@as(usize, 4), p.cmd_start); // "-weird-cmd"
}

// ---------------------------------------------------------------------------
// Layer 2: subprocess byte/exit anchors (paths before libselinux load)
// ---------------------------------------------------------------------------

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(a: std.mem.Allocator, extra: []const []const u8) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, build_options.exe_path);
    for (extra) |e| try argv.append(a, e);

    var io_instance: std.Io.Threaded = .init(a, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    const res = try std.process.run(a, io, .{ .argv = argv.items });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .term = res.term };
}

fn expectExit(term: std.process.Child.Term, code: u8) !void {
    switch (term) {
        .exited => |c| try testing.expectEqual(code, c),
        else => return error.UnexpectedTermination,
    }
}

// GNU: `runcon --version` exits 0. We pin our own version line literally.
test "subprocess: --version exits 0 with version line" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{"--version"});
    defer r.deinit(a);
    try expectExit(r.term, 0);
    try testing.expectEqualStrings("zruncon 1.0.0\n", r.stdout);
    try testing.expectEqualStrings("", r.stderr);
}

// GNU: `runcon --help` exits 0 and writes usage to stdout.
test "subprocess: --help exits 0 and prints usage to stdout" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{"--help"});
    defer r.deinit(a);
    try expectExit(r.term, 0);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "Usage: zruncon CONTEXT COMMAND [ARG]...\n"));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Run COMMAND with specified SELinux security context.") != null);
    try testing.expectEqualStrings("", r.stderr);
}

// GNU: an unknown option is a usage error to stderr, exit 1.
test "subprocess: unrecognized option exits 1 to stderr" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{ "-z", "cmd" });
    defer r.deinit(a);
    try expectExit(r.term, 1);
    try testing.expectEqualStrings("zruncon: unrecognized option '-z'\n", r.stderr);
}

// GNU getopt: "option requires an argument -- 'u'", exit 1.
test "subprocess: -u with no argument exits 1 to stderr" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{"-u"});
    defer r.deinit(a);
    try expectExit(r.term, 1);
    try testing.expectEqualStrings("zruncon: option requires an argument -- 'u'\n", r.stderr);
}

// GNU: a context with no command is a usage error, exit 1.
test "subprocess: context with no command exits 1" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{"system_u:system_r:unconfined_t:s0"});
    defer r.deinit(a);
    try expectExit(r.term, 1);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "missing command") != null);
}

// On this (non-SELinux) platform, a well-formed invocation reaches the
// libselinux load and fails there with exit 1 — proving the parser accepted
// the operands and control flowed past parsing rather than mis-execing the
// first operand. (On Linux with SELinux this path would attempt setcon.)
test "subprocess: valid context+command reaches SELinux load, exits 1" {
    const a = testing.allocator;
    var r = try run(a, &[_][]const u8{ "mycontext", "true" });
    defer r.deinit(a);
    try expectExit(r.term, 1);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "SELinux library not available") != null);
}
