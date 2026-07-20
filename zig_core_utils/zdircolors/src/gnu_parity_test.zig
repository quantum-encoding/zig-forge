//! Externally-anchored parity tests for `zdircolors` (a GNU `dircolors` reimpl).
//!
//! ANCHOR: two independent external anchors, never a roundtrip:
//!
//!   1. Differential against the REAL GNU `dircolors` binary (coreutils 9.10,
//!      Homebrew `/opt/homebrew/bin/gdircolors`). Each `expectParity` test runs
//!      zdircolors AND gdircolors with identical argv + environment and compares
//!      stdout / exit status byte-for-byte. If GNU is not installed those tests
//!      skip (error.SkipZigTest) — they never silently pass.
//!
//!   2. A literal-byte test asserting the exact canonical LS_COLORS bytes GNU
//!      coreutils 9.10 emits for the default database (transcribed verbatim from
//!      `TERM=xterm gdircolors -b`). It runs even without GNU present and is the
//!      mutation-test anchor for the ship-blocking `*.ext` extension-glob fix.
//!
//! The path to the freshly built zdircolors binary is threaded in via build
//! options (see build.zig), so the tests always exercise the current build.
//!
//! Process spawning: the current Zig std has moved spawning behind the Io
//! interface and dropped fork/execve/waitpid from std.posix, so (like the sibling
//! util tests) we drive the classic POSIX syscalls directly. The test links libc.

const std = @import("std");
const build_options = @import("build_options");

/// Absolute path to the freshly built zdircolors binary.
const ZDC = build_options.zdircolors_bin;

const gnu_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/dircolors",
    "/opt/homebrew/bin/gdircolors",
    "/usr/local/opt/coreutils/libexec/gnubin/dircolors",
    "/usr/local/bin/gdircolors",
    "/usr/bin/dircolors",
};

extern "c" fn fork() c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

// macOS/BSD open(2) flag values (fcntl.h).
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    /// WEXITSTATUS on normal exit; 0x1000 | signo if killed by a signal.
    code: u32,

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn gnuPath() ?[:0]const u8 {
    for (gnu_candidates) |p| {
        if (access(p.ptr, 0) == 0) return p; // F_OK
    }
    return null;
}

/// Build a NUL-terminated C vector from NUL-terminated slices.
fn cvec(a: std.mem.Allocator, items: []const [:0]const u8) ![:null]?[*:0]const u8 {
    const vec = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |it, idx| vec[idx] = it.ptr;
    return vec;
}

/// argv with a program-name slot at argv[0] (execve requires it; dircolors
/// parses options from argv[1] onward).
fn argvVec(a: std.mem.Allocator, args: []const [:0]const u8) ![:null]?[*:0]const u8 {
    const vec = try a.allocSentinel(?[*:0]const u8, args.len + 1, null);
    const prog: [:0]const u8 = "dircolors";
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

/// Run `path` with `argv` (argv[0] supplied by us) under exactly `env`,
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

/// Assert zdircolors and GNU dircolors produce identical stdout + exit status.
fn expectParity(argv: []const [:0]const u8, env: []const [:0]const u8) !void {
    const gnu = gnuPath() orelse return error.SkipZigTest;
    const a = std.testing.allocator;

    var z = try run(a, ZDC, argv, env);
    defer z.deinit(a);
    var g = try run(a, gnu, argv, env);
    defer g.deinit(a);

    std.testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print("stdout mismatch: gnu exit={d} zdc exit={d}\n", .{ g.code, z.code });
        return e;
    };
    try std.testing.expectEqual(g.code, z.code);
}

fn makeTempDir(a: std.mem.Allocator) ![:0]u8 {
    const template = try a.dupeZ(u8, "/tmp/zdircolors_test_XXXXXX");
    errdefer a.free(template);
    if (mkdtemp(template.ptr) == null) return error.MkdtempFailed;
    return template;
}

