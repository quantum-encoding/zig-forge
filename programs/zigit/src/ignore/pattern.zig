// Single .gitignore pattern: compile + match.
//
// Compile-time recognised syntax:
//   * Literal bytes, anywhere in the pattern.
//   * `*`        — 0+ chars except '/'  (token: .star)
//   * `?`        — 1 char except '/'    (token: .question)
//   * `**` in valid path-aware contexts — different token kinds:
//       - `**/foo`   leading `**/`   → .doublestar_dirs  (0+ "X/" runs)
//       - `foo/**/bar` middle `/**/` → .doublestar_dirs  (0+ "X/" runs)
//       - `foo/**`   trailing `/**`  → .doublestar       (0+ any chars)
//       - `**`       standalone      → .doublestar
//       - any other `**` position    → demoted to .star
//   * Leading `/`     → strips, sets `anchored=true`.
//   * Trailing `/`    → strips, sets `dir_only=true`.
//   * An internal `/` after stripping the above → `anchored=true`.
//   * Leading `!`     → strips, sets `negated=true`.
//   * Lines starting with `#` and blank lines → `compile` returns null.
//   * Backslash escapes: `\!`, `\#`, `\*`, `\?`, `\\` — the next
//     character is a literal byte. Useful for files literally named
//     `!foo` or `#bar`. A trailing backslash is kept as a literal `\`.
//
// Not supported in v1.1 — returns a clear error:
//   * Character classes `[abc]`, `[!a-z]` → `UnsupportedPatternCharClass`.
//
// Matcher semantics (Pattern.matches(path, is_dir)):
//   * `dir_only=true` AND `is_dir=false` → false.
//   * `anchored=true` → segments must match the FULL path starting
//     at position 0.
//   * `anchored=false` → the segments must match either the FULL
//     path or a /-aligned suffix of it (basename semantics). Matches
//     git's "no-slash patterns match at any depth via basename" rule:
//     `foo` matches `a/b/foo`, `*.log` matches `dir/foo.log`, etc.
//
// Note: `Segment` carries five tags rather than the four sketched in
// the spec. We needed `doublestar_dirs` to give `**/X` and `/**/`
// their canonical "0+ directory components, possibly zero" semantics
// inside the matcher; a generic `doublestar` (0+ chars including '/')
// can't represent "zero dirs" correctly when followed by a literal
// that has no leading slash.

const std = @import("std");

pub const Error = error{
    UnsupportedPatternCharClass,
    OutOfMemory,
};

pub const Segment = union(enum) {
    /// Exact byte match. May contain '/'.
    literal: []const u8,
    /// 0+ chars, none of which is '/'.
    star,
    /// 1 char, not '/'.
    question,
    /// 0+ chars, may include '/'. Used for trailing `/**` and a
    /// standalone `**` pattern.
    doublestar,
    /// 0+ "directory runs" — each run is `[^/]+/`. The empty match
    /// counts ("zero dirs"). Used for `**/foo` and `foo/**/bar` so
    /// the in-pattern slashes get absorbed cleanly.
    doublestar_dirs,
};

pub const Pattern = struct {
    /// Token sequence — caller-owned via deinit.
    segments: []Segment,
    /// True when the pattern is intended to match relative to the
    /// .gitignore's directory rather than at any depth. Set by the
    /// presence of a non-trailing '/' in the raw line. CONSUMED by the
    /// ruleset layer, not by `matches` itself.
    anchored: bool,
    /// True when the raw line ended in '/'.
    dir_only: bool,
    /// True when the raw line started with '!'.
    negated: bool,
    /// True if any segment is `.doublestar` or `.doublestar_dirs`.
    /// Pre-computed so a caller can pick a fast path for simple-glob
    /// patterns.
    has_doublestar: bool,

    pub fn deinit(self: *Pattern, allocator: std.mem.Allocator) void {
        for (self.segments) |seg| switch (seg) {
            .literal => |lit| allocator.free(lit),
            .star, .question, .doublestar, .doublestar_dirs => {},
        };
        allocator.free(self.segments);
        self.* = undefined;
    }

    pub fn matches(self: Pattern, path: []const u8, is_dir: bool) bool {
        if (self.dir_only and !is_dir) return false;

        // Anchored: full path only.
        if (self.anchored) return matchAt(self.segments, 0, path, 0);

        // Unanchored: try the full path AND every /-aligned suffix.
        // This is the basename-match-at-any-depth semantic from
        // gitignore(5): `foo` ignores `a/b/foo`, `*.log` ignores
        // `dir/foo.log`. `*` itself still doesn't cross '/' — that's
        // a per-segment glob property, separate from the
        // try-each-suffix loop.
        if (matchAt(self.segments, 0, path, 0)) return true;
        var p: usize = 0;
        while (true) {
            if (p >= path.len) return false;
            const slash = std.mem.indexOfScalarPos(u8, path, p, '/') orelse return false;
            p = slash + 1;
            if (matchAt(self.segments, 0, path, p)) return true;
        }
    }
};

