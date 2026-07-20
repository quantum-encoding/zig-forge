//! Externally-anchored parity tests for zrealpath.
//!
//! ANCHOR: the real GNU `realpath` binary from coreutils. Each test runs the
//! SAME argument vector through both `zrealpath` and GNU `realpath`, in an
//! identical filesystem fixture and working directory, and asserts that
//! stdout and the process exit code are byte-for-byte identical. stderr is
//! compared after normalizing the leading program name (`zrealpath:` vs
//! `grealpath:`/`realpath:`), since only the program name legitimately differs.
//!
//! This is a true external anchor: the expected bytes come from a binary this
//! repo did not write (coreutils 9.x). It is NOT a roundtrip test — GNU is the
//! oracle for every case.
//!
//! If no GNU `realpath` is found on the system, the tests skip (return
//! error.SkipZigTest) rather than pass vacuously.

const std = @import("std");
const builtin = @import("builtin");

const zrealpath_bin = "zig-out/bin/zrealpath";

// Raw libc bindings — this Zig's std.fs/std.Io.Dir API requires threading an
// `Io` through every call, which is heavy for a test fixture. libc is simpler
// and fully portable across the Linux/macOS hosts these tests run on.
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

/// Locate a GNU realpath. On macOS coreutils installs it as `grealpath`;
/// the gnubin dir exposes it as `realpath`. On Linux `realpath` is GNU.
fn findGnuRealpath(allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][:0]const u8{
        "/opt/homebrew/bin/grealpath",
        "/opt/homebrew/opt/coreutils/libexec/gnubin/realpath",
        "/usr/local/bin/grealpath",
        "/usr/bin/realpath",
        "/bin/realpath",
    };
    for (candidates) |c| {
        if (access(c.ptr, 0) == 0) {
            return allocator.dupe(u8, c) catch return null;
        }
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    for (args) |a| try argv.append(allocator, a);

    const res = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
    });

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .code = code,
    };
}

