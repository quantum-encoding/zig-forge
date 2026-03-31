// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Path validation and sandbox enforcement
//! Ensures all file operations stay within the sandbox root

const std = @import("std");

pub const PathError = error{
    PathOutsideSandbox,
    PathContainsNullByte,
    PathTooLong,
    InvalidPath,
    SymlinkLoop,
    AccessDenied,
};

pub const PathValidator = struct {
    sandbox_root: []const u8,
    writable_paths: []const []const u8,
    readonly_paths: []const []const u8,
    allocator: std.mem.Allocator,

    /// Canonical sandbox root (resolved)
    canonical_root: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        sandbox_root: []const u8,
        writable_paths: []const []const u8,
        readonly_paths: []const []const u8,
    ) !PathValidator {
        // Canonicalize sandbox root
        const canonical = try canonicalizePath(allocator, sandbox_root);

        return PathValidator{
            .sandbox_root = sandbox_root,
            .writable_paths = writable_paths,
            .readonly_paths = readonly_paths,
            .allocator = allocator,
            .canonical_root = canonical,
        };
    }

    pub fn deinit(self: *PathValidator) void {
        self.allocator.free(self.canonical_root);
    }

    /// Validate a path is within the sandbox and return its canonical form
    pub fn validatePath(self: *const PathValidator, path: []const u8) ![]const u8 {
        // Check for null bytes
        if (std.mem.indexOfScalar(u8, path, 0) != null) {
            return PathError.PathContainsNullByte;
        }

        // Resolve path relative to sandbox root if not absolute
        const full_path = if (path.len > 0 and path[0] == '/') blk: {
            break :blk try self.allocator.dupe(u8, path);
        } else blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.canonical_root, path });
        };
        defer self.allocator.free(full_path);

        // Canonicalize
        const canonical = try canonicalizePath(self.allocator, full_path);
        errdefer self.allocator.free(canonical);

        // Check if within sandbox
        if (!isPathWithinRoot(canonical, self.canonical_root)) {
            self.allocator.free(canonical);
            return PathError.PathOutsideSandbox;
        }

        return canonical;
    }

    /// Check if a validated path is writable
    pub fn isWritable(self: *const PathValidator, canonical_path: []const u8) bool {
        // If writable_paths is empty, entire sandbox is writable
        if (self.writable_paths.len == 0) {
            return true;
        }

        // Check if path is under any writable path
        for (self.writable_paths) |writable| {
            // Resolve writable path relative to sandbox if needed
            if (isPathWithinRoot(canonical_path, writable)) {
                return true;
            }
        }

        return false;
    }

    /// Check if a validated path is readable
    pub fn isReadable(self: *const PathValidator, canonical_path: []const u8) bool {
        _ = self;
        _ = canonical_path;
        // All paths within sandbox are readable
        return true;
    }
};

/// Canonicalize a path (resolve ., .., symlinks)
/// Caller owns returned memory
pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Use realpath via C for proper symlink resolution
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = std.c.realpath(path_z.ptr, &resolved_buf);

    if (result == null) {
        // Path doesn't exist yet - manually resolve . and ..
        return manualCanonicalize(allocator, path);
    }

    const resolved = std.mem.span(result.?);
    return allocator.dupe(u8, resolved);
}

/// Manual path canonicalization for non-existent paths
fn manualCanonicalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    defer components.deinit(allocator);

    const is_absolute = path.len > 0 and path[0] == '/';

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
        } else {
            try components.append(allocator, component);
        }
    }

    // Build result
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    if (is_absolute) {
        try result.append(allocator, '/');
    }

    for (components.items, 0..) |comp, i| {
        if (i > 0) {
            try result.append(allocator, '/');
        }
        try result.appendSlice(allocator, comp);
    }

    if (result.items.len == 0) {
        return allocator.dupe(u8, if (is_absolute) "/" else ".");
    }

    return result.toOwnedSlice(allocator);
}

/// Check if path is within root directory
fn isPathWithinRoot(path: []const u8, root: []const u8) bool {
    // Path must start with root
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }

    // If path is exactly root, it's valid
    if (path.len == root.len) {
        return true;
    }

    // If path is longer, next char must be /
    // This prevents /home/user matching /home/user2
    if (path.len > root.len) {
        return path[root.len] == '/';
    }

    return false;
}

// Tests
test "path within root" {
    try std.testing.expect(isPathWithinRoot("/home/user/work", "/home/user"));
    try std.testing.expect(isPathWithinRoot("/home/user", "/home/user"));
    try std.testing.expect(!isPathWithinRoot("/home/user2", "/home/user"));
    try std.testing.expect(!isPathWithinRoot("/etc/passwd", "/home/user"));
}

test "manual canonicalize" {
    const allocator = std.testing.allocator;

    const result1 = try manualCanonicalize(allocator, "/home/user/../user/./work");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("/home/user/work", result1);

    const result2 = try manualCanonicalize(allocator, "foo/bar/../baz");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("foo/baz", result2);
}