// ── Compilation ────────────────────────────────────────────────────

/// Compile a single .gitignore line. Returns null for blank lines
/// and `#`-comments (caller iterates with this in mind).
pub fn compile(allocator: std.mem.Allocator, raw_line: []const u8) Error!?Pattern {
    // 1. Trim trailing whitespace. Leading whitespace is significant
    //    in gitignore (it can be part of a filename); don't trim it.
    var line = std.mem.trimEnd(u8, raw_line, " \t\r\n");

    // 2. Blank / `#`-comment. An ESCAPED `\#` is a literal `#` — we
    //    only return null for an unescaped leading hash.
    if (line.len == 0) return null;
    if (line[0] == '#') return null;

    // 3. Negation prefix. `!foo` un-ignores foo; `\!foo` is the
    //    LITERAL filename "!foo" (escape — keep the bang, don't set
    //    `negated`). A bare `!` produces no rule.
    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
        if (line.len == 0) return null;
    }

    // 4. Directory-only suffix. A trailing literal `/` flags this; a
    //    trailing `\/` would technically be an escaped slash, but the
    //    only realistic escape contexts for `/` are at character
    //    boundaries and gitignore doesn't define them — treat the
    //    raw last byte.
    var dir_only = false;
    if (line[line.len - 1] == '/') {
        dir_only = true;
        line = line[0 .. line.len - 1];
        if (line.len == 0) return null;
    }

    // 5. Anchoring.
    //    A leading '/' anchors (and is stripped). After that, if the
    //    remaining line still contains a '/', the pattern is also
    //    anchored — git's rule is "any non-trailing separator anchors".
    var anchored = false;
    if (line[0] == '/') {
        anchored = true;
        line = line[1..];
        if (line.len == 0) return null;
    } else if (std.mem.indexOfScalar(u8, line, '/')) |_| {
        anchored = true;
    }

    // 6. Tokenize. We accumulate literal bytes into `lit_buf` rather
    //    than slicing the input — escapes (`\X` → X) need to be
    //    filtered out of the literal stream.
    var segs: std.ArrayListUnmanaged(Segment) = .empty;
    errdefer freeSegmentList(allocator, &segs);
    var lit_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer lit_buf.deinit(allocator);

    var has_doublestar = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            '*' => {
                try flushLiteral(allocator, &segs, &lit_buf);

                if (i + 1 < line.len and line[i + 1] == '*') {
                    // Double-star. The token we emit depends on
                    // surrounding context — see file header.
                    const at_start = i == 0;
                    const at_end = i + 2 == line.len;
                    const slash_before = i > 0 and line[i - 1] == '/';
                    const slash_after = i + 2 < line.len and line[i + 2] == '/';

                    if (at_start and slash_after) {
                        // `**/X` at start — emit dirs-absorber and skip
                        // past the trailing '/' so the next literal
                        // doesn't carry it.
                        try segs.append(allocator, .doublestar_dirs);
                        has_doublestar = true;
                        i += 3;
                    } else if (slash_before and slash_after) {
                        // `/**/` in the middle — same dirs-absorber.
                        try segs.append(allocator, .doublestar_dirs);
                        has_doublestar = true;
                        i += 3;
                    } else if (slash_before and at_end) {
                        // Trailing `/**` — generic doublestar.
                        try segs.append(allocator, .doublestar);
                        has_doublestar = true;
                        i += 2;
                    } else if (at_start and at_end) {
                        // `**` alone — generic doublestar.
                        try segs.append(allocator, .doublestar);
                        has_doublestar = true;
                        i += 2;
                    } else {
                        // Invalid context. Per gitignore(5):
                        //   "Other consecutive asterisks are considered
                        //   regular asterisks."
                        // Demote both `*`s to a single star.
                        try segs.append(allocator, .star);
                        i += 2;
                    }
                } else {
                    try segs.append(allocator, .star);
                    i += 1;
                }
            },
            '?' => {
                try flushLiteral(allocator, &segs, &lit_buf);
                try segs.append(allocator, .question);
                i += 1;
            },
            '[' => return Error.UnsupportedPatternCharClass,
            '\\' => {
                // Escape: the next byte is literal regardless of what
                // it is. A trailing backslash (no follower) is kept
                // as a literal `\` — matches sane glob conventions.
                if (i + 1 >= line.len) {
                    try lit_buf.append(allocator, '\\');
                    i += 1;
                } else {
                    try lit_buf.append(allocator, line[i + 1]);
                    i += 2;
                }
            },
            else => {
                try lit_buf.append(allocator, c);
                i += 1;
            },
        }
    }
    try flushLiteral(allocator, &segs, &lit_buf);

    return Pattern{
        .segments = try segs.toOwnedSlice(allocator),
        .anchored = anchored,
        .dir_only = dir_only,
        .negated = negated,
        .has_doublestar = has_doublestar,
    };
}

