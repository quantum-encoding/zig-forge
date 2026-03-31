//! QR Code Encoder - Pure Zig Implementation
//! Implements ISO/IEC 18004 QR Code standard (versions 1-40)
//! Supports byte, numeric, and alphanumeric encoding modes
//! Includes Reed-Solomon error correction in GF(256)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error correction levels
pub const ErrorCorrectionLevel = enum(u2) {
    L = 0, // ~7% recovery
    M = 1, // ~15% recovery
    Q = 2, // ~25% recovery
    H = 3, // ~30% recovery
};

/// Encoding modes
pub const EncodingMode = enum(u4) {
    numeric = 1,
    alphanumeric = 2,
    byte = 4,
};

/// Structured append for splitting data across multiple QR codes
pub const StructuredAppend = struct {
    symbol_index: u4, // 0-15: which part this is
    total_symbols: u4, // 1-16: total parts
    parity: u8, // XOR of all data bytes
};

/// Extended Channel Interpretation
pub const EciMode = enum(u24) {
    latin1 = 3,
    shift_jis = 20,
    utf8 = 26,
    _,
};

/// QR Code configuration
pub const QrConfig = struct {
    ec_level: ErrorCorrectionLevel = .M,
    min_version: u8 = 1,
    max_version: u8 = 40,
    quiet_zone: u8 = 4, // Border modules
    mode: ?EncodingMode = null, // null = auto-detect
    structured_append: ?StructuredAppend = null,
    eci: ?EciMode = null,
};

/// Encoded QR Code matrix
pub const QrCode = struct {
    version: u8,
    size: u8, // Modules per side (17 + version * 4)
    modules: []u8, // 1 = black, 0 = white
    ec_level: ErrorCorrectionLevel,

    pub fn deinit(self: *QrCode, allocator: Allocator) void {
        allocator.free(self.modules);
        self.* = undefined;
    }

    /// Get module at (x, y)
    pub fn getModule(self: *const QrCode, x: usize, y: usize) bool {
        if (x >= self.size or y >= self.size) return false;
        return self.modules[y * @as(usize, self.size) + x] == 1;
    }
};

