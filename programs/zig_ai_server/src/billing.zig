// Billing — two-phase commit for provider calls
// RESERVE → Provider Call → COMMIT or ROLLBACK
// Never call a provider without a balance reservation.
// Integer ticks only. Fail-closed on all errors.

const std = @import("std");
const Io = std.Io;
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const models_mod = @import("models.zig");

/// Estimate the maximum cost of a request in ticks.
/// Uses model pricing × max_tokens as upper bound.
pub fn estimateCost(model: []const u8, max_tokens: u32) i64 {
    const pricing = models_mod.getPricing(model);
    // Conservative estimate: assume input ≈ output for estimation
    // price_per_million * max_tokens / 1M = USD cost
    // Convert to millidollars then to ticks
    const output_millidollars: i64 = @intFromFloat(pricing.output * 1000.0);
    const input_millidollars: i64 = @intFromFloat(pricing.input * 1000.0);
    // Estimate: max_tokens output + half for input
    const estimated_output_ticks = @divFloor(output_millidollars * @as(i64, max_tokens) * 10_000_000, 1_000_000);
    const estimated_input_ticks = @divFloor(input_millidollars * @as(i64, @divFloor(max_tokens, 2)) * 10_000_000, 1_000_000);
    return estimated_output_ticks + estimated_input_ticks;
}

/// Calculate actual cost from real token usage.
/// Returns (cost_ticks, margin_ticks).
pub fn actualCost(model: []const u8, input_tokens: u32, output_tokens: u32, tier: types.DevTier) struct { cost: i64, margin: i64 } {
    const pricing = models_mod.getPricing(model);
    const input_millidollars: i64 = @intFromFloat(pricing.input * 1000.0);
    const output_millidollars: i64 = @intFromFloat(pricing.output * 1000.0);
    const input_ticks = @divFloor(input_millidollars * @as(i64, input_tokens) * 10_000_000, 1_000_000);
    const output_ticks = @divFloor(output_millidollars * @as(i64, output_tokens) * 10_000_000, 1_000_000);
    const cost = input_ticks + output_ticks;

    // Margin based on tier (basis points / 10000)
    const margin = @divFloor(cost * @as(i64, tier.marginBps()), 10000);
    return .{ .cost = cost, .margin = margin };
}

/// Reserve balance before calling a provider.
/// Returns reservation_id or error (402 insufficient balance).
pub fn reserve(
    store: *store_mod.Store,
    io: Io,
    auth: *const types.AuthContext,
    model: []const u8,
    max_tokens: u32,
    endpoint: []const u8,
) !u64 {
    const estimated = estimateCost(model, max_tokens);
    // Minimum reservation: 1000 ticks (prevent zero-cost bypass)
    const amount = @max(estimated, 1000);

    return store.reserve(
        io,
        auth.account.id.slice(),
        auth.key_hash,
        amount,
        endpoint,
        model,
    );
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
