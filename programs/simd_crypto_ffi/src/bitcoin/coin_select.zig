// =============================================================================
// Coin Selection Module
// =============================================================================
// Implements Bitcoin coin selection algorithms for optimal UTXO spending.
//
// Algorithms:
// 1. Branch and Bound (BnB) - Primary algorithm, aims for exact matches
// 2. Largest-First - Fallback when BnB fails
//
// Design Goals:
// - Minimize fees by reducing transaction size
// - Preserve privacy by avoiding unnecessary UTXO consolidation
// - Avoid creating dust change outputs
// - Find exact matches when possible (no change output needed)
// =============================================================================

const std = @import("std");
const tx_builder = @import("tx_builder.zig");

/// Coin selection error types
pub const CoinSelectError = error{
    InsufficientFunds,
    NoUtxosAvailable,
    TargetBelowDust,
    TooManyUtxos,
    SelectionFailed,
    /// The UTXO values sum past 2^64 - 1: no real UTXO set does, so the list is corrupt.
    AmountOutOfRange,
};

/// Result of coin selection
pub const SelectionResult = struct {
    /// Indices of selected UTXOs from the input array
    selected_indices: [MAX_SELECTION]usize,
    /// Number of selected UTXOs
    selected_count: usize,
    /// Total value of selected UTXOs
    total_value: u64,
    /// Expected change amount (0 if exact match)
    change_amount: u64,
    /// Whether this was an exact match (no change needed)
    is_exact_match: bool,
    /// Algorithm used for selection
    algorithm_used: Algorithm,

    pub const MAX_SELECTION: usize = 256;
};

/// Available selection algorithms
pub const Algorithm = enum(u8) {
    branch_and_bound = 0,
    largest_first = 1,
    smallest_first = 2,
    manual = 3,
};

/// Coin selection parameters
pub const SelectionParams = struct {
    /// Target amount to send (in satoshis)
    target_amount: u64,
    /// Fee rate in satoshis per virtual byte
    fee_rate: u64,
    /// Number of outputs (affects fee calculation)
    output_count: usize,
    /// Minimum change amount (below this, add to fee instead)
    min_change: u64,
    /// Whether to prefer avoiding change
    prefer_no_change: bool,

    /// Default parameters for typical P2WPKH transaction
    pub fn default(target: u64, fee_rate: u64) SelectionParams {
        return SelectionParams{
            .target_amount = target,
            .fee_rate = fee_rate,
            .output_count = 1,
            .min_change = tx_builder.DUST_LIMIT,
            .prefer_no_change = true,
        };
    }
};

/// UTXO for coin selection (minimal data needed for selection)
pub const CoinUtxo = struct {
    /// Value in satoshis
    value: u64,
    /// Original index in the UTXO pool
    original_index: usize,
    /// Size contribution for this input type (vbytes)
    /// P2WPKH input: ~68 vbytes (witness data has 75% discount)
    input_vsize: usize,

    /// Default P2WPKH input size
    pub fn p2wpkh(value: u64, index: usize) CoinUtxo {
        return CoinUtxo{
            .value = value,
            .original_index = index,
            .input_vsize = INPUT_VSIZE_P2WPKH,
        };
    }
};

// =============================================================================
// Constants
// =============================================================================

/// P2WPKH input virtual size (68 vbytes)
/// - 32 bytes txid
/// - 4 bytes vout
/// - 1 byte scriptSig length (0 for SegWit)
/// - 4 bytes sequence
/// - Witness: (1 + 72 + 1 + 33) / 4 = ~27 vbytes
pub const INPUT_VSIZE_P2WPKH: usize = 68;

/// P2WPKH output size (31 bytes, no discount)
pub const OUTPUT_VSIZE_P2WPKH: usize = 31;

/// Transaction overhead (version + locktime + segwit marker/flag + counts)
pub const TX_OVERHEAD_VSIZE: usize = 11;

/// Maximum iterations for Branch and Bound
const BNB_MAX_ITERATIONS: usize = 100_000;

