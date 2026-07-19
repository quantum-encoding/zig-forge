//! Alert evaluation system.
//!
//! Fixed-size alert list evaluated each frame from FlightData + AircraftLimits.
//! Radio altitude callouts fire once per threshold crossing on descent.
//! Pure evaluation — no heap allocation.

const std = @import("std");
const FlightData = @import("flight_data.zig").FlightData;
const AircraftLimits = @import("limits.zig").AircraftLimits;

pub const AlertPriority = enum(u8) {
    warning = 0, // Red — immediate action required
    caution = 1, // Yellow — awareness required
    advisory = 2, // Cyan — informational
};

pub const AlertId = enum(u8) {
    overspeed,
    bank_angle,
    descent_rate,
    low_fuel,
    low_fuel_caution,
    ra_2500,
    ra_1000,
    ra_500,
    ra_200,
    ra_100,
    ra_50,
    ra_30,
    ra_20,
    ra_10,
};

pub const Alert = struct {
    id: AlertId,
    priority: AlertPriority,
    message: []const u8,
};

pub const MAX_ALERTS = 16;

/// How many frames a radio-altitude callout stays visible after it fires. At
/// the 10 Hz update rate this is ~2 s, so "500", "100" etc. are actually
/// readable — a callout added only on the single crossing frame flickers for
/// ~100 ms and is effectively invisible.
pub const CALLOUT_HOLD_FRAMES: u16 = 20;

