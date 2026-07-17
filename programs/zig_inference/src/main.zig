const std = @import("std");
const gguf_mod = @import("gguf.zig");
const tensor_mod = @import("tensor.zig");
const tokenizer_mod = @import("tokenizer.zig");
const model_mod = @import("model.zig");
const sampler_mod = @import("sampler.zig");
const generate_mod = @import("generate.zig");
const math = @import("math.zig");
const quant = @import("quant.zig");
const kv_cache = @import("kv_cache.zig");
const whisper_mod = @import("whisper.zig");
const whisper_decode = @import("whisper_decode.zig");
const audio_mod = @import("audio.zig");
const whisper_loader = @import("whisper_loader.zig");
const u2net_mod = @import("u2net.zig");
const segment_mod = @import("segment.zig");
const image_mod = @import("image.zig");
const vision_loader = @import("vision_loader.zig");
const vits_mod = @import("vits.zig");
const tts_mod = @import("tts.zig");
const phonemize_mod = @import("phonemize.zig");
const wav_writer_mod = @import("wav_writer.zig");
const tts_conv1d_mod = @import("tts_conv1d.zig");

// ── I/O helpers for Zig 0.16 (no std.io.getStdOut) ──

fn writeStdout(data: []const u8) void {
    _ = std.c.write(1, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = std.c.write(2, data.ptr, data.len);
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(msg);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn stdoutStreamFn(data: []const u8) void {
    writeStdout(data);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, command, "info")) {
        try cmdInfo(allocator, rest);
    } else if (std.mem.eql(u8, command, "tokenize")) {
        try cmdTokenize(allocator, rest);
    } else if (std.mem.eql(u8, command, "generate")) {
        try cmdGenerate(allocator, rest);
    } else if (std.mem.eql(u8, command, "embed")) {
        try cmdEmbed(allocator, rest);
    } else if (std.mem.eql(u8, command, "bench")) {
        try cmdBench(allocator, rest);
    } else if (std.mem.eql(u8, command, "transcribe")) {
        try cmdTranscribe(allocator, rest);
    } else if (std.mem.eql(u8, command, "segment")) {
        try cmdSegment(allocator, rest);
    } else if (std.mem.eql(u8, command, "speak")) {
        try cmdSpeak(allocator, rest);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        printErr("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    writeStdout(
        \\zig-infer — Zig ML Inference Engine
        \\
        \\Usage:
        \\  zig-infer info     <model.gguf>              Show model information
        \\  zig-infer tokenize --model <path> "text"      Tokenize text
        \\  zig-infer generate --model <path> [options]   Generate text
        \\  zig-infer embed    --model <path> [options]   Text embedding (Qwen3-Embedding)
        \\  zig-infer bench    --model <path> [options]   Benchmark inference
        \\  zig-infer transcribe --model <path> --audio <wav> Transcribe audio
        \\  zig-infer segment   --model <path> --input <img> --output <png> Remove background
        \\  zig-infer speak     --model <path> --text "str" --output <wav> Text-to-speech
        \\
        \\Generate options:
        \\  --model <path>          Path to GGUF model file
        \\  --prompt "text"         Input prompt
        \\  --max-tokens N          Maximum tokens to generate (default: 256)
        \\  --temperature F         Sampling temperature (default: 0.7)
        \\  --top-k N               Top-K sampling (default: 40)
        \\  --top-p F               Nucleus sampling (default: 0.9)
        \\  --seed N                RNG seed (default: random)
        \\  --threads N             Number of threads (default: auto-detect)
        \\
        \\Bench options:
        \\  --model <path>          Path to GGUF model file
        \\  --prompt-len N          Prompt length for prefill bench (default: 128)
        \\  --gen-len N             Generation length (default: 32)
        \\  --threads N             Number of threads (default: auto-detect)
        \\
        \\Transcribe options:
        \\  --model <path>          Path to Whisper GGUF model file
        \\  --audio <path>          Path to input WAV file (16kHz mono 16-bit PCM)
        \\  --threads N             Number of threads (default: auto-detect)
        \\
        \\Segment options:
        \\  --model <path>          Path to ZVIS model file (u2netp.zvis)
        \\  --input <path>          Input image (PNG/JPEG)
        \\  --output <path>         Output PNG with transparent background
        \\  --mask <path>           Optional: save raw mask as grayscale PNG
        \\  --threads N             Number of threads (default: auto-detect)
        \\
        \\Speak options:
        \\  --model <path>          Path to ZVIS v2 TTS model file
        \\  --text "string"         Text to synthesize
        \\  --output <path>         Output WAV file path
        \\  --voice <name>          espeak-ng voice (default: en-us)
        \\  --noise-scale F         Noise scale (default: 0.667)
        \\  --length-scale F        Length/speed scale (default: 1.0)
        \\  --threads N             Number of threads (default: auto-detect)
        \\
    );
}

fn cmdInfo(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        printErr("Usage: zig-infer info <model.gguf>\n", .{});
        return;
    }
    const model_path = args[0];

    var gguf = try gguf_mod.GGUFFile.open(allocator, model_path);
    defer gguf.close();

    const params = gguf.parameterCount();
    const dom_quant = gguf.dominantQuantType();

    printOut(
        \\Architecture: {s}
        \\Parameters:   {d:.2}B
        \\Quantization: {s} (mostly)
        \\Layers:       {d}
        \\Hidden size:  {d}
        \\Heads:        {d} (KV: {d})
        \\FFN size:     {d}
        \\Vocab:        {d}
        \\Context:      {d}
        \\File size:    {d:.1} MB
        \\Tensors:      {d}
        \\
    , .{
        gguf.architecture,
        @as(f64, @floatFromInt(params)) / 1e9,
        dom_quant.name(),
        gguf.block_count,
        gguf.embedding_length,
        gguf.head_count,
        gguf.head_count_kv,
        gguf.feed_forward_length,
        gguf.vocab_size,
        gguf.context_length,
        @as(f64, @floatFromInt(gguf.mmap_len)) / (1024.0 * 1024.0),
        gguf.tensor_count,
    });
}

