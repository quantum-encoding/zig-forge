const std = @import("std");
const model_mod = @import("model.zig");
const sampler_mod = @import("sampler.zig");
const generate_mod = @import("generate.zig");
const whisper_mod = @import("whisper.zig");
const whisper_decode_mod = @import("whisper_decode.zig");
const u2net_mod = @import("u2net.zig");
const segment_mod = @import("segment.zig");
const image_mod = @import("image.zig");
const vits_mod = @import("vits.zig");
const tts_mod = @import("tts.zig");
const phonemize_mod = @import("phonemize.zig");
const wav_writer_mod = @import("wav_writer.zig");

// Re-export all modules for the shared library
pub const gguf = @import("gguf.zig");
pub const tensor = @import("tensor.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const math = @import("math.zig");
pub const quant = @import("quant.zig");
pub const kv_cache = @import("kv_cache.zig");
pub const audio = @import("audio.zig");
pub const whisper_loader = @import("whisper_loader.zig");
pub const whisper = @import("whisper.zig");
pub const whisper_decode = @import("whisper_decode.zig");
pub const conv = @import("conv.zig");
pub const vision_loader = @import("vision_loader.zig");
pub const u2net = @import("u2net.zig");
pub const segment = @import("segment.zig");
pub const vits = @import("vits.zig");
pub const tts = @import("tts.zig");
pub const tts_conv1d = @import("tts_conv1d.zig");
pub const wav_writer = @import("wav_writer.zig");

// Global buffer for FFI output capture
var ffi_buf: [*]u8 = undefined;
var ffi_buf_len: usize = 0;
var ffi_buf_pos: usize = 0;

fn ffiOutputFn(data: []const u8) void {
    const remaining = ffi_buf_len - ffi_buf_pos;
    const to_write = @min(data.len, remaining);
    if (to_write > 0) {
        @memcpy(ffi_buf[ffi_buf_pos..][0..to_write], data[0..to_write]);
        ffi_buf_pos += to_write;
    }
}

/// Create a model from a GGUF file path
export fn ziginfer_create(model_path: [*:0]const u8) ?*model_mod.Model {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(model_path);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_threads: u32 = if (cpu_count >= 1) @intCast(cpu_count) else 1;

    const model = allocator.create(model_mod.Model) catch return null;
    model.* = model_mod.Model.init(allocator, path, n_threads) catch {
        allocator.destroy(model);
        return null;
    };
    return model;
}

/// Destroy a model
export fn ziginfer_destroy(model: *model_mod.Model) void {
    model.deinit();
    std.heap.c_allocator.destroy(model);
}

/// Generate text from a prompt
export fn ziginfer_generate(
    model: *model_mod.Model,
    prompt: [*:0]const u8,
    max_tokens: u32,
    temperature: f32,
    output_buf: [*]u8,
    output_buf_len: usize,
) i32 {
    const allocator = std.heap.c_allocator;
    const prompt_str = std.mem.span(prompt);

    const config = sampler_mod.SamplerConfig{
        .temperature = temperature,
    };

    // Set up FFI buffer capture
    ffi_buf = output_buf;
    ffi_buf_len = output_buf_len;
    ffi_buf_pos = 0;

    _ = generate_mod.generate(
        allocator,
        model,
        prompt_str,
        config,
        max_tokens,
        ffiOutputFn,
    ) catch return -1;

    return @intCast(ffi_buf_pos);
}

/// Tokenize text, returns token count or negative error
export fn ziginfer_tokenize(
    model: *model_mod.Model,
    text: [*:0]const u8,
    output: [*]u32,
    max_tokens: usize,
) i32 {
    const allocator = std.heap.c_allocator;
    const text_str = std.mem.span(text);

    const tokens = model.tokenizer.encode(allocator, text_str, true) catch return -1;
    defer allocator.free(tokens);

    const count = @min(tokens.len, max_tokens);
    @memcpy(output[0..count], tokens[0..count]);
    return @intCast(count);
}

/// Get model info
export fn ziginfer_info(model: *model_mod.Model, buf: [*]u8, buf_len: usize) i32 {
    const msg = std.fmt.bufPrint(buf[0..buf_len], "arch={s} layers={d} d_model={d} vocab={d}", .{
        model.config.architecture,
        model.config.n_layers,
        model.config.d_model,
        model.config.vocab_size,
    }) catch return -1;
    return @intCast(msg.len);
}

// ── Whisper FFI ──

/// Create a Whisper model from a GGUF file path
export fn ziginfer_whisper_create(model_path: [*:0]const u8) ?*whisper_mod.WhisperModel {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(model_path);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_threads: u32 = if (cpu_count >= 1) @intCast(cpu_count) else 1;

    const model = allocator.create(whisper_mod.WhisperModel) catch return null;
    model.* = whisper_mod.WhisperModel.init(allocator, path, n_threads) catch {
        allocator.destroy(model);
        return null;
    };
    return model;
}

/// Destroy a Whisper model
export fn ziginfer_whisper_destroy(model: *whisper_mod.WhisperModel) void {
    model.deinit();
    std.heap.c_allocator.destroy(model);
}

/// Transcribe audio file, returns bytes written or negative error
export fn ziginfer_whisper_transcribe(
    model: *whisper_mod.WhisperModel,
    audio_path: [*:0]const u8,
    out_buf: [*]u8,
    buf_len: usize,
) i32 {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(audio_path);

    var result = whisper_decode_mod.transcribe(allocator, model, path, null) catch return -1;
    defer result.deinit(allocator);

    const copy_len = @min(result.text.len, buf_len);
    @memcpy(out_buf[0..copy_len], result.text[0..copy_len]);
    return @intCast(copy_len);
}

// ── Vision FFI ──

/// Create a U2NetP vision model from a ZVIS file path
export fn ziginfer_vision_create(model_path: [*:0]const u8) ?*u2net_mod.U2NetP {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(model_path);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_threads: u32 = if (cpu_count >= 1) @intCast(cpu_count) else 1;

    const model = allocator.create(u2net_mod.U2NetP) catch return null;
    model.* = u2net_mod.U2NetP.init(allocator, path, n_threads) catch {
        allocator.destroy(model);
        return null;
    };
    return model;
}

/// Destroy a vision model
export fn ziginfer_vision_destroy(model: *u2net_mod.U2NetP) void {
    model.deinit();
    std.heap.c_allocator.destroy(model);
}

/// Segment an image: remove background and save as RGBA PNG.
/// Returns 0 on success, -1 on error.
export fn ziginfer_vision_segment(
    model: *u2net_mod.U2NetP,
    image_path: [*:0]const u8,
    output_path: [*:0]const u8,
) i32 {
    const allocator = std.heap.c_allocator;

    var result = segment_mod.segmentAndSave(allocator, model, image_path, output_path) catch return -1;
    result.deinit(allocator);

    return 0;
}

// ── TTS FFI ──

/// Initialize the espeak-ng phonemizer with a voice name.
/// Returns 0 on success, -1 on error.
export fn ziginfer_tts_init_phonemizer(voice: [*:0]const u8) i32 {
    const voice_str = std.mem.span(voice);
    phonemize_mod.init(voice_str) catch return -1;
    return 0;
}

/// Create a VITS TTS model from a ZVIS v2 file path.
export fn ziginfer_tts_create(model_path: [*:0]const u8) ?*vits_mod.VitsModel {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(model_path);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_threads: u32 = if (cpu_count >= 1) @intCast(cpu_count) else 1;

    const model = allocator.create(vits_mod.VitsModel) catch return null;
    model.* = vits_mod.VitsModel.init(allocator, path, n_threads) catch {
        allocator.destroy(model);
        return null;
    };
    return model;
}

/// Destroy a TTS model.
export fn ziginfer_tts_destroy(model: *vits_mod.VitsModel) void {
    model.deinit();
    std.heap.c_allocator.destroy(model);
}

/// Synthesize speech from text. Writes f32 PCM audio to out_buf.
/// Returns number of samples written, or negative error.
export fn ziginfer_tts_synthesize(
    model: *vits_mod.VitsModel,
    text: [*:0]const u8,
    out_buf: [*]f32,
    buf_len: u32,
) i32 {
    const allocator = std.heap.c_allocator;
    const text_str = std.mem.span(text);

    const out = tts_mod.synthesize(allocator, model, text_str, 0.667, 1.0) catch return -1;

    const copy_len = @min(out.result.n_samples, buf_len);
    @memcpy(out_buf[0..copy_len], out.audio[0..copy_len]);
    return @intCast(copy_len);
}

/// Synthesize speech from text and save to a WAV file.
/// Returns 0 on success, -1 on error.
export fn ziginfer_tts_speak_to_file(
    model: *vits_mod.VitsModel,
    text: [*:0]const u8,
    output_path: [*:0]const u8,
) i32 {
    const allocator = std.heap.c_allocator;
    const text_str = std.mem.span(text);
    const path_str = std.mem.span(output_path);

    _ = tts_mod.synthesizeToWav(allocator, model, text_str, path_str, 0.667, 1.0) catch return -1;
    return 0;
}
