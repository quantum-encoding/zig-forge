//! zig_bloom - Probabilistic Data Structures Library
//!
//! A high-performance library for probabilistic data structures:
//! - Bloom Filter: Fast set membership testing with false positives
//! - Counting Bloom Filter: Bloom filter with deletion support
//! - Count-Min Sketch: Frequency estimation for streaming data
//! - HyperLogLog: Cardinality estimation with minimal memory
//!
//! All structures are designed for:
//! - Zero heap allocations in hot paths
//! - Cache-friendly memory layouts
//! - Thread-safe operations where applicable
//! - Configurable accuracy vs memory tradeoffs

pub const bloom_filter = @import("bloom_filter.zig");
pub const count_min = @import("count_min.zig");
pub const hyperloglog = @import("hyperloglog.zig");

// Re-export main types for convenience
pub const BloomFilter = bloom_filter.BloomFilter;
pub const CountingBloomFilter = bloom_filter.CountingBloomFilter;
pub const CountMinSketch = count_min.CountMinSketch;
pub const HeavyHitters = count_min.HeavyHitters;
pub const HyperLogLog = hyperloglog.HyperLogLog;
pub const HyperLogLogPlusPlus = hyperloglog.HyperLogLogPlusPlus;

// Version info
pub const version = "0.1.0";
pub const version_major = 0;
pub const version_minor = 1;
pub const version_patch = 0;

test {
    // Run all module tests
    @import("std").testing.refAllDecls(@This());
}