fn cmdTokenize(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var text: ?[]const u8 = null;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--model") and idx + 1 < args.len) {
            idx += 1;
            model_path = args[idx];
        } else {
            text = args[idx];
        }
    }

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };
    const txt = text orelse {
        printErr("Missing text argument\n", .{});
        return;
    };

    var gguf = try gguf_mod.GGUFFile.open(allocator, mp);
    defer gguf.close();

    var tokenizer = try tokenizer_mod.Tokenizer.init(allocator, &gguf);
    defer tokenizer.deinit();

    const tokens = try tokenizer.encode(allocator, txt, true);
    defer allocator.free(tokens);

    // Print token IDs
    writeStdout("Tokens: [");
    for (tokens, 0..) |tok, ti| {
        if (ti > 0) writeStdout(", ");
        printOut("{d}", .{tok});
    }
    writeStdout("]\n");

    // Print token strings
    writeStdout("Text:   [");
    for (tokens, 0..) |tok, ti| {
        if (ti > 0) writeStdout(", ");
        const piece = tokenizer.decodeToken(tok);
        printOut("\"{s}\"", .{piece});
    }
    writeStdout("]\n");

    printOut("Count:  {d} tokens\n", .{tokens.len});
}

fn detectThreadCount() u32 {
    const count = std.Thread.getCpuCount() catch return 1;
    return if (count >= 1) @intCast(count) else 1;
}

fn cmdGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var config = sampler_mod.SamplerConfig{};
    var max_tokens: u32 = 256;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--prompt") and has_next) {
            idx += 1; prompt = args[idx];
        } else if (std.mem.eql(u8, arg, "--max-tokens") and has_next) {
            idx += 1; max_tokens = std.fmt.parseInt(u32, args[idx], 10) catch 256;
        } else if (std.mem.eql(u8, arg, "--temperature") and has_next) {
            idx += 1; config.temperature = std.fmt.parseFloat(f32, args[idx]) catch 0.7;
        } else if (std.mem.eql(u8, arg, "--top-k") and has_next) {
            idx += 1; config.top_k = std.fmt.parseInt(u32, args[idx], 10) catch 40;
        } else if (std.mem.eql(u8, arg, "--top-p") and has_next) {
            idx += 1; config.top_p = std.fmt.parseFloat(f32, args[idx]) catch 0.9;
        } else if (std.mem.eql(u8, arg, "--seed") and has_next) {
            idx += 1; config.seed = std.fmt.parseInt(u64, args[idx], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };

    printErr("Loading model: {s}\n", .{mp});

    var model = try model_mod.Model.init(allocator, mp, n_threads);
    defer model.deinit();

    printErr("Model loaded: {s} ({d} layers, d_model={d}, vocab={d}, threads={d})\n", .{
        model.config.architecture,
        model.config.n_layers,
        model.config.d_model,
        model.config.vocab_size,
        n_threads,
    });

    const p = prompt orelse "Hello";

    const result = try generate_mod.generate(allocator, &model, p, config, max_tokens, stdoutStreamFn);

    writeStdout("\n");
    printErr(
        \\
        \\--- Stats ---
        \\Prompt:     {d} tokens ({d:.1} tok/s)
        \\Generation: {d} tokens ({d:.1} tok/s)
        \\Total:      {d:.2}s
        \\
    , .{
        result.prompt_tokens,
        result.promptTokPerSec(),
        result.tokens_generated,
        result.genTokPerSec(),
        result.totalSec(),
    });
}