fn flushLiteral(
    allocator: std.mem.Allocator,
    segs: *std.ArrayListUnmanaged(Segment),
    lit_buf: *std.ArrayListUnmanaged(u8),
) Error!void {
    if (lit_buf.items.len == 0) return;
    const owned = try lit_buf.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    try segs.append(allocator, .{ .literal = owned });
}

fn freeSegmentList(allocator: std.mem.Allocator, segs: *std.ArrayListUnmanaged(Segment)) void {
    for (segs.items) |seg| switch (seg) {
        .literal => |lit| allocator.free(lit),
        .star, .question, .doublestar, .doublestar_dirs => {},
    };
    segs.deinit(allocator);
}

// ── Matcher ────────────────────────────────────────────────────────

fn matchAt(segs: []const Segment, s_idx: usize, path: []const u8, p_idx: usize) bool {
    if (s_idx >= segs.len) return p_idx == path.len;

    switch (segs[s_idx]) {
        .literal => |lit| {
            if (path.len - p_idx < lit.len) return false;
            if (!std.mem.eql(u8, path[p_idx .. p_idx + lit.len], lit)) return false;
            return matchAt(segs, s_idx + 1, path, p_idx + lit.len);
        },
        .question => {
            if (p_idx >= path.len) return false;
            if (path[p_idx] == '/') return false;
            return matchAt(segs, s_idx + 1, path, p_idx + 1);
        },
        .star => {
            // Try 0..n consumed bytes; bail if we'd cross a '/'.
            var n: usize = 0;
            while (true) {
                if (matchAt(segs, s_idx + 1, path, p_idx + n)) return true;
                if (p_idx + n >= path.len) return false;
                if (path[p_idx + n] == '/') return false;
                n += 1;
            }
        },
        .doublestar => {
            // Try 0..n consumed bytes; '/' is allowed.
            var n: usize = 0;
            while (true) {
                if (matchAt(segs, s_idx + 1, path, p_idx + n)) return true;
                if (p_idx + n >= path.len) return false;
                n += 1;
            }
        },
        .doublestar_dirs => {
            // Try matching zero directory runs first (the canonical
            // "**/foo matches foo" case).
            if (matchAt(segs, s_idx + 1, path, p_idx)) return true;
            // Then 1+ dir runs: consume up to the next '/' and recurse
            // from just past it.
            var p = p_idx;
            while (true) {
                const slash = std.mem.indexOfScalarPos(u8, path, p, '/') orelse return false;
                if (matchAt(segs, s_idx + 1, path, slash + 1)) return true;
                p = slash + 1;
                if (p >= path.len) return false;
            }
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn compileOrPanic(line: []const u8) Pattern {
    const p = compile(testing.allocator, line) catch |err| std.debug.panic(
        "compileOrPanic: compile failed for '{s}': {s}",
        .{ line, @errorName(err) },
    );
    return p orelse @panic("expected pattern");
}

test "literal: matches exact name" {
    var p = compileOrPanic("foo.txt");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foo.txt", false));
    try testing.expect(!p.anchored);
    try testing.expect(!p.dir_only);
    try testing.expect(!p.negated);
    try testing.expect(!p.has_doublestar);
}

test "literal: doesn't match a different name" {
    var p = compileOrPanic("foo.txt");
    defer p.deinit(testing.allocator);
    try testing.expect(!p.matches("bar.txt", false));
}

test "anchored: leading slash sets anchor and is stripped" {
    var p = compileOrPanic("/build");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.matches("build", false));
    // `matches` requires the FULL path to match the segments. The
    // ruleset layer is responsible for not even calling `matches`
    // against `src/build` for an anchored pattern (it'd only try
    // against the path verbatim). Verify the pattern doesn't slop
    // its match across the leading directory.
    try testing.expect(!p.matches("src/build", false));
}

test "anchored: internal slash anchors too" {
    var p = compileOrPanic("src/foo");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.matches("src/foo", false));
    try testing.expect(!p.matches("foo", false));
    try testing.expect(!p.matches("x/src/foo", false));
}

test "dir_only: trailing slash gates on is_dir" {
    var p = compileOrPanic("node_modules/");
    defer p.deinit(testing.allocator);
    try testing.expect(p.dir_only);
    try testing.expect(p.matches("node_modules", true));
    try testing.expect(!p.matches("node_modules", false));
}

test "star: matches anything except /" {
    var p = compileOrPanic("*.log");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foo.log", false));
    try testing.expect(p.matches(".log", false)); // star matches empty
    try testing.expect(!p.matches("foo.txt", false));
    // Unanchored no-slash patterns use basename semantics — so
    // `*.log` DOES match `dir/foo.log` because the basename
    // `foo.log` matches. `*` itself still doesn't cross '/' inside
    // a single segment; the basename walk happens at the matcher
    // boundary, not inside a glob token.
    try testing.expect(p.matches("dir/foo.log", false));
    try testing.expect(p.matches("a/b/c/foo.log", false));
    // But the basename still has to match — not every depth-X path.
    try testing.expect(!p.matches("dir/foo.txt", false));
}

test "bare literal: no-slash pattern matches at any depth" {
    // The spec's headline gitignore semantic: a no-slash pattern
    // matches at any depth via basename. `foo` ignores both root-
    // level `foo` and nested `a/b/foo`.
    var p = compileOrPanic("foo");
    defer p.deinit(testing.allocator);
    try testing.expect(!p.anchored);
    try testing.expect(p.matches("foo", false));
    try testing.expect(p.matches("a/foo", false));
    try testing.expect(p.matches("a/b/foo", false));
    try testing.expect(p.matches("a/b/c/foo", false));
    // The basename must match exactly — partials don't count.
    try testing.expect(!p.matches("foobar", false));
    try testing.expect(!p.matches("a/foobar", false));
    try testing.expect(!p.matches("a/b/foo/extra", false));
}

test "star: bare `*` matches leading-dot files" {
    // Shell glob in many tools skips dotfiles for `*`. gitignore
    // does NOT — `*` matches any basename including `.env`. Verify.
    var p = compileOrPanic("*");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches(".env", false));
    try testing.expect(p.matches(".hidden", false));
    try testing.expect(p.matches("visible.txt", false));
    // And via the basename walk at depth too.
    try testing.expect(p.matches("nested/.env", false));
    try testing.expect(p.matches("a/b/.env", false));
}

