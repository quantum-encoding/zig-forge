// Cascading .gitignore ruleset.
//
// Architecture (see docs/V1_1_SPEC.md):
//   * One flat ordered list of (pattern, base_dir, source) — global
//     first, then `.git/info/exclude`, then in-repo `.gitignore`
//     files from shallowest to deepest. Within each file, lines are
//     in their original order.
//   * One evaluation function: relativize the path to each rule's
//     base_dir (skip rules whose base isn't an ancestor), match the
//     pattern, sweep LAST-TO-FIRST, first match decides — including
//     negation, which un-ignores.
//   * Two entry points: `isIgnored(path, is_dir)` and `isIgnoredDir(path)`.
//     They share the same evaluation; the dir variant exists to make
//     the prune contract explicit at the call site.
//
// The prune contract (correctness, not just perf):
//   When `isIgnoredDir(d)` returns true, the caller MUST NOT descend
//   into `d`. This is what makes "negations inside excluded
//   directories don't un-ignore" work — matching git's documented
//   behaviour. We enforce it structurally by NEVER reading the
//   `.gitignore` of a pruned subtree during cascade construction,
//   so rules from inside excluded dirs simply never enter the
//   cascade.
//
// Already-tracked files (paths that appear in the index) bypass the
// ruleset entirely — that's the caller's responsibility. `status` /
// `add` consult the index first; the ruleset is only consulted for
// paths NOT already tracked.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const pattern = @import("pattern.zig");
const Pattern = pattern.Pattern;

pub const Source = enum {
    /// `core.excludesFile` or default `~/.config/git/ignore` (lowest precedence).
    global,
    /// `.git/info/exclude`.
    info_exclude,
    /// An in-repo `.gitignore` at some depth.
    in_repo,
};

pub const RuleEntry = struct {
    pattern: Pattern,
    /// Repo-relative directory this rule's pattern is anchored to.
    /// Empty for `global` and `info_exclude`. For a `.gitignore` in
    /// `src/lib`, this is `"src/lib"`.
    base_dir: []const u8,
    source: Source,
    /// Human-readable path for diagnostics (e.g. `"src/.gitignore"`).
    source_label: []const u8,
    line_no: u32,
};

pub const Ruleset = struct {
    rules: []RuleEntry,
    /// Owns rules + every pattern's segment slices + every literal +
    /// every base_dir / source_label string.
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Ruleset) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }

    /// Test whether `path` (repo-relative, forward-slash separated)
    /// should be ignored. `is_dir` lets `dir_only` patterns gate
    /// correctly.
    ///
    /// The caller MUST consult the index FIRST — already-tracked
    /// files bypass `.gitignore`. This function answers the
    /// "should-be-ignored-if-untracked" question.
    pub fn isIgnored(self: Ruleset, path: []const u8, is_dir: bool) bool {
        return match(self.rules, path, is_dir);
    }

    /// Convenience for the walk's prune step. Equivalent to
    /// `isIgnored(path, is_dir=true)`. The contract: if this returns
    /// true, the caller MUST NOT descend into `path`. Negations inside
    /// `path` are NOT consulted and could not re-include anything
    /// even if we did descend (matches git's documented behaviour).
    pub fn isIgnoredDir(self: Ruleset, path: []const u8) bool {
        return match(self.rules, path, true);
    }
};

pub const LoadOptions = struct {
    /// Pre-read contents of the global excludes file (the caller
    /// resolves `core.excludesFile` or `~/.config/git/ignore`).
    /// Empty = no global file.
    global_excludes_bytes: []const u8 = "",
    /// Source label for diagnostics on the global file.
    global_excludes_label: []const u8 = "core.excludesFile",
    /// Pre-read contents of `.git/info/exclude`. Empty = none.
    info_exclude_bytes: []const u8 = "",
    info_exclude_label: []const u8 = ".git/info/exclude",
};

