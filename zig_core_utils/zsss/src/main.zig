//! zsss - Shamir Secret Sharing
//!
//! Cryptographically secure secret splitting using Shamir's Secret Sharing scheme
//! over GF(2^8). Information-theoretically secure - k-1 shares reveal zero information.
//!
//! Usage:
//!   zsss split -t 3 -n 5 -i secret.bin -o shares/      # Split into 5 shares, need 3 to recover
//!   zsss combine -s share1.dat -s share3.dat -s share5.dat -o recovered.bin
//!   zsss verify -s share1.dat                          # Verify share checksum
//!
//! Security:
//!   - Uses GF(2^8) finite field arithmetic (same as SLIP-39)
//!   - Cryptographic RNG for polynomial coefficients
//!   - CRC32 checksum for share integrity
//!   - Constant-time field operations (table lookups)

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");
const slip39 = @import("slip39.zig");
const stego = @import("stego.zig");
const ticket = @import("ticket.zig");

/// Cross-platform cryptographic random bytes
fn fillRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            // Use arc4random_buf on BSD-derived systems
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            // Use getrandom on Linux
            var filled: usize = 0;
            while (filled < buf.len) {
                const rc = std.c.getrandom(buf.ptr + filled, buf.len - filled, 0);
                if (rc >= 0) {
                    filled += @intCast(rc);
                } else {
                    // Fallback: if getrandom fails, try reading from /dev/urandom
                    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
                    if (fd >= 0) {
                        defer _ = std.c.close(fd);
                        while (filled < buf.len) {
                            const n = std.c.read(fd, buf.ptr + filled, buf.len - filled);
                            if (n <= 0) break;
                            filled += @intCast(n);
                        }
                    }
                    break;
                }
            }
        },
        else => {
            // Generic fallback using /dev/urandom
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

/// GF(2^8) Finite Field Arithmetic
/// Irreducible polynomial: x^8 + x^4 + x^3 + x + 1 (0x11B)
pub const GF256 = struct {
    /// Exponentiation table: exp_table[i] = g^i where g=0x03 is the generator
    var exp_table: [256]u8 = undefined;
    /// Logarithm table: log_table[x] = i where g^i = x
    var log_table: [256]u8 = undefined;
    var initialized: bool = false;

    /// Initialize the lookup tables (idempotent)
    pub fn init() void {
        if (initialized) return;

        // Generate tables using generator 0x03
        var x: u16 = 1;
        for (0..255) |i| {
            exp_table[i] = @intCast(x);
            log_table[@as(usize, @intCast(x))] = @intCast(i);

            // Multiply by generator 0x03 = x + 1
            // x * 0x03 = x * (x + 1) = x^2 + x
            x = x ^ (x << 1);
            if (x & 0x100 != 0) {
                x ^= 0x11B; // Reduce by irreducible polynomial
            }
        }
        exp_table[255] = exp_table[0]; // Wrap around for convenience
        log_table[0] = 0; // Convention: log(0) = 0, but multiply handles 0 specially

        initialized = true;
    }

    /// Addition in GF(2^8) is XOR
    pub inline fn add(a: u8, b: u8) u8 {
        return a ^ b;
    }

    /// Subtraction in GF(2^8) is also XOR (same as addition)
    pub inline fn sub(a: u8, b: u8) u8 {
        return a ^ b;
    }

    /// Multiplication using log/exp tables: a * b = g^(log(a) + log(b))
    pub fn multiply(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        const log_a: u16 = log_table[a];
        const log_b: u16 = log_table[b];
        const log_result = (log_a + log_b) % 255;
        return exp_table[@intCast(log_result)];
    }

    /// Division: a / b = a * b^(-1) = g^(log(a) - log(b))
    pub fn divide(a: u8, b: u8) u8 {
        if (a == 0) return 0;
        if (b == 0) @panic("GF256: division by zero");
        const log_a: u16 = log_table[a];
        const log_b: u16 = log_table[b];
        // Add 255 before subtraction to handle wraparound
        const log_result = (log_a + 255 - log_b) % 255;
        return exp_table[@intCast(log_result)];
    }

    /// Multiplicative inverse: a^(-1) = g^(255 - log(a))
    pub fn inverse(a: u8) u8 {
        if (a == 0) @panic("GF256: inverse of zero");
        const log_a: u16 = log_table[a];
        return exp_table[@intCast(255 - log_a)];
    }

    /// Power: a^n using repeated squaring
    pub fn power(base: u8, exp: u8) u8 {
        if (exp == 0) return 1;
        if (base == 0) return 0;
        const log_base: u16 = log_table[base];
        const log_result = (log_base * @as(u16, exp)) % 255;
        return exp_table[@intCast(log_result)];
    }
};

/// Share structure with metadata
pub const Share = struct {
    /// Share format version (for future compatibility)
    version: u8 = 1,
    /// Threshold (k) - minimum shares needed to recover
    threshold: u8,
    /// Total shares (n) created
    total_shares: u8,
    /// This share's index (1-255)
    index: u8,
    /// Secret identifier (first 4 bytes of SHA256(secret))
    secret_id: [4]u8,
    /// The share data (y-values for this x-coordinate)
    data: []u8,
    /// CRC32 checksum of all above fields
    checksum: u32,

    /// Serialize share to bytes
    pub fn serialize(self: *const Share, allocator: Allocator) ![]u8 {
        // Format: version(1) + threshold(1) + total(1) + index(1) + secret_id(4) + data_len(4) + data + checksum(4)
        const header_size = 1 + 1 + 1 + 1 + 4 + 4;
        const total_size = header_size + self.data.len + 4;

        var buffer = try allocator.alloc(u8, total_size);
        var pos: usize = 0;

        buffer[pos] = self.version;
        pos += 1;
        buffer[pos] = self.threshold;
        pos += 1;
        buffer[pos] = self.total_shares;
        pos += 1;
        buffer[pos] = self.index;
        pos += 1;

        @memcpy(buffer[pos .. pos + 4], &self.secret_id);
        pos += 4;

        // Data length as 4-byte little-endian
        const data_len: u32 = @intCast(self.data.len);
        buffer[pos] = @intCast(data_len & 0xFF);
        buffer[pos + 1] = @intCast((data_len >> 8) & 0xFF);
        buffer[pos + 2] = @intCast((data_len >> 16) & 0xFF);
        buffer[pos + 3] = @intCast((data_len >> 24) & 0xFF);
        pos += 4;

        @memcpy(buffer[pos .. pos + self.data.len], self.data);
        pos += self.data.len;

        // Compute checksum over everything before it
        const crc = std.hash.Crc32.hash(buffer[0..pos]);
        buffer[pos] = @intCast(crc & 0xFF);
        buffer[pos + 1] = @intCast((crc >> 8) & 0xFF);
        buffer[pos + 2] = @intCast((crc >> 16) & 0xFF);
        buffer[pos + 3] = @intCast((crc >> 24) & 0xFF);

        return buffer;
    }

    /// Deserialize share from bytes
    pub fn deserialize(allocator: Allocator, bytes: []const u8) !Share {
        if (bytes.len < 16) return error.ShareTooShort;

        var pos: usize = 0;

        const version = bytes[pos];
        pos += 1;
        if (version != 1) return error.UnsupportedVersion;

        const threshold = bytes[pos];
        pos += 1;
        const total_shares = bytes[pos];
        pos += 1;
        const index = bytes[pos];
        pos += 1;

        var secret_id: [4]u8 = undefined;
        @memcpy(&secret_id, bytes[pos .. pos + 4]);
        pos += 4;

        // Read data length
        const data_len: u32 = @as(u32, bytes[pos]) |
            (@as(u32, bytes[pos + 1]) << 8) |
            (@as(u32, bytes[pos + 2]) << 16) |
            (@as(u32, bytes[pos + 3]) << 24);
        pos += 4;

        if (bytes.len < pos + data_len + 4) return error.ShareTooShort;

        const data = try allocator.alloc(u8, data_len);
        @memcpy(data, bytes[pos .. pos + data_len]);
        pos += data_len;

        // Read and verify checksum
        const stored_crc: u32 = @as(u32, bytes[pos]) |
            (@as(u32, bytes[pos + 1]) << 8) |
            (@as(u32, bytes[pos + 2]) << 16) |
            (@as(u32, bytes[pos + 3]) << 24);

        const computed_crc = std.hash.Crc32.hash(bytes[0..pos]);
        if (stored_crc != computed_crc) {
            allocator.free(data);
            return error.ChecksumMismatch;
        }

        return Share{
            .version = version,
            .threshold = threshold,
            .total_shares = total_shares,
            .index = index,
            .secret_id = secret_id,
            .data = data,
            .checksum = stored_crc,
        };
    }

    pub fn deinit(self: *Share, allocator: Allocator) void {
        // Zero out data before freeing (security)
        @memset(self.data, 0);
        allocator.free(self.data);
    }
};

/// Shamir Secret Sharing implementation
pub const SSS = struct {
    /// Split a secret into n shares with threshold k
    /// Returns array of Share structures
    pub fn split(
        allocator: Allocator,
        secret: []const u8,
        threshold: u8,
        num_shares: u8,
    ) ![]Share {
        if (threshold < 2) return error.ThresholdTooLow;
        if (threshold > num_shares) return error.ThresholdExceedsShares;
        if (num_shares > 255) return error.TooManyShares;
        if (secret.len == 0) return error.EmptySecret;

        GF256.init();

        // Compute secret identifier (first 4 bytes of SHA256)
        var secret_id: [4]u8 = undefined;
        var hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(secret, &hash, .{});
        @memcpy(&secret_id, hash[0..4]);

        // Allocate shares
        const shares = try allocator.alloc(Share, num_shares);
        errdefer {
            for (shares) |*share| {
                if (share.data.len > 0) {
                    allocator.free(share.data);
                }
            }
            allocator.free(shares);
        }

        // Initialize share metadata
        for (shares, 1..) |*share, x| {
            share.* = Share{
                .version = 1,
                .threshold = threshold,
                .total_shares = num_shares,
                .index = @intCast(x),
                .secret_id = secret_id,
                .data = try allocator.alloc(u8, secret.len),
                .checksum = 0,
            };
        }

        // Allocate polynomial coefficients
        var coeffs = try allocator.alloc(u8, threshold);
        defer {
            // Zero out coefficients (security)
            @memset(coeffs, 0);
            allocator.free(coeffs);
        }

        // Process each byte of the secret independently
        for (secret, 0..) |secret_byte, byte_idx| {
            // Build polynomial: f(x) = secret_byte + a1*x + a2*x^2 + ... + a(k-1)*x^(k-1)
            coeffs[0] = secret_byte; // Constant term is the secret byte

            // Generate random coefficients using cryptographic RNG
            fillRandomBytes(coeffs[1..]);

            // Evaluate polynomial at x = 1, 2, 3, ..., n to create shares
            for (shares) |*share| {
                share.data[byte_idx] = evaluatePolynomial(coeffs, share.index);
            }
        }

        // Compute checksums
        for (shares) |*share| {
            const serialized = try share.serialize(allocator);
            defer allocator.free(serialized);
            // Checksum is embedded in serialization, extract it
            const len = serialized.len;
            share.checksum = @as(u32, serialized[len - 4]) |
                (@as(u32, serialized[len - 3]) << 8) |
                (@as(u32, serialized[len - 2]) << 16) |
                (@as(u32, serialized[len - 1]) << 24);
        }

        return shares;
    }

    /// Combine k or more shares to recover the secret
    pub fn combine(allocator: Allocator, shares: []const Share) ![]u8 {
        if (shares.len == 0) return error.NoShares;
        if (shares.len < shares[0].threshold) return error.InsufficientShares;

        GF256.init();

        // Verify all shares have same parameters
        const threshold = shares[0].threshold;
        const secret_id = shares[0].secret_id;
        const data_len = shares[0].data.len;

        for (shares[1..]) |share| {
            if (share.threshold != threshold) return error.ThresholdMismatch;
            if (!mem.eql(u8, &share.secret_id, &secret_id)) return error.SecretIdMismatch;
            if (share.data.len != data_len) return error.DataLengthMismatch;
        }

        // Check for duplicate x-coordinates
        for (shares, 0..) |share_i, i| {
            for (shares[i + 1 ..]) |share_j| {
                if (share_i.index == share_j.index) return error.DuplicateShareIndex;
            }
        }

        // Allocate secret buffer
        var secret = try allocator.alloc(u8, data_len);
        errdefer allocator.free(secret);

        // Use only the first 'threshold' shares (any k shares work)
        const k = @min(shares.len, @as(usize, threshold));

        // Reconstruct each byte using Lagrange interpolation
        for (0..data_len) |byte_idx| {
            secret[byte_idx] = interpolate(shares[0..k], byte_idx);
        }

        // Verify secret ID matches
        var hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(secret, &hash, .{});
        if (!mem.eql(u8, hash[0..4], &secret_id)) {
            // Zero out and free on verification failure
            @memset(secret, 0);
            allocator.free(secret);
            return error.SecretVerificationFailed;
        }

        return secret;
    }

    /// Evaluate polynomial at point x using Horner's method
    /// f(x) = c0 + c1*x + c2*x^2 + ... = c0 + x*(c1 + x*(c2 + ...))
    fn evaluatePolynomial(coeffs: []const u8, x: u8) u8 {
        var result: u8 = 0;
        var i = coeffs.len;
        while (i > 0) {
            i -= 1;
            result = GF256.add(GF256.multiply(result, x), coeffs[i]);
        }
        return result;
    }

    /// Lagrange interpolation to find f(0)
    /// f(0) = sum_i( y_i * L_i(0) )
    /// where L_i(0) = prod_{j!=i}( x_j / (x_j - x_i) )
    fn interpolate(shares: []const Share, byte_idx: usize) u8 {
        var result: u8 = 0;

        for (shares, 0..) |share_i, i| {
            var numerator: u8 = 1;
            var denominator: u8 = 1;

            for (shares, 0..) |share_j, j| {
                if (i == j) continue;

                // numerator *= x_j
                numerator = GF256.multiply(numerator, share_j.index);

                // denominator *= (x_i - x_j) = (x_i XOR x_j) in GF(2^8)
                denominator = GF256.multiply(denominator, GF256.sub(share_i.index, share_j.index));
            }

            // L_i(0) = numerator / denominator
            const lagrange = GF256.divide(numerator, denominator);

            // result += y_i * L_i(0)
            const term = GF256.multiply(share_i.data[byte_idx], lagrange);
            result = GF256.add(result, term);
        }

        return result;
    }
};

// =============================================================================
// CLI Interface
// =============================================================================

const Config = struct {
    command: Command = .help,
    threshold: u8 = 3,
    num_shares: u8 = 5,
    input_file: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    share_files: std.ArrayList([]const u8) = .empty,
    hex_mode: bool = false,
    slip39_mode: bool = false,
    verbose: bool = false,
    allocator: Allocator = undefined,
    // Steganography options
    image_file: ?[]const u8 = null,
    password: ?[]const u8 = null,
    layer_slot: ?u8 = null, // Layer slot for multi-layer steganography (0-255)

    // Ticket options
    event_id: ?[]const u8 = null,
    attendee_list: ?[]const u8 = null, // File with attendee IDs (one per line)
    ticket_count: u16 = 1, // Number of tickets to create
    ticket_tier: ?[]const u8 = null,
    seat_prefix: ?[]const u8 = null, // e.g., "A-" for seats A-1, A-2, etc.
    password_length: u8 = 8, // Length of generated passwords

    const Command = enum {
        split,
        combine,
        verify,
        stego_embed,
        stego_extract,
        ticket_create,
        ticket_verify,
        ticket_info,
        ticket_capacity,
        help,
        version,
    };

    fn deinit(self: *Config) void {
        // Free duplicated strings
        if (self.input_file) |f| self.allocator.free(f);
        if (self.output_path) |p| self.allocator.free(p);
        if (self.image_file) |i| self.allocator.free(i);
        if (self.password) |pw| self.allocator.free(pw);
        if (self.event_id) |e| self.allocator.free(e);
        if (self.attendee_list) |a| self.allocator.free(a);
        if (self.ticket_tier) |t| self.allocator.free(t);
        if (self.seat_prefix) |s| self.allocator.free(s);
        for (self.share_files.items) |s| self.allocator.free(s);
        self.share_files.deinit(self.allocator);
    }
};

fn parseArgs(allocator: Allocator, init: std.process.Init) !Config {
    var config = Config{
        .allocator = allocator,
    };

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // Skip program name

    while (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "split")) {
            config.command = .split;
        } else if (mem.eql(u8, arg, "combine")) {
            config.command = .combine;
        } else if (mem.eql(u8, arg, "verify")) {
            config.command = .verify;
        } else if (mem.eql(u8, arg, "stego")) {
            // Parse subcommand
            const subcmd = args_iter.next() orelse return error.MissingStegoSubcommand;
            if (mem.eql(u8, subcmd, "embed")) {
                config.command = .stego_embed;
            } else if (mem.eql(u8, subcmd, "extract")) {
                config.command = .stego_extract;
            } else {
                return error.UnknownStegoSubcommand;
            }
        } else if (mem.eql(u8, arg, "ticket")) {
            // Parse ticket subcommand
            const subcmd = args_iter.next() orelse return error.MissingTicketSubcommand;
            if (mem.eql(u8, subcmd, "create")) {
                config.command = .ticket_create;
            } else if (mem.eql(u8, subcmd, "verify")) {
                config.command = .ticket_verify;
            } else if (mem.eql(u8, subcmd, "info")) {
                config.command = .ticket_info;
            } else if (mem.eql(u8, subcmd, "capacity")) {
                config.command = .ticket_capacity;
            } else {
                return error.UnknownTicketSubcommand;
            }
        } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            config.command = .help;
        } else if (mem.eql(u8, arg, "--version") or mem.eql(u8, arg, "-V")) {
            config.command = .version;
        } else if (mem.eql(u8, arg, "--image")) {
            const val = args_iter.next() orelse return error.MissingImageFile;
            config.image_file = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--password") or mem.eql(u8, arg, "-p")) {
            const val = args_iter.next() orelse return error.MissingPassword;
            config.password = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--layer") or mem.eql(u8, arg, "-l")) {
            const val = args_iter.next() orelse return error.MissingLayerValue;
            config.layer_slot = try std.fmt.parseInt(u8, val, 10);
        } else if (mem.eql(u8, arg, "--event") or mem.eql(u8, arg, "-e")) {
            const val = args_iter.next() orelse return error.MissingEventId;
            config.event_id = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--attendees")) {
            const val = args_iter.next() orelse return error.MissingAttendeeList;
            config.attendee_list = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--count") or mem.eql(u8, arg, "-c")) {
            const val = args_iter.next() orelse return error.MissingTicketCount;
            config.ticket_count = try std.fmt.parseInt(u16, val, 10);
        } else if (mem.eql(u8, arg, "--tier")) {
            const val = args_iter.next() orelse return error.MissingTier;
            config.ticket_tier = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--seat-prefix")) {
            const val = args_iter.next() orelse return error.MissingSeatPrefix;
            config.seat_prefix = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "--pwd-length")) {
            const val = args_iter.next() orelse return error.MissingPwdLength;
            config.password_length = try std.fmt.parseInt(u8, val, 10);
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--threshold")) {
            const val = args_iter.next() orelse return error.MissingThresholdValue;
            config.threshold = try std.fmt.parseInt(u8, val, 10);
        } else if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--shares")) {
            const val = args_iter.next() orelse return error.MissingSharesValue;
            config.num_shares = try std.fmt.parseInt(u8, val, 10);
        } else if (mem.eql(u8, arg, "-i") or mem.eql(u8, arg, "--input")) {
            const val = args_iter.next() orelse return error.MissingInputFile;
            config.input_file = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output")) {
            const val = args_iter.next() orelse return error.MissingOutputPath;
            config.output_path = try allocator.dupe(u8, val);
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--share")) {
            const val = args_iter.next() orelse return error.MissingShareFile;
            try config.share_files.append(allocator, try allocator.dupe(u8, val));
        } else if (mem.eql(u8, arg, "--hex")) {
            config.hex_mode = true;
        } else if (mem.eql(u8, arg, "--slip39") or mem.eql(u8, arg, "--format")) {
            if (mem.eql(u8, arg, "--format")) {
                const val = args_iter.next() orelse return error.MissingFormatValue;
                if (mem.eql(u8, val, "slip39")) {
                    config.slip39_mode = true;
                } else if (mem.eql(u8, val, "binary") or mem.eql(u8, val, "bin")) {
                    config.slip39_mode = false;
                } else {
                    return error.UnknownFormat;
                }
            } else {
                config.slip39_mode = true;
            }
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else {
            // Treat as positional argument (share file for combine)
            if (config.command == .combine or config.command == .verify) {
                try config.share_files.append(allocator, try allocator.dupe(u8, arg));
            }
        }
    }

    return config;
}

