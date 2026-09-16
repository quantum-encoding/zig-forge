//! Layout anchors: compare the hand-written `sys.zig` against the numbers Apple's
//! clang computed from the SDK headers (`layout_anchors.zig`).
//!
//! This is the external test vector for the bindings. A struct transcribed with
//! a field out of order, a wrong reserved-array length, or an enum value off by
//! one shows up here as a failing offset, not as a silent misread in production.

const std = @import("std");
const sys = @import("sys.zig");
const anchors = @import("layout_anchors.zig");
const darwin = @import("darwin_kit");

const Resolved = struct { offset: usize, type: type };

/// Resolve one path segment inside `T`: a direct field, or a member promoted
/// out of an anonymous C union/struct (modelled as a named aggregate field in Zig).
fn resolveSegment(comptime T: type, comptime name: []const u8) ?Resolved {
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => {},
        else => return null,
    }
    if (@hasField(T, name)) {
        return .{ .offset = fieldOffset(T, name), .type = @FieldType(T, name) };
    }
    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            .@"struct", .@"union" => if (resolveSegment(f.type, name)) |inner| {
                return .{ .offset = fieldOffset(T, f.name) + inner.offset, .type = inner.type };
            },
            else => {},
        }
    }
    return null;
}

/// `@offsetOf` is defined for structs only; every union member starts at 0.
fn fieldOffset(comptime T: type, comptime name: []const u8) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => @offsetOf(T, name),
        else => 0,
    };
}

/// Resolve a dotted C member designator such as `destination.new_path.dir`.
fn resolvePath(comptime T: type, comptime path: []const u8) ?usize {
    var current: type = T;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        const r = resolveSegment(current, seg) orelse return null;
        offset += r.offset;
        current = r.type;
    }
    return offset;
}

test "anchor: every ES struct has clang's size and field offsets" {
    @setEvalBranchQuota(200_000);
    var failures: usize = 0;
    inline for (anchors.structs) |s| {
        if (!@hasDecl(sys, s.name)) {
            std.debug.print("sys.zig is missing {s}\n", .{s.name});
            failures += 1;
        } else {
            const T = @field(sys, s.name);
            if (@sizeOf(T) != s.size) {
                std.debug.print("{s}: sizeof {d} != clang {d}\n", .{ s.name, @sizeOf(T), s.size });
                failures += 1;
            }
            inline for (s.fields) |f| {
                if (comptime resolvePath(T, f.path)) |off| {
                    if (off != f.offset) {
                        std.debug.print("{s}.{s}: offset {d} != clang {d}\n", .{ s.name, f.path, off, f.offset });
                        failures += 1;
                    }
                } else {
                    std.debug.print("{s}.{s}: no such field in sys.zig\n", .{ s.name, f.path });
                    failures += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "anchor: every enumerator has clang's value and every enum is 4 bytes" {
    @setEvalBranchQuota(20_000);
    var failures: usize = 0;
    inline for (anchors.enums) |e| {
        const E = @field(sys.enums, e.name);
        if (@sizeOf(E) != e.size) {
            std.debug.print("{s}: sizeof {d} != clang {d}\n", .{ e.name, @sizeOf(E), e.size });
            failures += 1;
        }
        inline for (e.tags) |t| {
            const v: i64 = @intFromEnum(@field(E, t.name));
            if (v != t.value) {
                std.debug.print("{s}.{s}: {d} != clang {d}\n", .{ e.name, t.name, v, t.value });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "anchor: fixed-size array typedefs" {
    inline for (anchors.arrays) |a| {
        try std.testing.expectEqual(a.size, @sizeOf(@field(sys, a.name)));
    }
}

test "anchor: system types ES embeds match the SDK" {
    const map = .{
        .{ "stat", sys.struct_stat },
        .{ "statfs", sys.struct_statfs },
        .{ "attrlist", sys.struct_attrlist },
        .{ "timespec", sys.timespec },
        .{ "timeval", sys.timeval },
        .{ "audit_token_t", sys.audit_token_t },
        .{ "uuid_t", sys.uuid_t },
        .{ "acl_t", sys.acl_t },
        .{ "cpu_type_t", sys.cpu_type_t },
        .{ "cpu_subtype_t", sys.cpu_subtype_t },
        .{ "user_addr_t", sys.user_addr_t },
        .{ "user_size_t", sys.user_size_t },
        .{ "dev_t", sys.dev_t },
        .{ "mode_t", sys.mode_t },
        .{ "uid_t", sys.uid_t },
        .{ "gid_t", sys.gid_t },
        .{ "pid_t", sys.pid_t },
    };
    inline for (anchors.foreign) |f| {
        var found = false;
        inline for (map) |entry| {
            if (comptime std.mem.eql(u8, entry[0], f.name)) {
                found = true;
                if (@sizeOf(entry[1]) != f.size) {
                    std.debug.print("{s}: sizeof {d} != clang {d}\n", .{ f.name, @sizeOf(entry[1]), f.size });
                    return error.TestExpectedEqual;
                }
            }
        }
        if (!found) {
            std.debug.print("no Zig type mapped for foreign anchor {s}\n", .{f.name});
            return error.TestExpectedEqual;
        }
    }
}

test "the events union covers every non-reserved event type" {
    @setEvalBranchQuota(20_000);
    // Each ES_EVENT_TYPE_{AUTH,NOTIFY}_X must have an `x` member in es_events_t.
    var missing: usize = 0;
    inline for (std.meta.fields(sys.es_event_type_t)) |f| {
        const prefix_auth = "ES_EVENT_TYPE_AUTH_";
        const prefix_notify = "ES_EVENT_TYPE_NOTIFY_";
        const member: ?[]const u8 = comptime blk: {
            if (std.mem.startsWith(u8, f.name, prefix_auth)) break :blk &lower(f.name[prefix_auth.len..]);
            if (std.mem.startsWith(u8, f.name, prefix_notify)) break :blk &lower(f.name[prefix_notify.len..]);
            break :blk null;
        };
        if (member) |m| {
            if (!@hasField(sys.es_events_t, m)) {
                std.debug.print("es_events_t has no member '{s}' for {s}\n", .{ m, f.name });
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

fn lower(comptime s: []const u8) [s.len]u8 {
    var out: [s.len]u8 = undefined;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "darwin_kit audit token is the ES audit_token_t" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(darwin.AuditToken));
    try std.testing.expect(sys.audit_token_t == darwin.AuditToken);
}
