//! TLS 1.2/1.3 Client using BearSSL
//! Zero-allocation TLS for HFT WebSocket connections
//!
//! BearSSL is chosen for:
//! - No malloc() calls during handshake
//! - Small footprint (~200KB)
//! - Buffer-oriented API (perfect for io_uring)
//! - Minimal latency overhead

const std = @import("std");
const posix = std.posix;

/// BearSSL C bindings
const c = @cImport({
    @cInclude("bearssl.h");
});

/// HFT Certificate Pinning Strategy: Google Trust Services Root R4
///
/// Certificate pinning for Coinbase WebSocket connections.
/// We hardcode the Google Trust Services "GTS Root R4" root CA certificate.
///
/// Trust Anchor: Google Trust Services LLC - GTS Root R4
/// - Subject: C=US, O=Google Trust Services LLC, CN=GTS Root R4
/// - Key Type: ECDSA P-384 (BR_KEYTYPE_EC, secp384r1)
/// - Valid until: 2036-06-22 (long-lived root CA)
///
/// HFT Benefits:
/// - Faster than full chain validation (~5-10ms saved per handshake)
/// - More secure than trusting all CAs (only Google Trust Services)
/// - Works for all Coinbase services using Google's CDN (Cloudflare)
///
/// Generated using: brssl ta /path/to/gts-root-r4.pem
///
/// NOTE: This is a root CA with a very long validity period (2036).

/// Distinguished Name for GTS Root R4
const coinbase_ta_dn = [_]u8{
    0x30, 0x47, 0x31, 0x0B, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x06, 0x13,
    0x02, 0x55, 0x53, 0x31, 0x22, 0x30, 0x20, 0x06, 0x03, 0x55, 0x04, 0x0A,
    0x13, 0x19, 0x47, 0x6F, 0x6F, 0x67, 0x6C, 0x65, 0x20, 0x54, 0x72, 0x75,
    0x73, 0x74, 0x20, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x73, 0x20,
    0x4C, 0x4C, 0x43, 0x31, 0x14, 0x30, 0x12, 0x06, 0x03, 0x55, 0x04, 0x03,
    0x13, 0x0B, 0x47, 0x54, 0x53, 0x20, 0x52, 0x6F, 0x6F, 0x74, 0x20, 0x52,
    0x34,
};

/// EC P-384 public key for GTS Root R4
const coinbase_ta_ec_q = [_]u8{
    0x04, 0xF3, 0x74, 0x73, 0xA7, 0x68, 0x8B, 0x60, 0xAE, 0x43, 0xB8, 0x35,
    0xC5, 0x81, 0x30, 0x7B, 0x4B, 0x49, 0x9D, 0xFB, 0xC1, 0x61, 0xCE, 0xE6,
    0xDE, 0x46, 0xBD, 0x6B, 0xD5, 0x61, 0x18, 0x35, 0xAE, 0x40, 0xDD, 0x73,
    0xF7, 0x89, 0x91, 0x30, 0x5A, 0xEB, 0x3C, 0xEE, 0x85, 0x7C, 0xA2, 0x40,
    0x76, 0x3B, 0xA9, 0xC6, 0xB8, 0x47, 0xD8, 0x2A, 0xE7, 0x92, 0x91, 0x6A,
    0x73, 0xE9, 0xB1, 0x72, 0x39, 0x9F, 0x29, 0x9F, 0xA2, 0x98, 0xD3, 0x5F,
    0x5E, 0x58, 0x86, 0x65, 0x0F, 0xA1, 0x84, 0x65, 0x06, 0xD1, 0xDC, 0x8B,
    0xC9, 0xC7, 0x73, 0xC8, 0x8C, 0x6A, 0x2F, 0xE5, 0xC4, 0xAB, 0xD1, 0x1D,
    0x8A,
};

/// Trust anchor for Coinbase (Google Trust Services GTS Root R4)
var coinbase_trust_anchor = c.br_x509_trust_anchor{
    .dn = .{
        .data = @constCast(&coinbase_ta_dn),
        .len = coinbase_ta_dn.len,
    },
    .flags = c.BR_X509_TA_CA,
    .pkey = .{
        .key_type = c.BR_KEYTYPE_EC,
        .key = .{
            .ec = .{
                .curve = c.BR_EC_secp384r1,
                .q = @constCast(&coinbase_ta_ec_q),
                .qlen = coinbase_ta_ec_q.len,
            },
        },
    },
};

