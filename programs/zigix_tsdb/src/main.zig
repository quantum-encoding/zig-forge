/// Zigix TSDB — Time-series metrics store for bare-metal Zigix OS.
///
/// Receives chat metrics from zigix-chat over TCP (port 9090) and stores them
/// in an in-memory time-series database. Serves a /stats HTTP dashboard on
/// port 8081 showing response latencies, token usage, and request counts.
///
/// Wire protocol (TCP port 9090):
///   Client sends JSON lines, one per request:
///   {"ts":1710000000,"model":"claude-sonnet-4-5","latency_ms":1234,"tokens_in":50,"tokens_out":200,"status":"ok"}
///   Server responds: OK\n
///
/// HTTP endpoint (port 8081):
///   GET / — HTML dashboard with live stats
///   GET /api/stats — JSON stats summary
///   GET /api/recent — JSON array of last 50 entries

const std = @import("std");

const posix = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
});

const PORT: u16 = 8081;
const MAX_ENTRIES: usize = 10000;

// ---- Metrics storage ----

const MetricEntry = struct {
    timestamp: i64,
    latency_ms: u32,
    tokens_in: u32,
    tokens_out: u32,
    status_ok: bool,
    model: [64]u8,
    model_len: u8,
};

var entries: [MAX_ENTRIES]MetricEntry = undefined;
var entry_count: usize = 0;
var total_requests: u64 = 0;
var total_latency_ms: u64 = 0;
var total_tokens_in: u64 = 0;
var total_tokens_out: u64 = 0;
var total_errors: u64 = 0;

fn addEntry(e: MetricEntry) void {
    const idx = entry_count % MAX_ENTRIES;
    entries[idx] = e;
    if (entry_count < MAX_ENTRIES) entry_count += 1;
    total_requests += 1;
    total_latency_ms += e.latency_ms;
    total_tokens_in += e.tokens_in;
    total_tokens_out += e.tokens_out;
    if (!e.status_ok) total_errors += 1;
}

// ---- Main ----

pub fn main() !void {
    const sock = createListener(PORT) orelse return;

    const msg1 = "zigix-tsdb: listening on port 8081\n";
    _ = posix.write(1, msg1, msg1.len);

    // Single-port accept loop — handles both HTTP dashboard and metrics ingest
    while (true) {
        var caddr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
        var clen: posix.socklen_t = @sizeOf(posix.struct_sockaddr_in);
        const client = posix.accept(sock, @ptrCast(&caddr), &clen);
        if (client < 0) continue;

        handleClient(client);
        _ = posix.close(client);
    }
}

fn handleClient(fd: c_int) void {
    var buf: [8192]u8 = undefined;
    const n = posix.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const request = buf[0..@intCast(n)];

    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const first_line = request[0..line_end];

    if (std.mem.startsWith(u8, first_line, "POST /api/ingest")) {
        // Metrics ingest — body is JSON
        const body_sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
        handleMetricsClient(fd, request[body_sep + 4 ..]);
    } else if (std.mem.startsWith(u8, first_line, "GET /api/stats")) {
        serveStatsJson(fd);
    } else if (std.mem.startsWith(u8, first_line, "GET /api/recent")) {
        serveRecentJson(fd);
    } else {
        serveDashboard(fd);
    }
}

fn createListener(port: u16) ?c_int {
    const sock = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0);
    if (sock < 0) return null;

    var optval: c_int = 1;
    _ = posix.setsockopt(sock, posix.SOL_SOCKET, posix.SO_REUSEADDR, &optval, @sizeOf(c_int));

    var addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
    addr.sin_family = posix.AF_INET;
    addr.sin_port = @byteSwap(@as(u16, port));
    addr.sin_addr.s_addr = 0;

    if (posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.struct_sockaddr_in)) < 0) return null;
    if (posix.listen(sock, 8) < 0) return null;
    return sock;
}

// ---- Metrics TCP handler ----

fn handleMetricsClient(fd: c_int, data: []const u8) void {

    // Parse simple JSON fields manually (no allocator needed)
    var entry = MetricEntry{
        .timestamp = 0,
        .latency_ms = 0,
        .tokens_in = 0,
        .tokens_out = 0,
        .status_ok = true,
        .model = [_]u8{0} ** 64,
        .model_len = 0,
    };

    entry.timestamp = extractJsonInt(data, "\"ts\":") orelse blk: {
        var t: c_long = 0;
        _ = posix.time(&t);
        break :blk @as(i64, t);
    };
    entry.latency_ms = @truncate(@as(u64, @intCast(extractJsonInt(data, "\"latency_ms\":") orelse 0)));
    entry.tokens_in = @truncate(@as(u64, @intCast(extractJsonInt(data, "\"tokens_in\":") orelse 0)));
    entry.tokens_out = @truncate(@as(u64, @intCast(extractJsonInt(data, "\"tokens_out\":") orelse 0)));

    if (extractJsonStr(data, "\"model\":\"")) |m| {
        const copy_len = @min(m.len, 64);
        @memcpy(entry.model[0..copy_len], m[0..copy_len]);
        entry.model_len = @intCast(copy_len);
    }

    if (extractJsonStr(data, "\"status\":\"")) |s| {
        entry.status_ok = std.mem.eql(u8, s, "ok");
    }

    addEntry(entry);

    _ = posix.write(fd, "OK\n", 3);
}

