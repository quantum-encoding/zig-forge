//! Externally-anchored parity tests for ztimeout.
//!
//! The external anchor is the REAL GNU coreutils `timeout` binary
//! (`gtimeout`, coreutils 9.10), located at test time. Each case runs the
//! identical argument vector through both `ztimeout` and `gtimeout` and asserts
//! the observed exit status matches. GNU's exit-code contract is also documented
//! in `man timeout` / the coreutils manual:
//!
//!   124  COMMAND timed out, and --preserve-status was not given
//!   125  the timeout command itself failed (bad option / bad interval)
//!   126  COMMAND was found but could not be invoked
//!   127  COMMAND could not be found
//!   137  COMMAND was sent SIGKILL (128 + 9)
//!   -    otherwise, the exit status of COMMAND
//!
//! These are true external vectors: neither the inputs nor the expected outputs
//! were authored by ztimeout. If GNU's `timeout` is not installed the parity
//! suite skips (SkipZigTest) rather than silently passing, but the fixed
//! literal-exit-code assertions in "documented GNU exit codes" still run.
//!
//! Regression coverage (audit findings this suite would have caught):
//!   - fractional-duration overflow panic  (0.99999999999)      -> case group A
//!   - command-not-found returns 126 not 127                    -> case group B
//!   - attached short options -sKILL / -k0.2 rejected           -> case group C
//!   - `-s KILL` primary timeout returns 124 not 137            -> case group D
//!   - kill-after double-reap escalates 124 -> 137 wrongly      -> case group E

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Normalized exit result: an exit code (0..255) or a terminating signal.
const Outcome = union(enum) {
    exited: u8,
    signaled: u8,

    fn eql(self: Outcome, other: Outcome) bool {
        return switch (self) {
            .exited => |c| other == .exited and other.exited == c,
            .signaled => |s| other == .signaled and other.signaled == s,
        };
    }

    pub fn format(self: Outcome, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .exited => |c| try writer.print("exit {d}", .{c}),
            .signaled => |s| try writer.print("signal {d}", .{s}),
        }
    }
};

fn run(bin: []const u8, extra: []const []const u8) !Outcome {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (extra) |a| try argv.append(alloc, a);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| .{ .exited = c },
        .signal => |s| .{ .signaled = @intCast(@intFromEnum(s)) },
        else => error.UnexpectedTerm,
    };
}

fn ztimeoutBin() []const u8 {
    if (getenv("ZTIMEOUT_BIN")) |p| return std.mem.span(p);
    // Fallback: the build runs test steps with cwd at the project root.
    return "zig-out/bin/ztimeout";
}

fn findGtimeout() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/timeout",
        "/opt/homebrew/bin/gtimeout",
        "/usr/local/bin/gtimeout",
        "/usr/bin/gtimeout",
    };
    for (candidates) |c| {
        // Probe by running `<candidate> --version`; a clean run (exit 0) means
        // the binary exists and is the GNU tool. Spawn errors (FileNotFound)
        // just move to the next candidate.
        const r = run(c, &.{"--version"}) catch continue;
        if (r.eql(.{ .exited = 0 })) return c;
    }
    return null;
}

/// The parity matrix. Each entry's args are fed to BOTH binaries verbatim.
const cases = [_]struct { name: []const u8, args: []const []const u8 }{
    // A: fractional / duration parsing (regression: overflow panic)
    .{ .name = "A1 long-fraction no panic", .args = &.{ "0.99999999999", "true" } },
    .{ .name = "A2 short duration completes", .args = &.{ "5", "sh", "-c", "exit 0" } },
    .{ .name = "A3 plain integer passthrough", .args = &.{ "5", "sh", "-c", "exit 42" } },
    .{ .name = "A4 child killed by own signal", .args = &.{ "5", "sh", "-c", "kill -TERM $$" } },

    // B: command lookup (regression: 126 vs 127)
    .{ .name = "B1 command not found -> 127", .args = &.{ "1", "definitely_not_a_real_cmd_zzz" } },
    .{ .name = "B2 not-invokable dir -> 126", .args = &.{ "1", "/etc" } },

    // C: attached short options (regression: -sKILL / -k0.2 rejected)
    .{ .name = "C1 -sKILL attached", .args = &.{ "-sKILL", "0.2", "sleep", "5" } },
    .{ .name = "C2 -k0.2 attached, child dies on TERM", .args = &.{ "-k0.2", "0.2", "sleep", "5" } },
    .{ .name = "C3 -s KILL separate", .args = &.{ "-s", "KILL", "0.2", "sleep", "5" } },
    .{ .name = "C4 -k 0.2 separate", .args = &.{ "-k", "0.2", "0.2", "sleep", "5" } },

    // D: primary-signal exit status (regression: KILL primary -> 124)
    .{ .name = "D1 -s KILL primary -> 137", .args = &.{ "-s", "KILL", "0.2", "sleep", "5" } },
    .{ .name = "D2 default TERM timeout -> 124", .args = &.{ "0.2", "sleep", "5" } },
    .{ .name = "D3 --signal=KILL long form", .args = &.{ "--signal=KILL", "0.2", "sleep", "5" } },

    // E: kill-after escalation (regression: double-reap -> spurious 137)
    .{ .name = "E1 TERM-ignoring child escalates to KILL", .args = &.{ "-k0.3", "0.2", "sh", "-c", "trap '' TERM; sleep 5" } },
    .{ .name = "E2 preserve-status timeout -> 143", .args = &.{ "-p", "-k0.2", "0.2", "sleep", "5" } },

    // F: usage errors
    .{ .name = "F1 invalid interval -> 125", .args = &.{ "abc", "echo", "hi" } },
    .{ .name = "F2 unrecognized option -> 125", .args = &.{ "--nope", "5", "echo", "hi" } },
    .{ .name = "F3 missing operand -> 125", .args = &.{} },

    // G: option parsing / fast-exit races (regressions fixed alongside the audit)
    .{ .name = "G1 -- end of options then duration", .args = &.{ "--", "5", "echo", "ok" } },
    .{ .name = "G2 fast command in last poll window", .args = &.{ "0.1", "true" } },
    .{ .name = "G3 numeric signal -s 9", .args = &.{ "-s", "9", "0.2", "sleep", "5" } },
    .{ .name = "G4 SIG-prefixed name -s SIGINT", .args = &.{ "-s", "SIGINT", "0.2", "sh", "-c", "trap '' INT; sleep 5" } },
    .{ .name = "G5 zero duration disables timeout", .args = &.{ "0", "sh", "-c", "exit 5" } },
    .{ .name = "G6 hour suffix completes", .args = &.{ "2h", "true" } },
    .{ .name = "G7 child dies by QUIT (transparent)", .args = &.{ "5", "sh", "-c", "kill -QUIT $$" } },
};

