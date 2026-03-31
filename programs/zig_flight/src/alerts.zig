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

pub const AlertSystem = struct {
    alerts: [MAX_ALERTS]Alert = undefined,
    active_count: u8 = 0,
    prev_radio_alt: f32 = 0,
    last_ra_callout: ?AlertId = null,

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
        self.evaluateRadioAlt(fd.radio_alt_ft);

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

    fn evaluateRadioAlt(self: *AlertSystem, ra: f32) void {
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
                self.addAlert(.{ .id = t.id, .priority = .advisory, .message = t.msg });
                return; // One callout per frame
            }
        }

        // Reset callout state when climbing above 2500
        if (ra > 2500 and self.prev_radio_alt <= 2500) {
            self.last_ra_callout = null;
        }
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

test "radio altitude callout fires once" {
    var sys = AlertSystem.init();
    var fd = FlightData{};

    // Descend through 500 ft
    fd.radio_alt_ft = 600;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expectEqual(@as(u8, 0), sys.active_count); // No crossing yet

    fd.radio_alt_ft = 450; // Crossed 500
    sys.evaluate(&fd, &limits.GENERIC_JET);
    try std.testing.expect(sys.active_count >= 1);
    var found_500 = false;
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == .ra_500) found_500 = true;
    }
    try std.testing.expect(found_500);

    // Same altitude next frame — should NOT fire again
    fd.radio_alt_ft = 440;
    sys.evaluate(&fd, &limits.GENERIC_JET);
    found_500 = false;
    for (sys.alerts[0..sys.active_count]) |a| {
        if (a.id == .ra_500) found_500 = true;
    }
    try std.testing.expect(!found_500);
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
