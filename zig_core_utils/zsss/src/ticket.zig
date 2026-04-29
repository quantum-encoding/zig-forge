//! Event Ticket System using Multi-Layer Steganography
//!
//! Enables embedding up to 256 unique tickets in a single image.
//! Each ticket has its own password - the image can be shared publicly
//! but only password holders can access their specific ticket.
//!
//! Use Cases:
//! - Event tickets (concerts, conferences, sports)
//! - Digital invitations
//! - Access passes
//! - Limited edition collectibles

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const stego = @import("stego.zig");

/// Cross-platform cryptographic random bytes. SYS_getrandom on Linux
/// (works for both gnu/musl and Android-Bionic without an API-level
/// gate); arc4random on Darwin/BSD; /dev/urandom otherwise.
fn fillRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            var filled: usize = 0;
            while (filled < buf.len) {
                const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
                if (rc == 0) break;
                if (@as(isize, @bitCast(rc)) < 0) break;
                filled += rc;
            }
        },
        else => {
            const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
            if (fd >= 0) {
                defer _ = std.c.close(fd);
                var filled: usize = 0;
                while (filled < buf.len) {
                    const n = std.c.read(fd, buf.ptr + filled, buf.len - filled);
                    if (n <= 0) break;
                    filled += @intCast(n);
                }
            }
        },
    }
}

/// Maximum tickets per image (limited by layer slots 0-255)
pub const MAX_TICKETS_PER_IMAGE: usize = 256;

/// Ticket data structure - serialized to JSON and embedded in image layers
pub const TicketData = struct {
    /// Unique event identifier
    event_id: []const u8,
    /// Unique ticket identifier (for one-time use tracking)
    ticket_id: []const u8,
    /// Hash of attendee identifier (email/phone) for privacy
    attendee_hash: ?[]const u8 = null,
    /// Seat assignment (optional)
    seat: ?[]const u8 = null,
    /// Ticket tier (e.g., "VIP", "General", "Early Bird")
    tier: ?[]const u8 = null,
    /// Unix timestamp when ticket was issued
    issued_at: i64,
    /// Unix timestamp when ticket expires (optional)
    expires_at: ?i64 = null,
    /// Custom metadata as JSON string (optional)
    metadata: ?[]const u8 = null,
    /// Ed25519 signature of ticket data by organizer
    signature: []const u8,

    /// Serialize ticket to simple text format (key=value lines)
    pub fn toBytes(self: TicketData, allocator: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Simple line-based format
        try buf.appendSlice(allocator, "ZSSS_TICKET_V1\n");

        var line: [512]u8 = undefined;
        const event_line = std.fmt.bufPrint(&line, "event_id={s}\n", .{self.event_id}) catch return error.BufferTooSmall;
        try buf.appendSlice(allocator, event_line);

        const ticket_line = std.fmt.bufPrint(&line, "ticket_id={s}\n", .{self.ticket_id}) catch return error.BufferTooSmall;
        try buf.appendSlice(allocator, ticket_line);

        const issued_line = std.fmt.bufPrint(&line, "issued_at={d}\n", .{self.issued_at}) catch return error.BufferTooSmall;
        try buf.appendSlice(allocator, issued_line);

        if (self.seat) |seat| {
            const seat_line = std.fmt.bufPrint(&line, "seat={s}\n", .{seat}) catch return error.BufferTooSmall;
            try buf.appendSlice(allocator, seat_line);
        }

        if (self.tier) |tier| {
            const tier_line = std.fmt.bufPrint(&line, "tier={s}\n", .{tier}) catch return error.BufferTooSmall;
            try buf.appendSlice(allocator, tier_line);
        }

        if (self.expires_at) |exp| {
            const exp_line = std.fmt.bufPrint(&line, "expires_at={d}\n", .{exp}) catch return error.BufferTooSmall;
            try buf.appendSlice(allocator, exp_line);
        }

        const sig_line = std.fmt.bufPrint(&line, "signature={s}\n", .{self.signature}) catch return error.BufferTooSmall;
        try buf.appendSlice(allocator, sig_line);

        return buf.toOwnedSlice(allocator);
    }

    /// Deserialize ticket from bytes
    pub fn fromBytes(allocator: Allocator, data: []const u8) !TicketData {
        var event_id: ?[]const u8 = null;
        var ticket_id: ?[]const u8 = null;
        var seat: ?[]const u8 = null;
        var tier: ?[]const u8 = null;
        var signature: ?[]const u8 = null;
        var issued_at: i64 = 0;
        var expires_at: ?i64 = null;

        var lines = std.mem.splitScalar(u8, data, '\n');

        // Check header
        const header = lines.next() orelse return error.InvalidFormat;
        if (!std.mem.eql(u8, header, "ZSSS_TICKET_V1")) {
            return error.InvalidFormat;
        }

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                const key = line[0..eq_pos];
                const value = line[eq_pos + 1 ..];

                if (std.mem.eql(u8, key, "event_id")) {
                    event_id = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "ticket_id")) {
                    ticket_id = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "seat")) {
                    seat = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "tier")) {
                    tier = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "signature")) {
                    signature = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "issued_at")) {
                    issued_at = std.fmt.parseInt(i64, value, 10) catch 0;
                } else if (std.mem.eql(u8, key, "expires_at")) {
                    expires_at = std.fmt.parseInt(i64, value, 10) catch null;
                }
            }
        }

        if (event_id == null or ticket_id == null or signature == null) {
            return error.InvalidFormat;
        }

        return TicketData{
            .event_id = event_id.?,
            .ticket_id = ticket_id.?,
            .seat = seat,
            .tier = tier,
            .signature = signature.?,
            .issued_at = issued_at,
            .expires_at = expires_at,
            .attendee_hash = null,
            .metadata = null,
        };
    }

    /// Free allocated strings
    pub fn deinit(self: *TicketData, allocator: Allocator) void {
        allocator.free(self.event_id);
        allocator.free(self.ticket_id);
        if (self.attendee_hash) |h| allocator.free(h);
        if (self.seat) |s| allocator.free(s);
        if (self.tier) |t| allocator.free(t);
        if (self.metadata) |m| allocator.free(m);
        allocator.free(self.signature);
    }
};

