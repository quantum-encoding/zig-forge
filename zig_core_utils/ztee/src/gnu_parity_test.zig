//! Externally-anchored parity tests for ztee.
//!
//! The primary anchor is DIFFERENTIAL TESTING against the real GNU `tee`
//! binary (GNU coreutils 9.10, discovered at build time — see build.zig).
//! For each case we feed byte-identical stdin + argv to `ztee` and to GNU
//! `tee`, then compare, byte-for-byte:
//!   - what each wrote to standard output, and
//!   - the contents of the output file(s) each created on disk, and
//!   - the process exit status.
//!
//! This is a true external anchor per zig-forge/CLAUDE.md's golden rule: the
//! expected bytes come from an implementation ztee's author did not write.
//! These are NOT roundtrip tests — nothing here asserts decode(encode(x))==x;
//! every assertion is "ztee's observable output == GNU tee's observable
//! output" (or, for the diagnostic-format cases, == the literal bytes GNU
//! tee emits, quoted from a live run and cited inline).
//!
//! If no GNU `tee` is present on the build host, the differential cases are
//! skipped (error.SkipZigTest) and only the documented-byte cases run.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = std.Io.Dir;

const ZTEE = build_options.ztee_bin;
const GTEE = build_options.gtee_bin; // "" when no GNU tee was found