test "doublestar trailing: `foo/**` does not match `foo` itself" {
    // `foo/**` requires at least one path component AFTER `foo/`.
    // It ignores everything in the foo subtree, but NOT foo itself.
    // Real git: `git check-ignore foo` returns nothing when only
    // `foo/**` is in .gitignore.
    var p = compileOrPanic("foo/**");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.has_doublestar);
    try testing.expect(!p.matches("foo", false));
    try testing.expect(!p.matches("foo", true)); // not even as a directory
    try testing.expect(p.matches("foo/x", false));
    try testing.expect(p.matches("foo/x/y", false));
    try testing.expect(p.matches("foo/x/y/z.txt", false));
}

test "doublestar: leading **/ matches at any depth (including zero)" {
    var p = compileOrPanic("**/node_modules");
    defer p.deinit(testing.allocator);
    try testing.expect(p.has_doublestar);
    try testing.expect(p.matches("node_modules", false)); // zero dirs
    try testing.expect(p.matches("a/node_modules", false));
    try testing.expect(p.matches("a/b/node_modules", false));
    try testing.expect(p.matches("a/b/c/node_modules", false));
    // Must still anchor to the basename — partial matches fail.
    try testing.expect(!p.matches("node_modules_x", false));
    try testing.expect(!p.matches("a/not_node_modules", false));
}

