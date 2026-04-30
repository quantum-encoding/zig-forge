// Walk the work tree and produce a flat list of every file.
//
// Skips:
//   - `.git/`               — git's own metadata
//   - the `.git/index.tmp`  rename target should never be visible here,
//                           but we'd ignore it on principle anyway
//
// We don't yet honour `.gitignore` — that lands in Phase 5 along with
// `add` recursion. Symlinks are recorded with their lstat mode.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Mode = enum { regular, executable, symlink };

pub const Entry = struct {
    /// Slash-separated path relative to the work-tree root. Owned.
    path: []u8,
    mode: Mode,
};

/// Owned slice of Entry. Free with `freeEntries`.
pub const Listing = []Entry;

pub fn freeEntries(allocator: std.mem.Allocator, listing: Listing) void {
    for (listing) |e| allocator.free(e.path);
    allocator.free(listing);
}

pub fn walk(allocator: std.mem.Allocator, io: Io, work_root: Dir) !Listing {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }

    // We need an iterable handle on the same directory, so reopen
    // with .iterate=true. The original handle stays untouched.
    var iter_root = try work_root.openDir(io, ".", .{ .iterate = true });
    defer iter_root.close(io);

    var walker = try iter_root.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |w_entry| {
        // Normalise to forward-slashes so paths match index storage
        // even on Windows. The walker uses path.sep which is '\\' on
        // win32 — easy fix when we get there.
        switch (w_entry.kind) {
            .directory => {
                if (std.mem.eql(u8, w_entry.basename, ".git")) continue;
                try walker.enter(io, w_entry);
            },
            .file => {
                try entries.append(allocator, .{
                    .path = try allocator.dupe(u8, w_entry.path),
                    .mode = .regular, // permissions check happens at stat-time
                });
            },
            .sym_link => {
                try entries.append(allocator, .{
                    .path = try allocator.dupe(u8, w_entry.path),
                    .mode = .symlink,
                });
            },
            else => {},
        }
    }

    // Stable order for downstream comparisons.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    return try entries.toOwnedSlice(allocator);
}
