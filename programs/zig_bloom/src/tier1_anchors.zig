//! Tier-1 external anchors for zig_bloom.
//!
//! Per zig-forge/CLAUDE.md golden rule §1, a test only counts as an anchor if
//! its *expected values* come from a source the library author did not write.
//! Probabilistic data structures have no wire spec to anchor against, but they
//! do have published, closed-form guarantees — and those guarantees are the
//! external source here. Every expectation below is computed in-test from a
//! formula in the cited paper, never from an observed output of this library.
//!
//! Sources:
//!
//!  [B70]  Burton H. Bloom, "Space/Time Trade-offs in Hash Coding with
//!         Allowable Errors", CACM 13(7), 1970. Defines the one-sided error
//!         guarantee: a Bloom filter may report a false positive but *never* a
//!         false negative.
//!  [MU05] Mitzenmacher & Upfal, "Probability and Computing", §5.5.3. The
//!         false-positive probability of an m-bit, k-hash filter holding n
//!         items: (1 - e^(-kn/m))^k; the optimal parameters
//!         m = -n ln(p) / (ln 2)^2 and k = (m/n) ln 2.
//!  [KM06] Kirsch & Mitzenmacher, "Less Hashing, Same Performance: Building a
//!         Better Bloom Filter", ESA 2006. Proves the h1 + i*h2 double-hashing
//!         scheme this library uses attains the same asymptotic FP rate as k
//!         independent hashes — i.e. [MU05]'s formula is the right yardstick.
//!  [FFGM07] Flajolet, Fusy, Gandouet & Meunier, "HyperLogLog: the analysis of
//!         a near-optimal cardinality estimation algorithm", AofA 2007. The
//!         alpha_m bias-correction table and the relative standard error
//!         1.04/sqrt(m).
//!  [WVT90] Whang, Vander-Zanden & Taylor, "A Linear-Time Probabilistic
//!         Counting Algorithm for Database Applications", TODS 15(2), 1990.
//!         The linear-counting estimator n_hat = -m ln(V/m).
//!  [CM05] Cormode & Muthukrishnan, "An Improved Data Stream Summary: The
//!         Count-Min Sketch and its Applications", J. Algorithms 55(1), 2005.
//!         Dimensions w = ceil(e/eps), d = ceil(ln(1/delta)); the estimate
//!         never underestimates, and exceeds the true count by more than
//!         eps*N with probability at most delta.

const std = @import("std");
const testing = std.testing;

const bloom_filter = @import("bloom_filter.zig");
const count_min = @import("count_min.zig");
const hyperloglog = @import("hyperloglog.zig");

const BloomFilter = bloom_filter.BloomFilter;
const CountingBloomFilter = bloom_filter.CountingBloomFilter;
const format = bloom_filter.format;
const CountMinSketch = count_min.CountMinSketch;
const HyperLogLog = hyperloglog.HyperLogLog;
const SparseHyperLogLog = hyperloglog.SparseHyperLogLog;

// ============================================================================
// [B70] No false negatives — the defining Bloom-filter invariant
//
// A false positive is a tunable cost; a false negative is a correctness bug.
// The in-tree consumer (zig_token_service) checks token revocation through
// `contains`, so a false negative there is a revoked credential being
// accepted. These tests are exhaustive over the inserted set, not sampled.
// ============================================================================

test "anchor [B70]: BloomFilter never reports a false negative (string keys, exhaustive)" {
    const allocator = testing.allocator;
    const n: usize = 20_000;

    var bf = try BloomFilter([]const u8).initCapacity(allocator, n, 0.01);
    defer bf.deinit();

    var buf: [32]u8 = undefined;
    for (0..n) |i| {
        const key = try std.fmt.bufPrint(&buf, "token-{d}", .{i});
        bf.add(key);
    }

    // Every single inserted key must test positive.
    for (0..n) |i| {
        const key = try std.fmt.bufPrint(&buf, "token-{d}", .{i});
        if (!bf.contains(key)) {
            std.debug.print("false negative for inserted key '{s}'\n", .{key});
            return error.FalseNegative;
        }
    }
}

