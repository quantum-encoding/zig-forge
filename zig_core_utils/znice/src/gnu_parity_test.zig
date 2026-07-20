//! Externally-anchored parity tests for znice (GNU `nice` clone).
//!
//! The external anchor is the REAL GNU coreutils `nice` binary (`gnice`,
//! coreutils 9.10 on this machine). For each input we run BOTH znice and the
//! genuine GNU binary and require identical stdout + identical exit code. GNU
//! did not derive its output from znice, so agreement is a true external check
//! (per zig-forge/CLAUDE.md's golden rule — these are not roundtrip tests).
//!
//! When no GNU binary is present (e.g. CI without coreutils) the whole suite
//! degrades to `error.SkipZigTest` rather than a false pass.
//!
//! `znice_path` is injected by build.zig (the just-built binary). `gnice` is
//! discovered at runtime from the usual Homebrew locations.

const std = @import("std");
const build_opts = @import("build_opts");

const gnice_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/nice",
    "/opt/homebrew/bin/gnice",
    "/usr/local/opt/coreutils/libexec/gnubin/nice",
    "/usr/local/bin/gnice",
};

fn findGnice(a: std.mem.Allocator, io: std.Io) ?[]const u8 {
    for (gnice_candidates) |c| {
        // Probe by actually invoking `<candidate> --version`; the first one
        // that spawns and exits 0 is a real GNU nice.
        const r = std.process.run(a, io, .{ .argv = &.{ c, "--version" } }) catch continue;
        a.free(r.stdout);
        a.free(r.stderr);
        switch (r.term) {
            .exited => |code| if (code == 0) return c,
            else => {},
        }
    }
    return null;
}

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    /// Normal-exit code, or null if the process died from a signal (a crash —
    /// e.g. SIGABRT from a bounds-check abort, which is exactly what the OOB
    /// bug produced).
    code: ?u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Run {
    const r = try std.process.run(a, io, .{ .argv = argv });
    return .{
        .stdout = r.stdout,
        .stderr = r.stderr,
        .code = switch (r.term) {
            .exited => |c| c,
            else => null,
        },
    };
}

/// Build an argv slice: [tool] ++ args, with any element equal to the sentinel
/// "@GNICE@" replaced by the discovered gnice absolute path (so cases can run a
/// niceness-printing child that works regardless of PATH).
fn buildArgv(a: std.mem.Allocator, tool: []const u8, args: []const []const u8, gnice: []const u8) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    try list.append(a, tool);
    for (args) |arg| {
        try list.append(a, if (std.mem.eql(u8, arg, "@GNICE@")) gnice else arg);
    }
    return list.toOwnedSlice(a);
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    /// false for --version, whose text is implementation-specific (only the
    /// exit code is contractually GNU-defined).
    compare_stdout: bool = true,
};

