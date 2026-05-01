// .git/config reader + writer.
//
// git's config format is INI-shaped:
//
//   [section]
//       key = value
//   [section "subsection"]
//       key = value
//
// We model each setting as an `Entry { section, subsection, key, value }`
// in an ordered list. Lookups walk the list from the end, so the
// last-write-wins (the rule git uses for duplicates).
//
// Lookups accept dotted keys:
//
//   "user.name"          → section="user", subsection=null, key="name"
//   "remote.origin.url"  → section="remote", subsection="origin", key="url"
//
// Writes go through `set(section, subsection, key, value)` (which
// replaces the last matching entry or appends). `save(io, git_dir)`
// serialises the entries grouped by `(section, subsection)` and
// writes back to `.git/config`. Comments and exact whitespace are
// not preserved — this matches what `git config` does when it
// rewrites a file without complaint, and is good enough for our
// scope (clone setting `remote.origin.url`, `remote add`, etc.).
//
// `loadWithGlobal` reads `~/.gitconfig` first, then overlays
// `.git/config`, so project settings override global ones — the
// rule git uses. Only the project-local file is ever written back.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Entry = struct {
    /// Lowercased section name (`user`, `remote`, ...).
    section: []const u8,
    /// Subsection — case-sensitive, owned by arena, or null for plain
    /// `[name]` sections.
    subsection: ?[]const u8,
    /// Lowercased key name.
    key: []const u8,
    /// Value, owned by arena.
    value: []const u8,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Config) void {
        self.entries.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// Look up a value by dotted key. Returns null if missing.
    /// Walks from the end so last-write-wins on duplicates.
    pub fn get(self: *const Config, dotted_key: []const u8) ?[]const u8 {
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (entryMatchesDotted(e, dotted_key)) return e.value;
        }
        return null;
    }

    /// Set or replace a value. Walks from the end and replaces the
    /// last matching entry; if none exists, appends.
    pub fn set(
        self: *Config,
        section: []const u8,
        subsection: ?[]const u8,
        key: []const u8,
        value: []const u8,
    ) !void {
        const allocator = self.arena.allocator();
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (entryMatches(e, section, subsection, key)) {
                self.entries.items[i].value = try allocator.dupe(u8, value);
                return;
            }
        }
        try self.entries.append(allocator, .{
            .section = try allocator.dupe(u8, section),
            .subsection = if (subsection) |s| try allocator.dupe(u8, s) else null,
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }

    /// Set by dotted key. The dotted form is parsed as
    /// `section.key` (two parts) or `section.subsection.key`
    /// (three+ parts; everything between the first and last dot is
    /// treated as the subsection name).
    pub fn setDotted(self: *Config, dotted_key: []const u8, value: []const u8) !void {
        const parsed = parseDotted(dotted_key) orelse return error.InvalidConfigKey;
        try self.set(parsed.section, parsed.subsection, parsed.key, value);
    }

    /// Remove every entry matching the dotted key. Returns true if
    /// at least one entry was removed.
    pub fn unset(self: *Config, dotted_key: []const u8) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (entryMatchesDotted(self.entries.items[i], dotted_key)) {
                _ = self.entries.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Enumerate the distinct subsections under a top-level section.
    /// The returned slice is owned by the caller and lifetimes are
    /// borrowed from `self`'s arena (so don't outlive the Config).
    pub fn subsections(
        self: *const Config,
        allocator: std.mem.Allocator,
        section: []const u8,
    ) ![]const []const u8 {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);

        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.section, section)) continue;
            const sub = e.subsection orelse continue;
            if ((try seen.getOrPut(allocator, sub)).found_existing) continue;
            try out.append(allocator, sub);
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Serialise to an Allocating writer in `[section]` / `[section "sub"]`
    /// blocks. Loses comments, normalises whitespace.
    pub fn serialize(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        // Group by (section, subsection). Order of first appearance
        // is preserved so a round-trip on a hand-written config
        // doesn't reshuffle every time.
        const Group = struct {
            section: []const u8,
            subsection: ?[]const u8,
            indices: std.ArrayListUnmanaged(usize),
        };
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        defer {
            for (groups.items) |*g| g.indices.deinit(allocator);
            groups.deinit(allocator);
        }

        for (self.entries.items, 0..) |e, idx| {
            var found: ?usize = null;
            for (groups.items, 0..) |g, gi| {
                if (!std.mem.eql(u8, g.section, e.section)) continue;
                const same_sub = (g.subsection == null and e.subsection == null) or
                    (g.subsection != null and e.subsection != null and
                        std.mem.eql(u8, g.subsection.?, e.subsection.?));
                if (same_sub) {
                    found = gi;
                    break;
                }
            }
            if (found) |gi| {
                try groups.items[gi].indices.append(allocator, idx);
            } else {
                var indices: std.ArrayListUnmanaged(usize) = .empty;
                try indices.append(allocator, idx);
                try groups.append(allocator, .{
                    .section = e.section,
                    .subsection = e.subsection,
                    .indices = indices,
                });
            }
        }

        var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        defer allocating.deinit();
        const w = &allocating.writer;

        for (groups.items) |g| {
            if (g.subsection) |sub| {
                try w.print("[{s} \"{s}\"]\n", .{ g.section, sub });
            } else {
                try w.print("[{s}]\n", .{g.section});
            }
            for (g.indices.items) |idx| {
                const e = self.entries.items[idx];
                try w.print("\t{s} = {s}\n", .{ e.key, e.value });
            }
        }

        return try allocating.toOwnedSlice();
    }

    /// Save back to `.git/config`. Atomic via a `config.lock`
    /// rename so a crash mid-write can't truncate the file.
    pub fn save(self: *const Config, allocator: std.mem.Allocator, io: Io, git_dir: Dir) !void {
        const bytes = try self.serialize(allocator);
        defer allocator.free(bytes);
        try git_dir.writeFile(io, .{ .sub_path = "config.lock", .data = bytes });
        try git_dir.rename("config.lock", git_dir, "config", io);
    }
};