fn cmdEmbed(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    var task: []const u8 = "Given a web search query, retrieve relevant passages that answer the query";
    var dim: usize = 0; // 0 = full d_model (MRL: smaller truncates+renormalizes)
    var as_json = false;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--text") and has_next) {
            idx += 1; text = args[idx];
        } else if (std.mem.eql(u8, arg, "--query") and has_next) {
            idx += 1; query = args[idx];
        } else if (std.mem.eql(u8, arg, "--task") and has_next) {
            idx += 1; task = args[idx];
        } else if (std.mem.eql(u8, arg, "--dim") and has_next) {
            idx += 1; dim = std.fmt.parseInt(usize, args[idx], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        } else if (text == null and query == null) {
            text = arg; // positional
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };
    if (text == null and query == null) {
        printErr("Missing --text or --query argument\n", .{});
        return;
    }

    printErr("Loading model: {s}\n", .{mp});
    var model = try model_mod.Model.init(allocator, mp, n_threads);
    defer model.deinit();

    // Queries get the instruction wrapper "Instruct: {task}\nQuery:{q}" (note: no space
    // after "Query:"); documents are embedded raw. Matches Qwen3-Embedding's reference.
    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(allocator);
    if (query) |q| {
        const s = try std.fmt.allocPrint(allocator, "Instruct: {s}\nQuery:{s}", .{ task, q });
        defer allocator.free(s);
        try input_buf.appendSlice(allocator, s);
    } else {
        try input_buf.appendSlice(allocator, text.?);
    }

    // Tokenize (no BOS for Qwen3) and append EOS — Qwen3-Embedding pools the EOS token.
    var tokens_list: std.ArrayListUnmanaged(u32) = .empty;
    defer tokens_list.deinit(allocator);
    const enc = try model.tokenizer.encode(allocator, input_buf.items, false);
    defer allocator.free(enc);
    try tokens_list.appendSlice(allocator, enc);
    if (model.tokenizer.add_eos_default) try tokens_list.append(allocator, model.tokenizer.eos_id);

    const out_dim = if (dim > 0) @min(dim, @as(usize, model.config.d_model)) else model.config.d_model;
    const out = try allocator.alloc(f32, out_dim);
    defer allocator.free(out);

    const written = model.embed(tokens_list.items, out);

    if (as_json) {
        writeStdout("[");
        for (out[0..written], 0..) |v, vi| {
            if (vi > 0) writeStdout(",");
            printOut("{d:.6}", .{v});
        }
        writeStdout("]\n");
    } else {
        printErr("Embedding: dim={d}, tokens={d}\n", .{ written, tokens_list.items.len });
        printOut("[", .{});
        const preview = @min(written, 8);
        for (out[0..preview], 0..) |v, vi| {
            if (vi > 0) writeStdout(", ");
            printOut("{d:.5}", .{v});
        }
        if (written > preview) writeStdout(", ...");
        writeStdout("]\n");
    }
}

fn cmdBench(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var prompt_len: u32 = 128;
    var gen_len: u32 = 32;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--prompt-len") and has_next) {
            idx += 1; prompt_len = std.fmt.parseInt(u32, args[idx], 10) catch 128;
        } else if (std.mem.eql(u8, arg, "--gen-len") and has_next) {
            idx += 1; gen_len = std.fmt.parseInt(u32, args[idx], 10) catch 32;
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };

    printErr("Loading model: {s}\n", .{mp});

    var model = try model_mod.Model.init(allocator, mp, n_threads);
    defer model.deinit();

    printOut("Benchmarking: {s}\n", .{model.config.architecture});
    printOut("  Layers: {d}, d_model: {d}, vocab: {d}, threads: {d}\n", .{
        model.config.n_layers, model.config.d_model, model.config.vocab_size, n_threads,
    });

    // Prefill benchmark
    const capped_prompt = @min(prompt_len, model.config.vocab_size - 1);
    {
        const start_ns = getTimeNs();
        for (0..capped_prompt) |pi| {
            _ = model.forward(@intCast(pi + 1), @intCast(pi));
        }
        const elapsed = getTimeNs() - start_ns;
        const tps = @as(f64, @floatFromInt(capped_prompt)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
        printOut("Prefill:    {d} tokens in {d:.0}ms ({d:.1} tok/s)\n", .{
            capped_prompt,
            @as(f64, @floatFromInt(elapsed)) / 1e6,
            tps,
        });
    }

    // Generation benchmark
    {
        const start_ns = getTimeNs();
        var prev_token: u32 = 1;
        for (0..gen_len) |gi| {
            const logits = model.forward(prev_token, @intCast(capped_prompt + gi));
            prev_token = math.argmax(logits);
        }
        const elapsed = getTimeNs() - start_ns;
        const tps = @as(f64, @floatFromInt(gen_len)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
        printOut("Generation: {d} tokens in {d:.0}ms ({d:.1} tok/s)\n", .{
            gen_len,
            @as(f64, @floatFromInt(elapsed)) / 1e6,
            tps,
        });
    }
}

fn cmdTranscribe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var audio_path: ?[]const u8 = null;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--audio") and has_next) {
            idx += 1; audio_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };
    const ap = audio_path orelse {
        printErr("Missing --audio argument\n", .{});
        return;
    };

    printErr("Loading Whisper model: {s}\n", .{mp});

    var model = try whisper_mod.WhisperModel.init(allocator, mp, n_threads);
    defer model.deinit();

    printErr("Model loaded: whisper (enc={d}L, dec={d}L, d_model={d}, vocab={d}, threads={d})\n", .{
        model.config.n_audio_layer,
        model.config.n_text_layer,
        model.config.d_model,
        model.config.vocab_size,
        n_threads,
    });

    printErr("Transcribing: {s}\n", .{ap});

    var result = try whisper_decode.transcribe(allocator, &model, ap, stdoutStreamFn);
    defer result.deinit(allocator);

    writeStdout("\n");
    printErr(
        \\
        \\--- Stats ---
        \\Encode:  {d}ms
        \\Decode:  {d}ms ({d} tokens)
        \\Total:   {d}ms
        \\
    , .{
        result.encode_ms,
        result.decode_ms,
        result.n_tokens,
        result.encode_ms + result.decode_ms,
    });
}