fn writeTempFile(a: std.mem.Allocator, dir: [:0]const u8, name: []const u8, body: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    errdefer a.free(path);
    // NOTE: open(2) is variadic; on ARM64 the mode passed as a fixed 3rd arg is
    // not seen by libc's va_arg, so the created file gets a garbage mode. Set the
    // permissions explicitly with chmod(2) afterward.
    const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return error.OpenFailed;
    var written: usize = 0;
    while (written < body.len) {
        const n = write(fd, body.ptr + written, body.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = close(fd);
    if (chmod(path.ptr, 0o644) != 0) return error.ChmodFailed;
    return path;
}

// Environment presets.
const env_xterm = [_][:0]const u8{"TERM=xterm"};
const env_dumb = [_][:0]const u8{"TERM=dumb"};
const env_dumb_colorterm = [_][:0]const u8{ "TERM=dumb", "COLORTERM=truecolor" };
const env_con = [_][:0]const u8{"TERM=con80x25"};
const env_none = [_][:0]const u8{}; // TERM unset entirely
const env_tcsh = [_][:0]const u8{ "TERM=xterm", "SHELL=/bin/tcsh" };
const env_bash = [_][:0]const u8{ "TERM=xterm", "SHELL=/bin/bash" };

// ---------------------------------------------------------------------------
// GNU-diff anchors: default database
// ---------------------------------------------------------------------------

test "default DB, bourne shell, TERM=xterm matches GNU" {
    try expectParity(&.{"-b"}, &env_xterm);
}

test "default DB, c shell, TERM=xterm matches GNU" {
    try expectParity(&.{"-c"}, &env_xterm);
}

test "default DB, TERM=dumb no COLORTERM => empty, matches GNU" {
    try expectParity(&.{"-b"}, &env_dumb);
}

test "COLORTERM enables colors even with TERM=dumb, matches GNU" {
    try expectParity(&.{"-b"}, &env_dumb_colorterm);
}

test "bracket TERM pattern con[0-9]*x[0-9]* matches GNU" {
    try expectParity(&.{"-b"}, &env_con);
}

test "TERM unset => none => empty default output, matches GNU" {
    try expectParity(&.{"-b"}, &env_none);
}

test "SHELL=/bin/tcsh, no flag => csh syntax, matches GNU" {
    try expectParity(&.{}, &env_tcsh);
}

test "SHELL=/bin/bash, no flag => sh syntax, matches GNU" {
    try expectParity(&.{}, &env_bash);
}

// ---------------------------------------------------------------------------
// GNU-diff anchors: custom database files
// ---------------------------------------------------------------------------

test "extension entries get the required '*' glob prefix, matches GNU" {
    const a = std.testing.allocator;
    if (gnuPath() == null) return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "ext.dircolors", ".tar 01;31\n.foo 5\n");
    defer a.free(path);
    try expectParity(&.{ "-b", path }, &env_xterm);
}

test "leading-* glob entries pass through unchanged, matches GNU" {
    const a = std.testing.allocator;
    if (gnuPath() == null) return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "glob.dircolors", "*.tar 01;31\n*core 00;90\n");
    defer a.free(path);
    try expectParity(&.{ "-b", path }, &env_xterm);
}

test "unrecognized keyword in matched TERM section => exit 1, no stdout (matches GNU)" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "bad.dircolors", "TERM xterm\nBOGUS 5\n");
    defer a.free(path);

    var z = try run(a, ZDC, &.{ "-b", path }, &env_xterm);
    defer z.deinit(a);
    var g = try run(a, gnu, &.{ "-b", path }, &env_xterm);
    defer g.deinit(a);

    // Stderr text differs by program name; assert the behavior, not the bytes.
    try std.testing.expectEqual(g.code, z.code);
    try std.testing.expectEqual(@as(u32, 1), z.code);
    try std.testing.expectEqualStrings(g.stdout, z.stdout);
    try std.testing.expectEqualStrings("", z.stdout);
}

