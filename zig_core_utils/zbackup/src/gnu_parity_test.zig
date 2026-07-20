//! Externally-anchored tests for zbackup.
//!
//! ANCHOR NOTE: there is NO GNU `backup` coreutil (verified — neither
//! /opt/homebrew/opt/coreutils/libexec/gnubin/backup nor /opt/homebrew/bin/gbackup
//! exists), so there is no reference binary to diff against. These tests are
//! therefore anchored to *documented external specifications*, with the
//! expected values written literally (never derived by round-tripping
//! zbackup's own output):
//!
//!   - RFC 8259 (JSON): '{', '}' and keywords that appear INSIDE a JSON string
//!     value are ordinary characters, not structure. std.json is the stdlib's
//!     reference implementation of that grammar.
//!   - POSIX readlink(2): symlink target resolution.
//!   - zbackup's own documented status legend (>=90% pass, 50-90% warn,
//!     <50% fail — see the Legend line in `zbackup status`).

const std = @import("std");
const zb = @import("main.zig");
const testing = std.testing;

fn parse(json: []const u8) std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{ .allocate = .alloc_always },
    ) catch unreachable;
}

// RFC 8259: the '}' and the literal word "pass" that appear INSIDE the "note"
// string value are not structure. A correct parser must still read
// tests_passed=9, tests_total=10, status="fail". The old hand-rolled scanner
// (a) miscounted the in-string brace when bounding the object and (b)
// substring-matched "pass" before reaching "status":"fail", so it would have
// reported the wrong numbers and status=.pass. This is the primary anchor.
test "JSON: braces and keywords inside string values are not structural (RFC 8259)" {
    const json =
        \\{"utilities":{"zdemo":{"note":"contains a } brace and the word pass here","tests_passed":9,"tests_total":10,"status":"fail"}}}
    ;
    var p = parse(json);
    defer p.deinit();
    const r = zb.extractResultFromValue(p.value, "zdemo");
    try testing.expectEqual(@as(u32, 9), r.passed);
    try testing.expectEqual(@as(u32, 10), r.total);
    try testing.expect(r.status == .fail);
}

// Status must be an EXACT match on the status field, not a substring scan of
// the whole object. Here status is absent and total is 0 (so no percentage
// inference applies) -> .none. A decoy field says "all tests pass"; a
// substring scanner would wrongly report .pass.
test "JSON: status is exact-match, not substring (no false pass)" {
    const json =
        \\{"utilities":{"zx":{"message":"all tests pass","tests_passed":0,"tests_total":0}}}
    ;
    var p = parse(json);
    defer p.deinit();
    const r = zb.extractResultFromValue(p.value, "zx");
    try testing.expect(r.status == .none);
}

// Documented legend: >=90% pass, 50-90% warn, <50% fail (zbackup status).
test "JSON: percentage inference matches documented legend" {
    {
        const json =
            \\{"utilities":{"a":{"tests_passed":9,"tests_total":10}}}
        ;
        var p = parse(json);
        defer p.deinit();
        const r = zb.extractResultFromValue(p.value, "a");
        try testing.expect(r.status == .pass); // 90%
    }
    {
        const json =
            \\{"utilities":{"a":{"tests_passed":6,"tests_total":10}}}
        ;
        var p = parse(json);
        defer p.deinit();
        const r = zb.extractResultFromValue(p.value, "a");
        try testing.expect(r.status == .warn); // 60%
    }
    {
        const json =
            \\{"utilities":{"a":{"tests_passed":4,"tests_total":10}}}
        ;
        var p = parse(json);
        defer p.deinit();
        const r = zb.extractResultFromValue(p.value, "a");
        try testing.expect(r.status == .fail); // 40%
    }
}

// An explicit status wins over the inferred one (zdu in the real results.json
// is 82% but recorded "pass"). Anchored to that documented precedence.
test "JSON: explicit status overrides percentage inference" {
    const json =
        \\{"utilities":{"zdu":{"tests_passed":18,"tests_total":22,"status":"pass"}}}
    ;
    var p = parse(json);
    defer p.deinit();
    const r = zb.extractResultFromValue(p.value, "zdu");
    try testing.expectEqual(@as(u32, 18), r.passed);
    try testing.expectEqual(@as(u32, 22), r.total);
    try testing.expect(r.status == .pass); // not .warn despite 81.8%
}

