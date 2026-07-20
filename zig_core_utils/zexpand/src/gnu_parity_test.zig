// Externally-anchored parity tests for zexpand.
//
// The external anchor is the *real* GNU coreutils `expand` binary
// (resolved at runtime by gnuBin() to
// /opt/homebrew/opt/coreutils/libexec/gnubin/expand or gexpand). For every
// case below we run the SAME input + flags through both zexpand and GNU
// expand and assert byte-identical stdout AND identical process exit codes.
// This is a true third-party oracle, not a roundtrip: if zexpand's expansion
// or exit status drifts from GNU's, the test fails.
//
// Where GNU's stderr wording is locale/quote-style dependent we additionally
// assert only that zexpand's exit code matches and (for a few cases) that its
// stderr contains the documented GNU message fragment.
//
// Inputs are fed via a temp file passed as an argv argument (not stdin), so
// large inputs cannot deadlock the capture pipe.

const std = @import("std");
const c = std.c;
const build_options = @import("build_options");

extern "c" fn fork() c.pid_t;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const zexpand_bin = build_options.zexpand_bin;

// Resolve the real GNU `expand` binary (external oracle). First existing wins.
const gnu_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/expand",
    "/opt/homebrew/bin/gexpand",
    "/usr/bin/expand",
};

fn gnuBin() ?[:0]const u8 {
    for (gnu_candidates) |cand| {
        if (c.access(cand.ptr, 0) == 0) return cand; // 0 == F_OK
    }
    return null;
}

const CaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
};

// fork/exec `argv[0]` (absolute path), capturing stdout and stderr fully.
fn runCapture(alloc: std.mem.Allocator, argv: []const []const u8) !CaptureResult {
    var out_fds: [2]c.fd_t = undefined;
    var err_fds: [2]c.fd_t = undefined;
    if (c.pipe(&out_fds) != 0) return error.PipeFailed;
    if (c.pipe(&err_fds) != 0) return error.PipeFailed;

    // Build null-terminated argv array (dupeZ each element).
    var argv_z = try alloc.alloc(?[*:0]const u8, argv.len + 1);
    defer {
        for (argv_z[0..argv.len]) |p| if (p) |pp| alloc.free(std.mem.span(pp));
        alloc.free(argv_z);
    }
    for (argv, 0..) |a, i| argv_z[i] = (try alloc.dupeZ(u8, a)).ptr;
    argv_z[argv.len] = null;

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child.
        _ = c.dup2(out_fds[1], 1);
        _ = c.dup2(err_fds[1], 2);
        _ = c.close(out_fds[0]);
        _ = c.close(out_fds[1]);
        _ = c.close(err_fds[0]);
        _ = c.close(err_fds[1]);
        _ = execv(argv_z[0].?, @ptrCast(argv_z.ptr));
        c._exit(127);
    }

    // Parent.
    _ = c.close(out_fds[1]);
    _ = c.close(err_fds[1]);
    const stdout = try drain(alloc, out_fds[0]);
    const stderr = try drain(alloc, err_fds[0]);
    _ = c.close(out_fds[0]);
    _ = c.close(err_fds[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // WIFEXITED / WEXITSTATUS for macOS & Linux: low 7 bits = signal, 0x7f mask.
    const exit_code: i32 = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else 128 + (status & 0x7f);

    return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
}

fn drain(alloc: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(alloc);
}

var temp_counter: u64 = 0;

fn writeTempFile(alloc: std.mem.Allocator, contents: []const u8) ![:0]const u8 {
    const dir = "/tmp";
    temp_counter += 1;
    const uniq = (@as(u64, @intCast(c.getpid())) << 32) ^ temp_counter;
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/zexpand_test_{x}", .{ dir, uniq }, 0);
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < contents.len) {
        const n = c.write(fd, contents.ptr + off, contents.len - off);
        if (n < 0) {
            if (c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
    return path;
}

// Run `input` + `flags` through both binaries; assert identical stdout+exit.
// Returns the zexpand result so callers can make extra assertions (stderr).
fn parity(input: []const u8, flags: []const []const u8) !CaptureResult {
    const alloc = std.testing.allocator;

    // GNU binary must be present for the anchor to mean anything.
    const gnu_bin = gnuBin() orelse return error.SkipZigTest;

    const tmp = try writeTempFile(alloc, input);
    defer {
        _ = c.unlink(tmp.ptr);
        alloc.free(tmp);
    }

    var z_argv: std.ArrayList([]const u8) = .empty;
    defer z_argv.deinit(alloc);
    var g_argv: std.ArrayList([]const u8) = .empty;
    defer g_argv.deinit(alloc);
    try z_argv.append(alloc, zexpand_bin);
    try g_argv.append(alloc, gnu_bin);
    for (flags) |fl| {
        try z_argv.append(alloc, fl);
        try g_argv.append(alloc, fl);
    }
    try z_argv.append(alloc, tmp);
    try g_argv.append(alloc, tmp);

    const zr = try runCapture(alloc, z_argv.items);
    const gr = try runCapture(alloc, g_argv.items);
    defer {
        alloc.free(gr.stdout);
        alloc.free(gr.stderr);
    }
    errdefer {
        alloc.free(zr.stdout);
        alloc.free(zr.stderr);
    }

    std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
        std.debug.print("stdout mismatch flags={any}\n  gnu:  {any}\n  zig:  {any}\n", .{ flags, gr.stdout, zr.stdout });
        return e;
    };
    std.testing.expectEqual(gr.exit_code, zr.exit_code) catch |e| {
        std.debug.print("exit mismatch flags={any} gnu={d} zig={d}\n", .{ flags, gr.exit_code, zr.exit_code });
        return e;
    };
    return zr;
}

fn freeZ(r: CaptureResult) void {
    std.testing.allocator.free(r.stdout);
    std.testing.allocator.free(r.stderr);
}

const F = []const u8;

test "default 8-space tabs" {
    freeZ(try parity("a\tb\tc\n", &[_]F{}));
}

test "-t4 attached" {
    freeZ(try parity("a\tb\tc\n", &[_]F{"-t4"}));
}

test "-t 4 separated" {
    freeZ(try parity("a\tb\tc\n", &[_]F{ "-t", "4" }));
}

test "explicit ascending stop list -t 3,6,9" {
    freeZ(try parity("a\tb\tc\n", &[_]F{ "-t", "3,6,9" }));
}

test "explicit stop list -t 8,16" {
    freeZ(try parity("a\tb\tc\n", &[_]F{ "-t", "8,16" }));
}

test "increment form -t 2,+3" {
    freeZ(try parity("a\tb\tc\n", &[_]F{ "-t", "2,+3" }));
}

test "--tabs=4 long attached" {
    freeZ(try parity("a\tb\tc\n", &[_]F{"--tabs=4"}));
}

test "--tabs 4 long separated" {
    freeZ(try parity("a\tb\tc\n", &[_]F{ "--tabs", "4" }));
}

test "obsolete -4 numeric form" {
    freeZ(try parity("a\tb\tc\n", &[_]F{"-4"}));
}

test "obsolete -3,6 numeric list" {
    freeZ(try parity("a\tb\tc\n", &[_]F{"-3,6"}));
}

test "-i initial only" {
    freeZ(try parity("\ta\tb\n", &[_]F{"-i"}));
}

test "--initial long form" {
    freeZ(try parity("\ta\tb\n", &[_]F{"--initial"}));
}

test "clustered short options -it4" {
    freeZ(try parity("\ta\tb\n", &[_]F{"-it4"}));
}

test "backspace decrements column (col-8)" {
    // GNU: 'ab\b' leaves cursor at col 1, tab -> col 8 = 7 spaces.
    freeZ(try parity("ab\x08\tc\n", &[_]F{}));
}

test "multiple leading tabs and text" {
    freeZ(try parity("\t\tfoo\tbar\n\tbaz\n", &[_]F{ "-t", "4" }));
}

test "no tabs passthrough" {
    freeZ(try parity("hello world\nno tabs here\n", &[_]F{}));
}

test "trailing tab at line end" {
    freeZ(try parity("abc\t\n", &[_]F{ "-t", "4" }));
}

// --- The buffer-boundary correctness regression (audit finding #2) ----------
// A single logical line longer than the 65536-byte read buffer must keep the
// column count across the chunk boundary. Anchored against GNU with -t5 (a
// width that is NOT a divisor of 65536, so the pre-fix bug is observable).
test "long line across 64KiB read boundary -t5" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendNTimes(alloc, 'a', 70001);
    try input.append(alloc, '\t');
    try input.appendSlice(alloc, "X\n");
    freeZ(try parity(input.items, &[_]F{ "-t", "5" }));
}

// --- Error-path parity (exit codes) -----------------------------------------
// These GNU-reject inputs must exit 1 with empty stdout, matching GNU. stdout
// and exit code are byte/value compared by parity(); we also assert zexpand's
// stderr carries the documented GNU message fragment.

test "reject -t 0 (tab size cannot be 0)" {
    const r = try parity("a\tb\n", &[_]F{ "-t", "0" });
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "tab size cannot be 0") != null);
}