/// Cost of change output (creating + spending later)
/// Includes the output now + future input to spend it
const CHANGE_OUTPUT_COST: usize = OUTPUT_VSIZE_P2WPKH + INPUT_VSIZE_P2WPKH;

// =============================================================================
// Main Selection Function
// =============================================================================
//
// Overflow discipline. UTXO values arrive from a block explorer and the target and fee rate
// from the caller, and the Apple slices compile overflow checks out, so no amount here is
// added or multiplied with a bare operator:
//   * the UTXO values are summed once with std.math.add; a list that sums past 2^64 - 1 is
//     corrupt and refused with AmountOutOfRange, which bounds every later partial sum;
//   * a fee or a target + fee that does not fit in 64 bits exceeds any total that does, so
//     it is InsufficientFunds, exactly;
//   * search bounds and greedy stopping points saturate (`+|`), because "at least
//     2^64 - 1" is exactly what they mean; the final funding check is always the checked one.

/// Sum of every UTXO's value; AmountOutOfRange if it does not fit in a u64.
fn totalValue(utxos: []const CoinUtxo) CoinSelectError!u64 {
    var total: u64 = 0;
    for (utxos) |utxo| {
        total = std.math.add(u64, total, utxo.value) catch return CoinSelectError.AmountOutOfRange;
    }
    return total;
}

/// The fee for a transaction shape; one past 2^64 - 1 sats can never be paid.
fn feeFor(input_count: usize, output_count: usize, fee_rate: u64) CoinSelectError!u64 {
    return calculateFee(input_count, output_count, fee_rate) catch CoinSelectError.InsufficientFunds;
}

/// target + fee; a sum past 2^64 - 1 exceeds every total a UTXO list can have.
fn amountNeeded(target: u64, fee: u64) CoinSelectError!u64 {
    return std.math.add(u64, target, fee) catch CoinSelectError.InsufficientFunds;
}

/// Fill change_amount and is_exact_match for a selection holding at least `needed`.
fn settleChange(result: *SelectionResult, needed: u64, min_change: u64) void {
    const excess = result.total_value - needed;
    if (excess < min_change) {
        // Excess too small for a change output: it goes to the fee.
        result.change_amount = 0;
        result.is_exact_match = (excess == 0);
    } else {
        result.change_amount = excess;
        result.is_exact_match = false;
    }
}

/// Select UTXOs to fund a transaction
///
/// Uses Branch and Bound as primary algorithm, falls back to Largest-First.
///
/// Parameters:
/// - utxos: Available UTXOs to select from (at most SelectionResult.MAX_SELECTION)
/// - params: Selection parameters (target, fee rate, etc.)
/// - result: Output selection result
///
/// Returns: Error or success
pub fn selectCoins(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
) CoinSelectError!void {
    if (utxos.len == 0) {
        return CoinSelectError.NoUtxosAvailable;
    }
    if (utxos.len > SelectionResult.MAX_SELECTION) {
        return CoinSelectError.TooManyUtxos;
    }

    if (params.target_amount < tx_builder.DUST_LIMIT) {
        return CoinSelectError.TargetBelowDust;
    }

    const total_available = try totalValue(utxos);

    // Quick check: do we have enough total?
    const min_fee = try feeFor(1, params.output_count, params.fee_rate);
    if (total_available < try amountNeeded(params.target_amount, min_fee)) {
        return CoinSelectError.InsufficientFunds;
    }

    // Try Branch and Bound first (for exact matches)
    if (try branchAndBound(utxos, params)) |bnb| {
        result.* = bnb;
        return;
    }

    // Fall back to Largest-First
    return largestFirst(utxos, params, result);
}

// =============================================================================
// Branch and Bound Algorithm
// =============================================================================

