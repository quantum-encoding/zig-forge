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
    @cInclude("sys/time.h");
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
/// Where the NEXT entry goes, counted since start and never capped. Distinct
/// from `entry_count` (how many slots hold data) because the two stop agreeing
/// the moment the ring fills: indexing by the capped count makes every write
/// after the 10 000th land in slot 0, so the ring stops rotating and
/// `/api/recent` freezes on the batch that filled it while live traffic is
/// invisible.
var write_idx: u64 = 0;
var total_requests: u64 = 0;
var total_latency_ms: u64 = 0;
var total_tokens_in: u64 = 0;
var total_tokens_out: u64 = 0;
var total_errors: u64 = 0;

fn addEntry(e: MetricEntry) void {
    entries[write_idx % MAX_ENTRIES] = e;
    write_idx += 1;
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

        setClientTimeouts(client);
        handleClient(client);
        _ = posix.close(client);
    }
}

/// Seconds a single connection may spend blocked in one read or write.
const CLIENT_TIMEOUT_SECS: c_long = 5;

/// Bound both directions on an accepted socket.
///
/// The accept loop is sequential — accept, handle, close — so a peer that
/// completes the handshake and then sends nothing used to wedge ingest, stats
/// and dashboard alike until the kernel gave up on the socket (hours). A
/// receive timeout turns that into a five-second stall; the send timeout stops
/// the mirror-image case where a client accepts the connection and never reads
/// the response.
fn setClientTimeouts(fd: c_int) void {
    const tv = posix.struct_timeval{ .tv_sec = CLIENT_TIMEOUT_SECS, .tv_usec = 0 };
    _ = posix.setsockopt(fd, posix.SOL_SOCKET, posix.SO_RCVTIMEO, &tv, @sizeOf(posix.struct_timeval));
    _ = posix.setsockopt(fd, posix.SOL_SOCKET, posix.SO_SNDTIMEO, &tv, @sizeOf(posix.struct_timeval));
}

/// Read until the CRLFCRLF header terminator is in hand, returning its offset.
///
/// One `read()` is not a request: TCP is free to split headers across segments,
/// and treating the first arrival as the whole thing is what let a body land
/// half-parsed. Bounded by the buffer and, per connection, by SO_RCVTIMEO.
fn readHeaders(fd: c_int, buf: []u8, len: *usize) ?usize {
    while (true) {
        if (std.mem.indexOf(u8, buf[0..len.*], "\r\n\r\n")) |h| return h;
        if (len.* == buf.len) return null;
        const n = posix.read(fd, buf[len.*..].ptr, buf.len - len.*);
        if (n <= 0) return null;
        len.* += @intCast(n);
    }
}

/// The declared body length, or null when the header is absent or unparseable.
/// A request that does not say how long its body is has no body we are willing
/// to guess at — guessing is what silently zeroed latency and token counts.
fn contentLength(headers: []const u8) ?usize {
    const key = "content-length:";
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len < key.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..key.len], key)) continue;
        const v = std.mem.trim(u8, line[key.len..], " \t");
        return std.fmt.parseInt(usize, v, 10) catch null;
    }
    return null;
}

/// Read until the whole DECLARED body is in hand, so a body split across TCP
/// segments is never parsed as a short one. A short read used to be accepted
/// silently: every field the parser could not find defaulted to 0 and the
/// ingest was still acked, so real latency vanished into a healthy-looking
/// average. Bounded twice — by Content-Length and by the buffer.
fn readBody(fd: c_int, buf: []u8, len: *usize, body_start: usize) ?[]const u8 {
    const declared = contentLength(buf[0..body_start]) orelse return null;
    if (declared > buf.len - body_start) return null;
    const want = body_start + declared;
    while (len.* < want) {
        const n = posix.read(fd, buf[len.*..].ptr, buf.len - len.*);
        if (n <= 0) return null;
        len.* += @intCast(n);
    }
    return buf[body_start..want];
}

fn handleClient(fd: c_int) void {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;

    const header_end = readHeaders(fd, &buf, &len) orelse return;
    const line_end = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse return;
    const first_line = buf[0..line_end];

    if (std.mem.startsWith(u8, first_line, "POST /api/ingest")) {
        // Metrics ingest — body is JSON, and must be complete before it is read.
        const body = readBody(fd, &buf, &len, header_end + 4) orelse return;
        handleMetricsClient(fd, body);
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
    // Loopback, not INADDR_ANY: there is no auth, no token and no rate limit on
    // /api/ingest, so a wildcard bind hands every reachable peer the ability to
    // plant dashboard rows and flood the ring. A network ingestor needs a
    // credential first, not a wider bind.
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7F00_0001);

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
        // Validated BEFORE truncation, on the bytes the client actually sent:
        // a blind cut at 64 can split a codepoint, which would fail a valid
        // name while an invalid one could still pass on its first 64 bytes.
        if (!std.unicode.utf8ValidateSlice(m)) {
            _ = posix.write(fd, REJECT_MSG, REJECT_MSG.len);
            return;
        }
        const copy_len = utf8TruncLen(m, entry.model.len);
        @memcpy(entry.model[0..copy_len], m[0..copy_len]);
        entry.model_len = @intCast(copy_len);
    }

    if (extractJsonStr(data, "\"status\":\"")) |s| {
        entry.status_ok = std.mem.eql(u8, s, "ok");
    }

    addEntry(entry);

    _ = posix.write(fd, "OK\n", 3);
}

