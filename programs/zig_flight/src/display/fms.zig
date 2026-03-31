//! FMS — Flight Management System calculator results page.
//! Shows all derived values from Phase 2 flight calculators.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const tui = @import("tui_backend.zig");
const FlightData = @import("../flight_data.zig").FlightData;
const density_calc = @import("../calc/density_alt.zig");
const fuel_calc = @import("../calc/fuel.zig");
const vnav_calc = @import("../calc/vnav.zig");
const turn_calc = @import("../calc/turn.zig");

pub fn render(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const w = fb.width;
    const h = fb.height -| 1;
    fb.drawBox(0, 0, w, h, .dim);
    fb.putStr(0, 3, " FMS ", .bright_green, .black, true);

    renderAtmosphere(fb, fd);
    renderWind(fb, fd);
    renderFuel(fb, fd);
    renderVnav(fb, fd);
    renderPerformance(fb, fd);
}

fn renderAtmosphere(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(1, 2, 30, .dim);
    fb.putStr(1, 2, " ATMOSPHERE ", .bright_cyan, .black, true);

    fb.putFmt(2, 3, "Density Alt: {d:>7.0} ft", .{fd.density_alt_ft}, .green, .black, false);

    const isa_dev = density_calc.isaDeviation(fd.altitude_ft, fd.oat_c);
    const isa_color: tui.Color = if (@abs(isa_dev) > 15) .bright_yellow else .green;
    fb.putFmt(3, 3, "ISA Dev:     {d:>6.1} C", .{isa_dev}, isa_color, .black, false);

    const pa = density_calc.pressureAltitude(fd.altitude_ft, fd.barometer_inhg);
    fb.putFmt(4, 3, "Press Alt:   {d:>7.0} ft", .{pa}, .green, .black, false);

    fb.putFmt(5, 3, "OAT:         {d:>6.1} C", .{fd.oat_c}, .green, .black, false);

    const tas = density_calc.trueAirspeed(fd.airspeed_kts, fd.density_alt_ft);
    fb.putFmt(6, 3, "TAS:         {d:>6.0} kts", .{tas}, .green, .black, false);

    const isa_temp = density_calc.isaTemperature(fd.altitude_ft);
    fb.putFmt(7, 3, "ISA Temp:    {d:>6.1} C", .{isa_temp}, .dim, .black, false);
}

fn renderWind(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const col: u16 = 38;
    fb.drawHLine(1, col, 30, .dim);
    fb.putStr(1, col, " WIND ", .bright_cyan, .black, true);

    fb.putFmt(2, col + 1, "Heading:    {d:>05.1} M", .{fd.heading_mag_deg}, .green, .black, false);
    fb.putFmt(3, col + 1, "Wind:       {d:>03.0}/{d:>02.0} kts", .{ fd.wind_dir_deg, fd.wind_speed_kts }, .green, .black, false);

    const hw_color: tui.Color = if (fd.headwind_kts < -10) .bright_yellow else .green;
    fb.putFmt(4, col + 1, "Headwind:   {d:>6.1} kts", .{fd.headwind_kts}, hw_color, .black, false);

    const xw_color: tui.Color = if (@abs(fd.crosswind_kts) > 15) .bright_yellow else .green;
    fb.putFmt(5, col + 1, "Crosswind:  {d:>6.1} kts", .{fd.crosswind_kts}, xw_color, .black, false);

    fb.putFmt(6, col + 1, "WCA:        {d:>6.1} deg", .{fd.wind_correction_deg}, .cyan, .black, false);
    fb.putFmt(7, col + 1, "GS:         {d:>6.0} kts", .{fd.groundspeed_kts}, .green, .black, false);
}

fn renderFuel(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(9, 2, 30, .dim);
    fb.putStr(9, 2, " FUEL ", .bright_cyan, .black, true);

    fb.putFmt(10, 3, "Remaining:   {d:>7.0} kg", .{fd.fuel_total_kg}, .green, .black, false);

    const ff_kgh = fuel_calc.flowKgPerHour(fd.fuel_flow_kgs);
    fb.putFmt(11, 3, "Flow Total:  {d:>7.0} kg/h", .{ff_kgh}, .green, .black, false);

    const endur_color: tui.Color = if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs < 0.5)
        .bright_red
    else if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs < 1.0)
        .bright_yellow
    else
        .green;
    fb.putFmt(12, 3, "Endurance:   {d:>6.1} hrs", .{fd.fuel_endurance_hrs}, endur_color, .black, false);
    fb.putFmt(13, 3, "Range:       {d:>6.0} NM", .{fd.fuel_range_nm}, .green, .black, false);

    const sr = fuel_calc.specificRange(fd.groundspeed_kts, fd.fuel_flow_kgs);
    fb.putFmt(14, 3, "Spec Range:  {d:.4} NM/kg", .{sr}, .cyan, .black, false);
}

fn renderVnav(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    const col: u16 = 38;
    fb.drawHLine(9, col, 30, .dim);
    fb.putStr(9, col, " VNAV ", .bright_cyan, .black, true);

    // TOD to sea level on 3-degree path
    const tod = vnav_calc.topOfDescent(fd.altitude_ft, 0, 3.0);
    fb.putFmt(10, col + 1, "TOD dist:    {d:>6.1} NM", .{tod}, .green, .black, false);

    const req_vs = vnav_calc.requiredDescentRate(fd.groundspeed_kts, 3.0);
    fb.putFmt(11, col + 1, "Req VS:     {d:>6.0} fpm", .{req_vs}, .green, .black, false);

    const rule_vs = vnav_calc.descentRateRule(fd.groundspeed_kts);
    fb.putFmt(12, col + 1, "Rule of 5:  {d:>6.0} fpm", .{rule_vs}, .dim, .black, false);

    fb.putFmt(13, col + 1, "Current VS: {d:>6.0} fpm", .{fd.vsi_fpm}, .cyan, .black, false);

    // Vertical deviation if descending
    if (fd.vsi_fpm < -100 and fd.nav1_dme_nm > 0) {
        const vdev = @import("../calc/vnav.zig").verticalDeviation(fd.altitude_ft, 0, fd.nav1_dme_nm, 3.0);
        fb.putFmt(14, col + 1, "V.Dev:      {d:>6.0} ft", .{vdev}, if (@abs(vdev) > 500) .bright_yellow else .green, .black, false);
    }
}

fn renderPerformance(fb: *renderer_mod.FrameBuffer, fd: *const FlightData) void {
    fb.drawHLine(16, 2, 64, .dim);
    fb.putStr(16, 2, " PERFORMANCE ", .bright_cyan, .black, true);

    // Standard rate turn info
    const tr = turn_calc.turnRate(fd.airspeed_kts, 0);
    fb.putFmt(17, 3, "Std Rate Bank: {d:>4.0} deg  at {d:>4.0} kts", .{ tr.bank_deg, fd.airspeed_kts }, .green, .black, false);
    fb.putFmt(18, 3, "Turn Radius:   {d:>4.1} NM   ({d:>5.0} ft)", .{ tr.radius_nm, tr.radius_ft }, .green, .black, false);
}