/// Rendered QR code image
pub const QrImage = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGB data

    pub fn deinit(self: *QrImage, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

// ============================================================================
// Galois Field GF(256) for Reed-Solomon
// ============================================================================

const GF = struct {
    // GF(256) with primitive polynomial 0x11D (x^8 + x^4 + x^3 + x^2 + 1)
    const PRIMITIVE: u16 = 0x11D;

    // Precomputed tables
    var exp_table: [512]u8 = undefined;
    var log_table: [256]u8 = undefined;
    var initialized: bool = false;

    fn init() void {
        if (initialized) return;

        var x: u16 = 1;
        for (0..255) |i| {
            exp_table[i] = @intCast(x);
            log_table[@intCast(x)] = @intCast(i);
            x <<= 1;
            if (x >= 256) x ^= PRIMITIVE;
        }
        // Extend exp_table for easier modular arithmetic
        for (255..512) |i| {
            exp_table[i] = exp_table[i - 255];
        }
        log_table[0] = 0; // log(0) undefined, but set to 0 for convenience
        initialized = true;
    }

    fn multiply(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return exp_table[@as(usize, log_table[a]) + @as(usize, log_table[b])];
    }

    fn divide(a: u8, b: u8) u8 {
        if (b == 0) @panic("Division by zero in GF(256)");
        if (a == 0) return 0;
        const diff = @as(i16, log_table[a]) - @as(i16, log_table[b]);
        const idx: usize = @intCast(@mod(diff + 255, 255));
        return exp_table[idx];
    }

    fn power(x: u8, n: u8) u8 {
        if (n == 0) return 1;
        if (x == 0) return 0;
        const idx = (@as(usize, log_table[x]) * @as(usize, n)) % 255;
        return exp_table[idx];
    }
};

// ============================================================================
// Reed-Solomon Encoder
// ============================================================================

/// Generate Reed-Solomon error correction codewords
fn generateReedSolomon(allocator: Allocator, data: []const u8, ec_count: usize) ![]u8 {
    GF.init();

    // Generate generator polynomial coefficients
    var gen = try allocator.alloc(u8, ec_count + 1);
    defer allocator.free(gen);
    @memset(gen, 0);
    gen[0] = 1;

    for (0..ec_count) |i| {
        // Multiply by (x - alpha^i)
        var j: usize = ec_count;
        while (j > 0) : (j -= 1) {
            gen[j] = gen[j - 1] ^ GF.multiply(gen[j], GF.exp_table[i]);
        }
        gen[0] = GF.multiply(gen[0], GF.exp_table[i]);
    }

    // Polynomial division
    var remainder = try allocator.alloc(u8, ec_count);
    @memset(remainder, 0);

    for (data) |byte| {
        const factor = byte ^ remainder[0];
        // Shift remainder left
        for (0..ec_count - 1) |i| {
            remainder[i] = remainder[i + 1];
        }
        remainder[ec_count - 1] = 0;
        // Add generator * factor
        for (0..ec_count) |i| {
            remainder[i] ^= GF.multiply(gen[i + 1], factor);
        }
    }

    return remainder;
}

// ============================================================================
// QR Version and Capacity Tables (Versions 1-25)
// ============================================================================

/// Data capacity for each version at each EC level (byte mode) [L, M, Q, H]
const CAPACITY_BYTE = [40][4]u16{
    .{ 17, 14, 11, 7 }, // V1
    .{ 32, 26, 20, 14 }, // V2
    .{ 53, 42, 32, 24 }, // V3
    .{ 78, 62, 46, 34 }, // V4
    .{ 106, 84, 60, 44 }, // V5
    .{ 134, 106, 74, 58 }, // V6
    .{ 154, 122, 86, 64 }, // V7
    .{ 192, 152, 108, 84 }, // V8
    .{ 230, 180, 130, 98 }, // V9
    .{ 271, 213, 151, 119 }, // V10
    .{ 321, 251, 177, 137 }, // V11
    .{ 367, 287, 203, 155 }, // V12
    .{ 425, 331, 241, 177 }, // V13
    .{ 458, 362, 258, 194 }, // V14
    .{ 520, 412, 292, 220 }, // V15
    .{ 586, 450, 322, 250 }, // V16
    .{ 644, 504, 364, 280 }, // V17
    .{ 718, 560, 394, 310 }, // V18
    .{ 792, 624, 442, 338 }, // V19
    .{ 858, 666, 482, 382 }, // V20
    .{ 929, 711, 509, 403 }, // V21
    .{ 1003, 779, 565, 439 }, // V22
    .{ 1091, 857, 611, 461 }, // V23
    .{ 1171, 911, 661, 511 }, // V24
    .{ 1273, 997, 715, 535 }, // V25
    .{ 1367, 1059, 751, 573 }, // V26
    .{ 1465, 1125, 805, 601 }, // V27
    .{ 1528, 1190, 868, 661 }, // V28
    .{ 1628, 1264, 908, 701 }, // V29
    .{ 1732, 1370, 982, 745 }, // V30
    .{ 1840, 1452, 1030, 793 }, // V31
    .{ 1952, 1538, 1112, 845 }, // V32
    .{ 2068, 1628, 1168, 901 }, // V33
    .{ 2081, 1631, 1171, 911 }, // V34
    .{ 2209, 1725, 1231, 985 }, // V35
    .{ 2323, 1812, 1286, 1033 }, // V36
    .{ 2465, 1914, 1354, 1089 }, // V37
    .{ 2611, 2034, 1426, 1139 }, // V38
    .{ 2761, 2085, 1502, 1219 }, // V39
    .{ 2894, 2181, 1582, 1273 }, // V40
};

/// Data capacity for numeric mode [L, M, Q, H]
const CAPACITY_NUMERIC = [40][4]u16{
    .{ 41, 34, 27, 17 }, // V1
    .{ 77, 63, 48, 34 }, // V2
    .{ 127, 101, 77, 58 }, // V3
    .{ 187, 149, 111, 82 }, // V4
    .{ 255, 202, 144, 106 }, // V5
    .{ 322, 255, 178, 139 }, // V6
    .{ 370, 293, 207, 154 }, // V7
    .{ 461, 365, 259, 202 }, // V8
    .{ 552, 432, 312, 235 }, // V9
    .{ 652, 513, 364, 288 }, // V10
    .{ 772, 604, 427, 331 }, // V11
    .{ 883, 691, 489, 374 }, // V12
    .{ 1022, 796, 580, 427 }, // V13
    .{ 1101, 871, 621, 468 }, // V14
    .{ 1250, 991, 703, 530 }, // V15
    .{ 1408, 1082, 775, 602 }, // V16
    .{ 1548, 1212, 876, 674 }, // V17
    .{ 1725, 1346, 948, 746 }, // V18
    .{ 1903, 1500, 1063, 813 }, // V19
    .{ 2061, 1600, 1159, 919 }, // V20
    .{ 2232, 1708, 1224, 969 }, // V21
    .{ 2409, 1872, 1358, 1056 }, // V22
    .{ 2620, 2059, 1468, 1108 }, // V23
    .{ 2812, 2188, 1588, 1228 }, // V24
    .{ 3057, 2395, 1718, 1286 }, // V25
    .{ 3283, 2544, 1804, 1380 }, // V26
    .{ 3517, 2701, 1933, 1449 }, // V27
    .{ 3669, 2857, 2085, 1590 }, // V28
    .{ 3909, 3035, 2181, 1677 }, // V29
    .{ 4158, 3289, 2358, 1782 }, // V30
    .{ 4417, 3486, 2473, 1897 }, // V31
    .{ 4686, 3693, 2670, 2022 }, // V32
    .{ 4965, 3909, 2805, 2157 }, // V33
    .{ 5253, 4134, 2949, 2301 }, // V34
    .{ 5529, 4343, 3081, 2361 }, // V35
    .{ 5836, 4588, 3244, 2524 }, // V36
    .{ 6153, 4775, 3417, 2625 }, // V37
    .{ 6479, 5039, 3599, 2735 }, // V38
    .{ 6743, 5313, 3791, 2927 }, // V39
    .{ 7089, 5596, 3993, 3057 }, // V40
};

/// Data capacity for alphanumeric mode [L, M, Q, H]
const CAPACITY_ALPHANUMERIC = [40][4]u16{
    .{ 25, 20, 16, 10 }, // V1
    .{ 47, 38, 29, 20 }, // V2
    .{ 77, 61, 47, 35 }, // V3
    .{ 114, 90, 67, 50 }, // V4
    .{ 154, 122, 87, 64 }, // V5
    .{ 195, 154, 108, 84 }, // V6
    .{ 224, 178, 125, 93 }, // V7
    .{ 279, 221, 157, 122 }, // V8
    .{ 335, 262, 189, 143 }, // V9
    .{ 395, 311, 221, 174 }, // V10
    .{ 468, 366, 259, 200 }, // V11
    .{ 535, 419, 296, 227 }, // V12
    .{ 619, 483, 352, 259 }, // V13
    .{ 667, 528, 376, 283 }, // V14
    .{ 758, 600, 426, 321 }, // V15
    .{ 854, 656, 470, 365 }, // V16
    .{ 938, 734, 531, 408 }, // V17
    .{ 1046, 816, 574, 452 }, // V18
    .{ 1153, 909, 644, 493 }, // V19
    .{ 1249, 970, 702, 557 }, // V20
    .{ 1352, 1035, 742, 587 }, // V21
    .{ 1460, 1134, 823, 640 }, // V22
    .{ 1588, 1248, 890, 672 }, // V23
    .{ 1704, 1326, 963, 744 }, // V24
    .{ 1853, 1451, 1041, 779 }, // V25
    .{ 1990, 1542, 1094, 836 }, // V26
    .{ 2132, 1637, 1172, 878 }, // V27
    .{ 2223, 1732, 1263, 964 }, // V28
    .{ 2369, 1839, 1322, 1017 }, // V29
    .{ 2520, 1994, 1429, 1080 }, // V30
    .{ 2677, 2113, 1499, 1150 }, // V31
    .{ 2840, 2238, 1618, 1226 }, // V32
    .{ 3009, 2369, 1700, 1307 }, // V33
    .{ 3183, 2506, 1787, 1394 }, // V34
    .{ 3351, 2632, 1867, 1431 }, // V35
    .{ 3537, 2780, 1966, 1530 }, // V36
    .{ 3729, 2894, 2071, 1591 }, // V37
    .{ 3927, 3054, 2181, 1658 }, // V38
    .{ 4087, 3220, 2298, 1774 }, // V39
    .{ 4296, 3391, 2420, 1852 }, // V40
};

/// Total error correction codewords per version per EC level [L, M, Q, H]
const EC_CODEWORDS = [40][4]u16{
    .{ 7, 10, 13, 17 }, // V1
    .{ 10, 16, 22, 28 }, // V2
    .{ 15, 26, 36, 44 }, // V3
    .{ 20, 36, 52, 64 }, // V4
    .{ 26, 48, 72, 88 }, // V5
    .{ 36, 64, 96, 112 }, // V6
    .{ 40, 72, 108, 130 }, // V7
    .{ 48, 88, 132, 156 }, // V8
    .{ 60, 110, 160, 192 }, // V9
    .{ 72, 130, 192, 224 }, // V10
    .{ 80, 150, 224, 264 }, // V11
    .{ 96, 176, 260, 308 }, // V12
    .{ 104, 198, 288, 352 }, // V13
    .{ 120, 216, 320, 384 }, // V14
    .{ 132, 240, 360, 432 }, // V15
    .{ 144, 280, 408, 480 }, // V16
    .{ 168, 308, 448, 532 }, // V17
    .{ 180, 338, 504, 588 }, // V18
    .{ 196, 364, 546, 650 }, // V19
    .{ 224, 416, 600, 700 }, // V20
    .{ 224, 442, 644, 750 }, // V21
    .{ 252, 476, 690, 816 }, // V22
    .{ 270, 504, 750, 900 }, // V23
    .{ 300, 560, 810, 960 }, // V24
    .{ 312, 588, 870, 1050 }, // V25
    .{ 336, 644, 952, 1116 }, // V26
    .{ 360, 700, 1020, 1190 }, // V27
    .{ 390, 728, 1050, 1264 }, // V28
    .{ 420, 784, 1140, 1344 }, // V29
    .{ 450, 812, 1200, 1440 }, // V30
    .{ 480, 868, 1290, 1530 }, // V31
    .{ 510, 924, 1350, 1620 }, // V32
    .{ 540, 980, 1440, 1710 }, // V33
    .{ 570, 1036, 1530, 1800 }, // V34
    .{ 570, 1064, 1590, 1890 }, // V35
    .{ 600, 1120, 1680, 1980 }, // V36
    .{ 630, 1204, 1770, 2100 }, // V37
    .{ 660, 1260, 1860, 2220 }, // V38
    .{ 720, 1316, 1950, 2310 }, // V39
    .{ 750, 1372, 2040, 2430 }, // V40
};

/// Block structure info: (group1_blocks, group1_data_codewords, group2_blocks, group2_data_codewords)
/// EC codewords per block = EC_CODEWORDS[v][ec] / total_blocks
const BlockInfo = struct {
    g1_blocks: u8,
    g1_data: u16,
    g2_blocks: u8,
    g2_data: u16,
    ec_per_block: u8,
};

/// Total codewords (data + EC) per version (from ISO 18004)
const TOTAL_CODEWORDS = [40]u16{
    26,   44,   70,   100,  134,  172,  196,  242,  292,  346, // V1-10
    404,  466,  532,  581,  655,  733,  815,  901,  991,  1085, // V11-20
    1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185, // V21-30
    2323, 2465, 2611, 2761, 2876, 2994, 3144, 3298, 3456, 3706, // V31-40
};

/// Get block info for a version and EC level
fn getBlockInfo(version: u8, ec_level: ErrorCorrectionLevel) BlockInfo {
    const ec_idx = @intFromEnum(ec_level);
    const total_ec: u16 = EC_CODEWORDS[version - 1][ec_idx];

    const total_cw = TOTAL_CODEWORDS[version - 1];
    const total_data_cw = total_cw - total_ec;

    const info = getBlockInfoFromSpec(version, ec_idx, total_data_cw, total_ec);
    return info;
}

/// Block info from ISO 18004 spec tables
fn getBlockInfoFromSpec(version: u8, ec_idx: usize, total_data_cw: u16, total_ec: u16) BlockInfo {
    const NUM_BLOCKS_TABLE = [40][4]u8{
        .{ 1, 1, 1, 1 }, // V1
        .{ 1, 1, 1, 1 }, // V2
        .{ 1, 1, 2, 2 }, // V3
        .{ 1, 2, 2, 4 }, // V4
        .{ 1, 2, 4, 4 }, // V5
        .{ 2, 4, 4, 4 }, // V6
        .{ 2, 4, 6, 5 }, // V7
        .{ 2, 4, 6, 6 }, // V8
        .{ 2, 5, 8, 8 }, // V9
        .{ 4, 5, 8, 8 }, // V10
        .{ 4, 5, 8, 11 }, // V11
        .{ 4, 8, 10, 11 }, // V12
        .{ 4, 9, 12, 16 }, // V13
        .{ 4, 9, 16, 16 }, // V14
        .{ 6, 10, 12, 18 }, // V15
        .{ 6, 10, 17, 16 }, // V16
        .{ 6, 11, 16, 19 }, // V17
        .{ 6, 13, 18, 21 }, // V18
        .{ 7, 14, 21, 25 }, // V19
        .{ 8, 16, 20, 25 }, // V20
        .{ 8, 17, 23, 25 }, // V21
        .{ 9, 17, 23, 34 }, // V22
        .{ 9, 18, 25, 30 }, // V23
        .{ 10, 20, 27, 32 }, // V24
        .{ 12, 21, 29, 35 }, // V25
        .{ 12, 23, 34, 37 }, // V26
        .{ 12, 25, 34, 40 }, // V27
        .{ 13, 26, 35, 42 }, // V28
        .{ 14, 28, 38, 45 }, // V29
        .{ 15, 29, 40, 48 }, // V30
        .{ 16, 31, 43, 51 }, // V31
        .{ 17, 33, 45, 54 }, // V32
        .{ 18, 35, 48, 57 }, // V33
        .{ 19, 37, 51, 60 }, // V34
        .{ 19, 38, 53, 63 }, // V35
        .{ 20, 40, 56, 66 }, // V36
        .{ 21, 43, 59, 70 }, // V37
        .{ 22, 45, 62, 74 }, // V38
        .{ 24, 47, 65, 77 }, // V39
        .{ 25, 49, 68, 81 }, // V40
    };

    const total_blocks = NUM_BLOCKS_TABLE[version - 1][ec_idx];
    const ec_per_block: u8 = @intCast(total_ec / @as(u16, total_blocks));

    // Split data codewords across blocks
    const base_data_per_block = total_data_cw / @as(u16, total_blocks);
    const remainder = total_data_cw % @as(u16, total_blocks);

    // Group 1 has (total_blocks - remainder) blocks with base_data_per_block
    // Group 2 has remainder blocks with base_data_per_block + 1
    const g1_blocks: u8 = total_blocks - @as(u8, @intCast(remainder));
    const g2_blocks: u8 = @intCast(remainder);

    return BlockInfo{
        .g1_blocks = g1_blocks,
        .g1_data = base_data_per_block,
        .g2_blocks = g2_blocks,
        .g2_data = base_data_per_block + 1,
        .ec_per_block = ec_per_block,
    };
}

/// Select minimum version that can hold data
fn selectVersion(data_len: usize, ec_level: ErrorCorrectionLevel, min_ver: u8, max_ver: u8, mode: EncodingMode) ?u8 {
    const ec_idx = @intFromEnum(ec_level);
    const cap_table = switch (mode) {
        .numeric => &CAPACITY_NUMERIC,
        .alphanumeric => &CAPACITY_ALPHANUMERIC,
        .byte => &CAPACITY_BYTE,
    };
    var version: u8 = @max(min_ver, 1);
    while (version <= @min(max_ver, 40)) : (version += 1) {
        if (cap_table[version - 1][ec_idx] >= data_len) {
            return version;
        }
    }
    return null;
}

// ============================================================================
// Alignment Pattern Positions (Versions 2-25)
// ============================================================================

/// Alignment pattern center coordinates per version
/// Version 1 has no alignment patterns
const ALIGNMENT_POSITIONS = [40][]const u8{
    &[_]u8{}, // V1: none
    &[_]u8{ 6, 18 }, // V2
    &[_]u8{ 6, 22 }, // V3
    &[_]u8{ 6, 26 }, // V4
    &[_]u8{ 6, 30 }, // V5
    &[_]u8{ 6, 34 }, // V6
    &[_]u8{ 6, 22, 38 }, // V7
    &[_]u8{ 6, 24, 42 }, // V8
    &[_]u8{ 6, 26, 46 }, // V9
    &[_]u8{ 6, 28, 50 }, // V10
    &[_]u8{ 6, 30, 54 }, // V11
    &[_]u8{ 6, 32, 58 }, // V12
    &[_]u8{ 6, 34, 62 }, // V13
    &[_]u8{ 6, 26, 46, 66 }, // V14
    &[_]u8{ 6, 26, 48, 70 }, // V15
    &[_]u8{ 6, 26, 50, 74 }, // V16
    &[_]u8{ 6, 30, 54, 78 }, // V17
    &[_]u8{ 6, 30, 56, 82 }, // V18
    &[_]u8{ 6, 30, 58, 86 }, // V19
    &[_]u8{ 6, 34, 62, 90 }, // V20
    &[_]u8{ 6, 28, 50, 72, 94 }, // V21
    &[_]u8{ 6, 26, 50, 74, 98 }, // V22
    &[_]u8{ 6, 30, 54, 78, 102 }, // V23
    &[_]u8{ 6, 28, 54, 80, 106 }, // V24
    &[_]u8{ 6, 32, 58, 84, 110 }, // V25
    &[_]u8{ 6, 30, 58, 86, 114 }, // V26
    &[_]u8{ 6, 34, 62, 90, 118 }, // V27
    &[_]u8{ 6, 26, 50, 74, 98, 122 }, // V28
    &[_]u8{ 6, 30, 54, 78, 102, 126 }, // V29
    &[_]u8{ 6, 26, 52, 78, 104, 130 }, // V30
    &[_]u8{ 6, 30, 56, 82, 108, 134 }, // V31
    &[_]u8{ 6, 34, 60, 86, 112, 138 }, // V32
    &[_]u8{ 6, 30, 58, 86, 114, 142 }, // V33
    &[_]u8{ 6, 34, 62, 90, 118, 146 }, // V34
    &[_]u8{ 6, 30, 54, 78, 102, 126, 150 }, // V35
    &[_]u8{ 6, 24, 50, 76, 102, 128, 154 }, // V36
    &[_]u8{ 6, 28, 54, 80, 106, 132, 158 }, // V37
    &[_]u8{ 6, 32, 58, 84, 110, 136, 162 }, // V38
    &[_]u8{ 6, 26, 54, 82, 110, 138, 166 }, // V39
    &[_]u8{ 6, 30, 58, 86, 114, 142, 170 }, // V40
};

/// Version info bit strings for versions 7-40 (18 bits each, BCH encoded)
const VERSION_INFO = [_]u32{
    0x07C94, // V7
    0x085BC, // V8
    0x09A99, // V9
    0x0A4D3, // V10
    0x0BBF6, // V11
    0x0C762, // V12
    0x0D847, // V13
    0x0E60D, // V14
    0x0F928, // V15
    0x10B78, // V16
    0x1145D, // V17
    0x12A17, // V18
    0x13532, // V19
    0x149A6, // V20
    0x15683, // V21
    0x168C9, // V22
    0x177EC, // V23
    0x18EC4, // V24
    0x191E1, // V25
    0x1AFAB, // V26
    0x1B08E, // V27
    0x1CC1A, // V28
    0x1D33F, // V29
    0x1ED75, // V30
    0x1F250, // V31
    0x209D5, // V32
    0x216F0, // V33
    0x228BA, // V34
    0x2379F, // V35
    0x24B0B, // V36
    0x2542E, // V37
    0x26A64, // V38
    0x27541, // V39
    0x28C69, // V40
};

// ============================================================================
// QR Matrix Operations
// ============================================================================

/// Create empty QR matrix
fn createMatrix(allocator: Allocator, version: u8) ![]u8 {
    const size: usize = 17 + @as(usize, version) * 4;
    const matrix = try allocator.alloc(u8, size * size);
    @memset(matrix, 2); // 2 = unset, 0 = white, 1 = black
    return matrix;
}

/// Place finder pattern at (x, y)
fn placeFinderPattern(matrix: []u8, size: usize, cx: usize, cy: usize) void {
    // 7x7 finder pattern
    const pattern = [7][7]u8{
        .{ 1, 1, 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0, 0, 1 },
        .{ 1, 0, 1, 1, 1, 0, 1 },
        .{ 1, 0, 1, 1, 1, 0, 1 },
        .{ 1, 0, 1, 1, 1, 0, 1 },
        .{ 1, 0, 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1, 1, 1 },
    };

    for (0..7) |dy| {
        for (0..7) |dx| {
            const x = cx + dx;
            const y = cy + dy;
            if (x < size and y < size) {
                matrix[y * size + x] = pattern[dy][dx];
            }
        }
    }

    // Separator (white border)
    for (0..8) |i| {
        // Horizontal
        if (cy > 0 or i < 8) {
            const y = if (cy == 0) 7 else cy - 1;
            const x = cx + i;
            if (x < size and y < size and i < 8) {
                if (cy == 0) {
                    if (cx + i < size) matrix[7 * size + cx + i] = 0;
                }
            }
        }
    }
}

/// Place a 5x5 alignment pattern centered at (cx, cy)
fn placeAlignmentPattern(matrix: []u8, size: usize, cx: usize, cy: usize) void {
    const pattern = [5][5]u8{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 1, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    };

    if (cx < 2 or cy < 2) return;
    const start_x = cx - 2;
    const start_y = cy - 2;

    for (0..5) |dy| {
        for (0..5) |dx| {
            const x = start_x + dx;
            const y = start_y + dy;
            if (x < size and y < size) {
                matrix[y * size + x] = pattern[dy][dx];
            }
        }
    }
}

/// Place all alignment patterns for a version
fn placeAlignmentPatterns(matrix: []u8, size: usize, version: u8) void {
    if (version < 2) return;
    const positions = ALIGNMENT_POSITIONS[version - 1];
    if (positions.len == 0) return;

    for (positions) |cy| {
        for (positions) |cx| {
            // Skip if overlapping with finder patterns
            if (cx <= 8 and cy <= 8) continue; // Top-left finder
            if (cx >= size - 8 and cy <= 8) continue; // Top-right finder
            if (cx <= 8 and cy >= size - 8) continue; // Bottom-left finder
            placeAlignmentPattern(matrix, size, cx, cy);
        }
    }
}

/// Place version info (versions 7+)
fn placeVersionInfo(matrix: []u8, size: usize, version: u8) void {
    if (version < 7) return;
    const info = VERSION_INFO[version - 7];

    for (0..18) |i| {
        const bit: u8 = if ((info >> @intCast(i)) & 1 == 1) 1 else 0;
        const row = i / 3;
        const col = i % 3;
        // Bottom-left (below top-left finder)
        matrix[(size - 11 + col) * size + row] = bit;
        // Top-right (right of top-right finder)
        matrix[row * size + (size - 11 + col)] = bit;
    }
}

/// Place timing patterns
fn placeTimingPatterns(matrix: []u8, size: usize) void {
    for (8..size - 8) |i| {
        const val: u8 = if (i % 2 == 0) 1 else 0;
        if (matrix[6 * size + i] == 2) matrix[6 * size + i] = val; // Horizontal
        if (matrix[i * size + 6] == 2) matrix[i * size + 6] = val; // Vertical
    }
}

/// Place format information
fn placeFormatInfo(matrix: []u8, size: usize, ec_level: ErrorCorrectionLevel, mask: u3) void {
    // Format string: 5 data bits + 10 BCH error correction bits
    const format_data: u5 = (@as(u5, @intFromEnum(ec_level)) << 3) | @as(u5, mask);

    // BCH(15,5) encoding
    var format_bits: u15 = @as(u15, format_data) << 10;
    var gen: u15 = 0b10100110111 << 4;

    while (gen >= 0b10100110111) {
        if (format_bits & (gen & 0x7FFF) != 0) {
            format_bits ^= gen;
        }
        gen >>= 1;
    }
    format_bits = (@as(u15, format_data) << 10) | format_bits;
    format_bits ^= 0b101010000010010; // XOR mask

    // Place format bits
    const format_positions_1 = [_][2]usize{
        .{ 0, 8 }, .{ 1, 8 }, .{ 2, 8 }, .{ 3, 8 }, .{ 4, 8 }, .{ 5, 8 },
        .{ 7, 8 }, .{ 8, 8 }, .{ 8, 7 }, .{ 8, 5 }, .{ 8, 4 }, .{ 8, 3 },
        .{ 8, 2 }, .{ 8, 1 }, .{ 8, 0 },
    };

    for (0..15) |i| {
        const bit: u8 = if ((format_bits >> @intCast(14 - i)) & 1 == 1) 1 else 0;
        const pos = format_positions_1[i];
        matrix[pos[1] * size + pos[0]] = bit;
    }

    // Second copy
    for (0..15) |i| {
        const bit: u8 = if ((format_bits >> @intCast(14 - i)) & 1 == 1) 1 else 0;
        if (i < 8) {
            matrix[(size - 1 - i) * size + 8] = bit;
        } else {
            matrix[8 * size + (size - 15 + i)] = bit;
        }
    }

    // Dark module (always black)
    matrix[(size - 8) * size + 8] = 1;
}

/// Check if position is reserved (finder, timing, format, alignment, version info)
fn isReserved(x: usize, y: usize, size: usize, version: u8) bool {
    // Finder patterns + separators
    if (x <= 8 and y <= 8) return true;
    if (x >= size - 8 and y <= 8) return true;
    if (x <= 8 and y >= size - 8) return true;

    // Timing patterns
    if (x == 6 or y == 6) return true;

    // Version info areas (versions 7+)
    if (version >= 7) {
        // Bottom-left version info (6x3 area)
        if (x < 6 and y >= size - 11 and y < size - 8) return true;
        // Top-right version info (3x6 area)
        if (y < 6 and x >= size - 11 and x < size - 8) return true;
    }

    // Alignment patterns
    if (version >= 2) {
        const positions = ALIGNMENT_POSITIONS[version - 1];
        for (positions) |cy| {
            for (positions) |cx| {
                // Skip if overlapping with finder patterns
                if (cx <= 8 and cy <= 8) continue;
                if (cx >= size - 8 and cy <= 8) continue;
                if (cx <= 8 and cy >= size - 8) continue;
                // Check 5x5 area around center
                if (cx >= 2 and cy >= 2) {
                    if (x >= cx - 2 and x <= cx + 2 and y >= cy - 2 and y <= cy + 2) return true;
                }
            }
        }
    }

    return false;
}

/// Place data bits in matrix using standard QR zigzag pattern
fn placeDataBits(matrix: []u8, size: usize, version: u8, data_bits: []const u8) void {
    var bit_idx: usize = 0;
    var x: i32 = @intCast(size - 1);
    var going_up = true;

    while (x >= 0) {
        // Skip timing pattern column
        if (x == 6) {
            x -= 1;
            continue;
        }

        const col_pair: [2]usize = .{ @intCast(x), @intCast(@max(0, x - 1)) };

        if (going_up) {
            var y: i32 = @intCast(size - 1);
            while (y >= 0) : (y -= 1) {
                for (col_pair) |cx| {
                    const uy: usize = @intCast(y);
                    if (!isReserved(cx, uy, size, version) and matrix[uy * size + cx] == 2) {
                        if (bit_idx < data_bits.len * 8) {
                            const byte_idx = bit_idx / 8;
                            const bit_pos: u3 = @intCast(7 - (bit_idx % 8));
                            const bit = (data_bits[byte_idx] >> bit_pos) & 1;
                            matrix[uy * size + cx] = bit;
                            bit_idx += 1;
                        } else {
                            matrix[uy * size + cx] = 0;
                        }
                    }
                }
            }
        } else {
            var y: usize = 0;
            while (y < size) : (y += 1) {
                for (col_pair) |cx| {
                    if (!isReserved(cx, y, size, version) and matrix[y * size + cx] == 2) {
                        if (bit_idx < data_bits.len * 8) {
                            const byte_idx = bit_idx / 8;
                            const bit_pos: u3 = @intCast(7 - (bit_idx % 8));
                            const bit = (data_bits[byte_idx] >> bit_pos) & 1;
                            matrix[y * size + cx] = bit;
                            bit_idx += 1;
                        } else {
                            matrix[y * size + cx] = 0;
                        }
                    }
                }
            }
        }

        going_up = !going_up;
        x -= 2;
    }
}

/// Apply mask pattern
fn applyMask(matrix: []u8, size: usize, version: u8, mask: u3) void {
    for (0..size) |y| {
        for (0..size) |x| {
            if (!isReserved(x, y, size, version)) {
                const should_flip = switch (mask) {
                    0 => (x + y) % 2 == 0,
                    1 => y % 2 == 0,
                    2 => x % 3 == 0,
                    3 => (x + y) % 3 == 0,
                    4 => (x / 3 + y / 2) % 2 == 0,
                    5 => (x * y) % 2 + (x * y) % 3 == 0,
                    6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
                    7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
                };
                if (should_flip) {
                    matrix[y * size + x] ^= 1;
                }
            }
        }
    }
}

/// Calculate penalty score for mask selection
fn calculatePenalty(matrix: []const u8, size: usize) u32 {
    var penalty: u32 = 0;

    // Rule 1: Consecutive modules in row/column
    for (0..size) |y| {
        var count: u32 = 1;
        for (1..size) |x| {
            if (matrix[y * size + x] == matrix[y * size + x - 1]) {
                count += 1;
            } else {
                if (count >= 5) penalty += count - 2;
                count = 1;
            }
        }
        if (count >= 5) penalty += count - 2;
    }

    // Columns
    for (0..size) |x| {
        var count: u32 = 1;
        for (1..size) |y| {
            if (matrix[y * size + x] == matrix[(y - 1) * size + x]) {
                count += 1;
            } else {
                if (count >= 5) penalty += count - 2;
                count = 1;
            }
        }
        if (count >= 5) penalty += count - 2;
    }

    // Rule 2: 2x2 blocks
    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const val = matrix[y * size + x];
            if (val == matrix[y * size + x + 1] and
                val == matrix[(y + 1) * size + x] and
                val == matrix[(y + 1) * size + x + 1])
            {
                penalty += 3;
            }
        }
    }

    // Rule 3: Finder-like patterns (10111010000 or 00001011101)
    const RULE3_A = [_]u8{ 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0 };
    const RULE3_B = [_]u8{ 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 };
    // Scan rows
    for (0..size) |y| {
        if (size >= 11) {
            for (0..size - 10) |x| {
                var match_a = true;
                var match_b = true;
                for (0..11) |k| {
                    const m = matrix[y * size + x + k];
                    if (m != RULE3_A[k]) match_a = false;
                    if (m != RULE3_B[k]) match_b = false;
                    if (!match_a and !match_b) break;
                }
                if (match_a) penalty += 40;
                if (match_b) penalty += 40;
            }
        }
    }
    // Scan columns
    for (0..size) |x| {
        if (size >= 11) {
            for (0..size - 10) |y| {
                var match_a = true;
                var match_b = true;
                for (0..11) |k| {
                    const m = matrix[(y + k) * size + x];
                    if (m != RULE3_A[k]) match_a = false;
                    if (m != RULE3_B[k]) match_b = false;
                    if (!match_a and !match_b) break;
                }
                if (match_a) penalty += 40;
                if (match_b) penalty += 40;
            }
        }
    }

    // Rule 4: Balance
    var dark_count: u32 = 0;
    for (matrix[0 .. size * size]) |m| {
        if (m == 1) dark_count += 1;
    }
    const total = size * size;
    const percent = (dark_count * 100) / @as(u32, @intCast(total));
    const deviation = if (percent > 50) percent - 50 else 50 - percent;
    penalty += (deviation / 5) * 10;

    return penalty;
}

