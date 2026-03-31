// Logs tab — scrollable event feed generated from system state changes.

const std = @import("std");
const tui = @import("zig_tui");
const theme = @import("../theme.zig");
const sysinfo = @import("../sysinfo.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Style = tui.Style;

const MAX_ENTRIES = 200;

pub const Severity = enum {
    info,
    warn,
    alert,
};

const LogEntry = struct {
    timestamp: [19]u8 = [_]u8{' '} ** 19, // "YYYY-MM-DD HH:MM:SS"
    severity: Severity = .info,
    message: [96]u8 = [_]u8{0} ** 96,
    message_len: usize = 0,
};

var entries: [MAX_ENTRIES]LogEntry = [_]LogEntry{.{}} ** MAX_ENTRIES;
var count: usize = 0;
var head: usize = 0; // Next write position in ring buffer
var scroll_offset: usize = 0;

// Previous snapshot for delta detection
var prev_cpu_total: f32 = 0;
var prev_mem_pct: f32 = 0;
var initialized: bool = false;

pub fn addEntry(sev: Severity, msg: []const u8) void {
    var entry = &entries[head];
    entry.severity = sev;

    // Format timestamp from current time via clock_gettime
    var clock_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &clock_ts);
    const epoch_secs: u64 = @intCast(clock_ts.sec);
    // Simple epoch to date/time (good enough for display)
    formatEpoch(epoch_secs, &entry.timestamp);

    const len = @min(msg.len, entry.message.len);
    @memcpy(entry.message[0..len], msg[0..len]);
    entry.message_len = len;

    head = (head + 1) % MAX_ENTRIES;
    if (count < MAX_ENTRIES) count += 1;
}

pub fn checkForEvents(snap: *const sysinfo.SystemSnapshot) void {
    if (!initialized) {
        addEntry(.info, "System monitor started");
        addEntry(.info, "Collecting initial system data...");
        initialized = true;
        prev_cpu_total = snap.cpu_total;
        if (snap.mem_total_kb > 0) {
            prev_mem_pct = @as(f32, @floatFromInt(snap.mem_used_kb)) / @as(f32, @floatFromInt(snap.mem_total_kb)) * 100.0;
        }
        return;
    }

    // CPU spike detection
    if (snap.cpu_total > 80.0 and prev_cpu_total <= 80.0) {
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "CPU usage spike: {d:.0}%", .{snap.cpu_total}) catch "CPU spike detected";
        addEntry(.warn, msg);
    } else if (snap.cpu_total > 95.0) {
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "CPU critical: {d:.0}%", .{snap.cpu_total}) catch "CPU critical";
        addEntry(.alert, msg);
    }

    // Memory usage change detection
    if (snap.mem_total_kb > 0) {
        const mem_pct = @as(f32, @floatFromInt(snap.mem_used_kb)) / @as(f32, @floatFromInt(snap.mem_total_kb)) * 100.0;
        const delta = if (mem_pct > prev_mem_pct) mem_pct - prev_mem_pct else prev_mem_pct - mem_pct;
        if (delta > 5.0) {
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Memory usage: {d:.0}% (was {d:.0}%)", .{ mem_pct, prev_mem_pct }) catch "Memory change";
            addEntry(.info, msg);
        }
        if (mem_pct > 90.0 and prev_mem_pct <= 90.0) {
            addEntry(.warn, "Memory usage above 90%");
        }
        prev_mem_pct = mem_pct;
    }

    // Network error detection
    var i: u8 = 0;
    while (i < snap.net_iface_count) : (i += 1) {
        const iface = &snap.net_ifaces[i];
        const total_err = iface.rx_errors + iface.tx_errors;
        if (total_err > 0) {
            const name = iface.name[0..iface.name_len];
            // Only log if this is a non-lo interface with meaningful errors
            if (!std.mem.eql(u8, name, "lo")) {
                var msg_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Network errors on {s}: {d}", .{ name, total_err }) catch "Network errors";
                addEntry(.warn, msg);
                break; // One per refresh cycle
            }
        }
    }

    // Periodic heartbeat every ~30 refreshes (~60 seconds)
    const refresh_count = struct {
        var val: u32 = 0;
    };
    refresh_count.val += 1;
    if (refresh_count.val % 30 == 0) {
        var msg_buf: [96]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        const up = sysinfo.formatUptime(snap.uptime_secs, &up_buf);
        const msg = std.fmt.bufPrint(&msg_buf, "Heartbeat - uptime {s}, CPU {d:.0}%", .{ up, snap.cpu_total }) catch "Heartbeat";
        addEntry(.info, msg);
    }

    prev_cpu_total = snap.cpu_total;
}

