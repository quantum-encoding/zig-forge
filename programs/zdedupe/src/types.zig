//! Core types for zdedupe - duplicate finder and folder comparator

const std = @import("std");

/// File entry with metadata for duplicate detection
pub const FileEntry = struct {
    /// Absolute path to the file
    path: []const u8,
    /// File size in bytes
    size: u64,
    /// Inode number (for hard link detection)
    inode: u64,
    /// Device ID
    dev: u64,
    /// Modification time (seconds since epoch)
    mtime: i64,
    /// BLAKE3 hash (computed lazily)
    hash: ?[32]u8,
    /// Quick hash (first 4KB) for fast rejection
    quick_hash: ?[32]u8,
    /// Index (into the same file list) of the first-seen entry sharing this
    /// inode, when this entry is an additional hard link to it. Only populated
    /// by directory analysis, which has to know that a directory *contains*
    /// the file; the file-level pipeline never groups or hashes such entries.
    link_of: ?usize = null,

    pub fn deinit(self: *FileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    /// Format hash as hex string
    pub fn hashHex(self: *const FileEntry, buf: *[64]u8) []const u8 {
        if (self.hash) |h| {
            return std.fmt.bufPrint(buf, "{s}", .{std.fmt.fmtSliceHexLower(&h)}) catch "";
        }
        return "";
    }
};

/// File info within a duplicate group
pub const DuplicateFileInfo = struct {
    path: []const u8,
    mtime: i64, // seconds since epoch
};

/// Group of duplicate files (same content)
pub const DuplicateGroup = struct {
    /// Size of each file in bytes
    size: u64,
    /// BLAKE3 hash shared by all files
    hash: [32]u8,
    /// List of file paths in this group (legacy, for compatibility)
    files: std.ArrayListUnmanaged([]const u8),
    /// List of files with metadata
    file_infos: std.ArrayListUnmanaged(DuplicateFileInfo),
    /// Potential space savings if all but one file deleted
    savings: u64,
    /// Allocator for managing the list
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: u64, hash: [32]u8) DuplicateGroup {
        return .{
            .size = size,
            .hash = hash,
            .files = .empty,
            .file_infos = .empty,
            .savings = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DuplicateGroup) void {
        self.files.deinit(self.allocator);
        self.file_infos.deinit(self.allocator);
    }

    pub fn addFile(self: *DuplicateGroup, path: []const u8) !void {
        try self.files.append(self.allocator, path);
        // Update savings: (count - 1) * size
        if (self.files.items.len > 1) {
            self.savings = (self.files.items.len - 1) * self.size;
        }
    }

    /// Add file with metadata
    pub fn addFileWithInfo(self: *DuplicateGroup, path: []const u8, mtime: i64) !void {
        try self.files.append(self.allocator, path);
        try self.file_infos.append(self.allocator, .{ .path = path, .mtime = mtime });
        // Update savings: (count - 1) * size
        if (self.files.items.len > 1) {
            self.savings = (self.files.items.len - 1) * self.size;
        }
    }

    pub fn count(self: *const DuplicateGroup) usize {
        return self.files.items.len;
    }
};

/// Result of comparing two folders
pub const CompareResult = struct {
    /// Path to folder A
    folder_a: []const u8,
    /// Path to folder B
    folder_b: []const u8,
    /// Files identical in both folders (relative paths)
    identical: std.ArrayListUnmanaged([]const u8),
    /// Files only in folder A
    only_in_a: std.ArrayListUnmanaged([]const u8),
    /// Files only in folder B
    only_in_b: std.ArrayListUnmanaged([]const u8),
    /// Files with same path but different content
    modified: std.ArrayListUnmanaged([]const u8),
    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, folder_a: []const u8, folder_b: []const u8) !CompareResult {
        return .{
            .folder_a = try allocator.dupe(u8, folder_a),
            .folder_b = try allocator.dupe(u8, folder_b),
            .identical = .empty,
            .only_in_a = .empty,
            .only_in_b = .empty,
            .modified = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompareResult) void {
        self.allocator.free(self.folder_a);
        self.allocator.free(self.folder_b);

        for (self.identical.items) |p| self.allocator.free(p);
        for (self.only_in_a.items) |p| self.allocator.free(p);
        for (self.only_in_b.items) |p| self.allocator.free(p);
        for (self.modified.items) |p| self.allocator.free(p);

        self.identical.deinit(self.allocator);
        self.only_in_a.deinit(self.allocator);
        self.only_in_b.deinit(self.allocator);
        self.modified.deinit(self.allocator);
    }

    pub fn isIdentical(self: *const CompareResult) bool {
        return self.only_in_a.items.len == 0 and
            self.only_in_b.items.len == 0 and
            self.modified.items.len == 0;
    }
};

/// Configuration for duplicate finder
pub const Config = struct {
    /// Minimum file size to consider (bytes)
    min_size: u64 = 1,
    /// Maximum file size to consider (0 = unlimited)
    max_size: u64 = 0,
    /// Include hidden files (dotfiles)
    include_hidden: bool = true,
    /// Follow symbolic links
    follow_symlinks: bool = false,
    /// Number of threads (0 = auto)
    threads: u32 = 0,
    /// Size of quick hash (first N bytes)
    quick_hash_size: usize = 4096,
    /// Hash algorithm
    hash_algorithm: HashAlgorithm = .blake3,
    /// Entry basenames (files or directories) pruned from the walk, matched
    /// exactly — no globs. A pruned entry is treated as if it did not exist,
    /// and is counted so reports can say what was ignored. Scan roots are
    /// never pruned: the user named them explicitly.
    excludes: []const []const u8 = &.{},
    /// Prune any directory carrying a valid CACHEDIR.TAG (bford.info/cachedir),
    /// e.g. cargo's `target/`. Safer than excluding a generic name like
    /// "target" or "build", which could just as well hold user data.
    exclude_cache_dirs: bool = false,
    /// Roll file identities up into directory identities: report identical
    /// directories and directory pairs that largely overlap. See dirs.zig.
    ///
    /// While enabled, `min_size`/`max_size` stop filtering the *walk* and only
    /// filter the reported file groups: a directory must never be declared a
    /// copy of another because the file that differs was outside the size
    /// window.
    analyze_dirs: bool = false,
    /// Optional progress/cancel channel; see `Monitor`. Borrowed, and must
    /// outlive the scan.
    monitor: ?*Monitor = null,

    /// Basenames of regenerable output, safe to ignore when deciding whether
    /// two project copies hold the same work. Deliberately absent: `.git`
    /// (history is not regenerable — a stale copy can hold the only copy of a
    /// branch or stash) and generic names such as `target`, `build`, `dist`
    /// and `out` (`exclude_cache_dirs` covers cargo's `target/` by its tag).
    pub const default_excludes = [_][]const u8{
        // dependency / build caches
        "node_modules",
        "bower_components",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        "__pycache__",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".tox",
        ".gradle",
        ".svelte-kit",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        "DerivedData",
        // desktop metadata that differs between otherwise identical copies
        ".DS_Store",
        "Thumbs.db",
        "desktop.ini",
    };

    /// Key stores and credential files, never opened. A scan only ever
    /// compares content and reports nothing about what it read, but a security
    /// tool watching file access cannot know that: a duplicate finder walking
    /// `~/.ssh` and `~/.aws` looks exactly like one exfiltrating them. Skipping
    /// them costs a user nothing — nobody reclaims space by deduplicating a
    /// private key — and keeps the scan off every such tool's radar.
    ///
    /// Exact path components, matched like any other exclude.
    pub const credential_excludes = [_][]const u8{
        ".ssh",
        ".gnupg",
        "Keychains",
        ".password-store",
        ".vault-token",
        ".aws",
        ".azure",
        "gcloud",
        ".kube",
        ".docker",
        ".terraform.d",
        ".netrc",
        ".git-credentials",
        ".npmrc",
        ".pypirc",
        ".pgpass",
        ".my.cnf",
        ".boto",
        ".s3cfg",
        ".env",
        ".envrc",
    };

    pub const HashAlgorithm = enum {
        blake3,
        sha256,
    };

    /// Get effective thread count
    pub fn getThreadCount(self: *const Config) u32 {
        if (self.threads == 0) {
            return @intCast(@max(1, std.Thread.getCpuCount() catch 4));
        }
        return self.threads;
    }

    /// True if `size` is inside the configured [min_size, max_size] window.
    pub fn sizeInRange(self: *const Config, size: u64) bool {
        if (size < self.min_size) return false;
        if (self.max_size > 0 and size > self.max_size) return false;
        return true;
    }
};

/// Progress callback data
pub const Progress = struct {
    /// Current phase
    phase: Phase,
    /// Files processed in current phase
    files_processed: u64,
    /// Total files to process
    files_total: u64,
    /// Bytes processed
    bytes_processed: u64,
    /// Total bytes
    bytes_total: u64,
    /// Current file being processed
    current_file: ?[]const u8,

    pub const Phase = enum {
        scanning,
        size_grouping,
        quick_hashing,
        full_hashing,
        reporting,
        done,
    };

    pub fn percentComplete(self: *const Progress) f64 {
        if (self.files_total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.files_processed)) /
            @as(f64, @floatFromInt(self.files_total)) * 100.0;
    }
};

