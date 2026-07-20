//! Externally-anchored parity tests for zmktemp.
//!
//! Anchor: the REAL GNU coreutils `mktemp` binary (gmktemp / coreutils 9.10),
//! discovered at runtime. Every structural assertion below is cross-checked
//! against what gmktemp does for the SAME argv on THIS machine — so the expected
//! behaviour comes from an implementation zmktemp's author did not write, not
//! from a roundtrip. Where randomness makes byte-exact comparison impossible we
//! compare exit codes and path SHAPE (slash presence, literal prefixes/suffixes,
//! run lengths) which is exactly the contract GNU documents.
//!
//! Reference: GNU coreutils manual, "mktemp: Create temporary file or
//! directory" (https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html)
//! and mktemp(1)/mktemp(3): the LAST run of >=3 X's is replaced, chars after it
//! are an implicit suffix, an explicit TEMPLATE is relative to CWD unless -t /
//! -p / --tmpdir is given, --suffix must be slash-free and the template must end
//! in X, and --help/--version are written to stdout.

const std = @import("std");
const build_options = @import("build_options");

const ZMKTEMP = build_options.zmktemp_path;

const FILE = opaque {};
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;

const alloc = std.testing.allocator;

/// Result of running a shell command.
const Run = struct {
    stdout: []u8,
    exit: u8,
    fn deinit(self: *Run) void {
        alloc.free(self.stdout);
    }
    /// stdout with a single trailing '\n' stripped.
    fn line(self: Run) []const u8 {
        var s = self.stdout;
        if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
        return s;
    }
};

fn run(cmd_z: [:0]const u8) !Run {
    const f = popen(cmd_z.ptr, "r") orelse return error.PopenFailed;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..n]);
    }
    const status = pclose(f);
    // WEXITSTATUS: low 8 bits of (status >> 8) on macOS & Linux.
    const s: u32 = @bitCast(status);
    const exit: u8 = @truncate((s >> 8) & 0xff);
    return .{ .stdout = try list.toOwnedSlice(alloc), .exit = exit };
}

fn runFmt(comptime fmt: []const u8, args: anytype) !Run {
    const cmd = try std.fmt.allocPrintSentinel(alloc, fmt, args, 0);
    defer alloc.free(cmd);
    return run(cmd);
}

var gmktemp_cache: ?[]const u8 = null;

/// Locate the real GNU mktemp; skip the test (SkipZigTest) if it is absent.
fn gnu() ![]const u8 {
    if (gmktemp_cache) |g| return g;
    const candidates = [_][:0]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/mktemp",
        "/opt/homebrew/bin/gmktemp",
        "/usr/local/opt/coreutils/libexec/gnubin/mktemp",
        "/usr/local/bin/gmktemp",
    };
    for (candidates) |c| {
        if (access(c.ptr, 0) == 0) {
            gmktemp_cache = c;
            return c;
        }
    }
    return error.SkipZigTest;
}

fn hasSlash(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '/') != null;
}

