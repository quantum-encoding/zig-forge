//! Externally-anchored GNU parity tests for zvdir.
//!
//! The anchor is the REAL GNU coreutils `vdir` binary (invoked as `gvdir`, the
//! Homebrew name for GNU vdir 9.x). For a spread of representative fixtures and
//! flag combinations we run BOTH the freshly-built zvdir and GNU vdir on the
//! exact same absolute directory and assert their stdout is byte-for-byte
//! identical. This is a true external anchor: the expected bytes come from a
//! third-party implementation the library author did not write.
//!
//! If GNU vdir is not installed the parity tests SkipZigTest rather than fail,
//! so the suite stays green on machines without coreutils — but the moment a
//! regression diverges from GNU on a machine that has it, the test goes RED.
//!
//! The zvdir binary path is provided by build.zig via the ZVDIR_BIN env var
//! (the installed artifact); the fixtures are built with real coreutils
//! helpers (mkdir/ln/touch) so directory/symlink/mtime shapes are genuine.

const std = @import("std");
const testing = std.testing;

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const gvdir_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/vdir",
    "/opt/homebrew/bin/gvdir",
    "/usr/local/opt/coreutils/libexec/gnubin/vdir",
    "/usr/local/bin/gvdir",
    "/usr/bin/vdir",
};

fn findGvdir() ?[]const u8 {
    for (gvdir_candidates) |c| {
        // access(path, F_OK=0): 0 if the file exists.
        if (access(c.ptr, 0) == 0) return c;
    }
    return null;
}

fn zvdirBin() ?[]const u8 {
    const v = getenv("ZVDIR_BIN") orelse return null;
    return std.mem.span(v);
}

/// Run `argv` and return owned stdout bytes. Caller frees.
fn runStdout(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(res.stderr);
    return res.stdout;
}

/// Run a setup command; assert it exited 0.
fn runOk(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.SetupFailed,
        else => return error.SetupFailed,
    }
}

/// Build a fresh fixture tree under a unique temp dir and return its absolute
/// path (owned by `gpa`).
fn makeFixture(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    // All transient strings live in an arena freed on return; only the final
    // root path is duped into `gpa` for the caller.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // mktemp -d gives us a clean absolute directory.
    const mk = try std.process.run(a, io, .{ .argv = &.{ "mktemp", "-d" } });
    const root = std.mem.trimEnd(u8, mk.stdout, "\n");

    const adir = try std.fs.path.join(a, &.{ root, "adir" });
    const afile = try std.fs.path.join(a, &.{ root, "afile.txt" });
    const nested = try std.fs.path.join(a, &.{ adir, "nested" });

    try runOk(a, io, &.{ "mkdir", "-p", adir });
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "printf 'hello\\n' > '{s}'", .{afile}) });
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "printf 'x' > '{s}'", .{nested}) });
    // Relative symlink, matching a typical listing.
    try runOk(a, io, &.{ "ln", "-s", "afile.txt", try std.fs.path.join(a, &.{ root, "alink" }) });

    // A file with a name that exercises -b escaping: space + backslash.
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "printf '' > '{s}/a b'", .{root}) });
    // A large sparse file to exercise dynamic size-column width.
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "printf '' > '{s}/small'", .{root}) });
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "dd if=/dev/zero of='{s}/huge' bs=1 count=1 seek=123456788 2>/dev/null", .{root}) });

    // Dated files: old (year form) and future (year form).
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "touch -t 202001011230.00 '{s}/old2020'", .{root}) });
    try runOk(a, io, &.{ "sh", "-c", try std.fmt.allocPrint(a, "touch -t 203006150805.00 '{s}/future2030'", .{root}) });

    return gpa.dupe(u8, root);
}

/// Assert zvdir and gvdir produce identical stdout for `flags` on `dir`.
fn assertParity(gpa: std.mem.Allocator, io: std.Io, zbin: []const u8, gbin: []const u8, flags: []const u8, dir: []const u8) !void {
    const z_out = try runStdout(gpa, io, &.{ zbin, flags, dir });
    defer gpa.free(z_out);
    const g_out = try runStdout(gpa, io, &.{ gbin, flags, dir });
    defer gpa.free(g_out);

    if (!std.mem.eql(u8, z_out, g_out)) {
        std.debug.print(
            \\
            \\PARITY MISMATCH: flags='{s}' dir='{s}'
            \\--- GNU vdir ({s}) ---
            \\{s}
            \\--- zvdir ({s}) ---
            \\{s}
            \\
        , .{ flags, dir, gbin, g_out, zbin, z_out });
        return error.ParityMismatch;
    }
}

test "zvdir matches GNU vdir across fixtures and flags" {
    const gpa = testing.allocator;
    const io = testing.io;

    const zbin = zvdirBin() orelse {
        std.debug.print("ZVDIR_BIN not set; run via `zig build test`\n", .{});
        return error.SkipZigTest;
    };
    const gbin = findGvdir() orelse return error.SkipZigTest;

    const dir = try makeFixture(gpa, io);
    defer {
        // Best-effort cleanup (child process, not the sandboxed shell).
        const res = std.process.run(gpa, io, .{ .argv = &.{ "rm", "-rf", dir } }) catch null;
        if (res) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        gpa.free(dir);
    }

    // Flag matrix: default long listing, escaping, hidden entries, numeric ids,
    // and every sort mode + reverse. Each is diffed against real GNU vdir.
    const flag_sets = [_][]const u8{
        "-lb", // default vdir behavior (long + escape)
        "-b", // escape quoting alone
        "-a", // include . and ..
        "-A", // almost-all
        "-lbn", // numeric uid/gid columns
        "-lbt", // sort by mtime
        "-lbtr", // sort by mtime, reversed
        "-lbS", // sort by size
        "-lbr", // reverse name sort
        "-lbU", // unsorted (directory order)
        "-lba", // long + all
    };

    for (flag_sets) |flags| {
        try assertParity(gpa, io, zbin, gbin, flags, dir);
    }
}
