//! App module - application runner
//!
//! Re-exports application types.

pub const application = @import("application.zig");

pub const Application = application.Application;
pub const Config = application.Config;

test {
    @import("std").testing.refAllDecls(@This());
}
