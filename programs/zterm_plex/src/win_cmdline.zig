//! The pure half of starting a program on Windows: the command line the
//! Microsoft C runtime parses back into argv, the CreateProcessW environment
//! block, and an exit code as a POSIX-shaped status. No Win32 calls, so the
//! tests run on every platform; pty_windows.zig is the caller.

const std = @import("std");

/// How a program ended, POSIX-shaped. Windows has exit codes only: `code` is
/// the exit code when it fits a byte, 255 when it does not (an NTSTATUS such
/// as an access violation), and `signal` is 2 for STATUS_CONTROL_C_EXIT.
pub const ExitStatus = struct {
    code: u8 = 0,
    signal: u8 = 0,
};

/// A Windows exit code as the POSIX-shaped status the rest of zterm reports.
pub fn decodeExitCode(code: u32) ExitStatus {
    if (code <= 255) return .{ .code = @intCast(code) };
    if (code == 0xC000013A) return .{ .signal = 2 }; // STATUS_CONTROL_C_EXIT
    return .{ .code = 255 };
}

pub fn isBatchFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat");
}

/// The command line the Microsoft C runtime parses back into `argv`.
/// argv[0] follows the program-name rule (quoted whole, no escapes, so it may
/// not contain a quote); every other argument is quoted when it is empty or
/// holds whitespace or a quote, with backslashes doubled only where they
/// precede a quote.
pub fn commandLine(a: std.mem.Allocator, argv: [*:null]const ?[*:0]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (argv[i]) |arg_z| : (i += 1) {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (i > 0) try out.append(a, ' ');
        if (i == 0) {
            if (std.mem.indexOfScalar(u8, arg, '"') != null) return error.InvalidProgramName;
            const q = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t") != null;
            if (q) try out.append(a, '"');
            try out.appendSlice(a, arg);
            if (q) try out.append(a, '"');
            continue;
        }
        try appendQuoted(&out, a, arg);
    }
    return out.toOwnedSlice(a);
}

fn appendQuoted(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    const needs = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs) return out.appendSlice(a, arg);
    try out.append(a, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        if (ch == '"') {
            try out.appendNTimes(a, '\\', backslashes * 2 + 1);
        } else {
            try out.appendNTimes(a, '\\', backslashes);
        }
        backslashes = 0;
        try out.append(a, ch);
    }
    try out.appendNTimes(a, '\\', backslashes * 2);
    try out.append(a, '"');
}

/// The name part of a "NAME=value" entry. Names may begin with '=' (cmd.exe's
/// per-drive "=C:=C:\dir" entries), so the separator is searched from 1.
fn envName(entry: []const u8) []const u8 {
    if (entry.len <= 1) return entry;
    const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse return entry;
    return entry[0..eq];
}

fn lessIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(envName(lhs), envName(rhs));
}

/// A CreateProcessW environment block from POSIX-shaped "NAME=value" entries:
/// one entry per name — the LAST occurrence wins, matching how the callers
/// append overrides after inherited entries — sorted case-insensitively by
/// name as Windows expects, UTF-16, double-NUL terminated.
pub fn environmentBlock(a: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) ![:0]u16 {
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(a);
    var i: usize = 0;
    while (envp[i]) |e| : (i += 1) {
        const s = std.mem.sliceTo(e, 0);
        if (s.len == 0 or std.mem.indexOfScalarPos(u8, s, @min(1, s.len), '=') == null) continue;
        // Drop any earlier entry with this name: the later one wins.
        var j: usize = 0;
        while (j < entries.items.len) {
            if (std.ascii.eqlIgnoreCase(envName(entries.items[j]), envName(s))) {
                _ = entries.orderedRemove(j);
            } else j += 1;
        }
        try entries.append(a, s);
    }
    std.mem.sort([]const u8, entries.items, {}, lessIgnoreCase);

    var block: std.ArrayList(u16) = .empty;
    errdefer block.deinit(a);
    for (entries.items) |s| {
        const w = try std.unicode.utf8ToUtf16LeAlloc(a, s);
        defer a.free(w);
        try block.appendSlice(a, w);
        try block.append(a, 0);
    }
    if (entries.items.len == 0) try block.append(a, 0);
    return block.toOwnedSliceSentinel(a, 0);
}


