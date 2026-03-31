// Copyright (c) 2026 QUANTUM ENCODING LTD
// Contact: info@quantumencoding.io
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! zig_flight - X-Plane 12 Avionics MFD Toolkit
//!
//! Connects to X-Plane 12's Web API for real-time flight data streaming.
//! All flight calculators are pure functions with zero heap allocation —
//! Zig naturally enforces the JSF AV C++ coding standard.
//!
//! Sub-modules:
//! - `protocol`: JSON message construction/parsing for X-Plane WebSocket API
//! - `dataref_registry`: Dataref name→ID resolution and subscription
//! - `flight_data`: Flight data structures with update dispatch
//! - `xplane_client`: X-Plane 12 REST + WebSocket client
//! - `calc`: Pure flight calculators (wind, turn, vnav, density, fuel, nav, perf, approach)
//! - `alerts`: Alert evaluation system with radio altitude callouts
//! - `limits`: Aircraft envelope definitions and presets
//! - `demo`: Flight recording and replay
//! - `commands`: X-Plane command integration (autopilot control)

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const dataref_registry = @import("dataref_registry.zig");
pub const flight_data = @import("flight_data.zig");
pub const xplane_client = @import("xplane_client.zig");
pub const alerts = @import("alerts.zig");
pub const limits = @import("limits.zig");
pub const demo = @import("demo.zig");
pub const commands = @import("commands.zig");

// Flight calculators (Phase 2)
pub const calc = struct {
    pub const wind = @import("calc/wind.zig");
    pub const turn = @import("calc/turn.zig");
    pub const vnav = @import("calc/vnav.zig");
    pub const density_alt = @import("calc/density_alt.zig");
    pub const fuel = @import("calc/fuel.zig");
    pub const nav = @import("calc/nav.zig");
    pub const performance = @import("calc/performance.zig");
    pub const approach = @import("calc/approach.zig");
};

// TUI display system (Phase 3) + Framebuffer backend (Phase 4)
pub const display = struct {
    pub const tui_backend = @import("display/tui_backend.zig");
    pub const renderer = @import("display/renderer.zig");
    pub const pfd = @import("display/pfd.zig");
    pub const eicas = @import("display/eicas.zig");
    pub const nd = @import("display/nd.zig");
    pub const fms = @import("display/fms.zig");
    pub const mfd = @import("display/mfd.zig");
    pub const fb_backend = @import("display/fb_backend.zig");
};

// Convenience re-exports
pub const XPlaneClient = xplane_client.XPlaneClient;
pub const DatarefRegistry = dataref_registry.DatarefRegistry;
pub const FlightData = flight_data.FlightData;
pub const FieldMapping = dataref_registry.FieldMapping;
pub const AlertSystem = alerts.AlertSystem;
pub const AircraftLimits = limits.AircraftLimits;

// Dataref sets
pub const PFD_DATAREFS = dataref_registry.PFD_DATAREFS;
pub const ENGINE_DATAREFS = dataref_registry.ENGINE_DATAREFS;
pub const NAV_DATAREFS = dataref_registry.NAV_DATAREFS;
pub const FUEL_DATAREFS = dataref_registry.FUEL_DATAREFS;
pub const AUTOPILOT_DATAREFS = dataref_registry.AUTOPILOT_DATAREFS;

test {
    std.testing.refAllDecls(@This());
}
