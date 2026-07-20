//! Externally-anchored parity tests for zpgrep (a pgrep implementation).
//!
//! Anchoring strategy (per zig-forge/CLAUDE.md — no roundtrip-only tests):
//!
//!  1. Pattern-matching tests exercise the real matcher against POSIX
//!     Extended-Regular-Expression semantics. The pattern semantics
//!     (anchors `^`/`$`, alternation `|`, `.` wildcard, whole-string `-x`)
//!     are those procps-ng `pgrep` guarantees by compiling PATTERN with
//!     regcomp(REG_EXTENDED). Sources:
//!       - procps-ng pgrep(1): "The pattern is normally only matched against
//!         the process name. ... --exact: Only match processes whose names
//!         (or command lines if -f is specified) exactly match the pattern."
//!       - IEEE Std 1003.1 (POSIX) §9.4 Extended Regular Expressions.
//!     Expected booleans are written literally; they do NOT come from this
//!     library's own output. The pre-fix code used std.mem.indexOf (literal
//!     substring) and returns WRONG answers for every one of these — see the
//!     mutation note in the task write-up.
//!
//!  2. CLI-level tests shell out to the built zpgrep binary and assert the
//!     exact bytes / exit codes procps-ng documents. Note: on a host without
//!     /proc (macOS/BSD, this dev box) the tool enumerates zero processes, so
//!     these anchor the flag-plumbing and exit-code contract, which is exactly
//!     the `-c`-with-zero-matches bug this change fixes.
//!       - procps-ng pgrep(1) EXIT STATUS: 0 one or more matched, 1 none
//!         matched, 2 syntax error in the command line.
//!       - procps-ng pgrep(1) -c/--count: "Suppress normal output; instead
//!         print a count of matching processes. ... the command will return
//!         non-zero when the count is zero." pgrep prints `0\n` in that case.
//!
//! The local `pgrep` on this dev box is BSD pgrep (no -c, /proc-less), so it
//! cannot serve as the diff oracle; the anchors above are the documented
//! procps-ng contract instead.

const std = @import("std");
const main = @import("main.zig");
const zpgrep_path = @import("build_options").zpgrep_path;

// --- helper: compile a pattern and test one candidate string -----------------
fn match(pattern: [*:0]const u8, exact: bool, text: [:0]const u8) !bool {
    var m = try main.Matcher.init(pattern, exact);
    defer m.deinit();
    return m.matches(text.ptr, text.len);
}

// ============================================================================
// POSIX ERE semantics (the "single biggest parity gap" the audit flagged).
// ============================================================================

test "ERE anchors: ^ssh$ matches only the whole string 'ssh'" {
    // procps `pgrep '^ssh$'` matches a process literally named "ssh", not
    // "sshd" or "openssh". Literal-substring matching (the pre-fix bug) would
    // treat "^ssh$" as text and match NONE of these.
    try std.testing.expect(try match("^ssh$", false, "ssh"));
    try std.testing.expect(!try match("^ssh$", false, "sshd"));
    try std.testing.expect(!try match("^ssh$", false, "openssh"));
    try std.testing.expect(!try match("^ssh$", false, "xsshx"));
}

test "ERE alternation: foo|bar matches either branch" {
    try std.testing.expect(try match("foo|bar", false, "foo"));
    try std.testing.expect(try match("foo|bar", false, "bar"));
    try std.testing.expect(try match("foo|bar", false, "seafood")); // contains 'foo'
    try std.testing.expect(try match("foo|bar", false, "crowbar")); // contains 'bar'
    try std.testing.expect(!try match("foo|bar", false, "baz"));
}

test "ERE wildcard: ba.h matches bash/bath but not bh" {
    try std.testing.expect(try match("ba.h", false, "bash"));
    try std.testing.expect(try match("ba.h", false, "bath"));
    try std.testing.expect(!try match("ba.h", false, "bh"));
    try std.testing.expect(try match("ba.h", false, "baah")); // '.' = the 2nd 'a'
    try std.testing.expect(!try match("ba.h", false, "baxyh")); // '.' spans exactly one char
}

test "unanchored pattern still matches as a substring (default pgrep)" {
    // procps default: PATTERN matched anywhere in the (comm) name.
    try std.testing.expect(try match("ssh", false, "sshd"));
    try std.testing.expect(try match("ssh", false, "openssh"));
    try std.testing.expect(!try match("ssh", false, "bash"));
}

test "-x exact: whole-string match, metacharacters still honored" {
    // procps -x requires the regex to span the entire candidate string.
    try std.testing.expect(try match("ssh", true, "ssh"));
    try std.testing.expect(!try match("ssh", true, "sshd"));
    try std.testing.expect(!try match("ssh", true, "xssh"));
    // regex still applies under -x:
    try std.testing.expect(try match("ss.", true, "ssh"));
    try std.testing.expect(!try match("ss.", true, "sshd"));
    try std.testing.expect(try match("sshd?", true, "ssh")); // 'd?' optional
    try std.testing.expect(try match("sshd?", true, "sshd"));
}

test "invalid ERE is rejected (procps exits usage-error 2)" {
    try std.testing.expectError(error.InvalidRegex, main.Matcher.init("[", false));
    try std.testing.expectError(error.InvalidRegex, main.Matcher.init("a(", false));
}

// ============================================================================
// CLI contract (shell out to the built binary).
// ============================================================================

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    ok: bool, // true if process Exited (vs signalled)
    fn free(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(a: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const r = try std.process.run(a, std.testing.io, .{ .argv = argv });
    return .{
        .stdout = r.stdout,
        .stderr = r.stderr,
        .code = switch (r.term) {
            .exited => |c| c,
            else => 255,
        },
        .ok = r.term == .exited,
    };
}

test "CLI: -c with zero matches prints '0\\n' and exits 1 (procps -c contract)" {
    // THE headline fix. Pre-fix, zpgrep -c on no matches printed nothing and
    // exited 1; procps-ng prints the count `0` even when zero, still exit 1.
    const a = std.testing.allocator;
    const r = try run(a, &.{ zpgrep_path, "-c", "zzz_no_such_process_xyzzy" });
    defer r.free(a);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("0\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 1), r.code);
}

test "CLI: no pattern -> exit 2 (procps EXIT_USAGE)" {
    const a = std.testing.allocator;
    const r = try run(a, &.{zpgrep_path});
    defer r.free(a);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u8, 2), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no process selection criteria") != null);
}

test "CLI: invalid regular expression -> exit 2 (procps EXIT_USAGE)" {
    const a = std.testing.allocator;
    const r = try run(a, &.{ zpgrep_path, "[" });
    defer r.free(a);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u8, 2), r.code);
}

test "CLI: --version prints and exits 0" {
    const a = std.testing.allocator;
    const r = try run(a, &.{ zpgrep_path, "-V" });
    defer r.free(a);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "zpgrep") != null);
}

test "CLI: no matches (non-count) exits 1 with no stdout" {
    const a = std.testing.allocator;
    const r = try run(a, &.{ zpgrep_path, "zzz_no_such_process_xyzzy" });
    defer r.free(a);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
}