// =============================================================================
// File I/O Helpers (Zig 0.16 compatible)
// =============================================================================

fn readFileAlloc(allocator: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var data: std.ArrayListUnmanaged(u8) = .empty;
    errdefer data.deinit(allocator);

    var read_buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) break;
        const bytes_read: usize = @intCast(n);
        if (data.items.len + bytes_read > max_size) return error.FileTooBig;
        try data.appendSlice(allocator, read_buf[0..bytes_read]);
    }

    return data.toOwnedSlice(allocator);
}

fn writeFileAlloc(allocator: Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.CreateFileFailed;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data.ptr + written, data.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

extern "c" fn mkdir(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn makeDirectory(allocator: Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const result = mkdir(path_z.ptr, 0o755);
    if (result != 0) {
        const err = std.c.errno(result);
        // Ignore EEXIST (directory already exists)
        if (err != .EXIST) return error.MkdirFailed;
    }
}

fn printHelp() void {
    const help =
        \\zsss - Shamir Secret Sharing & Event Tickets
        \\
        \\Split secrets into shares using Shamir's Secret Sharing scheme.
        \\Create event tickets with up to 256 entries per image.
        \\
        \\USAGE:
        \\  zsss split -t <threshold> -n <shares> -i <input> -o <output_dir> [--slip39]
        \\  zsss combine -s <share1> -s <share2> ... -o <output>
        \\  zsss verify -s <share>
        \\  zsss stego embed --image <png> -i <data> -o <output.png> [-p password] [-l layer]
        \\  zsss stego extract --image <png> -o <output> [-p password] [-l layer]
        \\  zsss ticket create --image <png> --event <id> -c <count> -o <output>
        \\  zsss ticket verify --image <png> -p <password>
        \\  zsss ticket info --image <png> -p <password>
        \\  zsss ticket capacity --image <png>
        \\
        \\COMMANDS:
        \\  split            Split a secret into n shares with threshold k
        \\  combine          Recover secret from k or more shares
        \\  verify           Verify share integrity (checksum)
        \\  stego embed      Embed data into a PNG image using LSB steganography
        \\  stego extract    Extract hidden data from a PNG image
        \\  ticket create    Create batch tickets embedded in image (up to 256)
        \\  ticket verify    Verify a ticket with password (for gate entry)
        \\  ticket info      Show full ticket details
        \\  ticket capacity  Check how many tickets an image can hold
        \\
        \\OPTIONS:
        \\  -t, --threshold <k>   Minimum shares needed to recover (default: 3)
        \\  -n, --shares <n>      Total number of shares to create (default: 5)
        \\  -i, --input <file>    Input secret file (or data to embed for stego)
        \\  -o, --output <path>   Output file or directory
        \\  -s, --share <file>    Share file (can be repeated)
        \\  --image <png>         PNG image file (for steganography/tickets)
        \\  -p, --password <pwd>  Password for encryption or ticket access
        \\  -l, --layer <0-255>   Layer slot for multi-layer embedding
        \\  -e, --event <id>      Event identifier for tickets
        \\  -c, --count <n>       Number of tickets to create (max 256)
        \\  --tier <name>         Ticket tier (e.g., "VIP", "General")
        \\  --seat-prefix <str>   Seat prefix (e.g., "A-" for A-1, A-2, ...)
        \\  --pwd-length <n>      Generated password length (default: 8)
        \\  --hex                 Output shares in hex format
        \\  --slip39              Output shares as SLIP-39 mnemonics
        \\  -v, --verbose         Verbose output
        \\  -h, --help            Show this help
        \\  -V, --version         Show version
        \\
        \\EXAMPLES:
        \\  # Split seed.bin into 5 shares, need 3 to recover
        \\  zsss split -t 3 -n 5 -i seed.bin -o ./shares/
        \\
        \\  # Recover using any 3 shares
        \\  zsss combine -s shares/share-1.sss -s shares/share-3.sss -s shares/share-5.sss -o recovered.bin
        \\
        \\  # Hide a share inside a PNG image
        \\  zsss stego embed --image vacation.png -i shares/share-1.sss -o photo1.png -p "secret"
        \\
        \\  # Extract hidden share from PNG
        \\  zsss stego extract --image photo1.png -o extracted.sss -p "secret"
        \\
        \\  # Create 100 event tickets (each person gets unique password)
        \\  zsss ticket create --image poster.png --event "CONCERT-2026" -c 100 -o concert_tickets
        \\
        \\  # Verify ticket at event entry (scanner uses this)
        \\  zsss ticket verify --image concert_tickets.png -p "Abc12345"
        \\
        \\  # Check image capacity before creating tickets
        \\  zsss ticket capacity --image poster.png
        \\
        \\  # Create VIP tickets with seat assignments
        \\  zsss ticket create --image vip_poster.png --event "VIP-2026" -c 50 --tier VIP --seat-prefix "VIP-" -o vip_tickets
        \\
        \\TICKET SYSTEM:
        \\  - One image holds up to 256 unique tickets (one per layer)
        \\  - Each attendee gets a unique password to access their ticket
        \\  - Image can be shared publicly; only password holders can use it
        \\  - Verification is instant and works offline
        \\  - Perfect for: concerts, conferences, private events, access passes
        \\
        \\SECURITY:
        \\  - Uses GF(2^8) finite field (same as SLIP-39)
        \\  - Cryptographic RNG for all random values
        \\  - AES-256-GCM encryption with HKDF key derivation
        \\  - Password-seeded pixel position scrambling
        \\  - Each layer isolated (layer N uses pixels where index % 256 == N)
        \\
        \\zsss 0.1.0 - High-performance Secret Sharing & Event Tickets in Zig
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printVersion() void {
    std.debug.print("zsss 0.1.0\n", .{});
}

fn doSplit(allocator: Allocator, config: *const Config) !void {
    const input_file = config.input_file orelse {
        std.debug.print("Error: input file required (-i)\n", .{});
        return error.MissingInput;
    };

    const output_dir = config.output_path orelse ".";

    // Read secret from file
    const secret = readFileAlloc(allocator, input_file, 1024 * 1024) catch |err| {
        std.debug.print("Error reading input file: {}\n", .{err});
        return err;
    };
    defer {
        // Zero out secret before freeing
        @memset(secret, 0);
        allocator.free(secret);
    }

    if (config.verbose) {
        std.debug.print("Splitting {d} byte secret into {d} shares (threshold: {d})\n", .{
            secret.len,
            config.num_shares,
            config.threshold,
        });
    }

    // Split the secret
    const shares = try SSS.split(allocator, secret, config.threshold, config.num_shares);
    defer {
        for (shares) |*share| {
            share.deinit(allocator);
        }
        allocator.free(shares);
    }

    // Create output directory if needed
    makeDirectory(allocator, output_dir) catch {};

    // Generate random identifier for SLIP-39 (shared across all shares)
    var identifier_bytes: [2]u8 = undefined;
    fillRandomBytes(&identifier_bytes);
    const slip39_identifier: u15 = @truncate((@as(u16, identifier_bytes[0]) << 7) | (identifier_bytes[1] >> 1));

    // Write each share to a file
    for (shares) |*share| {
        var filename_buf: [256]u8 = undefined;

        if (config.slip39_mode) {
            // SLIP-39 mnemonic output
            const filename = std.fmt.bufPrint(&filename_buf, "{s}/share-{d}.slip39", .{
                output_dir,
                share.index,
            }) catch unreachable;

            // Create SLIP-39 metadata
            const meta = slip39.ShareMetadata{
                .identifier = slip39_identifier,
                .iteration_exponent = 0, // No passphrase derivation
                .group_index = 0,
                .group_threshold = 1,
                .group_count = 1,
                .member_index = @truncate(share.index -| 1), // 0-indexed for SLIP-39
                .member_threshold = @truncate(share.threshold),
                .share_value = share.data,
            };

            // Encode to word indices
            const word_indices = try slip39.encodeToWords(allocator, meta);
            defer allocator.free(word_indices);

            // Convert to mnemonic string
            const mnemonic = try slip39.wordsToMnemonic(allocator, word_indices);
            defer allocator.free(mnemonic);

            writeFileAlloc(allocator, filename, mnemonic) catch |err| {
                std.debug.print("Error writing share: {}\n", .{err});
                return err;
            };

            if (config.verbose) {
                std.debug.print("  Created: {s} ({d} words)\n", .{ filename, word_indices.len });
            }
        } else {
            // Binary output
            const serialized = try share.serialize(allocator);
            defer allocator.free(serialized);

            const filename = std.fmt.bufPrint(&filename_buf, "{s}/share-{d}.sss", .{
                output_dir,
                share.index,
            }) catch unreachable;

            if (config.hex_mode) {
                // Write as hex
                const hex_buf = try allocator.alloc(u8, serialized.len * 2);
                defer allocator.free(hex_buf);
                const hex_chars = "0123456789abcdef";
                for (serialized, 0..) |byte, idx| {
                    hex_buf[idx * 2] = hex_chars[byte >> 4];
                    hex_buf[idx * 2 + 1] = hex_chars[byte & 0xF];
                }
                writeFileAlloc(allocator, filename, hex_buf) catch |err| {
                    std.debug.print("Error writing share: {}\n", .{err});
                    return err;
                };
            } else {
                writeFileAlloc(allocator, filename, serialized) catch |err| {
                    std.debug.print("Error writing share: {}\n", .{err});
                    return err;
                };
            }

            if (config.verbose) {
                std.debug.print("  Created: {s} ({d} bytes)\n", .{ filename, serialized.len });
            }
        }
    }

    const ext = if (config.slip39_mode) ".slip39" else ".sss";
    std.debug.print("Successfully created {d} shares in {s}/ ({s} format)\n", .{ config.num_shares, output_dir, if (config.slip39_mode) "SLIP-39 mnemonic" else "binary" });
    std.debug.print("Secret ID: {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
        shares[0].secret_id[0],
        shares[0].secret_id[1],
        shares[0].secret_id[2],
        shares[0].secret_id[3],
    });
    if (config.slip39_mode) {
        std.debug.print("SLIP-39 Identifier: {d}\n", .{slip39_identifier});
    }
    std.debug.print("Threshold: {d} of {d} shares required to recover\n", .{
        config.threshold,
        config.num_shares,
    });
    _ = ext;
}

fn doCombine(allocator: Allocator, config: *Config) !void {
    if (config.share_files.items.len == 0) {
        std.debug.print("Error: at least one share file required (-s)\n", .{});
        return error.NoShares;
    }

    const output_file = config.output_path orelse "recovered.bin";

    // Load shares
    var shares: std.ArrayList(Share) = .empty;
    defer {
        for (shares.items) |*share| {
            share.deinit(allocator);
        }
        shares.deinit(allocator);
    }

    for (config.share_files.items) |share_path| {
        const data = readFileAlloc(allocator, share_path, 1024 * 1024) catch |err| {
            std.debug.print("Error reading share file '{s}': {}\n", .{ share_path, err });
            return err;
        };
        defer allocator.free(data);

        const share = Share.deserialize(allocator, data) catch |err| {
            std.debug.print("Error parsing share file '{s}': {}\n", .{ share_path, err });
            return err;
        };

        try shares.append(allocator, share);

        if (config.verbose) {
            std.debug.print("  Loaded share {d} from {s}\n", .{ share.index, share_path });
        }
    }

    if (config.verbose) {
        std.debug.print("Combining {d} shares...\n", .{shares.items.len});
    }

    // Check threshold
    if (shares.items.len < shares.items[0].threshold) {
        std.debug.print("Error: need at least {d} shares, only have {d}\n", .{
            shares.items[0].threshold,
            shares.items.len,
        });
        return error.InsufficientShares;
    }

    // Combine shares
    const secret = SSS.combine(allocator, shares.items) catch |err| {
        std.debug.print("Error combining shares: {}\n", .{err});
        return err;
    };
    defer {
        @memset(secret, 0);
        allocator.free(secret);
    }

    // Write recovered secret
    writeFileAlloc(allocator, output_file, secret) catch |err| {
        std.debug.print("Error creating output file: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully recovered {d} byte secret to {s}\n", .{ secret.len, output_file });
}

fn doVerify(allocator: Allocator, config: *Config) !void {
    if (config.share_files.items.len == 0) {
        std.debug.print("Error: share file required (-s)\n", .{});
        return error.NoShares;
    }

    var all_valid = true;

    for (config.share_files.items) |share_path| {
        const data = readFileAlloc(allocator, share_path, 1024 * 1024) catch |err| {
            std.debug.print("{s}: ERROR - cannot read file: {}\n", .{ share_path, err });
            all_valid = false;
            continue;
        };
        defer allocator.free(data);

        const share = Share.deserialize(allocator, data) catch |err| {
            std.debug.print("{s}: INVALID - {}\n", .{ share_path, err });
            all_valid = false;
            continue;
        };
        defer {
            var mutable_share = share;
            mutable_share.deinit(allocator);
        }

        std.debug.print("{s}: VALID\n", .{share_path});
        if (config.verbose) {
            std.debug.print("  Index: {d} of {d}\n", .{ share.index, share.total_shares });
            std.debug.print("  Threshold: {d}\n", .{share.threshold});
            std.debug.print("  Secret ID: {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
                share.secret_id[0],
                share.secret_id[1],
                share.secret_id[2],
                share.secret_id[3],
            });
            std.debug.print("  Data size: {d} bytes\n", .{share.data.len});
        }
    }

    if (!all_valid) {
        return error.VerificationFailed;
    }
}

fn doStegoEmbed(allocator: Allocator, config: *const Config) !void {
    const input_file = config.input_file orelse {
        std.debug.print("Error: input file required (-i) - the data to embed\n", .{});
        return error.MissingInput;
    };

    const image_file = config.image_file orelse {
        std.debug.print("Error: image file required (--image) - the PNG carrier image\n", .{});
        return error.MissingImageFile;
    };

    const output_file = config.output_path orelse "stego_output.png";

    // Read the data to embed
    const secret_data = readFileAlloc(allocator, input_file, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading input file: {}\n", .{err});
        return err;
    };
    defer allocator.free(secret_data);

    // Read the carrier image
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    if (config.verbose) {
        std.debug.print("Embedding {d} bytes into {s}\n", .{ secret_data.len, image_file });
        if (config.password != null) {
            std.debug.print("  Using password encryption (AES-256-GCM)\n", .{});
        }
        if (config.layer_slot) |slot| {
            std.debug.print("  Using layer slot: {d}\n", .{slot});
        }
    }

    // Embed data (with layer support)
    const output_png = stego.embedInPngWithLayer(
        allocator,
        png_data,
        secret_data,
        config.password,
        config.layer_slot,
    ) catch |err| {
        std.debug.print("Error embedding data: {}\n", .{err});
        return err;
    };
    defer allocator.free(output_png);

    // Write output
    writeFileAlloc(allocator, output_file, output_png) catch |err| {
        std.debug.print("Error writing output file: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully embedded {d} bytes into {s}\n", .{ secret_data.len, output_file });
    if (config.password != null) {
        std.debug.print("Data encrypted with AES-256-GCM (password required to extract)\n", .{});
    }
    if (config.layer_slot) |slot| {
        std.debug.print("Layer slot: {d} (use same layer to extract)\n", .{slot});
    }
}

fn doStegoExtract(allocator: Allocator, config: *const Config) !void {
    const image_file = config.image_file orelse {
        std.debug.print("Error: image file required (--image) - the PNG with embedded data\n", .{});
        return error.MissingImageFile;
    };

    const output_file = config.output_path orelse "extracted_data.bin";

    // Read the stego image
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    if (config.verbose) {
        std.debug.print("Extracting data from {s}\n", .{image_file});
        if (config.password != null) {
            std.debug.print("  Using password for decryption\n", .{});
        }
        if (config.layer_slot) |slot| {
            std.debug.print("  Extracting from layer slot: {d}\n", .{slot});
        }
    }

    // Extract data (with layer support)
    const extracted = stego.extractFromPngWithLayer(
        allocator,
        png_data,
        config.password,
        config.layer_slot,
    ) catch |err| {
        switch (err) {
            stego.StegoError.InvalidMagic => {
                if (config.layer_slot) |slot| {
                    std.debug.print("Error: No hidden data found at layer {d} (invalid magic)\n", .{slot});
                } else {
                    std.debug.print("Error: No hidden data found in image (invalid magic)\n", .{});
                }
            },
            stego.StegoError.DecryptionFailed => {
                std.debug.print("Error: Decryption failed - wrong password?\n", .{});
            },
            stego.StegoError.InvalidPassword => {
                std.debug.print("Error: Data is encrypted but no password provided (-p)\n", .{});
            },
            else => {
                std.debug.print("Error extracting data: {}\n", .{err});
            },
        }
        return err;
    };
    defer allocator.free(extracted);

    // Write output
    writeFileAlloc(allocator, output_file, extracted) catch |err| {
        std.debug.print("Error writing output file: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully extracted {d} bytes to {s}\n", .{ extracted.len, output_file });
}

// =============================================================================
// Ticket Commands
// =============================================================================

fn doTicketCreate(allocator: Allocator, config: *Config) !void {
    const image_file = config.image_file orelse {
        std.debug.print("Error: --image is required for ticket create\n", .{});
        return error.MissingImageFile;
    };

    const event_id = config.event_id orelse {
        std.debug.print("Error: --event is required for ticket create\n", .{});
        return error.MissingEventId;
    };

    const output_path = config.output_path orelse "tickets_output";

    // Read input image (max 100MB for images)
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    // Check capacity
    const capacity = ticket.calculateCapacity(png_data) catch {
        std.debug.print("Error: Invalid PNG image\n", .{});
        return error.InvalidPng;
    };

    const count = @min(config.ticket_count, @as(u16, @intCast(capacity.practical_ticket_capacity)));
    if (count == 0) {
        std.debug.print("Error: Image too small for tickets (need at least 1024x1024)\n", .{});
        return error.ImageTooSmall;
    }

    if (count < config.ticket_count) {
        std.debug.print("Warning: Reducing ticket count from {d} to {d} due to image capacity\n", .{ config.ticket_count, count });
    }

    std.debug.print("Creating {d} tickets for event: {s}\n", .{ count, event_id });
    std.debug.print("Image capacity: {d} bytes per layer, {d} practical tickets\n", .{ capacity.bytes_per_layer, capacity.practical_ticket_capacity });

    // Generate tickets
    var tickets: std.ArrayList(ticket.TicketEntry) = .empty;
    defer {
        for (tickets.items) |*entry| {
            allocator.free(entry.password);
            // Free ticket data fields
            allocator.free(entry.ticket.event_id);
            allocator.free(entry.ticket.ticket_id);
            allocator.free(entry.ticket.signature);
            if (entry.ticket.seat) |s| allocator.free(s);
            if (entry.ticket.tier) |t| allocator.free(t);
        }
        tickets.deinit(allocator);
    }

    // File for password output
    var password_output: std.ArrayList(u8) = .empty;
    defer password_output.deinit(allocator);

    // Get a timestamp-like value using random bytes (good enough for ticket ID purposes)
    var timestamp_bytes: [8]u8 = undefined;
    fillRandomBytes(&timestamp_bytes);
    const now: i64 = @bitCast(timestamp_bytes);

    for (0..count) |i| {
        const layer: u8 = @intCast(i);

        // Generate ticket ID and password (ownership transferred to ticket struct)
        const ticket_id = try ticket.generateTicketId(allocator);
        const password = try ticket.generatePassword(allocator, config.password_length);

        // Build seat assignment if prefix provided (must allocate for ownership)
        const seat: ?[]const u8 = if (config.seat_prefix) |prefix| blk: {
            var seat_buf: [32]u8 = undefined;
            const seat_str = std.fmt.bufPrint(&seat_buf, "{s}{d}", .{ prefix, i + 1 }) catch break :blk null;
            break :blk try allocator.dupe(u8, seat_str);
        } else null;

        // Dupe tier for ownership
        const tier_copy: ?[]const u8 = if (config.ticket_tier) |t| try allocator.dupe(u8, t) else null;

        // Create signature (ownership transferred)
        const sig = try ticket.signTicket(allocator, ticket_id, "organizer_key");

        // Dupe event_id for ownership
        const event_copy = try allocator.dupe(u8, event_id);

        const ticket_data = ticket.TicketData{
            .event_id = event_copy,
            .ticket_id = ticket_id,
            .seat = seat,
            .tier = tier_copy,
            .issued_at = now,
            .expires_at = null,
            .metadata = null,
            .signature = sig,
        };

        try tickets.append(allocator, .{
            .ticket = ticket_data,
            .password = password,
            .layer = layer,
        });

        // Record password for output
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "Ticket {d:3}: Layer {d:3} | Password: {s} | Seat: {s}\n", .{
            i + 1,
            layer,
            password,
            seat orelse "N/A",
        }) catch continue;
        try password_output.appendSlice(allocator, line);
    }

    // Embed all tickets into image
    std.debug.print("Embedding {d} tickets into image...\n", .{ tickets.items.len });

    const result = ticket.embedTickets(allocator, png_data, tickets.items) catch |err| {
        std.debug.print("Error embedding tickets: {}\n", .{err});
        return err;
    };
    defer allocator.free(result.image_data);

    std.debug.print("Successfully embedded {d} tickets\n", .{result.tickets_embedded});

    // Write output image
    var image_output_buf: [256]u8 = undefined;
    const image_output = std.fmt.bufPrint(&image_output_buf, "{s}.png", .{output_path}) catch output_path;

    writeFileAlloc(allocator, image_output, result.image_data) catch |err| {
        std.debug.print("Error writing output image: {}\n", .{err});
        return err;
    };

    // Write passwords file
    var pwd_output_buf: [256]u8 = undefined;
    const pwd_output = std.fmt.bufPrint(&pwd_output_buf, "{s}_passwords.txt", .{output_path}) catch "passwords.txt";

    writeFileAlloc(allocator, pwd_output, password_output.items) catch |err| {
        std.debug.print("Error writing passwords file: {}\n", .{err});
        return err;
    };

    std.debug.print("\nOutput files:\n", .{});
    std.debug.print("  Image: {s}\n", .{image_output});
    std.debug.print("  Passwords: {s}\n", .{pwd_output});
    std.debug.print("\nDistribute the image publicly. Send each attendee their password privately.\n", .{});
}

fn doTicketVerify(allocator: Allocator, config: *Config) !void {
    const image_file = config.image_file orelse {
        std.debug.print("Error: --image is required for ticket verify\n", .{});
        return error.MissingImageFile;
    };

    const password = config.password orelse {
        std.debug.print("Error: --password is required for ticket verify\n", .{});
        return error.MissingPassword;
    };

    // Read image
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    // Try to extract ticket
    const result = ticket.extractTicket(allocator, png_data, password) catch |err| {
        if (err == ticket.TicketError.NoTicketFound) {
            std.debug.print("INVALID: No valid ticket found for this password\n", .{});
        } else {
            std.debug.print("Error verifying ticket: {}\n", .{err});
        }
        return err;
    };
    var ticket_data = result.ticket;
    defer ticket_data.deinit(allocator);

    // Check expiration
    if (ticket.isTicketExpired(ticket_data)) {
        std.debug.print("EXPIRED: Ticket has expired\n", .{});
        std.debug.print("  Event: {s}\n", .{ticket_data.event_id});
        std.debug.print("  Ticket ID: {s}\n", .{ticket_data.ticket_id});
        return error.TicketExpired;
    }

    std.debug.print("VALID TICKET\n", .{});
    std.debug.print("  Event: {s}\n", .{ticket_data.event_id});
    std.debug.print("  Ticket ID: {s}\n", .{ticket_data.ticket_id});
    std.debug.print("  Layer: {d}\n", .{result.layer});
    if (ticket_data.seat) |seat| {
        std.debug.print("  Seat: {s}\n", .{seat});
    }
    if (ticket_data.tier) |tier| {
        std.debug.print("  Tier: {s}\n", .{tier});
    }
}

fn doTicketInfo(allocator: Allocator, config: *Config) !void {
    const image_file = config.image_file orelse {
        std.debug.print("Error: --image is required for ticket info\n", .{});
        return error.MissingImageFile;
    };

    const password = config.password orelse {
        std.debug.print("Error: --password is required for ticket info\n", .{});
        return error.MissingPassword;
    };

    // Read image
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    // Extract ticket
    const result = ticket.extractTicket(allocator, png_data, password) catch |err| {
        if (err == ticket.TicketError.NoTicketFound) {
            std.debug.print("No ticket found for this password\n", .{});
        } else {
            std.debug.print("Error extracting ticket: {}\n", .{err});
        }
        return err;
    };
    var ticket_data = result.ticket;
    defer ticket_data.deinit(allocator);

    // Print full ticket info
    std.debug.print("Ticket Information\n", .{});
    std.debug.print("==================\n", .{});
    std.debug.print("Event ID:    {s}\n", .{ticket_data.event_id});
    std.debug.print("Ticket ID:   {s}\n", .{ticket_data.ticket_id});
    std.debug.print("Layer:       {d}\n", .{result.layer});
    std.debug.print("Issued:      {d}\n", .{ticket_data.issued_at});
    if (ticket_data.expires_at) |exp| {
        std.debug.print("Expires:     {d}\n", .{exp});
    }
    if (ticket_data.seat) |seat| {
        std.debug.print("Seat:        {s}\n", .{seat});
    }
    if (ticket_data.tier) |tier| {
        std.debug.print("Tier:        {s}\n", .{tier});
    }
    if (ticket_data.attendee_hash) |hash| {
        std.debug.print("Attendee:    {s}\n", .{hash});
    }
    std.debug.print("Signature:   {s}...\n", .{ticket_data.signature[0..@min(16, ticket_data.signature.len)]});

    const expired = ticket.isTicketExpired(ticket_data);
    std.debug.print("Status:      {s}\n", .{if (expired) "EXPIRED" else "VALID"});
}

fn doTicketCapacity(allocator: Allocator, config: *Config) !void {
    const image_file = config.image_file orelse {
        std.debug.print("Error: --image is required for ticket capacity\n", .{});
        return error.MissingImageFile;
    };

    // Read image
    const png_data = readFileAlloc(allocator, image_file, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading image file: {}\n", .{err});
        return err;
    };
    defer allocator.free(png_data);

    // Get capacity info
    const capacity = ticket.calculateCapacity(png_data) catch {
        std.debug.print("Error: Invalid PNG image\n", .{});
        return error.InvalidPng;
    };

    std.debug.print("Image Ticket Capacity\n", .{});
    std.debug.print("=====================\n", .{});
    std.debug.print("Dimensions:      {d} x {d}\n", .{ capacity.image_width, capacity.image_height });
    std.debug.print("Total pixels:    {d}\n", .{capacity.total_pixels});
    std.debug.print("Pixels/layer:    {d}\n", .{capacity.pixels_per_layer});
    std.debug.print("Bytes/layer:     {d}\n", .{capacity.bytes_per_layer});
    std.debug.print("Max layers:      {d}\n", .{capacity.max_layers});
    std.debug.print("Practical capacity: {d} tickets\n", .{capacity.practical_ticket_capacity});

    if (capacity.practical_ticket_capacity == 0) {
        std.debug.print("\nWarning: Image too small for tickets. Use at least 1024x1024.\n", .{});
    } else if (capacity.practical_ticket_capacity < 256) {
        std.debug.print("\nNote: For full 256 ticket capacity, use at least 2048x2048.\n", .{});
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        printHelp();
        std.process.exit(1);
    };
    defer config.deinit();

    switch (config.command) {
        .split => doSplit(allocator, &config) catch {
            std.process.exit(1);
        },
        .combine => doCombine(allocator, &config) catch {
            std.process.exit(1);
        },
        .verify => doVerify(allocator, &config) catch {
            std.process.exit(1);
        },
        .stego_embed => doStegoEmbed(allocator, &config) catch {
            std.process.exit(1);
        },
        .stego_extract => doStegoExtract(allocator, &config) catch {
            std.process.exit(1);
        },
        .ticket_create => doTicketCreate(allocator, &config) catch {
            std.process.exit(1);
        },
        .ticket_verify => doTicketVerify(allocator, &config) catch {
            std.process.exit(1);
        },
        .ticket_info => doTicketInfo(allocator, &config) catch {
            std.process.exit(1);
        },
        .ticket_capacity => doTicketCapacity(allocator, &config) catch {
            std.process.exit(1);
        },
        .help => printHelp(),
        .version => printVersion(),
    }
}

// =============================================================================
// Tests
// =============================================================================

test "GF256 basic operations" {
    GF256.init();

    // Addition is XOR
    try std.testing.expectEqual(@as(u8, 0), GF256.add(5, 5));
    try std.testing.expectEqual(@as(u8, 6), GF256.add(5, 3));

    // Multiplication
    try std.testing.expectEqual(@as(u8, 0), GF256.multiply(0, 100));
    try std.testing.expectEqual(@as(u8, 0), GF256.multiply(100, 0));
    try std.testing.expectEqual(@as(u8, 1), GF256.multiply(1, 1));

    // Division
    try std.testing.expectEqual(@as(u8, 1), GF256.divide(5, 5));

    // Inverse
    for (1..256) |i| {
        const x: u8 = @intCast(i);
        const inv = GF256.inverse(x);
        try std.testing.expectEqual(@as(u8, 1), GF256.multiply(x, inv));
    }
}

test "SSS split and combine" {
    const allocator = std.testing.allocator;
    GF256.init();

    const secret = "Hello, Shamir Secret Sharing!";

    // Split into 5 shares with threshold 3
    const shares = try SSS.split(allocator, secret, 3, 5);
    defer {
        for (shares) |*share| {
            share.deinit(allocator);
        }
        allocator.free(shares);
    }

    // Combine using shares 1, 3, 5 (indices 0, 2, 4)
    var subset = [_]Share{ shares[0], shares[2], shares[4] };
    const recovered = try SSS.combine(allocator, &subset);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "SSS different share combinations" {
    const allocator = std.testing.allocator;
    GF256.init();

    const secret = "Test secret data 12345";

    const shares = try SSS.split(allocator, secret, 3, 5);
    defer {
        for (shares) |*share| {
            share.deinit(allocator);
        }
        allocator.free(shares);
    }

    // Try different combinations
    const combinations = [_][3]usize{
        .{ 0, 1, 2 },
        .{ 0, 1, 3 },
        .{ 0, 2, 4 },
        .{ 1, 2, 3 },
        .{ 2, 3, 4 },
    };

    for (combinations) |combo| {
        var subset = [_]Share{ shares[combo[0]], shares[combo[1]], shares[combo[2]] };
        const recovered = try SSS.combine(allocator, &subset);
        defer allocator.free(recovered);
        try std.testing.expectEqualStrings(secret, recovered);
    }
}

test "Share serialization roundtrip" {
    const allocator = std.testing.allocator;
    GF256.init();

    const secret = "Serialization test";

    var shares = try SSS.split(allocator, secret, 2, 3);
    defer {
        for (shares) |*share| {
            share.deinit(allocator);
        }
        allocator.free(shares);
    }

    // Serialize and deserialize first share
    const serialized = try shares[0].serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Share.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(shares[0].version, deserialized.version);
    try std.testing.expectEqual(shares[0].threshold, deserialized.threshold);
    try std.testing.expectEqual(shares[0].total_shares, deserialized.total_shares);
    try std.testing.expectEqual(shares[0].index, deserialized.index);
    try std.testing.expectEqualSlices(u8, &shares[0].secret_id, &deserialized.secret_id);
    try std.testing.expectEqualSlices(u8, shares[0].data, deserialized.data);
}
