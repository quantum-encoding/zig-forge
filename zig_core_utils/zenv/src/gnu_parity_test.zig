//! Externally-anchored parity tests for `zenv` (a GNU `env` reimplementation).
//!
//! ANCHOR: these tests are anchored two ways, both external to zenv's own code:
//!
//!   1. Differential against the REAL GNU `env` binary — GNU coreutils 9.10,
//!      installed by Homebrew at /opt/homebrew/bin/genv. Each `expectSame*`
//!      test runs zenv AND genv with identical argv + environment and compares
//!      their stdout / exit status. If genv is not installed the differential
//!      tests skip (they never silently pass).
//!
//!   2. Literal-byte tests (`test "LIT: ..."`) that assert the exact bytes GNU
//!      documents `env` to produce, taken from the GNU coreutils manual and the
//!      env(1) POSIX spec. These run even without genv present and are the
//!      mutation-test anchors for the two ship-blocking fixes:
//!        - `-S/--split-string` must SPLIT the string and RUN the command.
//!        - the command is resolved against the PATH of the MODIFIED environment
//!          (so `-i PATH=dir cmd` and `PATH=dir cmd` find the binary in `dir`).
//!
//! No test here is a roundtrip; every expected value comes from GNU, not zenv.

const std = @import("std");
const build_options = @import("build_options");

/// Absolute path to the freshly built zenv binary (threaded in by build.zig).
const ZENV = build_options.zenv_bin;
/// Absolute path to the real GNU env binary (Homebrew coreutils).
const GENV = "/opt/homebrew/bin/genv";

// libc primitives — the current Zig std has moved process spawning behind the
// Io interface and dropped fork/execve/waitpid from std.posix, so we drive the
// classic POSIX syscalls directly. The test links libc.
extern "c" fn fork() c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*:0]u8) ?[*:0]u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

// macOS/BSD open(2) flag values (fcntl.h).
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    /// Exit status (as WEXITSTATUS); 0x1000 | signo if killed by a signal.
    code: u32,

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn dupZ(a: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return a.dupeZ(u8, s);
}

/// Build a null-terminated C string vector from a slice of NUL-terminated slices.
fn cvec(a: std.mem.Allocator, items: []const [:0]const u8) ![:null]?[*:0]const u8 {
    const vec = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |it, idx| vec[idx] = it.ptr;
    return vec;
}

/// Like cvec but prepends a program-name slot at argv[0] (execve requires it;
/// env/zenv both skip argv[0] and parse options from argv[1] onward).
fn argvVec(a: std.mem.Allocator, args: []const [:0]const u8) ![:null]?[*:0]const u8 {
    const vec = try a.allocSentinel(?[*:0]const u8, args.len + 1, null);
    const prog: [:0]const u8 = "env";
    vec[0] = prog.ptr;
    for (args, 0..) |it, idx| vec[idx + 1] = it.ptr;
    return vec;
}

fn drain(a: std.mem.Allocator, fd: c_int, out: *std.ArrayListUnmanaged(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
}

/// Run `path` with `argv` (argv[0] included by caller) and exactly `env`,
/// capturing stdout, stderr and exit status.
fn run(
    a: std.mem.Allocator,
    path: []const u8,
    argv: []const [:0]const u8,
    env: []const [:0]const u8,
) !RunResult {
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    const argv_c = try argvVec(a, argv);
    defer a.free(argv_c);
    const env_c = try cvec(a, env);
    defer a.free(env_c);

    var out_pipe: [2]c_int = undefined;
    var err_pipe: [2]c_int = undefined;
    if (pipe(&out_pipe) != 0) return error.PipeFailed;
    if (pipe(&err_pipe) != 0) return error.PipeFailed;

    const pid = fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child: only async-signal-safe calls until execve.
        _ = close(out_pipe[0]);
        _ = close(err_pipe[0]);
        _ = dup2(out_pipe[1], 1);
        _ = dup2(err_pipe[1], 2);
        _ = close(out_pipe[1]);
        _ = close(err_pipe[1]);
        _ = execve(path_z.ptr, argv_c.ptr, env_c.ptr);
        _exit(127);
    }

    // Parent.
    _ = close(out_pipe[1]);
    _ = close(err_pipe[1]);

    var out_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out_buf.deinit(a);
    var err_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer err_buf.deinit(a);
    try drain(a, out_pipe[0], &out_buf);
    try drain(a, err_pipe[0], &err_buf);
    _ = close(out_pipe[0]);
    _ = close(err_pipe[0]);

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    // Darwin/BSD status decode: WIFEXITED == (status & 0x7f) == 0.
    const raw: u32 = @bitCast(status);
    const code: u32 = if ((raw & 0x7f) == 0)
        (raw >> 8) & 0xff
    else
        0x1000 | (raw & 0x7f);

    return .{
        .stdout = try out_buf.toOwnedSlice(a),
        .stderr = try err_buf.toOwnedSlice(a),
        .code = code,
    };
}