/// Build a Ruleset by walking `work_root`. The walk respects the
/// cascade-as-it's-being-built: subdirectories already excluded by
/// rules from higher up are NOT entered, so their `.gitignore`
/// files never contribute rules. This is the structural enforcement
/// of the prune-as-correctness-boundary contract.
pub fn load(
    parent_allocator: std.mem.Allocator,
    io: Io,
    work_root: Dir,
    opts: LoadOptions,
) !Ruleset {
    const arena_box = try parent_allocator.create(std.heap.ArenaAllocator);
    errdefer parent_allocator.destroy(arena_box);
    arena_box.* = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena_box.deinit();
    const arena = arena_box.allocator();

    var rules: std.ArrayListUnmanaged(RuleEntry) = .empty;

    // 1. Global excludes (lowest precedence).
    if (opts.global_excludes_bytes.len > 0) {
        const label = try arena.dupe(u8, opts.global_excludes_label);
        try parsePatterns(arena, io, &rules, opts.global_excludes_bytes, .global, "", label);
    }

    // 2. .git/info/exclude.
    if (opts.info_exclude_bytes.len > 0) {
        const label = try arena.dupe(u8, opts.info_exclude_label);
        try parsePatterns(arena, io, &rules, opts.info_exclude_bytes, .info_exclude, "", label);
    }

    // 3. Recursively walk work_root, reading .gitignore at each
    //    level and pruning excluded subtrees as we go.
    try recursiveLoad(arena, io, &rules, work_root, "");

    return .{
        .rules = try rules.toOwnedSlice(arena),
        .arena = arena_box,
    };
}

// ── Cascade-aware loader ───────────────────────────────────────────

fn recursiveLoad(
    arena: std.mem.Allocator,
    io: Io,
    rules: *std.ArrayListUnmanaged(RuleEntry),
    current_dir: Dir,
    rel_path: []const u8,
) !void {
    // Read .gitignore at the current level, if present.
    if (try readFileIfExists(arena, io, current_dir, ".gitignore")) |bytes| {
        const label = if (rel_path.len == 0)
            try arena.dupe(u8, ".gitignore")
        else
            try std.fmt.allocPrint(arena, "{s}/.gitignore", .{rel_path});
        try parsePatterns(arena, io, rules, bytes, .in_repo, rel_path, label);
    }

    // List entries and recurse into non-pruned subdirs. We capture
    // entry names eagerly because Iterator.next() invalidates the
    // previous entry's name on the next call.
    var subdirs: std.ArrayListUnmanaged([]u8) = .empty;
    defer subdirs.deinit(arena);

    var it = current_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        try subdirs.append(arena, try arena.dupe(u8, entry.name));
    }

    for (subdirs.items) |name| {
        const child_rel = if (rel_path.len == 0)
            try arena.dupe(u8, name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel_path, name });

        // PRUNE: if the cascade-so-far excludes this directory, do
        // NOT recurse — we won't read its .gitignore, so any
        // negations inside it can never enter the cascade. This is
        // the structural enforcement of git's "no un-ignoring
        // inside excluded dirs" rule.
        if (match(rules.items, child_rel, true)) continue;

        var sub = current_dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        };
        defer sub.close(io);
        try recursiveLoad(arena, io, rules, sub, child_rel);
    }
}

fn readFileIfExists(
    arena: std.mem.Allocator,
    io: Io,
    dir: Dir,
    sub_path: []const u8,
) !?[]u8 {
    return dir.readFileAlloc(io, sub_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => null,
        else => err,
    };
}

fn parsePatterns(
    arena: std.mem.Allocator,
    io: Io,
    rules: *std.ArrayListUnmanaged(RuleEntry),
    bytes: []const u8,
    source: Source,
    base_dir: []const u8,
    source_label: []const u8,
) !void {
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const pat_opt = pattern.compile(arena, line) catch |err| switch (err) {
            // Skip-with-warning per the v1.1 ruleset contract.
            // Never abort the walk over one bad pattern.
            error.UnsupportedPatternCharClass => {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "warning: skipping unsupported gitignore pattern (character class) at {s}:{d}\n",
                    .{ source_label, line_no },
                ) catch continue;
                File.stderr().writeStreamingAll(io, msg) catch {};
                continue;
            },
            error.OutOfMemory => return err,
        };
        const pat = pat_opt orelse continue; // blank line or comment
        const base_dup = try arena.dupe(u8, base_dir);
        try rules.append(arena, .{
            .pattern = pat,
            .base_dir = base_dup,
            .source = source,
            .source_label = source_label,
            .line_no = line_no,
        });
    }
}

