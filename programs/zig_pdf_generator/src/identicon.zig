//! Ethereum Blockie-style Identicon Generator
//! Generates deterministic visual identifiers from address strings.
//! Algorithm: Seed PRNG from address hash, generate colors, create symmetric 8x8 grid.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Configuration for identicon generation
pub const IdenticonConfig = struct {
    /// Grid size (8x8 recommended for blockies)
    size: u8 = 8,
    /// Output scale factor (final size = size * scale)
    scale: u8 = 8,
    /// Background color override (null = auto-generate)
    background_color: ?[3]u8 = null,
};

/// Generated identicon with raw RGB pixel data
pub const Identicon = struct {
    width: u32,
    height: u32,
    /// RGB pixel data (3 bytes per pixel, row-major order)
    pixels: []u8,

    pub fn deinit(self: *Identicon, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Simple seeded PRNG (xorshift32 variant)
/// Deterministic: same seed always produces same sequence
const Prng = struct {
    state: u32,

    fn init(seed: u32) Prng {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    fn next(self: *Prng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// Returns float in range [0, 1)
    fn nextFloat(self: *Prng) f32 {
        return @as(f32, @floatFromInt(self.next())) / @as(f32, @floatFromInt(@as(u32, 0xFFFFFFFF)));
    }
};

/// HSL to RGB conversion
/// h: 0-360, s: 0-1, l: 0-1
fn hslToRgb(h: f32, s: f32, l: f32) [3]u8 {
    if (s == 0) {
        const gray: u8 = @intFromFloat(l * 255);
        return .{ gray, gray, gray };
    }

    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;

    const r = hueToRgb(p, q, h / 360 + 1.0 / 3.0);
    const g = hueToRgb(p, q, h / 360);
    const b = hueToRgb(p, q, h / 360 - 1.0 / 3.0);

    return .{
        @intFromFloat(r * 255),
        @intFromFloat(g * 255),
        @intFromFloat(b * 255),
    };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

/// Generate seed from address string (deterministic hash)
fn seedFromAddress(address: []const u8) u32 {
    // Simple DJB2-style hash
    var hash: u32 = 5381;
    for (address) |c| {
        // Convert to lowercase for consistency
        const ch = if (c >= 'A' and c <= 'Z') c + 32 else c;
        hash = ((hash << 5) +% hash) +% ch;
    }
    return hash;
}

/// Generate three colors for the identicon
fn generateColors(prng: *Prng) struct { bg: [3]u8, fg: [3]u8, spot: [3]u8 } {
    // Generate base hue
    const hue = prng.nextFloat() * 360;

    // Background: light, desaturated
    const bg = hslToRgb(hue, 0.5, 0.85);

    // Foreground: darker, more saturated
    const fg_hue = @mod(hue + 180, 360); // Complementary
    const fg = hslToRgb(fg_hue, 0.6, 0.45);

    // Spot color: vibrant accent
    const spot_hue = @mod(hue + 90, 360);
    const spot = hslToRgb(spot_hue, 0.7, 0.55);

    return .{ .bg = bg, .fg = fg, .spot = spot };
}

/// Generate identicon from address string
pub fn generate(allocator: Allocator, address: []const u8, config: IdenticonConfig) !Identicon {
    const seed = seedFromAddress(address);
    var prng = Prng.init(seed);

    // Generate color palette
    const colors = generateColors(&prng);

    // Generate 8x8 grid (only need half due to horizontal symmetry)
    // Fixed size arrays for simplicity (8x8 is standard blockie size)
    var grid: [8][8]u2 = undefined;
    const grid_size: usize = @min(config.size, 8);
    const half_width = grid_size / 2;

    for (0..grid_size) |y| {
        for (0..half_width) |x| {
            // 0 = background, 1 = foreground, 2 = spot
            const val: u2 = @intCast(prng.next() % 3);
            grid[y][x] = val;
            // Mirror horizontally
            grid[y][grid_size - 1 - x] = val;
        }
    }

    // Calculate output dimensions
    const out_width: u32 = @as(u32, @intCast(grid_size)) * @as(u32, config.scale);
    const out_height: u32 = @as(u32, @intCast(grid_size)) * @as(u32, config.scale);
    const pixel_count = out_width * out_height * 3;

    // Allocate pixel buffer
    const pixels = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(pixels);

    // Render grid to pixels
    var py: usize = 0;
    while (py < out_height) : (py += 1) {
        var px: usize = 0;
        while (px < out_width) : (px += 1) {
            const gx = px / config.scale;
            const gy = py / config.scale;
            const cell_value = grid[gy][gx];

            const color: [3]u8 = switch (cell_value) {
                0 => if (config.background_color) |bg| bg else colors.bg,
                1 => colors.fg,
                2 => colors.spot,
                else => colors.bg,
            };

            const offset = (py * out_width + px) * 3;
            pixels[offset + 0] = color[0];
            pixels[offset + 1] = color[1];
            pixels[offset + 2] = color[2];
        }
    }

    return Identicon{
        .width = out_width,
        .height = out_height,
        .pixels = pixels,
    };
}

/// Generate identicon with default configuration
pub fn generateDefault(allocator: Allocator, address: []const u8) !Identicon {
    return generate(allocator, address, .{});
}

/// Generate identicon and return as raw RGB bytes
/// Convenience function for PDF embedding
pub fn generateRaw(allocator: Allocator, address: []const u8, size: u8, scale: u8) !struct {
    pixels: []u8,
    width: u32,
    height: u32,
} {
    const icon = try generate(allocator, address, .{ .size = size, .scale = scale });
    return .{
        .pixels = icon.pixels,
        .width = icon.width,
        .height = icon.height,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "deterministic output" {
    const allocator = std.testing.allocator;
    const address = "0x1234567890abcdef1234567890abcdef12345678";

    var icon1 = try generate(allocator, address, .{});
    defer icon1.deinit(allocator);

    var icon2 = try generate(allocator, address, .{});
    defer icon2.deinit(allocator);

    // Same address should produce identical output
    try std.testing.expectEqualSlices(u8, icon1.pixels, icon2.pixels);
}

test "different addresses produce different icons" {
    const allocator = std.testing.allocator;

    var icon1 = try generate(allocator, "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .{});
    defer icon1.deinit(allocator);

    var icon2 = try generate(allocator, "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", .{});
    defer icon2.deinit(allocator);

    // Different addresses should produce different output
    try std.testing.expect(!std.mem.eql(u8, icon1.pixels, icon2.pixels));
}

test "output dimensions" {
    const allocator = std.testing.allocator;

    var icon = try generate(allocator, "test", .{ .size = 8, .scale = 10 });
    defer icon.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 80), icon.width);
    try std.testing.expectEqual(@as(u32, 80), icon.height);
    try std.testing.expectEqual(@as(usize, 80 * 80 * 3), icon.pixels.len);
}

test "case insensitive" {
    const allocator = std.testing.allocator;

    var icon1 = try generate(allocator, "0xABCDEF", .{});
    defer icon1.deinit(allocator);

    var icon2 = try generate(allocator, "0xabcdef", .{});
    defer icon2.deinit(allocator);

    // Should be identical (case insensitive)
    try std.testing.expectEqualSlices(u8, icon1.pixels, icon2.pixels);
}

test "hsl to rgb conversion" {
    // Red: H=0, S=1, L=0.5
    const red = hslToRgb(0, 1, 0.5);
    try std.testing.expectEqual(@as(u8, 255), red[0]);
    try std.testing.expectEqual(@as(u8, 0), red[1]);
    try std.testing.expectEqual(@as(u8, 0), red[2]);

    // Green: H=120, S=1, L=0.5
    const green = hslToRgb(120, 1, 0.5);
    try std.testing.expectEqual(@as(u8, 0), green[0]);
    try std.testing.expectEqual(@as(u8, 255), green[1]);
    try std.testing.expectEqual(@as(u8, 0), green[2]);

    // Gray: S=0
    const gray = hslToRgb(0, 0, 0.5);
    try std.testing.expectEqual(@as(u8, 127), gray[0]);
    try std.testing.expectEqual(@as(u8, 127), gray[1]);
    try std.testing.expectEqual(@as(u8, 127), gray[2]);
}