test "unrecognized keyword in GLOBAL preamble is ignored, matches GNU" {
    const a = std.testing.allocator;
    if (gnuPath() == null) return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "global.dircolors", "BOGUS 5\n.tar 01;31\n");
    defer a.free(path);
    try expectParity(&.{ "-b", path }, &env_xterm);
}

test "obsolete OPTIONS/COLOR keywords recognized-and-ignored, matches GNU" {
    const a = std.testing.allocator;
    if (gnuPath() == null) return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "obs.dircolors", "TERM xterm\nOPTIONS -F\nCOLOR tty\n.tar 01;31\n");
    defer a.free(path);
    try expectParity(&.{ "-b", path }, &env_xterm);
}

test "non-matching TERM section disables its definitions, matches GNU" {
    const a = std.testing.allocator;
    if (gnuPath() == null) return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "nomatch.dircolors", "TERM foobar\n.tar 01;31\n");
    defer a.free(path);
    try expectParity(&.{ "-b", path }, &env_xterm);
}

// ---------------------------------------------------------------------------
// GNU-diff anchors: argument handling
// ---------------------------------------------------------------------------

test "extra operand rejected with exit 1, matches GNU" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse return error.SkipZigTest;
    const dir = try makeTempDir(a);
    defer a.free(dir);
    const p1 = try writeTempFile(a, dir, "one.dircolors", ".tar 01;31\n");
    defer a.free(p1);
    const p2 = try writeTempFile(a, dir, "two.dircolors", ".gz 01;31\n");
    defer a.free(p2);

    var z = try run(a, ZDC, &.{ "-b", p1, p2 }, &env_xterm);
    defer z.deinit(a);
    var g = try run(a, gnu, &.{ "-b", p1, p2 }, &env_xterm);
    defer g.deinit(a);

    try std.testing.expectEqual(g.code, z.code);
    try std.testing.expectEqual(@as(u32, 1), z.code);
    try std.testing.expectEqualStrings("", z.stdout);
}

// ---------------------------------------------------------------------------
// Cross-check: our -p database, parsed by GNU, yields GNU's canonical output.
// Anchors our default-database CONTENTS against GNU's parser.
// ---------------------------------------------------------------------------

test "our -p database, parsed by GNU, equals GNU's own default output" {
    const a = std.testing.allocator;
    const gnu = gnuPath() orelse return error.SkipZigTest;

    var rp = try run(a, ZDC, &.{"-p"}, &env_xterm);
    defer rp.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), rp.code);

    const dir = try makeTempDir(a);
    defer a.free(dir);
    const path = try writeTempFile(a, dir, "ourpdb.dircolors", rp.stdout);
    defer a.free(path);

    var via_ours = try run(a, gnu, &.{ "-b", path }, &env_xterm);
    defer via_ours.deinit(a);
    var gnu_default = try run(a, gnu, &.{"-b"}, &env_xterm);
    defer gnu_default.deinit(a);

    try std.testing.expectEqualStrings(gnu_default.stdout, via_ours.stdout);
}

// ---------------------------------------------------------------------------
// Literal-bytes anchor (no GNU binary required).
//
// Canonical GNU coreutils 9.10 default LS_COLORS, transcribed verbatim from
// `TERM=xterm gdircolors -b`. Documents the exact bytes an external
// implementation produces; this anchor bites even without GNU installed and is
// the mutation-test target for the extension-glob (`*.ext`) fix.
// ---------------------------------------------------------------------------

