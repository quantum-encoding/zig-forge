//! The Windows CSPRNG for zsss: `BCryptGenRandom` with the system-preferred
//! RNG (bcrypt.dll), the documented Windows API for key-grade random bytes.
//! Windows has no getrandom, arc4random or /dev/urandom, which the other
//! platforms' branches of `fillRandomBytes` use.

const std = @import("std");
const builtin = @import("builtin");

const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x0000_0002;

extern "bcrypt" fn BCryptGenRandom(
    algorithm: ?*anyopaque,
    buffer: [*]u8,
    len: u32,
    flags: u32,
) callconv(.winapi) i32;

/// Fills all of `buf` from the OS CSPRNG, or returns false. The call takes a
/// 32-bit length, so a larger buffer is filled in pieces.
pub fn fill(buf: []u8) bool {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n: u32 = @intCast(@min(buf.len - filled, std.math.maxInt(u32)));
        // An NTSTATUS: 0 is STATUS_SUCCESS, anything else is a failure.
        if (BCryptGenRandom(null, buf.ptr + filled, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            return false;
        }
        filled += n;
    }
    return true;
}

test "fill writes fresh random bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    try std.testing.expect(fill(&a));
    try std.testing.expect(fill(&b));
    // 2^-256 chance of a false failure for each.
    try std.testing.expect(!std.mem.allEqual(u8, &a, 0));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(fill(&.{}));
}
