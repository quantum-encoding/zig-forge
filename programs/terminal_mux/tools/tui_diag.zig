//! TUI renderer-diagnosis harness. Feeds a captured/synth byte stream through
//! the C ABI exactly as the Swift Metal view does, then dumps what the renderer
//! consumes: the grid as text, every cell that carries ATTR_UNDERLINE (defect
//! 1 — spurious underlines), and the tmux_find_urls ranges (the suspected
//! source). Confirms whether the emulator grid is correct (operator says yes)
//! and localizes the underline overreach.
//!
//!   zig run tools/tui_diag.zig -lc -- <stream.bin>

const std = @import("std");
const posix = std.posix;
const capi = @import("../src/capi.zig");

const Printer = struct {
    fn print(_: Printer, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var ai = std.process.Args.Iterator.init(init.minimal.args);
    while (ai.next()) |a| try args.append(alloc, a);
    if (args.items.len < 2) {
        std.debug.print("usage: tui_diag <stream.bin>\n", .{});
        return;
    }
    const path0 = try alloc.dupeZ(u8, args.items[1]);
    defer alloc.free(path0);
    const fd = try posix.openatZ(std.c.AT.FDCWD, path0, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    var rbuf: [65536]u8 = undefined;
    while (true) {
        const got = try posix.read(fd, &rbuf);
        if (got == 0) break;
        try list.appendSlice(alloc, rbuf[0..got]);
    }
    const bytes = list.items;

    const h = capi.tmux_create(40, 120, "/bin/cat", null) orelse return;
    defer capi.tmux_destroy(h);
    capi.tmux_feed(h, bytes.ptr, bytes.len);

    var rows: u16 = 0;
    var cols: u16 = 0;
    capi.tmux_grid_size(h, &rows, &cols);
    const total = @as(usize, rows) * cols;
    const cells = try alloc.alloc(capi.CCell, total);
    const n = capi.tmux_read_cells(h, cells.ptr, total);

    const out = Printer{};

    out.print("=== GRID {d}x{d} ({d} cells) ===\n", .{ rows, cols, n });
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        var col: usize = 0;
        var any = false;
        while (col < cols) : (col += 1) {
            const cell = cells[r * cols + col];
            if (cell.width == 0 or cell.ch == 0) continue;
            var ub: [4]u8 = undefined;
            const l = std.unicode.utf8Encode(@intCast(cell.ch), &ub) catch continue;
            if (len + l < buf.len) {
                @memcpy(buf[len .. len + l], ub[0..l]);
                len += l;
                any = true;
            }
        }
        if (any) out.print("{d:>2}| {s}\n", .{ r, buf[0..len] });
    }

    out.print("\n=== CELLS WITH ATTR_UNDERLINE (bit3=8) ===\n", .{});
    var underline_count: usize = 0;
    r = 0;
    while (r < rows) : (r += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const cell = cells[r * cols + col];
            if (cell.attrs & 8 != 0) {
                underline_count += 1;
                if (underline_count <= 40) {
                    const ch: u21 = @intCast(cell.ch);
                    var ub: [4]u8 = undefined;
                    const l = std.unicode.utf8Encode(ch, &ub) catch 0;
                    out.print("  ({d},{d}) '{s}'\n", .{ r, col, ub[0..l] });
                }
            }
        }
    }
    out.print("  total underlined cells: {d}\n", .{underline_count});

    out.print("\n=== tmux_find_urls RANGES ===\n", .{});
    var ranges: [64]capi.CUrlRange = undefined;
    const url_n = capi.tmux_find_urls(h, &ranges, ranges.len);
    out.print("  {d} range(s)\n", .{url_n});
    var i: usize = 0;
    while (i < url_n) : (i += 1) {
        const rg = ranges[i];
        out.print("  [{d}] ({d},{d})->({d},{d})  text: \"", .{ i, rg.start_row, rg.start_col, rg.end_row, rg.end_col });
        // Reconstruct the underlined text the way the Swift painter would.
        var rr: u16 = rg.start_row;
        while (rr <= rg.end_row) : (rr += 1) {
            const c0: usize = if (rr == rg.start_row) rg.start_col else 0;
            const c1: usize = if (rr == rg.end_row) rg.end_col else cols;
            var cc: usize = c0;
            while (cc < c1) : (cc += 1) {
                const cell = cells[@as(usize, rr) * cols + cc];
                if (cell.ch == 0) continue;
                var ub: [4]u8 = undefined;
                const l = std.unicode.utf8Encode(@intCast(cell.ch), &ub) catch continue;
                out.print("{s}", .{ub[0..l]});
            }
        }
        out.print("\"\n", .{});
    }
}
