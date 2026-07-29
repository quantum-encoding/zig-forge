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
// SLIP-39 specific codes. Appended rather than reusing the generic codes so
// callers can tell a malformed mnemonic from an inconsistent share set.
pub const ZSSS_ERR_SLIP39_INVALID_MNEMONIC: i32 = -20;
pub const ZSSS_ERR_SLIP39_INVALID_SHARE_SET: i32 = -21;
pub const ZSSS_ERR_SLIP39_INVALID_DIGEST: i32 = -22;
pub const ZSSS_ERR_SLIP39_INVALID_CONFIG: i32 = -23;
pub const ZSSS_ERR_SLIP39_INVALID_PASSPHRASE: i32 = -24;
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
// SLIP-0039 (interoperable mnemonic shares)
// =============================================================================
//
// These are separate entry points from zsss_split/zsss_combine above, which
// implement a different (zsss-native binary) scheme and keep their existing
// signatures and behaviour.

fn slip39ErrorCode(err: anyerror) i32 {
    return switch (err) {
        slip39.Error.UnknownWord,
        slip39.Error.MnemonicTooShort,
        slip39.Error.InvalidChecksum,
        slip39.Error.InvalidPadding,
        slip39.Error.GroupThresholdExceedsCount,
        => ZSSS_ERR_SLIP39_INVALID_MNEMONIC,

        slip39.Error.MismatchedShareParameters,
        slip39.Error.MismatchedMemberThreshold,
        slip39.Error.DuplicateMemberIndex,
        slip39.Error.DuplicateGroupIndex,
        slip39.Error.WrongNumberOfGroups,
        slip39.Error.WrongNumberOfShares,
        slip39.Error.InvalidShareValueLength,
        slip39.Error.EmptyShareSet,
        => ZSSS_ERR_SLIP39_INVALID_SHARE_SET,

        slip39.Error.InvalidDigest => ZSSS_ERR_SLIP39_INVALID_DIGEST,
        slip39.Error.InvalidPassphrase => ZSSS_ERR_SLIP39_INVALID_PASSPHRASE,

        slip39.Error.InvalidMasterSecretLength,
        slip39.Error.InvalidThreshold,
        slip39.Error.ThresholdOneWithMultipleMembers,
        slip39.Error.InvalidGroupConfiguration,
        => ZSSS_ERR_SLIP39_INVALID_CONFIG,

        error.OutOfMemory => ZSSS_ERR_OUT_OF_MEMORY,
        else => ZSSS_ERR_UNKNOWN,
    };
}

/// Pack a list of byte slices into the same length-prefixed framing that
/// zsss_split uses: [len1:u32 LE][bytes1][len2:u32 LE][bytes2]...
fn packFrames(items: []const []const u8) !ZsssBuffer {
    var total: usize = 0;
    for (items) |item| total += 4 + item.len;

    const output = try ffi_allocator.alloc(u8, total);
    var pos: usize = 0;
    for (items) |item| {
        std.mem.writeInt(u32, output[pos..][0..4], @intCast(item.len), .little);
        pos += 4;
        @memcpy(output[pos..][0..item.len], item);
        pos += item.len;
    }
    return .{ .data = output.ptr, .len = output.len, .error_code = ZSSS_OK };
}