// ── Evaluation ─────────────────────────────────────────────────────

fn match(rules: []const RuleEntry, path: []const u8, is_dir: bool) bool {
    // Last-match-wins: sweep backwards through the cascade. Return
    // immediately on the first rule that matches; negation flips
    // the answer.
    var i = rules.len;
    while (i > 0) {
        i -= 1;
        const r = &rules[i];
        const rel = relativize(path, r.base_dir) orelse continue;
        if (r.pattern.matches(rel, is_dir)) {
            return !r.pattern.negated;
        }
    }
    return false;
}

/// Make `path` relative to `base_dir`. Returns null when `path` is
/// not strictly under `base_dir` (i.e., this rule's source doesn't
/// apply to `path`).
fn relativize(path: []const u8, base_dir: []const u8) ?[]const u8 {
    if (base_dir.len == 0) return path;
    if (path.len <= base_dir.len) return null;
    if (!std.mem.startsWith(u8, path, base_dir)) return null;
    if (path[base_dir.len] != '/') return null;
    return path[base_dir.len + 1 ..];
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "relativize: strips base prefix, returns null off-scope" {
    try testing.expectEqualStrings("foo", relativize("foo", "").?);
    try testing.expectEqualStrings("foo", relativize("src/foo", "src").?);
    try testing.expectEqualStrings("a/b", relativize("src/a/b", "src").?);
    // path equals base — no children → skip
    try testing.expect(relativize("src", "src") == null);
    // path doesn't start with base → skip
    try testing.expect(relativize("lib/foo", "src") == null);
    // false-positive prefix match → skip (the path "src2/foo" must
    // NOT match base "src")
    try testing.expect(relativize("src2/foo", "src") == null);
}

test "match: empty cascade returns false for everything" {
    try testing.expect(!match(&.{}, "foo", false));
    try testing.expect(!match(&.{}, "a/b/c", true));
}

// ── Integration tests (build real ruleset from tmp dirs) ───────────

fn loadFromTmp(allocator: std.mem.Allocator, io: Io, root: Dir) !Ruleset {
    return load(allocator, io, root, .{});
}

test "ruleset: bare `*.log` in root .gitignore ignores at any depth" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.createDirPath(testing.io, "a/b");

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    try testing.expect(rs.isIgnored("foo.log", false));
    try testing.expect(rs.isIgnored("a/foo.log", false));
    try testing.expect(rs.isIgnored("a/b/foo.log", false));
    try testing.expect(!rs.isIgnored("foo.txt", false));
}

test "ruleset: nested .gitignore patterns don't leak to siblings" {
    // a/.gitignore says *.tmp. That must NOT affect b/foo.tmp.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/.gitignore", .data = "*.tmp\n" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    try testing.expect(rs.isIgnored("a/foo.tmp", false));
    try testing.expect(rs.isIgnored("a/sub/foo.tmp", false));
    try testing.expect(!rs.isIgnored("a/sub.txt", false));
    // The headline assertion — the rule scoped to `a/` doesn't leak.
    try testing.expect(!rs.isIgnored("b/foo.tmp", false));
    try testing.expect(!rs.isIgnored("foo.tmp", false));
}

test "ruleset: anchored /build in nested .gitignore stays scoped" {
    // src/.gitignore: `/build`. Must ignore src/build but NOT
    // src/lib/build (the leading-slash anchors to the .gitignore's
    // dir) and NOT root-level build.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "src/lib");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/.gitignore", .data = "/build\n" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    try testing.expect(rs.isIgnored("src/build", true));
    try testing.expect(!rs.isIgnored("src/lib/build", true));
    try testing.expect(!rs.isIgnored("build", true));
}

test "ruleset: cross-file last-match — in-repo negation overrides global" {
    // Global excludes `*.log`; in-repo .gitignore has `!debug.log`.
    // The composed cascade (global → in-repo) does a single sweep;
    // the in-repo negation, being later, wins for `debug.log`.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "!debug.log\n" });

    var rs = try load(a, testing.io, tmp.dir, .{
        .global_excludes_bytes = "*.log\n",
        .global_excludes_label = "fake-global",
    });
    defer rs.deinit();

    try testing.expect(rs.isIgnored("foo.log", false));     // global wins
    try testing.expect(!rs.isIgnored("debug.log", false));  // in-repo overrides
    try testing.expect(!rs.isIgnored("a/debug.log", false)); // basename match still works
}

