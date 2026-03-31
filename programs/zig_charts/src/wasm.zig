//! WASM API for zig_charts
//!
//! Exposes chart generation to JavaScript/browsers via WebAssembly.
//! JSON in → SVG out. Zero dependencies, runs anywhere WASM runs.
//!
//! Usage from JavaScript:
//! ```js
//! const json = JSON.stringify({ type: "pie", data: { segments: [...] } });
//! const jsonPtr = wasmAlloc(json.length);
//! wasmMemory.set(new TextEncoder().encode(json), jsonPtr);
//! const svgLen = zigcharts_render(jsonPtr, json.length);
//! const svgPtr = zigcharts_get_output();
//! const svg = new TextDecoder().decode(wasmMemory.slice(svgPtr, svgPtr + svgLen));
//! wasmFree(jsonPtr, json.length);
//! wasmFree(svgPtr, svgLen);
//! ```

const std = @import("std");
const json_mod = @import("json.zig");

// Use a fixed buffer allocator for WASM (no libc malloc)
var wasm_heap: [4 * 1024 * 1024]u8 = undefined; // 4 MB heap
var fba = std.heap.FixedBufferAllocator.init(&wasm_heap);

// Output buffer — pointer + length from last render
var output_ptr: [*]u8 = undefined;
var output_len: usize = 0;
var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

// ── Memory management ────────────────────────────────────────────────────────

/// Allocate bytes in WASM linear memory. Returns pointer for JS to write into.
export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = fba.allocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

/// Free previously allocated memory.
export fn wasm_free(ptr: [*]u8, size: usize) void {
    fba.allocator().free(ptr[0..size]);
}

// ── Chart rendering ──────────────────────────────────────────────────────────

/// Render a chart from JSON. Returns SVG length (0 on error).
/// Call zigcharts_get_output() to get the SVG pointer.
export fn zigcharts_render(json_ptr: [*]const u8, json_len: usize) usize {
    const allocator = fba.allocator();
    const json_str = json_ptr[0..json_len];

    const svg = json_mod.chartFromJson(allocator, json_str) catch |err| {
        setError(@errorName(err));
        return 0;
    };

    output_ptr = @constCast(svg.ptr);
    output_len = svg.len;
    return svg.len;
}

/// Get pointer to the last rendered SVG output.
export fn zigcharts_get_output() [*]u8 {
    return output_ptr;
}

/// Get pointer to the last error message.
export fn zigcharts_get_error() [*]const u8 {
    return &last_error;
}

/// Get length of the last error message.
export fn zigcharts_get_error_len() usize {
    return last_error_len;
}

/// Reset the allocator (free all memory, start fresh).
/// Call between renders to prevent heap exhaustion.
export fn zigcharts_reset() void {
    fba.reset();
    output_len = 0;
    last_error_len = 0;
}

/// Return the version string.
export fn zigcharts_version() [*]const u8 {
    return "1.0.0-wasm";
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn setError(msg: []const u8) void {
    const len = @min(msg.len, last_error.len);
    @memcpy(last_error[0..len], msg[0..len]);
    last_error_len = len;
}

// Freestanding panic handler (required for WASM)
pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    setError(msg);
    @trap();
}
