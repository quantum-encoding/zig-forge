//! Externally-anchored parity tests for zjq (a jq work-alike).
//!
//! The primary anchor is the real `jq` binary (jq 1.8.1, Homebrew): every case
//! below runs the SAME argv against both `zjq` and `jq` and asserts the stdout
//! bytes AND the process exit code match. jq is a third-party implementation
//! zjq's authors did not write, so this is a true external anchor — not a
//! roundtrip. See zig-forge/CLAUDE.md "golden rule" §1.
//!
//! When no jq binary is present, the suite falls back to `literal_cases`, whose
//! expected bytes/exit-codes were transcribed from jq 1.8.1's actual output
//! (captured while writing these tests) and from jq's documented exit-code
//! taxonomy (jq manual: 0 ok, 1 = -e null/false, 2 usage, 3 compile error,
//! 4 = -e no output, 5 = parse/runtime error).
//!
//! Every case writes `input` to a fixture file and runs `flags ++ [filter,
//! "in.json"]`, so no stdin plumbing is needed (jq and zjq both read a file
//! argument identically).
//!
//! The zjq binary under test is handed in by build.zig via build_options.zjq_bin.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const io = std.testing.io;

const jq_candidates = [_][]const u8{
    "/opt/homebrew/bin/jq",
    "/usr/local/bin/jq",
    "/usr/bin/jq",
};

fn findJq() ?[]const u8 {
    for (jq_candidates) |p| {
        Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 sentinel for signal/abnormal termination
};

fn runIn(
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    bin: []const u8,
    args: []const []const u8,
) !RunOut {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (args) |a| try argv.append(gpa, a);

    const r = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
    });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .code = code };
}

const zbin = build_options.zjq_bin;

const Case = struct {
    name: []const u8,
    flags: []const []const u8 = &.{}, // e.g. {"-c"}, {"-S"}, {"-e"}
    filter: []const u8,
    input: []const u8,
};

