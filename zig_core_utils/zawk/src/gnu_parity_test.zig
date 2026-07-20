//! Externally-anchored parity tests for zawk.
//!
//! ANCHOR: every `expectSameAsAwk` case runs the SAME program+flags+input
//! through BOTH the freshly-built `zawk` binary AND the host's real `awk`
//! (`/usr/bin/awk`, an independent third-party implementation this repo did
//! not write) and asserts byte-identical stdout. That is a true external
//! anchor per zig-forge/CLAUDE.md rule §1 — not a roundtrip. Cases are
//! restricted to POSIX behaviors where every conforming awk agrees, so the
//! anchor is the POSIX contract, cross-checked against a live reference impl.
//!
//! The `literalAnchor` cases additionally pin the exact bytes POSIX mandates
//! (e.g. `print 0` => "0\n") so they still bite if the reference binary is
//! absent. These two are the mutation-test targets (formatInt-zero and
//! unary-minus): reintroduce either bug and the literal assert goes RED.
//!
//! If `/usr/bin/awk` is missing the comparison cases SkipZigTest rather than
//! silently pass; the literal cases always run.

const std = @import("std");
const build_options = @import("build_options");

const ZAWK: []const u8 = build_options.zawk_exe;
const AWK: []const u8 = "/usr/bin/awk";
const io = std.testing.io;

fn awkAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, AWK, .{}) catch return false;
    return true;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    crashed: bool,
};

fn run(alloc: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    return switch (res.term) {
        .exited => |c| .{ .stdout = res.stdout, .stderr = res.stderr, .code = c, .crashed = false },
        else => .{ .stdout = res.stdout, .stderr = res.stderr, .code = 0, .crashed = true },
    };
}

/// Run `prog_args` (the awk program text plus any flags like -F, -v — but NOT
/// the binary name and NOT the input file) through both zawk and awk, feeding
/// `input` via a temp file, and assert identical stdout. zawk must also never
/// crash (segfault/abort), which pins the @intFromFloat-clamp fixes.
fn expectSameAsAwk(prog_args: []const []const u8, input: ?[]const u8) !void {
    if (!awkAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var input_path: ?[]const u8 = null;
    if (input) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = data });
        // tmpDir lives at .zig-cache/tmp/<sub_path>/ relative to the build root,
        // which is the child processes' inherited cwd; pass a relative path.
        input_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/in.txt", .{tmp.sub_path[0..]});
    }
    defer if (input_path) |p| alloc.free(p);

    var zargv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer zargv.deinit(alloc);
    var aargv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer aargv.deinit(alloc);

    try zargv.append(alloc, ZAWK);
    try aargv.append(alloc, AWK);
    for (prog_args) |a| {
        try zargv.append(alloc, a);
        try aargv.append(alloc, a);
    }
    if (input_path) |p| {
        try zargv.append(alloc, p);
        try aargv.append(alloc, p);
    }

    const zr = try run(alloc, zargv.items);
    defer alloc.free(zr.stdout);
    defer alloc.free(zr.stderr);
    const ar = try run(alloc, aargv.items);
    defer alloc.free(ar.stdout);
    defer alloc.free(ar.stderr);

    if (zr.crashed) {
        std.debug.print("zawk CRASHED on program: {s}\n", .{prog_args[0]});
        return error.ZawkCrashed;
    }
    if (!std.mem.eql(u8, zr.stdout, ar.stdout)) {
        std.debug.print(
            "PARITY MISMATCH\n  prog : {s}\n  zawk : \"{s}\"\n  awk  : \"{s}\"\n",
            .{ prog_args[0], zr.stdout, ar.stdout },
        );
        return error.OutputMismatch;
    }
}

/// POSIX-documented exact output, binary-independent (always runs).
fn literalAnchor(prog: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const zr = try run(alloc, &.{ ZAWK, prog });
    defer alloc.free(zr.stdout);
    defer alloc.free(zr.stderr);
    try std.testing.expect(!zr.crashed);
    try std.testing.expectEqualStrings(expected, zr.stdout);
}

// ---------------------------------------------------------------------------
// Mutation-test targets: exact POSIX bytes, independent of the reference awk.
// ---------------------------------------------------------------------------

test "literal: integer 0 prints ASCII '0' (formatInt zero-case)" {
    // POSIX: `awk 'BEGIN{print 0}'` writes "0\n". Reintroducing the
    // formatInt zero bug (buf[buf.len-1]='0') makes this emit a garbage byte.
    try literalAnchor("BEGIN{print 0}", "0\n");
}

test "literal: unary minus negates (0 - operand)" {
    // POSIX: `awk 'BEGIN{print -5}'` writes "-5\n". The operand-aliasing bug
    // made -x evaluate to x-x == 0, then the 0 hit the formatInt garbage path.
    try literalAnchor("BEGIN{print -5}", "-5\n");
}

test "literal: printf %c of numeric 65 is 'A'" {
    // POSIX printf: %c with a numeric arg is the character with that code.
    try literalAnchor("BEGIN{printf \"%c\\n\",65}", "A\n");
}

test "literal: printf %u of 0 is '0'" {
    try literalAnchor("BEGIN{printf \"%u\\n\",0}", "0\n");
}

// ---------------------------------------------------------------------------
// Reference-anchored parity: BEGIN-only programs.
// ---------------------------------------------------------------------------

test "parity: integer/negation/arithmetic" {
    try expectSameAsAwk(&.{"BEGIN{print 0}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print -5}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print 3-8, 2*4, 7%3, 10/4}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print -3*2, -(4+1)}"}, null);
}

