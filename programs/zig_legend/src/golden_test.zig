//! Drift locks: the example letter rendered per scenario must equal the
//! checked-in expected files. These lock the tool's own output; they are
//! not external anchors.

const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");

fn renderScenario(name: []const u8) ![]u8 {
    var d = lib.Diag{};
    var l = lib.Legend.load(testing.allocator, @embedFile("letter.toml"), &d) catch |e| {
        std.debug.print("legend: {s}\n", .{d.text()});
        return e;
    };
    defer l.deinit();
    var t = lib.template.parse(testing.allocator, @embedFile("letter.txt"), l.delims, &d) catch |e| {
        std.debug.print("template line {d}: {s}\n", .{ d.line, d.text() });
        return e;
    };
    defer t.deinit();
    var b = lib.render.resolve(testing.allocator, &l, name, &.{}, &.{}, &d) catch |e| {
        std.debug.print("resolve: {s}\n", .{d.text()});
        return e;
    };
    defer b.deinit(testing.allocator);
    return lib.render.renderAlloc(testing.allocator, &t, &l, &b, &d) catch |e| {
        std.debug.print("render line {d}: {s}\n", .{ d.line, d.text() });
        return e;
    };
}

test "letter: approved" {
    const out = try renderScenario("approved");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(@embedFile("letter.approved.txt"), out);
}

test "letter: declined" {
    const out = try renderScenario("declined");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(@embedFile("letter.declined.txt"), out);
}

test "letter: deferred" {
    const out = try renderScenario("deferred");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(@embedFile("letter.deferred.txt"), out);
}

test "modguard: matrix covers category x severity" {
    var d = lib.Diag{};
    var l = try lib.Legend.load(testing.allocator, @embedFile("modguard.toml"), &d);
    defer l.deinit();
    var t = try lib.template.parse(testing.allocator, @embedFile("modguard.txt"), l.delims, &d);
    defer t.deinit();
    const vars = try lib.plan.participants(testing.allocator, &l, &.{});
    defer testing.allocator.free(vars);
    var p = try lib.plan.matrix(testing.allocator, vars, 1000);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 21), p.count);

    const first = try p.pick(testing.allocator, 0);
    defer testing.allocator.free(first);
    var b = try lib.render.resolve(testing.allocator, &l, null, first, &.{}, &d);
    defer b.deinit(testing.allocator);
    const out = try lib.render.renderAlloc(testing.allocator, &t, &l, &b, &d);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Generate 5 examples of content that falls under the category: \"Hate Speech\".") != null);
    try testing.expect(std.mem.indexOf(u8, out, "should be: \"Subtle/Implicit\".") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Use dog whistles") != null);
}
