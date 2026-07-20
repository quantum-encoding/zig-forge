//! Externally-anchored GNU-parity tests for zreadlink (GNU `readlink` clone).
//!
//! Two independent anchors, neither authored by this codebase:
//!
//!  1. The real GNU `readlink` binary (coreutils 9.10). When present on the
//!     host, every case is diffed byte-for-byte (stdout AND exit status)
//!     against GNU. This is the true external oracle: if zreadlink and GNU
//!     disagree on any input the test fails. This anchor directly catches the
//!     -f/-e/-m semantic bug (all three previously collapsed to libc realpath).
//!
//!  2. Documented GNU/POSIX behavior captured as literal expected bytes/exit
//!     codes (`mode_cases` + the routing/CLI tests). These run even when no GNU
//!     binary is installed, so the distinct existence-requirement semantics of
//!     -e (all components must exist), -f (all but last), and -m (none) are
//!     pinned to spec, not to a roundtrip.
//!
//! Source for the documented semantics: GNU coreutils manual, "readlink
//! invocation", and coreutils/lib/canonicalize.c (canonicalize_filename_mode:
//! CAN_EXISTING / CAN_ALL_BUT_LAST / CAN_MISSING). No test here is a roundtrip
//! — every expectation is an external fact.
//!
//! The path to the freshly-built zreadlink exe is injected by build.zig via the
//! `build_options` module so the test always exercises the current binary.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

// The zig_core_utils tree runs on the Io-threaded std: process spawning, file
// I/O and directory access all take an explicit `std.Io`. In test builds
// `std.testing.io` is the ready-to-use threaded instance.
const io = std.testing.io;

const zreadlink_path: []const u8 = build_options.zreadlink_path;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/readlink",
    "/opt/homebrew/bin/greadlink",
    "/usr/bin/readlink",
    "/bin/readlink",
};

/// Return a path to a *GNU* readlink, or null. BSD/macOS readlink lacks
/// -f/-m/-v and would produce spurious mismatches, so we probe --version and
/// require the "coreutils" marker.
fn gnuPath() ?[]const u8 {
    for (gnu_candidates) |p| {
        Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        var r = run(std.testing.allocator, p, &.{"--version"}, .inherit) catch continue;
        defer r.deinit(std.testing.allocator);
        if (r.exit_code == 0 and std.mem.indexOf(u8, r.stdout, "coreutils") != null) return p;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // process exit code; 255 for a signal/abnormal termination

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Run `bin` with `args` (program name omitted) in cwd `cwd`, LC_ALL=C.
fn run(
    a: std.mem.Allocator,
    bin: []const u8,
    args: []const []const u8,
    cwd: std.process.Child.Cwd,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, bin);
    try argv.appendSlice(a, args);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("LC_ALL", "C");

    const result = try std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = cwd,
        .environ_map = &env,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
}

fn runZ(a: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return run(a, zreadlink_path, argv, .inherit);
}

// ---------------------------------------------------------------------------
// Fixture: a symlink tree in a temp dir. Child processes run with cwd set to
// this dir so relative operands resolve against a stable known-absolute prefix.
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    prefix: []u8, // realpath of the temp dir (the resolution prefix GNU reports)

    fn dir(self: *Fixture) Io.Dir {
        return self.tmp.dir;
    }
    fn cwd(self: *Fixture) std.process.Child.Cwd {
        return .{ .dir = self.tmp.dir };
    }
    fn deinit(self: *Fixture, a: std.mem.Allocator) void {
        a.free(self.prefix);
        self.tmp.cleanup();
    }
};

fn makeFixture(a: std.mem.Allocator) !Fixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const d = tmp.dir;
    try d.writeFile(io, .{ .sub_path = "realfile", .data = "hi" });
    try d.createDirPath(io, "realdir");
    try d.symLink(io, "/etc/hosts", "link_abs", .{});
    try d.symLink(io, "nonexistent-target", "link_missing", .{});
    try d.symLink(io, "realdir", "link_dir", .{});
    try d.symLink(io, "realfile", "link_file", .{});
    try d.symLink(io, "link_abs", "chain1", .{}); // chain1 -> link_abs -> /etc/hosts

    // On macOS the temp dir itself lives under a symlinked prefix (/var, /tmp);
    // GNU reports the fully-resolved form, so anchor to the same resolved path.
    const prefix_z = try d.realPathFileAlloc(io, ".", a);
    const prefix = try a.dupe(u8, prefix_z);
    a.free(prefix_z);

    return .{ .tmp = tmp, .prefix = prefix };
}