/// Branch and Bound coin selection
///
/// Attempts to find an exact match (no change) or minimal change.
/// Based on Bitcoin Core's implementation.
///
/// Only called by selectCoins, after totalValue(utxos) succeeded, so no sum of a subset of
/// the values can overflow.
///
/// Returns null if no solution found within iteration limit.
fn branchAndBound(
    utxos: []const CoinUtxo,
    params: SelectionParams,
) CoinSelectError!?SelectionResult {
    if (utxos.len == 0 or utxos.len > SelectionResult.MAX_SELECTION) {
        return null;
    }

    // Sort UTXOs by value descending for better pruning
    var sorted_indices: [SelectionResult.MAX_SELECTION]usize = undefined;
    var sorted_values: [SelectionResult.MAX_SELECTION]u64 = undefined;
    const n = utxos.len;

    for (0..n) |i| {
        sorted_indices[i] = i;
        sorted_values[i] = utxos[i].value;
    }

    // Simple insertion sort (good for small arrays)
    for (1..n) |i| {
        const key_idx = sorted_indices[i];
        const key_val = sorted_values[i];
        var j: usize = i;
        while (j > 0 and sorted_values[j - 1] < key_val) {
            sorted_indices[j] = sorted_indices[j - 1];
            sorted_values[j] = sorted_values[j - 1];
            j -= 1;
        }
        sorted_indices[j] = key_idx;
        sorted_values[j] = key_val;
    }

    // remaining_from[i]: the value of sorted UTXOs i..n-1, for the reachability prune.
    var remaining_from: [SelectionResult.MAX_SELECTION + 1]u64 = undefined;
    remaining_from[n] = 0;
    var k: usize = n;
    while (k > 0) {
        k -= 1;
        remaining_from[k] = remaining_from[k + 1] + sorted_values[k];
    }

    // Calculate target with fee (no change output)
    const target_no_change = try amountNeeded(params.target_amount, try feeFor(1, params.output_count, params.fee_rate));

    // Target with a change output: only an upper pruning bound, so it saturates.
    const fee_with_change = calculateFee(1, params.output_count +| 1, params.fee_rate) catch std.math.maxInt(u64);
    const target_with_change = params.target_amount +| fee_with_change;

    // Cost of creating change (output + future spending), saturating like any waste figure.
    const change_cost = std.math.mul(u64, CHANGE_OUTPUT_COST, params.fee_rate) catch std.math.maxInt(u64);

    // Search state
    var current_selection: [SelectionResult.MAX_SELECTION]bool = @splat(false);
    var current_value: u64 = 0;
    var current_input_count: usize = 0;

    // Best solution found
    var best_selection: [SelectionResult.MAX_SELECTION]bool = @splat(false);
    var best_waste: u64 = std.math.maxInt(u64);
    var found_solution = false;

    // Depth-first search with pruning
    var iterations: usize = 0;
    var depth: usize = 0;
    var backtrack = false;

    while (iterations < BNB_MAX_ITERATIONS) {
        iterations += 1;

        if (backtrack) {
            // Backtracking: find the last selected UTXO and deselect it
            while (depth > 0) {
                depth -= 1;
                if (current_selection[depth]) {
                    current_selection[depth] = false;
                    current_value -= sorted_values[depth];
                    current_input_count -= 1;
                    depth += 1; // Move to next branch (exclusion)
                    break;
                }
            }
            if (depth == 0 and !current_selection[0]) {
                break; // Exhausted all possibilities
            }
            backtrack = false;
            continue;
        }

        if (depth >= n) {
            // Leaf node: evaluate solution. A fee or need past 64 bits cannot be met here.
            const fee = feeFor(current_input_count, params.output_count, params.fee_rate) catch null;
            const needed = if (fee) |f| amountNeeded(params.target_amount, f) catch null else null;
            if (needed != null and current_value >= target_no_change and current_value >= needed.?) {
                const excess = current_value - needed.?;

                // "Waste": excess that becomes either change or fee
                const waste: u64 = if (excess == 0)
                    0 // Perfect match - no waste
                else if (excess < params.min_change)
                    excess // Excess too small for change, added to the fee
                else
                    change_cost; // Create change output

                if (!found_solution or waste < best_waste) {
                    best_waste = waste;
                    best_selection = current_selection;
                    found_solution = true;

                    // Perfect match? Stop searching
                    if (waste == 0) {
                        break;
                    }
                }
            }
            backtrack = true;
            continue;
        }

        // Pruning: if we can't reach target even with all remaining, backtrack
        if (current_value + remaining_from[depth] < target_no_change) {
            backtrack = true;
            continue;
        }

        // Pruning: if current value already exceeds target + max acceptable waste
        if (current_value > target_with_change +| best_waste) {
            backtrack = true;
            continue;
        }

        // Include current UTXO
        current_selection[depth] = true;
        current_value += sorted_values[depth];
        current_input_count += 1;
        depth += 1;
    }

    if (!found_solution) {
        return null;
    }

    // Build result
    var result = SelectionResult{
        .selected_indices = undefined,
        .selected_count = 0,
        .total_value = 0,
        .change_amount = 0,
        .is_exact_match = false,
        .algorithm_used = .branch_and_bound,
    };

    for (0..n) |i| {
        if (best_selection[i]) {
            result.selected_indices[result.selected_count] = utxos[sorted_indices[i]].original_index;
            result.selected_count += 1;
            result.total_value += sorted_values[i];
        }
    }

    const needed = try amountNeeded(params.target_amount, try feeFor(result.selected_count, params.output_count, params.fee_rate));
    if (result.total_value < needed) return CoinSelectError.SelectionFailed;
    settleChange(&result, needed, params.min_change);
    return result;
}