/// What a rejected ingest is told. The store never holds bytes it could not
/// validate, and the client is told so rather than being acked into believing
/// the metric landed.
const REJECT_MSG = "ERR invalid model encoding\n";

/// The largest length <= `max` that does not cut a UTF-8 codepoint in half.
fn utf8TruncLen(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    // s[n] is the first byte NOT copied; a continuation byte there means the
    // cut lands inside a sequence, so walk back to its lead byte.
    while (n > 0 and (s[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
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

/// Serialize a single metric entry as a JSON object via std.json.Stringify.
/// Using Stringify (not a printf template) guarantees the attacker-influenced
/// model string is escaped, closing the stored-XSS / JSON-corruption sink.
fn stringifyEntry(e: *const MetricEntry, writer: *std.Io.Writer) std.json.Stringify.Error!void {
    try std.json.Stringify.value(.{
        .ts = e.timestamp,
        .latency_ms = e.latency_ms,
        .tokens_in = e.tokens_in,
        .tokens_out = e.tokens_out,
        .ok = e.status_ok,
        .model = e.model[0..e.model_len],
    }, .{}, writer);
}

/// The half-open range of logical indices `/api/recent` reports, newest last.
///
/// Windowed off the write cursor, never off `entry_count`: once the ring is
/// full the count stops moving, so a count-based window pins the view to the
/// batch that filled the ring and every later entry is invisible.
fn recentWindow(writes: u64, stored: usize, want: u64) struct { start: u64, end: u64 } {
    const count = @min(@as(u64, stored), want);
    return .{ .start = writes - count, .end = writes };
}

fn serveRecentJson(fd: c_int) void {
    var body: [32768]u8 = undefined;
    var pos: usize = 0;
    body[pos] = '[';
    pos += 1;

    const w = recentWindow(write_idx, entry_count, 50);

    for (w.start..w.end) |i| {
        const idx = i % MAX_ENTRIES;
        const e = &entries[idx];

        // Serialize each entry with std.json.Stringify so the attacker-influenced
        // model bytes are escaped ("\, control chars, etc.) instead of interpolated
        // raw into a printf template — closes the stored-XSS / JSON-corruption sink.
        // Serialize into a per-entry scratch first so a buffer-full entry breaks the
        // loop cleanly without leaving a trailing comma (invalid JSON).
        var scratch: [640]u8 = undefined;
        var scratch_writer = std.Io.Writer.fixed(&scratch);
        stringifyEntry(e, &scratch_writer) catch break;
        const chunk = scratch_writer.buffered();

        // Reserve one byte for the closing ']'; account for the leading comma.
        const comma_len: usize = if (pos > 1) 1 else 0;
        if (pos + comma_len + chunk.len + 1 > body.len) break;

        if (comma_len == 1) {
            body[pos] = ',';
            pos += 1;
        }
        @memcpy(body[pos..][0..chunk.len], chunk);
        pos += chunk.len;
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
    // No Access-Control-Allow-Origin: the dashboard is served from this same
    // listener, so it needs none, and a wildcard let any origin the operator
    // visited read the full request history.
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.0 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
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
    \\// Rows are BUILT, not interpolated: e.model is attacker-supplied and an
    \\// innerHTML sink executes whatever it contains. textContent cannot.
    \\document.getElementById('rows').replaceChildren(...r.reverse().map(e=>{
    \\const tr=document.createElement('tr');
    \\for(const v of [new Date(e.ts*1000).toLocaleTimeString(),e.model,e.latency_ms+'ms',e.tokens_in,e.tokens_out]){
    \\const td=document.createElement('td');td.textContent=v;tr.appendChild(td);}
    \\const td=document.createElement('td'),b=document.createElement('span');
    \\b.className='badge '+(e.ok?'ok':'err');b.textContent=e.ok?'OK':'ERR';
    \\td.appendChild(b);tr.appendChild(td);return tr;}));}
    \\refresh();setInterval(refresh,3000);
    \\</script></body></html>
;

// ---- Tests ----

fn testEntry(model: []const u8) MetricEntry {
    var e: MetricEntry = .{
        .timestamp = 1710000000,
        .latency_ms = 1234,
        .tokens_in = 50,
        .tokens_out = 200,
        .status_ok = true,
        .model = undefined,
        .model_len = @intCast(model.len),
    };
    @memcpy(e.model[0..model.len], model);
    return e;
}

test "stringifyEntry emits the exact wire shape zigix_chat expects" {
    // Anchor: hand-written expected bytes matching the /api/recent contract the
    // dashboard + zigix_chat rely on (key order, unquoted bool, quoted string).
    const e = testEntry("claude-sonnet-4-5");
    var buf: [640]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try stringifyEntry(&e, &w);
    try std.testing.expectEqualStrings(
        \\{"ts":1710000000,"latency_ms":1234,"tokens_in":50,"tokens_out":200,"ok":true,"model":"claude-sonnet-4-5"}
    , w.buffered());
}

test "stringifyEntry escapes attacker-controlled model bytes (no JSON-IN-FMT injection)" {
    // A model containing a quote, backslash and control byte would break a printf
    // template ("model":"{s}") — verify Stringify escapes them per the JSON spec.
    const nasty = "cl\"aude\\\n<script>";
    const e = testEntry(nasty);
    var buf: [640]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try stringifyEntry(&e, &w);
    const out = w.buffered();

    // Escaped forms must be present on the wire.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"") != null); // \"
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\") != null); // \\
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null); //  \n

    // The output must be valid JSON and round-trip the model string exactly when
    // read back by std.json's parser (a distinct codepath), proving no corruption.
    const Parsed = struct {
        ts: i64,
        latency_ms: u32,
        tokens_in: u32,
        tokens_out: u32,
        ok: bool,
        model: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(nasty, parsed.value.model);
    try std.testing.expectEqual(@as(i64, 1710000000), parsed.value.ts);
    try std.testing.expect(parsed.value.ok);
}

test "the ring keeps rotating past MAX_ENTRIES instead of pinning slot 0" {
    // Reset the globals this test drives; they are process-wide.
    write_idx = 0;
    entry_count = 0;

    // One past a full ring: the wrap is exactly where a count-based index
    // stopped moving and every later write landed in slot 0.
    const total: u64 = MAX_ENTRIES + 1;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        var e = testEntry("m");
        e.latency_ms = @truncate(i);
        addEntry(e);
    }

    try std.testing.expectEqual(total, write_idx);
    try std.testing.expectEqual(MAX_ENTRIES, entry_count);
    // The newest write wrapped to slot 0, and slot 1 still holds the entry
    // written one full lap earlier — the ring rotated rather than froze.
    try std.testing.expectEqual(@as(u32, @truncate(total - 1)), entries[0].latency_ms);
    try std.testing.expectEqual(@as(u32, 1), entries[1].latency_ms);

    // /api/recent shows the 50 NEWEST, ending on the entry just written.
    const w = recentWindow(write_idx, entry_count, 50);
    try std.testing.expectEqual(total, w.end);
    try std.testing.expectEqual(total - 50, w.start);
    const newest = entries[(w.end - 1) % MAX_ENTRIES];
    try std.testing.expectEqual(@as(u32, @truncate(total - 1)), newest.latency_ms);

    write_idx = 0;
    entry_count = 0;
}

test "recentWindow never over-reads a partly filled ring" {
    try std.testing.expectEqual(@as(u64, 0), recentWindow(0, 0, 50).start);
    try std.testing.expectEqual(@as(u64, 0), recentWindow(0, 0, 50).end);
    const w = recentWindow(7, 7, 50);
    try std.testing.expectEqual(@as(u64, 0), w.start);
    try std.testing.expectEqual(@as(u64, 7), w.end);
}

test "contentLength reads the header case-insensitively, or refuses to guess" {
    try std.testing.expectEqual(@as(?usize, 42), contentLength("POST /api/ingest HTTP/1.0\r\nContent-Length: 42\r\n"));
    try std.testing.expectEqual(@as(?usize, 42), contentLength("POST / HTTP/1.0\r\ncontent-length:42\r\n"));
    try std.testing.expectEqual(@as(?usize, 42), contentLength("POST / HTTP/1.0\r\nCONTENT-LENGTH: \t42 \r\n"));
    // No header, and a header that is not a number: both refuse rather than
    // fall back to "whatever arrived", which is the truncation bug itself.
    try std.testing.expectEqual(@as(?usize, null), contentLength("GET / HTTP/1.0\r\nHost: x\r\n"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("POST / HTTP/1.0\r\nContent-Length: abc\r\n"));
}

test "utf8TruncLen cuts on a codepoint boundary" {
    // Three 3-byte codepoints; a cut at 8 must fall back to 6.
    const s = "\u{4f60}\u{597d}\u{4e16}";
    try std.testing.expectEqual(@as(usize, 9), s.len);
    try std.testing.expectEqual(@as(usize, 9), utf8TruncLen(s, 64));
    try std.testing.expectEqual(@as(usize, 6), utf8TruncLen(s, 8));
    try std.testing.expectEqual(@as(usize, 6), utf8TruncLen(s, 6));
    try std.testing.expectEqual(@as(usize, 3), utf8TruncLen(s, 5));
    try std.testing.expectEqual(@as(usize, 0), utf8TruncLen(s, 2));
    // ASCII is never shortened below the cap.
    try std.testing.expectEqual(@as(usize, 4), utf8TruncLen("abcdef", 4));
    // What the ingest path rejects outright: a lone continuation byte.
    try std.testing.expect(!std.unicode.utf8ValidateSlice("ok\x80bad"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
}