test "anchor [B70]: BloomFilter never reports a false negative (integer keys, exhaustive)" {
    const allocator = testing.allocator;
    const n: u64 = 20_000;

    var bf = try BloomFilter(u64).initCapacity(allocator, n, 0.01);
    defer bf.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) bf.add(i);

    i = 0;
    while (i < n) : (i += 1) {
        if (!bf.contains(i)) return error.FalseNegative;
    }
}

test "anchor [B70]: CountingBloomFilter never reports a false negative (exhaustive)" {
    const allocator = testing.allocator;
    const n: u64 = 20_000;

    var cbf = try CountingBloomFilter(u64).initCapacity(allocator, n, 0.01);
    defer cbf.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) cbf.add(i);

    i = 0;
    while (i < n) : (i += 1) {
        if (!cbf.contains(i)) return error.FalseNegative;
    }
}

test "anchor [B70]: union preserves membership of both operands (exhaustive)" {
    const allocator = testing.allocator;
    const n: u64 = 5_000;

    var a = try BloomFilter(u64).init(allocator, 200_000, 7);
    defer a.deinit();
    var b = try BloomFilter(u64).init(allocator, 200_000, 7);
    defer b.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        a.add(i);
        b.add(i + 1_000_000);
    }

    try a.unionWith(&b);

    // The union of two filters must contain every member of either.
    i = 0;
    while (i < n) : (i += 1) {
        if (!a.contains(i)) return error.FalseNegative;
        if (!a.contains(i + 1_000_000)) return error.FalseNegative;
    }
}

test "anchor [B70]: decoded filter answers identically to the original (exhaustive)" {
    const allocator = testing.allocator;
    const n: u64 = 5_000;

    var bf = try BloomFilter(u64).initCapacity(allocator, n, 0.01);
    defer bf.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) bf.add(i);

    const blob = try bf.encodeAlloc(allocator);
    defer allocator.free(blob);

    var restored = try BloomFilter(u64).decodeAlloc(allocator, blob);
    defer restored.deinit();

    try testing.expectEqual(bf.num_bits, restored.num_bits);
    try testing.expectEqual(bf.num_hashes, restored.num_hashes);
    try testing.expectEqual(bf.count, restored.count);

    // Membership answers must survive the round trip, positives and negatives
    // alike — a decoder that dropped or reordered words would still satisfy
    // "inserted keys test positive" if it set too many bits.
    i = 0;
    while (i < n * 2) : (i += 1) {
        try testing.expectEqual(bf.contains(i), restored.contains(i));
    }
}

// ============================================================================
// [MU05] / [KM06] Measured false-positive rate vs the published bound
// ============================================================================

/// [MU05] §5.5.3: probability a given bit is still 0 after n insertions with k
/// hashes into m bits is (1 - 1/m)^(kn) ≈ e^(-kn/m); a false positive requires
/// all k probed bits to be set.
fn theoreticalFpRate(m: usize, k: u32, n: usize) f64 {
    const mf = @as(f64, @floatFromInt(m));
    const kf = @as(f64, @floatFromInt(k));
    const nf = @as(f64, @floatFromInt(n));
    return std.math.pow(f64, 1.0 - @exp(-kf * nf / mf), kf);
}

test "anchor [MU05][KM06]: measured FP rate stays within the published bound" {
    const allocator = testing.allocator;
    const n: u64 = 10_000;
    const probes: u64 = 200_000;

    var bf = try BloomFilter(u64).initCapacity(allocator, n, 0.01);
    defer bf.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) bf.add(i);

    // Probe a disjoint key range; every hit is a false positive by construction.
    var false_positives: u64 = 0;
    i = 1_000_000;
    while (i < 1_000_000 + probes) : (i += 1) {
        if (bf.contains(i)) false_positives += 1;
    }
    const measured = @as(f64, @floatFromInt(false_positives)) / @as(f64, @floatFromInt(probes));

    const expected = theoreticalFpRate(bf.num_bits, bf.num_hashes, n);

    // [KM06] proves the h1 + i*h2 scheme matches k-independent hashing
    // asymptotically, so the measured rate should track `expected` closely.
    // The 1.5x ceiling absorbs finite-n variance (sigma over 200k probes at
    // p≈0.01 is ~0.0002, so 1.5x is ~25 sigma) while still failing loudly on a
    // structural regression: dropping a hash round or halving m would move the
    // rate by multiples, not percent.
    try testing.expect(measured <= expected * 1.5);

    // Guard the other direction too: a rate far *below* the bound means the
    // filter is oversized relative to what initCapacity promised, i.e. the
    // sizing math drifted.
    try testing.expect(measured >= expected * 0.5);

    // And the whole point of initCapacity(n, 0.01): honour the requested rate.
    try testing.expect(measured <= 0.02);
}

