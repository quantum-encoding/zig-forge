//! Externally-anchored parity tests for zsort.
//!
//! The external anchor is the REAL GNU coreutils `sort` binary (gsort, GNU
//! coreutils 9.10) installed via Homebrew. Each case runs the just-built zsort
//! AND gsort over identical input with identical flags and asserts byte-exact
//! stdout equality. Neither the inputs nor the expected outputs are authored by
//! this library: the expected output is whatever GNU sort produces. This is a
//! true external anchor (zig-forge golden rule §1), not a roundtrip.
//!
//! Both binaries run under LC_ALL=C so ordering is byte-collation (matching
//! zsort's byte-based comparator).
//!
//! Comparison is driven through libc `system()` (running `/bin/sh -c <script>`)
//! rather than the Io-based std process/fs APIs, to stay simple and portable.
//! A few behaviors GNU emits with a program-name prefix (`sort:` vs `zsort:`)
//! are anchored to documented GNU behavior (exit status + stderr present),
//! since the literal program name necessarily differs.

const std = @import("std");
const build_options = @import("build_options");

const ZSORT = build_options.zsort_exe;

extern "c" fn system(command: [*:0]const u8) c_int;

const gsort_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/sort",
    "/opt/homebrew/bin/gsort",
    "/usr/local/bin/gsort",
};

fn findGsort() ?[:0]const u8 {
    for (gsort_candidates) |c| {
        if (std.c.access(c.ptr, 0) == 0) return c; // F_OK == 0
    }
    return null;
}

/// WEXITSTATUS of a libc system() return value.
fn wexit(ret: c_int) u8 {
    return @truncate(@as(c_uint, @bitCast(ret)) >> 8 & 0xff);
}

