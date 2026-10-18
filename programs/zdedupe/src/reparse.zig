//! Reading reparse-point data (winnt.h `REPARSE_DATA_BUFFER`) from its bytes,
//! with no OS call, so the parsing is tested on every host. sys_windows.zig
//! fetches the bytes with `FSCTL_GET_REPARSE_POINT`.

const std = @import("std");

/// winnt.h IO_REPARSE_TAG_APPEXECLINK.
pub const tag_app_exec_link: u32 = 0x8000001B;

/// The executable an app execution alias runs (the `.exe` stubs in
/// `%LOCALAPPDATA%\Microsoft\WindowsApps`), as UTF-16 units decoded into
/// `out`. The alias's data is the 8-byte reparse header (tag, data length,
/// reserved), a version word, then NUL-terminated UTF-16 strings: the package
/// id, the app user model id, the executable, the application type. Null when
/// `data` is not an alias or its executable is missing or unterminated.
pub fn appExecLinkExe(data: []const u8, out: []u16) ?[]const u16 {
    const header = 8;
    const strings_at = header + 4;
    if (data.len < strings_at) return null;
    if (std.mem.readInt(u32, data[0..4], .little) != tag_app_exec_link) return null;
    const end = @min(data.len, header + @as(usize, std.mem.readInt(u16, data[4..6], .little)));
    if (end < strings_at) return null;
    const n = @min((end - strings_at) / 2, out.len);
    for (0..n) |i| out[i] = std.mem.readInt(u16, data[strings_at + 2 * i ..][0..2], .little);
    const units = out[0..n];

    var field: usize = 0;
    var start: usize = 0;
    for (units, 0..) |u, i| {
        if (u != 0) continue;
        if (field == 2) return if (i > start) units[start..i] else null;
        field += 1;
        start = i + 1;
    }
    return null;
}

/// An alias buffer holding `strings`, each NUL-terminated, the way Windows
/// writes one.
fn aliasBuffer(buf: []u8, tag: u32, strings: []const []const u8) []const u8 {
    var at: usize = 12;
    for (strings) |s| {
        for (s) |ch| {
            std.mem.writeInt(u16, buf[at..][0..2], ch, .little);
            at += 2;
        }
        std.mem.writeInt(u16, buf[at..][0..2], 0, .little);
        at += 2;
    }
    std.mem.writeInt(u32, buf[0..4], tag, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(at - 8), .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u32, buf[8..12], 3, .little);
    return buf[0..at];
}

fn expectUnits(expected: []const u8, got: ?[]const u16) !void {
    const units = got orelse return error.TestExpectedExecutable;
    try std.testing.expectEqual(expected.len, units.len);
    for (expected, units) |e, u| try std.testing.expectEqual(@as(u16, e), u);
}

test "an app execution alias's target is the executable it runs" {
    var buf: [512]u8 = undefined;
    var out: [256]u16 = undefined;
    const data = aliasBuffer(&buf, tag_app_exec_link, &.{
        "PythonSoftwareFoundation.Python.3.12_qbz5n2kfra8p0",
        "PythonSoftwareFoundation.Python.3.12_qbz5n2kfra8p0!Python",
        "C:\\Program Files\\WindowsApps\\PythonSoftwareFoundation.Python.3.12_3.12.10.0_x64__qbz5n2kfra8p0\\python3.12.exe",
        "0",
    });
    try expectUnits(
        "C:\\Program Files\\WindowsApps\\PythonSoftwareFoundation.Python.3.12_3.12.10.0_x64__qbz5n2kfra8p0\\python3.12.exe",
        appExecLinkExe(data, &out),
    );
}

test "a buffer that is not an alias, or lacks a whole executable, has no target" {
    var buf: [512]u8 = undefined;
    var out: [256]u16 = undefined;
    // Another tag (a symlink).
    try std.testing.expect(appExecLinkExe(aliasBuffer(&buf, 0xA000000C, &.{ "a", "b", "c.exe" }), &out) == null);
    // Only the package and app ids.
    try std.testing.expect(appExecLinkExe(aliasBuffer(&buf, tag_app_exec_link, &.{ "a", "a!App" }), &out) == null);
    // An empty executable.
    try std.testing.expect(appExecLinkExe(aliasBuffer(&buf, tag_app_exec_link, &.{ "a", "a!App", "" }), &out) == null);
    // Cut off inside the executable: no terminating NUL.
    const whole = aliasBuffer(&buf, tag_app_exec_link, &.{ "a", "a!App", "C:\\x.exe" });
    try std.testing.expect(appExecLinkExe(whole[0 .. whole.len - 2], &out) == null);
    // Shorter than the header and version.
    try std.testing.expect(appExecLinkExe(whole[0..10], &out) == null);
}

test "an alias's data length bounds the strings, not the buffer it came in" {
    var buf: [512]u8 = undefined;
    var out: [256]u16 = undefined;
    const data = aliasBuffer(&buf, tag_app_exec_link, &.{ "a", "a!App", "C:\\x.exe", "0" });
    // Declare the data to end before the executable's NUL.
    var short: [512]u8 = undefined;
    @memcpy(short[0..data.len], data);
    const exe_end: u16 = @intCast(4 + 2 * ("a".len + 1 + "a!App".len + 1 + "C:\\x.exe".len));
    std.mem.writeInt(u16, short[4..6], exe_end, .little);
    try std.testing.expect(appExecLinkExe(short[0..data.len], &out) == null);
}
