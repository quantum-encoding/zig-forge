// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");

/// Pure Zig mutex using atomics (no libc)
const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

/// Pure Zig timestamp using Io.Timestamp (no libc)
const Instant = struct {
    ts: std.Io.Timestamp,
    io: std.Io,

    pub fn now(io: std.Io) Instant {
        return .{ .ts = std.Io.Timestamp.now(io, .awake), .io = io };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const diff = earlier.ts.durationTo(self.ts);
        const ns = diff.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// Enterprise-grade retry engine with exponential backoff and jitter
/// Implements production-level resilience patterns for high-frequency trading

pub const RetryConfig = struct {
    max_attempts: u32 = 5,
    base_delay_ms: u64 = 100,
    max_delay_ms: u64 = 30000,
    backoff_multiplier: f64 = 2.0,
    jitter_factor: f64 = 0.1,
    enable_circuit_breaker: bool = true,
    circuit_failure_threshold: u32 = 10,
    circuit_recovery_timeout_ms: u64 = 60000,
};

pub const CircuitState = enum {
    closed,    // Normal operation
    open,      // Circuit is open, failing fast
    half_open, // Testing if service recovered
};

pub const CircuitBreaker = struct {
    state: CircuitState = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: ?Instant = null,
    config: RetryConfig,
    mutex: Mutex = .{},
    io: std.Io,

    pub fn init(config: RetryConfig, io: std.Io) CircuitBreaker {
        return CircuitBreaker{
            .config = config,
            .io = io,
        };
    }

    pub fn canExecute(self: *CircuitBreaker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (self.state) {
            .closed => return true,
            .open => {
                if (self.last_failure_time) |last_failure| {
                    const now_inst = Instant.now(self.io);
                    const elapsed_ns = now_inst.since(last_failure);
                    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
                    if (elapsed_ms > self.config.circuit_recovery_timeout_ms) {
                        self.state = .half_open;
                        return true;
                    }
                }
                return false;
            },
            .half_open => return true,
        }
    }

    pub fn onSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.failure_count = 0;
        if (self.state == .half_open) {
            self.success_count += 1;
            if (self.success_count >= 3) {
                self.state = .closed;
                self.success_count = 0;
            }
        }
    }

    pub fn onFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.failure_count += 1;
        self.last_failure_time = Instant.now(self.io);

        if (self.failure_count >= self.config.circuit_failure_threshold) {
            self.state = .open;
            self.success_count = 0;
        }
    }
};