test "anchor [MU05]: initCapacity reproduces the published optimal m and k" {
    const allocator = testing.allocator;

    // m = -n ln(p) / (ln 2)^2 ; k = (m/n) ln 2   [MU05 §5.5.3]
    const cases = [_]struct { n: usize, p: f64 }{
        .{ .n = 1_000, .p = 0.01 },
        .{ .n = 10_000, .p = 0.01 },
        .{ .n = 10_000, .p = 0.001 },
        .{ .n = 1_000_000, .p = 0.02 },
        .{ .n = 500, .p = 0.1 },
    };

    for (cases) |c| {
        var bf = try BloomFilter(u64).initCapacity(allocator, c.n, c.p);
        defer bf.deinit();

        const nf = @as(f64, @floatFromInt(c.n));
        const ln2 = @log(@as(f64, 2.0));
        const want_m = @as(usize, @intFromFloat(-nf * @log(c.p) / (ln2 * ln2)));
        const want_k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(want_m)) / nf * ln2));

        try testing.expectEqual(@max(want_m, 64), bf.num_bits);
        try testing.expectEqual(@max(want_k, 1), bf.num_hashes);

        // Sanity-check the closed form itself against the well-known rule of
        // thumb for p = 1%: ~9.6 bits per item, ~7 hash functions.
        if (c.p == 0.01 and c.n >= 1000) {
            const bits_per_item = @as(f64, @floatFromInt(bf.num_bits)) / nf;
            try testing.expect(bits_per_item > 9.0 and bits_per_item < 10.0);
            try testing.expectEqual(@as(u32, 6), bf.num_hashes);
        }
    }
}

// ============================================================================
// [FFGM07] HyperLogLog — published alpha table and error bound
// ============================================================================

test "anchor [FFGM07]: alpha_m matches the published bias-correction table" {
    const allocator = testing.allocator;

    // Flajolet et al. 2007, Fig. 3: alpha_16 = 0.673, alpha_32 = 0.697,
    // alpha_64 = 0.709, and alpha_m = 0.7213 / (1 + 1.079/m) for m >= 128.
    const cases = [_]struct { p: u6, alpha: f64 }{
        .{ .p = 4, .alpha = 0.673 },
        .{ .p = 5, .alpha = 0.697 },
        .{ .p = 6, .alpha = 0.709 },
    };

    for (cases) |c| {
        var hll = try HyperLogLog.init(allocator, c.p);
        defer hll.deinit();
        try testing.expectApproxEqAbs(c.alpha, hll.alpha, 1e-12);
    }

    var p: u6 = 7;
    while (p <= 18) : (p += 1) {
        var hll = try HyperLogLog.init(allocator, p);
        defer hll.deinit();
        const m = @as(f64, @floatFromInt(@as(usize, 1) << p));
        try testing.expectApproxEqAbs(0.7213 / (1.0 + 1.079 / m), hll.alpha, 1e-12);
    }
}

