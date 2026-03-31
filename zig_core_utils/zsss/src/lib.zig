//! zsss Library - C-compatible FFI interface
//!
//! Provides Shamir Secret Sharing and Steganography functions
//! callable from C, Java (JNI), Kotlin, Swift, etc.
//!
//! Memory Management:
//! - All returned buffers must be freed with zsss_free()
//! - Input buffers are not modified or freed by library functions
//! - Static libraries are compiled with PIC for shared library linking

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import core modules
const main = @import("main.zig");
const stego = @import("stego.zig");
const slip39 = @import("slip39.zig");
const ticket = @import("ticket.zig");

const GF256 = main.GF256;
const SSS = main.SSS;
const Share = main.Share;
const TicketData = ticket.TicketData;

// =============================================================================
// Memory Management
// =============================================================================

/// Global allocator for FFI - uses page allocator for portability
/// (No libc dependency)
const ffi_allocator = std.heap.page_allocator;

/// Result buffer returned to caller
pub const ZsssBuffer = extern struct {
    data: ?[*]u8,
    len: usize,
    error_code: i32,
};

/// Error codes
pub const ZSSS_OK: i32 = 0;
pub const ZSSS_ERR_INVALID_INPUT: i32 = -1;
pub const ZSSS_ERR_THRESHOLD_TOO_LOW: i32 = -2;
pub const ZSSS_ERR_THRESHOLD_EXCEEDS_SHARES: i32 = -3;
pub const ZSSS_ERR_TOO_MANY_SHARES: i32 = -4;
pub const ZSSS_ERR_EMPTY_SECRET: i32 = -5;
pub const ZSSS_ERR_NO_SHARES: i32 = -6;
pub const ZSSS_ERR_INSUFFICIENT_SHARES: i32 = -7;
pub const ZSSS_ERR_CHECKSUM_MISMATCH: i32 = -8;
pub const ZSSS_ERR_SECRET_VERIFICATION_FAILED: i32 = -9;
pub const ZSSS_ERR_OUT_OF_MEMORY: i32 = -10;
pub const ZSSS_ERR_IMAGE_TOO_SMALL: i32 = -11;
pub const ZSSS_ERR_INVALID_PNG: i32 = -12;
pub const ZSSS_ERR_INVALID_MAGIC: i32 = -13;
pub const ZSSS_ERR_DECRYPTION_FAILED: i32 = -14;
pub const ZSSS_ERR_INVALID_PASSWORD: i32 = -15;
pub const ZSSS_ERR_TICKET_NOT_FOUND: i32 = -16;
pub const ZSSS_ERR_TICKET_EXPIRED: i32 = -17;
pub const ZSSS_ERR_TICKET_INVALID: i32 = -18;
pub const ZSSS_ERR_LAYER_OCCUPIED: i32 = -19;
pub const ZSSS_ERR_UNKNOWN: i32 = -99;

/// Free a buffer returned by zsss functions
export fn zsss_free(buf: ZsssBuffer) void {
    if (buf.data) |ptr| {
        // Zero out before freeing (security)
        const slice = ptr[0..buf.len];
        @memset(slice, 0);
        ffi_allocator.free(slice);
    }
}

/// Get library version string
export fn zsss_version() [*:0]const u8 {
    return "0.1.0";
}

// =============================================================================
// Shamir Secret Sharing
// =============================================================================

