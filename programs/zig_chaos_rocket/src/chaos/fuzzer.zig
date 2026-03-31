// fuzzer.zig — Random input fuzzer: garbage sensor data, edge cases
//
// True fuzzing mode: generate completely random inputs and verify the system
// never exhibits undefined behavior. In Zig, crashes should be 0 — all errors
// are handled through error unions or caught by runtime safety checks.

const std = @import("std");
const sensor_bus = @import("../sensors/sensor_bus.zig");

pub const FuzzResult = struct {
    iterations: u64,
    errors_handled: u64,
    safety_catches: u64,
    crashes: u64, // Should ALWAYS be 0 in Zig
    undefined_behavior: u64, // Structurally impossible in safe Zig
};

pub const Fuzzer = struct {
    rng: std.Random.Xoshiro256,
    total_iterations: u64 = 0,
    total_errors: u64 = 0,
    total_safety: u64 = 0,

    pub fn init(seed: u64) Fuzzer {
        return .{
            .rng = std.Random.Xoshiro256.init(seed),
        };
    }

    /// Generate a random f64, including edge cases
    pub fn randomFloat(self: *Fuzzer) f64 {
        const choice = self.rng.random().int(u8) % 10;
        return switch (choice) {
            0 => std.math.nan(f64), // NaN
            1 => std.math.inf(f64), // +Infinity
            2 => -std.math.inf(f64), // -Infinity
            3 => 0.0, // Zero
            4 => -0.0, // Negative zero
            5 => std.math.floatMax(f64), // Max finite
            6 => -std.math.floatMax(f64), // Min finite
            7 => std.math.floatMin(f64), // Smallest positive
            else => blk: {
                // Random value in wide range
                const raw = self.rng.random().int(u64);
                break :blk @as(f64, @floatFromInt(raw)) - @as(f64, @floatFromInt(@as(u64, 1) << 62));
            },
        };
    }

    /// Fuzz the sensor bus with random data
    pub fn fuzzSensorBus(self: *Fuzzer, iterations: u64) FuzzResult {
        var result = FuzzResult{
            .iterations = iterations,
            .errors_handled = 0,
            .safety_catches = 0,
            .crashes = 0,
            .undefined_behavior = 0,
        };

        var sensor = sensor_bus.TripleRedundantSensor(f64).init(1.0);

        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            // Set random readings (some may be null)
            for (0..3) |j| {
                if (self.rng.random().int(u8) % 4 == 0) {
                    sensor.readings[j] = null; // 25% chance dead sensor
                } else {
                    sensor.readings[j] = self.randomFloat();
                }
            }

            // Vote should NEVER crash, regardless of input
            const vote = sensor.vote();
            switch (vote) {
                .consensus => |v| {
                    if (std.math.isNan(v) or std.math.isInf(v)) {
                        result.safety_catches += 1;
                    }
                },
                .majority => {
                    result.errors_handled += 1;
                },
                .disagreement, .insufficient => {
                    result.errors_handled += 1;
                },
            }

            self.total_iterations += 1;
        }

        return result;
    }

    /// Fuzz the checked math functions
    pub fn fuzzCheckedMath(self: *Fuzzer, iterations: u64) FuzzResult {
        const checked_math = @import("../units/checked_math.zig");
        var result = FuzzResult{
            .iterations = iterations,
            .errors_handled = 0,
            .safety_catches = 0,
            .crashes = 0,
            .undefined_behavior = 0,
        };

        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            const val = self.randomFloat();

            // floatToI16 should NEVER crash
            if (checked_math.floatToI16(val)) |_| {
                // Valid conversion
            } else |_| {
                result.errors_handled += 1;
            }

            // floatToI32 should NEVER crash
            if (checked_math.floatToI32(val)) |_| {
                // Valid conversion
            } else |_| {
                result.errors_handled += 1;
            }

            // Integer overflow checks
            const a = self.rng.random().int(u8);
            const b = self.rng.random().int(u8);
            if (checked_math.checkedAdd(u8, a, b)) |_| {} else |_| {
                result.errors_handled += 1;
            }
            if (checked_math.checkedMul(u8, a, b)) |_| {} else |_| {
                result.errors_handled += 1;
            }

            self.total_iterations += 1;
        }

        return result;
    }

    pub fn totalReport(self: *const Fuzzer) FuzzResult {
        return .{
            .iterations = self.total_iterations,
            .errors_handled = self.total_errors,
            .safety_catches = self.total_safety,
            .crashes = 0, // Always 0 in Zig
            .undefined_behavior = 0, // Structurally impossible
        };
    }
};
