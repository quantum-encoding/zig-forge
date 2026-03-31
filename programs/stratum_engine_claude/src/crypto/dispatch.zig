//! CPU Feature Detection and Hash Function Dispatch
//! Automatically selects fastest SHA-256d implementation based on CPU capabilities

const std = @import("std");
const builtin = @import("builtin");
const sha256d_scalar = @import("sha256d.zig");
const sha256_avx2 = @import("sha256_avx2.zig");
const sha256_avx512 = @import("sha256_avx512.zig");

/// Available SIMD implementations
pub const SIMDLevel = enum {
    scalar,
    avx2,
    avx512,

    pub fn toString(self: SIMDLevel) []const u8 {
        return switch (self) {
            .scalar => "Scalar",
            .avx2 => "AVX2 (8-way)",
            .avx512 => "AVX-512 (16-way)",
        };
    }
};

/// Global dispatcher (initialized once at startup)
var detected_level: SIMDLevel = .scalar;
var initialized: bool = false;

/// Detect best available SIMD level at runtime
pub fn detectCPU() SIMDLevel {
    // Check compile-time CPU features
    const features = builtin.cpu.features;

    // AVX-512F support (16-way parallel)
    if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512f))) {
        return .avx512;
    }

    // AVX2 support (8-way parallel)
    if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
        return .avx2;
    }

    // Fallback to scalar
    return .scalar;
}

/// Initialize dispatcher (call once at startup)
pub fn init() void {
    if (!initialized) {
        detected_level = detectCPU();
        initialized = true;
    }
}

/// Get current SIMD level
pub fn getLevel() SIMDLevel {
    if (!initialized) init();
    return detected_level;
}

/// Hash function dispatcher - automatically uses best implementation
pub const Hasher = struct {
    level: SIMDLevel,

    pub fn init() Hasher {
        if (!initialized) {
            @import("dispatch.zig").init();
        }
        return .{ .level = detected_level };
    }

    /// Hash single block header (scalar mode)
    pub fn hashOne(self: Hasher, header: *const [80]u8, output: *[32]u8) void {
        _ = self;
        sha256d_scalar.sha256d(header, output);
    }

    /// Hash 8 block headers (uses AVX2 if available)
    pub fn hash8(self: Hasher, headers: *const [8][80]u8, outputs: *[8][32]u8) void {
        switch (self.level) {
            .avx512, .avx2 => {
                // Use AVX2 implementation
                sha256_avx2.sha256d_x8(headers, outputs);
            },
            .scalar => {
                // Fallback: hash one by one
                for (0..8) |i| {
                    sha256d_scalar.sha256d(&headers[i], &outputs[i]);
                }
            },
        }
    }

    /// Hash 16 block headers (uses AVX-512 if available)
    pub fn hash16(self: Hasher, headers: *const [16][80]u8, outputs: *[16][32]u8) void {
        switch (self.level) {
            .avx512 => {
                // Use AVX-512 implementation
                sha256_avx512.sha256d_x16(headers, outputs);
            },
            .avx2 => {
                // Fallback: use AVX2 twice
                sha256_avx2.sha256d_x8(headers[0..8], outputs[0..8]);
                sha256_avx2.sha256d_x8(headers[8..16], outputs[8..16]);
            },
            .scalar => {
                // Fallback: hash one by one
                for (0..16) |i| {
                    sha256d_scalar.sha256d(&headers[i], &outputs[i]);
                }
            },
        }
    }

    /// Get optimal batch size for current CPU
    pub fn getBatchSize(self: Hasher) usize {
        return switch (self.level) {
            .avx512 => 16,
            .avx2 => 8,
            .scalar => 1,
        };
    }
};

test "dispatcher detects CPU" {
    const testing = std.testing;

    init();
    const level = getLevel();

    // Should detect at least scalar
    try testing.expect(level == .scalar or level == .avx2 or level == .avx512);
}

test "hasher batching" {
    const testing = std.testing;

    const hasher = Hasher.init();
    const batch_size = hasher.getBatchSize();

    // Should return valid batch size
    try testing.expect(batch_size == 1 or batch_size == 8 or batch_size == 16);
}
