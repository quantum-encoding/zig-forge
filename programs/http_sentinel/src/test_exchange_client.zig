//! Test WebSocket-over-TLS connection to Coinbase
//!
//! This test verifies:
//! 1. TCP connection to Coinbase
//! 2. TLS handshake with certificate pinning
//! 3. WebSocket upgrade (RFC 6455)
//! 4. Ready for HFT operations

const std = @import("std");
const ExchangeClient = @import("execution/exchange_client.zig").ExchangeClient;
const Exchange = @import("execution/exchange_client.zig").Exchange;
const Credentials = @import("execution/exchange_client.zig").Credentials;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n🔱 WebSocket-over-TLS Integration Test 🔱\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Dummy credentials (not needed for WebSocket upgrade test)
    const credentials = Credentials{
        .api_key = "test_key",
        .api_secret = "test_secret",
    };

    std.debug.print("📦 Initializing exchange client...\n", .{});
    var client = try ExchangeClient.init(allocator, .coinbase, credentials);
    defer client.deinit();

    std.debug.print("\n🚀 Starting connection sequence...\n", .{});
    std.debug.print("   Target: wss://advanced-trade-ws.coinbase.com\n\n", .{});

    // This will perform:
    // 1. TCP connection to 104.17.17.195:443
    // 2. TLS handshake with GTS Root R4 certificate pinning
    // 3. WebSocket upgrade request (RFC 6455)
    // 4. Verify HTTP/1.1 101 Switching Protocols response
    try client.connect();

    std.debug.print("\n✅ CONNECTION COMPLETE!\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Status: Ready for HFT operations\n", .{});
    std.debug.print("Protocol: WebSocket over TLS 1.2/1.3\n", .{});
    std.debug.print("Certificate: Google Trust Services GTS Root R4 (pinned)\n", .{});
    std.debug.print("Handshake: RFC 6455 compliant\n\n", .{});

    // Clean shutdown
    std.debug.print("🧹 Closing connection...\n", .{});
}