fn writeFileLibc(path_z: [*:0]const u8, content: []const u8) !void {
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < content.len) {
        const n = std.c.write(fd, content.ptr + off, content.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn joinArgs(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (args, 0..) |a, i| {
        if (i != 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, a);
    }
    return buf.toOwnedSlice(alloc);
}

const IN = "/tmp/zsort_parity_in.txt";
const OUT_Z = "/tmp/zsort_parity_z.txt";
const OUT_G = "/tmp/zsort_parity_g.txt";

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    input: []const u8,
};

const cases = [_]Case{
    .{ .name = "plain", .args = &.{}, .input = "cherry\nbanana\napple\nbanana\n" },
    .{ .name = "reverse", .args = &.{"-r"}, .input = "cherry\nbanana\napple\n" },
    .{ .name = "numeric", .args = &.{"-n"}, .input = "10\n2\n1\n100\n3\n" },
    // finding: -n must skip leading blanks (not string-compare '1'<'2')
    .{ .name = "numeric-padded", .args = &.{"-n"}, .input = "  10\n  2\n  100\n  3\n" },
    // finding: -n must parse a leading numeric prefix, ignoring trailing text
    .{ .name = "numeric-suffix", .args = &.{"-n"}, .input = "9kg\n80kg\n7kg\n120kg\n" },
    .{ .name = "numeric-neg", .args = &.{"-n"}, .input = "-5\n3\n-10\n0\n7\n" },
    .{ .name = "numeric-reverse", .args = &.{ "-n", "-r" }, .input = "10\n2\n1\n100\n3\n" },
    .{ .name = "ignore-case", .args = &.{"-f"}, .input = "Banana\napple\nCHERRY\nApple\n" },
    .{ .name = "unique", .args = &.{"-u"}, .input = "b\na\nb\nc\na\n" },
    // finding: -u -f dedups foo/foO by key equality
    .{ .name = "unique-fold", .args = &.{ "-u", "-f" }, .input = "foo\nfoO\nFOO\nbar\n" },
    // finding: -u dedups by SORT-KEY equality, not full-line bytes
    .{ .name = "unique-key-numeric", .args = &.{ "-u", "-k2", "-n" }, .input = "apple 1\nbanana 1\ncherry 2\n" },
    // finding: default field separator uses blank-run semantics (tabs)
    .{ .name = "key-tab", .args = &.{ "-k2", "-n" }, .input = "a\t3\nb\t1\nc\t2\n" },
    // finding: default field separator collapses runs of spaces
    .{ .name = "key-multispace", .args = &.{ "-k2", "-n" }, .input = "a    3\nb 1\nc   2\n" },
    .{ .name = "key-second-string", .args = &.{"-k2"}, .input = "x zebra\ny apple\nz mango\n" },
    // finding: -r reverses the last-resort whole-line tiebreak too
    .{ .name = "reverse-tiebreak", .args = &.{ "-n", "-r", "-k1" }, .input = "1 z\n1 a\n1 m\n" },
    // finding: -s stable keeps input order for equal keys
    .{ .name = "stable", .args = &.{ "-s", "-n", "-k1" }, .input = "2 zzz\n1 x\n2 aaa\n2 mmm\n" },
    // finding: -g places NaN first
    .{ .name = "general-nan", .args = &.{"-g"}, .input = "nan\n5\n2\n0.5\n" },
    .{ .name = "general-sci", .args = &.{"-g"}, .input = "1e3\n2.5\n1e-2\n50\n" },
    .{ .name = "ignore-blanks", .args = &.{"-b"}, .input = "   banana\napple\n  cherry\n" },
    .{ .name = "field-sep-colon", .args = &.{ "-t", ":", "-k2", "-n" }, .input = "root:3\nbin:1\nsys:2\n" },
    .{ .name = "version-sort", .args = &.{"-V"}, .input = "1.10\n1.2\n1.1\n1.20\n" },
    .{ .name = "reverse-numeric-key", .args = &.{ "-rn", "-k2" }, .input = "a 5\nb 1\nc 3\n" },
    .{ .name = "empty-lines", .args = &.{}, .input = "b\n\na\n\nc\n" },
    .{ .name = "no-trailing-newline", .args = &.{}, .input = "cherry\nbanana\napple" },
};

test "gnu parity: output matches gsort byte-for-byte" {
    const alloc = std.testing.allocator;
    const gsort = findGsort() orelse {
        std.debug.print("SKIP: no GNU sort binary found\n", .{});
        return error.SkipZigTest;
    };

    var failures: usize = 0;
    for (cases) |c| {
        try writeFileLibc(IN, c.input);
        const argstr = try joinArgs(alloc, c.args);
        defer alloc.free(argstr);

        const script = try std.fmt.allocPrintSentinel(alloc,
            \\export LC_ALL=C
            \\'{s}' {s} < '{s}' > '{s}' 2>/dev/null
            \\'{s}' {s} < '{s}' > '{s}' 2>/dev/null
            \\cmp -s '{s}' '{s}'
        , .{ ZSORT, argstr, IN, OUT_Z, gsort, argstr, IN, OUT_G, OUT_Z, OUT_G }, 0);
        defer alloc.free(script);

        const ret = system(script.ptr);
        if (wexit(ret) != 0) {
            failures += 1;
            std.debug.print("FAIL [{s}] args=[{s}] input={s}\n", .{ c.name, argstr, c.input });
            // Show the diff for debugging.
            const diff = try std.fmt.allocPrintSentinel(alloc, "diff '{s}' '{s}' 1>&2", .{ OUT_Z, OUT_G }, 0);
            defer alloc.free(diff);
            _ = system(diff.ptr);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// -o/--output=FILE: GNU writes the sorted result to FILE (not stdout) and the
// file is created. Anchored against gsort's own -o output on the same input,
// and asserts nothing was written to stdout.
test "gnu parity: -o writes to FILE, not stdout" {
    const alloc = std.testing.allocator;
    const gsort = findGsort() orelse return error.SkipZigTest;

    try writeFileLibc(IN, "cherry\nbanana\napple\n");
    const zo = "/tmp/zsort_parity_o_z.txt";
    const go = "/tmp/zsort_parity_o_g.txt";
    const zstdout = "/tmp/zsort_parity_o_stdout.txt";

    const script = try std.fmt.allocPrintSentinel(alloc,
        \\export LC_ALL=C
        \\'{s}' -o '{s}' '{s}' > '{s}' 2>/dev/null
        \\'{s}' -o '{s}' '{s}' 2>/dev/null
        \\cmp -s '{s}' '{s}' || exit 1
        \\test ! -s '{s}'
    , .{ ZSORT, zo, IN, zstdout, gsort, go, IN, zo, go, zstdout }, 0);
    defer alloc.free(script);

    try std.testing.expectEqual(@as(u8, 0), wexit(system(script.ptr)));
}

// GNU: a nonexistent input file => diagnostic on stderr and exit status 2.
test "gnu behavior: missing file exits 2 with diagnostic" {
    const alloc = std.testing.allocator;
    const script = try std.fmt.allocPrintSentinel(alloc,
        \\'{s}' /tmp/zsort_definitely_missing_xyz_12345 2>/tmp/zsort_parity_err.txt
        \\test $? -eq 2 && test -s /tmp/zsort_parity_err.txt
    , .{ZSORT}, 0);
    defer alloc.free(script);
    try std.testing.expectEqual(@as(u8, 0), wexit(system(script.ptr)));
}

// GNU: an unrecognized option => diagnostic on stderr and exit status 2.
test "gnu behavior: unknown option exits 2" {
    const alloc = std.testing.allocator;
    const long = try std.fmt.allocPrintSentinel(alloc, "'{s}' --bogus-option 2>/dev/null; test $? -eq 2", .{ZSORT}, 0);
    defer alloc.free(long);
    try std.testing.expectEqual(@as(u8, 0), wexit(system(long.ptr)));

    const short = try std.fmt.allocPrintSentinel(alloc, "'{s}' -Q 2>/dev/null; test $? -eq 2", .{ZSORT}, 0);
    defer alloc.free(short);
    try std.testing.expectEqual(@as(u8, 0), wexit(system(short.ptr)));
}

// GNU: --help and --version go to STDOUT with exit status 0.
test "gnu behavior: --help/--version to stdout, exit 0" {
    const alloc = std.testing.allocator;
    const h = try std.fmt.allocPrintSentinel(alloc,
        \\'{s}' --help > /tmp/zsort_parity_help.txt 2>/dev/null
        \\test $? -eq 0 && test -s /tmp/zsort_parity_help.txt
    , .{ZSORT}, 0);
    defer alloc.free(h);
    try std.testing.expectEqual(@as(u8, 0), wexit(system(h.ptr)));

    const v = try std.fmt.allocPrintSentinel(alloc,
        \\'{s}' --version > /tmp/zsort_parity_ver.txt 2>/dev/null
        \\test $? -eq 0 && test -s /tmp/zsort_parity_ver.txt
    , .{ZSORT}, 0);
    defer alloc.free(v);
    try std.testing.expectEqual(@as(u8, 0), wexit(system(v.ptr)));
}

// -c check mode: exit 0 on sorted input, 1 on unsorted. Anchored to gsort's own
// -c exit status on the same inputs.
test "gnu parity: -c exit status matches gsort" {
    const alloc = std.testing.allocator;
    const gsort = findGsort() orelse return error.SkipZigTest;

    const inputs = [_][]const u8{ "apple\nbanana\ncherry\n", "cherry\napple\nbanana\n" };
    for (inputs) |inp| {
        try writeFileLibc(IN, inp);
        // Compare the two exit codes numerically.
        const script = try std.fmt.allocPrintSentinel(alloc,
            \\'{s}' -c '{s}' 2>/dev/null; z=$?
            \\'{s}' -c '{s}' 2>/dev/null; g=$?
            \\test "$z" -eq "$g"
        , .{ ZSORT, IN, gsort, IN }, 0);
        defer alloc.free(script);
        try std.testing.expectEqual(@as(u8, 0), wexit(system(script.ptr)));
    }
}
