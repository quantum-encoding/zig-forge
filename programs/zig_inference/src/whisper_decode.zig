const std = @import("std");
const Allocator = std.mem.Allocator;
const whisper_mod = @import("whisper.zig");
const audio_mod = @import("audio.zig");
const math = @import("math.zig");
const WhisperModel = whisper_mod.WhisperModel;

// Whisper special tokens
pub const SOT: u32 = 50258; // Start of transcript
pub const EOT: u32 = 50257; // End of transcript
pub const ENGLISH: u32 = 50259; // English language
pub const TRANSCRIBE: u32 = 50359; // Transcribe task
pub const NO_TIMESTAMPS: u32 = 50363; // No timestamps

pub const TranscribeResult = struct {
    text: []u8,
    n_tokens: u32,
    encode_ms: u64,
    decode_ms: u64,

    pub fn deinit(self: *TranscribeResult, allocator: Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
    }
};

pub fn transcribe(
    allocator: Allocator,
    model: *WhisperModel,
    audio_path: []const u8,
    stream_fn: ?*const fn ([]const u8) void,
) !TranscribeResult {
    // 1. Read WAV
    const samples = try audio_mod.readWav(allocator, audio_path);
    defer allocator.free(samples);

    // 2. Compute mel spectrogram using model's pre-computed mel filters
    var mel = try audio_mod.melSpectrogramWithFilters(
        allocator,
        samples,
        model.wfile.mel_filters,
        model.wfile.mel_n_mels,
        model.wfile.mel_n_fft,
    );
    defer mel.deinit(allocator);

    // 3. Encode
    const encode_start = getTimeNs();
    model.encode(mel.data);
    model.computeCrossKV();
    const encode_ns = getTimeNs() - encode_start;

    // 4. Decode
    const decode_start = getTimeNs();
    model.resetDecoder();

    // Prefill initial tokens: SOT, English, Transcribe, NoTimestamps
    const initial_tokens = [_]u32{ SOT, ENGLISH, TRANSCRIBE, NO_TIMESTAMPS };

    var pos: u32 = 0;
    var prev_token: u32 = SOT;

    // Feed initial tokens (except first, which is SOT)
    for (initial_tokens) |tok| {
        _ = model.decode(tok, pos);
        prev_token = tok;
        pos += 1;
    }

    // Greedy decode loop
    const max_tokens: u32 = 224;
    var output_tokens: std.ArrayListUnmanaged(u32) = .empty;
    defer output_tokens.deinit(allocator);

    for (0..max_tokens) |_| {
        const logits = model.decode(prev_token, pos);

        // Suppress special tokens (>= SOT) except EOT
        suppressSpecialTokens(logits, model.config.vocab_size);

        const next = math.argmax(logits[0..model.config.vocab_size]);

        if (next == EOT) break;

        try output_tokens.append(allocator, next);

        // Stream token text
        if (stream_fn) |sfn| {
            if (next < @as(u32, @intCast(model.wfile.tokens.len))) {
                sfn(model.wfile.tokens[next]);
            }
        }

        prev_token = next;
        pos += 1;
    }

    const decode_ns = getTimeNs() - decode_start;

    // Build full text
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(allocator);

    for (output_tokens.items) |tok| {
        if (tok < @as(u32, @intCast(model.wfile.tokens.len))) {
            try text_buf.appendSlice(allocator, model.wfile.tokens[tok]);
        }
    }

    const text = try allocator.alloc(u8, text_buf.items.len);
    @memcpy(text, text_buf.items);

    return TranscribeResult{
        .text = text,
        .n_tokens = @intCast(output_tokens.items.len),
        .encode_ms = encode_ns / 1_000_000,
        .decode_ms = decode_ns / 1_000_000,
    };
}

fn suppressSpecialTokens(logits: []f32, vocab_size: u32) void {
    // Set all tokens >= SOT to -inf, except keep EOT accessible
    const special_start = SOT;
    if (special_start >= vocab_size) return;

    for (special_start..vocab_size) |i| {
        if (i != EOT) {
            logits[i] = -std.math.inf(f32);
        }
    }
}

fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
}
