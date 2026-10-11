//! Field reflection that compiles on both Zig 0.16 and 0.17.
//!
//! 0.17 removed `std.meta.fields` and reshaped `std.builtin.Type`: struct,
//! union and enum infos carry parallel `field_names` / `field_types` /
//! `field_values` slices instead of a `fields` slice of records. `fields`
//! below returns the old record shape from either, so the comptime loops over
//! the SDK types stay as they were.

pub const Field = struct {
    name: [:0]const u8,
    /// Struct and union fields only.
    type: type = void,
    /// Enum fields only.
    value: comptime_int = 0,
};

fn count(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        inline .@"struct", .@"union", .@"enum" => |info| if (@hasField(@TypeOf(info), "fields"))
            info.fields.len
        else
            info.field_names.len,
        else => @compileError("fields: not a struct, union or enum: " ++ @typeName(T)),
    };
}

pub fn fields(comptime T: type) [count(T)]Field {
    return comptime switch (@typeInfo(T)) {
        inline .@"struct", .@"union", .@"enum" => |info, tag| blk: {
            if (@hasField(@TypeOf(info), "fields")) {
                // Zig 0.16
                var out: [info.fields.len]Field = undefined;
                for (&out, info.fields) |*o, f| o.* = switch (tag) {
                    .@"enum" => .{ .name = f.name, .value = f.value },
                    else => .{ .name = f.name, .type = f.type },
                };
                break :blk out;
            } else {
                // Zig 0.17
                var out: [info.field_names.len]Field = undefined;
                for (&out, info.field_names, 0..) |*o, n, i| o.* = switch (tag) {
                    .@"enum" => .{ .name = n, .value = info.field_values[i] },
                    else => .{ .name = n, .type = info.field_types[i] },
                };
                break :blk out;
            }
        },
        else => @compileError("fields: not a struct, union or enum: " ++ @typeName(T)),
    };
}
