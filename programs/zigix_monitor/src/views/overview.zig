// Overview tab — CPU bars, memory, swap, disk, uptime, load averages.

const std = @import("std");
const tui = @import("zig_tui");
const theme = @import("../theme.zig");
const sysinfo = @import("../sysinfo.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Style = tui.Style;
const Color = tui.Color;

pub fn render(buf: *Buffer, area: Rect, snap: *const sysinfo.SystemSnapshot) void {
    if (area.height < 4) return;
    var y = area.y;

    // Section: System Identity
    _ = buf.writeStr(area.x, y, "SYSTEM", theme.title_style);
    y += 1;

    var line_buf: [128]u8 = undefined;
    const hn = snap.hostname[0..snap.hostname_len];
    const kv = snap.kernel_version[0..snap.kernel_version_len];
    const id_str = std.fmt.bufPrint(&line_buf, " {s}  |  {s}", .{ hn, kv }) catch " ?";
    _ = buf.writeStr(area.x, y, id_str, theme.text_style);
    y += 1;

    // Uptime
    var up_buf: [48]u8 = undefined;
    const up_str = sysinfo.formatUptime(snap.uptime_secs, &up_buf);
    var up_line: [64]u8 = undefined;
    const up_full = std.fmt.bufPrint(&up_line, " Uptime: {s}", .{up_str}) catch " Uptime: ?";
    _ = buf.writeStr(area.x, y, up_full, theme.dim_style);
    y += 1;

    // Load averages
    var load_buf: [64]u8 = undefined;
    const load_str = std.fmt.bufPrint(&load_buf, " Load: {d:.2}  {d:.2}  {d:.2}", .{ snap.load_1, snap.load_5, snap.load_15 }) catch " Load: ?";
    _ = buf.writeStr(area.x, y, load_str, theme.text_style);
    y += 2;

    if (y >= area.y + area.height) return;

    // Section: CPU
    _ = buf.writeStr(area.x, y, "CPU", theme.title_style);
    y += 1;

    const bar_x = area.x + 12; // Offset for labels
    const bar_width = if (area.width > 20) area.width - 20 else 10;

    // Total CPU bar
    if (y < area.y + area.height) {
        _ = buf.writeStr(area.x, y, " Total   ", theme.text_style);
        drawBar(buf, bar_x, y, bar_width, snap.cpu_total / 100.0);
        var pct_buf: [8]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, " {d:.0}%", .{snap.cpu_total}) catch "?";
        _ = buf.writeStr(bar_x + bar_width + 1, y, pct_str, theme.text_style);
        y += 1;
    }

    // Per-core bars (show if enough vertical space)
    if (area.width >= 60) {
        var core: u8 = 0;
        while (core < snap.cpu_count and y < area.y + area.height - 6) : (core += 1) {
            var core_label: [12]u8 = undefined;
            const cl = std.fmt.bufPrint(&core_label, " Core {d:<2}  ", .{core}) catch " ?";
            _ = buf.writeStr(area.x, y, cl, theme.dim_style);
            drawBar(buf, bar_x, y, bar_width, snap.cpu_usage[core] / 100.0);
            var cpct: [8]u8 = undefined;
            const cs = std.fmt.bufPrint(&cpct, " {d:.0}%", .{snap.cpu_usage[core]}) catch "?";
            _ = buf.writeStr(bar_x + bar_width + 1, y, cs, theme.dim_style);
            y += 1;
        }
    }

    y += 1;
    if (y >= area.y + area.height) return;

    // Section: Memory
    _ = buf.writeStr(area.x, y, "MEMORY", theme.title_style);
    y += 1;

    if (y < area.y + area.height and snap.mem_total_kb > 0) {
        var used_buf: [16]u8 = undefined;
        var total_buf: [16]u8 = undefined;
        const used_str = sysinfo.formatKb(snap.mem_used_kb, &used_buf);
        const total_str = sysinfo.formatKb(snap.mem_total_kb, &total_buf);
        const mem_pct = @as(f32, @floatFromInt(snap.mem_used_kb)) / @as(f32, @floatFromInt(snap.mem_total_kb));

        var mem_label: [48]u8 = undefined;
        const ml = std.fmt.bufPrint(&mem_label, " RAM      ", .{}) catch " RAM";
        _ = buf.writeStr(area.x, y, ml, theme.text_style);
        drawBar(buf, bar_x, y, bar_width, mem_pct);

        var mem_detail: [40]u8 = undefined;
        const md = std.fmt.bufPrint(&mem_detail, " {s} / {s}", .{ used_str, total_str }) catch "?";
        _ = buf.writeStr(bar_x + bar_width + 1, y, md, theme.text_style);
        y += 1;
    }

    // Swap
    if (y < area.y + area.height and snap.swap_total_kb > 0) {
        const swap_used = snap.swap_total_kb -| snap.swap_free_kb;
        var su_buf: [16]u8 = undefined;
        var st_buf: [16]u8 = undefined;
        const su_str = sysinfo.formatKb(swap_used, &su_buf);
        const st_str = sysinfo.formatKb(snap.swap_total_kb, &st_buf);
        const swap_pct = @as(f32, @floatFromInt(swap_used)) / @as(f32, @floatFromInt(snap.swap_total_kb));

        _ = buf.writeStr(area.x, y, " Swap     ", theme.text_style);
        drawBar(buf, bar_x, y, bar_width, swap_pct);

        var sd: [40]u8 = undefined;
        const swap_detail = std.fmt.bufPrint(&sd, " {s} / {s}", .{ su_str, st_str }) catch "?";
        _ = buf.writeStr(bar_x + bar_width + 1, y, swap_detail, theme.text_style);
        y += 1;
    }

    y += 1;
    if (y >= area.y + area.height) return;

    // Section: Disk
    _ = buf.writeStr(area.x, y, "DISK", theme.title_style);
    y += 1;

    if (y < area.y + area.height and snap.disk_total_kb > 0) {
        var du_buf: [16]u8 = undefined;
        var dt_buf: [16]u8 = undefined;
        const du_str = sysinfo.formatKb(snap.disk_used_kb, &du_buf);
        const dt_str = sysinfo.formatKb(snap.disk_total_kb, &dt_buf);
        const disk_pct = @as(f32, @floatFromInt(snap.disk_used_kb)) / @as(f32, @floatFromInt(snap.disk_total_kb));

        _ = buf.writeStr(area.x, y, " Root (/) ", theme.text_style);
        drawBar(buf, bar_x, y, bar_width, disk_pct);

        var dd: [40]u8 = undefined;
        const disk_detail = std.fmt.bufPrint(&dd, " {s} / {s}", .{ du_str, dt_str }) catch "?";
        _ = buf.writeStr(bar_x + bar_width + 1, y, disk_detail, theme.text_style);
    }
}

// Draw a horizontal bar using block characters
fn drawBar(buf: *Buffer, x: u16, y: u16, width: u16, ratio: f32) void {
    const clamped = std.math.clamp(ratio, 0.0, 1.0);
    const filled: u16 = @intFromFloat(clamped * @as(f32, @floatFromInt(width)));

    // Choose color based on usage level
    const fill_color = if (clamped > 0.9)
        theme.red_amber
    else if (clamped > 0.7)
        Color.fromRgb(255, 140, 0)
    else
        theme.amber;

    const filled_style = Style{ .fg = fill_color };
    const empty_style = Style{ .fg = theme.amber_dark };

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            buf.setChar(x + i, y, 0x2588, filled_style); // █
        } else {
            buf.setChar(x + i, y, 0x2591, empty_style); // ░
        }
    }
}