// ============================================================================
// Data Encoding with Multi-Block Interleaving
// ============================================================================

/// Alphanumeric character value lookup (returns null for invalid chars)
fn alphanumericValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        ' ' => 36,
        '$' => 37,
        '%' => 38,
        '*' => 39,
        '+' => 40,
        '-' => 41,
        '.' => 42,
        '/' => 43,
        ':' => 44,
        else => null,
    };
}

/// Detect optimal encoding mode for data
pub fn detectOptimalMode(data: []const u8) EncodingMode {
    var all_numeric = true;
    var all_alphanum = true;
    for (data) |c| {
        if (c < '0' or c > '9') all_numeric = false;
        if (alphanumericValue(c) == null) all_alphanum = false;
        if (!all_numeric and !all_alphanum) break;
    }
    if (all_numeric and data.len > 0) return .numeric;
    if (all_alphanum and data.len > 0) return .alphanumeric;
    return .byte;
}

/// Get character count indicator bit width for a mode and version
fn getCountBits(mode: EncodingMode, version: u8) u5 {
    return switch (mode) {
        .numeric => if (version <= 9) @as(u5, 10) else if (version <= 26) @as(u5, 12) else @as(u5, 14),
        .alphanumeric => if (version <= 9) @as(u5, 9) else if (version <= 26) @as(u5, 11) else @as(u5, 13),
        .byte => if (version <= 9) @as(u5, 8) else @as(u5, 16),
    };
}

