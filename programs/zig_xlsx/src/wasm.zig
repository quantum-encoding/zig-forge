//! Freestanding WebAssembly entry point for browser / edge embedding.
//!
//! Targets wasm32-freestanding: imports NOTHING from the host (no WASI, no
//! libc), so it instantiates with an empty import object straight from
//! `WebAssembly.instantiate`. The ABI mirrors zig_docx's wasm.zig / zigpdf's
//! wasm.zig: `wasm_alloc` for input, a single pointer return plus an out-length.
//!
//! Deliberately does NOT import xlsx.zig — that re-exports JsonWriter, which is
//! bound to libc `*std.c.FILE` and would drag libc into the freestanding graph.
//! Instead we drive the low-level modules (zip/workbook/sharedStrings/worksheet)
//! and emit JSON by hand.
//!
//! `xlsx_to_json(ptr,len,*outLen)` → bytes of an .xlsx in, JSON out:
//!   { "sheets": [ { "name": "Sheet1", "rows": [ ["a","b",null], ... ] } ] }
//! Each cell is a JSON string (as stored in the sheet) or null for an empty
//! cell. The host turns rows into a markdown table / line items.

const std = @import("std");
const zip = @import("zip.zig");
const workbook_mod = @import("workbook.zig");
const shared_strings_mod = @import("shared_strings.zig");
const worksheet_mod = @import("worksheet.zig");

const alloc = std.heap.wasm_allocator;

// ─── Memory management (host-controlled buffers) ───────────────────
export fn wasm_alloc(size: usize) usize {
    if (size == 0) return 0;
    const slice = alloc.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}
export fn wasm_free(ptr: usize, size: usize) void {
    if (ptr == 0 or size == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    alloc.free(p[0..size]);
}
/// Free a buffer returned by xlsx_to_json (same allocator as wasm_alloc).
export fn xlsx_free(ptr: usize, size: usize) void {
    wasm_free(ptr, size);
}

// ─── Error reporting ───────────────────────────────────────────────
var last_error: [256]u8 = undefined;
var last_error_len: usize = 0;
fn setError(msg: []const u8) void {
    const n = @min(msg.len, last_error.len);
    @memcpy(last_error[0..n], msg[0..n]);
    last_error_len = n;
}
export fn xlsx_get_error(out_len: *usize) ?[*]const u8 {
    out_len.* = last_error_len;
    return if (last_error_len == 0) null else &last_error;
}

// ─── JSON emission ─────────────────────────────────────────────────
fn appendEscaped(list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "";
                    try list.appendSlice(alloc, hex);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
    try list.append(alloc, '"');
}

/// Convert .xlsx bytes → JSON. Returns a heap pointer (free via xlsx_free) and
/// writes its length to out_len. Returns null + sets the error string on failure.
export fn xlsx_to_json(ptr: [*]const u8, len: usize, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    last_error_len = 0;
    const data = ptr[0..len];

    var archive = zip.ZipArchive.openFromMemory(alloc, data) catch {
        setError("not a valid xlsx (zip) file");
        return null;
    };
    defer archive.close();

    const wb_entry = archive.findEntry("xl/workbook.xml") orelse {
        setError("missing xl/workbook.xml");
        return null;
    };
    const wb_data = archive.extract(wb_entry) catch {
        setError("failed to read workbook.xml");
        return null;
    };
    defer alloc.free(wb_data);

    const rels_entry = archive.findEntry("xl/_rels/workbook.xml.rels") orelse {
        setError("missing workbook rels");
        return null;
    };
    const rels_data = archive.extract(rels_entry) catch {
        setError("failed to read workbook rels");
        return null;
    };
    defer alloc.free(rels_data);

    var workbook = workbook_mod.WorkbookInfo.parse(alloc, wb_data, rels_data) catch {
        setError("failed to parse workbook");
        return null;
    };
    defer workbook.deinit();

    var shared = blk: {
        if (archive.findEntry("xl/sharedStrings.xml")) |ss_entry| {
            const ss_data = archive.extract(ss_entry) catch {
                setError("failed to read sharedStrings");
                return null;
            };
            defer alloc.free(ss_data);
            break :blk shared_strings_mod.SharedStrings.parse(alloc, ss_data) catch {
                setError("failed to parse sharedStrings");
                return null;
            };
        } else {
            break :blk shared_strings_mod.SharedStrings{ .strings = .empty, .allocator = alloc };
        }
    };
    defer shared.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"sheets\":[") catch return oom();

    for (workbook.sheets, 0..) |sheet_info, si| {
        if (si != 0) out.append(alloc, ',') catch return oom();
        out.appendSlice(alloc, "{\"name\":") catch return oom();
        appendEscaped(&out, sheet_info.name) catch return oom();
        out.appendSlice(alloc, ",\"rows\":[") catch return oom();

        const ws_entry = archive.findEntry(sheet_info.path) orelse {
            out.append(alloc, ']') catch return oom();
            out.append(alloc, '}') catch return oom();
            continue;
        };
        const ws_data = archive.extract(ws_entry) catch {
            out.appendSlice(alloc, "]}") catch return oom();
            continue;
        };
        defer alloc.free(ws_data);

        var sheet = worksheet_mod.parseWorksheet(alloc, ws_data, &shared) catch {
            out.appendSlice(alloc, "]}") catch return oom();
            continue;
        };
        defer sheet.deinit(alloc);

        for (sheet.rows, 0..) |row, ri| {
            if (ri != 0) out.append(alloc, ',') catch return oom();
            out.append(alloc, '[') catch return oom();
            for (row, 0..) |cell, ci| {
                if (ci != 0) out.append(alloc, ',') catch return oom();
                if (cell) |value| {
                    appendEscaped(&out, value) catch return oom();
                } else {
                    out.appendSlice(alloc, "null") catch return oom();
                }
            }
            out.append(alloc, ']') catch return oom();
        }
        out.appendSlice(alloc, "]}") catch return oom();
    }
    out.appendSlice(alloc, "]}") catch return oom();

    // Copy into an exact-sized buffer the host owns + frees.
    const result = alloc.alloc(u8, out.items.len) catch return oom();
    @memcpy(result, out.items);
    out_len.* = result.len;
    return result.ptr;
}

fn oom() ?[*]u8 {
    setError("out of memory");
    return null;
}
