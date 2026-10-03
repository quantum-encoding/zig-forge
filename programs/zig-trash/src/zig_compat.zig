//! Type reflection that reads the same on Zig 0.16 and 0.17+.
//!
//! Zig 0.17 reports container fields struct-of-arrays style (`field_names`,
//! `field_types`, `field_values`, `param_types`) where 0.16 had arrays of
//! per-field structs (`fields`, `params`), and turned `std.meta.fields` into a
//! compile error. These helpers return the 0.16 shape from either layout.

const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    /// Field type; `void` for enum fields.
    type: type,
    /// Enum field value; 0 for struct and union fields.
    value: comptime_int = 0,
};

/// Fields of a struct, union or enum type.
pub inline fn fields(comptime T: type) []const Field {
    return comptime blk: {
        const info = @typeInfo(T);
        const sub = switch (info) {
            .@"struct", .@"union", .@"enum" => @field(info, @tagName(std.meta.activeTag(info))),
            else => @compileError("fields: expected struct, union or enum, found " ++ @typeName(T)),
        };
        const Sub = @TypeOf(sub);
        if (@hasField(Sub, "field_names")) {
            var out: [sub.field_names.len]Field = undefined;
            for (&out, 0..) |*f, i| f.* = .{
                .name = sub.field_names[i],
                .type = if (@hasField(Sub, "field_types")) sub.field_types[i] else void,
                .value = if (@hasField(Sub, "field_values")) sub.field_values[i] else 0,
            };
            const final = out;
            break :blk &final;
        } else {
            var out: [sub.fields.len]Field = undefined;
            for (&out, sub.fields) |*f, src| f.* = .{
                .name = src.name,
                .type = if (@hasField(@TypeOf(src), "type")) src.type else void,
                .value = if (@hasField(@TypeOf(src), "value")) src.value else 0,
            };
            const final = out;
            break :blk &final;
        }
    };
}

/// Parameter types of a function type; `null` marks `anytype` / generic parameters.
pub inline fn paramTypes(comptime F: type) []const ?type {
    return comptime blk: {
        const info = @typeInfo(F).@"fn";
        if (@hasField(@TypeOf(info), "param_types")) break :blk info.param_types;
        var out: [info.params.len]?type = undefined;
        for (&out, info.params) |*t, p| t.* = p.type;
        const final = out;
        break :blk &final;
    };
}