test "anchor [FFGM07]: estimates land inside the 1.04/sqrt(m) error bound" {
    const allocator = testing.allocator;

    const cardinalities = [_]u64{ 1_000, 10_000, 50_000, 100_000 };

    for ([_]u6{ 12, 14 }) |p| {
        for (cardinalities) |n| {
            var hll = try HyperLogLog.init(allocator, p);
            defer hll.deinit();

            var i: u64 = 0;
            while (i < n) : (i += 1) hll.add(i);

            const est = @as(f64, @floatFromInt(hll.estimate()));
            const truth = @as(f64, @floatFromInt(n));

            // sigma = 1.04/sqrt(m) relative; allow 3 sigma. This is the paper's
            // bound, not an observed value — a regression in the harmonic mean,
            // the alpha constant or the rank computation blows straight past it.
            const sigma = 1.04 / @sqrt(@as(f64, @floatFromInt(@as(usize, 1) << p)));
            const tolerance = truth * sigma * 3.0;

            if (@abs(est - truth) > tolerance) {
                std.debug.print(
                    "p={d} n={d}: estimate {d:.0} outside 3-sigma bound {d:.0} +/- {d:.0}\n",
                    .{ p, n, est, truth, tolerance },
                );
                return error.EstimateOutsideErrorBound;
            }
        }
    }
}

test "anchor [FFGM07]: standardError equals 1.04/sqrt(m)" {
    const allocator = testing.allocator;

    var p: u6 = 4;
    while (p <= 18) : (p += 1) {
        var hll = try HyperLogLog.init(allocator, p);
        defer hll.deinit();
        const m = @as(f64, @floatFromInt(@as(usize, 1) << p));
        try testing.expectApproxEqAbs(1.04 / @sqrt(m), hll.standardError(), 1e-12);
    }
}

// ============================================================================
// [WVT90] Sparse-mode linear counting
// ============================================================================

test "anchor [WVT90]: sparse-mode estimate follows linear counting, not raw occupancy" {
    const allocator = testing.allocator;

    // p = 14 gives m = 16384 registers with a sparse threshold of 1024, so
    // n = 900 stays in sparse mode. Raw occupancy (the pre-fix estimator)
    // undercounts here by the balls-into-bins collision rate; linear counting
    // corrects it.
    const p: u6 = 14;
    const n: u64 = 900;

    var sh = try SparseHyperLogLog.init(allocator, p);
    defer sh.deinit();

    var i: u64 = 0;
    while (i < n) : (i += 1) try sh.add(i);

    // Still sparse — this test is about the sparse estimator specifically.
    try testing.expect(sh.sparse != null);

    const filled = sh.sparse.?.count();
    const m = @as(f64, @floatFromInt(@as(usize, 1) << p));
    const zeros = m - @as(f64, @floatFromInt(filled));

    // [WVT90]: n_hat = -m ln(V/m), V = empty registers.
    const linear_counting = m * @log(m / zeros);
    try testing.expectEqual(@as(u64, @intFromFloat(@round(linear_counting))), sh.estimate());

    // Collisions really did occur, so raw occupancy would have undercounted —
    // this is what makes the correction observable rather than a no-op.
    try testing.expect(filled < n);

    // And the corrected estimate is accurate: linear counting's relative error
    // is sqrt(m*(e^t - t - 1))/(m*t) with t = n/m, which is well under 1% here.
    const est = @as(f64, @floatFromInt(sh.estimate()));
    try testing.expect(@abs(est - @as(f64, @floatFromInt(n))) <= @as(f64, @floatFromInt(n)) * 0.05);
}

test "anchor [WVT90]: sparse->dense conversion preserves the estimate" {
    const allocator = testing.allocator;

    const p: u6 = 14;
    var sh = try SparseHyperLogLog.init(allocator, p);
    defer sh.deinit();

    // Push past the 2^10 sparse threshold to exercise convertToDense, which
    // previously had zero test coverage.
    const n: u64 = 20_000;
    var i: u64 = 0;
    while (i < n) : (i += 1) try sh.add(i);

    try testing.expect(sh.sparse == null);
    try testing.expect(sh.hll != null);

    const est = @as(f64, @floatFromInt(sh.estimate()));
    const truth = @as(f64, @floatFromInt(n));
    const sigma = 1.04 / @sqrt(@as(f64, @floatFromInt(@as(usize, 1) << p)));
    try testing.expect(@abs(est - truth) <= truth * sigma * 3.0);
}

