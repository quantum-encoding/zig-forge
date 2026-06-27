//! URL detection over a terminal grid. Single-row scan for http(s)/ftp/file/www.
//! schemes; returns cell ranges (row, start_col, end_col-exclusive). Lives in the
//! core so every renderer inherits it: the renderer paints the ranges in
//! theme.url + underline and hit-tests clicks (reading the URL text straight from
//! its own cell buffer). Row-wrapped URLs are a later refinement.

const std = @import("std");
const terminal = @import("terminal.zig");

/// extern so it doubles as the C-ABI type (capi re-exports it as tmux_url_range).
pub const UrlRange = extern struct { row: u16, start_col: u16, end_col: u16 };

const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "www." };

fn charAt(grid: *const terminal.Grid, r: u16, c: u16) u8 {
    if (c >= grid.cols) return 0;
    const ch = grid.getCellConst(r, c).char;
    return if (ch < 128) @intCast(ch) else 0;
}

fn lower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn isAlnum(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

fn isUrlChar(ch: u8) bool {
    return isAlnum(ch) or std.mem.indexOfScalar(u8, "-._~:/?#[]@!$&'()*+,;=%", ch) != null;
}

fn matchesAt(grid: *const terminal.Grid, r: u16, c: u16, needle: []const u8) bool {
    var i: u16 = 0;
    while (i < needle.len) : (i += 1) {
        if (lower(charAt(grid, r, c +% i)) != needle[i]) return false;
    }
    return true;
}

/// If a URL starts at (r,c), return the exclusive end column; else null.
fn matchUrlStart(grid: *const terminal.Grid, r: u16, c: u16) ?u16 {
    var matched = false;
    for (schemes) |s| {
        if (matchesAt(grid, r, c, s)) {
            matched = true;
            break;
        }
    }
    if (!matched) return null;

    var end = c;
    while (end < grid.cols and isUrlChar(charAt(grid, r, end))) : (end += 1) {}
    // trim trailing sentence punctuation that's usually not part of the URL
    while (end > c and std.mem.indexOfScalar(u8, ".,;:!?", charAt(grid, r, end - 1)) != null) end -= 1;

    if (end <= c + 4) return null; // too short to be a real URL
    return end;
}

/// Fill `out` with the URL ranges visible in `grid`; returns the count written.
pub fn findUrls(grid: *const terminal.Grid, out: []UrlRange) usize {
    var count: usize = 0;
    var r: u16 = 0;
    while (r < grid.rows and count < out.len) : (r += 1) {
        var c: u16 = 0;
        while (c < grid.cols) {
            // only at a word boundary, so "awww." / "ahttp" don't match mid-token
            const boundary = c == 0 or !isUrlChar(charAt(grid, r, c - 1));
            if (boundary) {
                if (matchUrlStart(grid, r, c)) |end| {
                    out[count] = .{ .row = r, .start_col = c, .end_col = end };
                    count += 1;
                    if (count >= out.len) break;
                    c = end;
                    continue;
                }
            }
            c += 1;
        }
    }
    return count;
}

test "findUrls detects schemes and trims trailing punctuation" {
    var term = try terminal.Terminal.init(std.testing.allocator, 4, 80, 100);
    defer term.deinit();
    term.putPrintableRun("see https://example.com/path?q=1, and www.foo.org here");

    var buf: [8]UrlRange = undefined;
    const n = findUrls(&term.grid, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    // first URL starts at col 4 ("see " = 4 chars), trailing comma trimmed
    try std.testing.expectEqual(@as(u16, 0), buf[0].row);
    try std.testing.expectEqual(@as(u16, 4), buf[0].start_col);
    const c0 = charAt(&term.grid, 0, buf[0].end_col - 1);
    try std.testing.expect(c0 != ','); // comma not included
    // second is the www. one
    try std.testing.expect(buf[1].start_col > buf[0].end_col);
}
