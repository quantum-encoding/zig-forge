const std = @import("std");
const Allocator = std.mem.Allocator;
const vits_mod = @import("vits.zig");
const VitsModel = vits_mod.VitsModel;
const phonemize = @import("phonemize.zig");
const wav_writer = @import("wav_writer.zig");

pub const TtsResult = struct {
    n_samples: u32,
    sample_rate: u32,
    phoneme_count: usize,

    pub fn durationMs(self: TtsResult) u32 {
        if (self.sample_rate == 0) return 0;
        return @intCast(@as(u64, self.n_samples) * 1000 / self.sample_rate);
    }
};

/// Full TTS pipeline: text → phonemes → VITS → audio buffer.
/// The returned audio slice points into model's internal buffer (valid until next call).
pub fn synthesize(
    allocator: Allocator,
    model: *VitsModel,
    text: []const u8,
    noise_scale: f32,
    length_scale: f32,
) !struct { audio: []const f32, result: TtsResult } {
    // Phonemize
    const ph = try phonemize.textToPhonemeIds(allocator, text);
    defer allocator.free(ph.ids);

    // Synthesize
    const synth = try model.synthesize(ph.ids, noise_scale, length_scale);

    return .{
        .audio = synth.audio,
        .result = TtsResult{
            .n_samples = synth.n_samples,
            .sample_rate = synth.sample_rate,
            .phoneme_count = ph.n_phonemes,
        },
    };
}

/// Full TTS pipeline: text → phonemes → VITS → WAV file.
pub fn synthesizeToWav(
    allocator: Allocator,
    model: *VitsModel,
    text: []const u8,
    output_path: []const u8,
    noise_scale: f32,
    length_scale: f32,
) !TtsResult {
    const out = try synthesize(allocator, model, text, noise_scale, length_scale);

    try wav_writer.writeWav(allocator, output_path, out.audio, .{
        .sample_rate = out.result.sample_rate,
    });

    return out.result;
}