// =============================================================================
// Greedy Algorithms (Largest-First, Smallest-First)
// =============================================================================

const GreedyOrder = enum { largest_first, smallest_first };

fn greedySelect(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
    comptime order: GreedyOrder,
) CoinSelectError!void {
    if (utxos.len == 0) {
        return CoinSelectError.NoUtxosAvailable;
    }
    // A selection over only the first MAX_SELECTION UTXOs would ignore the rest silently.
    if (utxos.len > SelectionResult.MAX_SELECTION) {
        return CoinSelectError.TooManyUtxos;
    }
    // Refuse a corrupt list up front; every running total below is then bounded by it.
    _ = try totalValue(utxos);

    const n = utxos.len;

    var sorted_indices: [SelectionResult.MAX_SELECTION]usize = undefined;
    var sorted_values: [SelectionResult.MAX_SELECTION]u64 = undefined;

    for (0..n) |i| {
        sorted_indices[i] = i;
        sorted_values[i] = utxos[i].value;
    }

    // Insertion sort, descending for largest-first and ascending for smallest-first
    for (1..n) |i| {
        const key_idx = sorted_indices[i];
        const key_val = sorted_values[i];
        var j: usize = i;
        while (j > 0 and switch (order) {
            .largest_first => sorted_values[j - 1] < key_val,
            .smallest_first => sorted_values[j - 1] > key_val,
        }) {
            sorted_indices[j] = sorted_indices[j - 1];
            sorted_values[j] = sorted_values[j - 1];
            j -= 1;
        }
        sorted_indices[j] = key_idx;
        sorted_values[j] = key_val;
    }

    // Select UTXOs until we have enough
    result.selected_count = 0;
    result.total_value = 0;
    result.algorithm_used = switch (order) {
        .largest_first => .largest_first,
        .smallest_first => .smallest_first,
    };

    for (0..n) |i| {
        // Enough for the target, the fee with one more input and a change output, and the
        // minimum change. Saturating: a requirement past 2^64 - 1 only means keep selecting.
        const fee = calculateFee(result.selected_count + 1, params.output_count +| 1, params.fee_rate) catch std.math.maxInt(u64);
        const required = params.target_amount +| fee +| params.min_change;

        if (result.total_value >= required) {
            break; // We have enough
        }

        // Add this UTXO
        result.selected_indices[result.selected_count] = utxos[sorted_indices[i]].original_index;
        result.total_value += sorted_values[i];
        result.selected_count += 1;
    }

    // Check if we have enough
    const needed = try amountNeeded(params.target_amount, try feeFor(result.selected_count, params.output_count, params.fee_rate));
    if (result.total_value < needed) {
        return CoinSelectError.InsufficientFunds;
    }
    settleChange(result, needed, params.min_change);
}