const cases = [_]Case{
    .{ .name = "bare-print-niceness", .args = &.{} },
    .{ .name = "run-command-default-adj", .args = &.{"@GNICE@"} },
    .{ .name = "n-explicit-5", .args = &.{ "-n", "5", "@GNICE@" } },
    .{ .name = "n-joined-7", .args = &.{ "-n7", "@GNICE@" } },
    .{ .name = "long-adjustment=7", .args = &.{ "--adjustment=7", "@GNICE@" } },
    .{ .name = "n-clamp-high", .args = &.{ "-n", "999", "@GNICE@" } },
    .{ .name = "n-clamp-20", .args = &.{ "-n", "20", "@GNICE@" } },
    .{ .name = "n-clamp-21", .args = &.{ "-n", "21", "@GNICE@" } },
    .{ .name = "n-overflow-i64", .args = &.{ "-n", "99999999999", "@GNICE@" } },
    .{ .name = "n-overflow-huge", .args = &.{ "-n", "999999999999999999999999", "@GNICE@" } },
    .{ .name = "n-leading-space", .args = &.{ "-n", " 5", "@GNICE@" } },
    .{ .name = "n-plus", .args = &.{ "-n", "+5", "@GNICE@" } },
    .{ .name = "n-neg-zero", .args = &.{ "-n", "-0", "@GNICE@" } },
    .{ .name = "last-wins", .args = &.{ "-n", "1", "-n", "2", "@GNICE@" } },
    // Obsolete `-NUM` form: `-5` == +5, `--5` == -5, `-+5` == +5.
    .{ .name = "obsolete-5", .args = &.{ "-5", "@GNICE@" } },
    .{ .name = "obsolete--5", .args = &.{ "--5", "@GNICE@" } },
    .{ .name = "obsolete-+5", .args = &.{ "-+5", "@GNICE@" } },
    // Error contract: all of these must exit 125 with empty stdout.
    .{ .name = "invalid-adjustment-abc", .args = &.{ "-n", "abc", "@GNICE@" } },
    .{ .name = "invalid-adjustment-5x", .args = &.{ "-n", "5x", "@GNICE@" } },
    .{ .name = "invalid-adjustment-hex", .args = &.{ "-n", "0x5", "@GNICE@" } },
    .{ .name = "invalid-adjustment-trailing-space", .args = &.{ "-n", "5 ", "@GNICE@" } },
    .{ .name = "invalid-adjustment-empty", .args = &.{ "-n", "", "@GNICE@" } },
    .{ .name = "long-adjustment-invalid", .args = &.{ "--adjustment=abc", "@GNICE@" } },
    .{ .name = "n-missing-operand", .args = &.{"-n"} },
    .{ .name = "adjustment-without-command", .args = &.{ "-n", "5" } },
    .{ .name = "unknown-option", .args = &.{ "-x", "@GNICE@" } },
    // exec failure: command not found -> exit 127.
    .{ .name = "nonexistent-command", .args = &.{"this_command_does_not_exist_zzz_9182"} },
    // --version: exit 0 (stdout text is implementation-specific).
    .{ .name = "version", .args = &.{"--version"}, .compare_stdout = false },
    // --help: exit 0 (znice's help text is its own; only the exit code is the
    // GNU contract here, so don't byte-compare stdout).
    .{ .name = "help", .args = &.{"--help"}, .compare_stdout = false },
};

test "znice matches GNU nice across representative inputs" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gnice = findGnice(a, io) orelse {
        std.debug.print("SKIP: no GNU nice binary found in known locations\n", .{});
        return error.SkipZigTest;
    };
    const znice = build_opts.znice_path;

    var failures: usize = 0;
    for (cases) |c| {
        const zargv = try buildArgv(a, znice, c.args, gnice);
        defer a.free(zargv);
        const gargv = try buildArgv(a, gnice, c.args, gnice);
        defer a.free(gargv);

        const zr = try run(a, io, zargv);
        defer zr.deinit(a);
        const gr = try run(a, io, gargv);
        defer gr.deinit(a);

        var ok = true;
        if (zr.code == null) ok = false; // znice crashed (signal) -> never OK
        if (zr.code != gr.code) ok = false;
        if (c.compare_stdout and !std.mem.eql(u8, zr.stdout, gr.stdout)) ok = false;

        if (!ok) {
            failures += 1;
            std.debug.print(
                "FAIL [{s}]: znice(code={?d} out=\"{s}\") vs gnice(code={?d} out=\"{s}\")\n",
                .{ c.name, zr.code, zr.stdout, gr.code, gr.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Dedicated regression for the high-severity OOB (src/main.zig:115): a command
// name >= 4096 bytes used to @memcpy past a fixed 4096-byte stack buffer,
// aborting with SIGABRT (exit 134) in Debug and silently corrupting the stack
// in ReleaseFast. A correct build must terminate NORMALLY. We anchor the exact
// exit code to GNU (127, "No such file or directory").
test "long command name does not overflow the path buffer (OOB regression)" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const znice = build_opts.znice_path;

    const long_name = try a.alloc(u8, 5000);
    defer a.free(long_name);
    @memset(long_name, 'a');

    const r = try run(a, io, &.{ znice, long_name });
    defer r.deinit(a);

    // Must be a normal exit, NOT a signal/abort.
    try std.testing.expect(r.code != null);
    // GNU reports 127 for a not-found command; anchor to that.
    try std.testing.expectEqual(@as(u8, 127), r.code.?);

    // Cross-check against GNU when available.
    if (findGnice(a, io)) |gnice| {
        const gr = try run(a, io, &.{ gnice, long_name });
        defer gr.deinit(a);
        try std.testing.expectEqual(gr.code, r.code);
    }
}