fn extractJsonInt(data: []const u8, key: []const u8) ?i64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    var end = start;
    while (end < data.len and (data[end] >= '0' and data[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, data[start..end], 10) catch null;
}

fn extractJsonStr(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    const end = std.mem.indexOf(u8, data[start..], "\"") orelse return null;
    return data[start .. start + end];
}

// ---- HTTP handler ----

fn handleHttpClient(fd: c_int) void {
    var buf: [4096]u8 = undefined;
    const n = posix.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const request = buf[0..@intCast(n)];

    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const first_line = request[0..line_end];

    if (std.mem.startsWith(u8, first_line, "GET /api/stats")) {
        serveStatsJson(fd);
    } else if (std.mem.startsWith(u8, first_line, "GET /api/recent")) {
        serveRecentJson(fd);
    } else {
        serveDashboard(fd);
    }
}

fn serveStatsJson(fd: c_int) void {
    const avg_latency: u64 = if (total_requests > 0) total_latency_ms / total_requests else 0;
    var body: [512]u8 = undefined;
    const body_str = std.fmt.bufPrint(&body,
        \\{{"total_requests":{d},"avg_latency_ms":{d},"total_tokens_in":{d},"total_tokens_out":{d},"total_errors":{d},"entries_stored":{d}}}
    , .{ total_requests, avg_latency, total_tokens_in, total_tokens_out, total_errors, entry_count }) catch return;
    sendHttp(fd, "200 OK", "application/json", body_str);
}

fn serveRecentJson(fd: c_int) void {
    var body: [32768]u8 = undefined;
    var pos: usize = 0;
    body[pos] = '[';
    pos += 1;

    const count = @min(entry_count, 50);
    const start_idx = if (entry_count > count) entry_count - count else 0;

    for (start_idx..entry_count) |i| {
        const idx = i % MAX_ENTRIES;
        const e = &entries[idx];
        if (pos > 1) {
            body[pos] = ',';
            pos += 1;
        }
        const slice = std.fmt.bufPrint(body[pos..],
            \\{{"ts":{d},"latency_ms":{d},"tokens_in":{d},"tokens_out":{d},"ok":{s},"model":"{s}"}}
        , .{
            e.timestamp, e.latency_ms, e.tokens_in, e.tokens_out,
            if (e.status_ok) "true" else "false",
            e.model[0..e.model_len],
        }) catch break;
        pos += slice.len;
    }

    body[pos] = ']';
    pos += 1;
    sendHttp(fd, "200 OK", "application/json", body[0..pos]);
}

fn serveDashboard(fd: c_int) void {
    sendHttp(fd, "200 OK", "text/html; charset=utf-8", DASHBOARD_HTML);
}

fn sendHttp(fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.0 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = posix.write(fd, h.ptr, h.len);
    _ = posix.write(fd, body.ptr, body.len);
}

// ---- Dashboard HTML ----

const DASHBOARD_HTML =
    \\<!DOCTYPE html><html><head><meta charset="utf-8"><title>Zigix TSDB</title>
    \\<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:system-ui;background:#0a0a0a;color:#e0e0e0;padding:24px}
    \\h1{font-size:20px;margin-bottom:16px;color:#fff}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:24px}
    \\.card{background:#1a1a1a;border:1px solid #333;border-radius:8px;padding:16px}.card .label{font-size:12px;color:#888;text-transform:uppercase}
    \\.card .value{font-size:28px;font-weight:600;color:#4ade80;margin-top:4px}
    \\table{width:100%;border-collapse:collapse}th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #222}
    \\th{color:#888;font-size:12px;text-transform:uppercase}td{font-size:14px}.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:11px}
    \\.ok{background:#1a3a2a;color:#4ade80}.err{background:#3a1a1a;color:#f87171}</style></head>
    \\<body><h1>Zigix TSDB Dashboard</h1>
    \\<div class="stats" id="stats"></div>
    \\<h2 style="font-size:16px;margin-bottom:12px">Recent Requests</h2>
    \\<table><thead><tr><th>Time</th><th>Model</th><th>Latency</th><th>Tokens In</th><th>Tokens Out</th><th>Status</th></tr></thead>
    \\<tbody id="rows"></tbody></table>
    \\<script>
    \\async function refresh(){
    \\const s=await(await fetch('/api/stats')).json();
    \\document.getElementById('stats').innerHTML=
    \\`<div class="card"><div class="label">Requests</div><div class="value">${s.total_requests}</div></div>`+
    \\`<div class="card"><div class="label">Avg Latency</div><div class="value">${s.avg_latency_ms}ms</div></div>`+
    \\`<div class="card"><div class="label">Tokens In</div><div class="value">${s.total_tokens_in}</div></div>`+
    \\`<div class="card"><div class="label">Tokens Out</div><div class="value">${s.total_tokens_out}</div></div>`+
    \\`<div class="card"><div class="label">Errors</div><div class="value">${s.total_errors}</div></div>`+
    \\`<div class="card"><div class="label">Stored</div><div class="value">${s.entries_stored}</div></div>`;
    \\const r=await(await fetch('/api/recent')).json();
    \\document.getElementById('rows').innerHTML=r.reverse().map(e=>
    \\`<tr><td>${new Date(e.ts*1000).toLocaleTimeString()}</td><td>${e.model}</td><td>${e.latency_ms}ms</td><td>${e.tokens_in}</td><td>${e.tokens_out}</td><td><span class="badge ${e.ok?'ok':'err'}">${e.ok?'OK':'ERR'}</span></td></tr>`
    \\).join('');}
    \\refresh();setInterval(refresh,3000);
    \\</script></body></html>
;