/// Live view of a running scan, and the way to stop one.
///
/// Every field is an atomic, so any thread may read progress or request
/// cancellation while the scan runs on another — which is how a GUI keeps a
/// progress bar moving and a Cancel button working across the C FFI without
/// callbacks re-entering the host. The scan only ever *writes* progress and
/// *reads* `cancel_requested`.
pub const Monitor = struct {
    phase: std.atomic.Value(u32) = .init(@intFromEnum(Phase.idle)),
    /// Regular files found by the walk so far.
    files_found: std.atomic.Value(u64) = .init(0),
    /// Work items finished / expected in the current phase (hashing phases).
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    cancel_requested: std.atomic.Value(bool) = .init(false),

    /// Stable numbering: part of the C ABI (`zdedupe_progress.phase`).
    pub const Phase = enum(u32) {
        idle = 0,
        scanning = 1,
        size_grouping = 2,
        quick_hashing = 3,
        full_hashing = 4,
        analyzing = 5,
        writing = 6,
        done = 7,
    };

    pub fn reset(self: *Monitor) void {
        self.phase.store(@intFromEnum(Phase.idle), .release);
        self.files_found.store(0, .release);
        self.done.store(0, .release);
        self.total.store(0, .release);
        self.cancel_requested.store(false, .release);
    }

    pub fn enter(self: *Monitor, phase: Phase, total: u64) void {
        self.done.store(0, .release);
        self.total.store(total, .release);
        self.phase.store(@intFromEnum(phase), .release);
    }

    pub fn cancel(self: *Monitor) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn cancelled(self: *const Monitor) bool {
        return self.cancel_requested.load(.acquire);
    }
};

