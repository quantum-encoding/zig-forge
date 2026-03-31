const std = @import("std");
const math_ops = @import("math.zig");

pub const SamplerConfig = struct {
    temperature: f32 = 0.7,
    top_k: u32 = 40,
    top_p: f32 = 0.9,
    min_p: f32 = 0.05,
    repeat_penalty: f32 = 1.1,
    seed: u64 = 0,
};

pub const Sampler = struct {
    config: SamplerConfig,
    rng: std.Random.Xoshiro256,

    pub fn init(config: SamplerConfig) Sampler {
        const seed = if (config.seed != 0) config.seed else blk: {
            var buf: [8]u8 = undefined;
            std.c.arc4random_buf(&buf, 8);
            break :blk std.mem.readInt(u64, &buf, .little);
        };

        return Sampler{
            .config = config,
            .rng = std.Random.Xoshiro256.init(seed),
        };
    }

    /// Sample next token from logits
    pub fn sample(self: *Sampler, logits: []f32, prev_tokens: []const u32) u32 {
        // 1. Apply repeat penalty (look back up to 64 tokens)
        const lookback = @min(prev_tokens.len, 64);
        if (self.config.repeat_penalty != 1.0 and lookback > 0) {
            const start = prev_tokens.len - lookback;
            for (prev_tokens[start..]) |tok| {
                if (tok < logits.len) {
                    if (logits[tok] > 0) {
                        logits[tok] /= self.config.repeat_penalty;
                    } else {
                        logits[tok] *= self.config.repeat_penalty;
                    }
                }
            }
        }

        // 2. Greedy (temperature == 0)
        if (self.config.temperature == 0.0) {
            return math_ops.argmax(logits);
        }

        // 3. Apply temperature
        const inv_temp = 1.0 / self.config.temperature;
        for (logits) |*l| l.* *= inv_temp;

        // 4. Softmax
        math_ops.softmax(logits);

        // 5. Min-P: zero out tokens below min_p * max_prob
        if (self.config.min_p > 0.0) {
            var max_prob: f32 = 0.0;
            for (logits) |l| {
                if (l > max_prob) max_prob = l;
            }
            const threshold = self.config.min_p * max_prob;
            for (logits) |*l| {
                if (l.* < threshold) l.* = 0.0;
            }
        }

        // 6. Top-K: keep only top K values
        if (self.config.top_k > 0 and self.config.top_k < logits.len) {
            applyTopK(logits, self.config.top_k);
        }

        // 7. Top-P (nucleus): zero out tail below cumulative threshold
        if (self.config.top_p < 1.0) {
            applyTopP(logits, self.config.top_p);
        }

        // 8. Renormalize
        var sum: f32 = 0.0;
        for (logits) |l| sum += l;
        if (sum > 0.0) {
            const inv_sum = 1.0 / sum;
            for (logits) |*l| l.* *= inv_sum;
        } else {
            // All zeros — fall back to uniform over vocab
            const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(logits.len));
            for (logits) |*l| l.* = inv_n;
        }

        // 9. Sample from distribution
        return sampleFromDist(logits, &self.rng);
    }
};

fn applyTopK(logits: []f32, k: u32) void {
    const n = logits.len;
    if (k >= n) return;

    // Find kth largest using a fixed-size buffer tracking top-k values
    const capped_k = @min(k, 256);
    var top: [256]f32 = undefined;
    var top_len: u32 = 0;
    var min_of_top: f32 = -std.math.inf(f32);

    for (logits) |l| {
        if (top_len < capped_k) {
            top[top_len] = l;
            top_len += 1;
            if (top_len == capped_k) {
                min_of_top = top[0];
                for (top[1..top_len]) |t| {
                    if (t < min_of_top) min_of_top = t;
                }
            }
        } else if (l > min_of_top) {
            // Replace min with this value
            for (top[0..top_len]) |*t| {
                if (t.* == min_of_top) {
                    t.* = l;
                    break;
                }
            }
            // Recompute min
            min_of_top = top[0];
            for (top[1..top_len]) |t| {
                if (t < min_of_top) min_of_top = t;
            }
        }
    }

    // Zero out everything below the kth largest
    for (logits) |*l| {
        if (l.* < min_of_top) l.* = 0.0;
    }
}

fn applyTopP(logits: []f32, p: f32) void {
    // Binary search for the probability threshold where cumsum of values >= threshold == p
    var max_prob: f32 = 0.0;
    for (logits) |l| {
        if (l > max_prob) max_prob = l;
    }

    var lo: f32 = 0.0;
    var hi: f32 = max_prob;

    for (0..32) |_| {
        const mid = (lo + hi) / 2.0;
        var cs: f32 = 0.0;
        for (logits) |l| {
            if (l >= mid) cs += l;
        }
        if (cs > p) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    for (logits) |*l| {
        if (l.* < lo) l.* = 0.0;
    }
}

fn sampleFromDist(probs: []const f32, rng: *std.Random.Xoshiro256) u32 {
    const random = rng.random();
    var r = random.float(f32);

    for (probs, 0..) |p, i| {
        r -= p;
        if (r <= 0.0) return @intCast(i);
    }

    // Shouldn't get here, but return last non-zero token
    var last: u32 = 0;
    for (probs, 0..) |p, i| {
        if (p > 0.0) last = @intCast(i);
    }
    return last;
}