// ============================================================================
// [CM05] Count-Min Sketch — published dimensions and one-sided error
// ============================================================================

test "anchor [CM05]: initWithError uses w = ceil(e/eps), d = ceil(ln(1/delta))" {
    const allocator = testing.allocator;

    const cases = [_]struct { eps: f64, delta: f64 }{
        .{ .eps = 0.01, .delta = 0.001 },
        .{ .eps = 0.001, .delta = 0.01 },
        .{ .eps = 0.1, .delta = 0.1 },
    };

    for (cases) |c| {
        var cms = try CountMinSketch.initWithError(allocator, c.eps, c.delta);
        defer cms.deinit();

        try testing.expectEqual(
            @as(usize, @intFromFloat(@ceil(std.math.e / c.eps))),
            cms.width,
        );
        try testing.expectEqual(
            @max(@as(usize, @intFromFloat(@ceil(@log(1.0 / c.delta)))), 1),
            cms.depth,
        );
    }
}

test "anchor [CM05]: the sketch never underestimates (exhaustive over the stream)" {
    const allocator = testing.allocator;

    var cms = try CountMinSketch.initWithError(allocator, 0.001, 0.001);
    defer cms.deinit();

    // Deterministic skewed stream: item i appears (i % 37) + 1 times.
    const num_items: u64 = 2_000;
    var item: u64 = 0;
    while (item < num_items) : (item += 1) {
        const true_count: u32 = @intCast((item % 37) + 1);
        cms.addN(item, true_count);
    }

    // [CM05]: counters are only ever incremented on an item's own cells, so
    // min-over-rows is >= the true count for *every* item, always.
    item = 0;
    while (item < num_items) : (item += 1) {
        const true_count: u32 = @intCast((item % 37) + 1);
        if (cms.estimate(item) < true_count) return error.Underestimate;
    }
}

test "anchor [CM05]: overestimate stays within eps*N for >= 1-delta of items" {
    const allocator = testing.allocator;

    const eps: f64 = 0.001;
    const delta: f64 = 0.001;

    var cms = try CountMinSketch.initWithError(allocator, eps, delta);
    defer cms.deinit();

    const num_items: u64 = 2_000;
    var item: u64 = 0;
    while (item < num_items) : (item += 1) {
        cms.addN(item, @intCast((item % 37) + 1));
    }

    const total = @as(f64, @floatFromInt(cms.getTotalCount()));
    const slack = eps * total;

    var violations: u64 = 0;
    item = 0;
    while (item < num_items) : (item += 1) {
        const true_count = @as(f64, @floatFromInt((item % 37) + 1));
        const est = @as(f64, @floatFromInt(cms.estimate(item)));
        if (est > true_count + slack) violations += 1;
    }

    // The guarantee is per-item with failure probability at most delta.
    const violation_rate = @as(f64, @floatFromInt(violations)) / @as(f64, @floatFromInt(num_items));
    if (violation_rate > delta * 10.0) {
        std.debug.print(
            "{d}/{d} items exceeded the eps*N slack ({d:.4} > 10*delta)\n",
            .{ violations, num_items, violation_rate },
        );
        return error.ErrorBoundExceeded;
    }
}

// ============================================================================
// Serialization byte-layout lock
//
// The header bytes below are dictated by the documented format (see
// `bloom_filter.format`), so they are independent of how this library hashes
// or lays out its bit words: a decoder written from the doc comment alone
// produces exactly these bytes. The payload digests are drift locks, not
// external anchors — they exist so that any change to the hashing scheme,
// word order or endianness handling fails loudly instead of silently
// invalidating every previously written blob.
// ============================================================================

