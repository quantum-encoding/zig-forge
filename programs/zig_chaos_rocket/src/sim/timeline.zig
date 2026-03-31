// timeline.zig — Mission timeline: T-minus countdown, milestone events
//
// A Falcon 9-like launch sequence from ignition to orbit insertion.
// All times are in integer ticks, never floating-point.

const std = @import("std");
const vehicle_mod = @import("vehicle.zig");
const propulsion = @import("propulsion.zig");
const physics = @import("physics.zig");

pub const MilestoneType = enum {
    countdown_start,
    engine_chill,
    startup_ignition,
    liftoff,
    pitch_program,
    max_q,
    throttle_up,
    meco, // Main Engine Cut-Off
    stage_separation,
    ses1, // Second Engine Start 1
    fairing_sep,
    seco1, // Second Engine Cut-Off 1
    orbit_insertion,
    mission_complete,
};

pub const Milestone = struct {
    mtype: MilestoneType,
    name: []const u8,
    met_seconds: f64, // Nominal time (seconds from liftoff)
    triggered: bool = false,
    description: []const u8,
};

pub const Timeline = struct {
    milestones: [14]Milestone,
    current_idx: usize = 0,

    pub fn init() Timeline {
        return .{
            .milestones = .{
                .{ .mtype = .countdown_start, .name = "T-10 COUNTDOWN", .met_seconds = -10, .description = "Terminal countdown begins" },
                .{ .mtype = .engine_chill, .name = "ENGINE CHILL", .met_seconds = -7, .description = "LOX/RP-1 chill sequence" },
                .{ .mtype = .startup_ignition, .name = "IGNITION", .met_seconds = -3, .description = "Stage 1 engine ignition" },
                .{ .mtype = .liftoff, .name = "LIFTOFF", .met_seconds = 0, .description = "Holddown clamps release" },
                .{ .mtype = .pitch_program, .name = "PITCH PROGRAM", .met_seconds = 10, .description = "Begin gravity turn" },
                .{ .mtype = .max_q, .name = "MAX-Q", .met_seconds = 72, .description = "Maximum dynamic pressure" },
                .{ .mtype = .throttle_up, .name = "THROTTLE UP", .met_seconds = 90, .description = "Throttle back to 100%" },
                .{ .mtype = .meco, .name = "MECO", .met_seconds = 162, .description = "Main engine cut-off" },
                .{ .mtype = .stage_separation, .name = "STAGE SEP", .met_seconds = 165, .description = "Stage 1/2 separation" },
                .{ .mtype = .ses1, .name = "SES-1", .met_seconds = 170, .description = "Second engine start" },
                .{ .mtype = .fairing_sep, .name = "FAIRING SEP", .met_seconds = 210, .description = "Payload fairing jettison" },
                .{ .mtype = .seco1, .name = "SECO-1", .met_seconds = 510, .description = "Second engine cut-off" },
                .{ .mtype = .orbit_insertion, .name = "ORBIT INSERT", .met_seconds = 520, .description = "Orbital insertion confirmed" },
                .{ .mtype = .mission_complete, .name = "MISSION COMPLETE", .met_seconds = 540, .description = "Nominal orbit achieved" },
            },
        };
    }

    /// Check if any milestones should fire at the current MET
    pub fn checkMilestones(self: *Timeline, met_seconds: f64) ?*Milestone {
        for (&self.milestones) |*m| {
            if (!m.triggered and met_seconds >= m.met_seconds) {
                m.triggered = true;
                return m;
            }
        }
        return null;
    }

    /// Execute milestone actions on the vehicle
    pub fn executeMilestone(milestone: *const Milestone, state: *vehicle_mod.VehicleState, engines: *propulsion.EngineCluster) void {
        switch (milestone.mtype) {
            .startup_ignition => {
                engines.igniteStage(0);
            },
            .liftoff => {
                state.liftoff = true;
                state.stage_ignited[0] = true;
            },
            .pitch_program => {
                // Begin gravity turn: tilt 2 degrees from vertical
                state.attitude = units.Quaternion.fromAxisAngle(0, 1, 0, 88.0 * units.DEG_TO_RAD);
            },
            .max_q => {
                // Throttle down through max-Q
                engines.activeEngine().setThrottle(0.7);
            },
            .throttle_up => {
                engines.activeEngine().setThrottle(1.0);
            },
            .meco => {
                engines.shutdownStage(0);
                state.meco = true;
            },
            .stage_separation => {
                state.stage_separated[0] = true;
                state.current_stage = 1;
                // Drop stage 1 dry mass (subtract stage 1 dry mass from total dry)
                state.dry_mass_kg.value -= 22_200;
            },
            .ses1 => {
                engines.igniteStage(1);
                state.stage_ignited[1] = true;
            },
            .fairing_sep => {
                // Drop fairing mass
                state.dry_mass_kg.value -= 1_800;
            },
            .seco1 => {
                engines.shutdownStage(1);
            },
            .orbit_insertion => {
                state.in_orbit = true;
            },
            .mission_complete, .countdown_start, .engine_chill => {},
        }
    }

    /// Get the next upcoming milestone
    pub fn nextMilestone(self: *const Timeline) ?*const Milestone {
        for (&self.milestones) |*m| {
            if (!m.triggered) return m;
        }
        return null;
    }

    /// Count triggered milestones
    pub fn completedCount(self: *const Timeline) usize {
        var count: usize = 0;
        for (self.milestones) |m| {
            if (m.triggered) count += 1;
        }
        return count;
    }
};

const units = @import("../units/units.zig");

test "timeline initialization" {
    const tl = Timeline.init();
    try std.testing.expectEqual(@as(usize, 0), tl.completedCount());
}

test "milestones trigger in order" {
    var tl = Timeline.init();
    _ = tl.checkMilestones(-10);
    _ = tl.checkMilestones(-7);
    _ = tl.checkMilestones(-3);
    const liftoff = tl.checkMilestones(0);
    try std.testing.expect(liftoff != null);
    try std.testing.expect(liftoff.?.mtype == .liftoff);
}