pub const RetryEngine = struct {
    allocator: std.mem.Allocator,
    config: RetryConfig,
    circuit_breaker: ?CircuitBreaker,
    rate_limiter: RateLimiter,
    io: std.Io,

    const RateLimiter = struct {
        tokens: f64,
        max_tokens: f64,
        refill_rate: f64, // tokens per second
        last_refill: Instant,
        mutex: Mutex = .{},

        pub fn init(max_requests_per_minute: u32, io: std.Io) RateLimiter {
            const max_tokens = @as(f64, @floatFromInt(max_requests_per_minute));
            return RateLimiter{
                .tokens = max_tokens,
                .max_tokens = max_tokens,
                .refill_rate = max_tokens / 60.0, // per second
                .last_refill = Instant.now(io),
            };
        }

        pub fn tryAcquire(self: *RateLimiter, tokens_needed: f64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.refillTokens();

            if (self.tokens >= tokens_needed) {
                self.tokens -= tokens_needed;
                return true;
            }
            return false;
        }

        pub fn getWaitTimeMs(self: *RateLimiter, tokens_needed: f64) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.refillTokens();

            if (self.tokens >= tokens_needed) {
                return 0;
            }

            const tokens_deficit = tokens_needed - self.tokens;
            const wait_seconds = tokens_deficit / self.refill_rate;
            return @intFromFloat(wait_seconds * 1000.0);
        }

        fn refillTokens(self: *RateLimiter) void {
            const now_inst = Instant.now(self.last_refill.io);
            const elapsed_ns = now_inst.since(self.last_refill);
            const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

            const tokens_to_add = elapsed_seconds * self.refill_rate;
            self.tokens = @min(self.max_tokens, self.tokens + tokens_to_add);
            self.last_refill = now_inst;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: RetryConfig, io: std.Io) RetryEngine {
        return RetryEngine{
            .allocator = allocator,
            .config = config,
            .circuit_breaker = if (config.enable_circuit_breaker) CircuitBreaker.init(config, io) else null,
            .rate_limiter = RateLimiter.init(200, io),
            .io = io,
        };
    }

    /// Execute function with retry logic and rate limiting
    /// @param is_retryable_fn: Optional predicate to determine if an error is retryable
    pub fn execute(
        self: *RetryEngine,
        comptime ReturnType: type,
        context: anytype,
        func: fn (@TypeOf(context)) anyerror!ReturnType,
        is_retryable_fn: ?fn (err: anyerror) bool,
    ) !ReturnType {
        // Check circuit breaker
        if (self.circuit_breaker) |*cb| {
            if (!cb.canExecute()) {
                return error.CircuitBreakerOpen;
            }
        }

        var attempt: u32 = 0;
        var last_error: anyerror = undefined;

        while (attempt < self.config.max_attempts) {
            // Rate limiting
            if (!self.rate_limiter.tryAcquire(1.0)) {
                const wait_ms = self.rate_limiter.getWaitTimeMs(1.0);
                if (wait_ms > 0 and wait_ms < 5000) { // Don't wait more than 5 seconds
                    self.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(wait_ms)), .awake) catch {};
                }
            }

            // Attempt execution
            const result = func(context);

            if (result) |success| {
                // Success - update circuit breaker
                if (self.circuit_breaker) |*cb| {
                    cb.onSuccess();
                }
                return success;
            } else |err| {
                last_error = err;
                attempt += 1;

                // Check if error is retryable
                var should_retry = false;
                if (is_retryable_fn) |predicate| {
                    should_retry = predicate(err);
                } else {
                    // Default retry logic for common network errors
                    should_retry = isDefaultRetryable(err);
                }

                if (!should_retry) {
                    if (self.circuit_breaker) |*cb| {
                        cb.onFailure();
                    }
                    return err;
                }

                // Calculate backoff delay
                if (attempt < self.config.max_attempts) {
                    const delay_ms = self.calculateBackoffDelay(attempt);
                    self.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
                }
            }
        }

        // All attempts failed
        if (self.circuit_breaker) |*cb| {
            cb.onFailure();
        }

        return last_error;
    }

    fn isDefaultRetryable(err: anyerror) bool {
        // Default retry logic for common network/system errors
        return switch (err) {
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.SystemResources,
            error.Unexpected => true,
            else => false,
        };
    }

    fn calculateBackoffDelay(self: *RetryEngine, attempt: u32) u64 {
        var delay = @as(f64, @floatFromInt(self.config.base_delay_ms)) *
                   std.math.pow(f64, self.config.backoff_multiplier, @as(f64, @floatFromInt(attempt)));

        // Cap at max delay
        delay = @min(delay, @as(f64, @floatFromInt(self.config.max_delay_ms)));

        // Add jitter to prevent thundering herd (pure Zig random via Io)
        const jitter_range = delay * self.config.jitter_factor;
        var rand_bytes: [8]u8 = undefined;
        self.io.random(&rand_bytes);
        const rand_u64 = std.mem.readInt(u64, &rand_bytes, .little);
        const rand_frac = @as(f64, @floatFromInt(rand_u64)) / @as(f64, @floatFromInt(@as(u64, std.math.maxInt(u64))));
        const jitter = (rand_frac - 0.5) * jitter_range;
        delay += jitter;

        return @max(1, @as(u64, @intFromFloat(delay)));
    }

    /// Get current rate limiter status
    pub fn getRateLimitStatus(self: *RetryEngine) struct { tokens: f64, max_tokens: f64, refill_rate: f64 } {
        self.rate_limiter.mutex.lock();
        defer self.rate_limiter.mutex.unlock();

        self.rate_limiter.refillTokens();

        return .{
            .tokens = self.rate_limiter.tokens,
            .max_tokens = self.rate_limiter.max_tokens,
            .refill_rate = self.rate_limiter.refill_rate,
        };
    }

    /// Get circuit breaker status
    pub fn getCircuitBreakerStatus(self: *RetryEngine) ?struct {
        state: CircuitState,
        failure_count: u32,
        success_count: u32,
        can_execute: bool
    } {
        if (self.circuit_breaker) |*cb| {
            cb.mutex.lock();
            defer cb.mutex.unlock();

            return .{
                .state = cb.state,
                .failure_count = cb.failure_count,
                .success_count = cb.success_count,
                .can_execute = cb.canExecute(),
            };
        }
        return null;
    }
};
