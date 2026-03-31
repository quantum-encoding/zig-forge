// Zigix System Monitor — real-time system dashboard with PC-98 amber aesthetic.
// Imports zig_tui as the TUI framework, reads system state from /proc.

const std = @import("std");
const tui = @import("zig_tui");
const theme = @import("theme.zig");
const sysinfo = @import("sysinfo.zig");
const overview = @import("views/overview.zig");
const services = @import("views/services.zig");
const network = @import("views/network.zig");
const logs = @import("views/logs.zig");

const Buffer = tui.Buffer;
const Size = tui.Size;
const Rect = tui.Rect;
const Event = tui.Event;
const Style = tui.Style;
const Color = tui.Color;
const Cell = tui.Cell;

// Application state
var current_tab: usize = 0;
var collector: sysinfo.SysInfoCollector = .{};
var snapshot: sysinfo.SystemSnapshot = .{};
var tick_counter: u32 = 0;
const tab_names = [_][]const u8{ "Overview", "Services", "Network", "Logs" };

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Initial data collection (two samples for CPU delta)
    snapshot = collector.collect();
    // Brief pause for CPU delta measurement
    {
        const c = @cImport({
            @cInclude("time.h");
        });
        var req = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
        _ = c.nanosleep(&req, null);
    }
    snapshot = collector.collect();
    services.refresh();
    network.updateRates(&snapshot);
    logs.checkForEvents(&snapshot);

    var app = try tui.Application.init(allocator, .{
        .mouse_enabled = true,
        .tick_rate_ms = 16,
    });
    defer app.deinit();

    app.setRenderCallback(render);
    app.setEventCallback(handleEvent);

    try app.run();
}

fn render(buf: *Buffer, size: Size) void {
    // Clear with black background
    buf.clearStyle(Style{ .bg = Color.black });

    if (size.height < 6 or size.width < 40) {
        _ = buf.writeStr(0, 0, "Terminal too small (min 40x6)", theme.text_style);
        return;
    }

    // Header bar (row 0)
    renderHeader(buf, size);

    // Tab bar (row 1)
    renderTabs(buf, size);

    // Content area (row 3 to height-2)
    const content = Rect{
        .x = 1,
        .y = 3,
        .width = if (size.width > 2) size.width - 2 else 1,
        .height = if (size.height > 5) size.height - 5 else 1,
    };

    switch (current_tab) {
        0 => overview.render(buf, content, &snapshot),
        1 => services.render(buf, content, &snapshot),
        2 => network.render(buf, content, &snapshot),
        3 => logs.render(buf, content, &snapshot),
        else => {},
    }

    // Status bar (last row)
    renderStatusBar(buf, size);
}

fn handleEvent(event: Event) bool {
    // Quit on q, Q, or Escape
    if (event.isChar('q') or event.isChar('Q') or event.isEscape()) return false;

    switch (event) {
        .key => |k| {
            switch (k.key) {
                .char => |c| {
                    // Tab switching via number keys
                    if (c >= '1' and c <= '4') {
                        current_tab = c - '1';
                        return true;
                    }
                },
                .special => |s| {
                    switch (s) {
                        .left => {
                            if (current_tab > 0) current_tab -= 1;
                            return true;
                        },
                        .right => {
                            if (current_tab < tab_names.len - 1) current_tab += 1;
                            return true;
                        },
                        .up => {
                            if (current_tab == 3) logs.scrollUp();
                            return true;
                        },
                        .down => {
                            if (current_tab == 3) logs.scrollDown();
                            return true;
                        },
                        else => {},
                    }
                },
            }
        },
        .tick => {
            tick_counter += 1;
            // Refresh data every ~2 seconds (120 ticks at 16ms)
            if (tick_counter % 120 == 0) {
                snapshot = collector.collect();
                network.updateRates(&snapshot);
                logs.checkForEvents(&snapshot);
            }
            // Refresh services less frequently (~5 seconds)
            if (tick_counter % 300 == 0) {
                services.refresh();
            }
            return true;
        },
        else => {},
    }
    return true;
}