fn haveGenv() bool {
    return access(GENV, 0) == 0; // F_OK
}

/// Assert zenv and genv produce identical stdout and identical exit status.
fn expectSameExact(argv: []const [:0]const u8, env: []const [:0]const u8) !void {
    if (!haveGenv()) return error.SkipZigTest;
    const a = std.testing.allocator;

    var z = try run(a, ZENV, argv, env);
    defer z.deinit(a);
    var g = try run(a, GENV, argv, env);
    defer g.deinit(a);

    std.testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print("argv mismatch (stdout). genv exit={d} zenv exit={d}\n", .{ g.code, z.code });
        return e;
    };
    try std.testing.expectEqual(g.code, z.code);
}

fn sortedLines(a: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(a, line);
    }
    const owned = try lines.toOwnedSlice(a);
    std.mem.sort([]const u8, owned, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return owned;
}

/// Assert zenv and genv emit the SAME SET of environment lines. Order is not
/// compared: `env -i A=1 B=2` line order is a libc putenv artifact on macOS
/// (genv prints reverse-insertion), not a GNU semantic — the contract is the
/// set of variables, which is what a consumer relies on.
fn expectSameEnvSet(argv: []const [:0]const u8, env: []const [:0]const u8) !void {
    if (!haveGenv()) return error.SkipZigTest;
    const a = std.testing.allocator;

    var z = try run(a, ZENV, argv, env);
    defer z.deinit(a);
    var g = try run(a, GENV, argv, env);
    defer g.deinit(a);

    const zl = try sortedLines(a, z.stdout);
    defer a.free(zl);
    const gl = try sortedLines(a, g.stdout);
    defer a.free(gl);

    try std.testing.expectEqual(gl.len, zl.len);
    for (gl, zl) |gline, zline| {
        try std.testing.expectEqualStrings(gline, zline);
    }
    try std.testing.expectEqual(g.code, z.code);
}

const PATH_ENV = [_][:0]const u8{"PATH=/usr/bin:/bin"};

/// Create a fresh temp directory via mkdtemp(3). Returns the NUL-terminated
/// absolute path (owned by the caller).
fn makeTempDir(a: std.mem.Allocator) ![:0]u8 {
    const template = try a.dupeZ(u8, "/tmp/zenv_test_XXXXXX");
    errdefer a.free(template);
    if (mkdtemp(template.ptr) == null) return error.MkdtempFailed;
    return template;
}

/// Write an executable shell script `dir/name` that echoes `marker`.
fn plantTool(dir: []const u8, name: []const u8, marker: []const u8, a: std.mem.Allocator) !void {
    const tool_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    defer a.free(tool_path);
    const fd = open(tool_path.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o755);
    if (fd < 0) return error.OpenFailed;
    const body = try std.fmt.allocPrint(a, "#!/bin/sh\necho {s}\n", .{marker});
    defer a.free(body);
    _ = write(fd, body.ptr, body.len);
    _ = close(fd);
    // open() honors umask, so ensure the exec bits are actually set.
    if (chmod(tool_path.ptr, 0o755) != 0) return error.ChmodFailed;
}

