//! Externally-anchored parity tests for zunlink.
//!
//! The external anchor is the real GNU coreutils `unlink` binary
//! (GNU coreutils 9.10, /opt/homebrew/opt/coreutils/libexec/gnubin/unlink).
//! For each representative invocation we run BOTH zunlink and GNU unlink and
//! require byte-identical stdout, stderr, and exit code after normalizing away
//! the only legitimate difference: the program's own name (GNU prints its
//! argv[0]/basename; zunlink prints "zunlink"). Both are normalized to "PROG".
//!
//! This is a true external anchor per zig-forge/CLAUDE.md: the expected outputs
//! are produced by an implementation zunlink's author did not write. Where GNU
//! output is not byte-stable (e.g. --help emits OSC-8 hyperlink escapes), we
//! fall back to the documented contract (exit code + required substrings) with
//! the source cited inline. No roundtrip-only tests.
//!
//! Paths are injected by build.zig via the `build_options` module:
//!   zunlink_bin  absolute path to the built zunlink binary
//!   gnu_unlink   absolute path to GNU `unlink` (cases skip if it is absent)

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const Io = std.Io;

const ZUNLINK_BIN = build_options.zunlink_bin;
const GNU_UNLINK = build_options.gnu_unlink;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 == terminated by signal / abnormal exit

    fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Build an env map cloned from the process env but forced to the C locale so
/// GNU emits ASCII quotes ('x') rather than fancy U+2018/U+2019.
fn envC(alloc: std.mem.Allocator) !std.process.Environ.Map {
    var map = try testing.environ.createMap(alloc);
    errdefer map.deinit();
    try map.put("LC_ALL", "C");
    try map.put("LANG", "C");
    return map;
}

/// Run `prog` with `rest` as trailing args, in directory `dir`. argv[0] == prog
/// so the child sees its own path as its invocation name (matters for the
/// program-name token in GNU's messages).
fn run(alloc: std.mem.Allocator, prog: []const u8, rest: []const []const u8, dir: Io.Dir) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, prog);
    for (rest) |a| try argv.append(alloc, a);

    var map = try envC(alloc);
    defer map.deinit();

    const res = try std.process.run(alloc, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
        .environ_map = &map,
    });

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

/// Replace the program's own name (full path and basename) with "PROG",
/// guarding the verb "unlink" inside the phrase "cannot unlink" so that a GNU
/// basename of "unlink" is not clobbered by the basename replacement.
fn normalize(alloc: std.mem.Allocator, out: []const u8, prog_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(prog_path);
    const g = try std.mem.replaceOwned(u8, alloc, out, "cannot unlink", "cannot \x01\x01");
    defer alloc.free(g);
    const s1 = try std.mem.replaceOwned(u8, alloc, g, prog_path, "PROG");
    defer alloc.free(s1);
    const s2 = try std.mem.replaceOwned(u8, alloc, s1, base, "PROG");
    defer alloc.free(s2);
    return try std.mem.replaceOwned(u8, alloc, s2, "cannot \x01\x01", "cannot unlink");
}

fn gnuAvailable() bool {
    Io.Dir.accessAbsolute(testing.io, GNU_UNLINK, .{}) catch return false;
    return true;
}

/// Core assertion: for `args`, zunlink and GNU produce identical normalized
/// stdout/stderr and identical exit code. Each runs in its own fresh temp dir
/// so neither observes the other's side effects.
fn expectParity(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var td_z = testing.tmpDir(.{});
    defer td_z.cleanup();
    var td_g = testing.tmpDir(.{});
    defer td_g.cleanup();

    var zr = try run(alloc, ZUNLINK_BIN, args, td_z.dir);
    defer zr.deinit(alloc);
    var gr = try run(alloc, GNU_UNLINK, args, td_g.dir);
    defer gr.deinit(alloc);

    const z_out = try normalize(alloc, zr.stdout, ZUNLINK_BIN);
    defer alloc.free(z_out);
    const g_out = try normalize(alloc, gr.stdout, GNU_UNLINK);
    defer alloc.free(g_out);
    const z_err = try normalize(alloc, zr.stderr, ZUNLINK_BIN);
    defer alloc.free(z_err);
    const g_err = try normalize(alloc, gr.stderr, GNU_UNLINK);
    defer alloc.free(g_err);

    if (zr.code != gr.code or !std.mem.eql(u8, z_out, g_out) or !std.mem.eql(u8, z_err, g_err)) {
        const joined = try std.mem.join(alloc, " ", args);
        defer alloc.free(joined);
        std.debug.print(
            \\PARITY MISMATCH for args=[{s}]
            \\  exit:   zunlink={d} gnu={d}
            \\  stdout: zunlink=<<{s}>> gnu=<<{s}>>
            \\  stderr: zunlink=<<{s}>> gnu=<<{s}>>
            \\
        , .{ joined, zr.code, gr.code, z_out, g_out, z_err, g_err });
        return error.ParityMismatch;
    }
}