fn cmdSegment(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var mask_path: ?[]const u8 = null;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--input") and has_next) {
            idx += 1; input_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--output") and has_next) {
            idx += 1; output_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--mask") and has_next) {
            idx += 1; mask_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };
    const ip = input_path orelse {
        printErr("Missing --input argument\n", .{});
        return;
    };
    const op = output_path orelse {
        printErr("Missing --output argument\n", .{});
        return;
    };

    printErr("Loading U2NetP model: {s}\n", .{mp});

    var model = try u2net_mod.U2NetP.init(allocator, mp, n_threads);
    defer model.deinit();

    printErr("Model loaded ({d} tensors, threads={d})\n", .{ model.vfile.n_tensors, n_threads });
    printErr("Segmenting: {s}\n", .{ip});

    // Need null-terminated paths for C interop
    const c_input = try allocator.dupeZ(u8, ip);
    defer allocator.free(c_input);
    const c_output = try allocator.dupeZ(u8, op);
    defer allocator.free(c_output);

    var result = try segment_mod.segmentAndSave(allocator, &model, c_input.ptr, c_output.ptr);
    defer result.deinit(allocator);

    // Optionally save mask
    if (mask_path) |mkp| {
        const c_mask = try allocator.dupeZ(u8, mkp);
        defer allocator.free(c_mask);
        try segment_mod.saveMask(allocator, &result, c_mask.ptr);
        printErr("Mask saved: {s}\n", .{mkp});
    }

    printErr(
        \\
        \\--- Stats ---
        \\Inference: {d}ms
        \\Output:    {s}
        \\
    , .{ result.inference_ms, op });
}

fn cmdSpeak(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var voice: []const u8 = "en-us";
    var noise_scale: f32 = 0.667;
    var length_scale: f32 = 1.0;
    var n_threads: u32 = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const has_next = idx + 1 < args.len;
        if (std.mem.eql(u8, arg, "--model") and has_next) {
            idx += 1; model_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--text") and has_next) {
            idx += 1; text = args[idx];
        } else if (std.mem.eql(u8, arg, "--output") and has_next) {
            idx += 1; output_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--voice") and has_next) {
            idx += 1; voice = args[idx];
        } else if (std.mem.eql(u8, arg, "--noise-scale") and has_next) {
            idx += 1; noise_scale = std.fmt.parseFloat(f32, args[idx]) catch 0.667;
        } else if (std.mem.eql(u8, arg, "--length-scale") and has_next) {
            idx += 1; length_scale = std.fmt.parseFloat(f32, args[idx]) catch 1.0;
        } else if (std.mem.eql(u8, arg, "--threads") and has_next) {
            idx += 1; n_threads = std.fmt.parseInt(u32, args[idx], 10) catch 0;
        }
    }

    if (n_threads == 0) n_threads = detectThreadCount();

    const mp = model_path orelse {
        printErr("Missing --model argument\n", .{});
        return;
    };
    const txt = text orelse {
        printErr("Missing --text argument\n", .{});
        return;
    };
    const op = output_path orelse {
        printErr("Missing --output argument\n", .{});
        return;
    };

    // Initialize phonemizer
    printErr("Initializing espeak-ng voice: {s}\n", .{voice});
    phonemize_mod.init(voice) catch |err| {
        printErr("Failed to init espeak-ng: {s}\n", .{@errorName(err)});
        return;
    };
    defer phonemize_mod.deinit();

    printErr("Loading TTS model: {s}\n", .{mp});

    var model = try vits_mod.VitsModel.init(allocator, mp, n_threads);
    defer model.deinit();

    printErr("Model loaded (d_model={d}, enc_layers={d}, sample_rate={d}, threads={d})\n", .{
        model.config.d_model,
        model.config.n_enc_layers,
        model.config.sample_rate,
        n_threads,
    });

    printErr("Synthesizing: \"{s}\"\n", .{txt});

    const start_ns = getTimeNs();
    const result = try tts_mod.synthesizeToWav(allocator, &model, txt, op, noise_scale, length_scale);
    const elapsed_ns = getTimeNs() - start_ns;

    printErr(
        \\
        \\--- Stats ---
        \\Phonemes:    {d}
        \\Samples:     {d}
        \\Duration:    {d}ms
        \\Synthesis:   {d}ms
        \\Output:      {s}
        \\
    , .{
        result.phoneme_count,
        result.n_samples,
        result.durationMs(),
        elapsed_ns / 1_000_000,
        op,
    });
}

fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
}

test "gguf module compiles" {
    _ = gguf_mod;
}

test "tensor module compiles" {
    _ = tensor_mod;
}

test "tokenizer module compiles" {
    _ = tokenizer_mod;
}

test "math module compiles" {
    _ = math;
}

test "quant module compiles" {
    _ = quant;
}

test "model module compiles" {
    _ = model_mod;
}

test "sampler module compiles" {
    _ = sampler_mod;
}

test "generate module compiles" {
    _ = generate_mod;
}

test "kv_cache module compiles" {
    _ = kv_cache;
}

const thread_pool = @import("thread_pool.zig");
test "thread_pool module compiles" {
    _ = thread_pool;
}

test "whisper_loader module compiles" {
    _ = whisper_loader;
}

test "audio module compiles" {
    _ = audio_mod;
}

test "whisper module compiles" {
    _ = whisper_mod;
}

test "whisper_decode module compiles" {
    _ = whisper_decode;
}

const conv_mod = @import("conv.zig");
test "conv module compiles" {
    _ = conv_mod;
}

test "image module compiles" {
    _ = image_mod;
}

test "vision_loader module compiles" {
    _ = vision_loader;
}

test "u2net module compiles" {
    _ = u2net_mod;
}

test "segment module compiles" {
    _ = segment_mod;
}

test "tts_conv1d module compiles" {
    _ = tts_conv1d_mod;
}

test "wav_writer module compiles" {
    _ = wav_writer_mod;
}

test "vits module compiles" {
    _ = vits_mod;
}

test "tts module compiles" {
    _ = tts_mod;
}

// Note: phonemize module not tested here as it requires espeak-ng linked

test "leakyRelu basic" {
    var x = [_]f32{ -2.0, -1.0, 0.0, 1.0, 2.0 };
    math.leakyRelu(&x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), x[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), x[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), x[4], 1e-5);
}

test "tanh basic" {
    var x = [_]f32{ 0.0, 1.0, -1.0 };
    math.tanh(&x);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7616), x[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.7616), x[2], 0.01);
}

test "exp basic" {
    var x = [_]f32{ 0.0, 1.0, -1.0 };
    math.exp(&x);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.7183), x[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3679), x[2], 0.01);
}

test "cumsum basic" {
    var x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    math.cumsum(&x);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), x[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), x[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), x[3], 1e-5);
}

test "addScalar basic" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    var out: [3]f32 = undefined;
    math.addScalar(&out, &a, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), out[2], 1e-5);
}

test "mulScalar basic" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    var out: [3]f32 = undefined;
    math.mulScalar(&out, &a, 2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), out[2], 1e-5);
}

test "conv1d k=1 basic" {
    // 2-channel input, length 3 → 1 output channel, k=1
    const input = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 }; // [2 × 3]
    const weight = [_]f32{ 1.0, 2.0 }; // [1 × 2 × 1]
    const bias = [_]f32{0.5};
    var out: [3]f32 = undefined;
    tts_conv1d_mod.conv1d(&out, &input, &weight, &bias, 2, 3, 1, 1, 1, 0, 1, null);
    // out[0] = 0.5 + 1*1 + 2*4 = 9.5
    // out[1] = 0.5 + 1*2 + 2*5 = 12.5
    // out[2] = 0.5 + 1*3 + 2*6 = 15.5
    try std.testing.expectApproxEqAbs(@as(f32, 9.5), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 15.5), out[2], 1e-5);
}

test "depthwise conv1d basic" {
    // 2 channels, length 4, kernel 3, pad 1
    const input = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 }; // [2 × 4]
    const weight = [_]f32{ 1, 1, 1, 1, 1, 1 }; // [2 × 1 × 3]
    const bias = [_]f32{ 0, 0 };
    var out: [8]f32 = undefined;
    tts_conv1d_mod.depthwiseConv1d(&out, &input, &weight, &bias, 2, 4, 3, 1, 1);
    // ch0: [0+1+2, 1+2+3, 2+3+4, 3+4+0] = [3, 6, 9, 7]
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), out[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), out[3], 1e-5);
}

// ── Unit tests for core math ops ──