// ---------------------------------------------------------------------------
// Differential tests against GNU env (skip if genv absent)
// ---------------------------------------------------------------------------

test "genv-diff: -S splits and runs the command" {
    try expectSameExact(&.{ "-S", "FOO=bar printenv FOO" }, &PATH_ENV);
}

test "genv-diff: -S with leading assignment and trailing command args" {
    try expectSameExact(&.{ "-S", "A=1 B=2 printf [%s][%s] x y" }, &PATH_ENV);
}

test "genv-diff: -S tab escape does not split the word" {
    try expectSameExact(&.{ "-S", "printf [%s] a\\tb" }, &PATH_ENV);
}

test "genv-diff: -S newline escape" {
    try expectSameExact(&.{ "-S", "printf x\\ny" }, &PATH_ENV);
}

test "genv-diff: -S hash comment to end of string" {
    try expectSameExact(&.{ "-S", "printf %s hi #ignored tail here" }, &PATH_ENV);
}

test "genv-diff: -S backslash-c terminates parsing" {
    try expectSameExact(&.{ "-S", "printf abc\\cdef" }, &PATH_ENV);
}

test "genv-diff: -S escaped-hash is a literal hash" {
    try expectSameExact(&.{ "-S", "printf %s a\\#b" }, &PATH_ENV);
}

test "genv-diff: -S mid-word hash is literal" {
    try expectSameExact(&.{ "-S", "printf %s a#b" }, &PATH_ENV);
}

test "genv-diff: -S single quotes are literal (no escape processing)" {
    try expectSameExact(&.{ "-S", "printf [%s] 'a\\tb'" }, &PATH_ENV);
}

test "genv-diff: -S double quotes process escapes" {
    try expectSameExact(&.{ "-S", "printf [%s] \"a\\tb\"" }, &PATH_ENV);
}

test "genv-diff: -a overrides argv0" {
    try expectSameExact(&.{ "-a", "WOWNAME", "bash", "-c", "echo $0" }, &PATH_ENV);
}

test "genv-diff: --argv0= long form" {
    try expectSameExact(&.{ "--argv0=LONGARG", "bash", "-c", "echo $0" }, &PATH_ENV);
}

test "genv-diff: -i then run with default PATH fallback" {
    // Empty environment, bare command name -> must fall back to _PATH_DEFPATH.
    try expectSameExact(&.{ "-i", "printf", "OK" }, &.{});
}

test "genv-diff: -i sets a fixed environment (as a set)" {
    try expectSameEnvSet(&.{ "-i", "FOO=bar", "BAZ=qux", "ALPHA=1" }, &.{});
}

test "genv-diff: -u removes a variable" {
    try expectSameEnvSet(
        &.{ "-u", "DROPME" },
        &.{ "DROPME=1", "KEEP=2", "ALSO=3" },
    );
}

test "genv-diff: plain NAME=VALUE augments the environment (as a set)" {
    try expectSameEnvSet(
        &.{"ADDED=yes"},
        &.{ "EXISTING=1", "OTHER=2" },
    );
}

test "genv-diff: override existing variable value" {
    try expectSameEnvSet(
        &.{"EXISTING=changed"},
        &.{ "EXISTING=old", "KEEP=1" },
    );
}

test "genv-diff: dash implies ignore-environment" {
    try expectSameEnvSet(&.{ "-", "ONLY=this" }, &.{ "GONE=1", "ALSO=2" });
}

test "genv-diff: bad command exits 127 like GNU" {
    try expectSameExact(&.{"this_command_does_not_exist_zzz"}, &PATH_ENV);
}

// ---------------------------------------------------------------------------
// Literal-byte anchors (documented GNU behavior; run without genv)
// These are the mutation-test anchors for the two ship-blocking fixes.
// ---------------------------------------------------------------------------