const ParsedKey = struct {
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
};

fn parseDotted(dotted: []const u8) ?ParsedKey {
    const first = std.mem.indexOfScalar(u8, dotted, '.') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, dotted, '.') orelse return null;
    if (first == 0 or last == dotted.len - 1) return null;
    if (first == last) {
        return .{
            .section = dotted[0..first],
            .subsection = null,
            .key = dotted[first + 1 ..],
        };
    }
    return .{
        .section = dotted[0..first],
        .subsection = dotted[first + 1 .. last],
        .key = dotted[last + 1 ..],
    };
}

fn entryMatches(
    e: Entry,
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
) bool {
    if (!std.mem.eql(u8, e.section, section)) return false;
    if (!std.mem.eql(u8, e.key, key)) return false;
    if (e.subsection == null and subsection == null) return true;
    if (e.subsection == null or subsection == null) return false;
    return std.mem.eql(u8, e.subsection.?, subsection.?);
}

fn entryMatchesDotted(e: Entry, dotted: []const u8) bool {
    const parsed = parseDotted(dotted) orelse return false;
    return entryMatches(e, parsed.section, parsed.subsection, parsed.key);
}

/// Load `.git/config`. Returns an empty Config if the file is missing.
pub fn load(allocator: std.mem.Allocator, io: Io, git_dir: Dir) !Config {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    var cfg: Config = .{ .arena = arena };
    const bytes = git_dir.readFileAlloc(io, "config", cfg.arena.allocator(), .unlimited) catch |err| switch (err) {
        error.FileNotFound => return cfg,
        else => return err,
    };
    try parseInto(&cfg, bytes);
    return cfg;
}