/// Split a master secret into SLIP-0039 mnemonic shares.
///
/// group_specs points at `group_count` pairs of bytes
/// (member_threshold, member_count), one pair per group.
/// iteration_exponent must be 0-15; total PBKDF2 iterations are 10000 << e.
///
/// Returns the mnemonics as length-prefixed UTF-8 strings in the same framing
/// as zsss_split, ordered group 0 members first. Free with zsss_free().
export fn zsss_slip39_generate(
    secret_ptr: [*]const u8,
    secret_len: usize,
    group_threshold: u8,
    group_specs_ptr: [*]const u8,
    group_count: usize,
    passphrase_ptr: ?[*]const u8,
    passphrase_len: usize,
    iteration_exponent: u8,
    extendable: bool,
) ZsssBuffer {
    if (secret_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_EMPTY_SECRET };
    }
    if (group_count == 0 or group_count > slip39.MAX_SHARE_COUNT or iteration_exponent > 15) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_SLIP39_INVALID_CONFIG };
    }

    const groups = ffi_allocator.alloc(slip39.GroupSpec, group_count) catch {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
    };
    defer ffi_allocator.free(groups);
    const spec_bytes = group_specs_ptr[0 .. group_count * 2];
    for (groups, 0..) |*g, i| {
        g.* = .{ .member_threshold = spec_bytes[i * 2], .member_count = spec_bytes[i * 2 + 1] };
    }

    const passphrase: []const u8 = if (passphrase_ptr) |p| p[0..passphrase_len] else "";

    const mnemonics = slip39.generateMnemonics(ffi_allocator, secret_ptr[0..secret_len], .{
        .group_threshold = group_threshold,
        .groups = groups,
        .passphrase = passphrase,
        .extendable = extendable,
        .iteration_exponent = @intCast(iteration_exponent),
    }) catch |err| {
        return .{ .data = null, .len = 0, .error_code = slip39ErrorCode(err) };
    };
    // freeMnemonics zeroizes each mnemonic: they are the shares themselves.
    defer slip39.freeMnemonics(ffi_allocator, mnemonics);

    return packFrames(@ptrCast(mnemonics)) catch
        .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
}