pub const AlertSystem = struct {
    alerts: [MAX_ALERTS]Alert = undefined,
    active_count: u8 = 0,
    prev_radio_alt: f32 = 0,
    last_ra_callout: ?AlertId = null,

    // Latch state: keeps the most-recent RA callout on screen for
    // CALLOUT_HOLD_FRAMES frames instead of one.
    latched_id: ?AlertId = null,
    latch_msg: []const u8 = "",
    latch_remaining: u16 = 0,

    pub fn init() AlertSystem {
        return .{};
    }

    /// Evaluate all alert conditions from current flight data and limits.
    /// Clears the alert list, checks each condition, populates sorted by priority.
    pub fn evaluate(self: *AlertSystem, fd: *const FlightData, lim: *const AircraftLimits) void {
        self.active_count = 0;

        // --- Warnings (red) ---
        if (fd.airspeed_kts > lim.vmo) {
            self.addAlert(.{ .id = .overspeed, .priority = .warning, .message = "OVERSPEED" });
        }

        if (@abs(fd.roll_deg) > lim.max_bank_deg) {
            self.addAlert(.{ .id = .bank_angle, .priority = .warning, .message = "BANK ANGLE" });
        }

        if (fd.vsi_fpm < -lim.max_descent_rate_fpm) {
            self.addAlert(.{ .id = .descent_rate, .priority = .warning, .message = "SINK RATE" });
        }

        if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs < lim.min_endurance_warning_hrs) {
            self.addAlert(.{ .id = .low_fuel, .priority = .warning, .message = "LOW FUEL" });
        }

        // --- Cautions (yellow) ---
        if (fd.fuel_endurance_hrs > 0 and fd.fuel_endurance_hrs >= lim.min_endurance_warning_hrs and
            fd.fuel_endurance_hrs < lim.min_endurance_caution_hrs)
        {
            self.addAlert(.{ .id = .low_fuel_caution, .priority = .caution, .message = "FUEL LOW" });
        }

        // --- Radio altitude callouts (advisory, fire once per crossing) ---
        const fired = self.evaluateRadioAlt(fd.radio_alt_ft);

        // Keep the last callout latched on screen for the hold window even on
        // frames where no new threshold was crossed.
        if (!fired and self.latch_remaining > 0) {
            if (self.latched_id) |id| {
                self.addAlert(.{ .id = id, .priority = .advisory, .message = self.latch_msg });
            }
        }
        if (self.latch_remaining > 0) self.latch_remaining -= 1;

        // Store for next frame
        self.prev_radio_alt = fd.radio_alt_ft;

        // Sort by priority (warnings first, then cautions, then advisories)
        self.sortByPriority();
    }

    /// Get the active alerts slice.
    pub fn activeAlerts(self: *const AlertSystem) []const Alert {
        return self.alerts[0..self.active_count];
    }

    /// Check if any warning-priority alert is active.
    pub fn hasWarning(self: *const AlertSystem) bool {
        for (self.alerts[0..self.active_count]) |alert| {
            if (alert.priority == .warning) return true;
        }
        return false;
    }

    // --- Internal ---

    fn addAlert(self: *AlertSystem, alert: Alert) void {
        if (self.active_count < MAX_ALERTS) {
            self.alerts[self.active_count] = alert;
            self.active_count += 1;
        }
    }

    /// Evaluate radio-altitude callouts. Returns true if a new callout fired
    /// this frame (which also (re)arms the latch). Thresholds are ordered
    /// shallowest (2500) to deepest (10).
    fn evaluateRadioAlt(self: *AlertSystem, ra: f32) bool {
        const thresholds = [_]struct { alt: f32, id: AlertId, msg: []const u8 }{
            .{ .alt = 2500, .id = .ra_2500, .msg = "2500" },
            .{ .alt = 1000, .id = .ra_1000, .msg = "1000" },
            .{ .alt = 500, .id = .ra_500, .msg = "500" },
            .{ .alt = 200, .id = .ra_200, .msg = "200" },
            .{ .alt = 100, .id = .ra_100, .msg = "100" },
            .{ .alt = 50, .id = .ra_50, .msg = "50" },
            .{ .alt = 30, .id = .ra_30, .msg = "30" },
            .{ .alt = 20, .id = .ra_20, .msg = "20" },
            .{ .alt = 10, .id = .ra_10, .msg = "10" },
        };

        // Detect descending through a threshold: prev was above, current is at or below
        for (thresholds) |t| {
            if (self.prev_radio_alt > t.alt and ra <= t.alt and ra > 0) {
                // Only fire if we haven't already called out this threshold
                if (self.last_ra_callout) |last| {
                    if (@intFromEnum(last) >= @intFromEnum(t.id)) continue;
                }
                self.last_ra_callout = t.id;
                self.latched_id = t.id;
                self.latch_msg = t.msg;
                self.latch_remaining = CALLOUT_HOLD_FRAMES;
                self.addAlert(.{ .id = t.id, .priority = .advisory, .message = t.msg });
                return true; // One callout per frame
            }
        }

        // Re-arm on climb: if we've climbed back above a threshold, roll the
        // callout state back to the threshold just shallower than the
        // shallowest one crossed, so a subsequent descent calls the deeper
        // thresholds out again (e.g. a go-around from 400 ft then re-descent).
        // Iterating shallow→deep, the first upward crossing is the shallowest.
        for (thresholds, 0..) |t, i| {
            if (self.prev_radio_alt <= t.alt and ra > t.alt) {
                self.last_ra_callout = if (i == 0) null else thresholds[i - 1].id;
                break;
            }
        }
        return false;
    }

    fn sortByPriority(self: *AlertSystem) void {
        // Simple insertion sort on small array (max 16 elements)
        const count = self.active_count;
        if (count <= 1) return;
        var i: u8 = 1;
        while (i < count) : (i += 1) {
            const key = self.alerts[i];
            var j: u8 = i;
            while (j > 0 and @intFromEnum(self.alerts[j - 1].priority) > @intFromEnum(key.priority)) {
                self.alerts[j] = self.alerts[j - 1];
                j -= 1;
            }
            self.alerts[j] = key;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const limits = @import("limits.zig");

test "no alerts on default data" {
    var sys = AlertSystem.init();
    const fd = FlightData{};
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expectEqual(@as(u8, 0), sys.active_count);
}

test "overspeed alert" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    fd.airspeed_kts = 350; // Above GENERIC_JET Vmo of 340
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(sys.active_count >= 1);
    try std.testing.expectEqual(AlertId.overspeed, sys.alerts[0].id);
    try std.testing.expectEqual(AlertPriority.warning, sys.alerts[0].priority);
}

test "bank angle alert" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    fd.roll_deg = 35; // Above GENERIC_JET max_bank of 30
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(sys.active_count >= 1);
    // Find bank angle alert
    var found = false;
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == .bank_angle) found = true;
    }
    try std.testing.expect(found);
}

