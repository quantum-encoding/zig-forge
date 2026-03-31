# Migration Analysis: `lib/std/Random/ziggurat.zig`

## 1) Concept

This file implements the Ziggurat algorithm for generating random numbers from non-uniform distributions, specifically the normal and exponential distributions. The Ziggurat method is an efficient rejection sampling technique that uses precomputed tables to generate random variates. The key components include:

- The `ZigTable` struct that stores precomputed distribution parameters and function pointers
- The `next_f64` function that generates random numbers using the Ziggurat algorithm
- Factory functions (`ZigTableGen`) for creating distribution tables at compile time
- Predefined distributions (`NormDist` for normal distribution, `ExpDist` for exponential distribution)

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected for public interfaces.** This file maintains stable patterns:

- **No explicit allocator requirements**: The API uses comptime table generation and doesn't require runtime allocators
- **No I/O interface changes**: The Random interface remains consistent with previous versions
- **Error handling unchanged**: Functions don't return error unions; they use the same deterministic generation patterns
- **API structure stable**: The `next_f64` function signature and table-based approach remain unchanged

The public API consists of:
- `pub fn next_f64(random: Random, comptime tables: ZigTable) f64`
- `pub const ZigTable` struct type
- `pub fn ZigTableGen(...) ZigTable` comptime factory
- Precomputed distributions: `NormDist` and `ExpDist`

## 3) The Golden Snippet

```zig
const std = @import("std");
const Random = std.Random;

pub fn main() void {
    var prng = Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Generate normal distribution random numbers
    const normal_value = std.Random.ziggurat.next_f64(random, std.Random.ziggurat.NormDist);
    
    // Generate exponential distribution random numbers  
    const exp_value = std.Random.ziggurat.next_f64(random, std.Random.ziggurat.ExpDist);
    
    std.debug.print("Normal: {d}, Exponential: {d}\n", .{normal_value, exp_value});
}
```

## 4) Dependencies

- `std` (core standard library)
- `std.math` (mathematical functions: exp, log, sqrt, etc.)
- `std.Random` (random number generation interface)

**Migration Impact: LOW** - This is a stable utility module with no breaking API changes between 0.11 and 0.16.