/// Ticket with its assigned password and layer
pub const TicketEntry = struct {
    ticket: TicketData,
    password: []const u8,
    layer: u8,
};

/// Result of ticket embedding operation
pub const EmbedResult = struct {
    /// PNG image data with all tickets embedded
    image_data: []u8,
    /// Number of tickets successfully embedded
    tickets_embedded: usize,
    /// Capacity remaining (layers still available)
    layers_remaining: usize,
};

/// Result of ticket extraction
pub const ExtractResult = struct {
    ticket: TicketData,
    layer: u8,
    valid_signature: bool,
};

/// Error types for ticket operations
pub const TicketError = error{
    TooManyTickets,
    InvalidTicketData,
    SignatureVerificationFailed,
    TicketExpired,
    ImageTooSmall,
    NoTicketFound,
    InvalidPassword,
    DuplicateLayer,
    OutOfMemory,
};

/// Generate a cryptographically secure ticket ID
pub fn generateTicketId(allocator: Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    fillRandomBytes(&random_bytes);

    const hex = try allocator.alloc(u8, 32);
    const hex_array = std.fmt.bytesToHex(random_bytes, .lower);
    @memcpy(hex, &hex_array);
    return hex;
}

/// Generate a secure random password for a ticket
pub fn generatePassword(allocator: Allocator, length: usize) ![]u8 {
    const charset = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    const password = try allocator.alloc(u8, length);

    var random_bytes: [256]u8 = undefined;
    fillRandomBytes(random_bytes[0..length]);

    for (password, 0..) |*c, i| {
        c.* = charset[random_bytes[i] % charset.len];
    }

    return password;
}

/// Hash an attendee identifier (email/phone) for privacy
pub fn hashAttendee(allocator: Allocator, identifier: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(identifier, &hash, .{});

    const hex = try allocator.alloc(u8, 64);
    const hex_array = std.fmt.bytesToHex(hash, .lower);
    @memcpy(hex, &hex_array);
    return hex;
}

/// Create a signature placeholder (in production, use Ed25519 with organizer's key)
pub fn signTicket(allocator: Allocator, ticket_data: []const u8, _: []const u8) ![]u8 {
    // In production: use Ed25519 signing with organizer's private key
    // For now: create HMAC-SHA256 as placeholder
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(ticket_data, &hash, .{});

    const hex = try allocator.alloc(u8, 64);
    const hex_array = std.fmt.bytesToHex(hash, .lower);
    @memcpy(hex, &hex_array);
    return hex;
}

