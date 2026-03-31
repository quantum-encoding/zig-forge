const std = @import("std");
const Allocator = std.mem.Allocator;
const u2net_mod = @import("u2net.zig");
const image_mod = @import("image.zig");

pub const SegmentResult = struct {
    mask: []f32, // [H x W] alpha values in [0, 1]
    width: u32,
    height: u32,
    inference_ms: u64,

    pub fn deinit(self: *SegmentResult, allocator: Allocator) void {
        allocator.free(self.mask);
    }
};

/// Run segmentation on an image, returning the alpha mask.
pub fn segment(allocator: Allocator, model: *u2net_mod.U2NetP, image_path: [*:0]const u8) !SegmentResult {
    // Load and preprocess to 3x320x320
    const input = try image_mod.loadAndPreprocess(allocator, image_path, 320, 320);
    defer allocator.free(input);

    // Time the inference
    const start_ns = getTimeNs();
    const mask = try model.forward(allocator, input);
    const elapsed_ns = getTimeNs() - start_ns;

    return SegmentResult{
        .mask = mask,
        .width = 320,
        .height = 320,
        .inference_ms = elapsed_ns / 1_000_000,
    };
}

/// Run segmentation and save result as RGBA PNG with transparent background.
pub fn segmentAndSave(
    allocator: Allocator,
    model: *u2net_mod.U2NetP,
    image_path: [*:0]const u8,
    out_path: [*:0]const u8,
) !SegmentResult {
    const result = try segment(allocator, model, image_path);

    // Save with alpha channel applied to original image
    try image_mod.saveWithAlpha(allocator, image_path, result.mask, result.width, result.height, out_path);

    return result;
}

/// Save just the mask as a grayscale PNG.
pub fn saveMask(
    allocator: Allocator,
    result: *const SegmentResult,
    out_path: [*:0]const u8,
) !void {
    try image_mod.saveMask(allocator, result.mask, result.height, result.width, out_path);
}

fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
}