// The global single-threaded Io uses a *failing* allocator, which cannot spawn
// child processes (spawn needs to allocate the argv vector). Build our own
// Threaded instance backed by a real allocator. page_allocator avoids the
// testing allocator's leak accounting for the Io's own long-lived internals.
var g_threaded: ?std.Io.Threaded = null;
fn io() Io {
    if (g_threaded == null) {
        g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_threaded.?.io();
}

fn haveGnu() bool {
    return GTEE.len != 0;
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,

    fn deinit(self: *RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Create a clean, empty working directory (deleting any leftovers from a
/// prior run) and return an open handle to it.
fn freshDir(name: []const u8) !Dir {
    const i = io();
    const cwd = Dir.cwd();
    cwd.deleteTree(i, name) catch {};
    return cwd.createDirPathOpen(i, name, .{});
}

/// Run `bin` with `extra` argv, feeding `input` on stdin, inside `dir` (which
/// becomes the child's cwd, so any output files it creates land there).
/// Captures stdout and stderr to files and returns their bytes + exit code.
fn runTool(
    gpa: std.mem.Allocator,
    dir: Dir,
    bin: []const u8,
    extra: []const []const u8,
    input: []const u8,
) !RunOut {
    const i = io();

    try dir.writeFile(i, .{ .sub_path = "__stdin", .data = input });
    var infile = try dir.openFile(i, "__stdin", .{});
    defer infile.close(i);
    var outfile = try dir.createFile(i, "__stdout", .{});
    defer outfile.close(i);
    var errfile = try dir.createFile(i, "__stderr", .{});
    defer errfile.close(i);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (extra) |a| try argv.append(gpa, a);

    var child = try std.process.spawn(i, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
        .stdin = .{ .file = infile },
        .stdout = .{ .file = outfile },
        .stderr = .{ .file = errfile },
    });
    const term = try child.wait(i);
    const exit: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };

    const out = try dir.readFileAlloc(i, "__stdout", gpa, .unlimited);
    errdefer gpa.free(out);
    const err = try dir.readFileAlloc(i, "__stderr", gpa, .unlimited);
    return .{ .stdout = out, .stderr = err, .exit = exit };
}

fn readCase(gpa: std.mem.Allocator, dir: Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io(), name, gpa, .unlimited);
}

/// The workhorse: run the SAME input+argv through ztee and GNU tee in two
/// sibling scratch dirs, then assert stdout, exit code, and each named output
/// file match byte-for-byte.
fn expectParity(
    gpa: std.mem.Allocator,
    case: []const u8,
    extra: []const []const u8,
    input: []const u8,
    output_files: []const []const u8,
) !void {
    if (!haveGnu()) return error.SkipZigTest;

    var zbuf: [256]u8 = undefined;
    var gbuf: [256]u8 = undefined;
    const zname = try std.fmt.bufPrint(&zbuf, ".zig-cache/ztee-parity/{s}_z", .{case});
    const gname = try std.fmt.bufPrint(&gbuf, ".zig-cache/ztee-parity/{s}_g", .{case});

    var zdir = try freshDir(zname);
    defer zdir.close(io());
    var gdir = try freshDir(gname);
    defer gdir.close(io());

    var zr = try runTool(gpa, zdir, ZTEE, extra, input);
    defer zr.deinit(gpa);
    var gr = try runTool(gpa, gdir, GTEE, extra, input);
    defer gr.deinit(gpa);

    try std.testing.expectEqualStrings(gr.stdout, zr.stdout);
    try std.testing.expectEqual(gr.exit, zr.exit);

    for (output_files) |f| {
        const zc = try readCase(gpa, zdir, f);
        defer gpa.free(zc);
        const gc = try readCase(gpa, gdir, f);
        defer gpa.free(gc);
        try std.testing.expectEqualStrings(gc, zc);
    }
}

// ---------------------------------------------------------------------------
// Differential parity cases (anchor: real GNU tee output)
// ---------------------------------------------------------------------------

test "parity: basic copy to one file mirrors stdin on stdout" {
    try expectParity(std.testing.allocator, "basic", &.{"out.txt"}, "alpha\nbeta\ngamma\n", &.{"out.txt"});
}

test "parity: default mode truncates an existing longer file" {
    // Regression for the Darwin O_TRUNC bug: writing short content over a
    // pre-existing longer file must leave ONLY the new bytes, no stale tail.
    const gpa = std.testing.allocator;
    if (!haveGnu()) return error.SkipZigTest;
    const i = io();

    var zdir = try freshDir(".zig-cache/ztee-parity/trunc_z");
    defer zdir.close(i);
    var gdir = try freshDir(".zig-cache/ztee-parity/trunc_g");
    defer gdir.close(i);

    // Pre-seed both output files with 32 'A' bytes.
    const seed = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try zdir.writeFile(i, .{ .sub_path = "out.txt", .data = seed });
    try gdir.writeFile(i, .{ .sub_path = "out.txt", .data = seed });

    var zr = try runTool(gpa, zdir, ZTEE, &.{"out.txt"}, "BBB\n");
    defer zr.deinit(gpa);
    var gr = try runTool(gpa, gdir, GTEE, &.{"out.txt"}, "BBB\n");
    defer gr.deinit(gpa);

    const zc = try readCase(gpa, zdir, "out.txt");
    defer gpa.free(zc);
    const gc = try readCase(gpa, gdir, "out.txt");
    defer gpa.free(gc);
    try std.testing.expectEqualStrings(gc, zc);
    // Belt-and-suspenders: GNU leaves exactly "BBB\n".
    try std.testing.expectEqualStrings("BBB\n", zc);
}

test "parity: -a appends to an existing file (no truncation)" {
    // Regression for the Darwin O_APPEND bug: -a must extend, not clobber.
    const gpa = std.testing.allocator;
    if (!haveGnu()) return error.SkipZigTest;
    const i = io();

    var zdir = try freshDir(".zig-cache/ztee-parity/append_z");
    defer zdir.close(i);
    var gdir = try freshDir(".zig-cache/ztee-parity/append_g");
    defer gdir.close(i);

    try zdir.writeFile(i, .{ .sub_path = "log.txt", .data = "first\n" });
    try gdir.writeFile(i, .{ .sub_path = "log.txt", .data = "first\n" });

    var zr = try runTool(gpa, zdir, ZTEE, &.{ "-a", "log.txt" }, "second\n");
    defer zr.deinit(gpa);
    var gr = try runTool(gpa, gdir, GTEE, &.{ "-a", "log.txt" }, "second\n");
    defer gr.deinit(gpa);

    const zc = try readCase(gpa, zdir, "log.txt");
    defer gpa.free(zc);
    const gc = try readCase(gpa, gdir, "log.txt");
    defer gpa.free(gc);
    try std.testing.expectEqualStrings(gc, zc);
    try std.testing.expectEqualStrings("first\nsecond\n", zc);
}

test "parity: -a creates a new file when none exists" {
    try expectParity(std.testing.allocator, "append_new", &.{ "-a", "created.txt" }, "payload\n", &.{"created.txt"});
    // And exit status must be success, not the old 'Cannot open file' path.
}

test "parity: --append long-form" {
    try expectParity(std.testing.allocator, "append_long", &.{ "--append", "out.txt" }, "x\n", &.{"out.txt"});
}

test "parity: multiple output files all receive the stream" {
    try expectParity(std.testing.allocator, "multi", &.{ "a.txt", "b.txt", "c.txt" }, "one\ntwo\n", &.{ "a.txt", "b.txt", "c.txt" });
}

test "parity: binary data with quotes, backslashes and NUL bytes" {
    // tee must be byte-transparent; this stresses that we never treat data as text.
    try expectParity(
        std.testing.allocator,
        "binary",
        &.{"bin.dat"},
        "a\"b\\c\x00d\x01\x02\xff\xfe\ne\n",
        &.{"bin.dat"},
    );
}

test "parity: empty stdin still creates (truncates) the file" {
    try expectParity(std.testing.allocator, "empty", &.{"empty.txt"}, "", &.{"empty.txt"});
}

test "parity: '-' is a literal filename, not a second stdout" {
    // GNU coreutils 9.10 creates a file literally named '-'; it does NOT copy
    // to stdout a second time. Verified live: `printf HELLO | gtee -` prints
    // HELLO once and creates ./- containing HELLO.
    try expectParity(std.testing.allocator, "dash", &.{"-"}, "HELLO", &.{"-"});
}

test "parity: '--' ends option parsing so a dash-file is taken literally" {
    try expectParity(std.testing.allocator, "ddash", &.{ "--", "-x.txt" }, "data\n", &.{"-x.txt"});
}

test "parity: no file operands just copies stdin to stdout" {
    try expectParity(std.testing.allocator, "stdout_only", &.{}, "just stdout\n", &.{});
}

// ---------------------------------------------------------------------------
// Documented-byte cases (anchor: GNU tee's own documented output shape).
// These do not diff against GTEE because GNU embeds argv[0] (a full path) in
// the message, which differs from "ztee"; instead we assert the exact bytes
// GNU tee produces with the program name substituted, quoted from a live run.
// ---------------------------------------------------------------------------

test "help is written to stdout, not stderr" {
    // GNU `tee --help` writes to stdout (exit 0) so that `tee --help | pager`
    // works. Verified: gtee --help -> stdout non-empty, stderr empty.
    const gpa = std.testing.allocator;
    const i = io();
    var dir = try freshDir(".zig-cache/ztee-parity/help");
    defer dir.close(i);

    var r = try runTool(gpa, dir, ZTEE, &.{"--help"}, "");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), r.exit);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "Usage:"));
    try std.testing.expectEqualStrings("", r.stderr);
}

