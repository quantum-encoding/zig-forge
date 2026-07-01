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

/// Length of the URL scheme that begins at (r,c), or 0 if none matches.
fn schemeLenAt(grid: *const terminal.Grid, r: u16, c: u16) u16 {
    for (schemes) |s| {
        if (matchesAt(grid, r, c, s)) return @intCast(s.len);
    }
    return 0;
}

const End = struct { row: u16, col: u16 };

/// From a confirmed URL start, walk over URL chars (following soft row-wraps) and
/// trim trailing sentence punctuation. Returns the exclusive end.
fn extendAndTrim(grid: *const terminal.Grid, r0: u16, c0: u16) End {
    var r = r0;
    var c = c0;
    while (true) {
        while (c < grid.cols and isUrlChar(charAt(grid, r, c))) c += 1;
        // Continue onto the next row only when this row was GENUINELY soft-wrapped
        // (DECAWM autowrap with no CR/LF between), the URL filled the last column,
        // and the next row actually resumes with a URL char. A hard line break
        // stops the URL even if it happened to fill the full width — this is what
        // prevents the underline from bleeding into unrelated following lines.
        if (c == grid.cols and r + 1 < grid.rows and grid.isRowWrapped(r) and isUrlChar(charAt(grid, r + 1, 0))) {
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
        const scheme_len = schemeLenAt(grid, r, c);
        if (boundary and scheme_len > 0) {
            const e = extendAndTrim(grid, r, c);
            // Require at least one real host char past the scheme (or a soft-wrap
            // onto the next row). Rejects bare schemes like "https://" or "www."
            // with nothing after them.
            const long_enough = e.row > r or e.col > c + scheme_len;
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

test "findUrls: a hard-terminated line that fills the width does NOT bleed onto the next line" {
    // 19-col grid; "https://example.com" is exactly 19 chars, so it fills the
    // last column WITHOUT triggering autowrap (autowrap is lazy). A CR/LF then
    // hard-terminates the line, and the next line is all URL chars. The old
    // "filled last column + next row starts with a URL char" proxy would have
    // joined the two into one range (underline bleed); the real soft-wrap flag
    // must keep the URL confined to its own row.
    var term = try terminal.Terminal.init(std.testing.allocator, 4, 19, 100);
    defer term.deinit();

    term.putPrintableRun("https://example.com"); // fills row 0 exactly (col == cols)
    try std.testing.expect(!term.grid.isRowWrapped(0)); // no autowrap fired → hard line
    term.carriageReturn();
    term.newline();
    term.putPrintableRun("morestuff.com/path"); // row 1: URL chars, but a distinct line

    var buf: [4]UrlRange = undefined;
    const n = findUrls(&term.grid, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start_row);
    try std.testing.expectEqual(@as(u16, 0), buf[0].end_row); // stays on its own row — no bleed
    try std.testing.expectEqual(@as(u16, 19), buf[0].end_col); // through the full width
}
