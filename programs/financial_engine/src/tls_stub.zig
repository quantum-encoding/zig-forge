//! TLS Stub - No-op TLS client for builds without mbedTLS
//!
//! Used on Android and other platforms where mbedTLS is not available.
//! All operations return errors to indicate TLS is not supported.

const std = @import("std");
const posix = std.posix;

pub const TlsError = error{
    InitFailed,
    ConfigFailed,
    HandshakeFailed,
    CertificateError,
    ConnectionClosed,
    ReadError,
    WriteError,
    HostnameMismatch,
    TlsNotSupported,
};

/// Stub TLS client - all operations fail with TlsNotSupported
pub const TlsClient = struct {
    const Self = @This();

    connected: bool,

    pub fn init() Self {
        return .{ .connected = false };
    }

    pub fn deinit(_: *Self) void {}

    pub fn configure(_: *Self) TlsError!void {
        std.debug.print("TLS: Not supported on this platform (mbedTLS not linked)\n", .{});
        return TlsError.TlsNotSupported;
    }

    pub fn connect(_: *Self, _: []const u8, _: u16) TlsError!void {
        return TlsError.TlsNotSupported;
    }

    pub fn write(_: *Self, _: []const u8) TlsError!usize {
        return TlsError.TlsNotSupported;
    }

    pub fn read(_: *Self, _: []u8) TlsError!usize {
        return TlsError.TlsNotSupported;
    }

    pub fn close(self: *Self) void {
        self.connected = false;
    }

    pub fn getSocket(_: *Self) ?posix.socket_t {
        return null;
    }

    pub fn isConnected(self: Self) bool {
        return self.connected;
    }
};
