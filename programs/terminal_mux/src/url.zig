//! URL detection over a terminal grid. Scans for http(s)/ftp/file/www. schemes at
//! word boundaries, extends over valid URL chars, follows soft row-wraps (a URL
//! that fills the last column and continues at the next row's col 0), and trims
//! trailing sentence punctuation. Returns multi-row ranges
//! (start_row,start_col → end_row,end_col-exclusive). Core-side so every renderer
//! inherits it: paint the ranges in theme.url + underline, read the URL text from
//! the cell buffer (across rows), hit-test clicks.

const std = @import("std");
const terminal = @import("terminal.zig");

/// extern so it doubles as the C-ABI type (capi re-exports it as tmux_url_range).
/// A single-row URL has start_row == end_row.
pub const UrlRange = extern struct {
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16, // exclusive, on end_row
};

const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "www." };

fn charAt(grid: *const terminal.Grid, r: u16, c: u16) u8 {
    if (c >= grid.cols or r >= grid.rows) return 0;
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

fn schemeAt(grid: *const terminal.Grid, r: u16, c: u16) bool {
    for (schemes) |s| {
        if (matchesAt(grid, r, c, s)) return true;
    }
    return false;
}

const End = struct { row: u16, col: u16 };

/// From a confirmed URL start, walk over URL chars (following soft row-wraps) and
/// trim trailing sentence punctuation. Returns the exclusive end.
fn extendAndTrim(grid: *const terminal.Grid, r0: u16, c0: u16) End {
    var r = r0;
    var c = c0;
    while (true) {
        while (c < grid.cols and isUrlChar(charAt(grid, r, c))) c += 1;
        // soft wrap: filled the last column and the next row continues with a URL char
        if (c == grid.cols and r + 1 < grid.rows and isUrlChar(charAt(grid, r + 1, 0))) {
            r += 1;
            c = 0;
            continue;
        }
        break;
    }
    const min_col: u16 = if (r == r0) c0 else 0; // don't trim back into a previous row
    while (c > min_col and std.mem.indexOfScalar(u8, ".,;:!?", charAt(grid, r, c - 1)) != null) c -= 1;
    return .{ .row = r, .col = c };
}

/// Fill `out` with the URL ranges visible in `grid`; returns the count written.
pub fn findUrls(grid: *const terminal.Grid, out: []UrlRange) usize {
    var count: usize = 0;
    var r: u16 = 0;
    var c: u16 = 0;
    while (r < grid.rows and count < out.len) {
        if (c >= grid.cols) {
            r += 1;
            c = 0;
            continue;
        }
        const boundary = c == 0 or !isUrlChar(charAt(grid, r, c - 1));
        if (boundary and schemeAt(grid, r, c)) {
            const e = extendAndTrim(grid, r, c);
            const long_enough = e.row > r or e.col > c + 4;
            if (long_enough) {
                out[count] = .{ .start_row = r, .start_col = c, .end_row = e.row, .end_col = e.col };
                count += 1;
                r = e.row;
                c = e.col;
                continue;
            }
        }
        c += 1;
    }
    return count;
}

test "findUrls: two single-row URLs, trailing punctuation trimmed" {
    var term = try terminal.Terminal.init(std.testing.allocator, 4, 80, 100);
    defer term.deinit();
    term.putPrintableRun("see https://example.com/path?q=1, and www.foo.org here");

    var buf: [8]UrlRange = undefined;
    const n = findUrls(&term.grid, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start_row);
    try std.testing.expectEqual(@as(u16, 0), buf[0].end_row); // single row
    try std.testing.expectEqual(@as(u16, 4), buf[0].start_col); // after "see "
    try std.testing.expect(charAt(&term.grid, 0, buf[0].end_col - 1) != ','); // comma trimmed
    try std.testing.expect(buf[1].start_col > buf[0].end_col);
}

test "findUrls: a URL that soft-wraps spans two rows" {
    var term = try terminal.Terminal.init(std.testing.allocator, 4, 20, 100);
    defer term.deinit();
    // 33 chars into a 20-col grid → wraps to row 1
    term.putPrintableRun("https://example.com/averylongpath");

    var buf: [4]UrlRange = undefined;
    const n = findUrls(&term.grid, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start_row);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start_col);
    try std.testing.expectEqual(@as(u16, 1), buf[0].end_row); // wrapped onto row 1
}