/// Largest-First coin selection
///
/// Simple greedy algorithm: select largest UTXOs until target is met.
/// Always succeeds if sufficient funds are available.
pub fn largestFirst(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
) CoinSelectError!void {
    return greedySelect(utxos, params, result, .largest_first);
}

/// Smallest-First coin selection
///
/// Greedy algorithm: select smallest UTXOs first.
/// Good for consolidating dust, but creates larger transactions.
pub fn smallestFirst(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
) CoinSelectError!void {
    return greedySelect(utxos, params, result, .smallest_first);
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate transaction fee in satoshis: estimateVsize * fee_rate, exact whenever the fee fits
/// in a u64 (a rate of 0 is a fee of 0 however large the size); error.Overflow otherwise.
///
/// Parameters:
/// - input_count: Number of inputs
/// - output_count: Number of outputs
/// - fee_rate: Satoshis per virtual byte
pub fn calculateFee(input_count: usize, output_count: usize, fee_rate: u64) error{Overflow}!u64 {
    // The size is below 2^71, so the product overflows u128 only when it is far past 2^64.
    const fee = try std.math.mul(u128, exactVsize(input_count, output_count), fee_rate);
    return std.math.cast(u64, fee) orelse error.Overflow;
}

/// Estimate transaction virtual size; error.Overflow if it does not fit in a u64.
pub fn estimateVsize(input_count: usize, output_count: usize) error{Overflow}!u64 {
    return std.math.cast(u64, exactVsize(input_count, output_count)) orelse error.Overflow;
}

/// The virtual size, exactly: 11 + 68 * inputs + 31 * outputs is below 2^71 for any counts.
fn exactVsize(input_count: usize, output_count: usize) u128 {
    // P2WPKH transaction structure:
    // - 4 bytes version
    // - 1 byte marker (0x00)
    // - 1 byte flag (0x01)
    // - 1-3 bytes input count (varint)
    // - inputs: 68 vbytes each for P2WPKH
    // - 1-3 bytes output count (varint)
    // - outputs: 31 bytes each for P2WPKH
    // - 4 bytes locktime
    return @as(u128, TX_OVERHEAD_VSIZE) +
        @as(u128, input_count) * INPUT_VSIZE_P2WPKH +
        @as(u128, output_count) * OUTPUT_VSIZE_P2WPKH;
}

/// Check if a value is above dust threshold
pub fn isAboveDust(value: u64) bool {
    return value >= tx_builder.DUST_LIMIT;
}

/// Calculate effective value of a UTXO at given fee rate (value minus cost to spend it),
/// clamped to i64: a value above maxInt(i64) or a spend cost that sinks it below
/// minInt(i64) saturates instead of wrapping.
pub fn effectiveValue(utxo: CoinUtxo, fee_rate: u64) i64 {
    // (2^64 - 1)^2 fits in a u128, so the cost is exact.
    const spend_cost = @as(u128, utxo.input_vsize) * fee_rate;
    const value: u128 = utxo.value;
    if (value >= spend_cost) {
        return std.math.cast(i64, value - spend_cost) orelse std.math.maxInt(i64);
    }
    const deficit = spend_cost - value;
    if (deficit >= @as(u128, 1) << 63) return std.math.minInt(i64);
    return -@as(i64, @intCast(deficit));
}

// =============================================================================
// Tests
// =============================================================================

test "calculate fee" {
    // 1 input, 1 output at 10 sat/vbyte
    // vsize = 11 (overhead) + 68 (input) + 31 (output) = 110
    const fee = try calculateFee(1, 1, 10);
    try std.testing.expectEqual(@as(u64, 1100), fee);
}

test "largest first basic" {
    var utxos = [_]CoinUtxo{
        CoinUtxo.p2wpkh(50000, 0),
        CoinUtxo.p2wpkh(100000, 1),
        CoinUtxo.p2wpkh(25000, 2),
    };

    const params = SelectionParams.default(75000, 10);
    var result: SelectionResult = undefined;

    try largestFirst(&utxos, params, &result);

    // Should select the 100000 UTXO (largest)
    try std.testing.expectEqual(@as(usize, 1), result.selected_count);
    try std.testing.expectEqual(@as(usize, 1), result.selected_indices[0]); // Index of 100000
    try std.testing.expectEqual(@as(u64, 100000), result.total_value);
    try std.testing.expectEqual(Algorithm.largest_first, result.algorithm_used);
}

test "smallest first basic" {
    var utxos = [_]CoinUtxo{
        CoinUtxo.p2wpkh(50000, 0),
        CoinUtxo.p2wpkh(100000, 1),
        CoinUtxo.p2wpkh(25000, 2),
    };

    const params = SelectionParams.default(60000, 10);
    var result: SelectionResult = undefined;

    try smallestFirst(&utxos, params, &result);

    // Should select 25000 + 50000 first, then maybe 100000
    try std.testing.expect(result.selected_count >= 2);
    try std.testing.expectEqual(Algorithm.smallest_first, result.algorithm_used);
}

test "insufficient funds" {
    var utxos = [_]CoinUtxo{
        CoinUtxo.p2wpkh(10000, 0),
        CoinUtxo.p2wpkh(20000, 1),
    };

    const params = SelectionParams.default(100000, 10); // Target > available
    var result: SelectionResult = undefined;

    const err = selectCoins(&utxos, params, &result);
    try std.testing.expectError(CoinSelectError.InsufficientFunds, err);
}

test "branch and bound exact match" {
    var utxos = [_]CoinUtxo{
        CoinUtxo.p2wpkh(50000, 0),
        CoinUtxo.p2wpkh(60000, 1),
        CoinUtxo.p2wpkh(40000, 2),
    };

    // Fee for 1 input, 1 output at 10 sat/vb = 1100
    // Target 48900 + 1100 fee = 50000 exactly
    const params = SelectionParams.default(48900, 10);

    const maybe_result = try branchAndBound(&utxos, params);
    try std.testing.expect(maybe_result != null);

    const result = maybe_result.?;
    try std.testing.expectEqual(@as(usize, 1), result.selected_count);
    try std.testing.expectEqual(@as(u64, 50000), result.total_value);
    try std.testing.expect(result.is_exact_match or result.change_amount < tx_builder.DUST_LIMIT);
}

test "selection over more than MAX_SELECTION UTXOs is refused, not truncated" {
    var utxos: [SelectionResult.MAX_SELECTION + 1]CoinUtxo = undefined;
    for (&utxos, 0..) |*u, i| u.* = CoinUtxo.p2wpkh(1_000, i);
    // The one UTXO that could fund the target sits past the first MAX_SELECTION.
    utxos[SelectionResult.MAX_SELECTION] = CoinUtxo.p2wpkh(10_000_000, SelectionResult.MAX_SELECTION);
    const params = SelectionParams.default(5_000_000, 1);
    var result: SelectionResult = undefined;
    try std.testing.expectError(CoinSelectError.TooManyUtxos, largestFirst(&utxos, params, &result));
    try std.testing.expectError(CoinSelectError.TooManyUtxos, smallestFirst(&utxos, params, &result));
    try std.testing.expectError(CoinSelectError.TooManyUtxos, selectCoins(&utxos, params, &result));
}

test "amounts, fees and values that overflow 64 bits are refused or saturated, never wrapped" {
    const max = std.math.maxInt(u64);
    var result: SelectionResult = undefined;

    // The report's PoC 5: target u64::MAX - 100 against one 10 000-sat UTXO wrapped
    // target + fee, selected the UTXO and reported change 9001.
    var one = [_]CoinUtxo{CoinUtxo.p2wpkh(10_000, 0)};
    const huge_target = SelectionParams.default(max - 100, 10);
    try std.testing.expectError(error.InsufficientFunds, selectCoins(&one, huge_target, &result));
    try std.testing.expectError(error.InsufficientFunds, largestFirst(&one, huge_target, &result));
    try std.testing.expectError(error.InsufficientFunds, smallestFirst(&one, huge_target, &result));

    // A fee rate whose fee does not fit in 64 bits can never be paid.
    var rich = [_]CoinUtxo{CoinUtxo.p2wpkh(max - 1, 0)};
    const huge_rate = SelectionParams.default(10_000, max / 50);
    try std.testing.expectError(error.InsufficientFunds, selectCoins(&rich, huge_rate, &result));
    try std.testing.expectError(error.InsufficientFunds, largestFirst(&rich, huge_rate, &result));
    try std.testing.expectError(error.InsufficientFunds, smallestFirst(&rich, huge_rate, &result));

    // UTXO values from an explorer that sum past 64 bits are a corrupt list, not 0 sats.
    var two = [_]CoinUtxo{ CoinUtxo.p2wpkh(1 << 63, 0), CoinUtxo.p2wpkh(1 << 63, 1) };
    const small = SelectionParams.default(1_000, 1);
    try std.testing.expectError(error.AmountOutOfRange, selectCoins(&two, small, &result));
    try std.testing.expectError(error.AmountOutOfRange, largestFirst(&two, small, &result));
    try std.testing.expectError(error.AmountOutOfRange, smallestFirst(&two, small, &result));

    // Effective value saturates at the ends of i64.
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), effectiveValue(CoinUtxo.p2wpkh(max, 0), 0));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), effectiveValue(CoinUtxo.p2wpkh(0, 0), max));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), effectiveValue(CoinUtxo.p2wpkh(0, 0), (1 << 63) / INPUT_VSIZE_P2WPKH + 1));
}