test "golden: BloomFilter header byte layout is exactly as documented" {
    const allocator = testing.allocator;

    var bf = try BloomFilter([]const u8).init(allocator, 256, 3);
    defer bf.deinit();
    bf.add("alpha");
    bf.add("beta");

    const blob = try bf.encodeAlloc(allocator);
    defer allocator.free(blob);

    // 256 bits = 4 u64 words = 32 payload bytes.
    try testing.expectEqual(@as(usize, 28 + 32), blob.len);

    const want_header = [_]u8{
        'Z', 'B', 'L', 'M', // magic
        1, // version
        0, // kind = bloom
        0, 0, // reserved
        0x00, 0x01, 0, 0, 0, 0, 0, 0, // num_bits = 256, LE u64
        0x03, 0, 0, 0, // num_hashes = 3, LE u32
        0x02, 0, 0, 0, 0, 0, 0, 0, // count = 2, LE u64
    };
    try testing.expectEqualSlices(u8, &want_header, blob[0..28]);
}

test "golden: CountingBloomFilter header byte layout is exactly as documented" {
    const allocator = testing.allocator;

    var cbf = try CountingBloomFilter([]const u8).init(allocator, 64, 4);
    defer cbf.deinit();
    cbf.add("alpha");

    const blob = try cbf.encodeAlloc(allocator);
    defer allocator.free(blob);

    try testing.expectEqual(@as(usize, 28 + 64), blob.len);

    const want_header = [_]u8{
        'Z', 'B', 'L', 'M',
        1,    0x01, // version, kind = counting
        0, 0,
        0x40, 0,    0, 0, 0, 0, 0, 0, // num_counters = 64
        0x04, 0,    0, 0, // num_hashes = 4
        0x01, 0,    0, 0, 0, 0, 0, 0, // count = 1
    };
    try testing.expectEqualSlices(u8, &want_header, blob[0..28]);

    // Exactly `num_hashes` counters were touched (or fewer, on collision), and
    // every touched counter holds 1.
    var touched: usize = 0;
    for (blob[28..]) |c| {
        if (c != 0) {
            touched += 1;
            try testing.expectEqual(@as(u8, 1), c);
        }
    }
    try testing.expect(touched > 0 and touched <= 4);
}

test "golden: encoded payload is stable (hash/layout drift lock)" {
    const allocator = testing.allocator;

    var bf = try BloomFilter([]const u8).init(allocator, 512, 5);
    defer bf.deinit();
    for ([_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" }) |k| {
        bf.add(k);
    }

    const blob = try bf.encodeAlloc(allocator);
    defer allocator.free(blob);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});

    // Recorded from this implementation; changing the hash scheme, the
    // h1 + i*h2 combination, the word order or the encoder's endianness
    // handling all move this digest.
    const expected_hex = "9a2db8281f02130e686eb0ae6277ff0aa28c226da3d9e8cb025aae5dfb079f4c";
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, expected_hex);
    try testing.expectEqualSlices(u8, &want, &digest);
}

test "golden: HyperLogLog register dump is stable for a fixed input" {
    const allocator = testing.allocator;

    var hll = try HyperLogLog.init(allocator, 12);
    defer hll.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) hll.add(i);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hll.serialize(), &digest, .{});

    const expected_hex = "a9401b9f3a806de720b688029031089deb8a25935158317b3023c8a73bb2e5db";
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, expected_hex);
    try testing.expectEqualSlices(u8, &want, &digest);

    // The dump must reload into a matching estimator and reproduce the estimate.
    var restored = try HyperLogLog.init(allocator, 12);
    defer restored.deinit();
    try restored.deserialize(hll.serialize());
    try testing.expectEqual(hll.estimate(), restored.estimate());
}

// ============================================================================
// Degenerate-input and decoder-hardening negatives
// ============================================================================