// A missing utility, and non-object roots, must degrade to the empty result
// rather than crash or misreport.
test "JSON: missing utility and malformed roots yield empty result" {
    {
        const json =
            \\{"utilities":{"zls":{"tests_passed":1,"tests_total":1,"status":"pass"}}}
        ;
        var p = parse(json);
        defer p.deinit();
        const r = zb.extractResultFromValue(p.value, "zNOPE");
        try testing.expectEqual(@as(u32, 0), r.total);
        try testing.expect(r.status == .none);
    }
    {
        const json = "[1,2,3]"; // root is an array, not an object
        var p = parse(json);
        defer p.deinit();
        const r = zb.extractResultFromValue(p.value, "zls");
        try testing.expect(r.status == .none);
    }
}

// The UTILITIES table must have no duplicate zig_name or gnu_name, otherwise
// findUtilMapping (first-match) silently makes later entries dead and --all
// emits the same target twice (audit finding: zpaste listed twice, xclip
// twice). This proves the dedup.
test "UTILITIES: names are unique and every entry resolves to itself" {
    for (zb.UTILITIES, 0..) |a, i| {
        for (zb.UTILITIES, 0..) |b, j| {
            if (i == j) continue;
            if (std.mem.eql(u8, a.zig_name, b.zig_name)) {
                std.debug.print("duplicate zig_name: {s}\n", .{a.zig_name});
                return error.DuplicateZigName;
            }
            if (std.mem.eql(u8, a.gnu_name, b.gnu_name)) {
                std.debug.print("duplicate gnu_name: {s}\n", .{a.gnu_name});
                return error.DuplicateGnuName;
            }
        }
        const by_zig = zb.findUtilMapping(a.zig_name) orelse return error.MissingByZig;
        try testing.expect(std.mem.eql(u8, by_zig.zig_name, a.zig_name));
        const by_gnu = zb.findUtilMapping(a.gnu_name) orelse return error.MissingByGnu;
        try testing.expect(std.mem.eql(u8, by_gnu.gnu_name, a.gnu_name));
    }
}

// The swap installs a symlink at the GNU location pointing into ZBIN_DIR.
// Only such targets count as "active zig".
test "linkTargetIsZig: only targets under ZBIN_DIR count" {
    try testing.expect(zb.linkTargetIsZig("/usr/local/zbin/zls"));
    try testing.expect(!zb.linkTargetIsZig("/bin/ls"));
    try testing.expect(!zb.linkTargetIsZig("/usr/bin/ls"));
}

extern "c" fn symlink(existing: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

// POSIX readlink(2): resolveActiveIsZig must report true only when the path is
// a symlink whose target is under ZBIN_DIR, false for a symlink pointing
// elsewhere, and false for a regular file (readlink fails with EINVAL). Uses
// real on-disk symlinks so the actual readlink() syscall is exercised.
test "resolveActiveIsZig: readlink resolves the swap symlink (POSIX)" {
    // Fixed link paths under the OS temp dir (avoids the 0.16 Io.Dir churn).
    // Tests run sequentially; unlink first so a prior interrupted run cannot
    // leave a stale link and fail the create.
    const zig_link: [:0]const u8 = "/tmp/zbackup_test_active_link";
    const gnu_link: [:0]const u8 = "/tmp/zbackup_test_gnu_link";
    _ = unlink(zig_link.ptr);
    _ = unlink(gnu_link.ptr);

    // symlink into ZBIN_DIR -> active
    try testing.expect(symlink("/usr/local/zbin/zls", zig_link.ptr) == 0);
    defer _ = unlink(zig_link.ptr);
    try testing.expect(zb.resolveActiveIsZig(zig_link));

    // symlink to a real GNU path -> not active
    try testing.expect(symlink("/bin/ls", gnu_link.ptr) == 0);
    defer _ = unlink(gnu_link.ptr);
    try testing.expect(!zb.resolveActiveIsZig(gnu_link));

    // a real (non-symlink) regular file -> not active (readlink fails EINVAL)
    try testing.expect(!zb.resolveActiveIsZig("/bin/ls"));
}