test "GNU parity: error and option cases (byte-diff vs GNU unlink)" {
    const alloc = testing.allocator;
    if (!gnuAvailable()) {
        std.debug.print("GNU unlink not found at {s}; skipping byte-diff parity\n", .{GNU_UNLINK});
        return error.SkipZigTest;
    }

    // Each of these must match GNU coreutils 9.10 exactly (name normalized).
    const cases = [_][]const []const u8{
        &.{}, //                    missing operand
        &.{ "a", "b" }, //          extra operand 'b'
        &.{ "a", "b", "c" }, //     extra operand 'b' (first extra reported)
        &.{"-h"}, //                invalid option -- 'h'  (NOT help)
        &.{"-V"}, //                invalid option -- 'V'  (NOT version)
        &.{"-x"}, //                invalid option -- 'x'
        &.{"--foo"}, //             unrecognized option '--foo'
        &.{"--"}, //                missing operand (bare separator)
        &.{ "--", "a", "b" }, //    extra operand 'b' after --
        &.{"/no/such/path/xyz"}, // cannot unlink ...: No such file or directory
        &.{"-"}, //                 operand "-": cannot unlink '-': No such file...
        &.{ "--", "-h" }, //        operand "-h": cannot unlink '-h': No such file...
    };
    for (cases) |c| try expectParity(alloc, c);
}

test "GNU parity: --help and --version exit 0 (documented contract)" {
    // GNU --help emits OSC-8 hyperlink escapes and GNU-specific copyright, so a
    // byte-diff is inappropriate. The stable, documented contract (POSIX/GNU:
    // both exit 0 and print to stdout) is what we anchor. Abbreviations
    // --hel/--ver are unambiguous and must resolve, per getopt_long.
    const alloc = testing.allocator;

    var td = testing.tmpDir(.{});
    defer td.cleanup();

    const help_cases = [_][]const u8{ "--help", "--hel", "--h" };
    for (help_cases) |a| {
        var r = try run(alloc, ZUNLINK_BIN, &.{a}, td.dir);
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "Usage: zunlink") != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "--version") != null);
    }

    const ver_cases = [_][]const u8{ "--version", "--ver" };
    for (ver_cases) |a| {
        var r = try run(alloc, ZUNLINK_BIN, &.{a}, td.dir);
        defer r.deinit(alloc);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "zunlink") != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "1.0.0") != null);
    }
}

test "real unlink: create + remove a file, exit 0, silent" {
    // Anchor: POSIX unlink(2) removes the link; GNU unlink exits 0 with no
    // output on success. We verify the file is actually gone afterward.
    const alloc = testing.allocator;

    var td = testing.tmpDir(.{});
    defer td.cleanup();

    try td.dir.writeFile(testing.io, .{ .sub_path = "victim.txt", .data = "bye" });
    try td.dir.access(testing.io, "victim.txt", .{}); // sanity: it exists

    var r = try run(alloc, ZUNLINK_BIN, &.{"victim.txt"}, td.dir);
    defer r.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);

    const gone = if (td.dir.access(testing.io, "victim.txt", .{})) |_| false else |_| true;
    try testing.expect(gone);
}

test "real unlink: '--' lets a file named '-h' be removed" {
    // GNU parity: `unlink -- -h` removes the file literally named "-h". Without
    // `--` this file could never be unlinked (the regression the audit flagged).
    // We confirm the file is actually removed.
    const alloc = testing.allocator;

    var td = testing.tmpDir(.{});
    defer td.cleanup();

    try td.dir.writeFile(testing.io, .{ .sub_path = "-h", .data = "x" });
    try td.dir.access(testing.io, "-h", .{});

    var r = try run(alloc, ZUNLINK_BIN, &.{ "--", "-h" }, td.dir);
    defer r.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);

    const gone = if (td.dir.access(testing.io, "-h", .{})) |_| false else |_| true;
    try testing.expect(gone);
}