test "ruleset: within-file last-match — `foo/` then `!foo/` re-includes dir" {
    // git documents one specific case: a later `!foo/` can re-include
    // a directory excluded by an earlier `foo/` in the SAME file.
    // Verify that — and also verify the cascade then descends into
    // it (because the dir isn't excluded after re-inclusion, we DO
    // load its .gitignore).
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "foo");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "foo/\n!foo/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "foo/.gitignore", .data = "secret.txt\n" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // Directory: last match wins → !foo/ → not ignored.
    try testing.expect(!rs.isIgnoredDir("foo"));
    // Since foo/ wasn't pruned during loading, its .gitignore IS
    // in the cascade, so secret.txt inside it gets evaluated.
    try testing.expect(rs.isIgnored("foo/secret.txt", false));
    try testing.expect(!rs.isIgnored("foo/visible.txt", false));
}

test "ruleset: PRUNE BOUNDARY — negation inside excluded directory does not un-ignore" {
    // The single most important correctness property of the cascade:
    // once a parent directory is excluded, files inside CANNOT be
    // un-ignored from below. We enforce this STRUCTURALLY: a pruned
    // directory's .gitignore is never read, so its !-rule never
    // enters the cascade.
    //
    // Setup:
    //   /.gitignore         excludes `bar/`
    //   /bar/.gitignore     contains `!keep.txt`
    //   /bar/keep.txt       (a file inside the excluded dir)
    //
    // Expectation:
    //   * isIgnoredDir("bar") → true (the prune fires)
    //   * The cascade does NOT contain bar/.gitignore's rule.
    //   * From the ruleset's perspective, `bar/keep.txt` is NOT a
    //     positive-match for ignoring (the dir_only pattern doesn't
    //     match a file path). But the WALKER must observe the prune
    //     contract — it never sees `bar/keep.txt` at all because it
    //     doesn't descend.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "bar");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "bar/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bar/.gitignore", .data = "!keep.txt\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bar/keep.txt", .data = "x" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // The directory is excluded.
    try testing.expect(rs.isIgnoredDir("bar"));

    // CRITICAL: the cascade contains exactly ONE rule (the root
    // `bar/`). bar/.gitignore was never read because bar was pruned
    // during cascade construction. If this assertion fails, the
    // walker could be fooled into un-ignoring `bar/keep.txt`.
    try testing.expectEqual(@as(usize, 1), rs.rules.len);
    try testing.expectEqualStrings("", rs.rules[0].base_dir);
}

test "ruleset: dir_only x is_dir interaction — `build/` matches dir but not file named build" {
    // Pattern level was covered in pattern.zig tests; this one
    // demonstrates it at the ruleset level where it actually
    // matters: a file literally named `build` (no extension)
    // should NOT be ignored by `build/`.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "build/\n" });
    try tmp.dir.createDirPath(testing.io, "build");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "buildfile", .data = "x" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // The directory match — the headline case.
    try testing.expect(rs.isIgnoredDir("build"));
    try testing.expect(rs.isIgnored("build", true));
    // A file literally named `build` — must NOT match because the
    // pattern is dir_only.
    try testing.expect(!rs.isIgnored("build", false));
    // A file with `build` as a prefix — pattern doesn't match
    // because `buildfile` ≠ `build`.
    try testing.expect(!rs.isIgnored("buildfile", false));
}

test "ruleset: in-repo .gitignore evaluated relative to its containing dir" {
    // Belt-and-suspenders for the relative-path framing.
    //   /src/.gitignore   `*.tmp`
    //   /src/foo.tmp      → ignored
    //   /lib/foo.tmp      → NOT ignored (different scope)
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.createDirPath(testing.io, "lib");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/.gitignore", .data = "*.tmp\n" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    try testing.expect(rs.isIgnored("src/foo.tmp", false));
    try testing.expect(!rs.isIgnored("lib/foo.tmp", false));
}