/// Progress callback function type
pub const ProgressCallback = *const fn (*const Progress) void;

/// Report format options
pub const ReportFormat = enum {
    text,
    json,
    html,
};

/// Report options
pub const ReportOptions = struct {
    format: ReportFormat = .text,
    /// Show full paths (vs relative)
    full_paths: bool = true,
    /// Include file hashes in output
    include_hashes: bool = false,
    /// Sort groups by savings (largest first)
    sort_by_savings: bool = true,
};

/// Summary statistics for duplicate scan
pub const DuplicateSummary = struct {
    /// Total files scanned
    files_scanned: u64,
    /// Total size of files scanned
    bytes_scanned: u64,
    /// Number of duplicate groups found
    duplicate_groups: u64,
    /// Total duplicate files (excluding originals)
    duplicate_files: u64,
    /// Potential space savings in bytes
    space_savings: u64,
    /// Time taken for scan (nanoseconds)
    scan_time_ns: u64,
    /// Entries pruned by `Config.excludes` / `Config.exclude_cache_dirs`.
    excluded_entries: u64 = 0,
    /// Scan roots dropped because another root already covers them.
    overlapping_roots: u64 = 0,

    pub fn spaceSavingsHuman(self: *const DuplicateSummary, buf: []u8) []const u8 {
        return formatBytes(self.space_savings, buf);
    }
};