pub fn render(buf: *Buffer, area: Rect, snap: *const sysinfo.SystemSnapshot) void {
    _ = snap;
    if (area.height < 4) return;
    var y = area.y;

    _ = buf.writeStr(area.x, y, "SYSTEM LOG", theme.title_style);

    // Entry count
    var cnt_buf: [24]u8 = undefined;
    const cnt_str = std.fmt.bufPrint(&cnt_buf, "[{d} entries]", .{count}) catch "?";
    _ = buf.writeStr(area.x + 14, y, cnt_str, theme.dim_style);
    y += 2;

    if (count == 0) {
        _ = buf.writeStr(area.x + 1, y, "No events recorded yet.", theme.dim_style);
        return;
    }

    // Calculate visible range (show newest at bottom)
    const visible_rows = if (area.height > 3) area.height - 3 else 1;
    const display_count = @min(count, visible_rows);

    // Start index: ring buffer math
    // The newest entry is at (head - 1 + MAX) % MAX
    // We want to display `display_count` entries ending at the newest
    const start_logical = count -| display_count -| scroll_offset;

    var row: usize = 0;
    while (row < display_count) : (row += 1) {
        if (y >= area.y + area.height) break;

        const logical_idx = start_logical + row;
        if (logical_idx >= count) break;

        // Convert logical index to ring buffer index
        // Oldest entry is at (head - count + MAX) % MAX
        const oldest_ring = (head + MAX_ENTRIES - count) % MAX_ENTRIES;
        const ring_idx = (oldest_ring + logical_idx) % MAX_ENTRIES;

        const entry = &entries[ring_idx];
        const msg = entry.message[0..entry.message_len];

        // Severity indicator and color
        const sev_str = switch (entry.severity) {
            .info => "INFO ",
            .warn => "WARN ",
            .alert => "ALERT",
        };
        const sev_style = switch (entry.severity) {
            .info => theme.dim_style,
            .warn => Style{ .fg = theme.amber_bright, .attrs = .{ .bold = true } },
            .alert => Style{ .fg = theme.red_amber, .attrs = .{ .bold = true } },
        };
        const msg_style = switch (entry.severity) {
            .info => theme.text_style,
            .warn => Style{ .fg = theme.amber_bright },
            .alert => Style{ .fg = theme.red_amber },
        };

        var x = area.x + 1;
        // Timestamp
        x += buf.writeStr(x, y, &entry.timestamp, theme.dim_style);
        x += buf.writeStr(x, y, " ", theme.dim_style);
        // Severity
        x += buf.writeStr(x, y, sev_str, sev_style);
        x += buf.writeStr(x, y, " ", theme.dim_style);
        // Message
        _ = buf.writeStr(x, y, msg, msg_style);

        y += 1;
    }
}

pub fn scrollUp() void {
    if (scroll_offset < count -| 1) scroll_offset += 1;
}

pub fn scrollDown() void {
    if (scroll_offset > 0) scroll_offset -= 1;
}

// Simple epoch-to-date formatter (UTC)
fn formatEpoch(epoch: u64, buf: *[19]u8) void {
    // Days since epoch
    var days = epoch / 86400;
    const day_secs = epoch % 86400;
    const hour = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const second = day_secs % 60;

    // Year calculation (simplified Gregorian)
    var year: u32 = 1970;
    while (true) {
        const days_in_year: u64 = if (isLeap(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    // Month calculation
    const leap = isLeap(year);
    const month_days = if (leap)
        [_]u16{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        month += 1;
    }
    const day: u32 = @intCast(days + 1);

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    }) catch {};
}

fn isLeap(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}
