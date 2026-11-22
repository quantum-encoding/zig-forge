//! Freestanding WebAssembly entry point for browser / edge embedding.
//!
//! Targets wasm32-freestanding: imports NOTHING from the host (no WASI, no
//! libc), so it instantiates with an empty import object straight from
//! `WebAssembly.instantiate`. The ABI mirrors zig_docx's wasm.zig / zigpdf's
//! wasm.zig: `wasm_alloc` for input, a single pointer return plus an out-length.
//!
//! Deliberately does NOT import xlsx.zig — that re-exports JsonWriter, which is
//! bound to libc `*std.c.FILE` and would drag libc into the freestanding graph.
//! convert.zig drives the low-level modules and emits the JSON.
//!
//! `xlsx_to_json(ptr,len,*outLen)` → bytes of an .xlsx in, JSON out:
//!   { "sheets": [ { "name": "Sheet1", "rows": [ ["a","b",null], [], ... ] } ] }
//! Row i is spreadsheet row i+1 (rows Excel leaves out are empty arrays);
//! each cell is a JSON string or null for an empty cell, and numbers in a
//! date or time style are ISO 8601 text. The host turns rows into a markdown
//! table / line items.
//!
//! One instance serves any number of calls: every buffer is released with
//! wasm_free / xlsx_free by whoever allocated or received it, and the module
//! never frees the caller's input.

const std = @import("std");
const convert = @import("convert.zig");

// std.heap.wasm_allocator, minus the in-place shrink that leaks a 64 KiB page
// per call in a reused instance (see wasm_heap.zig).
const alloc = @import("wasm_heap.zig").allocator;

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

/// Convert .xlsx bytes → JSON (shape in convert.zig). Returns a heap pointer
/// (free via xlsx_free) and writes its length to out_len. Returns null + sets
/// the error string on failure. The input stays the caller's: free it with
/// wasm_free(ptr, len) after the call.
export fn xlsx_to_json(ptr: [*]const u8, len: usize, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    last_error_len = 0;
    const json = convert.xlsxToJson(alloc, ptr[0..len]) catch |err| {
        setError(convert.errorMessage(err));
        return null;
    };
    out_len.* = json.len;
    return json.ptr;
}
