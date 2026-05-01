// Re-exports for merge.

pub const base = @import("base.zig");
pub const three_way = @import("three_way.zig");

test {
    _ = @import("base.zig");
    _ = @import("three_way.zig");
}