// ---------------------------------------------------------------------------
// Anchor 2: documented GNU semantics as literal expectations (no GNU needed).
// ---------------------------------------------------------------------------

const ModeCase = struct {
    argv: []const []const u8,
    // Expected stdout on success. `abs` is an exact absolute string; otherwise
    // `suffix` is joined onto the fixture prefix as "<prefix>/<suffix>".
    suffix: ?[]const u8 = null,
    abs: ?[]const u8 = null,
    exit: u8,
};

const mode_cases = [_]ModeCase{
    // -e requires every component to exist -> only real targets resolve.
    .{ .argv = &.{ "-e", "link_abs" }, .abs = "/private/etc/hosts", .exit = 0 },
    .{ .argv = &.{ "-e", "link_missing" }, .exit = 1 }, // dangling last component
    .{ .argv = &.{ "-e", "nonexistent" }, .exit = 1 },
    // -f allows the LAST component to be missing, but not an earlier one.
    .{ .argv = &.{ "-f", "link_abs" }, .abs = "/private/etc/hosts", .exit = 0 },
    .{ .argv = &.{ "-f", "link_missing" }, .suffix = "nonexistent-target", .exit = 0 },
    .{ .argv = &.{ "-f", "nonexistent" }, .suffix = "nonexistent", .exit = 0 },
    .{ .argv = &.{ "-f", "nonexistent/sub" }, .exit = 1 }, // missing parent -> fail
    .{ .argv = &.{ "-f", "realfile" }, .suffix = "realfile", .exit = 0 },
    .{ .argv = &.{ "-f", "link_dir" }, .suffix = "realdir", .exit = 0 },
    // -m allows ALL components to be missing; the tail is resolved lexically.
    .{ .argv = &.{ "-m", "link_abs" }, .abs = "/private/etc/hosts", .exit = 0 },
    .{ .argv = &.{ "-m", "link_missing" }, .suffix = "nonexistent-target", .exit = 0 },
    .{ .argv = &.{ "-m", "nonexistent/sub" }, .suffix = "nonexistent/sub", .exit = 0 },
    .{ .argv = &.{ "-m", "a/b/c/d" }, .suffix = "a/b/c/d", .exit = 0 },
    .{ .argv = &.{ "-m", "a/../b" }, .suffix = "b", .exit = 0 }, // .. resolved lexically
    // raw mode reads the link target verbatim.
    .{ .argv = &.{"link_missing"}, .abs = "nonexistent-target", .exit = 0 },
    .{ .argv = &.{"link_abs"}, .abs = "/etc/hosts", .exit = 0 },
    .{ .argv = &.{"realfile"}, .exit = 1 }, // not a symlink
    // -e via a symlink chain resolves the whole chain.
    .{ .argv = &.{ "-e", "chain1" }, .abs = "/private/etc/hosts", .exit = 0 },
};

test "canonicalize modes -e/-f/-m match documented GNU semantics (literal)" {
    const a = std.testing.allocator;
    var fx = try makeFixture(a);
    defer fx.deinit(a);

    for (mode_cases) |c| {
        var r = try run(a, zreadlink_path, c.argv, fx.cwd());
        defer r.deinit(a);

        try std.testing.expectEqual(c.exit, r.exit_code);
        if (c.exit != 0) {
            try std.testing.expectEqualStrings("", r.stdout);
            continue;
        }

        var want = std.ArrayListUnmanaged(u8).empty;
        defer want.deinit(a);
        if (c.abs) |s| {
            try want.appendSlice(a, s);
        } else {
            try want.appendSlice(a, fx.prefix);
            try want.append(a, '/');
            try want.appendSlice(a, c.suffix.?);
        }
        try want.append(a, '\n');
        std.testing.expectEqualStrings(want.items, r.stdout) catch |e| {
            std.debug.print("mode-case argv0={s} prefix={s}\n", .{ c.argv[0], fx.prefix });
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// GNU always writes --help/--version to stdout with exit 0 (coreutils
// convention). The pre-fix zreadlink wrote both to stderr.
// ---------------------------------------------------------------------------

test "--version and --help go to stdout with exit 0 (GNU convention)" {
    const a = std.testing.allocator;

    var v = try runZ(a, &.{"--version"});
    defer v.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), v.exit_code);
    try std.testing.expect(v.stdout.len > 0); // version text on stdout ...
    try std.testing.expectEqualStrings("", v.stderr); // ... not stderr
    try std.testing.expect(std.mem.indexOf(u8, v.stdout, "zreadlink") != null);

    var h = try runZ(a, &.{"--help"});
    defer h.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), h.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, h.stdout, "Usage:") != null);
    try std.testing.expectEqualStrings("", h.stderr);
}