test "LIT: -S splits and executes (GNU manual: 'env -S \"cmd args\"' runs cmd)" {
    // Anchor source: GNU coreutils manual, `env` invocation, --split-string:
    // the single argument is split into words which become the command line.
    // `env -S 'FOO=bar printenv FOO'` therefore runs `printenv FOO` with FOO=bar
    // and prints "bar\n". This is the flagship correctness fix.
    const a = std.testing.allocator;
    var z = try run(a, ZENV, &.{ "-S", "FOO=bar printenv FOO" }, &PATH_ENV);
    defer z.deinit(a);
    try std.testing.expectEqualStrings("bar\n", z.stdout);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}

test "LIT: command resolved against the MODIFIED PATH under -i" {
    // GNU env resolves COMMAND against the PATH of the environment it hands the
    // child. With `-i` the inherited PATH is wiped, so a bare command name must
    // be found via the PATH given on the command line. We plant a uniquely named
    // executable in a temp dir that is NOT on the test process's PATH, then run
    //   zenv -i PATH=<tmp> zenv_probe_tool
    // which must execute it and print the marker. (Pre-fix zenv searched the
    // inherited process environ and returned 127.)
    const a = std.testing.allocator;

    const dir = try makeTempDir(a);
    defer a.free(dir);
    const tool_name = "zenv_probe_tool";
    try plantTool(dir, tool_name, "PROBE_OK", a);

    const path_env = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{dir}, 0);
    defer a.free(path_env);

    var z = try run(a, ZENV, &.{ "-i", path_env, tool_name }, &.{});
    defer z.deinit(a);
    try std.testing.expectEqualStrings("PROBE_OK\n", z.stdout);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}

test "LIT: command resolved against a NAME=VALUE PATH override (no -i)" {
    // Same anchor, without -i: a `PATH=<tmp>` assignment on the command line must
    // steer command resolution even though the inherited PATH lacks <tmp>.
    const a = std.testing.allocator;

    const dir = try makeTempDir(a);
    defer a.free(dir);
    const tool_name = "zenv_probe_tool2";
    try plantTool(dir, tool_name, "PROBE2_OK", a);

    const path_env = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{dir}, 0);
    defer a.free(path_env);

    // Inherited env deliberately has a PATH that does NOT contain the tool.
    var z = try run(a, ZENV, &.{ path_env, tool_name }, &.{"PATH=/usr/bin:/bin"});
    defer z.deinit(a);
    try std.testing.expectEqualStrings("PROBE2_OK\n", z.stdout);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}

test "LIT: --version writes to stdout with exit 0 (GNU convention)" {
    // GNU coreutils writes --version/--help to STDOUT with exit status 0.
    const a = std.testing.allocator;
    var z = try run(a, ZENV, &.{"--version"}, &PATH_ENV);
    defer z.deinit(a);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}

test "LIT: --help writes to stdout with exit 0 (GNU convention)" {
    const a = std.testing.allocator;
    var z = try run(a, ZENV, &.{"--help"}, &PATH_ENV);
    defer z.deinit(a);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}

test "LIT: -C without a command still chdirs before printing env" {
    // GNU honors -C/--chdir even with no COMMAND. We chdir to a temp dir and run
    // `zenv -C <tmp> pwd` (pwd reads $PWD-independent cwd) to observe the effect.
    const a = std.testing.allocator;

    const dir = try makeTempDir(a);
    defer a.free(dir);

    // pwd -P prints the physical (symlink-resolved) directory; /tmp is a symlink
    // to /private/tmp on macOS, so resolve our expected value the same way.
    var rp_buf: [1024:0]u8 = undefined;
    const rp = realpath(dir.ptr, &rp_buf) orelse return error.RealpathFailed;
    const expected = std.mem.span(rp);

    var z = try run(a, ZENV, &.{ "-C", dir, "pwd", "-P" }, &PATH_ENV);
    defer z.deinit(a);
    const got = std.mem.trimEnd(u8, z.stdout, "\n");
    try std.testing.expectEqualStrings(expected, got);
    try std.testing.expectEqual(@as(u32, 0), z.code);
}
