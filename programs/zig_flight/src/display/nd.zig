//! Navigation Display — compass rose, NAV/GPS radios, position, wind.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const tui = @import("tui_backend.zig");
const FlightData = @import("../flight_data.zig").FlightData;

pub fn render(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const w = fb.width;
    const h = fb.height -| 1;
    fb.drawBox(0, 0, w, h, .dim);
    fb.putStr(0, 3, " NAV ", .bright_green, .black, true);

    renderCompassRose(fb, fd);
    renderNavRadio(fb, fd);
    renderGpsInfo(fb, fd);
    renderPosition(fb, fd);
    renderWindInfo(fb, fd);
}

fn renderCompassRose(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    // Simplified compass rose centered at row 5, col 18
    const cx: u16 = 18;
    const cy: u16 = 5;
    const r: u16 = 3; // radius in rows

    fb.putStr(2, cx + 2, "COMPASS", .dim, .black, false);

    // Cardinal directions
    fb.putStr(cy - r, cx, "N", .bright_green, .black, true);
    fb.putStr(cy + r, cx, "S", .green, .black, false);
    fb.putStr(cy, cx - r * 2, "W", .green, .black, false);
    fb.putStr(cy, cx + r * 2, "E", .green, .black, false);

    // Intercardinal
    fb.putStr(cy - r + 1, cx - r, "NW", .dim, .black, false);
    fb.putStr(cy - r + 1, cx + r, "NE", .dim, .black, false);
    fb.putStr(cy + r - 1, cx - r, "SW", .dim, .black, false);
    fb.putStr(cy + r - 1, cx + r, "SE", .dim, .black, false);

    // Center dot (aircraft)
    fb.setCell(cy, cx, 0x25CF, .bright_white, .black, true); // ●

    // Current heading readout
    fb.putFmt(cy + r + 1, cx - 4, "HDG: {d:>05.1}M", .{fd.heading_mag_deg}, .bright_green, .black, true);
    fb.putFmt(cy + r + 2, cx - 4, "TRK: {d:>05.1}M", .{fd.ground_track_deg}, .green, .black, false);
}

fn renderNavRadio(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const col: u16 = 42;
    fb.drawBox(1, col, 28, 7, .dim);
    fb.putStr(1, col + 1, " NAV1 ", .cyan, .black, true);

    fb.putFmt(2, col + 2, "DME:  {d:>6.1} NM", .{fd.nav1_dme_nm}, .green, .black, false);

    // Horizontal deviation dots: ○ ○ ○ ● ○ ○ ○ (7 dots, center = on course)
    fb.putStr(3, col + 2, "HDEV: ", .dim, .black, false);
    renderDeviationDots(fb, 3, col + 8, fd.nav1_hdef_dots);

    // Vertical deviation dots
    fb.putStr(4, col + 2, "VDEV: ", .dim, .black, false);
    renderDeviationDots(fb, 4, col + 8, fd.nav1_vdef_dots);

    // Deviation values
    fb.putFmt(5, col + 2, "H: {d:>5.2} dots", .{fd.nav1_hdef_dots}, .cyan, .black, false);
    fb.putFmt(6, col + 2, "V: {d:>5.2} dots", .{fd.nav1_vdef_dots}, .cyan, .black, false);
}

fn renderDeviationDots(fb: *renderer_mod.FrameBuffer, row: u16, col: u16, dots: f32) void {
    // 5-dot display: ○ ○ ● ○ ○ with diamond at deviation position
    const center: f32 = 2.0;
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        const offset = @as(f32, @floatFromInt(i)) - center;
        const is_active = @abs(dots - offset) < 0.5;
        const char: u21 = if (is_active) 0x25C6 else 0x25CB; // ◆ or ○
        const color: tui.Color = if (is_active) .bright_green else .dim;
        fb.setCell(row, col + i * 2, char, color, .black, false);
    }
}

fn renderGpsInfo(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const col: u16 = 42;
    fb.drawBox(8, col, 28, 5, .dim);
    fb.putStr(8, col + 1, " GPS ", .cyan, .black, true);

    fb.putFmt(9, col + 2, "DME:  {d:>6.1} NM", .{fd.gps_dme_nm}, .green, .black, false);
    fb.putFmt(10, col + 2, "BRG:  {d:>05.1} M", .{fd.gps_bearing_deg}, .green, .black, false);
    fb.putFmt(11, col + 2, "GS:   {d:>5.0} kts", .{fd.groundspeed_kts}, .green, .black, false);
}

fn renderPosition(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(11, 2, 35, .dim);
    fb.putStr(11, 2, " POSITION ", .dim, .black, false);

    // Format lat/lon with N/S E/W
    const lat_dir: u8 = if (fd.latitude >= 0) 'N' else 'S';
    const lon_dir: u8 = if (fd.longitude >= 0) 'E' else 'W';
    fb.putFmt(12, 3, "LAT: {c} {d:>9.4}", .{ lat_dir, @abs(fd.latitude) }, .green, .black, false);
    fb.putFmt(13, 3, "LON: {c} {d:>9.4}", .{ lon_dir, @abs(fd.longitude) }, .green, .black, false);
}

fn renderWindInfo(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(15, 2, 35, .dim);
    fb.putStr(15, 2, " WIND ", .dim, .black, false);

    fb.putFmt(16, 3, "DIR: {d:>03.0}  SPD: {d:>2.0} kts", .{ fd.wind_dir_deg, fd.wind_speed_kts }, .green, .black, false);

    // Wind arrow (simplified: just show direction relative to heading)
    const relative = fd.wind_dir_deg - fd.heading_mag_deg;
    const arrow: u21 = if (@abs(relative) < 45 or @abs(relative) > 315) 0x2191 // ↑ headwind
    else if (relative > 45 and relative < 135) 0x2192 // → from right
    else if (relative > 135 and relative < 225) 0x2193 // ↓ tailwind
    else 0x2190; // ← from left
    fb.setCell(16, 32, arrow, .cyan, .black, true);
}
