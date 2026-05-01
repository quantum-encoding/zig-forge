// Re-exports for diff.

pub const myers = @import("myers.zig");
pub const unified = @import("unified.zig");
pub const diff3 = @import("diff3.zig");
pub const Op = myers.Op;
pub const Edit = myers.Edit;

test {
    _ = @import("myers.zig");
    _ = @import("unified.zig");
    _ = @import("diff3.zig");
}
