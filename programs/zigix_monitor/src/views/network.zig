// Network tab — per-interface traffic stats with rate calculation.

const std = @import("std");
const tui = @import("zig_tui");
const theme = @import("../theme.zig");
const sysinfo = @import("../sysinfo.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Style = tui.Style;

// Previous byte counters for rate calculation
var prev_rx: [sysinfo.MAX_NET_IFACES]u64 = [_]u64{0} ** sysinfo.MAX_NET_IFACES;
var prev_tx: [sysinfo.MAX_NET_IFACES]u64 = [_]u64{0} ** sysinfo.MAX_NET_IFACES;
var prev_timestamp: i64 = 0;
var rx_rate: [sysinfo.MAX_NET_IFACES]u64 = [_]u64{0} ** sysinfo.MAX_NET_IFACES;
var tx_rate: [sysinfo.MAX_NET_IFACES]u64 = [_]u64{0} ** sysinfo.MAX_NET_IFACES;
var has_prev: bool = false;

pub fn updateRates(snap: *const sysinfo.SystemSnapshot) void {
    if (has_prev and snap.timestamp_secs > prev_timestamp) {
        const dt: u64 = @intCast(snap.timestamp_secs - prev_timestamp);
        if (dt > 0) {
            var i: u8 = 0;
            while (i < snap.net_iface_count) : (i += 1) {
                const iface = &snap.net_ifaces[i];
                rx_rate[i] = (iface.rx_bytes -| prev_rx[i]) / dt;
                tx_rate[i] = (iface.tx_bytes -| prev_tx[i]) / dt;
            }
        }
    }

    // Store current as previous
    var i: u8 = 0;
    while (i < snap.net_iface_count) : (i += 1) {
        prev_rx[i] = snap.net_ifaces[i].rx_bytes;
        prev_tx[i] = snap.net_ifaces[i].tx_bytes;
    }
    prev_timestamp = snap.timestamp_secs;
    has_prev = true;
}

pub fn render(buf: *Buffer, area: Rect, snap: *const sysinfo.SystemSnapshot) void {
    if (area.height < 4) return;
    var y = area.y;

    _ = buf.writeStr(area.x, y, "NETWORK INTERFACES", theme.title_style);
    y += 2;

    // Column positions
    const col_name = area.x + 1;
    const col_rx_rate = area.x + 12;
    const col_tx_rate = area.x + 24;
    const col_rx_total = area.x + 36;
    const col_tx_total = area.x + 50;
    const col_errors = area.x + 64;

    // Header
    const hdr_style = Style{ .fg = theme.amber_bright, .bg = theme.amber_dark, .attrs = .{ .bold = true } };
    buf.fill(tui.Rect{ .x = area.x, .y = y, .width = area.width, .height = 1 }, tui.Cell.styled(' ', hdr_style));
    _ = buf.writeStr(col_name, y, "Interface", hdr_style);
    _ = buf.writeStr(col_rx_rate, y, "RX Rate", hdr_style);
    _ = buf.writeStr(col_tx_rate, y, "TX Rate", hdr_style);
    _ = buf.writeStr(col_rx_total, y, "RX Total", hdr_style);
    _ = buf.writeStr(col_tx_total, y, "TX Total", hdr_style);
    if (area.width > 70) _ = buf.writeStr(col_errors, y, "Errors", hdr_style);
    y += 1;

    // Separator
    {
        var sx: u16 = area.x;
        while (sx < area.x + area.width) : (sx += 1) {
            buf.setChar(sx, y, 0x2500, Style{ .fg = theme.amber_dim }); // ─
        }
        y += 1;
    }

    // Interface rows
    var i: u8 = 0;
    while (i < snap.net_iface_count) : (i += 1) {
        if (y >= area.y + area.height) break;
        const iface = &snap.net_ifaces[i];
        const name = iface.name[0..iface.name_len];

        // Dim loopback
        const is_lo = std.mem.eql(u8, name, "lo");
        const row_style = if (is_lo) theme.dim_style else theme.text_style;

        _ = buf.writeStr(col_name, y, name, row_style);

        // RX rate
        var rxr_buf: [16]u8 = undefined;
        const rxr = sysinfo.formatRate(rx_rate[i], &rxr_buf);
        _ = buf.writeStr(col_rx_rate, y, rxr, if (rx_rate[i] > 0 and !is_lo) theme.text_style else theme.dim_style);

        // TX rate
        var txr_buf: [16]u8 = undefined;
        const txr = sysinfo.formatRate(tx_rate[i], &txr_buf);
        _ = buf.writeStr(col_tx_rate, y, txr, if (tx_rate[i] > 0 and !is_lo) theme.text_style else theme.dim_style);

        // RX total
        var rxt_buf: [16]u8 = undefined;
        const rxt = formatBytes(iface.rx_bytes, &rxt_buf);
        _ = buf.writeStr(col_rx_total, y, rxt, row_style);

        // TX total
        var txt_buf: [16]u8 = undefined;
        const txt = formatBytes(iface.tx_bytes, &txt_buf);
        _ = buf.writeStr(col_tx_total, y, txt, row_style);

        // Errors
        if (area.width > 70) {
            const total_err = iface.rx_errors + iface.tx_errors + iface.rx_dropped + iface.tx_dropped;
            var err_buf: [12]u8 = undefined;
            const err_str = std.fmt.bufPrint(&err_buf, "{d}", .{total_err}) catch "?";
            const err_style = if (total_err > 0) Style{ .fg = theme.red_amber } else theme.dim_style;
            _ = buf.writeStr(col_errors, y, err_str, err_style);
        }

        y += 1;
    }

    if (snap.net_iface_count == 0) {
        _ = buf.writeStr(area.x + 1, y, "No network interfaces detected", theme.dim_style);
    }
}

fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    if (bytes >= 1073741824) {
        const v = bytes * 10 / 1073741824;
        return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ v / 10, v % 10 }) catch "?";
    } else if (bytes >= 1048576) {
        const v = bytes * 10 / 1048576;
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ v / 10, v % 10 }) catch "?";
    } else if (bytes >= 1024) {
        const v = bytes * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d} KB", .{ v / 10, v % 10 }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    }
}
