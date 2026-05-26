//! TLS 1.2/1.3 Client using mbedTLS
//! Production-grade TLS for HFT WebSocket connections
//!
//! mbedTLS is chosen for:
//! - Full TLS 1.3 support
//! - Proven track record (used in millions of devices)
//! - Flexible certificate handling
//! - Low latency overhead
//! - Active development and security updates

const std = @import("std");
const posix = std.posix;

/// mbedTLS C bindings
const c = @cImport({
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/error.h");
    @cInclude("mbedtls/x509_crt.h");
});

/// Candidate paths for the system CA bundle, probed in order. The first
/// path that mbedtls can parse a non-empty chain from is used.
///   - /etc/ssl/cert.pem ......... macOS (Homebrew openssl@3 / LibreSSL), Alpine
///   - /etc/ssl/certs/ca-certificates.crt ... Debian / Ubuntu
///   - /etc/pki/tls/certs/ca-bundle.crt ..... RHEL / CentOS / Fedora
///   - /etc/ssl/certs/ca-bundle.crt ......... older RHEL clones
const system_ca_bundle_candidates = [_][]const u8{
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/certs/ca-bundle.crt",
};

/// Load the system CA bundle into `cacert`. Returns the path that was
/// loaded so callers can log it. If no candidate path is parseable we
/// return error.NoSystemCaBundle — the caller MUST fail open here
/// instead of falling back to VERIFY_NONE; "MitM-resistant" without a
/// trust anchor is not a thing.
fn loadSystemCaChain(cacert: *c.mbedtls_x509_crt) ![]const u8 {
    for (system_ca_bundle_candidates) |path| {
        const path_z = std.posix.toPosixPath(path) catch continue;
        const ret = c.mbedtls_x509_crt_parse_file(cacert, &path_z);
        // mbedtls returns negative on hard failure, 0 on success, and a
        // positive integer = "number of certificates that failed to
        // parse" but the rest of the chain is usable. We accept 0 or a
        // positive result so long as something parsed.
        if (ret == 0) return path;
        // Reset state so a partial parse doesn't poison the next attempt.
        c.mbedtls_x509_crt_free(cacert);
        c.mbedtls_x509_crt_init(cacert);
    }
    return error.NoSystemCaBundle;
}

