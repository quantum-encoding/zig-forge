/// Direct TLS client for Zigix — bypasses std.Io by implementing custom
/// Reader/Writer vtables backed by POSIX socket read()/write().
///
/// Also includes a minimal UDP DNS resolver so we don't need hardcoded IPs.

const std = @import("std");
const tls = std.crypto.tls;
const Io = std.Io;
const linux = std.os.linux;

const posix = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("time.h");
});

// ---- Constants ----

const API_HOST = "api.anthropic.com";
const DNS_SERVER_IP = 0x0A000202; // 10.0.2.2 — QEMU SLIRP DNS (use GCE metadata below for prod)
const DNS_SERVER_GCE = 0xA9FEA9FE; // 169.254.169.254 — GCE metadata service
const FALLBACK_API_IP = 0xA04F680A; // 160.79.104.10 — hardcoded fallback

/// Buffer sizes for TLS. The min_buffer_len is typically 16 KiB + 5 (TLS record overhead).
const TLS_BUFFER_SIZE = tls.max_ciphertext_record_len;

// ---- Socket-backed Reader ----
// Mirrors std.Io.net.Stream.Reader exactly, but uses POSIX read() instead of io.vtable.netRead()

const SocketReader = struct {
    interface: Io.Reader,
    fd: c_int,

    fn init(fd: c_int, buffer: []u8) SocketReader {
        return .{
            .fd = fd,
            .interface = .{
                .vtable = &.{
                    .stream = streamFn,
                    .readVec = readVecFn,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    // Matches std.Io.net.Stream.Reader.streamImpl exactly
    fn streamFn(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(io_w.writableSliceGreedy(1) catch return error.WriteFailed);
        var data: [1][]u8 = .{dest};
        const n = readVecFn(io_r, &data) catch return error.ReadFailed;
        io_w.advance(n);
        return n;
    }

    // Matches std.Io.net.Stream.Reader.readVec — uses writableVector for proper scatter I/O
    var readVecCallCount: u32 = 0;
    fn readVecFn(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));

        // Build scatter list: caller's data buffers + internal buffer
        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = io_r.writableVector(&iovecs_buffer, data) catch
            return error.ReadFailed;
        const dest = iovecs_buffer[0..dest_n];
        if (dest_n == 0 or dest[0].len == 0) {
            if (readVecCallCount < 5) {
                _ = posix.write(2, "readVec: no writable buffers!\n", 30);
                readVecCallCount += 1;
            }
            return error.ReadFailed;
        }

        // Read into the first available buffer
        var n = posix.read(r.fd, dest[0].ptr, dest[0].len);
        // If read returns 0 (EOF), retry once after a brief pause — Zigix's TCP
        // may report EOF before all segments are delivered to userspace
        if (n == 0) {
            // Brief sleep to let TCP segments arrive
            var ts = linux.timespec{ .sec = 0, .nsec = 50_000_000 }; // 50ms
            _ = linux.nanosleep(&ts, null);
            n = posix.read(r.fd, dest[0].ptr, dest[0].len);
        }
        if (readVecCallCount < 12) {
            if (n > 0) {
                // Log first 5 bytes to verify TLS record boundaries:
                // byte 0: content_type (0x17=app_data, 0x16=handshake, 0x15=alert, 0x14=change_cipher)
                // bytes 1-2: version (0x03,0x03 = TLS 1.2 compat)
                // bytes 3-4: record length (big-endian)
                const count_u: usize = @intCast(n);
                const show = @min(count_u, 5);
                const d = dest[0].ptr;
                var db: [128]u8 = undefined;
                const dm = std.fmt.bufPrint(&db, "readVec: n={d} first=[{x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}] data_size={d}\n", .{
                    n,
                    if (show > 0) d[0] else 0,
                    if (show > 1) d[1] else 0,
                    if (show > 2) d[2] else 0,
                    if (show > 3) d[3] else 0,
                    if (show > 4) d[4] else 0,
                    data_size,
                }) catch "readVec: ?\n";
                _ = posix.write(2, dm.ptr, dm.len);
            } else {
                var db: [64]u8 = undefined;
                const dm = std.fmt.bufPrint(&db, "readVec: n={d} (EOF/error)\n", .{n}) catch "readVec: ?\n";
                _ = posix.write(2, dm.ptr, dm.len);
            }
            readVecCallCount += 1;
        }
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        const count: usize = @intCast(n);

        // If bytes went into internal buffer (past data_size), update end
        if (count > data_size) {
            io_r.end += count - data_size;
            if (readVecCallCount <= 12) {
                var sb: [80]u8 = undefined;
                const sm = std.fmt.bufPrint(&sb, "  -> internal: seek={d} end={d} added={d}\n", .{ io_r.seek, io_r.end, count - data_size }) catch "?\n";
                _ = posix.write(2, sm.ptr, sm.len);
            }
            return data_size;
        }
        return count;
    }
};

// ---- Socket-backed Writer ----
// Mirrors std.Io.net.Stream.Writer — uses buffered() + consume() contract

const SocketWriter = struct {
    interface: Io.Writer,
    fd: c_int,
    total_written: usize = 0,

    fn init(fd: c_int, buffer: []u8) SocketWriter {
        return .{
            .fd = fd,
            .interface = .{
                .vtable = &.{
                    .drain = drainFn,
                },
                .buffer = buffer,
            },
        };
    }

    // Write all buffered data + new data slices to the socket
    fn drainFn(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *SocketWriter = @alignCast(@fieldParentPtr("interface", io_w));

        // Write buffered data first
        const buffered = io_w.buffered();
        var total_written: usize = 0;
        if (buffered.len > 0) {
            writeAll(w.fd, buffered) catch return error.WriteFailed;
            total_written += buffered.len;
            w.total_written += buffered.len;
        }

        // Write each data slice (last one repeated 'splat' times)
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |slice| {
                writeAll(w.fd, slice) catch return error.WriteFailed;
                total_written += slice.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| {
                writeAll(w.fd, last) catch return error.WriteFailed;
                total_written += last.len;
            }
        }

        return io_w.consume(total_written);
    }

    fn writeAll(fd: c_int, buf: []const u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = posix.write(fd, buf.ptr + off, buf.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
};

// ---- DNS Resolver ----

/// Resolve a hostname to an IPv4 address via UDP DNS query.
/// Returns the IP in network byte order (big-endian), or null on failure.
pub fn resolveHostname(hostname: []const u8, dns_server_ip: u32) ?u32 {
    const sock = posix.socket(posix.AF_INET, posix.SOCK_DGRAM, 0);
    if (sock < 0) return null;
    defer _ = posix.close(sock);

    var addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
    addr.sin_family = posix.AF_INET;
    addr.sin_port = @byteSwap(@as(u16, 53));
    addr.sin_addr.s_addr = @byteSwap(dns_server_ip);

    if (posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.struct_sockaddr_in)) < 0)
        return null;

    // Build DNS query packet
    var query_buf: [512]u8 = undefined;
    const query_len = buildDnsQuery(hostname, &query_buf) orelse return null;

    // Send query
    const sent = posix.write(sock, &query_buf, query_len);
    if (sent <= 0) return null;

    // Set a read timeout (5 seconds) using SO_RCVTIMEO
    var tv: extern struct { tv_sec: c_long, tv_usec: c_long } = .{ .tv_sec = 5, .tv_usec = 0 };
    _ = posix.setsockopt(sock, posix.SOL_SOCKET, posix.SO_RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));

    // Read response
    var resp_buf: [512]u8 = undefined;
    const resp_n = posix.read(sock, &resp_buf, resp_buf.len);
    if (resp_n < 12) return null;
    const resp_len: usize = @intCast(resp_n);

    return parseDnsResponse(resp_buf[0..resp_len]);
}

fn buildDnsQuery(hostname: []const u8, buf: *[512]u8) ?usize {
    // DNS header: ID=0x1234, flags=0x0100 (standard query, recursion desired)
    // QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
    const header = [12]u8{
        0x12, 0x34, // ID
        0x01, 0x00, // Flags: standard query, RD=1
        0x00, 0x01, // QDCOUNT=1
        0x00, 0x00, // ANCOUNT=0
        0x00, 0x00, // NSCOUNT=0
        0x00, 0x00, // ARCOUNT=0
    };
    @memcpy(buf[0..12], &header);
    var pos: usize = 12;

    // Encode hostname as DNS labels
    var remaining = hostname;
    while (remaining.len > 0) {
        const dot_pos = std.mem.indexOf(u8, remaining, ".") orelse remaining.len;
        if (dot_pos == 0 or dot_pos > 63) return null;
        if (pos + 1 + dot_pos > buf.len - 5) return null; // leave room for null + type + class
        buf[pos] = @intCast(dot_pos);
        pos += 1;
        @memcpy(buf[pos .. pos + dot_pos], remaining[0..dot_pos]);
        pos += dot_pos;
        remaining = if (dot_pos < remaining.len) remaining[dot_pos + 1 ..] else &[0]u8{};
    }
    buf[pos] = 0; // terminating label
    pos += 1;

    // QTYPE = A (1), QCLASS = IN (1)
    buf[pos] = 0;
    buf[pos + 1] = 1;
    buf[pos + 2] = 0;
    buf[pos + 3] = 1;
    pos += 4;

    return pos;
}

fn parseDnsResponse(resp: []const u8) ?u32 {
    if (resp.len < 12) return null;

    // Check ANCOUNT > 0
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return null;

    // Skip header
    var pos: usize = 12;

    // Skip question section
    while (pos < resp.len and resp[pos] != 0) {
        if (resp[pos] & 0xC0 == 0xC0) {
            pos += 2;
            break;
        }
        pos += 1 + resp[pos];
    }
    if (pos < resp.len and resp[pos] == 0) pos += 1;
    pos += 4; // QTYPE + QCLASS

    // Parse answer records
    for (0..ancount) |_| {
        if (pos + 2 > resp.len) return null;

        // Skip name (may be compressed)
        if (resp[pos] & 0xC0 == 0xC0) {
            pos += 2;
        } else {
            while (pos < resp.len and resp[pos] != 0) {
                pos += 1 + resp[pos];
            }
            pos += 1;
        }

        if (pos + 10 > resp.len) return null;
        const rtype = (@as(u16, resp[pos]) << 8) | resp[pos + 1];
        const rdlength = (@as(u16, resp[pos + 8]) << 8) | resp[pos + 9];
        pos += 10;

        if (rtype == 1 and rdlength == 4 and pos + 4 <= resp.len) {
            // A record — return IP in network byte order
            return (@as(u32, resp[pos]) << 24) |
                (@as(u32, resp[pos + 1]) << 16) |
                (@as(u32, resp[pos + 2]) << 8) |
                @as(u32, resp[pos + 3]);
        }
        pos += rdlength;
    }
    return null;
}

// ---- TLS HTTPS Client ----

/// Call the Claude API directly over TLS. Returns allocator-owned response body.
pub fn callClaudeDirectTls(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request_body: []const u8,
) ![]u8 {
    // Use hardcoded IP for now — DNS resolution requires UDP support + SO_RCVTIMEO
    // which Zigix doesn't fully implement yet
    const api_ip: u32 = FALLBACK_API_IP;
    _ = posix.write(2, "tls: connecting to 160.79.104.10:443\n", 37);

    // Create TCP socket and connect to port 443
    const sock = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketCreateFailed;
    defer _ = posix.close(sock);

    var addr: posix.struct_sockaddr_in = std.mem.zeroes(posix.struct_sockaddr_in);
    addr.sin_family = posix.AF_INET;
    addr.sin_port = @byteSwap(@as(u16, 443));
    addr.sin_addr.s_addr = @byteSwap(api_ip);

    if (posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.struct_sockaddr_in)) < 0)
        return error.ConnectFailed;
    _ = posix.write(2, "tls: TCP connected, starting handshake\n", 39);

    // Quick test: can we read raw bytes from the socket after connect?
    // (Don't actually do this — just verify the connection is alive)
    // The server won't send anything until we send ClientHello, so skip this.

    // Allocate buffers for TLS
    const read_buf = try allocator.alloc(u8, TLS_BUFFER_SIZE);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, TLS_BUFFER_SIZE);
    defer allocator.free(write_buf);
    const tls_read_buf = try allocator.alloc(u8, TLS_BUFFER_SIZE);
    defer allocator.free(tls_read_buf);
    const tls_write_buf = try allocator.alloc(u8, TLS_BUFFER_SIZE);
    defer allocator.free(tls_write_buf);

    // Create socket-backed reader and writer for the encrypted stream
    var sock_reader = SocketReader.init(sock, read_buf);
    var sock_writer = SocketWriter.init(sock, write_buf);

    // Generate entropy for TLS handshake via Linux getrandom syscall
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    {
        var filled: usize = 0;
        while (filled < entropy.len) {
            const rc = linux.getrandom(entropy[filled..].ptr, entropy.len - filled, 0);
            // getrandom returns bytes read on success, or error encoded in upper bits
            if (rc > entropy.len) break; // error
            filled += rc;
        }
    }

    // Get current time for certificate validation via clock_gettime syscall
    const now_seconds: i64 = blk: {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) break :blk 1710000000; // fallback: ~Mar 2024
        break :blk ts.sec;
    };

    // Perform TLS handshake
    var tls_client = tls.Client.init(
        &sock_reader.interface,
        &sock_writer.interface,
        .{
            .host = .{ .explicit = API_HOST },
            .ca = .no_verification,
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
            .entropy = &entropy,
            .realtime_now = .{ .nanoseconds = @as(i96, now_seconds) * 1_000_000_000 },
            .allow_truncation_attacks = true,
        },
    ) catch |err| {
        // Log the error type for debugging
        var err_msg_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_msg_buf, "TLS handshake failed: {s}\n", .{@errorName(err)}) catch "TLS handshake failed\n";
        _ = posix.write(2, err_msg.ptr, err_msg.len);
        return error.TlsHandshakeFailed;
    };

    {
        var dbg: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&dbg, "tls: handshake OK, reader s={d} e={d}, input s={d} e={d}\n", .{
            tls_client.reader.seek, tls_client.reader.end,
            tls_client.input.seek, tls_client.input.end,
        }) catch "tls: handshake OK\n";
        _ = posix.write(2, msg.ptr, msg.len);
        // Log first bytes of any leftover input data
        const leftover = tls_client.input.buffered();
        if (leftover.len > 0 and leftover.len >= 5) {
            var lb: [80]u8 = undefined;
            const lm = std.fmt.bufPrint(&lb, "tls: input leftover={d} first=[{x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}]\n", .{
                leftover.len, leftover[0], leftover[1], leftover[2], leftover[3], leftover[4],
            }) catch "leftover?\n";
            _ = posix.write(2, lm.ptr, lm.len);
        }
    }

    // Build HTTP request
    var hdr_buf: [512]u8 = undefined;
    const http_header = std.fmt.bufPrint(&hdr_buf, "POST /v1/messages HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nx-api-key: {s}\r\nanthropic-version: 2023-06-01\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ API_HOST, api_key, request_body.len }) catch
        return error.HeaderTooLong;

    // Send HTTP request over TLS
    tls_client.writer.writeAll(http_header) catch return error.TlsWriteFailed;
    tls_client.writer.writeAll(request_body) catch return error.TlsWriteFailed;
    tls_client.writer.flush() catch return error.TlsWriteFailed;
    // CRITICAL: TLS drain encrypts into output buffer but doesn't flush it.
    // Must flush the underlying socket writer to actually send the bytes.
    sock_writer.interface.flush() catch return error.TlsWriteFailed;

    // No sleep — let the blocking read() handle waiting for data

    {
        var fb: [128]u8 = undefined;
        const fm = std.fmt.bufPrint(&fb, "tls: flushed {d}+{d} bytes, sock_written={d}\n", .{ http_header.len, request_body.len, sock_writer.total_written }) catch "tls: flushed\n";
        _ = posix.write(2, fm.ptr, fm.len);
    }

    // NOTE: Do NOT use recv(MSG_PEEK) here — Zigix doesn't implement MSG_PEEK,
    // so it consumes data, causing the TLS reader to miss the record header.

    // Read HTTP response over TLS using fillMore + buffered
    const max_response = 256 * 1024;
    var response = try allocator.alloc(u8, max_response);
    errdefer allocator.free(response);
    var total: usize = 0;

    while (total < max_response) {
        // Check if there's already decrypted data buffered
        var avail = tls_client.reader.buffered();
        if (avail.len == 0) {
            // Pull more TLS records until we get application data or hit EOF.
            // NewSessionTicket records return successfully from fillMore but
            // don't add to buffered(). Keep trying until data appears or EOF.
            var attempts: u32 = 0;
            while (attempts < 32) : (attempts += 1) {
                // Log input buffer state before fillMore
                {
                    const in_buf = tls_client.input.buffered();
                    var ib: [128]u8 = undefined;
                    const im = std.fmt.bufPrint(&ib, "tls: pre-fill#{d}: input_avail={d} input_seek={d} input_end={d}\n", .{
                        attempts, in_buf.len, tls_client.input.seek, tls_client.input.end,
                    }) catch "pre-fill?\n";
                    _ = posix.write(2, im.ptr, im.len);
                    // Log first 5 bytes of input buffer to verify record alignment
                    if (in_buf.len >= 5) {
                        var hb: [80]u8 = undefined;
                        const hm = std.fmt.bufPrint(&hb, "tls: input[0..5]=[{x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}]\n", .{
                            in_buf[0], in_buf[1], in_buf[2], in_buf[3], in_buf[4],
                        }) catch "input bytes?\n";
                        _ = posix.write(2, hm.ptr, hm.len);
                    }
                }
                tls_client.reader.fillMore() catch |err| {
                    var eb2: [128]u8 = undefined;
                    const em2 = std.fmt.bufPrint(&eb2, "tls: fill#{d} err={s} end={d} eof={}\n", .{ attempts, @errorName(err), tls_client.reader.end, tls_client.eof() }) catch "fill err\n";
                    _ = posix.write(2, em2.ptr, em2.len);
                    break;
                };
                avail = tls_client.reader.buffered();
                {
                    var db3: [64]u8 = undefined;
                    const dm3 = std.fmt.bufPrint(&db3, "tls: fill#{d} end={d} avail={d}\n", .{ attempts, tls_client.reader.end, avail.len }) catch "?\n";
                    _ = posix.write(2, dm3.ptr, dm3.len);
                }
                if (avail.len > 0) break;
            }
            // Final check — even if fillMore errored, there may be data
            if (avail.len == 0) avail = tls_client.reader.buffered();
            if (avail.len == 0) break;
        }

        const to_copy = @min(avail.len, max_response - total);
        @memcpy(response[total..][0..to_copy], avail[0..to_copy]);
        total += to_copy;
        // Advance reader past consumed data
        tls_client.reader.seek += to_copy;
    }

    // Send TLS close_notify
    tls_client.end() catch {};

    // Log how much we read
    {
        var len_buf: [64]u8 = undefined;
        const len_msg = std.fmt.bufPrint(&len_buf, "tls: read {d} bytes response\n", .{total}) catch "tls: read unknown bytes\n";
        _ = posix.write(2, len_msg.ptr, len_msg.len);
        // Log first 100 bytes for debugging
        if (total > 0) {
            const show = @min(total, 100);
            _ = posix.write(2, response.ptr, show);
            _ = posix.write(2, "\n", 1);
        }
    }

    // Find HTTP body (after \r\n\r\n)
    const body_sep = std.mem.indexOf(u8, response[0..total], "\r\n\r\n") orelse
        return error.InvalidHttpResponse;

    var body = response[body_sep + 4 .. total];

    // Handle chunked transfer encoding: strip chunk size headers
    // Chunked format: "<hex_size>\r\n<data>\r\n<hex_size>\r\n<data>\r\n0\r\n\r\n"
    // Detect chunked by checking if body starts with a hex number followed by \r\n
    if (body.len > 2 and isHexDigit(body[0])) {
        // Likely chunked — extract just the JSON
        // Find the first '{' which starts the JSON body
        if (std.mem.indexOf(u8, body, "{")) |json_start| {
            // Find the last '}' which ends the JSON
            if (std.mem.lastIndexOf(u8, body, "}")) |json_end| {
                body = body[json_start .. json_end + 1];
            }
        }
    }

    // Copy body to a properly sized allocation
    const result = try allocator.alloc(u8, body.len);
    @memcpy(result, body);
    allocator.free(response);
    return result;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
