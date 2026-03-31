//! Cross-Platform Cryptographic Random Number Generator
//!
//! Provides platform-specific secure random byte generation for:
//! - WASM: imports seedRandom from JS host (crypto.getRandomValues)
//! - macOS/iOS: arc4random_buf (BSD)
//! - Linux/Android: getrandom syscall (kernel 3.17+)
//! - Windows: BCryptGenRandom (Vista+)
//!
//! All implementations are cryptographically secure and suitable for key generation.
//!
//! Usage:
//!   const rng = @import("rng.zig");
//!   var buf: [32]u8 = undefined;
//!   rng.fillSecureRandom(&buf);

const std = @import("std");
const builtin = @import("builtin");

/// Error type for RNG failures
pub const RngError = error{
    /// System RNG unavailable or failed
    SystemRngFailed,
    /// Insufficient entropy available
    InsufficientEntropy,
    /// Platform not supported
    UnsupportedPlatform,
};

/// Fill buffer with cryptographically secure random bytes.
/// This is the primary interface - use this function.
///
/// Platform implementations:
/// - macOS/iOS/BSD: arc4random_buf (always succeeds, no seeding needed)
/// - Linux/Android: getrandom(2) syscall with GRND_RANDOM flag
/// - Windows: BCryptGenRandom with BCRYPT_USE_SYSTEM_PREFERRED_RNG
///
/// Panics if the system RNG is unavailable (should never happen on modern systems).
pub fn fillSecureRandom(buf: []u8) void {
    fillSecureRandomSafe(buf) catch |err| {
        @panic(switch (err) {
            RngError.SystemRngFailed => "System RNG failed - this should never happen",
            RngError.InsufficientEntropy => "Insufficient entropy - system not ready",
            RngError.UnsupportedPlatform => "Platform RNG not implemented",
        });
    };
}

/// Safe version that returns errors instead of panicking.
/// Use this if you need to handle RNG failures gracefully.
pub fn fillSecureRandomSafe(buf: []u8) RngError!void {
    if (buf.len == 0) return;

    switch (builtin.cpu.arch) {
        .wasm32, .wasm64 => {
            fillWasmRandom(buf);
        },
        else => switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                fillArc4Random(buf);
            },
            .freebsd, .netbsd, .openbsd, .dragonfly => {
                fillArc4Random(buf);
            },
            .linux => {
                try fillGetrandom(buf);
            },
            .windows => {
                try fillBCryptGenRandom(buf);
            },
            else => {
                // Fallback: try getrandom, then /dev/urandom
                fillGetrandom(buf) catch {
                    try fillDevUrandom(buf);
                };
            },
        },
    }
}

// ============================================================================
// Platform-Specific Implementations
// ============================================================================

/// WASM: import seedRandom from JS host
/// The host must provide an "env" import with:
///   seedRandom(ptr: i32, len: i32) -> void
/// which fills [ptr..ptr+len] with crypto-secure random bytes.
///
/// Cloudflare Workers JS glue:
///   env: { seedRandom: (ptr, len) => {
///     crypto.getRandomValues(new Uint8Array(wasm.memory.buffer, ptr, len));
///   }}
fn fillWasmRandom(buf: []u8) void {
    const seedRandom = struct {
        extern "env" fn seedRandom(ptr: [*]u8, len: usize) void;
    }.seedRandom;
    seedRandom(buf.ptr, buf.len);
}

/// macOS/BSD: arc4random_buf
/// - No initialization needed
/// - Cannot fail
/// - Automatically reseeds from kernel entropy
fn fillArc4Random(buf: []u8) void {
    // Declare arc4random_buf directly to avoid @cImport issues with cross-compilation
    const arc4random_buf = struct {
        extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
    }.arc4random_buf;
    arc4random_buf(buf.ptr, buf.len);
}

