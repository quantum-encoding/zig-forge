//! ═══════════════════════════════════════════════════════════════════════════
//! WASM TYPES - WebAssembly Type System
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Core types for WebAssembly as defined in the spec:
//! https://webassembly.github.io/spec/core/syntax/types.html

const std = @import("std");

/// Value types - the types that can be stored in locals/globals
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B, // SIMD
    funcref = 0x70,
    externref = 0x6F,

    pub fn byteSize(self: ValType) usize {
        return switch (self) {
            .i32, .f32 => 4,
            .i64, .f64 => 8,
            .v128 => 16,
            .funcref, .externref => @sizeOf(usize),
        };
    }
};

/// Runtime value
pub const Value = union(ValType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    v128: u128,
    funcref: ?u32, // Function index or null
    externref: ?*anyopaque,

    pub fn asI32(self: Value) i32 {
        return switch (self) {
            .i32 => |v| v,
            .i64 => |v| @truncate(v),
            else => 0,
        };
    }

    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .i32 => |v| v,
            .i64 => |v| v,
            else => 0,
        };
    }

    pub fn asU32(self: Value) u32 {
        return @bitCast(self.asI32());
    }

    pub fn asU64(self: Value) u64 {
        return @bitCast(self.asI64());
    }

    pub fn asF32(self: Value) f32 {
        return switch (self) {
            .f32 => |v| v,
            .i32 => |v| @bitCast(v),
            else => 0.0,
        };
    }

    pub fn asF64(self: Value) f64 {
        return switch (self) {
            .f64 => |v| v,
            .i64 => |v| @bitCast(v),
            else => 0.0,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        if (@intFromEnum(self) != @intFromEnum(other)) return false;
        return switch (self) {
            .i32 => |v| v == other.i32,
            .i64 => |v| v == other.i64,
            .f32 => |v| v == other.f32,
            .f64 => |v| v == other.f64,
            .v128 => |v| v == other.v128,
            .funcref => |v| v == other.funcref,
            .externref => |v| v == other.externref,
        };
    }

    pub fn format(self: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .i32 => |v| try writer.print("i32:{d}", .{v}),
            .i64 => |v| try writer.print("i64:{d}", .{v}),
            .f32 => |v| try writer.print("f32:{d}", .{v}),
            .f64 => |v| try writer.print("f64:{d}", .{v}),
            .v128 => |v| try writer.print("v128:{x}", .{v}),
            .funcref => |v| if (v) |idx| try writer.print("funcref:{d}", .{idx}) else try writer.writeAll("funcref:null"),
            .externref => |v| if (v) |ptr| try writer.print("externref:{*}", .{ptr}) else try writer.writeAll("externref:null"),
        }
    }
};

/// Block type - result type for blocks/loops/if
pub const BlockType = union(enum) {
    empty: void,
    val_type: ValType,
    type_idx: u32,
};

/// Function type signature
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn eql(self: FuncType, other: FuncType) bool {
        return std.mem.eql(ValType, self.params, other.params) and
            std.mem.eql(ValType, self.results, other.results);
    }
};

/// Limits for memories and tables
pub const Limits = struct {
    min: u32,
    max: ?u32 = null,

    pub fn valid(self: Limits, range_max: u32) bool {
        if (self.min > range_max) return false;
        if (self.max) |max| {
            if (max > range_max or max < self.min) return false;
        }
        return true;
    }
};

/// Memory type
pub const MemType = struct {
    limits: Limits,

    pub const PAGE_SIZE: u32 = 65536; // 64 KiB
    pub const MAX_PAGES: u32 = 65536; // 4 GiB max
};

/// Table type
pub const TableType = struct {
    elem_type: ValType,
    limits: Limits,
};

/// Global type
pub const GlobalType = struct {
    val_type: ValType,
    mutable: bool,
};

/// External kind for imports/exports
pub const ExternKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    mem = 0x02,
    global = 0x03,
};

/// Import descriptor
pub const Import = struct {
    module: []const u8,
    name: []const u8,
    desc: ImportDesc,

    pub const ImportDesc = union(ExternKind) {
        func: u32, // Type index
        table: TableType,
        mem: MemType,
        global: GlobalType,
    };
};

/// Export descriptor
pub const Export = struct {
    name: []const u8,
    desc: ExportDesc,

    pub const ExportDesc = struct {
        kind: ExternKind,
        idx: u32,
    };
};

/// Element segment
pub const Elem = struct {
    type: ValType,
    init: []const InitExpr,
    mode: Mode,

    pub const Mode = union(enum) {
        passive: void,
        active: struct {
            table_idx: u32,
            offset: InitExpr,
        },
        declarative: void,
    };
};

/// Data segment
pub const Data = struct {
    init: []const u8,
    mode: Mode,

    pub const Mode = union(enum) {
        passive: void,
        active: struct {
            mem_idx: u32,
            offset: InitExpr,
        },
    };
};

/// Initialization expression (constant expression)
pub const InitExpr = struct {
    instrs: []const u8, // Encoded instructions
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "value type sizes" {
    try std.testing.expectEqual(@as(usize, 4), ValType.i32.byteSize());
    try std.testing.expectEqual(@as(usize, 8), ValType.i64.byteSize());
    try std.testing.expectEqual(@as(usize, 4), ValType.f32.byteSize());
    try std.testing.expectEqual(@as(usize, 8), ValType.f64.byteSize());
}

test "value conversions" {
    const v = Value{ .i32 = 42 };
    try std.testing.expectEqual(@as(i32, 42), v.asI32());
    try std.testing.expectEqual(@as(i64, 42), v.asI64());
}

test "limits validation" {
    const valid_limits = Limits{ .min = 1, .max = 10 };
    try std.testing.expect(valid_limits.valid(100));

    const invalid_limits = Limits{ .min = 10, .max = 5 };
    try std.testing.expect(!invalid_limits.valid(100));
}