test "reject -t abc (invalid characters)" {
    const r = try parity("a\tb\n", &[_]F{ "-t", "abc" });
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid character") != null);
}

test "reject -t 8,4 (must be ascending)" {
    const r = try parity("a\tb\n", &[_]F{ "-t", "8,4" });
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "must be ascending") != null);
}

test "reject -t 4,4 (equal is not ascending)" {
    const r = try parity("a\tb\n", &[_]F{ "-t", "4,4" });
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
}

test "reject unknown short option -z" {
    const r = try parity("a\tb\n", &[_]F{"-z"});
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
}

test "reject unknown long option --foo" {
    const r = try parity("a\tb\n", &[_]F{"--foo"});
    defer freeZ(r);
    try std.testing.expect(r.exit_code == 1);
}

// --- Missing-file exit status (audit finding #1) ----------------------------
test "missing file exits 1 like GNU" {
    const alloc = std.testing.allocator;
    const gnu_bin = gnuBin() orelse return error.SkipZigTest;

    const zr = try runCapture(alloc, &[_][]const u8{ zexpand_bin, "/nonexistent_zexpand_xyz" });
    defer freeZ(zr);
    const gr = try runCapture(alloc, &[_][]const u8{ gnu_bin, "/nonexistent_zexpand_xyz" });
    defer freeZ(gr);

    try std.testing.expectEqual(gr.exit_code, zr.exit_code);
    try std.testing.expect(zr.exit_code == 1);
    // stdout is empty for both.
    try std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout);
}

// --version is a zexpand-specific string (not GNU byte-identical) but must
// exit 0 and print something — assert it does not hang/fall through to stdin.
test "--version exits 0 with output" {
    const alloc = std.testing.allocator;
    const zr = try runCapture(alloc, &[_][]const u8{ zexpand_bin, "--version" });
    defer freeZ(zr);
    try std.testing.expect(zr.exit_code == 0);
    try std.testing.expect(zr.stdout.len > 0);
}