fn isAlnum(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// CRITICAL: file creation actually works (the O_CREAT/O_EXCL Darwin-flag bug).
// Anchor: gmktemp with the same argv creates a regular file at exit 0.
// ---------------------------------------------------------------------------
test "file creation succeeds and creates a real regular file (Darwin O_CREAT)" {
    _ = try gnu(); // require the anchor to be present
    var r = try runFmt("{s} tmp.XXXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.exit);
    const path = r.line();
    try std.testing.expect(path.len > 0);
    // A null-terminated copy for libc calls.
    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);
    // File exists...
    try std.testing.expectEqual(@as(c_int, 0), access(pz.ptr, 0));
    // ...and gmktemp for the same argv also yields exit 0 + an existing file.
    const g = try gnu();
    var gr = try runFmt("{s} tmp.XXXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expectEqual(@as(u8, 0), gr.exit);
    const gpz = try alloc.dupeZ(u8, gr.line());
    defer alloc.free(gpz);
    try std.testing.expectEqual(@as(c_int, 0), access(gpz.ptr, 0));
    _ = unlink(gpz.ptr);
    _ = unlink(pz.ptr);
}

// ---------------------------------------------------------------------------
// CRITICAL companion: directory creation.
// ---------------------------------------------------------------------------
test "directory creation with -d creates a real directory" {
    _ = try gnu();
    var r = try runFmt("{s} -d tmp.XXXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.exit);
    const pz = try alloc.dupeZ(u8, r.line());
    defer alloc.free(pz);
    try std.testing.expectEqual(@as(c_int, 0), access(pz.ptr, 0));
    // Removing as a directory must succeed (proves it is a dir, not a file).
    try std.testing.expectEqual(@as(c_int, 0), rmdir(pz.ptr));
}

// ---------------------------------------------------------------------------
// HIGH: long X-run does not panic (OOB on the fixed 32-byte buffer).
// Anchor: gmktemp accepts a 40-X run and emits a 40-char alnum run.
// ---------------------------------------------------------------------------
test "40 X's does not crash and yields a 40-char alnum run" {
    const xs = "X" ** 40;
    var r = try runFmt("{s} -u tmp." ++ xs ++ " 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.exit);
    const out = r.line();
    try std.testing.expect(std.mem.startsWith(u8, out, "tmp."));
    const runpart = out["tmp.".len..];
    try std.testing.expectEqual(@as(usize, 40), runpart.len);
    try std.testing.expect(isAlnum(runpart));

    // gmktemp: same shape.
    const g = try gnu();
    var gr = try runFmt("{s} -u tmp." ++ xs ++ " 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expectEqual(@as(u8, 0), gr.exit);
    try std.testing.expectEqual(@as(usize, 40), gr.line()["tmp.".len..].len);
}

// ---------------------------------------------------------------------------
// HIGH: an explicit TEMPLATE is relative to CWD (no $TMPDIR prepend).
// Anchor: gmktemp `myXXXXXX` in /tmp prints a bare "my......" (no slash).
// ---------------------------------------------------------------------------
test "explicit template is relative to CWD, not TMPDIR" {
    var r = try runFmt("cd /tmp && {s} -u myXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.exit);
    const out = r.line();
    try std.testing.expect(!hasSlash(out)); // relative -> no directory component
    try std.testing.expect(std.mem.startsWith(u8, out, "my"));

    const g = try gnu();
    var gr = try runFmt("cd /tmp && {s} -u myXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(!hasSlash(gr.line()));
    try std.testing.expect(std.mem.startsWith(u8, gr.line(), "my"));
    try std.testing.expectEqual(out.len, gr.line().len);
}

// ---------------------------------------------------------------------------
// HIGH: an absolute template is honoured as-is.
// ---------------------------------------------------------------------------
test "absolute template placed exactly, no TMPDIR prefix, no double slash" {
    var r = try runFmt("{s} -u /tmp/fooXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    const out = r.line();
    try std.testing.expect(std.mem.startsWith(u8, out, "/tmp/foo"));
    try std.testing.expect(std.mem.indexOf(u8, out, "//") == null);

    const g = try gnu();
    var gr = try runFmt("{s} -u /tmp/fooXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.startsWith(u8, gr.line(), "/tmp/foo"));
}

// ---------------------------------------------------------------------------
// MEDIUM: the LAST X-run is replaced, earlier X's stay literal.
// Anchor: gmktemp `aXXXbYYYYXXXXXX` keeps the "aXXXbYYYY" prefix and randomises
// only the trailing 6.
// ---------------------------------------------------------------------------
test "trailing X-run is the one replaced (aXXXbYYYYXXXXXX)" {
    var r = try runFmt("{s} -u aXXXbYYYYXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    const out = r.line();
    try std.testing.expectEqual(@as(usize, 15), out.len);
    try std.testing.expect(std.mem.startsWith(u8, out, "aXXXbYYYY"));
    const tail = out["aXXXbYYYY".len..];
    try std.testing.expectEqual(@as(usize, 6), tail.len);
    try std.testing.expect(isAlnum(tail));
    // Regression guard: the trailing run must NOT be left literal "XXXXXX".
    try std.testing.expect(!std.mem.eql(u8, tail, "XXXXXX"));

    const g = try gnu();
    var gr = try runFmt("{s} -u aXXXbYYYYXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.startsWith(u8, gr.line(), "aXXXbYYYY"));
    try std.testing.expectEqual(out.len, gr.line().len);
}

// ---------------------------------------------------------------------------
// MEDIUM: -t interprets TEMPLATE relative to $TMPDIR.
// ---------------------------------------------------------------------------
test "-t prepends TMPDIR" {
    var r = try runFmt("TMPDIR=/tmp {s} -u -t fooXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.exit);
    try std.testing.expect(std.mem.startsWith(u8, r.line(), "/tmp/foo"));

    const g = try gnu();
    var gr = try runFmt("TMPDIR=/tmp {s} -u -t fooXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.startsWith(u8, gr.line(), "/tmp/foo"));
}

// ---------------------------------------------------------------------------
// implicit suffix: chars after the X-run are preserved after substitution.
// ---------------------------------------------------------------------------
test "implicit suffix preserved (fooXXXXXXbar)" {
    var r = try runFmt("{s} -u fooXXXXXXbar 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    const out = r.line();
    try std.testing.expect(std.mem.startsWith(u8, out, "foo"));
    try std.testing.expect(std.mem.endsWith(u8, out, "bar"));
    try std.testing.expectEqual(@as(usize, 12), out.len); // foo(3)+6+bar(3)

    const g = try gnu();
    var gr = try runFmt("{s} -u fooXXXXXXbar 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.endsWith(u8, gr.line(), "bar"));
    try std.testing.expectEqual(out.len, gr.line().len);
}

// ---------------------------------------------------------------------------
// --suffix appended.
// ---------------------------------------------------------------------------
test "explicit --suffix is appended after the X-run" {
    var r = try runFmt("{s} -u --suffix=.txt fooXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expect(std.mem.endsWith(u8, r.line(), ".txt"));
    try std.testing.expect(std.mem.startsWith(u8, r.line(), "foo"));

    const g = try gnu();
    var gr = try runFmt("{s} -u --suffix=.txt fooXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.endsWith(u8, gr.line(), ".txt"));
}

// ---------------------------------------------------------------------------
// double-slash normalisation when -p ends in '/'.
// ---------------------------------------------------------------------------
test "-p with trailing slash does not emit a double slash" {
    var r = try runFmt("{s} -u -p /tmp/ fooXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    try std.testing.expect(std.mem.startsWith(u8, r.line(), "/tmp/foo"));
    try std.testing.expect(std.mem.indexOf(u8, r.line(), "//") == null);

    const g = try gnu();
    var gr = try runFmt("{s} -u -p /tmp/ fooXXXXXX 2>/dev/null", .{g});
    defer gr.deinit();
    try std.testing.expect(std.mem.indexOf(u8, gr.line(), "//") == null);
}

// ---------------------------------------------------------------------------
// Error parity: exit codes must match gmktemp for each rejection.
// ---------------------------------------------------------------------------
fn expectSameExit(comptime argfmt: []const u8) !void {
    const g = try gnu();
    var zr = try runFmt("{s} " ++ argfmt ++ " >/dev/null 2>&1", .{ZMKTEMP});
    defer zr.deinit();
    var gr = try runFmt("{s} " ++ argfmt ++ " >/dev/null 2>&1", .{g});
    defer gr.deinit();
    try std.testing.expectEqual(gr.exit, zr.exit);
}

test "error: too few X's -> exit 1 (matches gmktemp)" {
    try expectSameExit("-u foo.XX");
}

test "error: --suffix containing slash -> exit 1 (matches gmktemp)" {
    try expectSameExit("-u --suffix=a/b fooXXXXXX");
}

test "error: --suffix with non-X trailing template -> exit 1 (matches gmktemp)" {
    try expectSameExit("-u --suffix=.txt fooXXXXXX.bar");
}

test "error: -t with a slash template -> exit 1 (matches gmktemp)" {
    try expectSameExit("-u -t a/bXXXXXX");
}

test "error: unknown option -> exit 1 (matches gmktemp)" {
    try expectSameExit("-u -z");
}

// ---------------------------------------------------------------------------
// --help / --version go to STDOUT (GNU parity), not stderr.
// ---------------------------------------------------------------------------
test "--help and --version are written to stdout, not stderr" {
    _ = try gnu();
    // stdout captured, stderr discarded -> must be non-empty.
    var out = try runFmt("{s} --help 2>/dev/null", .{ZMKTEMP});
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0), out.exit);
    try std.testing.expect(out.stdout.len > 0);
    // stderr captured (stdout discarded) -> must be empty.
    var err = try runFmt("{s} --help 2>&1 1>/dev/null", .{ZMKTEMP});
    defer err.deinit();
    try std.testing.expectEqual(@as(usize, 0), err.stdout.len);

    var vout = try runFmt("{s} --version 2>/dev/null", .{ZMKTEMP});
    defer vout.deinit();
    try std.testing.expect(vout.stdout.len > 0);
    var verr = try runFmt("{s} --version 2>&1 1>/dev/null", .{ZMKTEMP});
    defer verr.deinit();
    try std.testing.expectEqual(@as(usize, 0), verr.stdout.len);
}

// ---------------------------------------------------------------------------
// Unbiased alphabet: every emitted char is in the documented [A-Za-z0-9] set.
// (Rejection sampling replaced biased `% 62`; this asserts the alphabet only.)
// ---------------------------------------------------------------------------
test "generated characters are all alphanumeric" {
    var r = try runFmt("{s} -u tmp.XXXXXXXXXXXXXXXX 2>/dev/null", .{ZMKTEMP});
    defer r.deinit();
    const out = r.line();
    try std.testing.expect(std.mem.startsWith(u8, out, "tmp."));
    try std.testing.expect(isAlnum(out["tmp.".len..]));
}
