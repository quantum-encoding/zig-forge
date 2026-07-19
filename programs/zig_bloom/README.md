# zig_bloom

Probabilistic data structures library for Zig: Bloom filter, counting Bloom filter (with deletion), Count-Min Sketch, and HyperLogLog — all in-memory, single-threaded, and allocation-free after `init`.

## What's in it

| Type | Answers | Error direction |
|---|---|---|
| `BloomFilter(T)` | "is this item in the set?" | false positives only — **never** a false negative |
| `CountingBloomFilter(T)` | same, plus `remove` | false positives; false negatives possible only after a counter saturates at 255 |
| `CountMinSketch` | "how often did this item appear?" | overestimates only — never underestimates |
| `HeavyHitters` | "which items crossed a frequency threshold?" | candidate set is a superset (see below) |
| `HyperLogLog` | "how many distinct items?" | ±1.04/√m relative standard error |
| `SparseHyperLogLog` | same, sparse storage for small cardinalities | as above, once dense |

All of these are **read/write in both directions** where the name implies it: filters both `add` and `contains`, the sketch both `add` and `estimate`, HLL both `add` and `estimate`, and the filters both `encodeAlloc` and `decodeAlloc`.

## Not thread-safe

Nothing here uses atomics or locks. Concurrent mutation of a single instance races. Shard per-thread and combine with `unionWith` / `merge`, or guard externally.

## Usage

```zig
const bloom = @import("bloom");

var bf = try bloom.BloomFilter([]const u8).initCapacity(allocator, 10_000, 0.01);
defer bf.deinit();

bf.add("hello");
if (bf.contains("hello")) { ... }   // true
if (bf.contains("nope")) { ... }    // false, or a ~1% false positive
```

Sizing follows the standard closed form (Mitzenmacher & Upfal, *Probability and Computing* §5.5.3): `m = -n·ln(p)/(ln 2)²` bits and `k = (m/n)·ln 2` hash functions. `initCapacity` rejects `expected_items == 0` and any `fp_rate` outside `(0, 1)` rather than feeding NaN/inf into `@intFromFloat`.

Hashing is Kirsch–Mitzenmacher double hashing (`h1 + i·h2`) over two fixed-seed Wyhash calls. The seeds are public constants, so an adversary who chooses the inserted keys can steer false positives; that is fine for server-generated keys, and callers with adversarial input should not rely on the FP rate holding.

### Serialization

`encodeAlloc` produces a versioned, self-describing, little-endian blob; `decodeAlloc` reconstructs a filter from one. The byte layout is documented in `bloom_filter.format` and locked by tests:

```
off  size  field
0    4     magic "ZBLM"
4    1     format version (1)
5    1     kind: 0 = BloomFilter, 1 = CountingBloomFilter
6    2     reserved, must be 0
8    8     num_bits / num_counters (u64 LE)
16   4     num_hashes (u32 LE)
20   8     count (u64 LE)
28   ...   payload: ceil(num_bits/64) u64 LE words, or num_counters bytes
```

The decoder rejects bad magic, unknown versions, kind confusion, non-zero reserved bytes, `num_bits == 0` (division by zero), `num_hashes == 0` (which would make `contains` vacuously true for every input), and payload/header length disagreement.

`rawBits()` / `rawCounters()` expose the underlying words in host byte order for callers that want the bare array; that view is not a portable format.

`HyperLogLog.serialize` / `deserialize` are a raw one-byte-per-register dump with no header — the reader must already know the precision, which is why `deserialize` loads into a pre-constructed estimator.

### HyperLogLog

```zig
var hll = try bloom.HyperLogLog.init(allocator, 14); // 2^14 registers, ~0.8% error
defer hll.deinit();
for (items) |it| hll.add(it);
const n = hll.estimate();
```

`initWithError(allocator, rate)` picks a precision from the target error and clamps it into the supported `[4, 18]` range instead of failing on very tight rates. The α correction constants match the published table in Flajolet et al. (2007). There is deliberately **no** large-range correction: the classic `-2³²·ln(1 − E/2³²)` term assumes a 32-bit hash, and this implementation hashes with 64-bit Wyhash, so applying it would corrupt estimates above ~1.4e8.

`SparseHyperLogLog` was previously named `HyperLogLogPlusPlus`. That name overclaimed — Heule et al.'s HLL++ additionally stores a higher-precision sparse encoding and applies empirical bias-correction tables, neither of which is implemented here. What this type does provide is sparse storage below the threshold plus an unbiased linear-counting estimator (Whang et al., 1990) in that range; above the threshold it converts to a dense `HyperLogLog` and is exactly as accurate.

### Count-Min Sketch

`initWithError(allocator, epsilon, delta)` sizes the sketch as `w = ⌈e/ε⌉`, `d = ⌈ln(1/δ)⌉` per Cormode & Muthukrishnan (2005), giving the guarantee that estimates never underestimate and exceed the true count by more than `ε·N` with probability at most `δ`.

`HeavyHitters` admits an item to its candidate set when its estimated frequency crosses the threshold and never evicts it. Because frequency is `estimate / total_count` and `total_count` only grows, the candidate set is a **superset** of the current heavy hitters — re-check entries with `isHeavyHitter` if staleness matters.

## Testing

```
zig build test     # unit tests + tier-1 anchors
zig build bench    # throughput benchmarks
zig build run      # CLI demo
```

`src/tier1_anchors.zig` holds the external anchors required by [zig-forge/CLAUDE.md](../../CLAUDE.md) golden rule §1. Probabilistic structures have no wire spec to compare against, so the anchors are the published guarantees themselves — every expected value is computed in-test from a formula in a cited paper, never from an observed output of this library:

- **No false negatives** (Bloom 1970) — exhaustive, not sampled: every inserted key must test positive, for string and integer keys, for both filter variants, after `unionWith`, and after an encode/decode round trip.
- **False-positive rate** vs `(1 − e^(−kn/m))^k` (Mitzenmacher & Upfal; Kirsch & Mitzenmacher 2006 for the double-hashing equivalence), measured over 200k probes and bounded from both sides.
- **Optimal sizing** — `initCapacity` output checked against the closed form for a table of (n, p).
- **HyperLogLog** — α constants against the paper's table, estimates inside the 3σ band of the published `1.04/√m` error at four cardinalities.
- **Linear counting** (Whang et al. 1990) for sparse mode, including the sparse→dense conversion.
- **Count-Min Sketch** — published dimensions, the never-underestimates guarantee exhaustively over the stream, and the `ε·N` overestimate bound holding for ≥ 1−δ of items.
- **Byte-layout goldens** for the serialization header, plus digest drift locks on the payload and the HLL register dump.
- **Negatives** — malformed-blob rejection, degenerate sizing inputs, and a `FailingAllocator` sweep proving `CountMinSketch.init` leaks nothing on any allocation failure.

## Status

Not yet on the CLAUDE.md canonical library list. The in-tree consumer is `zig_token_service`, which uses `BloomFilter([]const u8)` for token revocation checks — a use where the one-sided error direction is the safe one (a false positive rejects a valid token; a false negative would accept a revoked one, which is exactly the invariant the anchors test exhaustively).