/// Load `~/.gitconfig` first (if HOME is set + the file exists),
/// then overlay `.git/config`. Last write wins, so project settings
/// override global ones.
pub fn loadWithGlobal(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    git_dir: Dir,
) !Config {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    var cfg: Config = .{ .arena = arena };

    if (environ.getPosix("HOME")) |home| {
        const path = try std.fs.path.join(cfg.arena.allocator(), &.{ home, ".gitconfig" });
        if (Dir.cwd().readFileAlloc(io, path, cfg.arena.allocator(), .unlimited)) |bytes| {
            try parseInto(&cfg, bytes);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (git_dir.readFileAlloc(io, "config", cfg.arena.allocator(), .unlimited)) |bytes| {
        try parseInto(&cfg, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return cfg;
}

/// Parse a config payload into `cfg.entries`. Strings are dup'd into
/// the config's arena.
pub fn parseInto(cfg: *Config, bytes: []const u8) !void {
    const allocator = cfg.arena.allocator();

    var current_section: []const u8 = "";
    var current_subsection: ?[]const u8 = null;
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.MalformedSection;
            const inside = std.mem.trim(u8, line[1..close], " \t");
            const space = std.mem.indexOfScalar(u8, inside, ' ');
            if (space) |sp| {
                const section_raw = std.mem.trim(u8, inside[0..sp], " \t");
                const sub_raw = std.mem.trim(u8, inside[sp + 1 ..], " \t");
                const sub_unquoted = std.mem.trim(u8, sub_raw, "\"");
                current_section = try lowerDup(allocator, section_raw);
                current_subsection = try allocator.dupe(u8, sub_unquoted);
            } else {
                current_section = try lowerDup(allocator, inside);
                current_subsection = null;
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_raw = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key_raw.len == 0 or current_section.len == 0) continue;

        const key = try lowerDup(allocator, key_raw);
        const sub_copy = if (current_subsection) |s| try allocator.dupe(u8, s) else null;
        try cfg.entries.append(allocator, .{
            .section = try allocator.dupe(u8, current_section),
            .subsection = sub_copy,
            .key = key,
            .value = try allocator.dupe(u8, value),
        });
    }
}

fn lowerDup(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
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

test "parses subsection (remote.origin.url)" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();

    try parseInto(&cfg,
        \\[remote "origin"]
        \\    url = https://example.com/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[remote "fork"]
        \\    url = https://example.com/fork.git
        \\
    );

    try testing.expectEqualStrings("https://example.com/repo.git", cfg.get("remote.origin.url").?);
    try testing.expectEqualStrings("https://example.com/fork.git", cfg.get("remote.fork.url").?);
}

test "subsections enumerates remote names" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();

    try parseInto(&cfg,
        \\[remote "origin"]
        \\    url = https://a/r.git
        \\[remote "fork"]
        \\    url = https://b/r.git
        \\[branch "main"]
        \\    remote = origin
        \\
    );

    const subs = try cfg.subsections(testing.allocator, "remote");
    defer testing.allocator.free(subs);
    try testing.expectEqual(@as(usize, 2), subs.len);
    try testing.expectEqualStrings("origin", subs[0]);
    try testing.expectEqualStrings("fork", subs[1]);
}

test "set + get + serialize round-trip" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();

    try cfg.set("user", null, "name", "Alice");
    try cfg.set("user", null, "email", "alice@example.com");
    try cfg.set("remote", "origin", "url", "https://example.com/r.git");

    try testing.expectEqualStrings("Alice", cfg.get("user.name").?);
    try testing.expectEqualStrings("https://example.com/r.git", cfg.get("remote.origin.url").?);

    const text = try cfg.serialize(testing.allocator);
    defer testing.allocator.free(text);

    var roundtrip: Config = .{ .arena = .init(testing.allocator) };
    defer roundtrip.deinit();
    try parseInto(&roundtrip, text);
    try testing.expectEqualStrings("Alice", roundtrip.get("user.name").?);
    try testing.expectEqualStrings("alice@example.com", roundtrip.get("user.email").?);
    try testing.expectEqualStrings("https://example.com/r.git", roundtrip.get("remote.origin.url").?);
}

test "set replaces existing value" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();
    try cfg.set("user", null, "name", "Alice");
    try cfg.set("user", null, "name", "Bob");
    try testing.expectEqualStrings("Bob", cfg.get("user.name").?);

    var count: usize = 0;
    for (cfg.entries.items) |e| {
        if (entryMatches(e, "user", null, "name")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "unset removes entries" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();
    try cfg.set("remote", "origin", "url", "https://x/y.git");
    try testing.expect(cfg.get("remote.origin.url") != null);
    try testing.expect(cfg.unset("remote.origin.url"));
    try testing.expect(cfg.get("remote.origin.url") == null);
    try testing.expect(!cfg.unset("remote.origin.url"));
}

test "setDotted handles two-part and three-part keys" {
    var cfg: Config = .{ .arena = .init(testing.allocator) };
    defer cfg.deinit();
    try cfg.setDotted("user.email", "x@y");
    try cfg.setDotted("remote.origin.url", "https://z");
    try testing.expectEqualStrings("x@y", cfg.get("user.email").?);
    try testing.expectEqualStrings("https://z", cfg.get("remote.origin.url").?);
}