test "rmsnorm basic" {
    var x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const w = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    var out: [4]f32 = undefined;
    math.rmsnorm(&out, &x, &w, 1e-5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.3651), out[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4606), out[3], 0.01);
}

test "softmax basic" {
    var x = [_]f32{ 1.0, 2.0, 3.0 };
    math.softmax(&x);

    var sum: f32 = 0.0;
    for (x) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);
    try std.testing.expect(x[2] > x[1]);
    try std.testing.expect(x[1] > x[0]);
}

test "silu basic" {
    var x = [_]f32{ 0.0, 1.0, -1.0 };
    math.silu(&x);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7311), x[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2689), x[2], 0.01);
}

test "argmax" {
    const x = [_]f32{ 1.0, 3.0, 2.0, 5.0, 4.0 };
    try std.testing.expectEqual(@as(u32, 3), math.argmax(&x));
}

test "layernorm basic" {
    var x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const w = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const b = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var out: [4]f32 = undefined;
    math.layernorm(&out, &x, &w, &b, 1e-5);

    // Mean = 2.5, var = 1.25, should normalize to roughly [-1.34, -0.45, 0.45, 1.34]
    try std.testing.expectApproxEqAbs(@as(f32, -1.3416), out[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.3416), out[3], 0.01);
}

test "gelu basic" {
    var x = [_]f32{ 0.0, 1.0, -1.0 };
    math.gelu(&x);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8412), x[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1588), x[2], 0.01);
}

test "sigmoid basic" {
    var x = [_]f32{ 0.0, 10.0, -10.0 };
    math.sigmoid(&x);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), x[0], 1e-5);
    try std.testing.expect(x[1] > 0.999);
    try std.testing.expect(x[2] < 0.001);
}

test "conv2d 1x1" {
    // 1-channel 2x2 input, 1x1 conv to 1 output channel
    const input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const weight = [_]f32{2.0};
    const bias = [_]f32{0.5};
    var out: [4]f32 = undefined;
    conv_mod.conv2d(&out, &input, &weight, &bias, 1, 2, 2, 1, 1, 1, 0, 1, null);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.5), out[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8.5), out[3], 1e-5);
}

test "maxpool2d basic" {
    // 1 channel 4x4 -> 2x2
    const input = [_]f32{
        1, 2, 3, 4,
        5, 6, 7, 8,
        9, 10, 11, 12,
        13, 14, 15, 16,
    };
    var out: [4]f32 = undefined;
    conv_mod.maxpool2d(&out, &input, 1, 4, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), out[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), out[3], 1e-5);
}

test "relu basic" {
    var x = [_]f32{ -1.0, 0.0, 1.0, -0.5 };
    conv_mod.relu(&x);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), x[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), x[3], 1e-5);
}

test "Q4_0 dequantize" {
    var block = quant.BlockQ4_0{
        .scale = @as(f16, 1.0),
        .quants = .{0x88} ** 16,
    };
    var out: [32]f32 = undefined;
    quant.dequantizeQ4_0(&block, &out);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 1e-5);
}

test "dot product f32 simd" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    const b = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    const result = quant.dotF32Simd(&a, &b, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 36.0), result, 1e-5);
}

// ══════════════════════════════════════════════════════════════════════════
// External-anchor dequant golden tests.
//
// Inputs (block byte layouts) and expected outputs are both derived from the
// published GGML quantization format spec — NOT from this engine's own output.
// Each block dtype below (Q8_0/Q4_0/Q4_1/Q6_K/Q4_K) has a fixed on-disk layout
// and a fixed dequant formula in ggml-quants.c; a bug in the nibble/bit
// unpacking, the scale/min application, or the -8/-32 zero-point bias would
// change these numbers. These replace the prior single all-0x88→0 Q4_0 case,
// which only exercised the degenerate zero block.
// ══════════════════════════════════════════════════════════════════════════

test "dequant golden: Q8_0 (out = quant * scale)" {
    // ggml Q8_0: 32 signed i8 quants scaled by one f16 delta.
    var block = quant.BlockQ8_0{ .scale = @as(f16, 3.0), .quants = .{0} ** 32 };
    block.quants[0] = 1;
    block.quants[1] = -1;
    block.quants[2] = 10;
    block.quants[3] = 127;
    block.quants[4] = -128;
    var out: [32]f32 = undefined;
    quant.dequantizeQ8_0(&block, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), out[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), out[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 381.0), out[3], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -384.0), out[4], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[5], 1e-4);
}

test "dequant golden: Q4_0 (out = (nibble - 8) * scale, lo->0..15 hi->16..31)" {
    // ggml Q4_0: low nibble of byte j -> element j, high nibble -> element j+16,
    // each with a -8 zero-point, scaled by one f16 delta.
    var block = quant.BlockQ4_0{ .scale = @as(f16, 2.0), .quants = .{0x88} ** 16 };
    block.quants[0] = 0xF0; // lo=0, hi=15
    block.quants[1] = 0x8A; // lo=10, hi=8
    var out: [32]f32 = undefined;
    quant.dequantizeQ4_0(&block, &out);
    try std.testing.expectApproxEqAbs(@as(f32, -16.0), out[0], 1e-4); // (0-8)*2
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), out[16], 1e-4); // (15-8)*2
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), out[1], 1e-4); // (10-8)*2
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[17], 1e-4); // (8-8)*2
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-4); // (8-8)*2
}

