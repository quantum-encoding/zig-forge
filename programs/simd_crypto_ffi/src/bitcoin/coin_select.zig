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

/// Select UTXOs to fund a transaction
///
/// Uses Branch and Bound as primary algorithm, falls back to Largest-First.
///
/// Parameters:
/// - utxos: Available UTXOs to select from
/// - utxo_count: Number of UTXOs
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

    if (params.target_amount < tx_builder.DUST_LIMIT) {
        return CoinSelectError.TargetBelowDust;
    }

    // Calculate total available
    var total_available: u64 = 0;
    for (utxos) |utxo| {
        total_available += utxo.value;
    }

    // Quick check: do we have enough total?
    const min_fee = calculateFee(1, params.output_count, params.fee_rate);
    if (total_available < params.target_amount + min_fee) {
        return CoinSelectError.InsufficientFunds;
    }

    // Try Branch and Bound first (for exact matches)
    const bnb_result = branchAndBound(utxos, params);
    if (bnb_result) |bnb| {
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
/// Returns null if no solution found within iteration limit.
fn branchAndBound(
    utxos: []const CoinUtxo,
    params: SelectionParams,
) ?SelectionResult {
    if (utxos.len == 0 or utxos.len > SelectionResult.MAX_SELECTION) {
        return null;
    }

    // Sort UTXOs by value descending for better pruning
    var sorted_indices: [SelectionResult.MAX_SELECTION]usize = undefined;
    var sorted_values: [SelectionResult.MAX_SELECTION]u64 = undefined;
    const n = @min(utxos.len, SelectionResult.MAX_SELECTION);

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

    // Calculate target with fee (no change output)
    const target_no_change = params.target_amount + calculateFee(1, params.output_count, params.fee_rate);

    // Calculate target with change output
    const target_with_change = params.target_amount + calculateFee(1, params.output_count + 1, params.fee_rate);

    // Cost of creating change (output + future spending)
    const change_cost = CHANGE_OUTPUT_COST * params.fee_rate;

    // Search state
    var current_selection: [SelectionResult.MAX_SELECTION]bool = [_]bool{false} ** SelectionResult.MAX_SELECTION;
    var current_value: u64 = 0;
    var current_input_count: usize = 0;

    // Best solution found
    var best_selection: [SelectionResult.MAX_SELECTION]bool = [_]bool{false} ** SelectionResult.MAX_SELECTION;
    var best_value: u64 = 0;
    var best_waste: i64 = std.math.maxInt(i64);
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
            // Leaf node: evaluate solution
            if (current_value >= target_no_change) {
                // Calculate fee for this selection
                const fee = calculateFee(current_input_count, params.output_count, params.fee_rate);

                if (current_value >= params.target_amount + fee) {
                    const excess = current_value - params.target_amount - fee;

                    // Calculate "waste" - excess that becomes either change or fee
                    var waste: i64 = undefined;
                    if (excess == 0) {
                        // Perfect match - no waste
                        waste = 0;
                    } else if (excess < params.min_change) {
                        // Excess too small for change, add to fee
                        waste = @intCast(excess);
                    } else {
                        // Create change output
                        waste = @intCast(change_cost);
                    }

                    if (waste < best_waste) {
                        best_waste = waste;
                        best_value = current_value;
                        best_selection = current_selection;
                        found_solution = true;

                        // Perfect match? Stop searching
                        if (waste == 0) {
                            break;
                        }
                    }
                }
            }
            backtrack = true;
            continue;
        }

        // Calculate remaining value from unprocessed UTXOs
        var remaining: u64 = 0;
        for (depth..n) |i| {
            remaining += sorted_values[i];
        }

        // Pruning: if we can't reach target even with all remaining, backtrack
        if (current_value + remaining < target_no_change) {
            backtrack = true;
            continue;
        }

        // Pruning: if current value already exceeds target + max acceptable waste
        if (current_value > target_with_change + @as(u64, @intCast(@max(0, best_waste)))) {
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

    // Calculate change
    const final_fee = calculateFee(result.selected_count, params.output_count, params.fee_rate);
    const excess = result.total_value - params.target_amount - final_fee;

    if (excess < params.min_change) {
        // Add excess to fee (no change output)
        result.change_amount = 0;
        result.is_exact_match = (excess == 0);
    } else {
        // Create change output
        result.change_amount = excess;
        result.is_exact_match = false;
    }

    return result;
}

// =============================================================================
// Largest-First Algorithm
// =============================================================================

/// Largest-First coin selection
///
/// Simple greedy algorithm: select largest UTXOs until target is met.
/// Always succeeds if sufficient funds are available.
pub fn largestFirst(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
) CoinSelectError!void {
    if (utxos.len == 0) {
        return CoinSelectError.NoUtxosAvailable;
    }

    const n = @min(utxos.len, SelectionResult.MAX_SELECTION);

    // Sort by value descending
    var sorted_indices: [SelectionResult.MAX_SELECTION]usize = undefined;
    var sorted_values: [SelectionResult.MAX_SELECTION]u64 = undefined;

    for (0..n) |i| {
        sorted_indices[i] = i;
        sorted_values[i] = utxos[i].value;
    }

    // Insertion sort descending
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

    // Select UTXOs until we have enough
    result.selected_count = 0;
    result.total_value = 0;
    result.algorithm_used = .largest_first;

    for (0..n) |i| {
        // Calculate required amount with current selection
        const fee = calculateFee(result.selected_count + 1, params.output_count + 1, params.fee_rate);
        const required = params.target_amount + fee + params.min_change;

        if (result.total_value >= required) {
            break; // We have enough
        }

        // Add this UTXO
        result.selected_indices[result.selected_count] = utxos[sorted_indices[i]].original_index;
        result.total_value += sorted_values[i];
        result.selected_count += 1;
    }

    // Check if we have enough
    const final_fee = calculateFee(result.selected_count, params.output_count, params.fee_rate);
    if (result.total_value < params.target_amount + final_fee) {
        return CoinSelectError.InsufficientFunds;
    }

    // Calculate change
    const excess = result.total_value - params.target_amount - final_fee;
    if (excess < params.min_change) {
        result.change_amount = 0;
        result.is_exact_match = (excess == 0);
    } else {
        result.change_amount = excess;
        result.is_exact_match = false;
    }
}

// =============================================================================
// Smallest-First Algorithm
// =============================================================================

/// Smallest-First coin selection
///
/// Greedy algorithm: select smallest UTXOs first.
/// Good for consolidating dust, but creates larger transactions.
pub fn smallestFirst(
    utxos: []const CoinUtxo,
    params: SelectionParams,
    result: *SelectionResult,
) CoinSelectError!void {
    if (utxos.len == 0) {
        return CoinSelectError.NoUtxosAvailable;
    }

    const n = @min(utxos.len, SelectionResult.MAX_SELECTION);

    // Sort by value ascending
    var sorted_indices: [SelectionResult.MAX_SELECTION]usize = undefined;
    var sorted_values: [SelectionResult.MAX_SELECTION]u64 = undefined;

    for (0..n) |i| {
        sorted_indices[i] = i;
        sorted_values[i] = utxos[i].value;
    }

    // Insertion sort ascending
    for (1..n) |i| {
        const key_idx = sorted_indices[i];
        const key_val = sorted_values[i];
        var j: usize = i;
        while (j > 0 and sorted_values[j - 1] > key_val) {
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
    result.algorithm_used = .smallest_first;

    for (0..n) |i| {
        const fee = calculateFee(result.selected_count + 1, params.output_count + 1, params.fee_rate);
        const required = params.target_amount + fee + params.min_change;

        if (result.total_value >= required) {
            break;
        }

        result.selected_indices[result.selected_count] = utxos[sorted_indices[i]].original_index;
        result.total_value += sorted_values[i];
        result.selected_count += 1;
    }

    const final_fee = calculateFee(result.selected_count, params.output_count, params.fee_rate);
    if (result.total_value < params.target_amount + final_fee) {
        return CoinSelectError.InsufficientFunds;
    }

    const excess = result.total_value - params.target_amount - final_fee;
    if (excess < params.min_change) {
        result.change_amount = 0;
        result.is_exact_match = (excess == 0);
    } else {
        result.change_amount = excess;
        result.is_exact_match = false;
    }
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate transaction fee in satoshis
///
/// Parameters:
/// - input_count: Number of inputs
/// - output_count: Number of outputs
/// - fee_rate: Satoshis per virtual byte
pub fn calculateFee(input_count: usize, output_count: usize, fee_rate: u64) u64 {
    const vsize = estimateVsize(input_count, output_count);
    return vsize * fee_rate;
}

/// Estimate transaction virtual size
pub fn estimateVsize(input_count: usize, output_count: usize) u64 {
    // P2WPKH transaction structure:
    // - 4 bytes version
    // - 1 byte marker (0x00)
    // - 1 byte flag (0x01)
    // - 1-3 bytes input count (varint)
    // - inputs: 68 vbytes each for P2WPKH
    // - 1-3 bytes output count (varint)
    // - outputs: 31 bytes each for P2WPKH
    // - 4 bytes locktime
    const base: u64 = TX_OVERHEAD_VSIZE;
    const inputs: u64 = @as(u64, @intCast(input_count)) * INPUT_VSIZE_P2WPKH;
    const outputs: u64 = @as(u64, @intCast(output_count)) * OUTPUT_VSIZE_P2WPKH;
    return base + inputs + outputs;
}

/// Check if a value is above dust threshold
pub fn isAboveDust(value: u64) bool {
    return value >= tx_builder.DUST_LIMIT;
}

/// Calculate effective value of a UTXO at given fee rate
/// (value minus cost to spend it)
pub fn effectiveValue(utxo: CoinUtxo, fee_rate: u64) i64 {
    const spend_cost = @as(u64, @intCast(utxo.input_vsize)) * fee_rate;
    if (utxo.value < spend_cost) {
        return -@as(i64, @intCast(spend_cost - utxo.value));
    }
    return @as(i64, @intCast(utxo.value - spend_cost));
}

// =============================================================================
// Tests
// =============================================================================

test "calculate fee" {
    // 1 input, 1 output at 10 sat/vbyte
    // vsize = 11 (overhead) + 68 (input) + 31 (output) = 110
    const fee = calculateFee(1, 1, 10);
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

    const maybe_result = branchAndBound(&utxos, params);
    try std.testing.expect(maybe_result != null);

    const result = maybe_result.?;
    try std.testing.expectEqual(@as(usize, 1), result.selected_count);
    try std.testing.expectEqual(@as(u64, 50000), result.total_value);
    try std.testing.expect(result.is_exact_match or result.change_amount < tx_builder.DUST_LIMIT);
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
