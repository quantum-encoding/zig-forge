//! Primary Flight Display — airspeed tape, attitude indicator, altitude tape,
//! heading strip, and data readout.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const tui = @import("tui_backend.zig");
const FlightData = @import("../flight_data.zig").FlightData;

pub fn render(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const w = fb.width;
    const h = fb.height -| 1; // Reserve bottom row for page bar
    fb.drawBox(0, 0, w, h, .dim);
    fb.putStr(0, 3, " PFD ", .bright_green, .black, true);

    renderAirspeedTape(fb, fd);
    renderAttitudeIndicator(fb, fd);
    renderAltitudeTape(fb, fd);
    renderVSI(fb, fd);
    renderHeadingStrip(fb, fd);
    renderDataReadout(fb, fd);
}

fn renderAirspeedTape(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const base_row: u16 = 2;
    const base_col: u16 = 2;
    const tape_h: u16 = 7;

    fb.drawBox(base_row, base_col, 7, tape_h, .white);
    fb.putStr(base_row, base_col + 1, " IAS ", .dim, .black, false);

    const ias: i32 = @intFromFloat(fd.airspeed_kts);
    const rounded = @divFloor(ias, 10) * 10;
    const center = base_row + tape_h / 2;

    var offset: i32 = -3;
    while (offset <= 3) : (offset += 1) {
        const speed = rounded - (offset * 10);
        const row: u16 = @intCast(@as(i32, @intCast(center)) + offset);
        if (row > base_row and row < base_row + tape_h - 1 and speed >= 0) {
            const color: tui.Color = if (offset == 0) .bright_green else .green;
            const bold = offset == 0;
            fb.putFmt(row, base_col + 1, "{d:>5}", .{speed}, color, .black, bold);
        }
    }

    // Pointer
    fb.setCell(center, base_col + 7, 0x25C4, .white, .black, true); // ◄
}

fn renderAttitudeIndicator(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const base_row: u16 = 2;
    const base_col: u16 = 11;
    const att_w: u16 = 34;
    const att_h: u16 = 9;

    fb.drawBox(base_row, base_col, att_w, att_h, .white);
    fb.putStr(base_row, base_col + 1, " ATT ", .dim, .black, false);

    const center_row = base_row + att_h / 2;
    const center_col = base_col + att_w / 2;

    // Pitch offset: each row ~2.5 degrees
    const pitch_offset: i16 = @intFromFloat(fd.pitch_deg / 2.5);

    // Draw sky (above horizon) and ground (below)
    const horizon_row: i16 = @as(i16, @intCast(center_row)) + pitch_offset;

    var r: u16 = base_row + 1;
    while (r < base_row + att_h - 1) : (r += 1) {
        const ri: i16 = @intCast(r);
        // Fill background to suggest sky/ground
        var c: u16 = base_col + 1;
        while (c < base_col + att_w - 1) : (c += 1) {
            if (ri < horizon_row) {
                fb.setCell(r, c, ' ', .cyan, .blue, false);
            } else if (ri > horizon_row) {
                fb.setCell(r, c, ' ', .yellow, .black, false);
            }
        }
    }

    // Horizon line
    if (horizon_row > base_row and horizon_row < base_row + att_h - 1) {
        const hr: u16 = @intCast(horizon_row);
        var c: u16 = base_col + 2;
        while (c < base_col + att_w - 2) : (c += 1) {
            fb.setCell(hr, c, 0x2500, .bright_green, .black, false); // ─
        }
    }

    // Pitch ladder marks at ±5 and ±10 degrees
    var deg: i16 = -10;
    while (deg <= 10) : (deg += 5) {
        if (deg == 0) {
            deg += 1;
            continue;
        }
        const mark_row: i16 = @as(i16, @intCast(center_row)) + pitch_offset - @divFloor(deg, 3);
        if (mark_row > base_row + 1 and mark_row < base_row + att_h - 2) {
            const mr: u16 = @intCast(mark_row);
            fb.putStr(mr, center_col - 4, "----", .dim, .black, false);
            fb.putStr(mr, center_col + 1, "----", .dim, .black, false);
            fb.putFmt(mr, center_col + 6, "{d}", .{@abs(deg)}, .dim, .black, false);
        }
    }

    // Aircraft wings symbol at center
    fb.putStr(center_row, center_col - 3, "--W--", .bright_white, .black, true);

    // Bank angle display
    fb.putFmt(base_row + att_h, base_col + 2, "BANK: {d:>6.1}", .{fd.roll_deg}, .cyan, .black, false);
    fb.putFmt(base_row + att_h, base_col + 20, "PITCH: {d:>5.1}", .{fd.pitch_deg}, .cyan, .black, false);
}