/// Split a secret into n shares with threshold k
/// Returns array of serialized shares concatenated with length prefixes
/// Format: [len1:u32][share1][len2:u32][share2]...
export fn zsss_split(
    secret_ptr: [*]const u8,
    secret_len: usize,
    threshold: u8,
    num_shares: u8,
) ZsssBuffer {
    if (secret_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_EMPTY_SECRET };
    }

    const secret = secret_ptr[0..secret_len];

    const shares = SSS.split(ffi_allocator, secret, threshold, num_shares) catch {
        // Use generic error code - specific errors would require matching against error set
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_INPUT };
    };
    defer {
        for (shares) |*share| {
            var mutable = share.*;
            mutable.deinit(ffi_allocator);
        }
        ffi_allocator.free(shares);
    }

    // Serialize all shares with length prefixes
    var total_size: usize = 0;
    var serialized_shares = ffi_allocator.alloc([]u8, shares.len) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };
    defer {
        for (serialized_shares) |s| {
            if (s.len > 0) ffi_allocator.free(s);
        }
        ffi_allocator.free(serialized_shares);
    }

    for (shares, 0..) |*share, i| {
        serialized_shares[i] = share.serialize(ffi_allocator) catch {
            return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
        };
        total_size += 4 + serialized_shares[i].len; // 4 bytes for length prefix
    }

    // Allocate output buffer
    const output = ffi_allocator.alloc(u8, total_size) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };

    // Write length-prefixed shares
    var pos: usize = 0;
    for (serialized_shares) |s| {
        const len: u32 = @intCast(s.len);
        output[pos] = @truncate(len & 0xFF);
        output[pos + 1] = @truncate((len >> 8) & 0xFF);
        output[pos + 2] = @truncate((len >> 16) & 0xFF);
        output[pos + 3] = @truncate((len >> 24) & 0xFF);
        pos += 4;
        @memcpy(output[pos..][0..s.len], s);
        pos += s.len;
    }

    return .{ .data = output.ptr, .len = output.len, .error_code = ZSSS_OK };
}

/// Combine shares to recover secret
/// shares_ptr: concatenated length-prefixed shares (same format as zsss_split output)
export fn zsss_combine(
    shares_ptr: [*]const u8,
    shares_len: usize,
) ZsssBuffer {
    if (shares_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_NO_SHARES };
    }

    const shares_data = shares_ptr[0..shares_len];

    // Parse length-prefixed shares
    var shares_list: std.ArrayList(Share) = .empty;
    defer {
        for (shares_list.items) |*s| {
            s.deinit(ffi_allocator);
        }
        shares_list.deinit(ffi_allocator);
    }

    var pos: usize = 0;
    while (pos + 4 <= shares_data.len) {
        const len: u32 = @as(u32, shares_data[pos]) |
            (@as(u32, shares_data[pos + 1]) << 8) |
            (@as(u32, shares_data[pos + 2]) << 16) |
            (@as(u32, shares_data[pos + 3]) << 24);
        pos += 4;

        if (pos + len > shares_data.len) break;

        const share = Share.deserialize(ffi_allocator, shares_data[pos..][0..len]) catch {
            return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_CHECKSUM_MISMATCH };
        };
        shares_list.append(ffi_allocator, share) catch {
            return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
        };
        pos += len;
    }

    if (shares_list.items.len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_NO_SHARES };
    }

    // Combine shares
    const secret = SSS.combine(ffi_allocator, shares_list.items) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INSUFFICIENT_SHARES };
    };

    return .{ .data = secret.ptr, .len = secret.len, .error_code = ZSSS_OK };
}

// =============================================================================
// Steganography
// =============================================================================

/// Embed data into a PNG image
/// password can be null for no encryption
/// layer_slot: -1 for default (all pixels), 0-255 for specific layer
export fn zsss_stego_embed(
    png_ptr: [*]const u8,
    png_len: usize,
    data_ptr: [*]const u8,
    data_len: usize,
    password_ptr: ?[*]const u8,
    password_len: usize,
    layer_slot: i16,
) ZsssBuffer {
    if (png_len == 0 or data_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_INPUT };
    }

    const png_data = png_ptr[0..png_len];
    const secret_data = data_ptr[0..data_len];
    const password: ?[]const u8 = if (password_ptr) |p| p[0..password_len] else null;
    const layer: ?u8 = if (layer_slot >= 0 and layer_slot <= 255) @intCast(layer_slot) else null;

    const output = stego.embedInPngWithLayer(
        ffi_allocator,
        png_data,
        secret_data,
        password,
        layer,
    ) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_IMAGE_TOO_SMALL };
    };

    return .{ .data = output.ptr, .len = output.len, .error_code = ZSSS_OK };
}

