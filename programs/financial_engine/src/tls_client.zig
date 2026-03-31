//! TLS Client Wrapper using mbedTLS
//!
//! Provides cross-platform TLS support for:
//! - Linux (x86_64, aarch64)
//! - Android (arm64-v8a, armeabi-v7a)
//! - macOS (x86_64, arm64)
//! - Windows (x86_64)
//!
//! Build mbedTLS:
//!   git clone https://github.com/Mbed-TLS/mbedtls.git
//!   cd mbedtls && mkdir build && cd build
//!   cmake -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF ..
//!   make -j$(nproc)
//!
//! For Android, use NDK toolchain:
//!   cmake -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
//!         -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 ..

const std = @import("std");
const posix = std.posix;

// mbedTLS C imports
const c = @cImport({
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/error.h");
    @cInclude("mbedtls/x509_crt.h");
});

// =============================================================================
// Error Types
// =============================================================================

pub const TlsError = error{
    InitFailed,
    ConfigFailed,
    HandshakeFailed,
    CertificateError,
    ConnectionClosed,
    ReadError,
    WriteError,
    HostnameMismatch,
};

// =============================================================================
// TLS Client
// =============================================================================

/// TLS client wrapper around mbedTLS
pub const TlsClient = struct {
    const Self = @This();

    // mbedTLS contexts
    ssl: c.mbedtls_ssl_context,
    conf: c.mbedtls_ssl_config,
    cacert: c.mbedtls_x509_crt,
    ctr_drbg: c.mbedtls_ctr_drbg_context,
    entropy: c.mbedtls_entropy_context,
    server_fd: c.mbedtls_net_context,

    // State
    connected: bool,
    hostname: [256]u8,
    hostname_len: usize,

    /// Initialize TLS client
    pub fn init() Self {
        var self: Self = undefined;

        // Initialize all contexts
        c.mbedtls_ssl_init(&self.ssl);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_x509_crt_init(&self.cacert);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_entropy_init(&self.entropy);
        c.mbedtls_net_init(&self.server_fd);

        self.connected = false;
        self.hostname = undefined;
        self.hostname_len = 0;

        return self;
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *Self) void {
        if (self.connected) {
            self.close();
        }

        c.mbedtls_ssl_free(&self.ssl);
        c.mbedtls_ssl_config_free(&self.conf);
        c.mbedtls_x509_crt_free(&self.cacert);
        c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
        c.mbedtls_entropy_free(&self.entropy);
        c.mbedtls_net_free(&self.server_fd);
    }

    /// Configure TLS with system CA certificates
    pub fn configure(self: *Self) TlsError!void {
        // Seed the random number generator
        const pers = "fix_tls_client";
        var ret = c.mbedtls_ctr_drbg_seed(
            &self.ctr_drbg,
            c.mbedtls_entropy_func,
            &self.entropy,
            pers,
            pers.len,
        );
        if (ret != 0) {
            logMbedError("ctr_drbg_seed", ret);
            return TlsError.InitFailed;
        }

        // Load system CA certificates
        // Try common paths for different platforms
        const ca_paths = [_][:0]const u8{
            "/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu
            "/etc/pki/tls/certs/ca-bundle.crt", // RHEL/CentOS
            "/etc/ssl/cert.pem", // macOS/FreeBSD
            "/system/etc/security/cacerts", // Android (directory)
            "/data/misc/keychain/cacerts-added", // Android (user)
        };

        var loaded = false;
        for (ca_paths) |path| {
            ret = c.mbedtls_x509_crt_parse_file(&self.cacert, path);
            if (ret >= 0) {
                loaded = true;
                break;
            }
        }

        // If no system certs found, try to use built-in Mozilla roots
        // (would need to embed them or use mbedtls_x509_crt_parse for PEM data)
        if (!loaded) {
            std.debug.print("TLS: Warning - no system CA certificates found\n", .{});
            // Continue anyway - will fail on cert verification
        }

        // Setup SSL config
        ret = c.mbedtls_ssl_config_defaults(
            &self.conf,
            c.MBEDTLS_SSL_IS_CLIENT,
            c.MBEDTLS_SSL_TRANSPORT_STREAM,
            c.MBEDTLS_SSL_PRESET_DEFAULT,
        );
        if (ret != 0) {
            logMbedError("ssl_config_defaults", ret);
            return TlsError.ConfigFailed;
        }

        // Set certificate verification mode
        c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
        c.mbedtls_ssl_conf_ca_chain(&self.conf, &self.cacert, null);
        c.mbedtls_ssl_conf_rng(&self.conf, c.mbedtls_ctr_drbg_random, &self.ctr_drbg);

        // Setup SSL context
        ret = c.mbedtls_ssl_setup(&self.ssl, &self.conf);
        if (ret != 0) {
            logMbedError("ssl_setup", ret);
            return TlsError.ConfigFailed;
        }
    }

    /// Connect to a TLS server
    pub fn connect(self: *Self, host: []const u8, port: u16) TlsError!void {
        // Store hostname for SNI
        if (host.len >= self.hostname.len) {
            return TlsError.ConfigFailed;
        }
        @memcpy(self.hostname[0..host.len], host);
        self.hostname[host.len] = 0;
        self.hostname_len = host.len;

        // Set hostname for SNI and certificate verification
        var ret = c.mbedtls_ssl_set_hostname(&self.ssl, &self.hostname);
        if (ret != 0) {
            logMbedError("ssl_set_hostname", ret);
            return TlsError.ConfigFailed;
        }

        // Connect TCP
        var port_str: [8]u8 = undefined;
        const port_slice = std.fmt.bufPrint(&port_str, "{d}", .{port}) catch return TlsError.ConfigFailed;
        port_str[port_slice.len] = 0;

        ret = c.mbedtls_net_connect(&self.server_fd, &self.hostname, &port_str, c.MBEDTLS_NET_PROTO_TCP);
        if (ret != 0) {
            logMbedError("net_connect", ret);
            return TlsError.HandshakeFailed;
        }

        // Set up I/O callbacks
        c.mbedtls_ssl_set_bio(&self.ssl, &self.server_fd, c.mbedtls_net_send, c.mbedtls_net_recv, null);

        // Perform TLS handshake
        while (true) {
            ret = c.mbedtls_ssl_handshake(&self.ssl);
            if (ret == 0) break;
            if (ret != c.MBEDTLS_ERR_SSL_WANT_READ and ret != c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                logMbedError("ssl_handshake", ret);

                // Check certificate verification result
                const flags = c.mbedtls_ssl_get_verify_result(&self.ssl);
                if (flags != 0) {
                    std.debug.print("TLS: Certificate verification failed: 0x{x}\n", .{flags});
                    return TlsError.CertificateError;
                }

                return TlsError.HandshakeFailed;
            }
        }

        self.connected = true;
        std.debug.print("TLS: Connected to {s}:{d} ({s})\n", .{
            host,
            port,
            std.mem.sliceTo(c.mbedtls_ssl_get_ciphersuite(&self.ssl), 0),
        });
    }

    /// Write data over TLS
    pub fn write(self: *Self, data: []const u8) TlsError!usize {
        if (!self.connected) return TlsError.ConnectionClosed;

        var total_written: usize = 0;
        while (total_written < data.len) {
            const ret = c.mbedtls_ssl_write(&self.ssl, data.ptr + total_written, data.len - total_written);
            if (ret < 0) {
                if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                    continue;
                }
                logMbedError("ssl_write", @intCast(ret));
                return TlsError.WriteError;
            }
            total_written += @intCast(ret);
        }
        return total_written;
    }

    /// Read data over TLS
    pub fn read(self: *Self, buffer: []u8) TlsError!usize {
        if (!self.connected) return TlsError.ConnectionClosed;

        while (true) {
            const ret = c.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);
            if (ret > 0) {
                return @intCast(ret);
            }
            if (ret == 0) {
                self.connected = false;
                return TlsError.ConnectionClosed;
            }
            if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                continue;
            }
            logMbedError("ssl_read", @intCast(ret));
            return TlsError.ReadError;
        }
    }

    /// Close TLS connection
    pub fn close(self: *Self) void {
        if (self.connected) {
            // Send close_notify
            _ = c.mbedtls_ssl_close_notify(&self.ssl);
            self.connected = false;
        }
        c.mbedtls_net_free(&self.server_fd);
    }

    /// Get underlying socket for polling
    pub fn getSocket(self: *Self) ?posix.socket_t {
        if (!self.connected) return null;
        return @intCast(self.server_fd.fd);
    }

    /// Check if connected
    pub fn isConnected(self: Self) bool {
        return self.connected;
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn logMbedError(context: []const u8, err: c_int) void {
    var buf: [256]u8 = undefined;
    c.mbedtls_strerror(err, &buf, buf.len);
    std.debug.print("TLS Error ({s}): {s} (code: {d})\n", .{
        context,
        std.mem.sliceTo(&buf, 0),
        err,
    });
}

// =============================================================================
// Tests
// =============================================================================

test "tls client init/deinit" {
    var client = TlsClient.init();
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
}

// =============================================================================
// Platform-specific CA certificate paths
// =============================================================================

/// Get the system CA certificate path for the current platform
pub fn getSystemCaPath() ?[]const u8 {
    const builtin = @import("builtin");

    return switch (builtin.os.tag) {
        .linux => "/etc/ssl/certs/ca-certificates.crt",
        .macos => "/etc/ssl/cert.pem",
        .windows => null, // Windows uses CryptoAPI, not file-based certs
        else => null,
    };
}

/// Check if running on Android
pub fn isAndroid() bool {
    const builtin = @import("builtin");
    return builtin.os.tag == .linux and builtin.abi == .android;
}
