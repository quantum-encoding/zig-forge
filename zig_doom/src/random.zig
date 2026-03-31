//! zig_doom/src/random.zig
//!
//! DOOM's deterministic pseudo-random number generator.
//! Translated from: linuxdoom-1.10/m_random.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM uses two independent PRNG streams (M_Random for UI/misc, P_Random for playsim)
//! both reading from the same 256-byte table but with separate indices.
//! This separation ensures demo playback stays deterministic regardless of menu activity.

const std = @import("std");

// DOOM's exact random number table — 256 entries
const rndtable = [256]u8{
    0,   8,   109, 220, 222, 241, 149, 107, 75,  248, 254, 140, 16,  66,  74,  21,
    211, 47,  80,  242, 154, 27,  205, 128, 161, 89,  77,  36,  95,  110, 85,  48,
    212, 140, 211, 249, 22,  79,  200, 50,  28,  188, 52,  140, 202, 120, 68,  145,
    62,  70,  184, 190, 91,  197, 152, 224, 149, 104, 25,  178, 252, 182, 202, 182,
    141, 197, 4,   81,  181, 242, 145, 42,  39,  227, 156, 198, 225, 193, 219, 93,
    122, 175, 249, 0,   175, 143, 70,  239, 46,  246, 163, 53,  163, 109, 168, 135,
    2,   235, 25,  92,  20,  145, 138, 77,  69,  166, 78,  176, 173, 212, 166, 113,
    94,  161, 41,  50,  239, 49,  111, 164, 70,  60,  2,   37,  171, 75,  136, 156,
    11,  56,  42,  146, 138, 229, 73,  146, 77,  61,  98,  196, 135, 106, 63,  197,
    195, 86,  96,  203, 113, 101, 170, 247, 181, 113, 80,  250, 108, 7,   255, 237,
    129, 226, 79,  107, 112, 166, 103, 241, 24,  223, 239, 120, 198, 58,  60,  82,
    128, 3,   184, 66,  143, 224, 145, 224, 81,  206, 163, 45,  63,  90,  168, 114,
    59,  33,  159, 95,  28,  139, 123, 98,  125, 196, 15,  70,  194, 253, 54,  14,
    109, 226, 71,  17,  161, 93,  186, 87,  244, 138, 20,  52,  123, 204, 26,  60,
    98,  55,  75,  185, 120, 252, 233, 158, 196, 46,  187, 150, 121, 180, 209, 0,
    176, 105, 71,  142, 118, 245, 103, 130, 111, 189, 48,  151, 237, 149, 56,  87,
};

var prnd_index: u8 = 0; // P_Random index (playsim — deterministic for demos)
var rnd_index: u8 = 0; // M_Random index (UI/misc)

/// P_Random — playsim random, deterministic for demo compatibility
pub fn pRandom() u8 {
    prnd_index +%= 1;
    return rndtable[prnd_index];
}

/// M_Random — UI/misc random
pub fn mRandom() u8 {
    rnd_index +%= 1;
    return rndtable[rnd_index];
}

/// Clear both PRNG states (called at level start for demo sync)
pub fn clearRandom() void {
    rnd_index = 0;
    prnd_index = 0;
}

/// Get P_Random as signed (-255..255) — used for spread/scatter
pub fn pSubRandom() i32 {
    const a: i32 = pRandom();
    const b: i32 = pRandom();
    return a - b;
}

test "prng sequence matches doom" {
    clearRandom();
    // After clear, first pRandom reads index 1
    try std.testing.expectEqual(@as(u8, 8), pRandom());
    try std.testing.expectEqual(@as(u8, 109), pRandom());
    try std.testing.expectEqual(@as(u8, 220), pRandom());
    try std.testing.expectEqual(@as(u8, 222), pRandom());
}

test "prng independence" {
    clearRandom();
    const p1 = pRandom(); // advances prnd_index
    const m1 = mRandom(); // advances rnd_index independently
    _ = pRandom(); // should still be sequential
    try std.testing.expectEqual(@as(u8, 8), p1);
    try std.testing.expectEqual(@as(u8, 8), m1);
}

test "prng wraps at 256" {
    clearRandom();
    // Call 256 times to wrap
    for (0..256) |_| {
        _ = pRandom();
    }
    // Index wrapped to 0, next read is index 1 again
    try std.testing.expectEqual(@as(u8, 8), pRandom());
}