test "calculateFee and estimateVsize are exact whenever the result fits, Overflow otherwise" {
    // walletcore's prop_zig_fee_helpers_never_wrap grid, against a u128 oracle.
    const counts = [_]usize{ 0, 1, 2, 200, std.math.maxInt(u32), std.math.maxInt(usize) / 68, std.math.maxInt(usize) };
    const rates = [_]u64{ 0, 1, 1000, std.math.maxInt(u64) / 110, std.math.maxInt(u64) };
    for (counts) |i| for (counts) |o| {
        const vsize: u128 = 11 + 68 * @as(u128, i) + 31 * @as(u128, o);
        if (vsize <= std.math.maxInt(u64)) {
            try std.testing.expectEqual(@as(u64, @intCast(vsize)), try estimateVsize(i, o));
        } else {
            try std.testing.expectError(error.Overflow, estimateVsize(i, o));
        }
        for (rates) |r| {
            const fee = vsize *| r;
            if (fee <= std.math.maxInt(u64)) {
                try std.testing.expectEqual(@as(u64, @intCast(fee)), try calculateFee(i, o, r));
            } else {
                try std.testing.expectError(error.Overflow, calculateFee(i, o, r));
            }
        }
    };
}

test "calculateFee and estimateVsize report overflow" {
    try std.testing.expectError(error.Overflow, calculateFee(1, 1, std.math.maxInt(u64)));
    try std.testing.expectError(error.Overflow, estimateVsize(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.Overflow, estimateVsize(1, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(u64, 110), try estimateVsize(1, 1));
}

test "effective value" {
    const utxo = CoinUtxo.p2wpkh(10000, 0);

    // At 10 sat/vb, cost to spend is 68 * 10 = 680
    // Effective value = 10000 - 680 = 9320
    const eff = effectiveValue(utxo, 10);
    try std.testing.expectEqual(@as(i64, 9320), eff);

    // At very high fee rate, effective value can be negative
    const eff_high = effectiveValue(utxo, 200);
    try std.testing.expect(eff_high < 0);
}

test "select coins integration" {
    var utxos = [_]CoinUtxo{
        CoinUtxo.p2wpkh(100000, 0),
        CoinUtxo.p2wpkh(50000, 1),
        CoinUtxo.p2wpkh(75000, 2),
    };

    const params = SelectionParams.default(80000, 5);
    var result: SelectionResult = undefined;

    try selectCoins(&utxos, params, &result);

    // Should find a valid selection
    try std.testing.expect(result.selected_count > 0);
    try std.testing.expect(result.total_value >= 80000);
}