test "negative: decoder rejects malformed blobs" {
    const allocator = testing.allocator;

    var bf = try BloomFilter(u64).init(allocator, 128, 3);
    defer bf.deinit();
    bf.add(@as(u64, 1));

    const good = try bf.encodeAlloc(allocator);
    defer allocator.free(good);

    // Truncated below the header.
    try testing.expectError(
        error.TruncatedData,
        BloomFilter(u64).decodeAlloc(allocator, good[0..10]),
    );

    // Bad magic.
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        bad[0] = 'X';
        try testing.expectError(error.BadMagic, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // Unsupported version.
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        bad[4] = 99;
        try testing.expectError(error.UnsupportedVersion, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // Kind confusion: a counting blob must not load as a plain filter.
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        bad[5] = @intFromEnum(format.Kind.counting);
        try testing.expectError(error.KindMismatch, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // Reserved bytes must be zero (they are the extension point).
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        bad[6] = 1;
        try testing.expectError(error.ReservedNotZero, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // num_hashes == 0 would make `contains` vacuously true for every input —
    // in a revocation filter, that accepts every revoked token.
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        std.mem.writeInt(u32, bad[16..20], 0, .little);
        try testing.expectError(error.InvalidHashCount, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // num_bits == 0 would divide by zero in addHashed/containsHashed.
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        std.mem.writeInt(u64, bad[8..16], 0, .little);
        try testing.expectError(error.InvalidLength, BloomFilter(u64).decodeAlloc(allocator, bad));
    }

    // Payload length must agree with the declared bit count.
    {
        const bad = try allocator.dupe(u8, good[0 .. good.len - 8]);
        defer allocator.free(bad);
        try testing.expectError(error.LengthMismatch, BloomFilter(u64).decodeAlloc(allocator, bad));
    }
}

test "negative: sizing math rejects degenerate inputs instead of hitting @intFromFloat" {
    const allocator = testing.allocator;

    // HyperLogLog.initWithError
    try testing.expectError(error.InvalidErrorRate, HyperLogLog.initWithError(allocator, 0.0));
    try testing.expectError(error.InvalidErrorRate, HyperLogLog.initWithError(allocator, -0.1));
    try testing.expectError(error.InvalidErrorRate, HyperLogLog.initWithError(allocator, 1.0));
    try testing.expectError(error.InvalidErrorRate, HyperLogLog.initWithError(allocator, std.math.nan(f64)));

    // Tiny error rates clamp to max precision rather than failing.
    {
        var hll = try HyperLogLog.initWithError(allocator, 0.0001);
        defer hll.deinit();
        try testing.expectEqual(@as(u6, 18), hll.precision);
    }
    // Loose error rates clamp to min precision.
    {
        var hll = try HyperLogLog.initWithError(allocator, 0.9);
        defer hll.deinit();
        try testing.expectEqual(@as(u6, 4), hll.precision);
    }

    // CountMinSketch.initWithError
    try testing.expectError(error.InvalidEpsilon, CountMinSketch.initWithError(allocator, 0.0, 0.01));
    try testing.expectError(error.InvalidEpsilon, CountMinSketch.initWithError(allocator, -1.0, 0.01));
    try testing.expectError(error.InvalidEpsilon, CountMinSketch.initWithError(allocator, std.math.nan(f64), 0.01));
    try testing.expectError(error.InvalidDelta, CountMinSketch.initWithError(allocator, 0.01, 0.0));
    try testing.expectError(error.InvalidDelta, CountMinSketch.initWithError(allocator, 0.01, 1.0));

    // CountMinSketch.init
    try testing.expectError(error.InvalidWidth, CountMinSketch.init(allocator, 0, 5));
    try testing.expectError(error.InvalidDepth, CountMinSketch.init(allocator, 100, 0));

    // SparseHyperLogLog validates precision up front, not on later conversion.
    try testing.expectError(error.InvalidPrecision, SparseHyperLogLog.init(allocator, 3));
    try testing.expectError(error.InvalidPrecision, SparseHyperLogLog.init(allocator, 19));
}

test "negative: CountMinSketch.init leaks nothing on any allocation failure" {
    // The failing allocator asserts at deinit that everything allocated was
    // freed, so an error-path leak in init fails this test rather than merely
    // being invisible.
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing.allocator();

        // depth = 8 rows + the row array + the seed array = 10 allocations, so
        // this sweep covers every failure point plus the success case.
        if (CountMinSketch.init(allocator, 64, 8)) |cms_const| {
            var cms = cms_const;
            cms.deinit();
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
        // FailingAllocator tracks outstanding bytes; anything left is a leak.
        try testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
    }
}
