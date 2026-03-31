//! zig_ratelimit - Rate Limiting Library
//!
//! A comprehensive rate limiting library with multiple algorithms:
//!
//! - **Token Bucket**: Allows bursts up to bucket capacity, refills at constant rate
//! - **Leaky Bucket**: Smooth output rate, requests queue and drain steadily
//! - **GCRA**: Generic Cell Rate Algorithm, precise burst control
//! - **Sliding Window Log**: Exact tracking with timestamp log
//! - **Sliding Window Counter**: Approximate tracking with fixed memory
//! - **Fixed Window Counter**: Simple counter reset at intervals
//!
//! ## Algorithm Comparison
//!
//! | Algorithm | Memory | Accuracy | Burst | Use Case |
//! |-----------|--------|----------|-------|----------|
//! | Token Bucket | O(1) | Exact | Yes | API rate limiting |
//! | Leaky Bucket | O(1) | Exact | Queue | Traffic shaping |
//! | GCRA | O(1) | Exact | Controlled | Network QoS |
//! | Sliding Log | O(n) | Exact | No | High accuracy needed |
//! | Sliding Counter | O(1) | ~Approx | No | Memory constrained |
//! | Fixed Window | O(1) | Exact* | 2x at boundary | Simple cases |
//!
//! ## Example
//!
//! ```zig
//! const ratelimit = @import("ratelimit");
//!
//! // Token bucket: 100 requests/sec with burst of 50
//! var limiter = ratelimit.TokenBucket.init(50, 100);
//!
//! if (limiter.tryAcquire(1)) {
//!     // Request allowed
//!     handleRequest();
//! } else {
//!     // Rate limited
//!     return error.TooManyRequests;
//! }
//! ```

pub const token_bucket = @import("token_bucket.zig");
pub const leaky_bucket = @import("leaky_bucket.zig");
pub const sliding_window = @import("sliding_window.zig");

// Re-export main types
pub const TokenBucket = token_bucket.TokenBucket;
pub const AtomicTokenBucket = token_bucket.AtomicTokenBucket;
pub const LeakyBucket = leaky_bucket.LeakyBucket;
pub const GCRA = leaky_bucket.GCRA;
pub const SlidingWindowLog = sliding_window.SlidingWindowLog;
pub const SlidingWindowCounter = sliding_window.SlidingWindowCounter;
pub const FixedWindowCounter = sliding_window.FixedWindowCounter;

/// Version info
pub const version = "0.1.0";
pub const version_major = 0;
pub const version_minor = 1;
pub const version_patch = 0;

/// Convenience function to create a rate limiter for the common case
/// rate: Requests per second
/// burst: Maximum burst size (uses token bucket)
pub fn createLimiter(burst: f64, rate: f64) TokenBucket {
    return TokenBucket.init(burst, rate);
}

/// Create a thread-safe rate limiter
pub fn createAtomicLimiter(burst: f64, rate: f64) AtomicTokenBucket {
    return AtomicTokenBucket.init(burst, rate);
}

test {
    // Run all module tests
    @import("std").testing.refAllDecls(@This());
}