const gnu_910_default_sh =
    "LS_COLORS='rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:" ++
    "bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=00:" ++
    "tw=30;42:ow=34;42:st=37;44:ex=01;32:" ++
    "*.7z=01;31:*.ace=01;31:*.alz=01;31:*.apk=01;31:*.arc=01;31:*.arj=01;31:" ++
    "*.bz=01;31:*.bz2=01;31:*.cab=01;31:*.cpio=01;31:*.crate=01;31:*.deb=01;31:" ++
    "*.drpm=01;31:*.dwm=01;31:*.dz=01;31:*.ear=01;31:*.egg=01;31:*.esd=01;31:" ++
    "*.gz=01;31:*.jar=01;31:*.lha=01;31:*.lrz=01;31:*.lz=01;31:*.lz4=01;31:" ++
    "*.lzh=01;31:*.lzma=01;31:*.lzo=01;31:*.pyz=01;31:*.rar=01;31:*.rpm=01;31:" ++
    "*.rz=01;31:*.sar=01;31:*.swm=01;31:*.t7z=01;31:*.tar=01;31:*.taz=01;31:" ++
    "*.tbz=01;31:*.tbz2=01;31:*.tgz=01;31:*.tlz=01;31:*.txz=01;31:*.tz=01;31:" ++
    "*.tzo=01;31:*.tzst=01;31:*.udeb=01;31:*.war=01;31:*.whl=01;31:*.wim=01;31:" ++
    "*.xz=01;31:*.z=01;31:*.zip=01;31:*.zoo=01;31:*.zst=01;31:" ++
    "*.avif=01;35:*.jpg=01;35:*.jpeg=01;35:*.jxl=01;35:*.mjpg=01;35:*.mjpeg=01;35:" ++
    "*.gif=01;35:*.bmp=01;35:*.pbm=01;35:*.pgm=01;35:*.ppm=01;35:*.tga=01;35:" ++
    "*.xbm=01;35:*.xpm=01;35:*.tif=01;35:*.tiff=01;35:*.png=01;35:*.svg=01;35:" ++
    "*.svgz=01;35:*.mng=01;35:*.pcx=01;35:*.mov=01;35:*.mpg=01;35:*.mpeg=01;35:" ++
    "*.m2v=01;35:*.mkv=01;35:*.webm=01;35:*.webp=01;35:*.ogm=01;35:*.mp4=01;35:" ++
    "*.m4v=01;35:*.mp4v=01;35:*.vob=01;35:*.qt=01;35:*.nuv=01;35:*.wmv=01;35:" ++
    "*.asf=01;35:*.rm=01;35:*.rmvb=01;35:*.flc=01;35:*.avi=01;35:*.fli=01;35:" ++
    "*.flv=01;35:*.gl=01;35:*.dl=01;35:*.xcf=01;35:*.xwd=01;35:*.yuv=01;35:" ++
    "*.cgm=01;35:*.emf=01;35:*.ogv=01;35:*.ogx=01;35:" ++
    "*.aac=00;36:*.au=00;36:*.flac=00;36:*.m4a=00;36:*.mid=00;36:*.midi=00;36:" ++
    "*.mka=00;36:*.mp3=00;36:*.mpc=00;36:*.ogg=00;36:*.ra=00;36:*.wav=00;36:" ++
    "*.oga=00;36:*.opus=00;36:*.spx=00;36:*.xspf=00;36:" ++
    "*~=00;90:*#=00;90:*.bak=00;90:*.crdownload=00;90:*.dpkg-dist=00;90:" ++
    "*.dpkg-new=00;90:*.dpkg-old=00;90:*.dpkg-tmp=00;90:*.old=00;90:*.orig=00;90:" ++
    "*.part=00;90:*.rej=00;90:*.rpmnew=00;90:*.rpmorig=00;90:*.rpmsave=00;90:" ++
    "*.swp=00;90:*.tmp=00;90:*.ucf-dist=00;90:*.ucf-new=00;90:*.ucf-old=00;90:';\n" ++
    "export LS_COLORS\n";

test "LIT: default output byte-exact vs transcribed coreutils 9.10 bytes" {
    const a = std.testing.allocator;
    var z = try run(a, ZDC, &.{"-b"}, &env_xterm);
    defer z.deinit(a);
    try std.testing.expectEqualStrings(gnu_910_default_sh, z.stdout);
}
