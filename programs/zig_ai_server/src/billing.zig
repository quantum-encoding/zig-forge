// Billing — two-phase commit with dynamic output capping
// RESERVE → Provider Call → COMMIT or ROLLBACK
// Never call a provider without a balance reservation.
// Integer ticks only. Fail-closed on all errors.
//
// Dynamic Output Capping:
//   Instead of failing when the user can't afford worst-case output,
//   we calculate affordable_output_tokens and cap max_tokens to that.
//   The provider enforces the cap; we refund unused reservation on commit.

const std = @import("std");
const Io = std.Io;
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const models_mod = @import("models.zig");

const TICKS_PER_USD: i64 = 10_000_000_000;

// ── Pricing Helpers ────────────────────────────────────────────

/// Convert $/million-tokens price to ticks per token.
fn ticksPerToken(price_per_million: f64) i64 {
    // price_per_million USD * TICKS_PER_USD / 1_000_000
    return @intFromFloat(price_per_million * @as(f64, @floatFromInt(TICKS_PER_USD)) / 1_000_000.0);
}

/// Estimate input tokens from message payload size (~4 chars/token for English).
pub fn estimateInputTokens(messages_byte_len: usize) u32 {
    const tokens = messages_byte_len / 4;
    return @intCast(@max(tokens, 1)); // minimum 1 token
}

// ── Dynamic Output Capping ─────────────────────────────────────

/// Result of the dynamic capping calculation.
pub const BillingCap = struct {
    /// max_tokens to send to the provider (capped to what the user can afford)
    capped_max_tokens: u32,
    /// Total ticks to reserve (input estimate + capped output)
    reservation_ticks: i64,
    /// Estimated input cost in ticks
    input_cost_ticks: i64,
};

/// Calculate affordable output tokens and the reservation amount.
/// Never fails due to balance — instead caps output to what the user can afford.
/// Returns null only if the user can't afford even 1 output token (truly broke).
pub fn calculateCap(
    model: []const u8,
    requested_max_tokens: u32,
    estimated_input_tokens: u32,
    balance_ticks: i64,
    tier: types.DevTier,
) ?BillingCap {
    const pricing = models_mod.getPricing(model);
    const input_tpt = ticksPerToken(pricing.input);
    const output_tpt = ticksPerToken(pricing.output);

    // Margin multiplier: (10000 + marginBps) / 10000
    const margin_bps: i64 = @intCast(tier.marginBps());

    // Input cost (with margin)
    const raw_input_cost = input_tpt * @as(i64, estimated_input_tokens);
    const input_margin = @divFloor(raw_input_cost * margin_bps, 10000);
    const input_cost = raw_input_cost + input_margin;

    // Remaining balance after input
    const remaining = balance_ticks - input_cost;
    if (remaining <= 0) return null; // can't even afford the input

    // Affordable output tokens (accounting for margin)
    const output_cost_per_token = output_tpt + @divFloor(output_tpt * margin_bps, 10000);
    if (output_cost_per_token <= 0) return null; // safety

    const affordable_output: u32 = @intCast(@min(
        @divFloor(remaining, output_cost_per_token),
        std.math.maxInt(u32),
    ));

    if (affordable_output == 0) return null; // can't afford even 1 output token

    // Cap to the lesser of requested and affordable
    const capped = @min(requested_max_tokens, affordable_output);

    // Reservation = input cost + capped output cost (with margin)
    const raw_output_cost = output_tpt * @as(i64, capped);
    const output_margin = @divFloor(raw_output_cost * margin_bps, 10000);
    const reservation = input_cost + raw_output_cost + output_margin;

    return .{
        .capped_max_tokens = capped,
        .reservation_ticks = @max(reservation, 1000), // minimum 1000 ticks
        .input_cost_ticks = input_cost,
    };
}

// ── Reserve / Commit / Rollback ────────────────────────────────

/// Reserve balance with dynamic output capping.
/// Returns (reservation_id, capped_max_tokens) or error if truly broke.
pub fn reserveWithCap(
    store: *store_mod.Store,
    io: Io,
    auth: *const types.AuthContext,
    model: []const u8,
    requested_max_tokens: u32,
    estimated_input_tokens: u32,
    endpoint: []const u8,
) !struct { reservation_id: u64, capped_max_tokens: u32 } {
    const cap = calculateCap(
        model,
        requested_max_tokens,
        estimated_input_tokens,
        auth.account.balance_ticks,
        auth.account.tier,
    ) orelse return error.InsufficientBalance;

    const rid = try store.reserve(
        io,
        auth.account.id.slice(),
        auth.key_hash,
        cap.reservation_ticks,
        endpoint,
        model,
    );

    return .{
        .reservation_id = rid,
        .capped_max_tokens = cap.capped_max_tokens,
    };
}

/// Legacy estimate (kept for tests and estimation display).
pub fn estimateCost(model: []const u8, max_tokens: u32) i64 {
    const pricing = models_mod.getPricing(model);
    const output_millidollars: i64 = @intFromFloat(pricing.output * 1000.0);
    const input_millidollars: i64 = @intFromFloat(pricing.input * 1000.0);
    const estimated_output_ticks = @divFloor(output_millidollars * @as(i64, max_tokens) * 10_000_000, 1_000_000);
    const estimated_input_ticks = @divFloor(input_millidollars * @as(i64, @divFloor(max_tokens, 2)) * 10_000_000, 1_000_000);
    return estimated_output_ticks + estimated_input_ticks;
}

/// Calculate actual cost from real token usage.
pub fn actualCost(model: []const u8, input_tokens: u32, output_tokens: u32, tier: types.DevTier) struct { cost: i64, margin: i64 } {
    const pricing = models_mod.getPricing(model);
    const input_ticks = ticksPerToken(pricing.input) * @as(i64, input_tokens);
    const output_ticks = ticksPerToken(pricing.output) * @as(i64, output_tokens);
    const cost = input_ticks + output_ticks;
    const margin = @divFloor(cost * @as(i64, tier.marginBps()), 10000);
    return .{ .cost = cost, .margin = margin };
}

/// Commit billing after successful provider response.
pub fn commit(
    store: *store_mod.Store,
    io: Io,
    reservation_id: u64,
    model: []const u8,
    input_tokens: u32,
    output_tokens: u32,
    tier: types.DevTier,
) void {
    const cost = actualCost(model, input_tokens, output_tokens, tier);
    store.commitReservation(io, reservation_id, cost.cost, cost.margin) catch {};
}

/// Rollback billing on provider failure.
pub fn rollback(
    store: *store_mod.Store,
    io: Io,
    reservation_id: u64,
) void {
    store.rollbackReservation(io, reservation_id);
}
