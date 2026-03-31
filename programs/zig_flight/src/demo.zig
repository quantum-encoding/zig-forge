//! Flight recording and replay.
//!
//! Binary format for recording dataref streams and replaying them without X-Plane.
//! Compact fixed-size frames: ~136 bytes/frame × 10Hz × 1hr ≈ 4.9 MB.
//! Uses C file API for Zig 0.16 compatibility.

const std = @import("std");
const FlightData = @import("flight_data.zig").FlightData;

// C file API — fseek not exposed via std.c in Zig 0.16
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
const SEEK_SET: c_int = 0;

// ============================================================================
// Recording format
// ============================================================================

pub const MAGIC = [4]u8{ 'Z', 'F', 'L', 'T' };
pub const FORMAT_VERSION: u16 = 1;
pub const FIELD_COUNT: u16 = 34; // Number of serialized fields

pub const DemoHeader = extern struct {
    magic: [4]u8 = MAGIC,
    version: u16 = FORMAT_VERSION,
    field_count: u16 = FIELD_COUNT,
    frame_count: u64 = 0,
    _reserved: [16]u8 = [_]u8{0} ** 16,
};

/// Packed frame data: timestamp + all FlightData numeric fields.
/// Layout: u64 timestamp, then 32 f32 fields, then 2 f64 fields = 8 + 128 + 16 = 152 bytes.
pub const DemoFrame = extern struct {
    timestamp_ms: u64 = 0,
    // Attitude
    pitch_deg: f32 = 0,
    roll_deg: f32 = 0,
    heading_mag_deg: f32 = 0,
    slip_deg: f32 = 0,
    // Air data
    airspeed_kts: f32 = 0,
    altitude_ft: f32 = 0,
    vsi_fpm: f32 = 0,
    radio_alt_ft: f32 = 0,
    barometer_inhg: f32 = 29.92,
    oat_c: f32 = 15.0,
    airspeed_trend: f32 = 0,
    // Navigation (f32 parts)
    groundspeed_kts: f32 = 0,
    ground_track_deg: f32 = 0,
    wind_dir_deg: f32 = 0,
    wind_speed_kts: f32 = 0,
    nav1_dme_nm: f32 = 0,
    nav1_hdef_dots: f32 = 0,
    nav1_vdef_dots: f32 = 0,
    gps_dme_nm: f32 = 0,
    gps_bearing_deg: f32 = 0,
    // Engine
    n1_percent: f32 = 0,
    n2_percent: f32 = 0,
    itt_deg_c: f32 = 0,
    oil_psi: f32 = 0,
    oil_temp_c: f32 = 0,
    fuel_flow_kgs: f32 = 0,
    // Fuel
    fuel_quantity: f32 = 0,
    fuel_used_kg: f32 = 0,
    fuel_total_kg: f32 = 0,
    // Autopilot
    ap_alt_ft: f32 = 0,
    ap_hdg_deg: f32 = 0,
    ap_speed_kts: f32 = 0,
    // Navigation (f64 parts — at end for alignment)
    latitude: f64 = 0,
    longitude: f64 = 0,
};

comptime {
    // Verify header is exactly 32 bytes
    if (@sizeOf(DemoHeader) != 32) @compileError("DemoHeader must be 32 bytes");
}

fn timestampMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ============================================================================
// Serialization helpers
// ============================================================================

fn flightDataToFrame(fd: *const FlightData) DemoFrame {
    return .{
        .timestamp_ms = timestampMs(),
        .pitch_deg = fd.pitch_deg,
        .roll_deg = fd.roll_deg,
        .heading_mag_deg = fd.heading_mag_deg,
        .slip_deg = fd.slip_deg,
        .airspeed_kts = fd.airspeed_kts,
        .altitude_ft = fd.altitude_ft,
        .vsi_fpm = fd.vsi_fpm,
        .radio_alt_ft = fd.radio_alt_ft,
        .barometer_inhg = fd.barometer_inhg,
        .oat_c = fd.oat_c,
        .airspeed_trend = fd.airspeed_trend,
        .groundspeed_kts = fd.groundspeed_kts,
        .ground_track_deg = fd.ground_track_deg,
        .wind_dir_deg = fd.wind_dir_deg,
        .wind_speed_kts = fd.wind_speed_kts,
        .nav1_dme_nm = fd.nav1_dme_nm,
        .nav1_hdef_dots = fd.nav1_hdef_dots,
        .nav1_vdef_dots = fd.nav1_vdef_dots,
        .gps_dme_nm = fd.gps_dme_nm,
        .gps_bearing_deg = fd.gps_bearing_deg,
        .n1_percent = fd.n1_percent,
        .n2_percent = fd.n2_percent,
        .itt_deg_c = fd.itt_deg_c,
        .oil_psi = fd.oil_psi,
        .oil_temp_c = fd.oil_temp_c,
        .fuel_flow_kgs = fd.fuel_flow_kgs,
        .fuel_quantity = fd.fuel_quantity,
        .fuel_used_kg = fd.fuel_used_kg,
        .fuel_total_kg = fd.fuel_total_kg,
        .ap_alt_ft = fd.ap_alt_ft,
        .ap_hdg_deg = fd.ap_hdg_deg,
        .ap_speed_kts = fd.ap_speed_kts,
        .latitude = fd.latitude,
        .longitude = fd.longitude,
    };
}