test "parity: substr with clamped/huge/negative args" {
    try expectSameAsAwk(&.{"BEGIN{print substr(\"hello\",2,3)}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print substr(\"hello\",-2,3)}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print substr(\"hello\",2,1e20)}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print substr(\"hello\",2)}"}, null);
}

test "parity: printf %c numeric and string" {
    try expectSameAsAwk(&.{"BEGIN{printf \"%c\\n\",65}"}, null);
    try expectSameAsAwk(&.{"BEGIN{printf \"%c\\n\",\"hi\"}"}, null);
}

test "parity: sprintf honors its format string" {
    try expectSameAsAwk(&.{"BEGIN{print sprintf(\"%05.2f|%s|%d\",3.1,\"x\",42)}"}, null);
}

test "parity: printf integer conversions and width" {
    try expectSameAsAwk(&.{"BEGIN{printf \"%d %u %x %o\\n\",0,0,0,0}"}, null);
    try expectSameAsAwk(&.{"BEGIN{printf \"[%5d][%-5d][%05d]\\n\",42,42,42}"}, null);
}

test "parity: string builtins" {
    try expectSameAsAwk(&.{"BEGIN{print length(\"hello\")}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print index(\"hello\",\"ll\")}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print toupper(\"abc\"), tolower(\"XYZ\")}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print int(3.9), sqrt(16)}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print \"a\" \"b\" 1+2}"}, null);
}

test "parity: regex builtins" {
    try expectSameAsAwk(&.{"BEGIN{s=\"aaa\"; n=gsub(/a/,\"b\",s); print n, s}"}, null);
    try expectSameAsAwk(&.{"BEGIN{s=\"hello\"; sub(/l/,\"L\",s); print s}"}, null);
    try expectSameAsAwk(&.{"BEGIN{print match(\"foobar\",/bar/), RSTART, RLENGTH}"}, null);
    try expectSameAsAwk(&.{"BEGIN{n=split(\"a:b:c\",arr,\":\"); print n, arr[1], arr[3]}"}, null);
}

// ---------------------------------------------------------------------------
// Reference-anchored parity: record-processing programs (stdin -> temp file).
// ---------------------------------------------------------------------------

test "parity: field access and NF/NR" {
    try expectSameAsAwk(&.{"{print $1, $3}"}, "a b c\n");
    try expectSameAsAwk(&.{"{print NF}"}, "a b c\nd e\n");
    try expectSameAsAwk(&.{"{print NR, $0}"}, "x\ny\nz\n");
    try expectSameAsAwk(&.{"{print $NF}"}, "a b c d\n");
}

test "parity: computed field index" {
    try expectSameAsAwk(&.{"{print $(1+1)}"}, "a b c\n");
}

test "no-crash: out-of-range field index is clamped, not a SIGABRT" {
    // Critical finding: `$(1e20)` did @intFromFloat into usize with no upper
    // clamp and aborted (exit 134). BSD awk instead raises a fatal error; the
    // point of the fix is that zawk must NOT be killed by a signal. (This is a
    // known parity gap vs awk's fatal-error semantics — see remaining[].)
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "a b c\n" });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/in.txt", .{tmp.sub_path[0..]});
    defer alloc.free(path);

    const r = try run(alloc, &.{ ZAWK, "{print $(1e20)}", path });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expect(!r.crashed);
}

test "no-crash: substr with a non-finite/huge length is clamped, not a SIGABRT" {
    // Critical finding: substr(...,1e20) aborted via unchecked @intFromFloat.
    const alloc = std.testing.allocator;
    const r = try run(alloc, &.{ ZAWK, "BEGIN{print substr(\"hello\",2,1e20)}" });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expect(!r.crashed);
    try std.testing.expectEqualStrings("ello\n", r.stdout);
}

test "parity: field assignment and OFS rebuild" {
    try expectSameAsAwk(&.{ "{$2=\"X\"; print}" }, "a b c\n");
    try expectSameAsAwk(&.{"BEGIN{OFS=\"-\"}{$1=$1; print}"}, "a b c\n");
}

test "parity: accumulation ending at zero (formatInt zero path)" {
    try expectSameAsAwk(&.{"{s+=$1} END{print s}"}, "1\n2\n3\n");
    try expectSameAsAwk(&.{"{s+=$1} END{print s}"}, "5\n-5\n");
}

test "parity: -F and -v flags" {
    try expectSameAsAwk(&.{ "-F,", "{print $2}" }, "a,b,c\n");
    try expectSameAsAwk(&.{ "-v", "n=5", "{print n, $0}" }, "x\n");
}

test "parity: patterns and numeric field comparison" {
    try expectSameAsAwk(&.{"/e/{print}"}, "apple\nbee\n");
    try expectSameAsAwk(&.{"NR==2{print}"}, "a\nb\nc\n");
    try expectSameAsAwk(&.{"$1>2{print}"}, "3\n5\n1\n");
    try expectSameAsAwk(&.{"{print $1-$2}"}, "10 20\n");
}

test "parity: printf %c and gsub on records" {
    try expectSameAsAwk(&.{"{printf \"%c\\n\",$1+0}"}, "65\n");
    try expectSameAsAwk(&.{"{gsub(/X/,\"-\"); print}"}, "aXbXc\n");
    try expectSameAsAwk(&.{"{print tolower($0)}"}, "HELLO\n");
}