/// Extract data from a PNG image
/// password can be null if data was not encrypted
/// layer_slot: -1 for default (all pixels), 0-255 for specific layer
export fn zsss_stego_extract(
    png_ptr: [*]const u8,
    png_len: usize,
    password_ptr: ?[*]const u8,
    password_len: usize,
    layer_slot: i16,
) ZsssBuffer {
    if (png_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_INPUT };
    }

    const png_data = png_ptr[0..png_len];
    const password: ?[]const u8 = if (password_ptr) |p| p[0..password_len] else null;
    const layer: ?u8 = if (layer_slot >= 0 and layer_slot <= 255) @intCast(layer_slot) else null;

    const output = stego.extractFromPngWithLayer(
        ffi_allocator,
        png_data,
        password,
        layer,
    ) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_MAGIC };
    };

    return .{ .data = output.ptr, .len = output.len, .error_code = ZSSS_OK };
}

// =============================================================================
// Event Tickets
// =============================================================================

/// Ticket information result structure
pub const ZsssTicketInfo = extern struct {
    event_id: ?[*]u8,
    event_id_len: usize,
    ticket_id: ?[*]u8,
    ticket_id_len: usize,
    seat: ?[*]u8,
    seat_len: usize,
    tier: ?[*]u8,
    tier_len: usize,
    layer: u8,
    issued_at: i64,
    expires_at: i64, // 0 if no expiry
    is_valid: bool,
    error_code: i32,
};

/// Create and embed a single ticket into a PNG image
/// Returns the modified PNG image with the ticket embedded
export fn zsss_ticket_embed(
    png_ptr: [*]const u8,
    png_len: usize,
    event_id_ptr: [*]const u8,
    event_id_len: usize,
    password_ptr: [*]const u8,
    password_len: usize,
    layer: u8,
    seat_ptr: ?[*]const u8,
    seat_len: usize,
    tier_ptr: ?[*]const u8,
    tier_len: usize,
) ZsssBuffer {
    if (png_len == 0 or event_id_len == 0 or password_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_INPUT };
    }

    const png_data = png_ptr[0..png_len];
    const event_id = event_id_ptr[0..event_id_len];
    const password = password_ptr[0..password_len];
    const seat: ?[]const u8 = if (seat_ptr) |p| p[0..seat_len] else null;
    const tier: ?[]const u8 = if (tier_ptr) |p| p[0..tier_len] else null;

    // Generate ticket ID and signature
    const ticket_id = ticket.generateTicketId(ffi_allocator) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };
    defer ffi_allocator.free(ticket_id);

    const sig = ticket.signTicket(ffi_allocator, ticket_id, "organizer_key") catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };
    defer ffi_allocator.free(sig);

    // Create ticket data
    var ticket_data = TicketData{
        .event_id = event_id,
        .ticket_id = ticket_id,
        .seat = seat,
        .tier = tier,
        .issued_at = 0, // Will be set by current time
        .signature = sig,
    };

    // Serialize ticket
    const ticket_bytes = ticket_data.toBytes(ffi_allocator) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };
    defer ffi_allocator.free(ticket_bytes);

    // Embed into image at specified layer
    const output = stego.embedInPngWithLayer(
        ffi_allocator,
        png_data,
        ticket_bytes,
        password,
        layer,
    ) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_IMAGE_TOO_SMALL };
    };

    return .{ .data = output.ptr, .len = output.len, .error_code = ZSSS_OK };
}

/// Extract and verify a ticket from a PNG image
/// Returns the raw ticket data bytes
export fn zsss_ticket_extract(
    png_ptr: [*]const u8,
    png_len: usize,
    password_ptr: [*]const u8,
    password_len: usize,
) ZsssBuffer {
    if (png_len == 0 or password_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_INVALID_INPUT };
    }

    const png_data = png_ptr[0..png_len];
    const password = password_ptr[0..password_len];

    // Try all 256 layers to find the ticket
    for (0..256) |i| {
        const layer: u8 = @intCast(i);
        const extracted = stego.extractFromPngWithLayer(
            ffi_allocator,
            png_data,
            password,
            layer,
        ) catch continue;

        // Try to parse as ticket
        var parsed = TicketData.fromBytes(ffi_allocator, extracted) catch {
            ffi_allocator.free(extracted);
            continue;
        };

        // Valid ticket found - return the raw bytes
        parsed.deinit(ffi_allocator);
        return .{ .data = extracted.ptr, .len = extracted.len, .error_code = ZSSS_OK };
    }

    return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_TICKET_NOT_FOUND };
}

