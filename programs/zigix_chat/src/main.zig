/// Zigix Chat — self-contained AI chat server for bare-metal Zigix OS.
///
/// Serves an HTML chat UI on port 80 and proxies requests to Claude API
/// over HTTPS. Uses POSIX socket APIs for maximum Zigix compatibility.
///
/// Cross-compile: zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall

const std = @import("std");
const tls_client = @import("tls_client.zig");

const posix = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

// ---- Configuration ----

const LISTEN_PORT: u16 = 8080;
const CLAUDE_MODEL = "claude-sonnet-4-6";
const MAX_REQUEST = 65536;
const MAX_RESPONSE = 1024 * 1024;
const TSDB_PORT: u16 = 8081;

// TSDB IP (Machine B) — read from /etc/tsdb_host at startup
var tsdb_ip: u32 = 0; // 0 = disabled

// ---- Embedded HTML Chat UI ----

const INDEX_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>Zigix Chat</title>
    \\<style>
    \\*{margin:0;padding:0;box-sizing:border-box}
    \\body{font-family:system-ui,-apple-system,sans-serif;background:#0a0a0a;color:#e0e0e0;height:100vh;display:flex;flex-direction:column}
    \\header{padding:16px 24px;border-bottom:1px solid #222;display:flex;align-items:center;gap:12px}
    \\header h1{font-size:18px;font-weight:600;color:#fff}
    \\header .badge{font-size:11px;background:#1a3a2a;color:#4ade80;padding:2px 8px;border-radius:12px}
    \\header .sub{font-size:12px;color:#666}
    \\.chat{flex:1;overflow-y:auto;padding:24px;display:flex;flex-direction:column;gap:16px}
    \\.msg{max-width:720px;padding:12px 16px;border-radius:12px;line-height:1.6;white-space:pre-wrap;word-wrap:break-word;font-size:15px}
    \\.msg.user{align-self:flex-end;background:#1d4ed8;color:#fff;border-bottom-right-radius:4px}
    \\.msg.assistant{align-self:flex-start;background:#1a1a1a;border:1px solid #333;border-bottom-left-radius:4px}
    \\.msg.system{align-self:center;color:#666;font-size:13px;font-style:italic}
    \\form{padding:16px 24px;border-top:1px solid #222;display:flex;gap:12px}
    \\input{flex:1;padding:12px 16px;background:#111;border:1px solid #333;border-radius:8px;color:#fff;font-size:15px;outline:none}
    \\input:focus{border-color:#3b82f6}
    \\button{padding:12px 24px;background:#2563eb;color:#fff;border:none;border-radius:8px;font-size:15px;cursor:pointer;font-weight:500}
    \\button:hover{background:#1d4ed8}
    \\button:disabled{opacity:.5;cursor:not-allowed}
    \\.typing{display:none;align-self:flex-start;color:#888;font-size:13px;padding:8px 16px}
    \\.typing.active{display:block}
    \\</style>
    \\</head>
    \\<body>
    \\<header>
    \\<div>
    \\<h1>Zigix Chat</h1>
    \\<div class="sub">Bare-metal OS &middot; Google Cloud Axion (ARM64) &middot; gVNIC &middot; Custom TCP/IP</div>
    \\</div>
    \\<span class="badge">live</span>
    \\</header>
    \\<div class="chat" id="chat">
    \\<div class="msg system">Connected to Zigix OS. Every layer from NIC driver to HTTP server is hand-written Zig. Type a message to chat with Claude.</div>
    \\</div>
    \\<div class="typing" id="typing">Claude is thinking&hellip;</div>
    \\<form id="form">
    \\<input id="input" placeholder="Ask anything..." autocomplete="off" autofocus>
    \\<button type="submit" id="btn">Send</button>
    \\</form>
    \\<script>
    \\const chat=document.getElementById('chat'),form=document.getElementById('form'),
    \\input=document.getElementById('input'),typing=document.getElementById('typing'),
    \\btn=document.getElementById('btn');
    \\let history=[];
    \\function addMsg(role,text){
    \\const d=document.createElement('div');d.className='msg '+role;d.textContent=text;
    \\chat.appendChild(d);chat.scrollTop=chat.scrollHeight;}
    \\form.onsubmit=async e=>{e.preventDefault();const q=input.value.trim();if(!q)return;
    \\input.value='';addMsg('user',q);history.push({role:'user',content:q});
    \\typing.classList.add('active');btn.disabled=true;
    \\try{const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},
    \\body:JSON.stringify({messages:history})});
    \\const j=await r.json();const t=j.content||j.error||'No response';
    \\addMsg('assistant',t);history.push({role:'assistant',content:t});
    \\}catch(err){addMsg('system','Error: '+err.message);}
    \\typing.classList.remove('active');btn.disabled=false;input.focus();};
    \\</script>
    \\</body></html>
;

// ---- Main ----

var api_key_storage: [256]u8 = undefined;
var api_key_len: usize = 0;

pub fn main() !void {
    // Read API key from environment or /etc/anthropic_key file
    const key_ptr: ?[*:0]const u8 = posix.getenv("ANTHROPIC_API_KEY");
    if (key_ptr != null) {
        const key_slice = std.mem.sliceTo(key_ptr.?, 0);
        @memcpy(api_key_storage[0..key_slice.len], key_slice);
        api_key_len = key_slice.len;
    } else {
        // Try reading from file (for Zigix where env vars may not work)
        var fd = std.c.open("/etc/anthropic_key", .{}, @as(c_uint, 0));
        if (fd < 0) fd = std.c.open("/anthropic_key", .{}, @as(c_uint, 0));
        if (fd >= 0) {
            const n = posix.read(fd, &api_key_storage, api_key_storage.len);
            _ = posix.close(fd);
            if (n > 0) {
                // Trim trailing whitespace
                api_key_len = @intCast(n);
                while (api_key_len > 0 and (api_key_storage[api_key_len - 1] == '\n' or api_key_storage[api_key_len - 1] == '\r' or api_key_storage[api_key_len - 1] == ' '))
                    api_key_len -= 1;
            }
        }
    }
    if (api_key_len == 0) {
        const err_msg = "Error: Set ANTHROPIC_API_KEY env var or create /etc/anthropic_key\n";
        _ = posix.write(2, err_msg, err_msg.len);
        return;
    }

    // Load TSDB host IP from /etc/tsdb_host (format: "10.164.15.xxx")
    {
        var tfd = std.c.open("/etc/tsdb_host", .{}, @as(c_uint, 0));
        if (tfd < 0) tfd = std.c.open("/tsdb_host", .{}, @as(c_uint, 0));
        if (tfd >= 0) {
            var tbuf: [32]u8 = undefined;
            const tn = std.c.read(tfd, &tbuf, tbuf.len);
            _ = std.c.close(tfd);
            if (tn > 0) {
                var tlen: usize = @intCast(tn);
                while (tlen > 0 and (tbuf[tlen - 1] == '\n' or tbuf[tlen - 1] == ' ')) tlen -= 1;
                if (parseIpv4(tbuf[0..tlen])) |ip| {
                    tsdb_ip = ip;
                    const m = "zigix-chat: TSDB metrics enabled\n";
                    _ = posix.write(1, m, m.len);
                }
            }
        }
    }

    // Create TCP socket
    const sock = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0);
    if (sock < 0) {
        _ = posix.write(2, "Error: socket() failed\n", 23);
        return;
    }

    // Set SO_REUSEADDR
    var optval: c_int = 1;
    _ = posix.setsockopt(sock, posix.SOL_SOCKET, posix.SO_REUSEADDR, &optval, @sizeOf(c_int));

    // Bind
    var addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
    addr.sin_family = posix.AF_INET;
    addr.sin_port = @byteSwap(@as(u16, LISTEN_PORT));
    addr.sin_addr.s_addr = 0; // INADDR_ANY

    if (posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.struct_sockaddr_in)) < 0) {
        _ = posix.write(2, "Error: bind() failed\n", 21);
        return;
    }

    // Listen
    if (posix.listen(sock, 16) < 0) {
        _ = posix.write(2, "Error: listen() failed\n", 23);
        return;
    }

    const msg = "zigix-chat: listening on port 80\n";
    _ = posix.write(1, msg, msg.len);

    // Accept loop
    while (true) {
        var client_addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
        var client_len: posix.socklen_t = @sizeOf(posix.struct_sockaddr_in);

        const client = posix.accept(sock, @ptrCast(&client_addr), &client_len);
        if (client < 0) continue;

        handleClient(client);

        _ = posix.close(client);
    }
}

fn handleClient(fd: c_int) void {
    var buf: [MAX_REQUEST]u8 = undefined;

    // Read HTTP request
    const n = posix.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const request = buf[0..@intCast(n)];

    // Parse first line
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const first_line = request[0..line_end];

    if (std.mem.startsWith(u8, first_line, "GET / ") or
        std.mem.startsWith(u8, first_line, "GET /index"))
    {
        sendResponse(fd, "200 OK", "text/html; charset=utf-8", INDEX_HTML);
    } else if (std.mem.startsWith(u8, first_line, "POST /api/chat")) {
        handleChatApi(fd, request);
    } else if (std.mem.startsWith(u8, first_line, "GET /health")) {
        sendResponse(fd, "200 OK", "application/json",
            \\{"status":"ok","os":"zigix","hw":"gce-axion-arm64","nic":"gvnic","tls":"zig-std-crypto"}
        );
    } else {
        sendResponse(fd, "404 Not Found", "text/plain", "Not Found");
    }
}

fn handleChatApi(fd: c_int, request: []const u8) void {
    const body_sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
    const body = request[body_sep + 4 ..];

    const allocator = std.heap.c_allocator;

    // Time the API call
    var t_start: i64 = 0;
    {
        var tp: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &tp);
        t_start = tp.sec;
    }
    const start_ms = getMonotonicMs();

    const result = callClaudeApi(allocator, body) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch return;
        sendResponse(fd, "502 Bad Gateway", "application/json", err_msg);
        // Report error metric
        reportMetric(t_start, getMonotonicMs() - start_ms, 0, 0, false);
        return;
    };
    defer allocator.free(result);

    const latency = getMonotonicMs() - start_ms;
    sendResponse(fd, "200 OK", "application/json", result);

    // Report success metric (rough token estimates from response size)
    const tokens_out: u32 = @truncate(result.len / 4); // ~4 chars per token
    reportMetric(t_start, latency, 50, tokens_out, true);
}

fn callClaudeApi(allocator: std.mem.Allocator, chat_body: []const u8) ![]u8 {
    const key = api_key_storage[0..api_key_len];

    // The chat body is: {"messages":[...]}
    // Extract the messages array substring directly
    const msgs_key = "\"messages\":";
    const msgs_start = std.mem.indexOf(u8, chat_body, msgs_key) orelse return error.InvalidInput;
    const msgs_json = chat_body[msgs_start + msgs_key.len ..];
    const msgs_end = std.mem.lastIndexOf(u8, msgs_json, "]") orelse return error.InvalidInput;
    const messages_slice = msgs_json[0 .. msgs_end + 1];

    // Build Claude API request body
    var body_buf: [MAX_REQUEST]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"model\":\"{s}\",\"max_tokens\":2048,\"messages\":{s}}}", .{ CLAUDE_MODEL, messages_slice }) catch return error.InvalidInput;

    // Call Claude API directly over TLS (no relay needed)
    const resp_body = tls_client.callClaudeDirectTls(allocator, key, body) catch |err| {
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "TLS API call failed: {s}\n", .{@errorName(err)}) catch "TLS API call failed\n";
        _ = posix.write(2, err_msg.ptr, err_msg.len);
        return error.Unexpected;
    };
    defer allocator.free(resp_body);

    // Parse Claude response
    const resp = try std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{});
    defer resp.deinit();

    if (resp.value.object.get("error")) |err_obj| {
        if (err_obj.object.get("message")) |msg| {
            return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg.string});
        }
    }

    if (resp.value.object.get("content")) |content| {
        if (content.array.items.len > 0) {
            if (content.array.items[0].object.get("text")) |text| {
                // Escape the text for JSON output
                return escapeJsonResponse(allocator, text.string);
            }
        }
    }

    return std.fmt.allocPrint(allocator, "{{\"error\":\"Could not parse response\"}}", .{});
}

fn escapeJsonResponse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Simple JSON string escaping: wrap text in {"content":"..."}
    var out = try allocator.alloc(u8, text.len * 2 + 32);
    var i: usize = 0;
    const prefix = "{\"content\":\"";
    @memcpy(out[0..prefix.len], prefix);
    i = prefix.len;

    for (text) |ch| {
        switch (ch) {
            '"' => { out[i] = '\\'; out[i+1] = '"'; i += 2; },
            '\\' => { out[i] = '\\'; out[i+1] = '\\'; i += 2; },
            '\n' => { out[i] = '\\'; out[i+1] = 'n'; i += 2; },
            '\r' => { out[i] = '\\'; out[i+1] = 'r'; i += 2; },
            '\t' => { out[i] = '\\'; out[i+1] = 't'; i += 2; },
            else => { out[i] = ch; i += 1; },
        }
    }
    const suffix = "\"}";
    @memcpy(out[i..i+suffix.len], suffix);
    i += suffix.len;

    return allocator.realloc(out, i) catch out[0..i];
}