test "dequant golden: Q4_1 (out = nibble * scale + min)" {
    // ggml Q4_1: like Q4_0 but affine (scale, min) with NO zero-point subtraction.
    var block = quant.BlockQ4_1{ .scale = @as(f16, 2.0), .min = @as(f16, 1.0), .quants = .{0} ** 16 };
    block.quants[0] = 0x31; // lo=1, hi=3
    var out: [32]f32 = undefined;
    quant.dequantizeQ4_1(&block, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[0], 1e-4); // 1*2+1
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), out[16], 1e-4); // 3*2+1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[1], 1e-4); // 0*2+1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[17], 1e-4); // 0*2+1
}

test "dequant golden: Q6_K (6-bit split ql/qh, -32 zero-point, sub-block scales)" {
    // ggml Q6_K super-block of 256. With every ql/qh nibble zero and unit scales,
    // each output is d*scale*(0-32) = -32. We perturb the first element only:
    // ql[0]=0x0A (low nibble 10), qh[0]=0x01 (its 2 high bits = 1) -> q1 = 10|(1<<4)=26,
    // so out[0] = 1*1*(26-32) = -6. A nibble-swap or missing-high-bits bug moves out[0].
    var block = quant.BlockQ6_K{
        .ql = .{0} ** 128,
        .qh = .{0} ** 64,
        .scales = .{1} ** 16,
        .d = @as(f16, 1.0),
    };
    block.ql[0] = 0x0A;
    block.qh[0] = 0x01;
    var out: [256]f32 = undefined;
    quant.dequantizeQ6_K(&block, &out);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), out[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -32.0), out[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -32.0), out[64], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -32.0), out[255], 1e-4);
}

test "dequant golden: Q4_K (affine sub-blocks, 6-bit packed scale/min)" {
    // ggml Q4_K super-block of 256. First 32 outputs use sub-block 0 (scale=scales[0],
    // min=scales[4]); the next 32 use sub-block 1 (scale=scales[1], min=scales[5]).
    // d=dmin=1.0, scales[0]=2, scales[1]=3, scales[4]=1, scales[5]=1, qs[0]=0x21.
    //   out[0]  = d1*(qs[0]&0xF) - m1 = 2*1 - 1 = 1
    //   out[32] = d2*(qs[0]>>4)  - m2 = 3*2 - 1 = 5
    var block = quant.BlockQ4_K{
        .d = @as(f16, 1.0),
        .dmin = @as(f16, 1.0),
        .scales = .{0} ** 12,
        .qs = .{0} ** 128,
    };
    block.scales[0] = 2;
    block.scales[1] = 3;
    block.scales[4] = 1;
    block.scales[5] = 1;
    block.qs[0] = 0x21;
    var out: [256]f32 = undefined;
    quant.dequantizeQ4_K(&block, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 1e-4); // 2*0 - 1
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), out[32], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), out[33], 1e-4); // 3*0 - 1
}

// ══════════════════════════════════════════════════════════════════════════
// GGUF reader robustness: malformed / truncated files must be REJECTED with a
// clean error, never read out of bounds. These exercise the bounds-checked
// Reader + header validation in gguf.zig. The FFI libraries build ReleaseFast
// (safety off), so an unchecked cursor here would fault on unmapped pages.
// ══════════════════════════════════════════════════════════════════════════

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}
fn le64(v: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    return b;
}

fn writeTempFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    const n = std.c.write(fd, bytes.ptr, bytes.len);
    if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
}

fn expectGgufError(bytes: []const u8, expected: anyerror) !void {
    const path = "/tmp/ziginfer_gguf_robustness_test.gguf";
    try writeTempFile(path, bytes);
    defer _ = std.c.unlink(path.ptr);
    // testing.allocator would flag any leak: verifies open() cleans up on reject.
    try std.testing.expectError(expected, gguf_mod.GGUFFile.open(std.testing.allocator, path));
}

test "gguf reject: file smaller than header floor" {
    try expectGgufError(&[_]u8{ 'G', 'G', 'U', 'F', 3, 0 }, error.FileTooSmall);
}

test "gguf reject: bad magic" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try buf.appendSlice(a, "XXXX"); // wrong magic
    try buf.appendSlice(a, &le32(3)); // version
    try buf.appendSlice(a, &le64(0)); // tensor_count
    try buf.appendSlice(a, &le64(0)); // metadata_kv_count
    try expectGgufError(buf.items, error.InvalidMagic);
}

