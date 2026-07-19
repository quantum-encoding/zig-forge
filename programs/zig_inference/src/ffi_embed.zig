//! Lean embedding-only FFI surface.
//!
//! This is a separate library root from `ffi.zig` on purpose: it imports ONLY the
//! modules needed for text embedding (GGUF + model + tokenizer + math), so the
//! resulting static library links nothing beyond libc. No espeak-ng, no Whisper,
//! no Vision/TTS, no stb. That keeps it safe to embed in a sandboxed, notarized
//! macOS app where dragging in espeak-ng and its data files is a liability.
//!
//! Build: `zig build embed-lib` -> zig-out/lib/libziginfer_embed.a
//! Handle lifecycle: create once, embed many times, destroy at shutdown.
//! NOT thread-safe per handle — serialize calls or use one handle per thread.

const std = @import("std");
const model_mod = @import("model.zig");

/// Load a model from a GGUF path, auto-detecting thread count. Returns an opaque
/// handle or null on failure.
export fn ziginfer_create(model_path: [*:0]const u8) ?*model_mod.Model {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_threads: u32 = if (cpu_count >= 1) @intCast(cpu_count) else 1;
    return createWithThreads(model_path, n_threads);
}

/// Load a model with an explicit thread count (0 = auto-detect).
export fn ziginfer_create_with_threads(model_path: [*:0]const u8, n_threads: u32) ?*model_mod.Model {
    const threads = if (n_threads == 0) blk: {
        const c = std.Thread.getCpuCount() catch 1;
        break :blk @as(u32, if (c >= 1) @intCast(c) else 1);
    } else n_threads;
    return createWithThreads(model_path, threads);
}

fn createWithThreads(model_path: [*:0]const u8, n_threads: u32) ?*model_mod.Model {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(model_path);
    const model = allocator.create(model_mod.Model) catch return null;
    model.* = model_mod.Model.init(allocator, path, n_threads) catch {
        allocator.destroy(model);
        return null;
    };
    return model;
}

/// Free a model handle.
export fn ziginfer_destroy(model: *model_mod.Model) void {
    model.deinit();
    std.heap.c_allocator.destroy(model);
}

/// Native embedding dimension (d_model) for this model: 0.6B=1024, 4B=2560, 8B=4096.
/// Use this to size the `out` buffer for ziginfer_embed.
export fn ziginfer_embed_dim(model: *model_mod.Model) u32 {
    return model.config.d_model;
}

/// Embed `text` into a normalized vector written to `out` (capacity in floats).
///
///   is_query != 0 : wrap as "Instruct: {task}\nQuery:{text}" (Qwen3-Embedding query
///                   form). task may be null or "" for the default retrieval instruction.
///   is_query == 0 : embed `text` verbatim (document form).
///
/// out_capacity below d_model truncates then re-normalizes (Matryoshka / MRL).
/// Returns the number of dims written, or a negative value on error.
export fn ziginfer_embed(
    model: *model_mod.Model,
    text: [*:0]const u8,
    is_query: i32,
    task: ?[*:0]const u8,
    out: [*]f32,
    out_capacity: usize,
) i32 {
    const allocator = std.heap.c_allocator;
    const text_str = std.mem.span(text);
    const task_str = if (task) |t| std.mem.span(t) else "";

    const dim = @min(out_capacity, @as(usize, model.config.d_model));
    const written = model.embedInto(allocator, text_str, is_query != 0, task_str, out[0..dim]) catch |e| return switch (e) {
        error.EmptyInput => -2,
        else => -1,
    };
    return @intCast(written);
}