test "version is written to stdout, not stderr" {
    const gpa = std.testing.allocator;
    const i = io();
    var dir = try freshDir(".zig-cache/ztee-parity/version");
    defer dir.close(i);

    var r = try runTool(gpa, dir, ZTEE, &.{"--version"}, "");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), r.exit);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expectEqualStrings("", r.stderr);
}

test "invalid option reports the single offending character and exits 1" {
    // GNU tee for `tee -z` prints (with its argv[0]):
    //   "<prog>: invalid option -- 'z'\nTry '<prog> --help' for more information.\n"
    // and exits 1. We assert ztee's exact bytes with prog == "ztee".
    const gpa = std.testing.allocator;
    const i = io();
    var dir = try freshDir(".zig-cache/ztee-parity/badopt");
    defer dir.close(i);

    var r = try runTool(gpa, dir, ZTEE, &.{"-z"}, "");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 1), r.exit);
    try std.testing.expectEqualStrings(
        "ztee: invalid option -- 'z'\nTry 'ztee --help' for more information.\n",
        r.stderr,
    );
}

test "invalid option in a cluster names the offending char, not the whole cluster" {
    // `tee -ax` -> GNU says "invalid option -- 'x'" (the single char), and the
    // BOTH diagnostic lines survive on a redirected stderr (the persistent
    // File.Writer fix). The old code re-wrapped the fd each print() and only
    // the last line survived; and it printed the whole "ax" cluster.
    const gpa = std.testing.allocator;
    const i = io();
    var dir = try freshDir(".zig-cache/ztee-parity/badcluster");
    defer dir.close(i);

    var r = try runTool(gpa, dir, ZTEE, &.{"-ax"}, "");
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 1), r.exit);
    try std.testing.expectEqualStrings(
        "ztee: invalid option -- 'x'\nTry 'ztee --help' for more information.\n",
        r.stderr,
    );
    // Two lines must both be present (regression for the clobbered-writer bug).
    var line_count: usize = 0;
    for (r.stderr) |c| {
        if (c == '\n') line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}