test "ztimeout matches GNU timeout exit status across the parity matrix" {
    const zbin = ztimeoutBin();
    const gbin = findGtimeout() orelse {
        std.debug.print("SKIP: GNU timeout (gtimeout) not found; parity suite requires it\n", .{});
        return error.SkipZigTest;
    };

    var failures: usize = 0;
    for (cases) |c| {
        const zr = run(zbin, c.args) catch |e| {
            std.debug.print("FAIL {s}: ztimeout run error {}\n", .{ c.name, e });
            failures += 1;
            continue;
        };
        const gr = run(gbin, c.args) catch |e| {
            std.debug.print("FAIL {s}: gtimeout run error {}\n", .{ c.name, e });
            failures += 1;
            continue;
        };
        if (!zr.eql(gr)) {
            std.debug.print("MISMATCH {s}: ztimeout={f} gtimeout={f}\n", .{ c.name, zr, gr });
            failures += 1;
        }
    }
    if (failures != 0) {
        std.debug.print("{d}/{d} parity cases mismatched\n", .{ failures, cases.len });
        return error.ParityMismatch;
    }
}

test "documented GNU exit codes (literal, no external binary needed)" {
    // These literals are the coreutils-documented contract, written out so the
    // suite still asserts concrete values even where gtimeout is absent.
    const zbin = ztimeoutBin();

    // 124: plain timeout with default signal (GNU "consumes" the TERM it sent).
    try std.testing.expect((try run(zbin, &.{ "0.2", "sleep", "5" })).eql(.{ .exited = 124 }));
    // SIGKILL as the primary timeout signal: GNU is signal-transparent and
    // re-raises SIGKILL on itself, so the raw wait status is "killed by signal
    // 9" (a shell still reports $?=137 = 128+9). Verified against gtimeout 9.10
    // via waitpid: `gtimeout -s KILL 0.2 sleep 5` -> WIFSIGNALED, WTERMSIG==9.
    try std.testing.expect((try run(zbin, &.{ "-s", "KILL", "0.2", "sleep", "5" })).eql(.{ .signaled = 9 }));
    // Signal transparency: a child that dies from a signal on its own (before
    // any timeout) causes timeout to re-raise that signal. gtimeout waitpid:
    // `gtimeout 5 sh -c 'kill -TERM $$'` -> WIFSIGNALED, WTERMSIG==15.
    try std.testing.expect((try run(zbin, &.{ "5", "sh", "-c", "kill -TERM $$" })).eql(.{ .signaled = 15 }));
    // --preserve-status on a timeout reports 128+sig as a normal exit (143),
    // NOT a signal death. gtimeout waitpid: `gtimeout -p -k0.2 0.2 sleep 5` -> exit 143.
    try std.testing.expect((try run(zbin, &.{ "-p", "-k0.2", "0.2", "sleep", "5" })).eql(.{ .exited = 143 }));
    // 127: command not found.
    try std.testing.expect((try run(zbin, &.{ "1", "definitely_not_a_real_cmd_zzz" })).eql(.{ .exited = 127 }));
    // 126: found but not invokable (a directory).
    try std.testing.expect((try run(zbin, &.{ "1", "/etc" })).eql(.{ .exited = 126 }));
    // 125: bad time interval.
    try std.testing.expect((try run(zbin, &.{ "abc", "echo", "hi" })).eql(.{ .exited = 125 }));
    // passthrough: child's own exit code is preserved.
    try std.testing.expect((try run(zbin, &.{ "5", "sh", "-c", "exit 42" })).eql(.{ .exited = 42 }));
    // fractional-overflow regression: must NOT panic; command runs -> 0.
    try std.testing.expect((try run(zbin, &.{ "0.99999999999", "true" })).eql(.{ .exited = 0 }));
}
