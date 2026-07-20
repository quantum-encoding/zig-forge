//! Externally-anchored tests for zinstall.
//!
//! Two kinds of anchor, neither of which is a roundtrip (per the zig-forge
//! golden rule):
//!
//!  1. Pure `parseMode` unit tests whose expected values are the mode the real
//!     GNU `install -m <str>` produces (recorded literally below, each with the
//!     exact command used to obtain it on GNU coreutils 9.10). These pin the
//!     symbolic-mode compiler independent of any filesystem side effects.
//!
//!  2. Differential tests that run the freshly built `zinstall` binary AND the
//!     real GNU `install` (`/opt/homebrew/bin/ginstall`) on identical inputs
//!     and assert the resulting on-disk file has the same mode/content/mtime.
//!     Because both binaries run under the same kernel, OS-level quirks (e.g.
//!     macOS stripping setgid on chmod by a non-group-member) affect both
//!     equally, so the diff stays a true parity check.
//!
//! If no GNU `install` is present, the differential tests SkipZigTest rather
//! than silently passing.

const std = @import("std");
const build_options = @import("build_options");
const main = @import("main.zig");

const zinstall_path = build_options.zinstall_path;

const Stat = std.c.Stat;
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;

const is_darwin = @import("builtin").target.os.tag.isDarwin();
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = if (is_darwin) 0x0200 else 0o100;
const O_TRUNC: c_int = if (is_darwin) 0x0400 else 0o1000;

fn gnuInstall() ?[:0]const u8 {
    const candidates = [_][:0]const u8{
        "/opt/homebrew/bin/ginstall",
        "/opt/homebrew/opt/coreutils/libexec/gnubin/install",
        "/usr/local/bin/ginstall",
    };
    for (candidates) |c| {
        if (access(c.ptr, 0) == 0) return c;
    }
    return null;
}

const io = std.testing.io;
const gpa = std.testing.allocator;

fn run(argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

/// Make a fresh temp directory via `mktemp -d`; caller owns the returned slice.
fn mkTmpDir() ![]u8 {
    const r = try run(&.{ "mktemp", "-d" });
    defer gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);
    const trimmed = std.mem.trimEnd(u8, r.stdout, "\n");
    const out = try gpa.dupe(u8, trimmed);
    gpa.free(r.stdout);
    return out;
}

fn join(dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
}