fn frameToFlightData(frame: *const DemoFrame, fd: *FlightData) void {
    fd.pitch_deg = frame.pitch_deg;
    fd.roll_deg = frame.roll_deg;
    fd.heading_mag_deg = frame.heading_mag_deg;
    fd.slip_deg = frame.slip_deg;
    fd.airspeed_kts = frame.airspeed_kts;
    fd.altitude_ft = frame.altitude_ft;
    fd.vsi_fpm = frame.vsi_fpm;
    fd.radio_alt_ft = frame.radio_alt_ft;
    fd.barometer_inhg = frame.barometer_inhg;
    fd.oat_c = frame.oat_c;
    fd.airspeed_trend = frame.airspeed_trend;
    fd.groundspeed_kts = frame.groundspeed_kts;
    fd.ground_track_deg = frame.ground_track_deg;
    fd.wind_dir_deg = frame.wind_dir_deg;
    fd.wind_speed_kts = frame.wind_speed_kts;
    fd.nav1_dme_nm = frame.nav1_dme_nm;
    fd.nav1_hdef_dots = frame.nav1_hdef_dots;
    fd.nav1_vdef_dots = frame.nav1_vdef_dots;
    fd.gps_dme_nm = frame.gps_dme_nm;
    fd.gps_bearing_deg = frame.gps_bearing_deg;
    fd.n1_percent = frame.n1_percent;
    fd.n2_percent = frame.n2_percent;
    fd.itt_deg_c = frame.itt_deg_c;
    fd.oil_psi = frame.oil_psi;
    fd.oil_temp_c = frame.oil_temp_c;
    fd.fuel_flow_kgs = frame.fuel_flow_kgs;
    fd.fuel_quantity = frame.fuel_quantity;
    fd.fuel_used_kg = frame.fuel_used_kg;
    fd.fuel_total_kg = frame.fuel_total_kg;
    fd.ap_alt_ft = frame.ap_alt_ft;
    fd.ap_hdg_deg = frame.ap_hdg_deg;
    fd.ap_speed_kts = frame.ap_speed_kts;
    fd.latitude = frame.latitude;
    fd.longitude = frame.longitude;
    fd.update_tick += 1;
}

// ============================================================================
// DemoRecorder
// ============================================================================

pub const DemoRecorder = struct {
    file: *std.c.FILE,
    frame_count: u64 = 0,

    pub fn init(path: [*:0]const u8) !DemoRecorder {
        const file = std.c.fopen(path, "wb") orelse return error.CannotOpenFile;

        // Write header with frame_count=0 (patched on finish)
        const header = DemoHeader{};
        const header_bytes: [*]const u8 = @ptrCast(&header);
        const written = std.c.fwrite(header_bytes, @sizeOf(DemoHeader), 1, file);
        if (written != 1) {
            _ = std.c.fclose(file);
            return error.WriteFailed;
        }

        return .{ .file = file };
    }

    pub fn recordFrame(self: *DemoRecorder, fd: *const FlightData) void {
        const frame = flightDataToFrame(fd);
        const frame_bytes: [*]const u8 = @ptrCast(&frame);
        const written = std.c.fwrite(frame_bytes, @sizeOf(DemoFrame), 1, self.file);
        if (written == 1) {
            self.frame_count += 1;
        }
    }

    pub fn finish(self: *DemoRecorder) void {
        // Seek back to header and patch frame_count
        _ = fseek(self.file, 0, SEEK_SET);
        var header = DemoHeader{ .frame_count = self.frame_count };
        const header_bytes: [*]const u8 = @ptrCast(&header);
        _ = std.c.fwrite(header_bytes, @sizeOf(DemoHeader), 1, self.file);
        _ = std.c.fclose(self.file);
    }
};

// ============================================================================
// DemoPlayer
// ============================================================================

pub const DemoPlayer = struct {
    file: *std.c.FILE,
    header: DemoHeader = .{},
    frames_read: u64 = 0,

    pub fn init(path: [*:0]const u8) !DemoPlayer {
        const file = std.c.fopen(path, "rb") orelse return error.CannotOpenFile;

        // Read and validate header
        var header: DemoHeader = undefined;
        const header_ptr: [*]u8 = @ptrCast(&header);
        const read_count = std.c.fread(header_ptr, @sizeOf(DemoHeader), 1, file);
        if (read_count != 1) {
            _ = std.c.fclose(file);
            return error.ReadFailed;
        }

        if (!std.mem.eql(u8, &header.magic, &MAGIC)) {
            _ = std.c.fclose(file);
            return error.InvalidFormat;
        }

        if (header.version != FORMAT_VERSION) {
            _ = std.c.fclose(file);
            return error.UnsupportedVersion;
        }

        return .{ .file = file, .header = header };
    }

    /// Read the next frame and apply to FlightData. Returns false at EOF.
    pub fn nextFrame(self: *DemoPlayer, fd: *FlightData) bool {
        var frame: DemoFrame = undefined;
        const frame_ptr: [*]u8 = @ptrCast(&frame);
        const read_count = std.c.fread(frame_ptr, @sizeOf(DemoFrame), 1, self.file);
        if (read_count != 1) return false;

        frameToFlightData(&frame, fd);
        self.frames_read += 1;
        return true;
    }

    /// Seek back to the first frame for looping playback.
    pub fn reset(self: *DemoPlayer) void {
        _ = fseek(self.file, @intCast(@sizeOf(DemoHeader)), SEEK_SET);
        self.frames_read = 0;
    }

    pub fn frameCount(self: *const DemoPlayer) u64 {
        return self.header.frame_count;
    }

    pub fn isFinished(self: *const DemoPlayer) bool {
        return self.frames_read >= self.header.frame_count;
    }

    pub fn deinit(self: *DemoPlayer) void {
        _ = std.c.fclose(self.file);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DemoHeader size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(DemoHeader));
}

