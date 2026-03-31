// sensor_bus.zig — Sensor data bus with voter/arbitration logic
//
// BOEING 737 MAX MCAS — October 29, 2018 & March 10, 2019 — 346 lives lost
//
// The Maneuvering Characteristics Augmentation System (MCAS) relied on a
// SINGLE angle-of-attack (AoA) sensor. When that sensor failed (stuck at 21°
// nose-up), MCAS repeatedly pushed the nose down. Pilots fought the system
// 26 times on the Lion Air flight before losing control.
//
// The 737 MAX had TWO AoA sensors but MCAS only read from ONE (alternating
// left/right by aircraft). The "disagree" indicator was a paid optional extra.
//
// This sensor bus implements triple-redundant voting. A single sensor failure
// CANNOT cause a control action. You need 2-of-3 agreement.

const std = @import("std");

pub const SensorFault = union(enum) {
    stuck: void, // Reading never changes (frozen sensor)
    bias: f64, // Constant offset added to reading
    noise: f64, // Random noise magnitude
    dead: void, // Sensor returns null (no reading)
    inverted: void, // Sign flipped
    max_saturated: void, // Pegged at max value
    spike: f64, // Momentary spike of given magnitude
};

pub fn TripleRedundantSensor(comptime T: type) type {
    return struct {
        readings: [3]?T = .{ null, null, null },
        labels: [3][]const u8 = .{ "A", "B", "C" },
        tolerance: f64,
        faults: [3]?SensorFault = .{ null, null, null },
        fault_active: [3]bool = .{ false, false, false },

        const Self = @This();

        pub const VoteResult = union(enum) {
            consensus: T, // All three agree within tolerance
            majority: struct { value: T, outlier: u8 }, // 2 agree, 1 outlier
            disagreement: void, // No consensus possible
            insufficient: void, // Fewer than 2 valid readings
        };

        pub fn init(tol: f64) Self {
            return .{ .tolerance = tol };
        }

        pub fn setReading(self: *Self, idx: u8, value: T) void {
            if (idx < 3) {
                self.readings[idx] = value;
            }
        }

        pub fn setAllReadings(self: *Self, value: T) void {
            self.readings = .{ value, value, value };
        }

        /// Vote on sensor readings. Returns consensus value or error detail.
        pub fn vote(self: *const Self) VoteResult {
            var valid: [3]T = undefined;
            var valid_idx: [3]u8 = undefined;
            var valid_count: u8 = 0;

            for (self.readings, 0..) |reading, i| {
                if (reading) |r| {
                    valid[valid_count] = r;
                    valid_idx[valid_count] = @intCast(i);
                    valid_count += 1;
                }
            }

            if (valid_count < 2) return .insufficient;

            if (valid_count == 2) {
                if (withinTolerance(valid[0], valid[1], self.tolerance)) {
                    return .{ .consensus = avg2(valid[0], valid[1]) };
                }
                return .disagreement;
            }

            // 3 readings: check all pairs
            const ab = withinTolerance(valid[0], valid[1], self.tolerance);
            const ac = withinTolerance(valid[0], valid[2], self.tolerance);
            const bc = withinTolerance(valid[1], valid[2], self.tolerance);

            if (ab and ac and bc) {
                // All three agree
                return .{ .consensus = avg3(valid[0], valid[1], valid[2]) };
            }

            if (ab and !ac and !bc) {
                // A and B agree, C is outlier
                return .{ .majority = .{ .value = avg2(valid[0], valid[1]), .outlier = valid_idx[2] } };
            }
            if (ac and !ab and !bc) {
                // A and C agree, B is outlier
                return .{ .majority = .{ .value = avg2(valid[0], valid[2]), .outlier = valid_idx[1] } };
            }
            if (bc and !ab and !ac) {
                // B and C agree, A is outlier
                return .{ .majority = .{ .value = avg2(valid[1], valid[2]), .outlier = valid_idx[0] } };
            }

            // Edge case: ab and bc but not ac (shouldn't normally happen with consistent tolerance)
            if (ab) return .{ .majority = .{ .value = avg2(valid[0], valid[1]), .outlier = valid_idx[2] } };
            if (bc) return .{ .majority = .{ .value = avg2(valid[1], valid[2]), .outlier = valid_idx[0] } };
            if (ac) return .{ .majority = .{ .value = avg2(valid[0], valid[2]), .outlier = valid_idx[1] } };

            return .disagreement;
        }

        /// Inject a fault into sensor N (for chaos testing)
        pub fn injectFault(self: *Self, sensor_idx: u8, fault: SensorFault) void {
            if (sensor_idx < 3) {
                self.faults[sensor_idx] = fault;
                self.fault_active[sensor_idx] = true;
            }
        }

        /// Clear fault on sensor N
        pub fn clearFault(self: *Self, sensor_idx: u8) void {
            if (sensor_idx < 3) {
                self.faults[sensor_idx] = null;
                self.fault_active[sensor_idx] = false;
            }
        }

        /// Apply any active faults to the readings
        pub fn applyFaults(self: *Self, rng: *std.Random.Xoshiro256) void {
            for (0..3) |i| {
                if (self.faults[i]) |fault| {
                    switch (fault) {
                        .stuck => {}, // Reading stays the same (don't update)
                        .bias => |b| {
                            if (self.readings[i]) |*r| r.* += b;
                        },
                        .noise => |n| {
                            if (self.readings[i]) |*r| {
                                const rand_val = @as(f64, @floatFromInt(rng.random().int(u32))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
                                r.* += (rand_val - 0.5) * 2.0 * n;
                            }
                        },
                        .dead => self.readings[i] = null,
                        .inverted => {
                            if (self.readings[i]) |*r| r.* = -r.*;
                        },
                        .max_saturated => self.readings[i] = std.math.floatMax(f64),
                        .spike => |mag| {
                            if (self.readings[i]) |*r| r.* += mag;
                        },
                    }
                }
            }
        }

        fn withinTolerance(a: T, b: T, tol: f64) bool {
            return @abs(a - b) <= tol;
        }

        fn avg2(a: T, b: T) T {
            return (a + b) / 2.0;
        }

        fn avg3(a: T, b: T, c: T) T {
            return (a + b + c) / 3.0;
        }
    };
}

// ============================================================================
// Tests — including MCAS scenario
// ============================================================================

test "triple redundant - all agree" {
    var sensor = TripleRedundantSensor(f64).init(1.0);
    sensor.setAllReadings(10.0);
    const result = sensor.vote();
    switch (result) {
        .consensus => |v| try std.testing.expectApproxEqAbs(10.0, v, 0.01),
        else => return error.TestUnexpectedResult,
    }
}

test "MCAS scenario: one sensor stuck" {
    var sensor = TripleRedundantSensor(f64).init(2.0);
    sensor.readings = .{ 21.0, 5.0, 5.5 }; // Sensor A stuck at 21°
    const result = sensor.vote();
    switch (result) {
        .majority => |m| {
            try std.testing.expectApproxEqAbs(5.25, m.value, 0.01);
            try std.testing.expectEqual(@as(u8, 0), m.outlier); // Sensor A is outlier
        },
        else => return error.TestUnexpectedResult,
    }
}

test "all sensors dead = insufficient" {
    var sensor = TripleRedundantSensor(f64).init(1.0);
    // All null by default
    const result = sensor.vote();
    switch (result) {
        .insufficient => {},
        else => return error.TestUnexpectedResult,
    }
}

test "two sensors disagree = disagreement" {
    var sensor = TripleRedundantSensor(f64).init(1.0);
    sensor.readings = .{ 0.0, 100.0, null };
    const result = sensor.vote();
    switch (result) {
        .disagreement => {},
        else => return error.TestUnexpectedResult,
    }
}