/// Encode data bytes into the full codeword sequence with multi-block RS interleaving
fn encodeDataWithBlocks(allocator: Allocator, data: []const u8, version: u8, ec_level: ErrorCorrectionLevel, mode: EncodingMode, config: QrConfig) ![]u8 {
    const bi = getBlockInfo(version, ec_level);
    const total_blocks = @as(usize, bi.g1_blocks) + @as(usize, bi.g2_blocks);
    const total_data_cw = @as(usize, bi.g1_blocks) * @as(usize, bi.g1_data) + @as(usize, bi.g2_blocks) * @as(usize, bi.g2_data);

    // Build data bitstream
    var bitstream = try allocator.alloc(u8, total_data_cw);
    @memset(bitstream, 0);
    defer allocator.free(bitstream);

    var bit_pos: usize = 0;

    // ECI header (if specified)
    if (config.eci) |eci| {
        const eci_val = @intFromEnum(eci);
        writeBits(bitstream, &bit_pos, 0b0111, 4); // ECI mode indicator
        if (eci_val <= 127) {
            writeBits(bitstream, &bit_pos, @intCast(eci_val), 8);
        } else if (eci_val <= 16383) {
            writeBits(bitstream, &bit_pos, @intCast(0x8000 | eci_val), 16);
        } else {
            writeBits(bitstream, &bit_pos, @intCast(0xC00000 | eci_val), 24);
        }
    }

    // Structured append header (if specified)
    if (config.structured_append) |sa| {
        writeBits(bitstream, &bit_pos, 0b0011, 4); // Structured append mode
        writeBits(bitstream, &bit_pos, @as(u16, sa.symbol_index), 4);
        writeBits(bitstream, &bit_pos, @as(u16, sa.total_symbols -| 1), 4);
        writeBits(bitstream, &bit_pos, @as(u16, sa.parity), 8);
    }

    // Mode indicator
    writeBits(bitstream, &bit_pos, @intFromEnum(mode), 4);

    // Character count indicator
    const count_bits = getCountBits(mode, version);
    writeBits(bitstream, &bit_pos, @intCast(data.len), count_bits);

    // Encode data based on mode
    switch (mode) {
        .byte => {
            for (data) |byte| {
                writeBits(bitstream, &bit_pos, byte, 8);
            }
        },
        .numeric => {
            var i: usize = 0;
            while (i < data.len) {
                if (i + 3 <= data.len) {
                    // 3 digits → 10 bits
                    const val: u16 = @as(u16, data[i] - '0') * 100 + @as(u16, data[i + 1] - '0') * 10 + @as(u16, data[i + 2] - '0');
                    writeBits(bitstream, &bit_pos, val, 10);
                    i += 3;
                } else if (i + 2 <= data.len) {
                    // 2 digits → 7 bits
                    const val: u16 = @as(u16, data[i] - '0') * 10 + @as(u16, data[i + 1] - '0');
                    writeBits(bitstream, &bit_pos, val, 7);
                    i += 2;
                } else {
                    // 1 digit → 4 bits
                    writeBits(bitstream, &bit_pos, @as(u16, data[i] - '0'), 4);
                    i += 1;
                }
            }
        },
        .alphanumeric => {
            var i: usize = 0;
            while (i < data.len) {
                if (i + 2 <= data.len) {
                    // 2 chars → 11 bits
                    const v1 = alphanumericValue(data[i]) orelse 0;
                    const v2 = alphanumericValue(data[i + 1]) orelse 0;
                    const val: u16 = @as(u16, v1) * 45 + @as(u16, v2);
                    writeBits(bitstream, &bit_pos, val, 11);
                    i += 2;
                } else {
                    // 1 char → 6 bits
                    const v1 = alphanumericValue(data[i]) orelse 0;
                    writeBits(bitstream, &bit_pos, @as(u16, v1), 6);
                    i += 1;
                }
            }
        },
    }

    // Terminator (up to 4 zero bits)
    const remaining_bits = total_data_cw * 8 - bit_pos;
    const term_bits = @min(remaining_bits, 4);
    writeBits(bitstream, &bit_pos, 0, @intCast(term_bits));

    // Pad to byte boundary
    if (bit_pos % 8 != 0) {
        writeBits(bitstream, &bit_pos, 0, @intCast(8 - (bit_pos % 8)));
    }

    // Pad with 0xEC, 0x11 alternation
    var pad_byte: usize = 0;
    while (bit_pos < total_data_cw * 8) {
        const pad = if (pad_byte % 2 == 0) @as(u8, 0xEC) else @as(u8, 0x11);
        writeBits(bitstream, &bit_pos, pad, 8);
        pad_byte += 1;
    }

    // Split into blocks
    const max_data_per_block = @as(usize, bi.g2_data);
    const max_ec_per_block = @as(usize, bi.ec_per_block);

    // Allocate storage for all blocks
    var block_data = try allocator.alloc([]u8, total_blocks);
    defer {
        for (block_data) |bd| allocator.free(bd);
        allocator.free(block_data);
    }
    var block_ec = try allocator.alloc([]u8, total_blocks);
    defer {
        for (block_ec) |be| allocator.free(be);
        allocator.free(block_ec);
    }

    // Split data into blocks and compute RS for each
    var data_offset: usize = 0;
    for (0..total_blocks) |b| {
        const block_size: usize = if (b < bi.g1_blocks) bi.g1_data else bi.g2_data;
        block_data[b] = try allocator.dupe(u8, bitstream[data_offset .. data_offset + block_size]);
        block_ec[b] = try generateReedSolomon(allocator, block_data[b], max_ec_per_block);
        data_offset += block_size;
    }

    // Interleave data codewords
    const total_cw = total_data_cw + total_blocks * max_ec_per_block;
    var result = try allocator.alloc(u8, total_cw);
    var out_idx: usize = 0;

    // Interleave data
    for (0..max_data_per_block) |i| {
        for (0..total_blocks) |b| {
            const block_size: usize = if (b < bi.g1_blocks) bi.g1_data else bi.g2_data;
            if (i < block_size) {
                result[out_idx] = block_data[b][i];
                out_idx += 1;
            }
        }
    }

    // Interleave EC codewords
    for (0..max_ec_per_block) |i| {
        for (0..total_blocks) |b| {
            result[out_idx] = block_ec[b][i];
            out_idx += 1;
        }
    }

    return result;
}