/// Summary statistics for folder comparison
pub const CompareSummary = struct {
    /// Files in folder A
    files_in_a: u64,
    /// Files in folder B
    files_in_b: u64,
    /// Identical files
    identical_count: u64,
    /// Files only in A
    only_in_a_count: u64,
    /// Files only in B
    only_in_b_count: u64,
    /// Modified files
    modified_count: u64,
    /// Time taken (nanoseconds)
    compare_time_ns: u64,
};

/// Format bytes as human-readable string
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024.0 and unit_idx < units.len - 1) {
        value /= 1024.0;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_idx] }) catch "";
    }
}

/// Parse size string like "10MB", "1GB", "500KB"
pub fn parseSize(str: []const u8) !u64 {
    if (str.len == 0) return error.InvalidSize;

    var end: usize = 0;
    while (end < str.len and (std.ascii.isDigit(str[end]) or str[end] == '.')) {
        end += 1;
    }

    if (end == 0) return error.InvalidSize;

    const num_str = str[0..end];
    const suffix = str[end..];

    const num = std.fmt.parseFloat(f64, num_str) catch return error.InvalidSize;

    const multiplier: u64 = if (suffix.len == 0)
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "b"))
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "kb") or std.ascii.eqlIgnoreCase(suffix, "k"))
        1024
    else if (std.ascii.eqlIgnoreCase(suffix, "mb") or std.ascii.eqlIgnoreCase(suffix, "m"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "gb") or std.ascii.eqlIgnoreCase(suffix, "g"))
        1024 * 1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "tb") or std.ascii.eqlIgnoreCase(suffix, "t"))
        1024 * 1024 * 1024 * 1024
    else
        return error.InvalidSize;

    return @intFromFloat(num * @as(f64, @floatFromInt(multiplier)));
}

// ============================================================================
// Tests
// ============================================================================

test "formatBytes" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", formatBytes(0, &buf));
    try std.testing.expectEqualStrings("100 B", formatBytes(100, &buf));
    try std.testing.expectEqualStrings("1.00 KB", formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.50 KB", formatBytes(1536, &buf));
    try std.testing.expectEqualStrings("1.00 MB", formatBytes(1024 * 1024, &buf));
    try std.testing.expectEqualStrings("1.00 GB", formatBytes(1024 * 1024 * 1024, &buf));
}

test "parseSize" {
    try std.testing.expectEqual(@as(u64, 1024), try parseSize("1KB"));
    try std.testing.expectEqual(@as(u64, 1024), try parseSize("1kb"));
    try std.testing.expectEqual(@as(u64, 1024), try parseSize("1K"));
    try std.testing.expectEqual(@as(u64, 1048576), try parseSize("1MB"));
    try std.testing.expectEqual(@as(u64, 1073741824), try parseSize("1GB"));
    try std.testing.expectEqual(@as(u64, 500), try parseSize("500"));
    try std.testing.expectEqual(@as(u64, 1536), try parseSize("1.5KB"));
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expectEqual(@as(u64, 1), config.min_size);
    try std.testing.expectEqual(@as(u64, 0), config.max_size);
    try std.testing.expect(config.include_hidden);
    try std.testing.expect(!config.follow_symlinks);
}

test "Progress percentComplete" {
    const p1 = Progress{
        .phase = .scanning,
        .files_processed = 50,
        .files_total = 100,
        .bytes_processed = 0,
        .bytes_total = 0,
        .current_file = null,
    };
    try std.testing.expectEqual(@as(f64, 50.0), p1.percentComplete());

    const p2 = Progress{
        .phase = .done,
        .files_processed = 0,
        .files_total = 0,
        .bytes_processed = 0,
        .bytes_total = 0,
        .current_file = null,
    };
    try std.testing.expectEqual(@as(f64, 0.0), p2.percentComplete());
}

test "DuplicateGroup" {
    const allocator = std.testing.allocator;
    var group = DuplicateGroup.init(allocator, 1024, [_]u8{0} ** 32);
    defer group.deinit();

    try group.addFile("/path/a");
    try std.testing.expectEqual(@as(u64, 0), group.savings);

    try group.addFile("/path/b");
    try std.testing.expectEqual(@as(u64, 1024), group.savings);

    try group.addFile("/path/c");
    try std.testing.expectEqual(@as(u64, 2048), group.savings);
}