fn writeFile(path: [:0]const u8, contents: []const u8) !void {
    const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    // The variadic open(2) mode arg is unreliable through a fixed-arity extern
    // decl on arm64, so set a deterministic mode on the fd explicitly.
    _ = fchmod(fd, 0o644);
    var off: usize = 0;
    while (off < contents.len) {
        const n = write(fd, contents[off..].ptr, contents.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn modeOf(path: [:0]const u8) !u32 {
    var st: Stat = undefined;
    if (stat(path.ptr, &st) != 0) return error.StatFailed;
    return @as(u32, st.mode) & 0o7777;
}

fn readAll(path: [:0]const u8) ![]u8 {
    const r = try run(&.{ "cat", path });
    defer gpa.free(r.stderr);
    return r.stdout;
}

fn expectTermOk(r: std.process.RunResult) !void {
    switch (r.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("child exited {d}: {s}\n", .{ code, r.stderr });
            return error.ChildFailed;
        },
        else => return error.ChildAbnormal,
    }
}

// ---------------------------------------------------------------------------
// 1. parseMode compiled-mode anchors (values from GNU coreutils 9.10 `install`)
// ---------------------------------------------------------------------------

test "parseMode: octal literals" {
    try std.testing.expectEqual(@as(?c_uint, 0o755), main.parseMode("755"));
    try std.testing.expectEqual(@as(?c_uint, 0o644), main.parseMode("0644"));
    try std.testing.expectEqual(@as(?c_uint, 0o600), main.parseMode("600"));
}

test "parseMode: symbolic modes match GNU install -m output" {
    // Each expected value was produced by running, on GNU coreutils 9.10:
    //   printf hi > s; ginstall -m <STR> s d; stat -f '%p' d
    // and reading the low 12 bits. parseMode is the pure compiler, so it must
    // reproduce the compiled mode GNU applies.

    // ginstall -m u+s,a+rx  ->  04555  (setuid preserved; this was the audit bug)
    try std.testing.expectEqual(@as(?c_uint, 0o4555), main.parseMode("u+s,a+rx"));
    // ginstall -m u+rwx,go+rx -> 0755
    try std.testing.expectEqual(@as(?c_uint, 0o755), main.parseMode("u+rwx,go+rx"));
    // ginstall -m a+rwx -> 0777
    try std.testing.expectEqual(@as(?c_uint, 0o777), main.parseMode("a+rwx"));
    // ginstall -m u=rwx,g=rx,o= -> 0750
    try std.testing.expectEqual(@as(?c_uint, 0o750), main.parseMode("u=rwx,g=rx,o="));
    // ginstall -m go-w -> 0 (base mode is 0; nothing to clear). Old code
    // wrongly substituted 0o755 here.
    try std.testing.expectEqual(@as(?c_uint, 0o0), main.parseMode("go-w"));
    // ginstall -m +t -> 01000 (sticky)
    try std.testing.expectEqual(@as(?c_uint, 0o1000), main.parseMode("+t"));
    // ginstall -m o+t -> 01000
    try std.testing.expectEqual(@as(?c_uint, 0o1000), main.parseMode("o+t"));
    // ginstall -m u+s -> 04000 (setuid only)
    try std.testing.expectEqual(@as(?c_uint, 0o4000), main.parseMode("u+s"));
    // g+s compiles to setgid 02000 per POSIX chmod symbolic-mode semantics
    // (IEEE Std 1003.1 "chmod", the 's' perm with who 'g'). On macOS the
    // *filesystem* result of `ginstall -m g+s` shows 0 because the kernel
    // strips setgid on chmod by a non-group-member; that is a kernel effect,
    // not a compiler effect, so the pure compiled mode is 02000.
    try std.testing.expectEqual(@as(?c_uint, 0o2000), main.parseMode("g+s"));
}

// ---------------------------------------------------------------------------
// 2. Differential tests against the real GNU install binary
// ---------------------------------------------------------------------------

fn differentialMode(flag_args: []const []const u8) !void {
    const gnu = gnuInstall() orelse return error.SkipZigTest;
    const dir = try mkTmpDir();
    defer gpa.free(dir);

    const src = try join(dir, "src.bin");
    defer gpa.free(src);
    try writeFile(src, "the quick brown fox\x00jumps\nover");

    const zdst = try join(dir, "zdst");
    defer gpa.free(zdst);
    const gdst = try join(dir, "gdst");
    defer gpa.free(gdst);

    {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, zinstall_path);
        try argv.appendSlice(gpa, flag_args);
        try argv.appendSlice(gpa, &.{ src, zdst });
        const r = try run(argv.items);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }
    {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, gnu);
        try argv.appendSlice(gpa, flag_args);
        try argv.appendSlice(gpa, &.{ src, gdst });
        const r = try run(argv.items);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    const zmode = try modeOf(zdst);
    const gmode = try modeOf(gdst);
    try std.testing.expectEqual(gmode, zmode);

    const zc = try readAll(zdst);
    defer gpa.free(zc);
    const gc = try readAll(gdst);
    defer gpa.free(gc);
    try std.testing.expectEqualSlices(u8, gc, zc);
}

test "diff vs GNU: default mode" {
    try differentialMode(&.{});
}

test "diff vs GNU: -m 755" {
    try differentialMode(&.{ "-m", "755" });
}

test "diff vs GNU: -m 644" {
    try differentialMode(&.{ "-m", "0644" });
}

test "diff vs GNU: bundled -m755" {
    try differentialMode(&.{"-m755"});
}

test "diff vs GNU: symbolic -m u+s,a+rx (setuid preserved)" {
    try differentialMode(&.{ "-m", "u+s,a+rx" });
}

test "diff vs GNU: symbolic -m u=rwx,g=rx,o=" {
    try differentialMode(&.{ "-m", "u=rwx,g=rx,o=" });
}

test "diff vs GNU: install SOURCE into DIRECTORY" {
    const gnu = gnuInstall() orelse return error.SkipZigTest;
    const dir = try mkTmpDir();
    defer gpa.free(dir);

    const src = try join(dir, "prog");
    defer gpa.free(src);
    try writeFile(src, "#!/bin/sh\necho hi\n");

    const zsub = try join(dir, "zbin");
    defer gpa.free(zsub);
    const gsub = try join(dir, "gbin");
    defer gpa.free(gsub);
    for ([_][:0]const u8{ zsub, gsub }) |d| {
        const r = try run(&.{ "mkdir", d });
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }

    // Trailing slash: install into the directory, basename preserved.
    const zdir_slash = try join(dir, "zbin/");
    defer gpa.free(zdir_slash);
    const gdir_slash = try join(dir, "gbin/");
    defer gpa.free(gdir_slash);

    {
        const r = try run(&.{ zinstall_path, "-m", "700", src, zdir_slash });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }
    {
        const r = try run(&.{ gnu, "-m", "700", src, gdir_slash });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    const zinstalled = try join(dir, "zbin/prog");
    defer gpa.free(zinstalled);
    const ginstalled = try join(dir, "gbin/prog");
    defer gpa.free(ginstalled);

    // This is the exact workflow the audit found broken on macOS (wrong Stat
    // ABI meant dest-is-directory detection failed and the file was never
    // placed under the directory).
    try std.testing.expectEqual(try modeOf(ginstalled), try modeOf(zinstalled));

    const zc = try readAll(zinstalled);
    defer gpa.free(zc);
    const gc = try readAll(ginstalled);
    defer gpa.free(gc);
    try std.testing.expectEqualSlices(u8, gc, zc);
}

test "diff vs GNU: multiple SOURCES into DIRECTORY" {
    const gnu = gnuInstall() orelse return error.SkipZigTest;
    const dir = try mkTmpDir();
    defer gpa.free(dir);

    const a = try join(dir, "a.txt");
    defer gpa.free(a);
    const b = try join(dir, "b.txt");
    defer gpa.free(b);
    try writeFile(a, "alpha");
    try writeFile(b, "bravo");

    const zdir = try join(dir, "zmany");
    defer gpa.free(zdir);
    const gdir = try join(dir, "gmany");
    defer gpa.free(gdir);
    for ([_][:0]const u8{ zdir, gdir }) |d| {
        const r = try run(&.{ "mkdir", d });
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }

    {
        const r = try run(&.{ zinstall_path, a, b, zdir });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }
    {
        const r = try run(&.{ gnu, a, b, gdir });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        const zf = try std.fmt.allocPrintSentinel(gpa, "{s}/zmany/{s}", .{ dir, name }, 0);
        defer gpa.free(zf);
        const gf = try std.fmt.allocPrintSentinel(gpa, "{s}/gmany/{s}", .{ dir, name }, 0);
        defer gpa.free(gf);
        const zc = try readAll(zf);
        defer gpa.free(zc);
        const gc = try readAll(gf);
        defer gpa.free(gc);
        try std.testing.expectEqualSlices(u8, gc, zc);
    }
}

test "diff vs GNU: -p preserves source mtime" {
    const gnu = gnuInstall() orelse return error.SkipZigTest;
    const dir = try mkTmpDir();
    defer gpa.free(dir);

    const src = try join(dir, "src");
    defer gpa.free(src);
    try writeFile(src, "timestamped");
    // Set a fixed, non-current mtime so a "0 mtime" regression is obvious.
    {
        const r = try run(&.{ "touch", "-t", "202001011200.00", src });
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }

    const zdst = try join(dir, "zp");
    defer gpa.free(zdst);
    const gdst = try join(dir, "gp");
    defer gpa.free(gdst);

    {
        const r = try run(&.{ zinstall_path, "-p", src, zdst });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }
    {
        const r = try run(&.{ gnu, "-p", src, gdst });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    var src_st: Stat = undefined;
    var z_st: Stat = undefined;
    var g_st: Stat = undefined;
    try std.testing.expect(stat(src.ptr, &src_st) == 0);
    try std.testing.expect(stat(zdst.ptr, &z_st) == 0);
    try std.testing.expect(stat(gdst.ptr, &g_st) == 0);

    // GNU preserves the source mtime; so must we (audit: it was writing 0).
    try std.testing.expectEqual(src_st.mtime().sec, g_st.mtime().sec);
    try std.testing.expectEqual(g_st.mtime().sec, z_st.mtime().sec);
}

test "diff vs GNU: -C compare on identical files is a no-op copy" {
    const gnu = gnuInstall() orelse return error.SkipZigTest;
    const dir = try mkTmpDir();
    defer gpa.free(dir);

    const src = try join(dir, "src");
    defer gpa.free(src);
    try writeFile(src, "identical contents for compare");

    const zdst = try join(dir, "zc");
    defer gpa.free(zdst);
    const gdst = try join(dir, "gc");
    defer gpa.free(gdst);

    // First install (creates the dest).
    for ([_][2][]const u8{ .{ zinstall_path, zdst }, .{ gnu, gdst } }) |pair| {
        const r = try run(&.{ pair[0], "-m", "644", src, pair[1] });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    // Second install with -C: contents already identical -> should succeed and
    // leave a byte-identical file (never a false "differ" forcing garbage).
    for ([_][2][]const u8{ .{ zinstall_path, zdst }, .{ gnu, gdst } }) |pair| {
        const r = try run(&.{ pair[0], "-C", "-m", "644", src, pair[1] });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try expectTermOk(r);
    }

    const zc = try readAll(zdst);
    defer gpa.free(zc);
    const gc = try readAll(gdst);
    defer gpa.free(gc);
    try std.testing.expectEqualSlices(u8, gc, zc);
    try std.testing.expectEqual(try modeOf(gdst), try modeOf(zdst));
}