fn renderHeader(buf: *Buffer, size: Size) void {
    // Fill header line
    buf.fill(
        Rect{ .x = 0, .y = 0, .width = size.width, .height = 1 },
        Cell.styled(' ', Style{ .bg = theme.amber_dark }),
    );

    const title = " ZIGIX SYSTEM MONITOR v1.0 ";
    const title_x = if (size.width > title.len) (size.width - @as(u16, @intCast(title.len))) / 2 else 0;
    _ = buf.writeStr(title_x, 0, title, theme.header_bg_style);
}

fn renderTabs(buf: *Buffer, size: Size) void {
    const y: u16 = 1;
    var x: u16 = 1;

    for (tab_names, 0..) |name, i| {
        const is_active = (i == current_tab);

        // Tab number
        var num_buf: [4]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, " {d}:", .{i + 1}) catch "?";

        if (is_active) {
            _ = buf.writeStr(x, y, num_str, Style{ .fg = Color.black, .bg = theme.amber, .attrs = .{ .bold = true } });
            x += @intCast(num_str.len);
            _ = buf.writeStr(x, y, name, Style{ .fg = Color.black, .bg = theme.amber, .attrs = .{ .bold = true } });
            x += @intCast(name.len);
            _ = buf.writeStr(x, y, " ", Style{ .fg = Color.black, .bg = theme.amber });
            x += 1;
        } else {
            _ = buf.writeStr(x, y, num_str, Style{ .fg = theme.amber_dim });
            x += @intCast(num_str.len);
            _ = buf.writeStr(x, y, name, Style{ .fg = theme.amber_medium });
            x += @intCast(name.len);
            _ = buf.writeStr(x, y, " ", Style{});
            x += 1;
        }
        x += 1; // Gap between tabs
    }

    // Separator line below tabs
    {
        var sx: u16 = 0;
        while (sx < size.width) : (sx += 1) {
            buf.setChar(sx, 2, 0x2500, Style{ .fg = theme.amber_dim }); // ─
        }
    }
}

fn renderStatusBar(buf: *Buffer, size: Size) void {
    const y = size.height - 1;

    // Fill background
    buf.fill(
        Rect{ .x = 0, .y = y, .width = size.width, .height = 1 },
        Cell.styled(' ', theme.statusbar_style),
    );

    var x: u16 = 1;

    // Hostname
    const hn = snapshot.hostname[0..snapshot.hostname_len];
    x += buf.writeStr(x, y, hn, theme.statusbar_style);
    x += buf.writeStr(x, y, " | ", theme.statusbar_sep_style);

    // Kernel version
    const kv = snapshot.kernel_version[0..snapshot.kernel_version_len];
    _ = buf.writeStr(x, y, kv, theme.statusbar_style);

    // Center: key hints
    const hints = "1-4:Tab  \xE2\x86\x90\xE2\x86\x91\xE2\x86\x93\xE2\x86\x92:Nav  Q:Quit";
    const hints_len: u16 = 28; // approximate display width
    const hints_x = if (size.width > hints_len) (size.width - hints_len) / 2 else 0;
    _ = buf.writeStr(hints_x, y, hints, theme.statusbar_style);

    // Right: current time
    var time_buf: [8]u8 = undefined;
    const time_str = getCurrentTime(&time_buf);
    const time_x = if (size.width > time_str.len + 1) size.width - @as(u16, @intCast(time_str.len)) - 1 else 0;
    _ = buf.writeStr(time_x, y, time_str, theme.statusbar_style);
}

fn getCurrentTime(buf: *[8]u8) []const u8 {
    var clock_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &clock_ts);
    const epoch: u64 = @intCast(clock_ts.sec);
    const day_secs = epoch % 86400;
    const hour: u32 = @intCast(day_secs / 3600);
    const minute: u32 = @intCast((day_secs % 3600) / 60);
    const second: u32 = @intCast(day_secs % 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch "??:??:??";
}