/// Write bits to a byte array
fn writeBits(buf: []u8, bit_pos: *usize, value: u16, count: u5) void {
    var remaining = count;
    const val = value;
    while (remaining > 0) {
        remaining -= 1;
        const byte_idx = bit_pos.* / 8;
        const bit_offset: u3 = @intCast(7 - (bit_pos.* % 8));
        if (byte_idx < buf.len) {
            if ((val >> @intCast(remaining)) & 1 == 1) {
                buf[byte_idx] |= @as(u8, 1) << bit_offset;
            }
        }
        bit_pos.* += 1;
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Encode data into QR code
pub fn encode(allocator: Allocator, data: []const u8, config: QrConfig) !QrCode {
    // Determine encoding mode
    const mode = config.mode orelse detectOptimalMode(data);

    // Select version
    const version = selectVersion(data.len, config.ec_level, config.min_version, config.max_version, mode) orelse
        return error.DataTooLong;

    const size: u8 = @intCast(17 + @as(usize, version) * 4);

    // Encode data with multi-block interleaving
    const final_data = try encodeDataWithBlocks(allocator, data, version, config.ec_level, mode, config);
    defer allocator.free(final_data);

    // Create matrix
    const matrix = try createMatrix(allocator, version);
    errdefer allocator.free(matrix);

    // Place finder patterns
    placeFinderPattern(matrix, size, 0, 0);
    placeFinderPattern(matrix, size, size - 7, 0);
    placeFinderPattern(matrix, size, 0, size - 7);

    // Place alignment patterns (v2+)
    placeAlignmentPatterns(matrix, size, version);

    // Place timing patterns
    placeTimingPatterns(matrix, size);

    // Place version info (v7+)
    placeVersionInfo(matrix, size, version);

    // Place data
    placeDataBits(matrix, size, version, final_data);

    // Try all masks and select best
    var best_mask: u3 = 0;
    var best_penalty: u32 = std.math.maxInt(u32);

    for (0..8) |mask_idx| {
        const mask: u3 = @intCast(mask_idx);
        const test_matrix = try allocator.dupe(u8, matrix);
        defer allocator.free(test_matrix);

        applyMask(test_matrix, size, version, mask);
        const penalty = calculatePenalty(test_matrix, size);

        if (penalty < best_penalty) {
            best_penalty = penalty;
            best_mask = mask;
        }
    }

    // Apply best mask
    applyMask(matrix, size, version, best_mask);

    // Place format info
    placeFormatInfo(matrix, size, config.ec_level, best_mask);

    return QrCode{
        .version = version,
        .size = size,
        .modules = matrix,
        .ec_level = config.ec_level,
    };
}

/// Render configuration with color support
pub const RenderConfig = struct {
    module_size: u8 = 4,
    quiet_zone: u8 = 4,
    fg_r: u8 = 0,
    fg_g: u8 = 0,
    fg_b: u8 = 0,
    bg_r: u8 = 255,
    bg_g: u8 = 255,
    bg_b: u8 = 255,
};

/// Render QR code to RGB image (black on white)
pub fn render(allocator: Allocator, qr: *const QrCode, module_size: u8, quiet_zone: u8) !QrImage {
    return renderWithConfig(allocator, qr, .{ .module_size = module_size, .quiet_zone = quiet_zone });
}

/// Render QR code to RGB image with custom colors
pub fn renderWithConfig(allocator: Allocator, qr: *const QrCode, config: RenderConfig) !QrImage {
    const total_size = @as(u32, qr.size) + @as(u32, config.quiet_zone) * 2;
    const img_size = total_size * @as(u32, config.module_size);
    const pixel_count = img_size * img_size * 3;

    var pixels = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(pixels);

    // Fill with background color
    var i: usize = 0;
    while (i < pixel_count) : (i += 3) {
        pixels[i + 0] = config.bg_r;
        pixels[i + 1] = config.bg_g;
        pixels[i + 2] = config.bg_b;
    }

    // Draw modules
    for (0..qr.size) |qy| {
        for (0..qr.size) |qx| {
            if (qr.getModule(qx, qy)) {
                const px_start = (@as(u32, @intCast(qx)) + config.quiet_zone) * config.module_size;
                const py_start = (@as(u32, @intCast(qy)) + config.quiet_zone) * config.module_size;

                var py: u32 = py_start;
                while (py < py_start + config.module_size) : (py += 1) {
                    var px: u32 = px_start;
                    while (px < px_start + config.module_size) : (px += 1) {
                        const offset = (py * img_size + px) * 3;
                        pixels[offset + 0] = config.fg_r;
                        pixels[offset + 1] = config.fg_g;
                        pixels[offset + 2] = config.fg_b;
                    }
                }
            }
        }
    }

    return QrImage{
        .width = img_size,
        .height = img_size,
        .pixels = pixels,
    };
}

/// One-shot encode and render
pub fn encodeAndRender(allocator: Allocator, data: []const u8, module_size: u8, config: QrConfig) !QrImage {
    var qr = try encode(allocator, data, config);
    defer qr.deinit(allocator);
    return render(allocator, &qr, module_size, config.quiet_zone);
}

// ============================================================================
// SVG Output
// ============================================================================

/// SVG rendering configuration
pub const SvgConfig = struct {
    module_size: u8 = 4,
    quiet_zone: u8 = 4,
    foreground: []const u8 = "#000000",
    background: []const u8 = "#FFFFFF",
};

/// Rendered QR code as SVG string
pub const QrSvg = struct {
    data: []u8,

    pub fn deinit(self: *QrSvg, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Render QR code as SVG string (path-based, compact output)
pub fn renderSvg(allocator: Allocator, qr: *const QrCode, config: SvgConfig) !QrSvg {
    const total_size = @as(u32, qr.size) + @as(u32, config.quiet_zone) * 2;
    const img_size = total_size * @as(u32, config.module_size);

    // Build SVG string using ArrayList
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // SVG header
    var tmp: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&tmp, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\"><rect width=\"{d}\" height=\"{d}\" fill=\"{s}\"/><path fill=\"{s}\" d=\"", .{ img_size, img_size, img_size, img_size, img_size, img_size, config.background, config.foreground }) catch return error.Overflow;
    try buf.appendSlice(allocator, header);

    // Build path data — merge consecutive horizontal modules per row
    const ms = @as(u32, config.module_size);
    const qz = @as(u32, config.quiet_zone);
    for (0..qr.size) |qy| {
        var qx: usize = 0;
        while (qx < qr.size) {
            if (qr.getModule(qx, qy)) {
                // Find run of consecutive black modules
                var run: usize = 1;
                while (qx + run < qr.size and qr.getModule(qx + run, qy)) : (run += 1) {}
                // Emit rectangle as path subpath
                const px = (@as(u32, @intCast(qx)) + qz) * ms;
                const py = (@as(u32, @intCast(qy)) + qz) * ms;
                const w = @as(u32, @intCast(run)) * ms;
                var path_buf: [64]u8 = undefined;
                const path_str = std.fmt.bufPrint(&path_buf, "M{d},{d}h{d}v{d}h-{d}z", .{ px, py, w, ms, w }) catch continue;
                try buf.appendSlice(allocator, path_str);
                qx += run;
            } else {
                qx += 1;
            }
        }
    }

    try buf.appendSlice(allocator, "\"/></svg>");

    return QrSvg{ .data = try buf.toOwnedSlice(allocator) };
}

/// One-shot encode and render to SVG
pub fn encodeAndRenderSvg(allocator: Allocator, data: []const u8, config: QrConfig, svg_config: SvgConfig) !QrSvg {
    var qr = try encode(allocator, data, config);
    defer qr.deinit(allocator);
    return renderSvg(allocator, &qr, svg_config);
}

// ============================================================================
// Tests
// ============================================================================

test "encode simple string" {
    const allocator = std.testing.allocator;

    var qr = try encode(allocator, "HELLO", .{});
    defer qr.deinit(allocator);

    try std.testing.expect(qr.version >= 1);
    try std.testing.expect(qr.size >= 21); // Version 1 = 21x21
}

test "encode bitcoin URI" {
    const allocator = std.testing.allocator;
    const uri = "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.5";

    var qr = try encode(allocator, uri, .{ .ec_level = .M });
    defer qr.deinit(allocator);

    try std.testing.expect(qr.version <= 10);
}

test "render to image" {
    const allocator = std.testing.allocator;

    var img = try encodeAndRender(allocator, "TEST", 4, .{ .quiet_zone = 2 });
    defer img.deinit(allocator);

    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height == img.width); // Square
    try std.testing.expect(img.pixels.len == img.width * img.height * 3);
}

test "deterministic output" {
    const allocator = std.testing.allocator;

    var qr1 = try encode(allocator, "SAME DATA", .{});
    defer qr1.deinit(allocator);

    var qr2 = try encode(allocator, "SAME DATA", .{});
    defer qr2.deinit(allocator);

    try std.testing.expectEqualSlices(u8, qr1.modules, qr2.modules);
}

test "GF multiply" {
    GF.init();
    try std.testing.expectEqual(@as(u8, 0), GF.multiply(0, 5));
    try std.testing.expectEqual(@as(u8, 0), GF.multiply(5, 0));
    try std.testing.expectEqual(@as(u8, 1), GF.multiply(1, 1));
}

test "encode large data uses higher version" {
    const allocator = std.testing.allocator;
    // 250 bytes needs version > 10 at EC-M (force byte mode since A is alphanumeric)
    const data = "A" ** 250;
    var qr = try encode(allocator, data, .{ .ec_level = .M, .max_version = 25, .mode = .byte });
    defer qr.deinit(allocator);
    try std.testing.expect(qr.version > 10);
    try std.testing.expect(qr.version <= 25);
}

test "version 25 capacity" {
    const allocator = std.testing.allocator;
    // Version 25 EC-L can hold 1273 bytes
    const data = "X" ** 1000;
    var qr = try encode(allocator, data, .{ .ec_level = .L, .max_version = 25 });
    defer qr.deinit(allocator);
    try std.testing.expect(qr.version <= 25);
}

test "v40 capacity" {
    const allocator = std.testing.allocator;
    // Version 40 EC-L can hold 2894 bytes in byte mode
    const data = "Z" ** 2800;
    var qr = try encode(allocator, data, .{ .ec_level = .L, .mode = .byte });
    defer qr.deinit(allocator);
    try std.testing.expect(qr.version >= 37);
    try std.testing.expect(qr.version <= 40);
}

test "numeric mode" {
    const allocator = std.testing.allocator;
    // "0123456789" is 10 digits — numeric mode is much more efficient
    var qr_num = try encode(allocator, "0123456789012345", .{ .mode = .numeric });
    defer qr_num.deinit(allocator);

    var qr_byte = try encode(allocator, "0123456789012345", .{ .mode = .byte });
    defer qr_byte.deinit(allocator);

    // Numeric mode should use same or smaller version
    try std.testing.expect(qr_num.version <= qr_byte.version);
}

test "alphanumeric mode" {
    const allocator = std.testing.allocator;
    var qr = try encode(allocator, "HELLO WORLD", .{ .mode = .alphanumeric });
    defer qr.deinit(allocator);
    try std.testing.expect(qr.version >= 1);
}

test "auto mode detection" {
    try std.testing.expectEqual(EncodingMode.numeric, detectOptimalMode("1234567890"));
    try std.testing.expectEqual(EncodingMode.alphanumeric, detectOptimalMode("HELLO WORLD"));
    try std.testing.expectEqual(EncodingMode.byte, detectOptimalMode("hello world")); // lowercase
    try std.testing.expectEqual(EncodingMode.byte, detectOptimalMode("https://example.com"));
}

test "SVG output" {
    const allocator = std.testing.allocator;
    var svg = try encodeAndRenderSvg(allocator, "TEST SVG", .{}, .{});
    defer svg.deinit(allocator);

    // SVG should start with <svg
    try std.testing.expect(svg.data.len > 20);
    try std.testing.expect(std.mem.startsWith(u8, svg.data, "<svg"));
    // Should contain path element
    try std.testing.expect(std.mem.indexOf(u8, svg.data, "<path") != null);
}

test "color rendering" {
    const allocator = std.testing.allocator;
    var qr = try encode(allocator, "COLOR", .{});
    defer qr.deinit(allocator);

    var img = try renderWithConfig(allocator, &qr, .{
        .fg_r = 255,
        .fg_g = 0,
        .fg_b = 0,
        .bg_r = 0,
        .bg_g = 0,
        .bg_b = 255,
    });
    defer img.deinit(allocator);

    try std.testing.expect(img.width > 0);
    // Check a quiet zone pixel is blue (background)
    try std.testing.expectEqual(@as(u8, 0), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[2]);
}
