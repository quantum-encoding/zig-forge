const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WavParams = struct {
    sample_rate: u32 = 22050,
    channels: u16 = 1,
    bits_per_sample: u16 = 16,
};

/// Write f32 audio samples to a WAV file (PCM 16-bit).
/// Samples are expected in range [-1.0, 1.0].
pub fn writeWav(allocator: Allocator, path: []const u8, samples: []const f32, params: WavParams) !void {
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);

    const fp = std.c.fopen(c_path.ptr, "wb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(fp);

    const n_samples: u32 = @intCast(samples.len);
    const bytes_per_sample: u32 = @as(u32, params.bits_per_sample) / 8;
    const data_size: u32 = n_samples * @as(u32, params.channels) * bytes_per_sample;
    const byte_rate: u32 = params.sample_rate * @as(u32, params.channels) * bytes_per_sample;
    const block_align: u16 = params.channels * @as(u16, @intCast(bytes_per_sample));

    // RIFF header (44 bytes)
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM format
    std.mem.writeInt(u16, header[22..24], params.channels, .little);
    std.mem.writeInt(u32, header[24..28], params.sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], params.bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_size, .little);

    if (std.c.fwrite(&header, 1, 44, fp) != 44) return error.WriteFailed;

    // Convert f32 to i16 and write in chunks
    var buf: [1024]i16 = undefined;
    var written: usize = 0;
    while (written < samples.len) {
        const chunk = @min(samples.len - written, 1024);
        for (0..chunk) |i| {
            const clamped = std.math.clamp(samples[written + i], -1.0, 1.0);
            buf[i] = @intFromFloat(clamped * 32767.0);
        }
        const bytes = chunk * 2;
        if (std.c.fwrite(@ptrCast(&buf), 1, bytes, fp) != bytes) return error.WriteFailed;
        written += chunk;
    }
}
