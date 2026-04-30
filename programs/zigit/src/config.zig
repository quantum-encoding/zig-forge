// Tiny .git/config reader.
//
// git's config format is INI-shaped:
//
//   [section]
//       key = value
//   [section "subsection"]
//       key = value
//
// Phase 3 only needs `[user] name` and `[user] email`, so we
// implement the smallest possible subset:
//
//   * Skip blank lines and lines starting with `#` or `;`.
//   * `[name]` opens a section, lowercased. We don't bother with
//     subsections (none in the keys we care about).
//   * `key = value` lines record `(section.key) → value`. Leading and
//     trailing whitespace on both sides is stripped.
//   * Quoted values, escapes, line continuations: not supported.
//
// Returns null lookups for missing values; the porcelain layer
// decides whether that's an error or falls back to env / defaults.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Keys are stored as "section.key" (e.g. "user.name") to flatten
    /// the two-level lookup into one StringHashMap.
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Config) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn get(self: *const Config, dotted_key: []const u8) ?[]const u8 {
        return self.map.get(dotted_key);
    }
};

/// Load `.git/config`. Returns an empty Config if the file is missing.
pub fn load(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !Config {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    const bytes = git_dir.readFileAlloc(io, "config", arena.allocator(), .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena },
        else => return err,
    };

    var cfg: Config = .{ .arena = arena };
    try parseInto(&cfg, bytes);
    return cfg;
}

/// Parse a config payload into `cfg.map`. Values are dup'd into the
/// arena owned by `cfg`.
pub fn parseInto(cfg: *Config, bytes: []const u8) !void {
    const allocator = cfg.arena.allocator();

    var current_section: []const u8 = ""; // empty until we see a [section]
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.MalformedSection;
            // We deliberately drop subsections — `[user]` is enough for
            // our keys, and `[remote "origin"]` would silently be
            // treated as section "remote" for us, which is wrong but
            // harmless until we actually need remotes.
            const inside = std.mem.trim(u8, line[1..close], " \t\"");
            const space = std.mem.indexOfScalar(u8, inside, ' ');
            const section_name = if (space) |i| inside[0..i] else inside;

            const lowered = try allocator.alloc(u8, section_name.len);
            for (section_name, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
            current_section = lowered;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or current_section.len == 0) continue;

        const dotted = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ current_section, key });
        const value_copy = try allocator.dupe(u8, value);
        try cfg.map.put(allocator, dotted, value_copy);
    }
}

const testing = std.testing;

test "parses a minimal user section" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();

    try parseInto(&cfg,
        \\[core]
        \\    repositoryformatversion = 0
        \\[user]
        \\    name = Alice
        \\    email = alice@example.com
        \\
    );

    try testing.expectEqualStrings("Alice", cfg.get("user.name").?);
    try testing.expectEqualStrings("alice@example.com", cfg.get("user.email").?);
    try testing.expectEqualStrings("0", cfg.get("core.repositoryformatversion").?);
}

test "ignores comments and blank lines" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();

    try parseInto(&cfg,
        \\# top comment
        \\
        \\[user]
        \\; oops
        \\    name = Bob
        \\
    );

    try testing.expectEqualStrings("Bob", cfg.get("user.name").?);
}

test "missing key returns null" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();
    try parseInto(&cfg, "[user]\n    name = X\n");
    try testing.expect(cfg.get("user.email") == null);
    try testing.expect(cfg.get("never.heard.of.it") == null);
}
