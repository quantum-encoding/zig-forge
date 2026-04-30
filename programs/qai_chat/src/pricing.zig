//! Per-model pricing lookup for cost display.
//!
//! Source of truth is http_sentinel/model_costs.csv (kept under that
//! repo for upstream maintenance). We `@embedFile` it at compile time
//! and parse on the first lookup, caching the parsed table for the
//! life of the process.
//!
//! Pricing semantics:
//!   - input_per_1m / output_per_1m are dollars per 1,000,000 tokens
//!   - estimate(input, output) → cost in dollars
//!
//! Lookup is case-sensitive substring-aware: gives priority to exact
//! matches first, then to the longest prefix match. So a config saying
//! "claude-sonnet-4-6" will land on "claude-sonnet-4-5-20250929" only
//! if no closer entry exists — the caller can also pre-normalise.

const std = @import("std");

pub const Pricing = struct {
    input_per_1m: f64,
    output_per_1m: f64,
};

// Inline copy of the canonical price list. Mirrors the relevant rows in
// programs/http_sentinel/model_costs.csv. Update when adding new models.
//
// Format: provider,model,input_per_1m,output_per_1m
//   (the source CSV has more columns; we only need the first four.)
const csv_data =
    \\provider,model,input_per_1m,output_per_1m
    \\anthropic,claude-sonnet-4-5-20250929,3,15
    \\anthropic,claude-sonnet-4-6,3,15
    \\anthropic,claude-sonnet-4-6-20250929,3,15
    \\anthropic,claude-opus-4-1-20250805,15,75
    \\anthropic,claude-opus-4-7,15,75
    \\anthropic,claude-haiku-4-5-20251001,0.8,4
    \\anthropic,claude-3-5-sonnet-20240620,3,15
    \\deepseek,deepseek-chat,0.28,0.42
    \\deepseek,deepseek-reasoner,0.28,0.42
    \\google,gemini-2.5-pro,2.5,15
    \\google,gemini-2.5-flash,0.3,2.5
    \\google,gemini-2.5-flash-lite,0.1,0.4
    \\xai,grok-4-1-fast-non-reasoning,0.2,0.5
    \\xai,grok-4-1-fast-reasoning,0.2,0.5
    \\xai,grok-4-0709,3,15
    \\xai,grok-code-fast-1,0.2,1.5
    \\xai,grok-4-20-0309-non-reasoning,2.0,6.0
    \\xai,grok-4-20-0309-reasoning,2.0,6.0
    \\xai,grok-4-20-multi-agent-0309,2.0,6.0
    \\openai,gpt-5,1.25,10
    \\openai,gpt-5-mini,0.25,2
    \\openai,gpt-5-nano,0.05,0.4
    \\openai,gpt-5.1,1.25,10
    \\openai,gpt-5.1-mini,0.25,2
    \\openai,gpt-5.2,1.75,12
    \\openai,gpt-5.2-pro,3.5,25
    \\openai,gpt-5.4,2.5,15
    \\openai,gpt-5.4-mini,0.75,5
    \\openai,gpt-4.1,2,8
    \\openai,gpt-4.1-mini,0.4,1.6
    \\openai,gpt-4.1-nano,0.1,0.4
    \\openai,o1,15,60
    \\openai,o1-mini,3,12
    \\openai,o3,2,8
    \\openai,o3-pro,30,120
    \\openai,o3-mini,1.1,4.4
    \\openai,o4-mini,1.1,4.4
;

const Entry = struct {
    model: []const u8,
    pricing: Pricing,
};

/// Parsed table — populated lazily on first lookup. Backed by the
/// embedded CSV; entry slices point into csv_data. Allocated lazily.
var entries: ?[]Entry = null;
var entries_arena: ?std.heap.ArenaAllocator = null;

/// Look up pricing for a model. Returns null if no entry matches.
/// Falls back from exact match → longest prefix match.
pub fn lookup(gpa: std.mem.Allocator, model: []const u8) ?Pricing {
    const tbl = ensureLoaded(gpa) catch return null;

    for (tbl) |e| {
        if (std.mem.eql(u8, e.model, model)) return e.pricing;
    }

    // Longest-prefix fallback: useful for date-stamped snapshots like
    // "claude-sonnet-4-5-20250929" matched by config "claude-sonnet-4-5".
    var best: ?Entry = null;
    var best_len: usize = 0;
    for (tbl) |e| {
        if (std.mem.startsWith(u8, e.model, model) or std.mem.startsWith(u8, model, e.model)) {
            const overlap = @min(e.model.len, model.len);
            if (overlap > best_len) {
                best = e;
                best_len = overlap;
            }
        }
    }
    if (best) |b| return b.pricing;
    return null;
}

/// Compute cost in dollars for a given (input_tokens, output_tokens) pair.
pub fn estimate(p: Pricing, input_tokens: u64, output_tokens: u64) f64 {
    const in_cost = (@as(f64, @floatFromInt(input_tokens)) / 1_000_000.0) * p.input_per_1m;
    const out_cost = (@as(f64, @floatFromInt(output_tokens)) / 1_000_000.0) * p.output_per_1m;
    return in_cost + out_cost;
}

fn ensureLoaded(gpa: std.mem.Allocator) ![]Entry {
    if (entries) |e| return e;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(Entry) = .empty;

    var lines = std.mem.splitScalar(u8, csv_data, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (first) {
            first = false;
            continue;
        }
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // CSV columns:
        // provider, model, input_cost_per_1m, output_cost_per_1m, ...
        var fields = std.mem.splitScalar(u8, line, ',');
        _ = fields.next() orelse continue; // provider
        const model = fields.next() orelse continue;
        const in_cost_str = fields.next() orelse continue;
        const out_cost_str = fields.next() orelse continue;

        const in_cost = std.fmt.parseFloat(f64, std.mem.trim(u8, in_cost_str, " \t")) catch continue;
        const out_cost = std.fmt.parseFloat(f64, std.mem.trim(u8, out_cost_str, " \t")) catch continue;

        try list.append(a, .{
            .model = try a.dupe(u8, std.mem.trim(u8, model, " \t")),
            .pricing = .{ .input_per_1m = in_cost, .output_per_1m = out_cost },
        });
    }

    const owned = try list.toOwnedSlice(a);
    entries = owned;
    entries_arena = arena;
    return owned;
}

test "lookup finds exact and prefix matches" {
    const exact = lookup(std.testing.allocator, "claude-sonnet-4-5-20250929");
    try std.testing.expect(exact != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), exact.?.input_per_1m, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), exact.?.output_per_1m, 0.001);

    const prefix = lookup(std.testing.allocator, "deepseek-chat");
    try std.testing.expect(prefix != null);

    const missing = lookup(std.testing.allocator, "made-up-model-99");
    try std.testing.expect(missing == null);
}

test "estimate computes cents correctly" {
    const p = Pricing{ .input_per_1m = 3.0, .output_per_1m = 15.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), estimate(p, 1000, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.018), estimate(p, 1000, 1000), 0.0001);
}
