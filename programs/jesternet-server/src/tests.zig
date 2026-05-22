// Root test entry point. Each module's tests are pulled in via @import
// so `zig build test` discovers them through the build graph.

const std = @import("std");

comptime {
    _ = @import("strings.zig");
    _ = @import("stream.zig");
    _ = @import("auth/tokens.zig");
    _ = @import("auth/pipeline.zig");
    _ = @import("store/types.zig");
    _ = @import("store/wal.zig");
    _ = @import("store/store.zig");
    _ = @import("events.zig");
    _ = @import("handlers/iso_timestamp.zig");
    _ = @import("handlers/notifications.zig");
    _ = @import("handlers/tokens.zig");
    _ = @import("handlers/settings.zig");
    _ = @import("router.zig");
    // router.zig has no tests yet — stubs only. Re-add when handler
    // dispatch lands in #64.
}

test "scaffold compiles" {
    // No-op smoke test. Confirms `zig build test` runs end-to-end against
    // the build graph + zigit dep resolution.
    try std.testing.expect(true);
}
