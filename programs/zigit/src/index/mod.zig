// Re-exports for the index subsystem.

pub const Index = @import("file.zig").Index;
pub const Entry = @import("entry.zig").Entry;
pub const Mode = @import("entry.zig").Mode;

test {
    _ = @import("entry.zig");
    _ = @import("file.zig");
}