/// TLS connection state
pub const TlsClient = struct {
    /// mbedTLS network context
    server_fd: c.mbedtls_net_context,

    /// mbedTLS SSL context
    ssl: c.mbedtls_ssl_context,

    /// mbedTLS SSL configuration
    conf: c.mbedtls_ssl_config,

    /// mbedTLS entropy context (for RNG)
    entropy: c.mbedtls_entropy_context,

    /// mbedTLS CTR_DRBG context (deterministic RNG)
    ctr_drbg: c.mbedtls_ctr_drbg_context,

    /// Trust anchors loaded from the system CA bundle. Borrowed by `conf`
    /// via mbedtls_ssl_conf_ca_chain — must outlive any handshake on this
    /// client.
    cacert: c.mbedtls_x509_crt,

    /// Connection state
    connected: bool,
    handshake_done: bool,

    const Self = @This();

    /// Initialize TLS client. Loads the system trust store and configures
    /// the SSL context for MBEDTLS_SSL_VERIFY_REQUIRED. There is no
    /// "VERIFY_NONE for latency" mode — silently-MitM-able connections are
    /// not faster, they are just compromised. If you need a custom trust
    /// store (e.g. a pinned cert for a specific exchange), build a
    /// separate client.
    pub fn init(allocator: std.mem.Allocator, sockfd: posix.socket_t) !Self {
        _ = allocator; // Reserved for future use

        var self = Self{
            .server_fd = undefined,
            .ssl = undefined,
            .conf = undefined,
            .entropy = undefined,
            .ctr_drbg = undefined,
            .cacert = undefined,
            .connected = false,
            .handshake_done = false,
        };

        // Initialize contexts
        c.mbedtls_net_init(&self.server_fd);
        c.mbedtls_ssl_init(&self.ssl);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_entropy_init(&self.entropy);
        c.mbedtls_x509_crt_init(&self.cacert);

        // Seed RNG
        const pers = "hft_ssl_client";
        const ret = c.mbedtls_ctr_drbg_seed(
            &self.ctr_drbg,
            c.mbedtls_entropy_func,
            &self.entropy,
            pers.ptr,
            pers.len,
        );
        if (ret != 0) {
            return error.RngSeedFailed;
        }

        // Load the system CA bundle. Without this, VERIFY_REQUIRED would
        // reject every handshake.
        _ = loadSystemCaChain(&self.cacert) catch |err| {
            c.mbedtls_x509_crt_free(&self.cacert);
            c.mbedtls_entropy_free(&self.entropy);
            c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
            c.mbedtls_ssl_config_free(&self.conf);
            c.mbedtls_ssl_free(&self.ssl);
            c.mbedtls_net_free(&self.server_fd);
            return err;
        };

        // Set socket FD
        self.server_fd.fd = sockfd;

        return self;
    }

    /// Perform TLS handshake
    ///
    /// This negotiates TLS 1.3 (or falls back to TLS 1.2) with the server.
    /// Call this ONCE at startup, not in the hot path!
    pub fn connect(self: *Self, hostname: []const u8) !void {
        // Setup SSL configuration
        var ret = c.mbedtls_ssl_config_defaults(
            &self.conf,
            c.MBEDTLS_SSL_IS_CLIENT,
            c.MBEDTLS_SSL_TRANSPORT_STREAM,
            c.MBEDTLS_SSL_PRESET_DEFAULT,
        );
        if (ret != 0) {
            std.debug.print("mbedtls_ssl_config_defaults failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
            return error.SslConfigFailed;
        }

        // Require full certificate chain validation. The mbedtls
        // handshake will call x509_crt_verify against `cacert` (loaded
        // from the system bundle in init) and abort if the server's
        // cert doesn't chain to a trusted root, has expired, or is
        // signed for a different name (mbedtls_ssl_set_hostname below
        // pins the expected CN/SAN).
        c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
        c.mbedtls_ssl_conf_ca_chain(&self.conf, &self.cacert, null);
        c.mbedtls_ssl_conf_rng(&self.conf, c.mbedtls_ctr_drbg_random, &self.ctr_drbg);

        ret = c.mbedtls_ssl_setup(&self.ssl, &self.conf);
        if (ret != 0) {
            std.debug.print("mbedtls_ssl_setup failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
            return error.SslSetupFailed;
        }

        // Set SNI hostname
        const hostname_z = try std.posix.toPosixPath(hostname);
        ret = c.mbedtls_ssl_set_hostname(&self.ssl, &hostname_z);
        if (ret != 0) {
            std.debug.print("mbedtls_ssl_set_hostname failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
            return error.SslSetHostnameFailed;
        }

        // Set I/O callbacks
        c.mbedtls_ssl_set_bio(
            &self.ssl,
            &self.server_fd,
            c.mbedtls_net_send,
            c.mbedtls_net_recv,
            null,
        );

        self.connected = true;

        // Perform handshake
        std.debug.print("🔐 Performing TLS handshake...\n", .{});
        while (true) {
            ret = c.mbedtls_ssl_handshake(&self.ssl);
            if (ret == 0) {
                break;
            }
            if (ret != c.MBEDTLS_ERR_SSL_WANT_READ and ret != c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                std.debug.print("mbedtls_ssl_handshake failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
                return error.TlsHandshakeFailed;
            }
        }

        self.handshake_done = true;

        // Print connection info
        const version = c.mbedtls_ssl_get_version(&self.ssl);
        const ciphersuite = c.mbedtls_ssl_get_ciphersuite(&self.ssl);
        std.debug.print("✅ TLS handshake complete\n", .{});
        std.debug.print("   Protocol: {s}\n", .{version});
        std.debug.print("   Ciphersuite: {s}\n\n", .{ciphersuite});
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
            const ret = c.mbedtls_ssl_write(&self.ssl, remaining.ptr, remaining.len);

            if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                continue; // Retry
            }

            if (ret < 0) {
                std.debug.print("mbedtls_ssl_write failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
                return error.SendFailed;
            }

            const sent: usize = @intCast(ret);
            total_sent += sent;
            remaining = remaining[sent..];
        }

        return total_sent;
    }

    /// Receive application data (decrypts automatically)
    pub fn recv(self: *Self, buffer: []u8) !usize {
        if (!self.handshake_done) return error.NotConnected;

        const ret = c.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);

        if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
            return error.WouldBlock;
        }

        if (ret == c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
            return error.ConnectionClosed;
        }

        if (ret < 0) {
            std.debug.print("mbedtls_ssl_read failed: -0x{x:0>4}\n", .{@as(u32, @intCast(-ret))});
            return error.RecvFailed;
        }

        return @intCast(ret);
    }

    /// Close TLS connection gracefully
    pub fn close(self: *Self) void {
        if (self.connected) {
            _ = c.mbedtls_ssl_close_notify(&self.ssl);
            c.mbedtls_net_free(&self.server_fd);
            c.mbedtls_ssl_free(&self.ssl);
            c.mbedtls_ssl_config_free(&self.conf);
            c.mbedtls_x509_crt_free(&self.cacert);
            c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
            c.mbedtls_entropy_free(&self.entropy);
            self.connected = false;
            self.handshake_done = false;
        }
    }

    /// Get last TLS error (for debugging)
    pub fn getLastError(self: *Self) i32 {
        _ = self;
        return 0; // TODO: Implement error tracking if needed
    }
};

// Tests
test "TLS client initialization loads system CA chain" {
    const allocator = std.testing.allocator;

    // Create dummy socket via libc. std.posix.socket is not exposed on
    // macOS under Zig 0.16 — the libc path is the portable choice.
    const sockfd: c_int = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (sockfd < 0) return error.SocketFailed;
    defer _ = std.c.close(sockfd);

    var tls = try TlsClient.init(allocator, sockfd);
    defer tls.close();

    // The init path must have successfully loaded a CA chain from the
    // system bundle — otherwise loadSystemCaChain would have returned
    // error.NoSystemCaBundle and init would have propagated it. Reaching
    // this point is proof the trust store is populated.
    try std.testing.expect(!tls.handshake_done);
    try std.testing.expect(!tls.connected);
}
