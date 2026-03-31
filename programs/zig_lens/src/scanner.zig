const std = @import("std");
const models = @import("models.zig");

pub const FileEntry = struct {
    path: []const u8,
    relative_path: []const u8,
    size_bytes: u64,
    language: models.Language,
};

const skip_dirs = [_][]const u8{
    "zig-cache",
    "zig-out",
    ".zig-cache",
    ".git",
    ".github",
    "target", // Rust build artifacts
    "node_modules",
    "__pycache__",
    ".svelte-kit",
    ".next",
    "dist",
    "venv",
    ".venv",
    ".egg-info",
    "vendor", // Go vendored dependencies
};

fn shouldSkipPath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        for (&skip_dirs) |skip| {
            if (std.mem.eql(u8, component, skip)) return true;
        }
    }
    return false;
}

pub fn scanDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) !std.ArrayListUnmanaged(FileEntry) {
    var entries: std.ArrayListUnmanaged(FileEntry) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return entries;
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return entries;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        const lang = detectLanguage(entry.basename) orelse continue;

        // Skip files inside excluded directories
        if (shouldSkipPath(entry.path)) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        const rel_path = try allocator.dupe(u8, entry.path);

        // File size comes from source length during parse
        const size: u64 = 0;

        try entries.append(allocator, .{
            .path = full_path,
            .relative_path = rel_path,
            .size_bytes = size,
            .language = lang,
        });
    }

    // Sort by relative path for deterministic output
    std.mem.sortUnstable(FileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
        }
    }.lessThan);

    return entries;
}

pub fn scanSingleFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !std.ArrayListUnmanaged(FileEntry) {
    var entries: std.ArrayListUnmanaged(FileEntry) = .empty;

    const path_copy = try allocator.dupe(u8, file_path);

    // Extract basename as relative path
    const basename = std.fs.path.basename(file_path);
    const rel = try allocator.dupe(u8, basename);
    const lang = detectLanguage(basename) orelse .zig;

    try entries.append(allocator, .{
        .path = path_copy,
        .relative_path = rel,
        .size_bytes = 0,
        .language = lang,
    });

    return entries;
}

fn detectLanguage(basename: []const u8) ?models.Language {
    if (std.mem.endsWith(u8, basename, ".zig")) return .zig;
    if (std.mem.endsWith(u8, basename, ".rs")) return .rust;
    if (std.mem.endsWith(u8, basename, ".c")) return .c;
    if (std.mem.endsWith(u8, basename, ".h")) return .c;
    if (std.mem.endsWith(u8, basename, ".py")) return .python;
    if (std.mem.endsWith(u8, basename, ".js")) return .javascript;
    if (std.mem.endsWith(u8, basename, ".ts")) return .javascript;
    if (std.mem.endsWith(u8, basename, ".tsx")) return .javascript;
    if (std.mem.endsWith(u8, basename, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, basename, ".svelte")) return .javascript;
    if (std.mem.endsWith(u8, basename, ".go")) return .go;
    return null;
}

pub fn detectProjectName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "./")) {
        return "project";
    }
    const trimmed = std.mem.trim(u8, path, "/");
    if (trimmed.len == 0) return "project";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        return trimmed[idx + 1 ..];
    }
    return trimmed;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "detectLanguage recognizes .zig files" {
    const lang = detectLanguage("example.zig");
    try std.testing.expectEqual(lang, models.Language.zig);
}

test "detectLanguage recognizes .py files" {
    const lang = detectLanguage("script.py");
    try std.testing.expectEqual(lang, models.Language.python);
}

test "detectLanguage recognizes .rs files" {
    const lang = detectLanguage("main.rs");
    try std.testing.expectEqual(lang, models.Language.rust);
}

test "detectLanguage recognizes .js files" {
    const lang = detectLanguage("app.js");
    try std.testing.expectEqual(lang, models.Language.javascript);
}

test "detectLanguage recognizes .c files" {
    const lang = detectLanguage("main.c");
    try std.testing.expectEqual(lang, models.Language.c);
}

test "detectLanguage recognizes .h files" {
    const lang = detectLanguage("header.h");
    try std.testing.expectEqual(lang, models.Language.c);
}

test "detectLanguage returns null for unknown extensions" {
    const lang = detectLanguage("file.unknown");
    try std.testing.expect(lang == null);
}

test "detectLanguage recognizes .tsx files as JavaScript" {
    const lang = detectLanguage("component.tsx");
    try std.testing.expectEqual(lang, models.Language.javascript);
}

test "detectLanguage recognizes .jsx files as JavaScript" {
    const lang = detectLanguage("component.jsx");
    try std.testing.expectEqual(lang, models.Language.javascript);
}

test "detectProjectName for current directory" {
    const name = detectProjectName(".");
    try std.testing.expectEqualSlices(u8, name, "project");
}

test "detectProjectName for root directory" {
    const name = detectProjectName("./");
    try std.testing.expectEqualSlices(u8, name, "project");
}

test "detectProjectName extracts simple name" {
    const name = detectProjectName("myproject");
    try std.testing.expectEqualSlices(u8, name, "myproject");
}

test "detectProjectName extracts name from path" {
    const name = detectProjectName("/home/user/myproject");
    try std.testing.expectEqualSlices(u8, name, "myproject");
}

test "shouldSkipPath returns true for zig-cache" {
    const should_skip = shouldSkipPath("zig-cache/stuff");
    try std.testing.expect(should_skip);
}

test "shouldSkipPath returns true for node_modules" {
    const should_skip = shouldSkipPath("node_modules/lib");
    try std.testing.expect(should_skip);
}

test "shouldSkipPath returns false for regular paths" {
    const should_skip = shouldSkipPath("src/main.zig");
    try std.testing.expect(!should_skip);
}
