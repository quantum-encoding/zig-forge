//! Lock-Free Message Queues
//!
//! Wait-free inter-thread communication

pub const spsc = @import("spsc/queue.zig");
pub const mpmc = @import("mpmc/queue.zig");

pub fn Spsc(comptime T: type) type {
    return spsc.SpscQueue(T);
}

pub fn Mpmc(comptime T: type) type {
    return mpmc.MpmcQueue(T);
}

test {
    @import("std").testing.refAllDecls(@This());
}