test "negative bank angle alert" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    fd.roll_deg = -35;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    var found = false;
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == .bank_angle) found = true;
    }
    try std.testing.expect(found);
}

test "descent rate alert" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    fd.vsi_fpm = -7000; // Exceeds 6000 fpm limit
    sys.evaluate(&fd, &limits.GENERIC_JET);
    var found = false;
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == .descent_rate) found = true;
    }
    try std.testing.expect(found);
}

test "low fuel warning and caution" {
    var sys = AlertSystem.init();
    var fd = FlightData{};

    // Warning: endurance < 0.5h
    fd.fuel_endurance_hrs = 0.3;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expectEqual(AlertId.low_fuel, sys.alerts[0].id);
    try std.testing.expectEqual(AlertPriority.warning, sys.alerts[0].priority);

    // Caution: 0.5 <= endurance < 1.0
    fd.fuel_endurance_hrs = 0.7;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expectEqual(AlertId.low_fuel_caution, sys.alerts[0].id);
    try std.testing.expectEqual(AlertPriority.caution, sys.alerts[0].priority);
}

fn hasAlert(sys: *const AlertSystem, id: AlertId) bool {
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == id) return true;
    }
    return false;
}

test "radio altitude callout latches for the hold window then clears" {
    var sys = AlertSystem.init();
    var fd = FlightData{};

    // Descend through 500 ft
    fd.radio_alt_ft = 600;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expectEqual(@as(u8, 0), sys.active_count); // No crossing yet

    fd.radio_alt_ft = 450; // Crossed 500 — fires
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(hasAlert(&sys, .ra_500));

    // Steady altitude next frame — no NEW crossing, but the callout is latched
    // and stays visible (this is the fix: it used to vanish after one frame).
    fd.radio_alt_ft = 440;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(hasAlert(&sys, .ra_500));

    // After the hold window elapses at a steady altitude, it clears and does
    // not re-fire (fires once per crossing).
    var i: usize = 0;
    while (i < CALLOUT_HOLD_FRAMES + 2) : (i += 1) {
        sys.evaluate(&fd, &limits.GENERIC_JET);
    }
    try std.testing.expect(!hasAlert(&sys, .ra_500));
}

test "radio altitude callouts re-arm after a go-around" {
    var sys = AlertSystem.init();
    var fd = FlightData{};

    // Descend and call out down to 200 ft.
    fd.radio_alt_ft = 600;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    fd.radio_alt_ft = 450; // ra_500
    sys.evaluate(&fd, &limits.GENERIC_JET);
    fd.radio_alt_ft = 150; // ra_200 (last_ra_callout now ra_200)
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(hasAlert(&sys, .ra_200));

    // Go around: climb through 500 and 1000 — this must re-arm the callouts.
    fd.radio_alt_ft = 1500;
    sys.evaluate(&fd, &limits.GENERIC_JET);

    // Re-descend: a callout must fire again. Without the re-arm, last_ra_callout
    // would still be ra_200 and gate every shallower threshold, producing
    // silence on the whole approach.
    fd.radio_alt_ft = 450;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(hasAlert(&sys, .ra_1000));
}

test "alerts sorted by priority" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    fd.airspeed_kts = 350; // warning: overspeed
    fd.fuel_endurance_hrs = 0.7; // caution: fuel low

    // Set up RA crossing for advisory
    sys.prev_radio_alt = 600;
    fd.radio_alt_ft = 450;

    sys.evaluate(&fd, &limits.GENERIC_JET);
    // Warnings should come before cautions, cautions before advisories
    if (sys.active_count >= 2) {
        try std.testing.expect(@intFromEnum(sys.alerts[0].priority) <= @intFromEnum(sys.alerts[1].priority));
    }
}

test "hasWarning" {
    var sys = AlertSystem.init();
    var fd = FlightData{};
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(!sys.hasWarning());

    fd.airspeed_kts = 350;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(sys.hasWarning());
}