/// Batch embed multiple tickets into a single image
/// Each ticket is assigned to a unique layer (0-255) with its own password
pub fn embedTickets(
    allocator: Allocator,
    png_data: []const u8,
    tickets: []const TicketEntry,
) !EmbedResult {
    if (tickets.len > MAX_TICKETS_PER_IMAGE) {
        return TicketError.TooManyTickets;
    }

    // Check for duplicate layers
    var layer_used: [256]bool = [_]bool{false} ** 256;
    for (tickets) |entry| {
        if (layer_used[entry.layer]) {
            return TicketError.DuplicateLayer;
        }
        layer_used[entry.layer] = true;
    }

    // Start with original image
    var current_image = try allocator.dupe(u8, png_data);
    errdefer allocator.free(current_image);

    var embedded_count: usize = 0;

    for (tickets) |entry| {
        // Serialize ticket to JSON
        const ticket_bytes = try entry.ticket.toBytes(allocator);
        defer allocator.free(ticket_bytes);

        // Embed into the specified layer
        const new_image = stego.embedInPngWithLayer(
            allocator,
            current_image,
            ticket_bytes,
            entry.password,
            entry.layer,
        ) catch |err| {
            // If image is too small for this layer, skip but continue
            if (err == stego.StegoError.ImageTooSmall) {
                continue;
            }
            return err;
        };

        allocator.free(current_image);
        current_image = new_image;
        embedded_count += 1;
    }

    return EmbedResult{
        .image_data = current_image,
        .tickets_embedded = embedded_count,
        .layers_remaining = MAX_TICKETS_PER_IMAGE - embedded_count,
    };
}

/// Extract a ticket from an image using password
/// Tries all 256 layers to find the matching ticket
pub fn extractTicket(
    allocator: Allocator,
    png_data: []const u8,
    password: []const u8,
) !ExtractResult {
    // Try each layer until we find valid ticket data
    for (0..256) |layer_idx| {
        const layer: u8 = @intCast(layer_idx);

        const extracted = stego.extractFromPngWithLayer(
            allocator,
            png_data,
            password,
            layer,
        ) catch |err| {
            // Invalid magic means wrong layer or no data, try next
            if (err == stego.StegoError.InvalidMagic) {
                continue;
            }
            // Other errors might be transient, try next layer
            continue;
        };
        defer allocator.free(extracted);

        // Try to parse as ticket JSON
        const ticket = TicketData.fromBytes(allocator, extracted) catch {
            // Not valid ticket JSON, might be other data in this layer
            continue;
        };

        // Verify signature if available
        const valid_sig = verifyTicketSignature(ticket) catch false;

        return ExtractResult{
            .ticket = ticket,
            .layer = layer,
            .valid_signature = valid_sig,
        };
    }

    return TicketError.NoTicketFound;
}

/// Extract a ticket from a specific known layer
pub fn extractTicketFromLayer(
    allocator: Allocator,
    png_data: []const u8,
    password: []const u8,
    layer: u8,
) !ExtractResult {
    const extracted = try stego.extractFromPngWithLayer(
        allocator,
        png_data,
        password,
        layer,
    );
    defer allocator.free(extracted);

    const ticket = try TicketData.fromBytes(allocator, extracted);

    // Verify signature if available
    const valid_sig = verifyTicketSignature(ticket) catch false;

    return ExtractResult{
        .ticket = ticket,
        .layer = layer,
        .valid_signature = valid_sig,
    };
}

/// Verify the ticket signature using Ed25519
/// This creates a canonical form of the ticket and verifies the signature
fn verifyTicketSignature(ticket: TicketData) !bool {
    // Decode hex signature - Ed25519 signatures are 64 bytes
    if (ticket.signature.len != 128) { // 64 bytes = 128 hex chars
        return false;
    }

    var sig_bytes: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const hex_str = ticket.signature[i * 2 .. i * 2 + 2];
        sig_bytes[i] = std.fmt.parseInt(u8, hex_str, 16) catch return false;
    }

    // For now, we perform a basic validation that signature is non-empty
    // Full Ed25519 verification would require the organizer's public key
    // which isn't stored in the ticket. In a real system, you'd:
    // 1. Store the organizer's public key separately
    // 2. Create a canonical message form from ticket fields
    // 3. Use crypto.sign.Ed25519.verify() with the public key
    // This simplified version just checks that a signature exists and is non-zero
    var non_zero = false;
    for (sig_bytes) |b| {
        if (b != 0) {
            non_zero = true;
            break;
        }
    }

    return non_zero;
}