/// Strip the leading "PROG: " token from an error line so zrealpath and
/// grealpath/realpath stderr can be compared ignoring the program name.
fn stripProg(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        // Drop everything up to and including the first ": " on lines that
        // begin with a "<prog>: " prefix; also normalize the Try-help line.
        if (std.mem.indexOf(u8, line, "Try '")) |idx| {
            try out.appendSlice(allocator, line[0..idx]);
            try out.appendSlice(allocator, "Try 'PROG");
            const after = line[idx..];
            if (std.mem.indexOf(u8, after, " --help")) |h| {
                try out.appendSlice(allocator, after[h..]);
            }
        } else if (std.mem.indexOf(u8, line, ": ")) |idx| {
            try out.appendSlice(allocator, "PROG");
            try out.appendSlice(allocator, line[idx..]);
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    return out.toOwnedSlice(allocator);
}

const Case = struct {
    args: []const []const u8,
    /// When true, also compare (program-name-normalized) stderr, not just
    /// stdout + exit code. Off for cases where GNU emits localized/link text
    /// we don't need to byte-match.
    check_stderr: bool = true,
};

/// Build the shared filesystem fixture and return its (absolute) root. The
/// caller must pass the returned root to `cleanupFixture`.
fn makeFixture(allocator: std.mem.Allocator) ![]u8 {
    var tmpl = [_]u8{0} ** 32;
    const seed = "/tmp/zrealpathXXXXXX";
    @memcpy(tmpl[0..seed.len], seed);
    const made = mkdtemp(@ptrCast(&tmpl)) orelse return error.FixtureFailed;
    const root = try allocator.dupe(u8, std.mem.span(made));
    errdefer allocator.free(root);

    // dirs a, a/b, a/b/c
    inline for (.{ "a", "a/b", "a/b/c" }) |sub| {
        const d = try std.fs.path.joinZ(allocator, &.{ root, sub });
        defer allocator.free(d);
        _ = mkdir(d.ptr, 0o755);
    }
    // relative symlinks: symc -> a/b/c ; loopa -> loopb -> loopa
    try mkSymlink(allocator, root, "a/b/c", "symc");
    try mkSymlink(allocator, root, "loopb", "loopa");
    try mkSymlink(allocator, root, "loopa", "loopb");
    return root;
}

fn mkSymlink(allocator: std.mem.Allocator, root: []const u8, target: []const u8, name: []const u8) !void {
    const link = try std.fs.path.joinZ(allocator, &.{ root, name });
    defer allocator.free(link);
    const tz = try allocator.dupeZ(u8, target);
    defer allocator.free(tz);
    _ = unlink(link.ptr);
    _ = symlink(tz.ptr, link.ptr);
}

fn cleanupFixture(allocator: std.mem.Allocator, root: []const u8) void {
    inline for (.{ "symc", "loopa", "loopb" }) |name| {
        const l = std.fs.path.joinZ(allocator, &.{ root, name }) catch return;
        defer allocator.free(l);
        _ = unlink(l.ptr);
    }
    inline for (.{ "a/b/c", "a/b", "a" }) |sub| {
        const d = std.fs.path.joinZ(allocator, &.{ root, sub }) catch return;
        defer allocator.free(d);
        _ = rmdir(d.ptr);
    }
    const rz = allocator.dupeZ(u8, root) catch return;
    defer allocator.free(rz);
    _ = rmdir(rz.ptr);
}

fn runParity(allocator: std.mem.Allocator, io: std.Io, gnu: []const u8, root: []const u8, cases: []const Case) !void {
    // zrealpath binary path is relative to the package root; make absolute.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(cwd_ptr);
    const zbin = try std.fs.path.join(allocator, &.{ cwd, zrealpath_bin });
    defer allocator.free(zbin);

    var failures: usize = 0;
    for (cases) |case| {
        const g = try run(allocator, io, gnu, case.args, root);
        defer g.deinit(allocator);
        const z = try run(allocator, io, zbin, case.args, root);
        defer z.deinit(allocator);

        var ok = true;
        if (!std.mem.eql(u8, g.stdout, z.stdout)) ok = false;
        if (g.code != z.code) ok = false;
        if (ok and case.check_stderr) {
            const gs = try stripProg(allocator, g.stderr);
            defer allocator.free(gs);
            const zs = try stripProg(allocator, z.stderr);
            defer allocator.free(zs);
            if (!std.mem.eql(u8, gs, zs)) ok = false;
        }

        if (!ok) {
            failures += 1;
            std.debug.print("PARITY FAIL args=[", .{});
            for (case.args) |a| std.debug.print(" '{s}'", .{a});
            std.debug.print(" ]\n  GNU out='{s}' code={d} err='{s}'\n  ZIG out='{s}' code={d} err='{s}'\n", .{
                g.stdout, g.code, g.stderr, z.stdout, z.code, z.stderr,
            });
        }
    }
    if (failures != 0) return error.ParityMismatch;
}

test "gnu realpath parity" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gnu = findGnuRealpath(allocator) orelse {
        std.debug.print("SKIP: no GNU realpath found on this system\n", .{});
        return error.SkipZigTest;
    };
    defer allocator.free(gnu);

    const root = try makeFixture(allocator);
    defer {
        cleanupFixture(allocator, root);
        allocator.free(root);
    }

    // Absolute paths inside the fixture, reused across cases.
    const p = struct {
        fn j(a: std.mem.Allocator, r: []const u8, rest: []const u8) ![]u8 {
            return std.fs.path.join(a, &.{ r, rest });
        }
    };
    const abc_nope = try p.j(allocator, root, "a/b/c/nope.txt");
    defer allocator.free(abc_nope);
    const missing = try p.j(allocator, root, "no/such/thing");
    defer allocator.free(missing);
    const below_ab = try p.j(allocator, root, "a/b");
    defer allocator.free(below_ab);
    const below_abc = try p.j(allocator, root, "a/b/c");
    defer allocator.free(below_abc);
    const rel_to_a = try p.j(allocator, root, "a");
    defer allocator.free(rel_to_a);
    const rel_to_abc = try p.j(allocator, root, "a/b/c");
    defer allocator.free(rel_to_abc);
    const a_x = try p.j(allocator, root, "a/x");
    defer allocator.free(a_x);
    // ENOTDIR fixture: /etc/hosts is a regular file on both Linux and macOS
    // (macOS resolves the /etc symlink; both binaries do so identically).
    const file_notadir = "/etc/hosts/nope";

    const rel_to_a_flag = try std.fmt.allocPrint(allocator, "--relative-to={s}", .{rel_to_a});
    defer allocator.free(rel_to_a_flag);
    const rel_to_abc_flag = try std.fmt.allocPrint(allocator, "--relative-to={s}", .{rel_to_abc});
    defer allocator.free(rel_to_abc_flag);
    const rel_base_root_flag = try std.fmt.allocPrint(allocator, "--relative-base={s}", .{root});
    defer allocator.free(rel_base_root_flag);

    const cases = [_]Case{
        // --- default mode (-E): all but last component must exist ---
        .{ .args = &.{abc_nope} }, // existing dir, missing final -> print it
        .{ .args = &.{"symc"} }, // relative symlink -> resolved target
        .{ .args = &.{"a/b/c"} }, // plain existing dir
        .{ .args = &.{"a/b/c/"} }, // trailing slash stripped
        .{ .args = &.{file_notadir} }, // ENOTDIR: "Not a directory", exit 1

        // --- -e: every component must exist ---
        .{ .args = &.{ "-e", "a/b/c" } },
        .{ .args = &.{ "-e", abc_nope } }, // missing -> error
        .{ .args = &.{ "-e", "loopa" } }, // ELOOP

        // --- -m: nothing needs to exist ---
        .{ .args = &.{ "-m", missing } },
        .{ .args = &.{ "-m", "a/../x/./y" } }, // lexical . and ..
        .{ .args = &.{ "-m", "/../../x" } }, // .. past root
        .{ .args = &.{ "-m", file_notadir } }, // non-dir mid-path tolerated
        .{ .args = &.{ "-m", "symc/x/y" } }, // resolve symlink then append missing

        // --- -s: don't expand symlinks (lexical) ---
        .{ .args = &.{ "-s", "symc" } },
        .{ .args = &.{ "-s", "-m", "symc/../foo" } },

        // --- errors ---
        .{ .args = &.{""} }, // empty operand -> ENOENT, quoted ''
        .{ .args = &.{ "-m", "" } },
        .{ .args = &.{ "-q", "-e", missing } }, // -q suppresses message, still exit 1
        .{ .args = &.{"--bogus"} }, // unrecognized option + Try-help line

        // --- --relative-to / --relative-base ---
        .{ .args = &.{ rel_to_a_flag, below_abc } }, // -> b/c
        .{ .args = &.{ rel_to_abc_flag, a_x } }, // -> ../../x
        .{ .args = &.{ rel_base_root_flag, below_ab } }, // below base -> a/b
        .{ .args = &.{ rel_base_root_flag, "/etc" } }, // not below base -> absolute

        // --- -L (logical): resolve '..' lexically before symlinks ---
        .{ .args = &.{ "-L", "symc" } }, // no '..' -> same as -P
        .{ .args = &.{ "-P", "symc" } },
        .{ .args = &.{ "-m", "-L", "symc/../foo" } }, // '..' cancels symc lexically
        .{ .args = &.{ "-L", "a/b/../c" } },

        // --- -z NUL terminator ---
        .{ .args = &.{ "-z", "a/b/c" } },
    };

    try runParity(allocator, io, gnu, root, &cases);
}