test "doublestar: middle /**/ matches zero or more middle dirs" {
    var p = compileOrPanic("a/**/b");
    defer p.deinit(testing.allocator);
    try testing.expect(p.has_doublestar);
    try testing.expect(p.matches("a/b", false)); // zero middle dirs
    try testing.expect(p.matches("a/x/b", false));
    try testing.expect(p.matches("a/x/y/b", false));
    try testing.expect(!p.matches("a/b/extra", false));
    try testing.expect(!p.matches("x/a/b", false));
}

test "doublestar: trailing /** matches anything in the subtree" {
    var p = compileOrPanic("vendor/**");
    defer p.deinit(testing.allocator);
    try testing.expect(p.has_doublestar);
    try testing.expect(p.matches("vendor/x", false));
    try testing.expect(p.matches("vendor/x/y", false));
    try testing.expect(p.matches("vendor/x/y/z.txt", false));
    // Trailing `/**` requires at least one path component after
    // "vendor/" — the standalone "vendor" path has no trailing slash
    // for the literal "vendor/" to match.
    try testing.expect(!p.matches("vendor", false));
}

test "doublestar: ** in invalid position demotes to *" {
    // `foo**bar` is per spec "consecutive asterisks treated as
    // regular asterisks" — equivalent to `foo*bar` (single star).
    var p = compileOrPanic("foo**bar");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foobar", false));
    try testing.expect(p.matches("foo_xyz_bar", false));
    // Crucially, ** in this position must NOT cross '/'.
    try testing.expect(!p.matches("foo/bar", false));
}

test "question: matches exactly one non-slash char" {
    var p = compileOrPanic("foo?.txt");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foox.txt", false));
    try testing.expect(p.matches("foo1.txt", false));
    try testing.expect(!p.matches("foo.txt", false));   // zero chars
    try testing.expect(!p.matches("fooxx.txt", false)); // two chars
    try testing.expect(!p.matches("foo/.txt", false));  // slash isn't matched
}

test "negation: leading ! sets the flag and is stripped" {
    var p = compileOrPanic("!important.log");
    defer p.deinit(testing.allocator);
    try testing.expect(p.negated);
    // The pattern body still matches normally — negation is the
    // ruleset's signal to UN-ignore.
    try testing.expect(p.matches("important.log", false));
    try testing.expect(!p.matches("trivial.log", false));
}

test "compile: blank line returns null" {
    try testing.expect((try compile(testing.allocator, "")) == null);
    try testing.expect((try compile(testing.allocator, "   ")) == null);
    try testing.expect((try compile(testing.allocator, "\t")) == null);
}

test "compile: # comment returns null" {
    try testing.expect((try compile(testing.allocator, "# this is a comment")) == null);
    try testing.expect((try compile(testing.allocator, "#node_modules")) == null);
}

test "compile: bare '!' returns null" {
    try testing.expect((try compile(testing.allocator, "!")) == null);
}

test "compile: bare '/' returns null" {
    try testing.expect((try compile(testing.allocator, "/")) == null);
}

test "compile: character class is rejected with clear error" {
    try testing.expectError(Error.UnsupportedPatternCharClass, compile(testing.allocator, "[abc]"));
    try testing.expectError(Error.UnsupportedPatternCharClass, compile(testing.allocator, "foo[0-9].txt"));
}