/// Get ticket information from a PNG image
/// Returns structured ticket info
export fn zsss_ticket_info(
    png_ptr: [*]const u8,
    png_len: usize,
    password_ptr: [*]const u8,
    password_len: usize,
    out_info: *ZsssTicketInfo,
) i32 {
    if (png_len == 0 or password_len == 0) {
        out_info.* = .{
            .event_id = null,
            .event_id_len = 0,
            .ticket_id = null,
            .ticket_id_len = 0,
            .seat = null,
            .seat_len = 0,
            .tier = null,
            .tier_len = 0,
            .layer = 0,
            .issued_at = 0,
            .expires_at = 0,
            .is_valid = false,
            .error_code = ZSSS_ERR_INVALID_INPUT,
        };
        return ZSSS_ERR_INVALID_INPUT;
    }

    const png_data = png_ptr[0..png_len];
    const password = password_ptr[0..password_len];

    // Try all 256 layers to find the ticket
    for (0..256) |i| {
        const layer: u8 = @intCast(i);
        const extracted = stego.extractFromPngWithLayer(
            ffi_allocator,
            png_data,
            password,
            layer,
        ) catch continue;
        defer ffi_allocator.free(extracted);

        // Try to parse as ticket
        var parsed = TicketData.fromBytes(ffi_allocator, extracted) catch continue;
        defer parsed.deinit(ffi_allocator);

        // Copy strings to output buffers (caller must free)
        const event_copy = ffi_allocator.dupe(u8, parsed.event_id) catch {
            out_info.error_code = ZSSS_ERR_OUT_OF_MEMORY;
            return ZSSS_ERR_OUT_OF_MEMORY;
        };
        const ticket_copy = ffi_allocator.dupe(u8, parsed.ticket_id) catch {
            ffi_allocator.free(event_copy);
            out_info.error_code = ZSSS_ERR_OUT_OF_MEMORY;
            return ZSSS_ERR_OUT_OF_MEMORY;
        };

        var seat_copy: ?[]u8 = null;
        if (parsed.seat) |s| {
            seat_copy = ffi_allocator.dupe(u8, s) catch null;
        }

        var tier_copy: ?[]u8 = null;
        if (parsed.tier) |t| {
            tier_copy = ffi_allocator.dupe(u8, t) catch null;
        }

        out_info.* = .{
            .event_id = event_copy.ptr,
            .event_id_len = event_copy.len,
            .ticket_id = ticket_copy.ptr,
            .ticket_id_len = ticket_copy.len,
            .seat = if (seat_copy) |s| s.ptr else null,
            .seat_len = if (seat_copy) |s| s.len else 0,
            .tier = if (tier_copy) |t| t.ptr else null,
            .tier_len = if (tier_copy) |t| t.len else 0,
            .layer = layer,
            .issued_at = parsed.issued_at,
            .expires_at = parsed.expires_at orelse 0,
            .is_valid = true,
            .error_code = ZSSS_OK,
        };
        return ZSSS_OK;
    }

    out_info.* = .{
        .event_id = null,
        .event_id_len = 0,
        .ticket_id = null,
        .ticket_id_len = 0,
        .seat = null,
        .seat_len = 0,
        .tier = null,
        .tier_len = 0,
        .layer = 0,
        .issued_at = 0,
        .expires_at = 0,
        .is_valid = false,
        .error_code = ZSSS_ERR_TICKET_NOT_FOUND,
    };
    return ZSSS_ERR_TICKET_NOT_FOUND;
}