// Cases chosen to exercise the audit's fixed findings AND core surface:
//   - jsonEqual on composites (unique / == / group_by / contains)
//   - add mixed int+float
//   - .[-0] negative-zero out-of-bounds
//   - length of a fractional number (no i64 truncation)
//   - flatten (deep) vs flatten(n)
//   - -S sort-keys (recursive), -R raw-input, -e exit-status
//   - error exit codes (parse -> 5, compile -> 3)
const cases = [_]Case{
    // --- core identity / access ---
    .{ .name = "identity-pretty", .filter = ".", .input = "{\"b\":1,\"a\":2}" },
    .{ .name = "identity-compact", .flags = &.{"-c"}, .filter = ".", .input = "{\"b\":1,\"a\":2}" },
    .{ .name = "field", .filter = ".name", .input = "{\"name\":\"x\",\"age\":5}" },
    .{ .name = "iterate", .filter = ".[]", .input = "[1,2,3]" },
    .{ .name = "index", .filter = ".[1]", .input = "[10,20,30]" },
    .{ .name = "index-neg1", .filter = ".[-1]", .input = "[10,20,30]" },
    .{ .name = "nested", .filter = ".a.b.c", .input = "{\"a\":{\"b\":{\"c\":7}}}" },
    // --- FIX: negative-zero index (was OOB read arr[len]) ---
    .{ .name = "index-neg0", .flags = &.{"-c"}, .filter = ".[-0]", .input = "[1,2,3]" },
    // --- FIX: length of fractional/large number must not truncate to i64 ---
    .{ .name = "length-frac", .filter = "length", .input = "2.5" },
    .{ .name = "length-array", .filter = "length", .input = "[1,2,3,4]" },
    .{ .name = "length-string", .filter = "length", .input = "\"hello\"" },
    // --- FIX: add mixed int+float (was double-counting -> 9) ---
    .{ .name = "add-mixed", .filter = "add", .input = "[1,2.5,3]" },
    .{ .name = "add-ints", .filter = "add", .input = "[1,2,3]" },
    .{ .name = "add-empty", .filter = "add", .input = "[]" },
    // --- FIX: jsonEqual on composites (unique / == / group_by) ---
    .{ .name = "unique-nested-arrays", .flags = &.{"-c"}, .filter = "unique", .input = "[[1],[1]]" },
    .{ .name = "unique-dups", .flags = &.{"-c"}, .filter = "unique", .input = "[1,1,2,3,3]" },
    .{ .name = "eq-arrays", .flags = &.{"-c"}, .filter = ".[0]==.[1]", .input = "[[1,2],[1,2]]" },
    .{ .name = "eq-arrays-ne", .flags = &.{"-c"}, .filter = ".[0]==.[1]", .input = "[[1,2],[1,3]]" },
    .{ .name = "eq-objects", .flags = &.{"-c"}, .filter = ".[0]==.[1]", .input = "[{\"a\":1},{\"a\":1}]" },
    .{ .name = "group-by", .flags = &.{"-c"}, .filter = "group_by(.k)", .input = "[{\"k\":1,\"v\":\"a\"},{\"k\":2,\"v\":\"b\"},{\"k\":1,\"v\":\"c\"}]" },
    // --- FIX: flatten deep vs flatten(n) ---
    .{ .name = "flatten-deep", .flags = &.{"-c"}, .filter = "flatten", .input = "[1,[2,[3]]]" },
    .{ .name = "flatten-depth1", .flags = &.{"-c"}, .filter = "flatten(1)", .input = "[1,[2,[3,[4]]]]" },
    // --- FIX: -S sort-keys, recursive ---
    .{ .name = "sort-keys-pretty", .flags = &.{"-S"}, .filter = ".", .input = "{\"b\":1,\"a\":2}" },
    .{ .name = "sort-keys-compact", .flags = &.{ "-c", "-S" }, .filter = ".", .input = "{\"b\":1,\"a\":2}" },
    .{ .name = "sort-keys-nested", .flags = &.{ "-c", "-S" }, .filter = ".", .input = "{\"b\":1,\"a\":{\"d\":1,\"c\":2}}" },
    // --- FIX: -R raw input ---
    .{ .name = "raw-input-single", .flags = &.{"-R"}, .filter = ".", .input = "hello world" },
    .{ .name = "raw-input-lines", .flags = &.{"-R"}, .filter = ".", .input = "a\nb\n" },
    .{ .name = "raw-input-blank-line", .flags = &.{ "-R", "-c" }, .filter = ".", .input = "a\n\nb\n" },
    .{ .name = "raw-input-slurp", .flags = &.{ "-R", "-s" }, .filter = ".", .input = "x y\nz\n" },
    // --- common builtins ---
    .{ .name = "keys", .flags = &.{"-c"}, .filter = "keys", .input = "{\"b\":1,\"a\":2}" },
    .{ .name = "sort", .flags = &.{"-c"}, .filter = "sort", .input = "[3,1,2]" },
    .{ .name = "map-inc", .flags = &.{"-c"}, .filter = "map(.+1)", .input = "[1,2,3]" },
    .{ .name = "to-entries", .flags = &.{"-c"}, .filter = "to_entries", .input = "{\"a\":1}" },
    .{ .name = "min", .filter = "min", .input = "[5,3,8,1]" },
    .{ .name = "max", .filter = "max", .input = "[5,3,8,1]" },
    .{ .name = "has", .filter = "has(\"a\")", .input = "{\"a\":1,\"b\":2}" },
    .{ .name = "raw-output", .flags = &.{"-r"}, .filter = ".name", .input = "{\"name\":\"bob\"}" },
    // --- -e exit-status parity (stdout + code both checked) ---
    .{ .name = "exit-status-null", .flags = &.{"-e"}, .filter = ".", .input = "null" },
    .{ .name = "exit-status-false", .flags = &.{"-e"}, .filter = ".", .input = "false" },
    .{ .name = "exit-status-true", .flags = &.{"-e"}, .filter = ".", .input = "true" },
    .{ .name = "exit-status-number", .flags = &.{"-e"}, .filter = ".", .input = "1" },
    .{ .name = "exit-status-no-output", .flags = &.{"-e"}, .filter = ".[]", .input = "[]" },
    // --- error exit-code parity ---
    .{ .name = "parse-error", .filter = ".", .input = "{bad" },
    .{ .name = "parse-error-truncated", .filter = ".", .input = "[1,2" },
    .{ .name = "compile-error", .filter = ".[", .input = "1" },
};

