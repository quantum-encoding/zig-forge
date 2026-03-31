//! EICAS — Engine Indicating and Crew Alerting System.
//! Two engine columns, fuel summary, and threshold-based alerts.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const tui = @import("tui_backend.zig");
const FlightData = @import("../flight_data.zig").FlightData;
const fuel_calc = @import("../calc/fuel.zig");
const AlertSystem = @import("../alerts.zig").AlertSystem;
const AlertPriority = @import("../alerts.zig").AlertPriority;

pub fn render(fb: *renderer_mod.FrameBuffer, fd: *const FlightData, alert_sys: *const AlertSystem) void {
    const w = fb.width;
    const h = fb.height -| 1;
    fb.drawBox(0, 0, w, h, .dim);
    fb.putStr(0, 3, " EICAS ", .bright_green, .black, true);

    // Engine headers
    fb.putStr(1, 3, "ENGINE 1", .bright_white, .black, true);
    fb.putStr(1, 38, "ENGINE 2", .bright_white, .black, true);

    renderEngine(fb, fd, 3);
    renderEngine2(fb, fd, 38);
    renderFuelSection(fb, fd);
    renderAlerts(fb, alert_sys);
}

fn renderEngine(fb: *renderer_mod.FrameBuffer, fd: *const FlightData, col: u16) void {
    const n1 = fd.n1_percent;
    const n1_color: tui.Color = if (n1 > 100) .bright_red else if (n1 > 95) .bright_yellow else .bright_green;
    fb.putFmt(2, col, "N1:  {d:>5.1}%", .{n1}, n1_color, .black, n1 > 95);
    fb.drawBarGauge(3, col, 25, n1, n1_color, .dim);

    fb.putFmt(4, col, "N2:  {d:>5.1}%", .{fd.n2_percent}, .green, .black, false);

    const itt_color: tui.Color = if (fd.itt_deg_c > 800) .bright_red else if (fd.itt_deg_c > 700) .bright_yellow else .green;
    fb.putFmt(5, col, "ITT: {d:>5.0} C", .{fd.itt_deg_c}, itt_color, .black, fd.itt_deg_c > 700);

    const oil_color: tui.Color = if (fd.oil_psi > 0 and fd.oil_psi < 25) .bright_yellow else .green;
    fb.putFmt(6, col, "OIL P: {d:>3.0} psi", .{fd.oil_psi}, oil_color, .black, false);
    fb.putFmt(7, col, "OIL T: {d:>3.0} C", .{fd.oil_temp_c}, .green, .black, false);

    const ff_kgh = fuel_calc.flowKgPerHour(fd.fuel_flow_kgs);
    fb.putFmt(8, col, "FF: {d:>6.0} kg/h", .{ff_kgh}, .green, .black, false);
}

fn renderEngine2(fb: *renderer_mod.FrameBuffer, fd: *const FlightData, col: u16) void {
    // Mirror of engine 1 data (single-engine struct for now)
    renderEngine(fb, fd, col);
}

fn renderFuelSection(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(10, 3, 50, .dim);
    fb.putStr(10, 3, " FUEL ", .dim, .black, false);

    const endur_color: tui.Color = if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs < 0.5)
        .bright_red
    else if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs < 1.0)
        .bright_yellow
    else
        .green;

    fb.putFmt(11, 3, "TOTAL: {d:>7.0} kg", .{fd.fuel_total_kg}, .green, .black, false);
    fb.putFmt(11, 25, "ENDUR: {d:>4.1} h", .{fd.fuel_endurance_hrs}, endur_color, .black, false);
    fb.putFmt(11, 42, "RANGE: {d:>5.0} NM", .{fd.fuel_range_nm}, .green, .black, false);

    const sr = fuel_calc.specificRange(fd.groundspeed_kts, fd.fuel_flow_kgs);
    const ff_total_kgh = fuel_calc.flowKgPerHour(fd.fuel_flow_kgs) * 2.0; // Two engines
    fb.putFmt(12, 3, "SR: {d:.3} NM/kg", .{sr}, .cyan, .black, false);
    fb.putFmt(12, 25, "FF TOT: {d:>5.0} kg/h", .{ff_total_kgh}, .green, .black, false);
}

fn renderAlerts(fb: *renderer_mod.FrameBuffer, alert_sys: *const AlertSystem) void {
    fb.drawHLine(14, 3, 50, .dim);
    fb.putStr(14, 3, " ALERTS ", .dim, .black, false);

    const alerts = alert_sys.activeAlerts();
    if (alerts.len == 0) {
        fb.putStr(15, 5, "(none)", .dim, .black, false);
        return;
    }

    var row: u16 = 15;
    for (alerts) |alert| {
        if (row >= fb.height -| 2) break;

        const color: tui.Color = switch (alert.priority) {
            .warning => .bright_red,
            .caution => .bright_yellow,
            .advisory => .bright_cyan,
        };
        const bold = alert.priority == .warning;
        const prefix: []const u8 = switch (alert.priority) {
            .warning => "!! ",
            .caution => "!  ",
            .advisory => "   ",
        };

        fb.putStr(row, 5, prefix, color, .black, bold);
        fb.putStr(row, 5 + @as(u16, @intCast(prefix.len)), alert.message, color, .black, bold);
        row += 1;
    }
}