fn renderAltitudeTape(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const base_row: u16 = 2;
    const base_col: u16 = 47;
    const tape_h: u16 = 7;

    fb.drawBox(base_row, base_col, 9, tape_h, .white);
    fb.putStr(base_row, base_col + 1, "  ALT  ", .dim, .black, false);

    const alt: i32 = @intFromFloat(fd.altitude_ft);
    const rounded = @divFloor(alt, 100) * 100;
    const center = base_row + tape_h / 2;

    var offset: i32 = -3;
    while (offset <= 3) : (offset += 1) {
        const altitude = rounded - (offset * 100);
        const row: u16 = @intCast(@as(i32, @intCast(center)) + offset);
        if (row > base_row and row < base_row + tape_h - 1) {
            const color: tui.Color = if (offset == 0) .bright_green else .green;
            const bold = offset == 0;
            fb.putFmt(row, base_col + 1, "{d:>7}", .{altitude}, color, .black, bold);
        }
    }

    // Pointer
    fb.setCell(center, base_col -| 1, 0x25BA, .white, .black, true); // ►
}

fn renderVSI(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const col: u16 = 58;
    fb.putStr(2, col, "VS", .dim, .black, false);

    const vsi = fd.vsi_fpm;
    const color: tui.Color = if (@abs(vsi) < 100) .green else if (vsi > 0) .cyan else .yellow;
    fb.putFmt(3, col, "{d:>6.0}", .{vsi}, color, .black, false);
    fb.putStr(4, col, "fpm", .dim, .black, false);

    // Bar indicator
    const bar_h: u16 = 5;
    const center_row: u16 = 5 + bar_h / 2;
    // Scale: ±2000 fpm fills the bar
    const clamped = @max(-2000.0, @min(2000.0, vsi));
    const bar_offset: i16 = -@as(i16, @intFromFloat(clamped / 2000.0 * @as(f32, @floatFromInt(bar_h / 2))));

    var r: u16 = 5;
    while (r < 5 + bar_h) : (r += 1) {
        const ri: i16 = @intCast(r);
        const ci: i16 = @intCast(center_row);
        if ((bar_offset < 0 and ri >= ci + bar_offset and ri <= ci) or
            (bar_offset > 0 and ri >= ci and ri <= ci + bar_offset) or
            (bar_offset == 0 and ri == ci))
        {
            fb.setCell(r, col + 1, 0x2588, color, .black, false); // █
        } else {
            fb.setCell(r, col + 1, 0x2502, .dim, .black, false); // │
        }
    }
}

fn renderHeadingStrip(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const row: u16 = 13;
    const base_col: u16 = 11;
    const strip_w: u16 = 40;

    fb.drawBox(row, base_col, strip_w, 3, .white);
    fb.putStr(row, base_col + 1, " HDG ", .dim, .black, false);

    const center_col = base_col + strip_w / 2;
    const hdg: i32 = @intFromFloat(fd.heading_mag_deg);

    // Pointer at top
    fb.setCell(row, center_col, 0x25BC, .bright_white, .black, true); // ▼

    // Show heading values across the strip
    var offset: i32 = -4;
    while (offset <= 4) : (offset += 1) {
        var h = @mod(hdg + offset * 10, 360);
        if (h < 0) h += 360;
        const col_pos: u16 = @intCast(@as(i32, @intCast(center_col)) + offset * 4);
        if (col_pos <= base_col or col_pos >= base_col + strip_w - 3) continue;

        // Cardinal directions
        if (h == 0 or h == 360) {
            fb.putStr(row + 1, col_pos, "N", .bright_green, .black, true);
        } else if (h == 90) {
            fb.putStr(row + 1, col_pos, "E", .bright_green, .black, true);
        } else if (h == 180) {
            fb.putStr(row + 1, col_pos, "S", .bright_green, .black, true);
        } else if (h == 270) {
            fb.putStr(row + 1, col_pos, "W", .bright_green, .black, true);
        } else {
            fb.putFmt(row + 1, col_pos -| 1, "{d:>03}", .{h}, .green, .black, offset == 0);
        }
    }
}

fn renderDataReadout(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const row1: u16 = 16;
    const row2: u16 = 17;

    fb.drawHLine(row1 - 1, 2, 64, .dim);

    fb.putFmt(row1, 2, "GS: {d:>4.0} kts", .{fd.groundspeed_kts}, .green, .black, false);
    fb.putFmt(row1, 18, "WIND: {d:>03.0}/{d:>02.0}", .{ fd.wind_dir_deg, fd.wind_speed_kts }, .green, .black, false);
    fb.putFmt(row1, 34, "RA: {d:>6.0} ft", .{fd.radio_alt_ft}, .green, .black, false);
    fb.putFmt(row1, 50, "BARO: {d:.2}", .{fd.barometer_inhg}, .green, .black, false);

    fb.putFmt(row2, 2, "HW: {d:>5.1} kts", .{fd.headwind_kts}, .cyan, .black, false);
    fb.putFmt(row2, 18, "XW: {d:>5.1} kts", .{fd.crosswind_kts}, .cyan, .black, false);
    fb.putFmt(row2, 34, "WCA: {d:>5.1}", .{fd.wind_correction_deg}, .cyan, .black, false);
    fb.putFmt(row2, 50, "DA: {d:>6.0} ft", .{fd.density_alt_ft}, .cyan, .black, false);
}
