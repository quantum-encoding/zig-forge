// staging.zig — Stage separation sequencing and jettison logic

const std = @import("std");
const vehicle_mod = @import("vehicle.zig");
const propulsion = @import("propulsion.zig");

pub const StagingEvent = struct {
    stage: u8,
    event_type: EventType,
    met_ticks: u64,

    pub const EventType = enum {
        engine_cutoff,
        separation,
        engine_ignition,
        fairing_jettison,
    };
};

pub const StagingSequencer = struct {
    events: [16]?StagingEvent = [_]?StagingEvent{null} ** 16,
    event_count: u8 = 0,
    stage1_prop_mass: f64 = 395_700, // kg propellant in stage 1
    stage2_prop_mass: f64 = 15_300, // kg propellant in stage 2

    pub fn init() StagingSequencer {
        return .{};
    }

    /// Check if stage 1 propellant is depleted
    pub fn checkStage1Depletion(self: *StagingSequencer, state: *const vehicle_mod.VehicleState) bool {
        _ = self;
        // Stage 1 is depleted when remaining propellant drops below stage 2 amount
        return state.propellant_mass_kg.value <= 15_300 and
            state.current_stage == 0 and
            state.liftoff;
    }

    pub fn logEvent(self: *StagingSequencer, event: StagingEvent) void {
        if (self.event_count < 16) {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
    }
};