fn sendResponse(fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.0 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = posix.write(fd, hdr.ptr, hdr.len);
    _ = posix.write(fd, body.ptr, body.len);
}

// ---- Metrics reporting to TSDB (Machine B) ----

fn getMonotonicMs() u64 {
    var tp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &tp);
    return @as(u64, @intCast(tp.sec)) * 1000 + @as(u64, @intCast(tp.nsec)) / 1_000_000;
}

fn reportMetric(timestamp: i64, latency_ms: u64, tokens_in: u32, tokens_out: u32, ok: bool) void {
    if (tsdb_ip == 0) return;

    const sock = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0);
    if (sock < 0) return;
    defer _ = posix.close(sock);

    var addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
    addr.sin_family = posix.AF_INET;
    addr.sin_port = @byteSwap(@as(u16, TSDB_PORT));
    addr.sin_addr.s_addr = @byteSwap(tsdb_ip);

    if (posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.struct_sockaddr_in)) < 0) return;

    // Build JSON metric and send as HTTP POST
    var buf: [512]u8 = undefined;
    const json_body = std.fmt.bufPrint(&buf,
        \\{{"ts":{d},"model":"{s}","latency_ms":{d},"tokens_in":{d},"tokens_out":{d},"status":"{s}"}}
    , .{
        timestamp, CLAUDE_MODEL, latency_ms, tokens_in, tokens_out,
        if (ok) "ok" else "error",
    }) catch return;

    var hdr: [256]u8 = undefined;
    const http_req = std.fmt.bufPrint(&hdr, "POST /api/ingest HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{json_body.len}) catch return;
    _ = posix.write(sock, http_req.ptr, http_req.len);
    _ = posix.write(sock, json_body.ptr, json_body.len);
}

fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var num: u32 = 0;
    for (s) |c| {
        if (c == '.') {
            if (part_idx >= 4) return null;
            parts[part_idx] = @truncate(num);
            part_idx += 1;
            num = 0;
        } else if (c >= '0' and c <= '9') {
            num = num * 10 + (c - '0');
        } else return null;
    }
    if (part_idx != 3) return null;
    parts[3] = @truncate(num);
    return @as(u32, parts[0]) << 24 | @as(u32, parts[1]) << 16 | @as(u32, parts[2]) << 8 | @as(u32, parts[3]);
}
