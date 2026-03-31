//! X-Plane command integration.
//!
//! Maps keyboard inputs to autopilot dataref adjustments.
//! Uses the existing WebSocket `dataref_set_values` message to push
//! value changes to X-Plane in real time.

const std = @import("std");
const protocol = @import("protocol.zig");
const FlightData = @import("flight_data.zig").FlightData;
const DatarefRegistry = @import("dataref_registry.zig").DatarefRegistry;
const FieldMapping = @import("dataref_registry.zig").FieldMapping;
const XPlaneClient = @import("xplane_client.zig").XPlaneClient;

pub const CommandId = enum(u8) {
    ap_toggle,
    hdg_up,
    hdg_down,
    alt_up,
    alt_down,
    spd_up,
    spd_down,
    vs_up,
    vs_down,
};

/// Compute the new dataref value for a given command.
/// Returns the target FieldMapping and new value.
pub fn computeValue(cmd: CommandId, fd: *const FlightData) struct { field: FieldMapping, value: f64 } {
    return switch (cmd) {
        .ap_toggle => .{
            .field = .ap_state,
            .value = if (fd.ap_state != 0) 0 else 1,
        },
        .hdg_up => .{
            .field = .ap_hdg_deg,
            .value = wrapHeading(fd.ap_hdg_deg + 1),
        },
        .hdg_down => .{
            .field = .ap_hdg_deg,
            .value = wrapHeading(fd.ap_hdg_deg - 1),
        },
        .alt_up => .{
            .field = .ap_alt_ft,
            .value = clampAlt(fd.ap_alt_ft + 100),
        },
        .alt_down => .{
            .field = .ap_alt_ft,
            .value = clampAlt(fd.ap_alt_ft - 100),
        },
        .spd_up => .{
            .field = .ap_speed_kts,
            .value = clampSpeed(fd.ap_speed_kts + 1),
        },
        .spd_down => .{
            .field = .ap_speed_kts,
            .value = clampSpeed(fd.ap_speed_kts - 1),
        },
        .vs_up => .{
            .field = .ap_vsi_fpm,
            .value = @as(f64, fd.ap_vsi_fpm) + 100,
        },
        .vs_down => .{
            .field = .ap_vsi_fpm,
            .value = @as(f64, fd.ap_vsi_fpm) - 100,
        },
    };
}

/// Execute a command: compute value, look up dataref ID, send to X-Plane.
pub fn execute(
    client: *XPlaneClient,
    cmd: CommandId,
    fd: *const FlightData,
    registry: *const DatarefRegistry,
) void {
    const result = computeValue(cmd, fd);

    // Find the dataref ID for this field
    const id = findDatarefId(registry, result.field) orelse return;

    // Build and send the set-value message
    var msg_buf: [512]u8 = undefined;
    const msg = protocol.buildSetValueMessage(&msg_buf, 0, id, result.value) catch return;
    client.wsSendText(msg) catch {};
}

/// Map a key character to a CommandId. Returns null for non-command keys.
pub fn keyToCommand(key: u8) ?CommandId {
    return switch (key) {
        'a' => .ap_toggle,
        'h' => .hdg_up,
        'H' => .hdg_down,
        'v' => .alt_up,
        'V' => .alt_down,
        's' => .spd_up,
        'S' => .spd_down,
        'w' => .vs_up,
        'W' => .vs_down,
        else => null,
    };
}

// ============================================================================
// Helpers
// ============================================================================

fn wrapHeading(hdg: f32) f64 {
    var h: f64 = @floatCast(hdg);
    if (h >= 360.0) h -= 360.0;
    if (h < 0.0) h += 360.0;
    return h;
}

fn clampAlt(alt: f32) f64 {
    return @max(0.0, @min(50000.0, @as(f64, @floatCast(alt))));
}

fn clampSpeed(spd: f32) f64 {
    return @max(0.0, @min(500.0, @as(f64, @floatCast(spd))));
}

fn findDatarefId(registry: *const DatarefRegistry, field: FieldMapping) ?u64 {
    for (0..registry.count) |i| {
        if (registry.entries[i].field == field) return registry.entries[i].id;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "heading wrap" {
    try std.testing.expectEqual(@as(f64, 0.0), wrapHeading(360.0));
    try std.testing.expectEqual(@as(f64, 1.0), wrapHeading(361.0));
    try std.testing.expectEqual(@as(f64, 359.0), wrapHeading(-1.0));
    try std.testing.expectEqual(@as(f64, 180.0), wrapHeading(180.0));
}

test "altitude clamp" {
    try std.testing.expectEqual(@as(f64, 0.0), clampAlt(-100));
    try std.testing.expectEqual(@as(f64, 50000.0), clampAlt(51000));
    try std.testing.expectEqual(@as(f64, 35000.0), clampAlt(35000));
}

test "speed clamp" {
    try std.testing.expectEqual(@as(f64, 0.0), clampSpeed(-10));
    try std.testing.expectEqual(@as(f64, 500.0), clampSpeed(600));
    try std.testing.expectEqual(@as(f64, 250.0), clampSpeed(250));
}

test "computeValue heading" {
    var fd = FlightData{};
    fd.ap_hdg_deg = 359;

    const up = computeValue(.hdg_up, &fd);
    try std.testing.expectEqual(FieldMapping.ap_hdg_deg, up.field);
    try std.testing.expectEqual(@as(f64, 0.0), up.value);

    fd.ap_hdg_deg = 0;
    const down = computeValue(.hdg_down, &fd);
    try std.testing.expectEqual(@as(f64, 359.0), down.value);
}

test "computeValue ap toggle" {
    var fd = FlightData{};
    fd.ap_state = 0;

    const on = computeValue(.ap_toggle, &fd);
    try std.testing.expectEqual(@as(f64, 1.0), on.value);

    fd.ap_state = 1;
    const off = computeValue(.ap_toggle, &fd);
    try std.testing.expectEqual(@as(f64, 0.0), off.value);
}

test "computeValue altitude" {
    var fd = FlightData{};
    fd.ap_alt_ft = 35000;

    const up = computeValue(.alt_up, &fd);
    try std.testing.expectEqual(@as(f64, 35100.0), up.value);

    fd.ap_alt_ft = 0;
    const down = computeValue(.alt_down, &fd);
    try std.testing.expectEqual(@as(f64, 0.0), down.value); // clamped at 0
}

test "keyToCommand mapping" {
    try std.testing.expectEqual(CommandId.ap_toggle, keyToCommand('a').?);
    try std.testing.expectEqual(CommandId.hdg_up, keyToCommand('h').?);
    try std.testing.expectEqual(CommandId.hdg_down, keyToCommand('H').?);
    try std.testing.expectEqual(CommandId.alt_up, keyToCommand('v').?);
    try std.testing.expectEqual(CommandId.vs_down, keyToCommand('W').?);
    try std.testing.expect(keyToCommand('x') == null);
    try std.testing.expect(keyToCommand('1') == null);
}