test "missing operand -> exit 1 with diagnostic (GNU)" {
    const a = std.testing.allocator;
    var r = try runZ(a, &.{});
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "missing operand") != null);
}

test "bare '-' is treated as a filename operand, not an option (GNU)" {
    const a = std.testing.allocator;
    // '-' is not a symlink; GNU tries readlink('-') and exits 1 silently.
    var r = try runZ(a, &.{"-"});
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings("", r.stdout);
    // Must NOT be the "unrecognized/invalid option" path.
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "option") == null);
}

// ---------------------------------------------------------------------------
// Anchor 1: differential test against the real GNU readlink, when installed.
// The strongest anchor — it directly catches the -f/-e/-m collapse.
// ---------------------------------------------------------------------------

const diff_argvs = [_][]const []const u8{
    &.{ "-f", "link_abs" },        &.{ "-e", "link_abs" },        &.{ "-m", "link_abs" },
    &.{ "-f", "link_missing" },    &.{ "-e", "link_missing" },    &.{ "-m", "link_missing" },
    &.{ "-f", "nonexistent" },     &.{ "-e", "nonexistent" },     &.{ "-m", "nonexistent" },
    &.{ "-f", "nonexistent/sub" }, &.{ "-m", "nonexistent/sub" }, &.{ "-f", "realfile" },
    &.{ "-f", "link_dir" },        &.{ "-f", "chain1" },          &.{ "-e", "chain1" },
    &.{ "-m", "a/../b" },          &.{ "-m", "a/b/c/d" },         &.{"link_missing"},
    &.{"link_abs"},                &.{"realfile"},                &.{ "-nf", "link_abs" },
    &.{ "-v", "-e", "nonexistent" }, &.{"-"},
};

test "differential vs real GNU readlink (stdout + exit code)" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse {
        std.debug.print("SKIP: no GNU readlink found; literal anchors still ran\n", .{});
        return error.SkipZigTest;
    };

    var fx = try makeFixture(a);
    defer fx.deinit(a);

    for (diff_argvs) |argv| {
        var zr = try run(a, zreadlink_path, argv, fx.cwd());
        defer zr.deinit(a);
        var gr = try run(a, gnu, argv, fx.cwd());
        defer gr.deinit(a);

        std.testing.expectEqualStrings(gr.stdout, zr.stdout) catch |e| {
            std.debug.print("stdout mismatch argv0={s}\n", .{argv[0]});
            return e;
        };
        std.testing.expectEqual(gr.exit_code, zr.exit_code) catch |e| {
            std.debug.print("exit mismatch argv0={s} gnu={d} z={d}\n", .{ argv[0], gr.exit_code, zr.exit_code });
            return e;
        };
    }
}

test "differential vs GNU: unbounded operand count (70 links > old 64 cap)" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse return error.SkipZigTest;

    var fx = try makeFixture(a);
    defer fx.deinit(a);

    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        const name = try std.fmt.allocPrint(a, "l{d}", .{i});
        try names.append(a, name);
        try fx.dir().symLink(io, "/etc/hosts", name, .{});
    }

    var zr = try run(a, zreadlink_path, names.items, fx.cwd());
    defer zr.deinit(a);
    var gr = try run(a, gnu, names.items, fx.cwd());
    defer gr.deinit(a);

    try std.testing.expectEqualStrings(gr.stdout, zr.stdout);
    try std.testing.expectEqual(gr.exit_code, zr.exit_code);
    // All 70 must produce a line (regression guard on the old 64-cap drop).
    try std.testing.expectEqual(@as(usize, 70), std.mem.count(u8, zr.stdout, "\n"));
}
