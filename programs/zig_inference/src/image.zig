const std = @import("std");
const Allocator = std.mem.Allocator;
const conv = @import("conv.zig");

// ── stb_image C interop ──

extern fn stbi_load(filename: [*:0]const u8, x: *c_int, y: *c_int, channels: *c_int, desired: c_int) ?[*]u8;
extern fn stbi_image_free(data: [*]u8) void;
extern fn stbi_write_png(filename: [*:0]const u8, w: c_int, h: c_int, comp: c_int, data: [*]const u8, stride: c_int) c_int;

pub const Image = struct {
    data: [*]u8,
    width: u32,
    height: u32,
    channels: u32,

    pub fn deinit(self: *Image) void {
        stbi_image_free(self.data);
    }
};

/// Load an image from file using stb_image (supports PNG, JPEG, BMP, etc.)
pub fn loadImage(path: [*:0]const u8) !Image {
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const data = stbi_load(path, &w, &h, &ch, 3) orelse return error.ImageLoadFailed;
    return Image{
        .data = data,
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = 3,
    };
}

/// Load image and preprocess to [3 x target_h x target_w] f32 tensor, normalized to [0,1]
pub fn loadAndPreprocess(allocator: Allocator, path: [*:0]const u8, target_h: u32, target_w: u32) ![]f32 {
    var img = try loadImage(path);
    defer img.deinit();

    const out_size: usize = 3 * @as(usize, target_h) * target_w;
    const result = try allocator.alloc(f32, out_size);

    if (img.width == target_w and img.height == target_h) {
        // Direct copy, HWC RGB -> CHW normalized
        hwcToChw(result, img.data, img.width, img.height);
    } else {
        // Resize: first convert to CHW float, then bilinear resize
        const src_size: usize = 3 * @as(usize, img.height) * img.width;
        const src_chw = try allocator.alloc(f32, src_size);
        defer allocator.free(src_chw);

        hwcToChw(src_chw, img.data, img.width, img.height);
        conv.resizeBilinear(result, src_chw, 3, img.height, img.width, target_h, target_w);
    }

    return result;
}

/// Convert HWC u8 [0,255] to CHW f32 [0,1]
fn hwcToChw(out: []f32, data: [*]const u8, w: u32, h: u32) void {
    const hw: usize = @as(usize, h) * w;
    for (0..h) |y| {
        for (0..w) |x| {
            const pixel = (y * w + x) * 3;
            out[0 * hw + y * w + x] = @as(f32, @floatFromInt(data[pixel + 0])) / 255.0;
            out[1 * hw + y * w + x] = @as(f32, @floatFromInt(data[pixel + 1])) / 255.0;
            out[2 * hw + y * w + x] = @as(f32, @floatFromInt(data[pixel + 2])) / 255.0;
        }
    }
}

/// Load an image with RGBA (4 channels) for compositing
pub fn loadImageRgba(path: [*:0]const u8) !Image {
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const data = stbi_load(path, &w, &h, &ch, 4) orelse return error.ImageLoadFailed;
    return Image{
        .data = data,
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = 4,
    };
}

/// Apply alpha mask to original image and save as RGBA PNG
/// mask: [mask_h x mask_w] f32 in [0,1], resized to match original dimensions
pub fn saveWithAlpha(
    allocator: Allocator,
    orig_path: [*:0]const u8,
    mask: []const f32,
    mask_h: u32,
    mask_w: u32,
    out_path: [*:0]const u8,
) !void {
    var img = try loadImageRgba(orig_path);
    defer img.deinit();

    const w = img.width;
    const h = img.height;
    const n_pixels: usize = @as(usize, h) * w;

    // Resize mask to original image dimensions if needed
    var final_mask: []f32 = undefined;
    var own_mask = false;
    if (mask_h == h and mask_w == w) {
        // Use mask directly (cast away const for the slice)
        final_mask = @constCast(mask[0..n_pixels]);
    } else {
        final_mask = try allocator.alloc(f32, n_pixels);
        own_mask = true;
        conv.resizeBilinear(final_mask, mask, 1, mask_h, mask_w, h, w);
    }
    defer if (own_mask) allocator.free(final_mask);

    // Apply alpha: set the A channel of each RGBA pixel
    for (0..n_pixels) |i| {
        const alpha_u8: u8 = @intFromFloat(std.math.clamp(final_mask[i], 0.0, 1.0) * 255.0);
        img.data[i * 4 + 3] = alpha_u8;
    }

    // Write RGBA PNG
    const ret = stbi_write_png(out_path, @intCast(w), @intCast(h), 4, img.data, @intCast(w * 4));
    if (ret == 0) return error.WriteFailed;
}

/// Save a raw alpha mask as grayscale PNG
pub fn saveMask(
    allocator: Allocator,
    mask: []const f32,
    mask_h: u32,
    mask_w: u32,
    out_path: [*:0]const u8,
) !void {
    const n_pixels: usize = @as(usize, mask_h) * mask_w;
    const buf = try allocator.alloc(u8, n_pixels);
    defer allocator.free(buf);

    for (0..n_pixels) |i| {
        buf[i] = @intFromFloat(std.math.clamp(mask[i], 0.0, 1.0) * 255.0);
    }

    const ret = stbi_write_png(out_path, @intCast(mask_w), @intCast(mask_h), 1, buf.ptr, @intCast(mask_w));
    if (ret == 0) return error.WriteFailed;
}
