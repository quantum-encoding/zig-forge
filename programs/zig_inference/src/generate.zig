const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("model.zig");
const sampler_mod = @import("sampler.zig");

pub const GenerateResult = struct {
    tokens_generated: u32,
    prompt_tokens: u32,
    prompt_ns: u64,
    gen_ns: u64,

    pub fn promptTokPerSec(self: GenerateResult) f64 {
        if (self.prompt_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(self.prompt_tokens)) / (@as(f64, @floatFromInt(self.prompt_ns)) / 1e9);
    }

    pub fn genTokPerSec(self: GenerateResult) f64 {
        if (self.gen_ns == 0) return 0.0;
        return @as(f64, @floatFromInt(self.tokens_generated)) / (@as(f64, @floatFromInt(self.gen_ns)) / 1e9);
    }

    pub fn totalSec(self: GenerateResult) f64 {
        return @as(f64, @floatFromInt(self.prompt_ns + self.gen_ns)) / 1e9;
    }
};

/// Output callback type — called with each token's text as it's generated
pub const OutputFn = *const fn ([]const u8) void;

fn nullOutput(_: []const u8) void {}

/// Generate text from a prompt, streaming each token via output_fn
pub fn generate(
    allocator: Allocator,
    model: *model_mod.Model,
    prompt: []const u8,
    config: sampler_mod.SamplerConfig,
    max_tokens: u32,
    output_fn: OutputFn,
) !GenerateResult {
    var sampler = sampler_mod.Sampler.init(config);

    const tokens = try model.tokenizer.encode(allocator, prompt, true);
    defer allocator.free(tokens);

    if (tokens.len == 0) return GenerateResult{
        .tokens_generated = 0,
        .prompt_tokens = 0,
        .prompt_ns = 0,
        .gen_ns = 0,
    };

    var prev_tokens: std.ArrayListUnmanaged(u32) = .empty;
    defer prev_tokens.deinit(allocator);

    // Unified prefill + generation loop (like llama2.c)
    // Process each token through forward(), sampling only after prompt ends
    var token: u32 = tokens[0];
    var generated: u32 = 0;
    var prompt_ns: u64 = 0;
    var gen_ns: u64 = 0;
    const total_len = @as(u32, @intCast(tokens.len)) + max_tokens;

    var pos: u32 = 0;
    while (pos < total_len) {
        const is_prefill = pos < tokens.len;
        const timer_start = getTimeNs();

        const logits = model.forward(token, pos);

        var next_token: u32 = undefined;

        if (is_prefill) {
            // During prefill, advance to the next prompt token
            prompt_ns += getTimeNs() - timer_start;
            if (pos + 1 < tokens.len) {
                next_token = tokens[pos + 1];
            } else {
                // Last prefill position: sample from these logits
                const logits_copy = try allocator.alloc(f32, logits.len);
                defer allocator.free(logits_copy);
                @memcpy(logits_copy, logits);
                next_token = sampler.sample(logits_copy, prev_tokens.items);
                prompt_ns += getTimeNs() - timer_start - prompt_ns;
            }
        } else {
            // Generation: sample next token
            const logits_copy = try allocator.alloc(f32, logits.len);
            defer allocator.free(logits_copy);
            @memcpy(logits_copy, logits);
            next_token = sampler.sample(logits_copy, prev_tokens.items);

            gen_ns += getTimeNs() - timer_start;

            if (next_token == model.tokenizer.eos_id) break;

            // Stream output
            emitToken(model, next_token, output_fn);

            generated += 1;
        }

        try prev_tokens.append(allocator, next_token);
        token = next_token;
        pos += 1;
    }

    return GenerateResult{
        .tokens_generated = generated,
        .prompt_tokens = @intCast(tokens.len),
        .prompt_ns = prompt_ns,
        .gen_ns = gen_ns,
    };
}

/// Emit a token's text to the output function, handling SentencePiece ▁→space conversion
fn emitToken(model: *model_mod.Model, tok: u32, output_fn: OutputFn) void {
    const piece = model.tokenizer.decodeToken(tok);
    if (piece.len == 0) return;

    // Handle byte-level tokens <0xXX>
    if (piece.len == 6 and piece[0] == '<' and piece[1] == '0' and piece[2] == 'x' and piece[5] == '>') {
        const byte_val = std.fmt.parseInt(u8, piece[3..5], 16) catch return;
        const byte_arr = [1]u8{byte_val};
        output_fn(&byte_arr);
        return;
    }

    // Replace ▁ (0xE2 0x96 0x81) with space
    var j: usize = 0;
    while (j < piece.len) {
        if (j + 3 <= piece.len and piece[j] == 0xE2 and piece[j + 1] == 0x96 and piece[j + 2] == 0x81) {
            output_fn(" ");
            j += 3;
        } else {
            var end = j + 1;
            while (end < piece.len) {
                if (end + 3 <= piece.len and piece[end] == 0xE2 and piece[end + 1] == 0x96 and piece[end + 2] == 0x81) break;
                end += 1;
            }
            output_fn(piece[j..end]);
            j = end;
        }
    }
}

fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
}