/// Recover a master secret from SLIP-0039 mnemonics.
///
/// mnemonics_ptr holds length-prefixed UTF-8 mnemonic strings in the same
/// framing that zsss_slip39_generate produces. Free the result with zsss_free().
///
/// There is no way to verify the passphrase (spec: "Passphrase verification"):
/// a wrong passphrase returns a different master secret, not an error.
export fn zsss_slip39_combine(
    mnemonics_ptr: [*]const u8,
    mnemonics_len: usize,
    passphrase_ptr: ?[*]const u8,
    passphrase_len: usize,
) ZsssBuffer {
    if (mnemonics_len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_NO_SHARES };
    }

    var mnemonics: std.ArrayList([]const u8) = .empty;
    defer mnemonics.deinit(ffi_allocator);

    const data = mnemonics_ptr[0..mnemonics_len];
    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + len > data.len) break;
        mnemonics.append(ffi_allocator, data[pos..][0..len]) catch {
            return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_OUT_OF_MEMORY };
        };
        pos += len;
    }

    if (mnemonics.items.len == 0) {
        return .{ .data = null, .len = 0, .error_code = ZSSS_ERR_NO_SHARES };
    }

    const passphrase: []const u8 = if (passphrase_ptr) |p| p[0..passphrase_len] else "";

    const secret = slip39.combineMnemonics(ffi_allocator, mnemonics.items, passphrase) catch |err| {
        return .{ .data = null, .len = 0, .error_code = slip39ErrorCode(err) };
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
        ZSSS_ERR_SLIP39_INVALID_MNEMONIC => "Invalid SLIP-39 mnemonic (word, length, checksum or padding)",
        ZSSS_ERR_SLIP39_INVALID_SHARE_SET => "Invalid SLIP-39 share set (mismatched or wrong number of shares)",
        ZSSS_ERR_SLIP39_INVALID_DIGEST => "SLIP-39 digest check failed (shares do not belong to one secret)",
        ZSSS_ERR_SLIP39_INVALID_CONFIG => "Invalid SLIP-39 configuration (secret length, threshold or groups)",
        ZSSS_ERR_SLIP39_INVALID_PASSPHRASE => "SLIP-39 passphrase must be printable ASCII (32-126)",
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

/// Extract the Nth length-prefixed share frame (including its 4-byte length
/// prefix) from a `zsss_split` output buffer. Returns an empty slice if absent.
fn nthShareFrame(buf: []const u8, n: usize) []const u8 {
    var pos: usize = 0;
    var idx: usize = 0;
    while (pos + 4 <= buf.len) {
        const len: u32 = @as(u32, buf[pos]) |
            (@as(u32, buf[pos + 1]) << 8) |
            (@as(u32, buf[pos + 2]) << 16) |
            (@as(u32, buf[pos + 3]) << 24);
        const start = pos;
        pos += 4;
        if (pos + len > buf.len) break;
        pos += len;
        if (idx == n) return buf[start..pos];
        idx += 1;
    }
    return buf[0..0];
}

// Regression for audit finding X-3: feeding `zsss_combine` shares drawn from
// two INDEPENDENT splits of the SAME secret (same n,k, distinct indices) used
// to SIGSEGV via a double-free on the secret-verification failure path. It must
// now return a clean negative error code and never crash. This is the exact
// shape reproduced from the Rust seed-recovery path.
test "FFI combine mismatched same-secret shares returns error, no crash" {
    zsss_init();

    const secret = "SAME-SECRET-FOR-FFI-MIX-TEST!!!!";
    const split_a = zsss_split(secret.ptr, secret.len, 3, 5);
    defer zsss_free(split_a);
    const split_b = zsss_split(secret.ptr, secret.len, 3, 5);
    defer zsss_free(split_b);

    try std.testing.expectEqual(ZSSS_OK, split_a.error_code);
    try std.testing.expectEqual(ZSSS_OK, split_b.error_code);

    const buf_a = split_a.data.?[0..split_a.len];
    const buf_b = split_b.data.?[0..split_b.len];

    // Distinct indices (A#1, B#2, B#3): passes structural checks, fails
    // reconstruction verification -> must surface as an error code, not a crash.
    const a = std.testing.allocator;
    var combo: std.ArrayList(u8) = .empty;
    defer combo.deinit(a);
    try combo.appendSlice(a, nthShareFrame(buf_a, 0));
    try combo.appendSlice(a, nthShareFrame(buf_b, 1));
    try combo.appendSlice(a, nthShareFrame(buf_b, 2));

    const result = zsss_combine(combo.items.ptr, combo.items.len);
    defer zsss_free(result);

    // No SIGSEGV reaching here is the primary assertion. The set is
    // structurally valid, so it is rejected at reconstruction verification,
    // mapped by the FFI layer to ZSSS_ERR_INSUFFICIENT_SHARES.
    try std.testing.expect(result.error_code != ZSSS_OK);
    try std.testing.expectEqual(ZSSS_ERR_INSUFFICIENT_SHARES, result.error_code);
}

test "FFI SLIP-39 generate and combine, single group" {
    const master_secret = [_]u8{
        0xBB, 0x54, 0xAA, 0xC4, 0xB8, 0x9D, 0xC8, 0x68,
        0xBA, 0x37, 0xD9, 0xCC, 0x21, 0xB2, 0xCE, 0xCE,
    };
    // One group, 3 of 5.
    const specs = [_]u8{ 3, 5 };
    const passphrase = "TREZOR";

    const generated = zsss_slip39_generate(
        &master_secret,
        master_secret.len,
        1,
        &specs,
        1,
        passphrase.ptr,
        passphrase.len,
        0,
        true,
    );
    defer zsss_free(generated);
    try std.testing.expectEqual(ZSSS_OK, generated.error_code);

    // Feed back three of the five frames.
    const a = std.testing.allocator;
    var combo: std.ArrayList(u8) = .empty;
    defer combo.deinit(a);
    const buf = generated.data.?[0..generated.len];
    for ([_]usize{ 0, 2, 4 }) |i| {
        try combo.appendSlice(a, nthShareFrame(buf, i));
    }

    const combined = zsss_slip39_combine(combo.items.ptr, combo.items.len, passphrase.ptr, passphrase.len);
    defer zsss_free(combined);
    try std.testing.expectEqual(ZSSS_OK, combined.error_code);
    try std.testing.expectEqualSlices(u8, &master_secret, combined.data.?[0..combined.len]);

    // Two frames is below the member threshold: a clean error, not a crash.
    var short: std.ArrayList(u8) = .empty;
    defer short.deinit(a);
    try short.appendSlice(a, nthShareFrame(buf, 0));
    try short.appendSlice(a, nthShareFrame(buf, 2));
    const insufficient = zsss_slip39_combine(short.items.ptr, short.items.len, passphrase.ptr, passphrase.len);
    defer zsss_free(insufficient);
    try std.testing.expectEqual(ZSSS_ERR_SLIP39_INVALID_SHARE_SET, insufficient.error_code);
}

test "FFI SLIP-39 generate rejects a too-short secret and a bad group spec" {
    const short_secret = [_]u8{ 1, 2, 3, 4 };
    const specs = [_]u8{ 2, 3 };
    const too_short = zsss_slip39_generate(&short_secret, short_secret.len, 1, &specs, 1, null, 0, 1, true);
    defer zsss_free(too_short);
    try std.testing.expectEqual(ZSSS_ERR_SLIP39_INVALID_CONFIG, too_short.error_code);

    const secret = [_]u8{0x42} ** 16;
    // Group threshold above the number of groups.
    const bad_gt = zsss_slip39_generate(&secret, secret.len, 3, &specs, 1, null, 0, 1, true);
    defer zsss_free(bad_gt);
    try std.testing.expectEqual(ZSSS_ERR_SLIP39_INVALID_CONFIG, bad_gt.error_code);

    // Iteration exponent out of the 4-bit field's range.
    const bad_e = zsss_slip39_generate(&secret, secret.len, 1, &specs, 1, null, 0, 16, true);
    defer zsss_free(bad_e);
    try std.testing.expectEqual(ZSSS_ERR_SLIP39_INVALID_CONFIG, bad_e.error_code);
}

test "FFI SLIP-39 multi-group round-trip" {
    const master_secret = [_]u8{0x5A} ** 32;
    // Three groups: 1of1, 2of3, 2of2; two groups required.
    const specs = [_]u8{ 1, 1, 2, 3, 2, 2 };

    const generated = zsss_slip39_generate(&master_secret, master_secret.len, 2, &specs, 3, null, 0, 0, true);
    defer zsss_free(generated);
    try std.testing.expectEqual(ZSSS_OK, generated.error_code);

    const buf = generated.data.?[0..generated.len];
    const a = std.testing.allocator;
    var combo: std.ArrayList(u8) = .empty;
    defer combo.deinit(a);
    // Group 0's only share (frame 0) plus two of group 1's three (frames 1, 3).
    for ([_]usize{ 0, 1, 3 }) |i| {
        try combo.appendSlice(a, nthShareFrame(buf, i));
    }

    const combined = zsss_slip39_combine(combo.items.ptr, combo.items.len, null, 0);
    defer zsss_free(combined);
    try std.testing.expectEqual(ZSSS_OK, combined.error_code);
    try std.testing.expectEqualSlices(u8, &master_secret, combined.data.?[0..combined.len]);
}

// Mixing shares of two DIFFERENT secrets with overlapping indices must also be
// rejected cleanly (duplicate-index / secret-id mismatch), never crash.
test "FFI combine cross-secret shares with colliding indices returns error" {
    zsss_init();

    const secret_a = "AAAAAAAAAAAAAAAA";
    const secret_b = "BBBBBBBBBBBBBBBB";
    const split_a = zsss_split(secret_a.ptr, secret_a.len, 3, 5);
    defer zsss_free(split_a);
    const split_b = zsss_split(secret_b.ptr, secret_b.len, 3, 5);
    defer zsss_free(split_b);

    const a = std.testing.allocator;
    var combo: std.ArrayList(u8) = .empty;
    defer combo.deinit(a);
    // Full concatenation -> indices 1..5 appear twice -> duplicate index.
    try combo.appendSlice(a, split_a.data.?[0..split_a.len]);
    try combo.appendSlice(a, split_b.data.?[0..split_b.len]);

    const result = zsss_combine(combo.items.ptr, combo.items.len);
    defer zsss_free(result);
    try std.testing.expect(result.error_code != ZSSS_OK);
}