/// Free ticket info strings
export fn zsss_ticket_info_free(info: *ZsssTicketInfo) void {
    if (info.event_id) |p| {
        ffi_allocator.free(p[0..info.event_id_len]);
    }
    if (info.ticket_id) |p| {
        ffi_allocator.free(p[0..info.ticket_id_len]);
    }
    if (info.seat) |p| {
        ffi_allocator.free(p[0..info.seat_len]);
    }
    if (info.tier) |p| {
        ffi_allocator.free(p[0..info.tier_len]);
    }
    info.* = .{
        .event_id = null,
        .event_id_len = 0,
        .ticket_id = null,
        .ticket_id_len = 0,
        .seat = null,
        .seat_len = 0,
        .tier = null,
        .tier_len = 0,
        .layer = 0,
        .issued_at = 0,
        .expires_at = 0,
        .is_valid = false,
        .error_code = 0,
    };
}

/// Get image ticket capacity
/// Returns: number of tickets (layers) the image can hold (max 256)
export fn zsss_ticket_capacity(
    png_ptr: [*]const u8,
    png_len: usize,
    bytes_per_ticket: *usize,
) i32 {
    if (png_len == 0) {
        bytes_per_ticket.* = 0;
        return 0;
    }

    const png_data = png_ptr[0..png_len];
    const dims = stego.getPngDimensions(png_data) catch {
        bytes_per_ticket.* = 0;
        return 0;
    };

    const total_pixels = dims.width * dims.height;
    const pixels_per_layer = total_pixels / 256;
    const usable_bytes = (pixels_per_layer * 3) / 8;
    const capacity = if (usable_bytes > stego.HEADER_SIZE) usable_bytes - stego.HEADER_SIZE else 0;

    bytes_per_ticket.* = capacity;
    return 256; // Max layers
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Get error message for error code
export fn zsss_error_message(error_code: i32) [*:0]const u8 {
    return switch (error_code) {
        ZSSS_OK => "Success",
        ZSSS_ERR_INVALID_INPUT => "Invalid input",
        ZSSS_ERR_THRESHOLD_TOO_LOW => "Threshold too low (minimum 2)",
        ZSSS_ERR_THRESHOLD_EXCEEDS_SHARES => "Threshold exceeds number of shares",
        ZSSS_ERR_TOO_MANY_SHARES => "Too many shares (maximum 255)",
        ZSSS_ERR_EMPTY_SECRET => "Empty secret",
        ZSSS_ERR_NO_SHARES => "No shares provided",
        ZSSS_ERR_INSUFFICIENT_SHARES => "Insufficient shares to recover secret",
        ZSSS_ERR_CHECKSUM_MISMATCH => "Share checksum mismatch (corrupted)",
        ZSSS_ERR_SECRET_VERIFICATION_FAILED => "Secret verification failed",
        ZSSS_ERR_OUT_OF_MEMORY => "Out of memory",
        ZSSS_ERR_IMAGE_TOO_SMALL => "Image too small for data",
        ZSSS_ERR_INVALID_PNG => "Invalid PNG image",
        ZSSS_ERR_INVALID_MAGIC => "No hidden data found",
        ZSSS_ERR_DECRYPTION_FAILED => "Decryption failed (wrong password)",
        ZSSS_ERR_INVALID_PASSWORD => "Password required but not provided",
        ZSSS_ERR_TICKET_NOT_FOUND => "No valid ticket found for this password",
        ZSSS_ERR_TICKET_EXPIRED => "Ticket has expired",
        ZSSS_ERR_TICKET_INVALID => "Invalid ticket data",
        ZSSS_ERR_LAYER_OCCUPIED => "Layer already contains data",
        else => "Unknown error",
    };
}

/// Initialize the library (call once before use)
export fn zsss_init() void {
    GF256.init();
}

// =============================================================================
// Tests
// =============================================================================

test "FFI split and combine" {
    zsss_init();

    const secret = "Test secret for FFI";
    const result = zsss_split(secret.ptr, secret.len, 3, 5);
    defer zsss_free(result);

    try std.testing.expect(result.error_code == ZSSS_OK);
    try std.testing.expect(result.data != null);

    // Combine using the same buffer
    const combined = zsss_combine(result.data.?, result.len);
    defer zsss_free(combined);

    try std.testing.expect(combined.error_code == ZSSS_OK);
    try std.testing.expectEqualStrings(secret, combined.data.?[0..combined.len]);
}