test "escape: `\\!foo` matches literal `!foo` (not negation)" {
    var p = compileOrPanic("\\!foo");
    defer p.deinit(testing.allocator);
    try testing.expect(!p.negated);
    try testing.expect(p.matches("!foo", false));
    try testing.expect(!p.matches("foo", false));
    // Basename walk still works on the escaped literal.
    try testing.expect(p.matches("a/!foo", false));
}

test "escape: `\\#foo` matches literal `#foo` (not a comment)" {
    var p = compileOrPanic("\\#foo");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("#foo", false));
    try testing.expect(p.matches("a/#foo", false));
    try testing.expect(!p.matches("foo", false));
}

test "escape: `\\*` is a literal asterisk, NOT a wildcard" {
    var p = compileOrPanic("\\*");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("*", false));
    // A literal `*` doesn't match arbitrary filenames the way a
    // glob would.
    try testing.expect(!p.matches("foo", false));
    try testing.expect(!p.matches("anything", false));
}

test "escape: `\\?` is a literal question mark" {
    var p = compileOrPanic("\\?");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("?", false));
    try testing.expect(!p.matches("x", false));
}

test "escape: `\\\\` is a literal backslash" {
    var p = compileOrPanic("\\\\");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("\\", false));
    try testing.expect(!p.matches("", false));
}

test "escape: trailing backslash is kept as a literal `\\`" {
    var p = compileOrPanic("foo\\");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foo\\", false));
}

test "compile: combination — negated dir_only literal" {
    var p = compileOrPanic("!build/");
    defer p.deinit(testing.allocator);
    try testing.expect(p.negated);
    try testing.expect(p.dir_only);
    try testing.expect(!p.anchored);
    try testing.expect(p.matches("build", true));
    try testing.expect(!p.matches("build", false));
}

test "compile: combination — anchored dir_only with glob" {
    var p = compileOrPanic("/dist/*.map/");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.dir_only);
    try testing.expect(p.matches("dist/foo.map", true));
    try testing.expect(p.matches("dist/bar.map", true));
    try testing.expect(!p.matches("dist/foo.map", false));    // not a dir
    try testing.expect(!p.matches("nested/dist/foo.map", true)); // anchored
}

test "compile: trailing whitespace is trimmed" {
    var p = compileOrPanic("foo.txt   ");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("foo.txt", false));
    // The trailing spaces shouldn't have been baked into the literal.
    try testing.expect(!p.matches("foo.txt   ", false));
}

test "compile: leading whitespace is significant (matches git)" {
    var p = compileOrPanic("  spaced");
    defer p.deinit(testing.allocator);
    try testing.expect(p.matches("  spaced", false));
    try testing.expect(!p.matches("spaced", false));
}

test "matcher: literal containing internal slash (anchored multi-segment)" {
    var p = compileOrPanic("src/cli/main.zig");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.matches("src/cli/main.zig", false));
    try testing.expect(!p.matches("src/cli/main.zigx", false));
    try testing.expect(!p.matches("xsrc/cli/main.zig", false));
}

test "matcher: star inside a path segment" {
    var p = compileOrPanic("src/*.zig");
    defer p.deinit(testing.allocator);
    try testing.expect(p.anchored);
    try testing.expect(p.matches("src/main.zig", false));
    try testing.expect(p.matches("src/foo.zig", false));
    // `*` doesn't cross '/'.
    try testing.expect(!p.matches("src/sub/foo.zig", false));
}

test "matcher: leading **/ combined with dir_only" {
    var p = compileOrPanic("**/target/");
    defer p.deinit(testing.allocator);
    try testing.expect(p.dir_only);
    try testing.expect(p.has_doublestar);
    try testing.expect(p.matches("target", true));
    try testing.expect(p.matches("a/target", true));
    try testing.expect(p.matches("a/b/target", true));
    try testing.expect(!p.matches("target", false)); // not a dir
}

test "matcher: empty segments slice (defensive — shouldn't happen via compile)" {
    // compile() never produces an empty segment slice for a real
    // pattern, but the matcher must still behave for path == empty.
    var p = compileOrPanic("a");
    defer p.deinit(testing.allocator);
    try testing.expect(!p.matches("", false));
}
