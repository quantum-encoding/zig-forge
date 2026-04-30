// Re-exports for diff.

pub const myers = @import("myers.zig");
pub const unified = @import("unified.zig");
pub const Op = myers.Op;
pub const Edit = myers.Edit;

test {
    _ = @import("myers.zig");
    _ = @import("unified.zig");
}