test "parity against real jq (stdout + exit code)" {
    const jq = findJq() orelse {
        std.debug.print("SKIP: no jq found; literal-byte anchors still run below\n", .{});
        return error.SkipZigTest;
    };
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var failures: usize = 0;
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.json", .data = c.input });

        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        for (c.flags) |f| try args.append(gpa, f);
        try args.append(gpa, c.filter);
        try args.append(gpa, "in.json");

        const zr = try runIn(gpa, tmp.dir, zbin, args.items);
        defer gpa.free(zr.stdout);
        defer gpa.free(zr.stderr);
        const jr = try runIn(gpa, tmp.dir, jq, args.items);
        defer gpa.free(jr.stdout);
        defer gpa.free(jr.stderr);

        if (!std.mem.eql(u8, zr.stdout, jr.stdout) or zr.code != jr.code) {
            failures += 1;
            std.debug.print(
                "MISMATCH [{s}]: exit z={d} j={d}\n  zjq stdout: {s}\n  jq  stdout: {s}\n",
                .{ c.name, zr.code, jr.code, zr.stdout, jr.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// --- Literal-byte anchors (survive even when no jq binary is installed) ------
// Expected bytes/exit-codes transcribed from jq 1.8.1's observed output and its
// documented exit-code taxonomy. These are NOT roundtrips: the expected bytes
// are written out explicitly, independent of zjq's own code.

const LiteralCase = struct {
    name: []const u8,
    flags: []const []const u8 = &.{},
    filter: []const u8,
    input: []const u8,
    expect_stdout: []const u8,
    expect_code: u8,
};

const literal_cases = [_]LiteralCase{
    // .[-0] == .[0] (jq): first element, NOT an out-of-bounds read of arr[len].
    .{ .name = "neg0", .flags = &.{"-c"}, .filter = ".[-0]", .input = "[1,2,3]", .expect_stdout = "1\n", .expect_code = 0 },
    // add over mixed int+float: 1 + 2.5 + 3 = 6.5 (not 9).
    .{ .name = "add-mixed", .filter = "add", .input = "[1,2.5,3]", .expect_stdout = "6.5\n", .expect_code = 0 },
    // length of a fractional number is its absolute value, preserved as a number.
    .{ .name = "length-frac", .filter = "length", .input = "2.5", .expect_stdout = "2.5\n", .expect_code = 0 },
    // unique dedups structurally-equal nested arrays to one element.
    .{ .name = "unique-nested", .flags = &.{"-c"}, .filter = "unique", .input = "[[1],[1]]", .expect_stdout = "[[1]]\n", .expect_code = 0 },
    // == is true for structurally-equal arrays.
    .{ .name = "eq-arrays", .flags = &.{"-c"}, .filter = ".[0]==.[1]", .input = "[[1,2],[1,2]]", .expect_stdout = "true\n", .expect_code = 0 },
    // bare flatten flattens ALL levels.
    .{ .name = "flatten-deep", .flags = &.{"-c"}, .filter = "flatten", .input = "[1,[2,[3]]]", .expect_stdout = "[1,2,3]\n", .expect_code = 0 },
    // -S sorts object keys ascending by byte order.
    .{ .name = "sort-keys", .flags = &.{ "-c", "-S" }, .filter = ".", .input = "{\"b\":1,\"a\":2}", .expect_stdout = "{\"a\":2,\"b\":1}\n", .expect_code = 0 },
    // -R: a line of text becomes a JSON string.
    .{ .name = "raw-input", .flags = &.{"-R"}, .filter = ".", .input = "hello world", .expect_stdout = "\"hello world\"\n", .expect_code = 0 },
    // -R over two newline-terminated lines -> two JSON strings.
    .{ .name = "raw-lines", .flags = &.{"-R"}, .filter = ".", .input = "a\nb\n", .expect_stdout = "\"a\"\n\"b\"\n", .expect_code = 0 },
    // -e with a null last output -> exit 1, output still printed.
    .{ .name = "exit-null", .flags = &.{"-e"}, .filter = ".", .input = "null", .expect_stdout = "null\n", .expect_code = 1 },
    // -e with false last output -> exit 1.
    .{ .name = "exit-false", .flags = &.{"-e"}, .filter = ".", .input = "false", .expect_stdout = "false\n", .expect_code = 1 },
    // -e with a truthy last output -> exit 0.
    .{ .name = "exit-true", .flags = &.{"-e"}, .filter = ".", .input = "true", .expect_stdout = "true\n", .expect_code = 0 },
    // -e with no output at all -> exit 4.
    .{ .name = "exit-none", .flags = &.{"-e"}, .filter = ".[]", .input = "[]", .expect_stdout = "", .expect_code = 4 },
    // malformed JSON -> parse error, exit 5, no stdout.
    .{ .name = "parse-error", .filter = ".", .input = "{bad", .expect_stdout = "", .expect_code = 5 },
    // uncompilable filter -> compile error, exit 3, no stdout.
    .{ .name = "compile-error", .filter = ".[", .input = "1", .expect_stdout = "", .expect_code = 3 },
};

test "literal-byte anchors (jq 1.8.1 observed output + documented exit codes)" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var failures: usize = 0;
    for (literal_cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.json", .data = c.input });

        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        for (c.flags) |f| try args.append(gpa, f);
        try args.append(gpa, c.filter);
        try args.append(gpa, "in.json");

        const zr = try runIn(gpa, tmp.dir, zbin, args.items);
        defer gpa.free(zr.stdout);
        defer gpa.free(zr.stderr);

        if (!std.mem.eql(u8, c.expect_stdout, zr.stdout) or c.expect_code != zr.code) {
            failures += 1;
            std.debug.print(
                "LITERAL MISMATCH [{s}]: exit want={d} got={d}\n  want stdout: {s}\n  zjq  stdout: {s}\n",
                .{ c.name, c.expect_code, zr.code, c.expect_stdout, zr.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