// ── tests (every platform) ───────────────────────────────────────────────────
//
// DRIFT LOCKS: the expected strings below are this encoder's own output,
// pinned so a change is seen. The external anchor for the quoting is the
// CommandLineToArgvW test in pty_windows.zig, and for the environment block
// the cmd.exe test beside it; both run on Windows.

const testing = std.testing;

fn lineOf(args: []const [*:0]const u8) ![]u8 {
    var argv: [8:null]?[*:0]const u8 = @splat(null);
    for (args, 0..) |a, i| argv[i] = a;
    return commandLine(testing.allocator, &argv);
}

test "commandLine quotes only what needs it (drift lock)" {
    const cases = [_]struct { args: []const [*:0]const u8, want: []const u8 }{
        .{ .args = &.{ "C:\\bin\\claude.exe", "--brief", "fix it" }, .want = "C:\\bin\\claude.exe --brief \"fix it\"" },
        .{ .args = &.{ "C:\\Program Files\\x.exe", "a" }, .want = "\"C:\\Program Files\\x.exe\" a" },
        .{ .args = &.{ "p.exe", "" }, .want = "p.exe \"\"" },
        .{ .args = &.{ "p.exe", "ab\"c" }, .want = "p.exe \"ab\\\"c\"" },
        .{ .args = &.{ "p.exe", "a\\\\b c" }, .want = "p.exe \"a\\\\b c\"" },
        .{ .args = &.{ "p.exe", "end\\ " }, .want = "p.exe \"end\\ \"" },
        .{ .args = &.{ "p.exe", "x y\\" }, .want = "p.exe \"x y\\\\\"" },
        .{ .args = &.{ "p.exe", "a\\b" }, .want = "p.exe a\\b" },
    };
    for (cases) |cs| {
        const got = try lineOf(cs.args);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(cs.want, got);
    }
}

test "commandLine refuses a program name holding a quote" {
    try testing.expectError(error.InvalidProgramName, lineOf(&.{"C:\\a\"b.exe"}));
}

test "environmentBlock: one entry per name, the last wins, sorted, double-NUL (drift lock)" {
    const envp = [_:null]?[*:0]const u8{ "b=2", "A=1", "=C:=C:\\w", "PATH=x", "a=3", "junk", "Path=y" };
    const block = try environmentBlock(testing.allocator, &envp);
    defer testing.allocator.free(block);
    const want = std.unicode.utf8ToUtf16LeStringLiteral("=C:=C:\\w\x00a=3\x00b=2\x00Path=y\x00");
    try testing.expectEqualSlices(u16, want, block);
    try testing.expectEqual(@as(u16, 0), block.ptr[block.len]);
}

test "environmentBlock of nothing is a valid empty block" {
    const envp = [_:null]?[*:0]const u8{};
    const block = try environmentBlock(testing.allocator, &envp);
    defer testing.allocator.free(block);
    try testing.expectEqualSlices(u16, &.{0}, block);
    try testing.expectEqual(@as(u16, 0), block.ptr[block.len]);
}

test "decodeExitCode: a byte as the code, an NTSTATUS as 255, Ctrl-C as signal 2" {
    try testing.expectEqual(ExitStatus{ .code = 7 }, decodeExitCode(7));
    try testing.expectEqual(ExitStatus{ .code = 255 }, decodeExitCode(255));
    try testing.expectEqual(ExitStatus{ .code = 255 }, decodeExitCode(0xC0000005));
    try testing.expectEqual(ExitStatus{ .signal = 2 }, decodeExitCode(0xC000013A));
}

test "isBatchFile: .cmd and .bat in any case, nothing else" {
    try testing.expect(isBatchFile("C:\\x\\claude.cmd"));
    try testing.expect(isBatchFile("C:\\x\\RUN.BAT"));
    try testing.expect(!isBatchFile("C:\\x\\claude.exe"));
    try testing.expect(!isBatchFile("C:\\x\\cmd"));
}