/// Linux: getrandom(2) syscall
/// - Available since kernel 3.17 (2014)
/// - Blocks until entropy pool is initialized
/// - Returns -1 on error with errno set
fn fillGetrandom(buf: []u8) RngError!void {
    const GRND_RANDOM: c_uint = 0x0002; // Use /dev/random (blocking, higher quality)
    const GRND_NONBLOCK: c_uint = 0x0001;
    _ = GRND_NONBLOCK;

    // Use the syscall directly for maximum compatibility
    const SYS_getrandom: usize = switch (builtin.cpu.arch) {
        .x86_64 => 318,
        .aarch64 => 278,
        .arm => 384,
        .x86 => 355,
        .riscv64 => 278,
        else => @compileError("getrandom syscall number not defined for this architecture"),
    };

    var remaining = buf;
    while (remaining.len > 0) {
        const result = std.os.linux.syscall3(
            @enumFromInt(SYS_getrandom),
            @intFromPtr(remaining.ptr),
            remaining.len,
            GRND_RANDOM,
        );

        const signed_result: isize = @bitCast(result);
        if (signed_result < 0) {
            const errno: std.os.linux.E = @enumFromInt(-signed_result);
            switch (errno) {
                .INTR => continue, // Interrupted, retry
                .NOSYS => return RngError.UnsupportedPlatform, // Syscall not available
                else => return RngError.SystemRngFailed,
            }
        }

        const bytes_read: usize = @intCast(signed_result);
        if (bytes_read == 0) {
            return RngError.InsufficientEntropy;
        }
        remaining = remaining[bytes_read..];
    }
}

/// Windows: BCryptGenRandom
/// - Available since Windows Vista
/// - Uses system preferred RNG (CNG)
fn fillBCryptGenRandom(buf: []u8) RngError!void {
    // Windows API types
    const NTSTATUS = i32;
    const ULONG = u32;
    const PUCHAR = [*]u8;
    const BCRYPT_ALG_HANDLE = ?*anyopaque;

    const BCRYPT_USE_SYSTEM_PREFERRED_RNG: ULONG = 0x00000002;
    const STATUS_SUCCESS: NTSTATUS = 0;

    // Import BCryptGenRandom from bcrypt.dll
    // Use winapi calling convention for Windows API
    const BCryptGenRandom = struct {
        extern "bcrypt" fn BCryptGenRandom(
            hAlgorithm: BCRYPT_ALG_HANDLE,
            pbBuffer: PUCHAR,
            cbBuffer: ULONG,
            dwFlags: ULONG,
        ) callconv(std.builtin.CallingConvention.winapi) NTSTATUS;
    }.BCryptGenRandom;

    const status = BCryptGenRandom(
        null, // Use system preferred RNG
        buf.ptr,
        @intCast(buf.len),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG,
    );

    if (status != STATUS_SUCCESS) {
        return RngError.SystemRngFailed;
    }
}

/// Fallback: /dev/urandom
/// - Works on most Unix-like systems
/// - Should only be used as last resort
fn fillDevUrandom(buf: []u8) RngError!void {
    const file = std.fs.openFileAbsolute("/dev/urandom", .{ .mode = .read_only }) catch {
        return RngError.SystemRngFailed;
    };
    defer file.close();

    var remaining = buf;
    while (remaining.len > 0) {
        const bytes_read = file.read(remaining) catch {
            return RngError.SystemRngFailed;
        };
        if (bytes_read == 0) {
            return RngError.InsufficientEntropy;
        }
        remaining = remaining[bytes_read..];
    }
}

// ============================================================================
// Tests
// ============================================================================

test "fillSecureRandom produces non-zero output" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    fillSecureRandom(&buf1);
    fillSecureRandom(&buf2);

    // Should not be all zeros
    var all_zero = true;
    for (buf1) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);

    // Two calls should produce different output
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "fillSecureRandom handles empty buffer" {
    var buf: [0]u8 = undefined;
    fillSecureRandom(&buf); // Should not crash
}

test "fillSecureRandom handles large buffer" {
    var buf: [4096]u8 = undefined;
    fillSecureRandom(&buf);

    // Should have reasonable entropy (not all same value)
    var histogram: [256]usize = [_]usize{0} ** 256;
    for (buf) |b| {
        histogram[b] += 1;
    }

    // No single byte value should appear more than 100 times in 4096 bytes
    // (statistically extremely unlikely for real random data)
    var max_count: usize = 0;
    for (histogram) |count| {
        if (count > max_count) max_count = count;
    }
    try std.testing.expect(max_count < 100);
}

test "fillSecureRandomSafe returns errors correctly" {
    // This test just ensures the safe version compiles and can be called
    var buf: [32]u8 = undefined;
    // fillSecureRandomSafe should succeed on supported platforms
    fillSecureRandomSafe(&buf) catch |err| {
        // If it fails, it should be one of our expected errors
        try std.testing.expect(err == RngError.SystemRngFailed or
            err == RngError.InsufficientEntropy or
            err == RngError.UnsupportedPlatform);
        return;
    };
    // If we get here, it succeeded - verify buffer was modified
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    // Should have non-zero bytes (extremely unlikely to be all zeros)
    try std.testing.expect(!all_zero);
}
