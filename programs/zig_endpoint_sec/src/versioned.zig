//! Message-version gating.
//!
//! `es_message_t.version` tells which fields the kernel actually filled in;
//! a field the header marks "available only if message version >= N" holds
//! garbage on older messages. The table of those fields is generated from the
//! header comments (`layout_anchors.min_versions`), so accessors here cannot
//! disagree with Apple's documentation without the generator noticing.

const std = @import("std");
const sys = @import("sys.zig");
const anchors = @import("layout_anchors.zig");

fn baseName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// Minimum `es_message_t.version` at which `field` of `T` is meaningful; 1 when
/// the header places no restriction on it.
pub fn minVersion(comptime T: type, comptime field: []const u8) u32 {
    const v = comptime blk: {
        const name = baseName(T);
        for (anchors.min_versions) |entry| {
            if (std.mem.eql(u8, entry.type, name) and std.mem.eql(u8, entry.field, field)) break :blk entry.min_version;
        }
        break :blk 1;
    };
    return v;
}

/// True when a message of `version` carries `field` of `T`.
pub inline fn has(comptime T: type, version: u32, comptime field: []const u8) bool {
    return version >= minVersion(T, field);
}

/// Read a direct field of `T`, or null when the message is too old to carry it.
pub inline fn get(comptime T: type, ptr: *const T, version: u32, comptime field: []const u8) ?@FieldType(T, field) {
    if (!has(T, version, field)) return null;
    return @field(ptr, field);
}

// ───────────────────────────── tests ─────────────────────────────

test "every generated gate names a real field (directly or through an anonymous aggregate)" {
    @setEvalBranchQuota(20_000);
    inline for (anchors.min_versions) |v| {
        const T = @field(sys, v.type);
        try std.testing.expect(hasFieldDeep(T, v.field));
        try std.testing.expect(v.min_version >= 2);
    }
}

fn hasFieldDeep(comptime T: type, comptime name: []const u8) bool {
    if (@hasField(T, name)) return true;
    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            .@"struct", .@"union" => if (hasFieldDeep(f.type, name)) return true,
            else => {},
        }
    }
    return false;
}

test "gates match the header for the fields the wrappers rely on" {
    try std.testing.expectEqual(@as(u32, 2), minVersion(sys.es_process_t, "tty"));
    try std.testing.expectEqual(@as(u32, 3), minVersion(sys.es_process_t, "start_time"));
    try std.testing.expectEqual(@as(u32, 4), minVersion(sys.es_process_t, "responsible_audit_token"));
    try std.testing.expectEqual(@as(u32, 4), minVersion(sys.es_process_t, "parent_audit_token"));
    try std.testing.expectEqual(@as(u32, 10), minVersion(sys.es_process_t, "cs_validation_category"));
    try std.testing.expectEqual(@as(u32, 11), minVersion(sys.es_process_t, "cdhash_full"));
    try std.testing.expectEqual(@as(u32, 7), minVersion(sys.es_event_exec_t, "dyld_exec_path"));
    try std.testing.expectEqual(@as(u32, 2), minVersion(sys.es_event_exec_t, "script"));
    try std.testing.expectEqual(@as(u32, 3), minVersion(sys.es_event_exec_t, "cwd"));
    try std.testing.expectEqual(@as(u32, 4), minVersion(sys.es_event_exec_t, "last_fd"));
    try std.testing.expectEqual(@as(u32, 6), minVersion(sys.es_event_exec_t, "image_cputype"));
    try std.testing.expectEqual(@as(u32, 4), minVersion(sys.es_message_t, "thread"));
    try std.testing.expectEqual(@as(u32, 2), minVersion(sys.es_message_t, "seq_num"));
    try std.testing.expectEqual(@as(u32, 1), minVersion(sys.es_message_t, "deadline"));
    try std.testing.expectEqual(@as(u32, 9), minVersion(sys.es_event_signal_t, "instigator"));
}

test "get returns null below the gate and the value at or above it" {
    var p: sys.es_process_t = undefined;
    p.ppid = 42;
    p.tty = null;
    p.cs_validation_category = .ES_CS_VALIDATION_CATEGORY_PLATFORM;
    try std.testing.expectEqual(@as(?sys.pid_t, 42), get(sys.es_process_t, &p, 1, "ppid"));
    try std.testing.expect(get(sys.es_process_t, &p, 9, "cs_validation_category") == null);
    try std.testing.expectEqual(sys.es_cs_validation_category_t.ES_CS_VALIDATION_CATEGORY_PLATFORM, get(sys.es_process_t, &p, 10, "cs_validation_category").?);
}