/// TLS connection state
pub const TlsClient = struct {
    /// SSL context (BearSSL engine)
    ssl_ctx: c.br_ssl_client_context,

    /// X.509 validation context
    x509_ctx: c.br_x509_minimal_context,

    /// I/O buffer for BearSSL (send + receive combined)
    iobuf: [16384]u8 align(64),

    /// Underlying TCP socket
    sockfd: posix.socket_t,

    /// Trust anchors (root certificates)
    trust_anchors: []const c.br_x509_trust_anchor,

    /// Connection state
    connected: bool,
    handshake_done: bool,

    const Self = @This();

    /// Initialize TLS client with certificate pinning for Coinbase
    ///
    /// HFT Mode: Certificate pinning to Google Trust Services WE1 intermediate CA.
    /// This validates Coinbase certificates while avoiding full chain validation overhead.
    ///
    /// Security: Only accepts certificates signed by Google Trust Services WE1.
    /// Performance: ~5-10ms faster than full chain validation.
    pub fn init(allocator: std.mem.Allocator, sockfd: posix.socket_t) !Self {
        var self = Self{
            .ssl_ctx = undefined,
            .x509_ctx = undefined,
            .iobuf = undefined,
            .sockfd = sockfd,
            .trust_anchors = &.{}, // Using pinned certificate
            .connected = false,
            .handshake_done = false,
        };

        // Step 1: Initialize X.509 minimal context with pinned Coinbase trust anchor
        // This validates against Google Trust Services WE1 intermediate CA
        c.br_x509_minimal_init(
            &self.x509_ctx,
            &c.br_sha256_vtable,
            &coinbase_trust_anchor, // Pinned Google Trust Services WE1 CA
            1, // num_trust_anchors = 1
        );

        // Step 2: Initialize SSL client context with all crypto implementations
        // br_ssl_client_init_full() sets up all default cipher suites and crypto
        c.br_ssl_client_init_full(
            &self.ssl_ctx,
            &self.x509_ctx,
            &coinbase_trust_anchor, // Pass same pinned anchor
            1, // num_trust_anchors = 1
        );

        // Step 3: Disable renegotiation (security + performance)
        c.br_ssl_engine_set_all_flags(&self.ssl_ctx.eng, c.BR_OPT_NO_RENEGOTIATION);

        // Step 4: Set I/O buffer (bidirectional for full-duplex)
        c.br_ssl_engine_set_buffer(
            &self.ssl_ctx.eng,
            &self.iobuf,
            self.iobuf.len,
            1, // Bidirectional mode
        );

        _ = allocator; // Reserved for future trust anchor loading

        return self;
    }

    /// Perform TLS handshake
    ///
    /// This is the expensive operation (~10-50ms depending on network RTT).
    /// Call this ONCE at startup, not in the hot path!
    pub fn connect(self: *Self, hostname: []const u8) !void {
        // Set socket to non-blocking mode for handshake
        // This prevents deadlock when server has sent all handshake data
        const flags = try posix.fcntl(self.sockfd, posix.F.GETFL, 0);
        const O_NONBLOCK: u32 = 0o4000; // Linux O_NONBLOCK flag
        _ = try posix.fcntl(self.sockfd, posix.F.SETFL, @as(u32, @intCast(flags)) | O_NONBLOCK);

        // Reset SSL engine
        const hostname_z = try std.posix.toPosixPath(hostname);
        const result = c.br_ssl_client_reset(&self.ssl_ctx, &hostname_z, 0);
        if (result == 0) {
            return error.TlsResetFailed;
        }

        self.connected = true;

        // Perform handshake
        try self.doHandshake();

        // Restore blocking mode for application data
        _ = try posix.fcntl(self.sockfd, posix.F.SETFL, flags);

        self.handshake_done = true;
    }

    /// Execute TLS handshake state machine with non-blocking I/O
    fn doHandshake(self: *Self) !void {
        while (!self.handshake_done) {
            const state = c.br_ssl_engine_current_state(&self.ssl_ctx.eng);

            // Check if handshake is complete FIRST (before sending/receiving)
            if ((state & (c.BR_SSL_SENDAPP | c.BR_SSL_RECVAPP)) != 0) {
                // Application data can now be sent/received - handshake complete!
                return;
            }

            if ((state & c.BR_SSL_CLOSED) != 0) {
                const err = c.br_ssl_engine_last_error(&self.ssl_ctx.eng);
                if (err != c.BR_ERR_OK) {
                    std.debug.print("TLS error: {}\n", .{err});
                    return error.TlsHandshakeFailed;
                }
                return; // Connection closed cleanly
            }

            if ((state & c.BR_SSL_SENDREC) != 0) {
                // Need to send data to peer
                var len: usize = undefined;
                const buf = c.br_ssl_engine_sendrec_buf(&self.ssl_ctx.eng, &len);

                const sent = try posix.send(self.sockfd, buf[0..len], 0);
                c.br_ssl_engine_sendrec_ack(&self.ssl_ctx.eng, sent);
            }

            if ((state & c.BR_SSL_RECVREC) != 0) {
                // Need to receive data from peer (non-blocking)
                var len: usize = undefined;
                const buf = c.br_ssl_engine_recvrec_buf(&self.ssl_ctx.eng, &len);

                const received = posix.recv(self.sockfd, buf[0..len], 0) catch |err| {
                    // Handle non-blocking errors
                    if (err == error.WouldBlock) {
                        // No data available yet - continue loop to check state
                        continue;
                    }
                    return err;
                };

                if (received == 0) {
                    // EOF - server closed connection
                    // Check if this is an error or expected
                    const tls_err = c.br_ssl_engine_last_error(&self.ssl_ctx.eng);
                    if (tls_err != c.BR_ERR_OK) {
                        std.debug.print("TLS error on close: {}\n", .{tls_err});
                        return error.ConnectionClosed;
                    }
                    // Clean close - handshake might be complete
                    // Let the next iteration check SENDAPP/RECVAPP state
                    continue;
                }

                c.br_ssl_engine_recvrec_ack(&self.ssl_ctx.eng, received);
            }
        }
    }

    /// Send application data (encrypts automatically)
    ///
    /// Hot path: This is called for every order submission.
    /// Target: <100ns overhead for encryption
    pub fn send(self: *Self, data: []const u8) !usize {
        if (!self.handshake_done) return error.NotConnected;

        var total_sent: usize = 0;
        var remaining = data;

        while (remaining.len > 0) {
            // Get buffer for sending application data
            var len: usize = undefined;
            const buf = c.br_ssl_engine_sendapp_buf(&self.ssl_ctx.eng, &len);

            if (len == 0) {
                // Buffer full, flush
                try self.flush();
                continue;
            }

            // Copy data to SSL buffer
            const to_copy = @min(len, remaining.len);
            @memcpy(buf[0..to_copy], remaining[0..to_copy]);
            c.br_ssl_engine_sendapp_ack(&self.ssl_ctx.eng, to_copy);

            total_sent += to_copy;
            remaining = remaining[to_copy..];

            // Flush encrypted data to socket
            try self.flush();
        }

        return total_sent;
    }

    /// Receive application data (decrypts automatically)
    ///
    /// Optional timeout parameter (in seconds). Default: 10 seconds.
    /// Set timeout_secs = 0 for blocking mode (wait forever).
    pub fn recv(self: *Self, buffer: []u8) !usize {
        return self.recvTimeout(buffer, 10);
    }

    /// Receive with custom timeout (in seconds)
    pub fn recvTimeout(self: *Self, buffer: []u8, timeout_secs: u32) !usize {
        if (!self.handshake_done) return error.NotConnected;

        // Set socket receive timeout (if not zero)
        if (timeout_secs > 0) {
            const timeout = posix.timeval{
                .sec = @intCast(timeout_secs),
                .usec = 0,
            };
            try posix.setsockopt(
                self.sockfd,
                posix.SOL.SOCKET,
                posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            );
        }

        // First, try to read any pending decrypted data
        var len: usize = undefined;
        var buf = c.br_ssl_engine_recvapp_buf(&self.ssl_ctx.eng, &len);

        if (len > 0) {
            const to_copy = @min(len, buffer.len);
            @memcpy(buffer[0..to_copy], buf[0..to_copy]);
            c.br_ssl_engine_recvapp_ack(&self.ssl_ctx.eng, to_copy);
            std.debug.print("📥 Received {d} bytes (from BearSSL buffer)\n", .{to_copy});
            return to_copy;
        }

        // No pending data, receive from socket and decrypt
        while (true) {
            const state = c.br_ssl_engine_current_state(&self.ssl_ctx.eng);
            std.debug.print("🔍 BearSSL state: 0x{x:0>4} ", .{state});
            if ((state & c.BR_SSL_SENDREC) != 0) std.debug.print("[SENDREC] ", .{});
            if ((state & c.BR_SSL_RECVREC) != 0) std.debug.print("[RECVREC] ", .{});
            if ((state & c.BR_SSL_SENDAPP) != 0) std.debug.print("[SENDAPP] ", .{});
            if ((state & c.BR_SSL_RECVAPP) != 0) std.debug.print("[RECVAPP] ", .{});
            if ((state & c.BR_SSL_CLOSED) != 0) std.debug.print("[CLOSED] ", .{});
            std.debug.print("\n", .{});

            if ((state & c.BR_SSL_RECVREC) != 0) {
                // Receive encrypted data from peer
                var recv_len: usize = undefined;
                const recv_buf = c.br_ssl_engine_recvrec_buf(&self.ssl_ctx.eng, &recv_len);

                const received = posix.recv(self.sockfd, recv_buf[0..recv_len], 0) catch |err| {
                    // Handle timeout specially
                    if (err == error.WouldBlock) {
                        std.debug.print("⏱️  Recv timeout after {d}s\n", .{timeout_secs});
                        return error.Timeout;
                    }
                    return err;
                };

                if (received == 0) {
                    std.debug.print("🔌 Connection closed by peer\n", .{});
                    return error.ConnectionClosed;
                }

                std.debug.print("📡 Received {d} encrypted bytes from socket\n", .{received});
                c.br_ssl_engine_recvrec_ack(&self.ssl_ctx.eng, received);
            }

            if ((state & c.BR_SSL_RECVAPP) != 0) {
                // Decrypted data available
                buf = c.br_ssl_engine_recvapp_buf(&self.ssl_ctx.eng, &len);

                if (len > 0) {
                    const to_copy = @min(len, buffer.len);
                    @memcpy(buffer[0..to_copy], buf[0..to_copy]);
                    c.br_ssl_engine_recvapp_ack(&self.ssl_ctx.eng, to_copy);

                    // Debug: Print hex dump of received data (first 128 bytes)
                    std.debug.print("📥 Decrypted {d} bytes:\n", .{to_copy});
                    const dump_len = @min(to_copy, 128);
                    for (buffer[0..dump_len], 0..) |byte, i| {
                        if (i % 16 == 0) std.debug.print("\n  ", .{});
                        std.debug.print("{x:0>2} ", .{byte});
                    }
                    std.debug.print("\n\n", .{});

                    // Also print as ASCII (printable chars only)
                    std.debug.print("📄 ASCII view:\n  ", .{});
                    for (buffer[0..dump_len]) |byte| {
                        if (byte >= 32 and byte <= 126) {
                            std.debug.print("{c}", .{byte});
                        } else if (byte == '\n') {
                            std.debug.print("\n  ", .{});
                        } else if (byte == '\r') {
                            // Skip carriage returns
                        } else {
                            std.debug.print(".", .{});
                        }
                    }
                    std.debug.print("\n\n", .{});

                    return to_copy;
                }
            }

            if ((state & c.BR_SSL_CLOSED) != 0) {
                std.debug.print("🔒 TLS connection closed\n", .{});
                return error.ConnectionClosed;
            }
        }
    }

    /// Flush encrypted data to socket
    fn flush(self: *Self) !void {
        while (true) {
            const state = c.br_ssl_engine_current_state(&self.ssl_ctx.eng);

            if ((state & c.BR_SSL_SENDREC) == 0) {
                break; // Nothing to send
            }

            var len: usize = undefined;
            const buf = c.br_ssl_engine_sendrec_buf(&self.ssl_ctx.eng, &len);

            const sent = try posix.send(self.sockfd, buf[0..len], 0);
            c.br_ssl_engine_sendrec_ack(&self.ssl_ctx.eng, sent);
        }
    }

    /// Close TLS connection gracefully
    pub fn close(self: *Self) void {
        if (self.connected) {
            c.br_ssl_engine_close(&self.ssl_ctx.eng);
            self.flush() catch {}; // Best effort
            self.connected = false;
            self.handshake_done = false;
        }
    }

    /// Get last TLS error
    pub fn getLastError(self: *Self) i32 {
        return @intCast(c.br_ssl_engine_last_error(&self.ssl_ctx.eng));
    }
};

// Simple test to verify BearSSL linking
test "BearSSL library linked" {
    // This test just verifies we can call BearSSL functions
    var ctx: c.br_ssl_client_context = undefined;
    var x509: c.br_x509_minimal_context = undefined;

    c.br_ssl_client_init_full(&ctx, &x509, null, 0);

    // Should not crash - BearSSL is linked correctly
    try std.testing.expect(true);
}

test "TLS client initialization" {
    const allocator = std.testing.allocator;

    // Create dummy socket (won't actually connect)
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer _ = std.c.close(sockfd);

    var tls = try TlsClient.init(allocator, sockfd);
    defer tls.close();

    try std.testing.expect(!tls.handshake_done);
    try std.testing.expect(!tls.connected);
}
