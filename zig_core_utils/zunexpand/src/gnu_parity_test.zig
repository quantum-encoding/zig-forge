//! GNU-parity tests for zunexpand.
//!
//! EXTERNAL ANCHOR: these tests compare zunexpand's byte-for-byte output (and
//! exit codes) against the real GNU `unexpand` binary (GNU coreutils 9.10) when
//! it is installed, and against literal expected bytes captured from that same
//! GNU binary when it is not. No roundtrip tests — every expectation originates
//! from GNU / documented POSIX behavior, not from zunexpand itself.
//!
//! The built zunexpand path is injected by build.zig via `build_options`.

const std = @import("std");
const build_options = @import("build_options");

const ZUNEXPAND = build_options.zunexpand_path;
const io = std.testing.io;

const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/unexpand",
    "/opt/homebrew/bin/gunexpand",
    "/usr/local/opt/coreutils/libexec/gnubin/unexpand",
};

fn findGnu(alloc: std.mem.Allocator) ?[]const u8 {
    for (GNU_CANDIDATES) |c| {
        const res = std.process.run(alloc, io, .{ .argv = &.{ c, "--version" } }) catch continue;
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        if (std.mem.indexOf(u8, res.stdout, "GNU coreutils") != null) return c;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn free(self: RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

fn runArgv(alloc: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

/// A temp file holding `input`, whose absolute path can be passed to a child.
const InputFile = struct {
    td: std.testing.TmpDir,
    path: []u8,

    fn create(alloc: std.mem.Allocator, input: []const u8) !InputFile {
        var td = std.testing.tmpDir(.{});
        errdefer td.cleanup();
        try td.dir.writeFile(io, .{ .sub_path = "in", .data = input });
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const path = try std.fmt.allocPrint(alloc, "{s}/.zig-cache/tmp/{s}/in", .{ cwd, td.sub_path });
        return .{ .td = td, .path = path };
    }

    fn deinit(self: *InputFile, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.td.cleanup();
    }
};

/// Run `bin` with `flags` on an input file whose contents are `input`.
fn runOnFile(alloc: std.mem.Allocator, bin: []const u8, flags: []const []const u8, input: []const u8) !RunResult {
    var f = try InputFile.create(alloc, input);
    defer f.deinit(alloc);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (flags) |fl| try argv.append(alloc, fl);
    try argv.append(alloc, f.path);

    return runArgv(alloc, argv.items);
}

// ---------------------------------------------------------------------------
// 1. Literal vectors captured from GNU coreutils 9.10 `unexpand`.
//    These pin the exact bytes so the anchor holds even without a GNU binary.
// ---------------------------------------------------------------------------

const Vector = struct { flags: []const []const u8, input: []const u8, expected: []const u8 };

const LITERAL_VECTORS = [_]Vector{
    // default: leading 8 spaces -> one tab (tab stop 8)
    .{ .flags = &.{}, .input = "        x", .expected = "\tx" },
    // default: a maximal leading blank run mixing spaces + a tab collapses.
    // (finding #2 — blank runs are merged across tabs)
    .{ .flags = &.{}, .input = "   \thi", .expected = "\thi" },
    // default: mixed leading blanks collapse to two tabs
    .{ .flags = &.{}, .input = "\t  \tx", .expected = "\t\tx" },
    // default: internal blanks are NOT touched
    .{ .flags = &.{}, .input = "   a   b", .expected = "   a   b" },
    // -a: internal blank run spanning a tab is re-tabified (finding #2)
    .{ .flags = &.{"-a"}, .input = "a  \t  b", .expected = "a\t  b" },
    .{ .flags = &.{"-a"}, .input = "a   \tb", .expected = "a\tb" },
    // -a: two spaces reaching a tab stop -> tab; a lone space never converts
    .{ .flags = &.{"-a"}, .input = "aaaaaa  x", .expected = "aaaaaa\tx" },
    .{ .flags = &.{"-a"}, .input = "aaaaaaa x", .expected = "aaaaaaa x" },
    .{ .flags = &.{"-a"}, .input = "aaaaaaa  x", .expected = "aaaaaaa\t x" },
    // -a: single interior space unchanged, two unreachable spaces unchanged
    .{ .flags = &.{"-a"}, .input = "a b", .expected = "a b" },
    .{ .flags = &.{"-a"}, .input = "a  b", .expected = "a  b" },
    // -t implies -a and sets the tab stops (finding #1)
    .{ .flags = &.{"-t2,4,6"}, .input = "x    y    z", .expected = "x\t\t y    z" },
    .{ .flags = &.{"-t4"}, .input = "x       y", .expected = "x\t\ty" },
    // -t with an explicit finite list: no tab stops past the last (col 6)
    .{ .flags = &.{"-t2,4,6"}, .input = "aaaaaaaa    z", .expected = "aaaaaaaa    z" },
    // -t4 past-stops trailing spaces
    .{ .flags = &.{"-t4"}, .input = "abcdefghij        z", .expected = "abcdefghij\t\t  z" },
    // trailing blanks that cannot reach a stop stay put
    .{ .flags = &.{"-a"}, .input = "ab   ", .expected = "ab   " },
    // a bare tab already on a stop is preserved
    .{ .flags = &.{"-a"}, .input = "a\tb", .expected = "a\tb" },
};

test "literal GNU 9.10 vectors" {
    const alloc = std.testing.allocator;
    for (LITERAL_VECTORS, 0..) |v, idx| {
        const r = try runOnFile(alloc, ZUNEXPAND, v.flags, v.input);
        defer r.free(alloc);
        std.testing.expectEqualStrings(v.expected, r.stdout) catch |e| {
            std.debug.print("literal vector #{d} (flags[0]={s}) FAILED\n", .{ idx, if (v.flags.len > 0) v.flags[0] else "<none>" });
            return e;
        };
        try std.testing.expectEqual(@as(u8, 0), r.code);
    }
}

test "final newline preservation" {
    const alloc = std.testing.allocator;
    {
        const r = try runOnFile(alloc, ZUNEXPAND, &.{}, "        a\n        b\n");
        defer r.free(alloc);
        try std.testing.expectEqualStrings("\ta\n\tb\n", r.stdout);
    }
    {
        const r = try runOnFile(alloc, ZUNEXPAND, &.{}, "        a\n        b");
        defer r.free(alloc);
        try std.testing.expectEqualStrings("\ta\n\tb", r.stdout);
    }
}

// ---------------------------------------------------------------------------
// 2. Differential fuzz vs the real GNU binary (skipped if none installed).
//    Exhaustively enumerate every string over {space, tab, 'x'} up to length 5
//    and assert identical output under several flag sets.
// ---------------------------------------------------------------------------

fn diffCase(alloc: std.mem.Allocator, gnu: []const u8, flags: []const []const u8, input: []const u8) !void {
    const a = try runOnFile(alloc, ZUNEXPAND, flags, input);
    defer a.free(alloc);
    const b = try runOnFile(alloc, gnu, flags, input);
    defer b.free(alloc);
    std.testing.expectEqualStrings(b.stdout, a.stdout) catch |e| {
        std.debug.print("DIFF flags[0]={s} input.len={d}\n", .{ if (flags.len > 0) flags[0] else "<none>", input.len });
        return e;
    };
    try std.testing.expectEqual(b.code, a.code);
}

test "differential vs GNU unexpand (exhaustive small strings)" {
    const alloc = std.testing.allocator;
    const gnu = findGnu(alloc) orelse return error.SkipZigTest;

    const alphabet = [_]u8{ ' ', '\t', 'x' };
    const flag_sets = [_][]const []const u8{
        &.{},
        &.{"-a"},
        &.{"--first-only"},
        &.{"-t3"},
        &.{"-t2,4,6"},
    };

    var buf: [5]u8 = undefined;
    var len: usize = 0;
    while (len <= 5) : (len += 1) {
        const total = std.math.pow(usize, alphabet.len, len);
        var n: usize = 0;
        while (n < total) : (n += 1) {
            var rem = n;
            var k: usize = 0;
            while (k < len) : (k += 1) {
                buf[k] = alphabet[rem % alphabet.len];
                rem /= alphabet.len;
            }
            const input = buf[0..len];
            for (flag_sets) |fs| {
                try diffCase(alloc, gnu, fs, input);
            }
        }
    }
}

test "differential vs GNU unexpand (multi-line + backspace)" {
    const alloc = std.testing.allocator;
    const gnu = findGnu(alloc) orelse return error.SkipZigTest;

    const inputs = [_][]const u8{
        "        a\n        b\n",
        "        a\n        b", // no final newline
        "\t   \tx\n  y  \n",
        "ab\x08   cd", // backspace then spaces
        "\n\n        z\n",
        "",
    };
    const flag_sets = [_][]const []const u8{ &.{}, &.{"-a"}, &.{"-t4"} };
    for (inputs) |in| {
        for (flag_sets) |fs| {
            try diffCase(alloc, gnu, fs, in);
        }
    }
}

// ---------------------------------------------------------------------------
// 3. Error / exit-code parity: directory arg, missing file, invalid -t.
// ---------------------------------------------------------------------------

test "directory argument errors with exit 1 and real errno" {
    const alloc = std.testing.allocator;
    var f = try InputFile.create(alloc, "");
    defer f.deinit(alloc);
    // Point at the containing tmp directory itself (a directory, not the file).
    const dpath = std.fs.path.dirname(f.path).?;

    const r = try runArgv(alloc, &.{ ZUNEXPAND, dpath });
    defer r.free(alloc);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    // real errno surfaced, not a hardcoded "No such file or directory"
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Is a directory") != null);
}

test "missing file errors with exit 1 and correct errno text" {
    const alloc = std.testing.allocator;
    const r = try runArgv(alloc, &.{ ZUNEXPAND, "/no/such/path/zzz" });
    defer r.free(alloc);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
}

test "invalid -t argument errors with exit 1" {
    const alloc = std.testing.allocator;
    {
        const r = try runOnFile(alloc, ZUNEXPAND, &.{ "-t", "abc" }, "x  y");
        defer r.free(alloc);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expectEqualStrings("", r.stdout);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "tab size") != null);
    }
    {
        const r = try runOnFile(alloc, ZUNEXPAND, &.{"-t0"}, "x  y");
        defer r.free(alloc);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot be 0") != null);
    }
}

test "error parity vs GNU (exit codes match)" {
    const alloc = std.testing.allocator;
    const gnu = findGnu(alloc) orelse return error.SkipZigTest;

    {
        const a = try runArgv(alloc, &.{ ZUNEXPAND, "/no/such/path/zzz" });
        defer a.free(alloc);
        const b = try runArgv(alloc, &.{ gnu, "/no/such/path/zzz" });
        defer b.free(alloc);
        try std.testing.expectEqual(b.code, a.code);
    }
    {
        const a = try runOnFile(alloc, ZUNEXPAND, &.{ "-t", "abc" }, "x  y");
        defer a.free(alloc);
        const b = try runOnFile(alloc, gnu, &.{ "-t", "abc" }, "x  y");
        defer b.free(alloc);
        try std.testing.expectEqual(b.code, a.code);
        try std.testing.expectEqualStrings(b.stdout, a.stdout); // both empty
    }
}
