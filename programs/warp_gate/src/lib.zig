//! ═══════════════════════════════════════════════════════════════════════════
//! WARP GATE - Peer-to-Peer Code Transfer
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Direct laptop-to-laptop file transfer without cloud intermediaries.
//!
//! Features:
//! • One-time transfer codes (e.g., warp-729-alpha)
//! • NAT traversal via STUN + UDP hole punching
//! • Local network discovery via mDNS
//! • ChaCha20-Poly1305 encryption (no TLS overhead)
//! • Zero-copy streaming with io_uring
//! • Resume support for interrupted transfers
//!
//! Protocol flow:
//! 1. Sender generates transfer code from random bytes
//! 2. Both peers discover public IP:port via STUN
//! 3. Peers exchange endpoints through mDNS (local) or signaling (remote)
//! 4. UDP hole punching establishes direct connection
//! 5. Encrypted file stream with integrity verification

pub const crypto = @import("crypto/chacha.zig");
pub const network = @import("network/transport.zig");
pub const protocol = @import("protocol/wire.zig");
pub const discovery = @import("discovery/resolver.zig");
pub const warp_code = @import("protocol/warp_code.zig");

// Re-exports for convenience
pub const WarpCode = warp_code.WarpCode;
pub const Transport = network.Transport;
pub const FileStream = protocol.FileStream;
pub const Resolver = discovery.Resolver;

/// Warp Gate session for file transfer
pub const WarpSession = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    code: WarpCode,
    transport: ?Transport = null,
    resolver: Resolver,
    state: State = .idle,
    encryption_key: [32]u8 = undefined,

    pub const State = enum {
        idle,
        discovering,
        connecting,
        connected,
        handshaking,
        transferring,
        completed,
        failed,
    };

    pub const Role = enum {
        sender,
        receiver,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, role: Role) !Self {
        const code = switch (role) {
            .sender => WarpCode.generate(),
            .receiver => WarpCode{ .bytes = [_]u8{0} ** 6 }, // Will be set via setCode
        };

        return Self{
            .allocator = allocator,
            .io = io,
            .code = code,
            .resolver = try Resolver.init(allocator, io),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.transport) |*t| t.deinit();
        self.resolver.deinit();
        // Securely wipe encryption key
        crypto.secureZero(&self.encryption_key);
    }

    /// Set transfer code (receiver only)
    pub fn setCode(self: *Self, code_str: []const u8) !void {
        self.code = try WarpCode.parse(code_str);
        // Derive encryption key from code
        self.encryption_key = self.code.deriveKey();
    }

    /// Get transfer code string (sender displays this)
    pub fn getCodeString(self: *const Self) [WarpCode.STRING_LEN]u8 {
        return self.code.toString();
    }

    /// Start discovery and connection process
    pub fn connect(self: *Self) !void {
        self.state = .discovering;

        // Start mDNS discovery for local peers
        try self.resolver.startMdns(self.code.hash());

        // Query STUN for public endpoint
        const public_endpoint = try self.resolver.queryStun();

        // Exchange endpoints and perform hole punching
        self.state = .connecting;

        // Initialize transport for communication
        var transport = try Transport.init(self.allocator, self.io);
        errdefer transport.deinit();

        // Attempt to discover local peer first via mDNS
        const code_hash = self.code.hash();
        const local_peer = try self.resolver.pollLocal(code_hash);

        // Use local peer if found, otherwise use public endpoint
        const peer_endpoint = if (local_peer) |local|
            local
        else
            public_endpoint;

        // Perform NAT hole punching with exponential backoff
        var hole_puncher = network.HolePuncher{
            .transport = &transport,
            .peer_endpoint = peer_endpoint,
            .local_endpoint = public_endpoint,
            .punch_interval_ms = 100,
            .max_attempts = 50,
        };

        try hole_puncher.punch();

        // Transition to connected state and store transport
        transport.state = .connected;
        self.transport = transport;
        self.state = .connected;
    }

    /// Send a file or directory
    pub fn send(self: *Self, path: []const u8) !void {
        if (self.state != .connecting and self.state != .transferring) {
            return error.InvalidState;
        }

        self.state = .transferring;

        // Open file/directory and stream
        var stream = try FileStream.init(self.allocator, path);
        defer stream.deinit();

        // Send encrypted chunks
        while (try stream.nextChunk()) |chunk| {
            const encrypted = try crypto.encrypt(&self.encryption_key, chunk);
            if (self.transport) |*t| {
                try t.send(encrypted);
            }
        }

        self.state = .completed;
    }

    /// Receive files to destination
    pub fn receive(self: *Self, dest_path: []const u8) !void {
        if (self.state != .connecting and self.state != .transferring) {
            return error.InvalidState;
        }

        self.state = .transferring;

        // Create output stream
        var stream = try FileStream.initWrite(self.allocator, dest_path);
        defer stream.deinit();

        // Receive and decrypt chunks
        while (true) {
            if (self.transport) |*t| {
                const encrypted = try t.recv() orelse break;

                const decrypted = try crypto.decrypt(&self.encryption_key, encrypted);
                try stream.writeChunk(decrypted);
            } else break;
        }

        self.state = .completed;
    }
};

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "warp session lifecycle" {
    var sender = try WarpSession.init(std.testing.allocator, std.testing.io, .sender);
    defer sender.deinit();

    const code_str = sender.getCodeString();
    try std.testing.expect(code_str[0] == 'w');
    try std.testing.expect(code_str[1] == 'a');
    try std.testing.expect(code_str[2] == 'r');
    try std.testing.expect(code_str[3] == 'p');
    try std.testing.expect(code_str[4] == '-');
}

test "warp code round-trip" {
    // Test that parsing a code string produces consistent results
    const str = "warp-729-alpha";
    const parsed1 = try WarpCode.parse(str);
    const parsed2 = try WarpCode.parse(str);
    // Same input should produce same output
    try std.testing.expectEqualSlices(u8, &parsed1.bytes, &parsed2.bytes);
    // And the toString should preserve the meaningful parts
    const output = parsed1.toString();
    try std.testing.expect(std.mem.startsWith(u8, &output, "warp-729-alpha"));
}

test {
    std.testing.refAllDecls(@This());
}
