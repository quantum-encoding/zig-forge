//! ═══════════════════════════════════════════════════════════════════════════
//! WASM RUNTIME - WebAssembly Interpreter
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! A pure Zig WebAssembly runtime implementation.
//!
//! Features:
//! • Full WASM 1.0 MVP instruction set
//! • Stack-based bytecode interpreter
//! • Memory management with bounds checking
//! • WASI preview1 support (fd_write, proc_exit, etc.)
//!
//! Usage:
//! ```zig
//! const wasm = @import("wasm_runtime");
//!
//! // Load and parse a module
//! const bytes = try std.Io.Dir.cwd().readFileAlloc(allocator, "module.wasm", max_size);
//! var module = try wasm.Module.parse(allocator, bytes);
//! defer module.deinit();
//!
//! // Create instance and run
//! var instance = try wasm.Instance.init(allocator, &module);
//! defer instance.deinit();
//!
//! // Call exported function
//! const result = try instance.call("main", &.{});
//! ```

pub const core = struct {
    pub const binary = @import("core/binary.zig");
    pub const types = @import("core/types.zig");
    pub const opcodes = @import("core/opcodes.zig");
    pub const interpreter = @import("core/interpreter.zig");
};

pub const wasi = @import("wasi/wasi.zig");

// Re-exports for convenience
pub const Module = core.binary.Module;
pub const Instance = core.interpreter.Instance;
pub const Memory = core.interpreter.Memory;
pub const Value = core.types.Value;
pub const ValType = core.types.ValType;
pub const TrapError = core.interpreter.TrapError;

/// Parse a WASM binary module
pub fn parse(allocator: std.mem.Allocator, data: []const u8) core.binary.ParseError!Module {
    return core.binary.parse(allocator, data);
}

/// Create a new runtime instance from a module
pub fn instantiate(allocator: std.mem.Allocator, module: *const Module) !Instance {
    return Instance.init(allocator, module);
}

/// Create a WASI-enabled instance
/// NOTE: Call setupImports() on the returned instance before running
pub fn instantiateWasi(allocator: std.mem.Allocator, module: *const Module, config: wasi.Config) !wasi.WasiInstance {
    return wasi.WasiInstance.init(allocator, module, config);
}

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parse minimal module" {
    const minimal = core.binary.MAGIC ++ core.binary.VERSION;
    var module = try parse(std.testing.allocator, &minimal);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 0), module.types.len);
}

test "parse module with type section" {
    // Module with one function type: () -> i32
    const bytes = core.binary.MAGIC ++ core.binary.VERSION ++
        [_]u8{
        0x01, // Type section
        0x05, // Section size
        0x01, // 1 type
        0x60, // func
        0x00, // 0 params
        0x01, // 1 result
        0x7F, // i32
    };

    var module = try parse(std.testing.allocator, &bytes);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.types.len);
    try std.testing.expectEqual(@as(usize, 0), module.types[0].params.len);
    try std.testing.expectEqual(@as(usize, 1), module.types[0].results.len);
    try std.testing.expectEqual(ValType.i32, module.types[0].results[0]);
}

test {
    std.testing.refAllDecls(@This());
}