test "DemoFrame round-trip" {
    // Create test flight data
    var fd = FlightData{};
    fd.airspeed_kts = 280.5;
    fd.altitude_ft = 35000;
    fd.heading_mag_deg = 275.3;
    fd.pitch_deg = 2.5;
    fd.roll_deg = -5.0;
    fd.vsi_fpm = -500;
    fd.radio_alt_ft = 2200;
    fd.n1_percent = 87.5;
    fd.fuel_total_kg = 5000;
    fd.latitude = 51.477928;
    fd.longitude = -0.001545;
    fd.ap_hdg_deg = 270;

    // Serialize
    const frame = flightDataToFrame(&fd);

    // Deserialize into fresh FlightData
    var fd2 = FlightData{};
    frameToFlightData(&frame, &fd2);

    // Verify all fields match
    try std.testing.expectEqual(fd.airspeed_kts, fd2.airspeed_kts);
    try std.testing.expectEqual(fd.altitude_ft, fd2.altitude_ft);
    try std.testing.expectEqual(fd.heading_mag_deg, fd2.heading_mag_deg);
    try std.testing.expectEqual(fd.pitch_deg, fd2.pitch_deg);
    try std.testing.expectEqual(fd.roll_deg, fd2.roll_deg);
    try std.testing.expectEqual(fd.vsi_fpm, fd2.vsi_fpm);
    try std.testing.expectEqual(fd.radio_alt_ft, fd2.radio_alt_ft);
    try std.testing.expectEqual(fd.n1_percent, fd2.n1_percent);
    try std.testing.expectEqual(fd.fuel_total_kg, fd2.fuel_total_kg);
    try std.testing.expectEqual(fd.latitude, fd2.latitude);
    try std.testing.expectEqual(fd.longitude, fd2.longitude);
    try std.testing.expectEqual(fd.ap_hdg_deg, fd2.ap_hdg_deg);
    try std.testing.expectEqual(@as(u64, 1), fd2.update_tick);
}

test "recorder and player round-trip" {
    const path: [*:0]const u8 = "/tmp/zig_flight_test.zflt";

    // Record 3 frames
    {
        var rec = try DemoRecorder.init(path);

        var fd = FlightData{};
        fd.airspeed_kts = 100;
        fd.altitude_ft = 1000;
        fd.latitude = 51.0;
        fd.longitude = -1.0;
        rec.recordFrame(&fd);

        fd.airspeed_kts = 200;
        fd.altitude_ft = 2000;
        rec.recordFrame(&fd);

        fd.airspeed_kts = 300;
        fd.altitude_ft = 3000;
        rec.recordFrame(&fd);

        try std.testing.expectEqual(@as(u64, 3), rec.frame_count);
        rec.finish();
    }

    // Play back
    {
        var player = try DemoPlayer.init(path);
        defer player.deinit();

        try std.testing.expectEqual(@as(u64, 3), player.frameCount());

        var fd = FlightData{};

        try std.testing.expect(player.nextFrame(&fd));
        try std.testing.expectEqual(@as(f32, 100), fd.airspeed_kts);
        try std.testing.expectEqual(@as(f32, 1000), fd.altitude_ft);
        try std.testing.expectEqual(@as(f64, 51.0), fd.latitude);

        try std.testing.expect(player.nextFrame(&fd));
        try std.testing.expectEqual(@as(f32, 200), fd.airspeed_kts);

        try std.testing.expect(player.nextFrame(&fd));
        try std.testing.expectEqual(@as(f32, 300), fd.airspeed_kts);
        try std.testing.expectEqual(@as(f32, 3000), fd.altitude_ft);

        // EOF
        try std.testing.expect(!player.nextFrame(&fd));
        try std.testing.expect(player.isFinished());

        // Reset and replay
        player.reset();
        try std.testing.expect(player.nextFrame(&fd));
        try std.testing.expectEqual(@as(f32, 100), fd.airspeed_kts);
    }
}

test "invalid file" {
    const result = DemoPlayer.init("/tmp/nonexistent_zig_flight_test.zflt");
    try std.testing.expectError(error.CannotOpenFile, result);
}
