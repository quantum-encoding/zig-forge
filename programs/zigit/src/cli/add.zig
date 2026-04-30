// `zigit add <files...>`
//
// Porcelain wrapper around `update-index --add`. We don't yet handle
// directories or globs ("zigit add ." Phase 4) — pass explicit
// file paths.

const std = @import("std");
const Io = std.Io;
const update_index = @import("update_index.zig");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingFileArgument;

    // Re-use update-index's --add code path. Build a fresh argv that
    // prepends the flag.
    var forwarded: std.ArrayListUnmanaged([]const u8) = .empty;
    defer forwarded.deinit(allocator);
    try forwarded.append(allocator, "--add");
    for (args) |a| try forwarded.append(allocator, a);

    try update_index.run(allocator, io, forwarded.items);
}
