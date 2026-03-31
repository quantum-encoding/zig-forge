# Migration Card: std.Random.Xoroshiro128

## 1) Concept

This file implements the Xoroshiro128+ pseudorandom number generator (PRNG) algorithm. It provides a high-performance random number generator that produces 64-bit values and can fill arbitrary byte buffers with random data. The key components include the generator state (two 64-bit integers), core generation functions (`next` and `fill`), seeding functionality using SplitMix64, and a jump-ahead capability for advancing the generator state by 2^64 positions.

The implementation exposes both direct access to the underlying algorithm through methods like `next()` and `fill()`, as well as integration with Zig's standard Random interface through the `random()` method, allowing it to be used interchangeably with other PRNG implementations in the standard library.

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes identified** for migration from 0.11 to 0.16. The public interface remains stable:

- **No allocator requirements**: The struct uses direct initialization (`Xoroshiro128{...}`) and doesn't require memory allocation
- **No I/O interface changes**: This is a pure computation module with no I/O dependencies
- **Error handling unchanged**: All functions are non-failing (no error returns)
- **API structure consistent**: Uses simple `init()` constructor pattern, not factory functions

The implementation does show some internal Zig language evolution:
- Use of `@truncate` and `@intCast` with explicit types
- `comptime` loop variables in `fill()` function
- Standard library namespace organization

## 3) The Golden Snippet

```zig
const std = @import("std");
const Xoroshiro128 = std.Random.Xoroshiro128;

// Initialize with seed
var prng = Xoroshiro128.init(12345);

// Generate individual random numbers
const random_value = prng.next();

// Fill buffers with random bytes
var buffer: [100]u8 = undefined;
prng.fill(&buffer);

// Use with std.Random interface
var random = prng.random();
const ranged_value = random.intRangeAtMost(u32, 0, 100);
```

## 4) Dependencies

- `std.math` - For rotation operations (`rotl`)
- `std.Random` - For the Random interface and SplitMix64 seeding

**No heavy dependencies** - this is a self-contained PRNG implementation with minimal standard library imports.