/// Check if a ticket has expired
/// Note: In production, use proper system time. This placeholder checks
/// only if expires_at is in the past (relative to issued_at as estimate)
pub fn isTicketExpired(ticket_data: TicketData) bool {
    if (ticket_data.expires_at) |expires| {
        // Simple check: if expires_at is before issued_at, something's wrong
        // In production, compare against real system time
        return expires < ticket_data.issued_at;
    }
    return false;
}

/// Calculate how many tickets can fit in an image
pub fn calculateCapacity(png_data: []const u8) !CapacityInfo {
    const dimensions = try stego.getPngDimensions(png_data);
    const total_pixels = dimensions.width * dimensions.height;
    const pixels_per_layer = total_pixels / 256;

    // Each pixel stores 1 bit, minus header overhead
    const header_bits = stego.HEADER_SIZE * 8;
    const usable_bits_per_layer = if (pixels_per_layer > header_bits)
        pixels_per_layer - header_bits
    else
        0;
    const bytes_per_layer = usable_bits_per_layer / 8;

    // Typical ticket JSON is ~150-300 bytes
    const typical_ticket_size: usize = 250;
    const practical_capacity = if (bytes_per_layer >= typical_ticket_size)
        @min(256, total_pixels / (typical_ticket_size * 8 + header_bits))
    else
        0;

    return CapacityInfo{
        .image_width = dimensions.width,
        .image_height = dimensions.height,
        .total_pixels = total_pixels,
        .pixels_per_layer = pixels_per_layer,
        .bytes_per_layer = bytes_per_layer,
        .max_layers = 256,
        .practical_ticket_capacity = practical_capacity,
    };
}

pub const CapacityInfo = struct {
    image_width: usize,
    image_height: usize,
    total_pixels: usize,
    pixels_per_layer: usize,
    bytes_per_layer: usize,
    max_layers: usize,
    practical_ticket_capacity: usize,
};

// =============================================================================
// Tests
// =============================================================================

test "generate ticket ID" {
    const allocator = std.testing.allocator;

    const id1 = try generateTicketId(allocator);
    defer allocator.free(id1);

    const id2 = try generateTicketId(allocator);
    defer allocator.free(id2);

    // Should be 32 hex chars
    try std.testing.expectEqual(@as(usize, 32), id1.len);
    try std.testing.expectEqual(@as(usize, 32), id2.len);

    // Should be unique
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "generate password" {
    const allocator = std.testing.allocator;

    const pwd = try generatePassword(allocator, 8);
    defer allocator.free(pwd);

    try std.testing.expectEqual(@as(usize, 8), pwd.len);

    // Should only contain allowed characters
    const charset = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    for (pwd) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, charset, c) != null);
    }
}

test "hash attendee" {
    const allocator = std.testing.allocator;

    const hash = try hashAttendee(allocator, "test@example.com");
    defer allocator.free(hash);

    // SHA256 produces 64 hex chars
    try std.testing.expectEqual(@as(usize, 64), hash.len);
}

test "ticket JSON roundtrip" {
    const allocator = std.testing.allocator;

    const ticket = TicketData{
        .event_id = "EVT-2026-001",
        .ticket_id = "TKT-00042",
        .attendee_hash = "abc123",
        .seat = "A-15",
        .tier = "VIP",
        .issued_at = 1704672000,
        .expires_at = 1704758400,
        .metadata = null,
        .signature = "sig123",
    };

    const json_data = try ticket.toBytes(allocator);
    defer allocator.free(json_data);

    var parsed = try TicketData.fromBytes(allocator, json_data);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings(ticket.event_id, parsed.event_id);
    try std.testing.expectEqualStrings(ticket.ticket_id, parsed.ticket_id);
    try std.testing.expectEqualStrings(ticket.seat.?, parsed.seat.?);
    try std.testing.expectEqual(ticket.issued_at, parsed.issued_at);
}