test "gguf reject: absurd metadata_kv_count (> file size)" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try buf.appendSlice(a, "GGUF");
    try buf.appendSlice(a, &le32(3));
    try buf.appendSlice(a, &le64(0)); // tensor_count
    try buf.appendSlice(a, &le64(0xFFFF_FFFF)); // metadata_kv_count: absurd
    try expectGgufError(buf.items, error.CorruptHeader);
}

test "gguf reject: metadata string length overruns EOF" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try buf.appendSlice(a, "GGUF");
    try buf.appendSlice(a, &le32(3));
    try buf.appendSlice(a, &le64(0)); // tensor_count
    try buf.appendSlice(a, &le64(1)); // metadata_kv_count = 1
    try buf.appendSlice(a, &le64(1_000_000)); // key length: runs past EOF
    // (no key bytes follow) -> readString must reject, not slice past the mmap.
    try expectGgufError(buf.items, error.Truncated);
}

test "gguf reject: tensor n_dims > 4 (would overflow dims[4])" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try buf.appendSlice(a, "GGUF");
    try buf.appendSlice(a, &le32(3));
    try buf.appendSlice(a, &le64(1)); // tensor_count = 1
    try buf.appendSlice(a, &le64(0)); // metadata_kv_count = 0
    try buf.appendSlice(a, &le64(1)); // tensor name length = 1
    try buf.append(a, 'a'); // tensor name
    try buf.appendSlice(a, &le32(99)); // n_dims = 99 (invalid)
    try expectGgufError(buf.items, error.InvalidTensorDims);
}

test "gguf reject: general.alignment = 0" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    const key = "general.alignment";
    try buf.appendSlice(a, "GGUF");
    try buf.appendSlice(a, &le32(3));
    try buf.appendSlice(a, &le64(0)); // tensor_count = 0
    try buf.appendSlice(a, &le64(1)); // metadata_kv_count = 1
    try buf.appendSlice(a, &le64(key.len)); // key length
    try buf.appendSlice(a, key); // key
    try buf.appendSlice(a, &le32(4)); // value type = uint32
    try buf.appendSlice(a, &le32(0)); // value = 0 (invalid alignment)
    try expectGgufError(buf.items, error.InvalidAlignment);
}

// ══════════════════════════════════════════════════════════════════════════
// External-anchor embedding test (gated on ZIGINFER_TEST_MODEL pointing at a
// real Qwen3-Embedding GGUF, e.g. models/Qwen3-Embedding-4B-Q8_0.gguf).
//
// Skipped when the env var is unset so `zig build test` stays hermetic and
// fast. When enabled it anchors against model-external facts: the embed()
// contract L2-normalizes (‖v‖≈1), and the model's learned semantics rank a
// topically-relevant document above an unrelated one under cosine similarity.
// ══════════════════════════════════════════════════════════════════════════

fn cosineOfNormalized(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    for (a, b) |x, y| dot += x * y;
    return dot;
}

test "embed golden: real-model L2-norm + semantic ordering (gated)" {
    const env_ptr = std.c.getenv("ZIGINFER_TEST_MODEL") orelse return;
    const model_path = std.mem.span(env_ptr);
    // Use the C allocator: the model makes many long-lived allocations and we
    // don't want the leak detector to fail on any internal buffer it retains.
    const allocator = std.heap.c_allocator;

    var model = try model_mod.Model.init(allocator, model_path, 4);
    defer model.deinit();

    const d = model.config.d_model;
    const query = try allocator.alloc(f32, d);
    defer allocator.free(query);
    const relevant = try allocator.alloc(f32, d);
    defer allocator.free(relevant);
    const unrelated = try allocator.alloc(f32, d);
    defer allocator.free(unrelated);

    try embedText(&model, allocator, "The capital of France is Paris.", query);
    try embedText(&model, allocator, "Paris is the capital city of France.", relevant);
    try embedText(&model, allocator, "Photosynthesis converts sunlight into chemical energy.", unrelated);

    // embed() L2-normalizes: each vector should have unit length.
    for ([_][]const f32{ query, relevant, unrelated }) |v| {
        var norm_sq: f32 = 0;
        for (v) |x| norm_sq += x * x;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm_sq, 1e-2);
    }

    // The relevant document must be closer (higher cosine) to the query.
    const sim_rel = cosineOfNormalized(query, relevant);
    const sim_unrel = cosineOfNormalized(query, unrelated);
    try std.testing.expect(sim_rel > sim_unrel);
}

fn embedText(model: *model_mod.Model, allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const enc = try model.tokenizer.encode(allocator, text, false);
    defer allocator.free(enc);
    var tokens: std.ArrayListUnmanaged(u32) = .empty;
    defer tokens.deinit(allocator);
    try tokens.appendSlice(allocator, enc);
    if (model.tokenizer.add_eos_default) try tokens.append(allocator, model.tokenizer.eos_id);
    _ = model.embed(tokens.items, out);
}
