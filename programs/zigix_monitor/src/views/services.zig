// Services tab — shows known services with port/status detection via /proc/net/tcp.

const std = @import("std");
const tui = @import("zig_tui");
const theme = @import("../theme.zig");
const sysinfo = @import("../sysinfo.zig");

const Buffer = tui.Buffer;
const Rect = tui.Rect;
const Style = tui.Style;

const ServiceDef = struct {
    name: []const u8,
    port: u16,
    proto: []const u8,
    description: []const u8,
};

const known_services = [_]ServiceDef{
    .{ .name = "zhttpd", .port = 80, .proto = "TCP", .description = "HTTP Server" },
    .{ .name = "dns-server", .port = 53, .proto = "UDP", .description = "DNS Resolver" },
    .{ .name = "kv-store", .port = 6379, .proto = "TCP", .description = "Distributed KV (Raft)" },
    .{ .name = "reverse-proxy", .port = 8080, .proto = "TCP", .description = "Reverse Proxy" },
    .{ .name = "ssh", .port = 22, .proto = "TCP", .description = "Secure Shell" },
};

// Cache for port listening state (refreshed externally)
var listening_ports: [65536]bool = [_]bool{false} ** 65536;
var ports_loaded: bool = false;

pub fn refresh() void {
    @memset(&listening_ports, false);
    ports_loaded = false;

    // /proc/net/tcp holds one line per socket; a few hundred sockets exceed 8 KB
    // and truncating past a watched LISTEN entry makes a running service report
    // STOPPED. Size generously and read the whole file (shared robust reader).
    var buf: [262144]u8 = undefined;

    // Parse /proc/net/tcp for TCP LISTEN ports
    if (sysinfo.readProcFile("/proc/net/tcp", &buf)) |data| {
        parseTcpPorts(data);
    }
    // Parse /proc/net/tcp6
    if (sysinfo.readProcFile("/proc/net/tcp6", &buf)) |data| {
        parseTcpPorts(data);
    }
    // Parse /proc/net/udp for UDP ports
    if (sysinfo.readProcFile("/proc/net/udp", &buf)) |data| {
        parseUdpPorts(data);
    }

    ports_loaded = true;
}

fn parseTcpPorts(data: []const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // Skip header

    while (lines.next()) |line| {
        if (line.len < 20) continue;
        // Fields: sl local_address rem_address st ...
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // sl
        const local = it.next() orelse continue; // local_address
        _ = it.next(); // rem_address
        const state = it.next() orelse continue; // st

        // State 0A = LISTEN
        if (!std.mem.eql(u8, state, "0A")) continue;

        // local_address format: "00000000:XXXX" or "0000...0000:XXXX"
        if (std.mem.lastIndexOfScalar(u8, local, ':')) |colon| {
            const port_hex = local[colon + 1 ..];
            const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;
            listening_ports[port] = true;
        }
    }
}

fn parseUdpPorts(data: []const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // Skip header

    while (lines.next()) |line| {
        if (line.len < 20) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // sl
        const local = it.next() orelse continue;
        // UDP: state 07 = CLOSE, but any bound port counts
        if (std.mem.lastIndexOfScalar(u8, local, ':')) |colon| {
            const port_hex = local[colon + 1 ..];
            const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;
            if (port > 0) listening_ports[port] = true;
        }
    }
}

pub fn render(buf: *Buffer, area: Rect, snap: *const sysinfo.SystemSnapshot) void {
    _ = snap;
    if (area.height < 4) return;

    var y = area.y;
    _ = buf.writeStr(area.x, y, "SERVICES", theme.title_style);
    y += 2;

    // Column headers
    const col_name = area.x + 1;
    const col_status = area.x + 20;
    const col_port = area.x + 32;
    const col_proto = area.x + 40;
    const col_desc = area.x + 48;

    const hdr_style = Style{ .fg = theme.amber_bright, .bg = theme.amber_dark, .attrs = .{ .bold = true } };

    // Header background
    buf.fill(Rect{ .x = area.x, .y = y, .width = area.width, .height = 1 }, tui.Cell.styled(' ', hdr_style));
    _ = buf.writeStr(col_name, y, "Service", hdr_style);
    _ = buf.writeStr(col_status, y, "Status", hdr_style);
    _ = buf.writeStr(col_port, y, "Port", hdr_style);
    _ = buf.writeStr(col_proto, y, "Proto", hdr_style);
    if (area.width > 50) _ = buf.writeStr(col_desc, y, "Description", hdr_style);
    y += 1;

    // Separator
    {
        var sx: u16 = area.x;
        while (sx < area.x + area.width) : (sx += 1) {
            buf.setChar(sx, y, 0x2500, Style{ .fg = theme.amber_dim }); // ─
        }
        y += 1;
    }

    // Service rows
    for (known_services) |svc| {
        if (y >= area.y + area.height) break;

        const is_running = ports_loaded and listening_ports[svc.port];
        const row_style = theme.text_style;

        _ = buf.writeStr(col_name, y, svc.name, row_style);

        if (is_running) {
            _ = buf.writeStr(col_status, y, "RUNNING", Style{ .fg = theme.amber_bright, .attrs = .{ .bold = true } });
        } else {
            _ = buf.writeStr(col_status, y, "STOPPED", Style{ .fg = theme.amber_dim });
        }

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{svc.port}) catch "?";
        _ = buf.writeStr(col_port, y, port_str, row_style);
        _ = buf.writeStr(col_proto, y, svc.proto, theme.dim_style);
        if (area.width > 50) _ = buf.writeStr(col_desc, y, svc.description, theme.dim_style);

        y += 1;
    }

    // Footer hint
    y += 1;
    if (y < area.y + area.height) {
        var summary_buf: [64]u8 = undefined;
        var running_count: u16 = 0;
        for (known_services) |svc| {
            if (ports_loaded and listening_ports[svc.port]) running_count += 1;
        }
        const summary = std.fmt.bufPrint(&summary_buf, " {d}/{d} services active", .{ running_count, known_services.len }) catch "?";
        _ = buf.writeStr(area.x, y, summary, theme.dim_style);
    }
}

// ---------------------------------------------------------------------------
// Tests. Fixture is real /proc/net/tcp text (kernel format): state 0A = LISTEN,
// state 01 = ESTABLISHED; local_address is "HEXADDR:HEXPORT".
// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseTcpPorts marks only LISTEN ports" {
    @memset(&listening_ports, false);

    // Header + a LISTEN on :22 (0016) and :80 (0050), and an ESTABLISHED on
    // :8080 (1F90) which must NOT be reported as listening.
    const fixture =
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" ++
        "   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 100 1 0000 100\n" ++
        "   1: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 101 1 0000 100\n" ++
        "   2: 0100007F:1F90 0100007F:C000 01 00000000:00000000 00:00000000 00000000  1000        0 102 1 0000 100\n";

    parseTcpPorts(fixture);

    try testing.expect(listening_ports[22]); // 0x0016 LISTEN
    try testing.expect(listening_ports[80]); // 0x0050 LISTEN
    try testing.expect(!listening_ports[8080]); // 0x1F90 ESTABLISHED, not LISTEN
    try testing.expect(!listening_ports[443]); // never present

    @memset(&listening_ports, false);
}