test "ruleset: bad pattern skipped with warning, walk continues" {
    // A `[abc]` pattern in the middle of a .gitignore should NOT
    // abort the load. The following lines should still register.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".gitignore",
        .data = "*.log\n[ch]\n*.tmp\n",
    });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // The two valid lines should both be in the cascade.
    try testing.expectEqual(@as(usize, 2), rs.rules.len);
    try testing.expect(rs.isIgnored("foo.log", false));
    try testing.expect(rs.isIgnored("foo.tmp", false));
}

test "ruleset: blank lines and # comments contribute no rules" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".gitignore",
        .data = "# a comment\n\n*.log\n\n# trailing\n",
    });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rules.len);
    try testing.expect(rs.isIgnored("x.log", false));
}

test "ruleset: info_exclude bytes contribute rules with empty base_dir" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var rs = try load(a, testing.io, tmp.dir, .{
        .info_exclude_bytes = "*.secret\n",
    });
    defer rs.deinit();

    try testing.expect(rs.isIgnored("foo.secret", false));
    try testing.expect(rs.isIgnored("a/b/foo.secret", false));
}

test "ruleset: a directory's own .gitignore cannot save it from a parent exclusion" {
    // The prune decision for a directory uses the cascade BUILT FROM
    // ITS PARENTS, before the directory's own .gitignore is read.
    // A child can never influence its own prune decision — a `!*`
    // or `!.` inside vendor/.gitignore cannot rescue `vendor/` if
    // the root .gitignore already excluded it.
    //
    // This is a different code path from the file-inside case
    // (`bar/` + bar/.gitignore `!keep.txt`) covered above — that one
    // tests "file inside excluded dir stays excluded"; this tests
    // "directory itself, evaluated by the parent's cascade".
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "vendor");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "vendor/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vendor/.gitignore", .data = "!*\n!.\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vendor/lib.js", .data = "x" });

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // The directory stays excluded — vendor/.gitignore's negations
    // cannot reach the parent's decision.
    try testing.expect(rs.isIgnoredDir("vendor"));

    // Structural proof: vendor/.gitignore was never read because
    // vendor was pruned during cascade construction. So neither
    // `!*` nor `!.` ever entered the cascade. Cascade contains
    // exactly the root rule.
    try testing.expectEqual(@as(usize, 1), rs.rules.len);
    try testing.expectEqualStrings("", rs.rules[0].base_dir);
}

test "ruleset: symlink-to-directory is not descended during cascade construction" {
    // A freshly-checked-out symlink that points at a directory must
    // NOT be walked through. Following symlink-dirs causes infinite
    // loops on cyclic links and lets the cascade leak rules from
    // outside the repo. We rely on the iterator's lstat semantics
    // (sym_link kind even when the target is a directory) plus the
    // `entry.kind != .directory` filter in recursiveLoad.
    //
    // Skip on Windows where symlink creation requires the developer
    // privilege we can't assume in tests.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Real directory with a .gitignore that, if read, would change
    // the cascade in an observable way.
    try tmp.dir.createDirPath(testing.io, "real");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real/.gitignore", .data = "leaked-rule\n" });

    // Symlink at the root pointing at the real directory. If the
    // loader followed it, real/.gitignore would be read TWICE —
    // once under "real" and once under "link" — and `leaked-rule`
    // would appear in the cascade with base_dir = "link".
    tmp.dir.symLink(testing.io, "real", "link", .{ .is_directory = true }) catch |err| switch (err) {
        // Some filesystems can't create symlinks; skip cleanly.
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var rs = try loadFromTmp(a, testing.io, tmp.dir);
    defer rs.deinit();

    // Cascade contains exactly ONE rule, from real/.gitignore — the
    // symlink wasn't followed.
    try testing.expectEqual(@as(usize, 1), rs.rules.len);
    try testing.expectEqualStrings("real", rs.rules[0].base_dir);

    // And the leaked-rule pattern only applies under "real/", not
    // under "link/" (which it would if the symlink had been
    // followed during construction).
    try testing.expect(rs.isIgnored("real/leaked-rule", false));
    try testing.expect(!rs.isIgnored("link/leaked-rule", false));
}
