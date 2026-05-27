// Rule engine for the zig_lens security scanner.
//
// This module exposes a data-driven rule schema (`Rule` / `RuleKind` /
// `Confidence`), a TOML loader, and a scan engine that dispatches a
// loaded rule against a source line + the enclosing-function table.
//
// The historic hardcoded rules (JSON-IN-FMT, MBEDTLS-VERIFY-NONE,
// EQL-FOR-SECRETS, SHELL-CHILD) live in `default_rules.toml` and are
// embedded into the binary via `@embedFile`. The `--rules <path>` CLI
// flag overrides the embedded default with a user-supplied TOML
// document, so audit teams can ship organization-specific rulesets
// without recompiling the scanner.
//
// Gating policy:
//   confidence = "high"   + gate = true    → counted toward --strict
//                                            (fatal exit 2 if matched)
//   confidence = "high"   + gate = false   → printed as WARN
//   confidence = "medium" / "low"          → printed as WARN regardless
//                                            of gate (advisory only)
//
// This is the "fuzzy advisory" mode: new candidate rules can ship at
// medium confidence, surface in scan output as WARN, and prove
// themselves before being promoted to gate=true.

const std = @import("std");
const toml = @import("zig_toml");
const models = @import("../models.zig");

// ── Public types ──────────────────────────────────────────────────

pub const Confidence = enum {
    high,
    medium,
    low,

    pub fn fromString(s: []const u8) ?Confidence {
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "low")) return .low;
        return null;
    }

    pub fn toString(self: Confidence) []const u8 {
        return switch (self) {
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }
};

pub const RuleKind = enum {
    /// Match strictly on the current line. Optional `window_lines`
    /// lookahead lets a multi-line format string register a match.
    line_match,
    /// `line_match` semantics PLUS the enclosing function's name
    /// or parameters must contain a recognized secret sub-token.
    enclosing_fn,
    /// `line_match` semantics PLUS the enclosing function's body
    /// must mention a process-spawn primitive (Child.init,
    /// process.run, execve, execvp).
    enclosing_fn_with_body,
    /// The line must contain at least one item from EACH group
    /// listed in `line_groups`. Useful for argv-pair patterns
    /// ([\"sh\", \"-c\"], [\"bash\", \"-c\"] …).
    line_groups,

    pub fn fromString(s: []const u8) ?RuleKind {
        if (std.mem.eql(u8, s, "line_match")) return .line_match;
        if (std.mem.eql(u8, s, "enclosing_fn")) return .enclosing_fn;
        if (std.mem.eql(u8, s, "enclosing_fn_with_body")) return .enclosing_fn_with_body;
        if (std.mem.eql(u8, s, "line_groups")) return .line_groups;
        return null;
    }
};

/// One detection rule. Owns all of its string slices (TOML loader
/// dupes everything onto the supplied allocator).
pub const Rule = struct {
    id: []const u8,
    summary: []const u8,
    message: []const u8,
    covers: []const u8,
    does_not_cover: []const u8,
    severity: models.RiskLevel,
    confidence: Confidence,
    gate: bool,
    kind: RuleKind,

    // line_match / enclosing_fn / enclosing_fn_with_body inputs.
    // `contains_any` matches by raw substring; `contains_ident_any`
    // matches by token boundary (so `eql` doesn't fire inside
    // `equal_to`). The rule fires if ANY array has a hit — the
    // arrays are OR'd within the line filter.
    contains_any: [][]const u8 = &.{},
    contains_ident_any: [][]const u8 = &.{},
    not_contains_ident_any: [][]const u8 = &.{},
    /// Substring negative match on the current line. If ANY of these
    /// substrings appear on the matched line, the rule does NOT
    /// fire — used to express "fire on @intCast UNLESS the line also
    /// contains std.math.cast or .len bounds-check logic."
    not_contains_any: [][]const u8 = &.{},

    // Window lookahead for line_match (and the variants).
    window_lines: u8 = 0,
    window_contains_any: [][]const u8 = &.{},

    // Enclosing-function constraints.
    require_secret_function: bool = false,
    require_spawn_in_function: bool = false,

    // line_groups: each group is a `[]const []const u8`; the line
    // must contain at least one item from EACH group.
    line_groups: [][][]const u8 = &.{},
};

pub const RuleSet = struct {
    rules: []Rule,
    arena: ?*std.heap.ArenaAllocator,

    /// Free all rules and the backing arena (if owned).
    pub fn deinit(self: *RuleSet) void {
        if (self.arena) |a| {
            const backing = a.child_allocator;
            a.deinit();
            backing.destroy(a);
            self.arena = null;
        }
        self.rules = &.{};
    }
};

// ── Loader: TOML → RuleSet ───────────────────────────────────────

pub const LoadError = error{
    OutOfMemory,
    TomlParse,
    SchemaInvalid,
};

/// Parse `source` (TOML text) into a RuleSet. The RuleSet owns its
/// own arena allocator (sized off `backing`) so callers can free the
/// whole set in one shot via `set.deinit()`.
pub fn loadFromToml(backing: std.mem.Allocator, source: []const u8) LoadError!RuleSet {
    const arena_ptr = backing.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena_ptr.* = std.heap.ArenaAllocator.init(backing);
    errdefer {
        arena_ptr.deinit();
        backing.destroy(arena_ptr);
    }
    const arena = arena_ptr.allocator();

    // Use the backing allocator for the parser so we can free its
    // intermediate state independently of the rule arena.
    var doc = toml.parseToml(backing, source) catch return error.TomlParse;
    defer doc.deinit(backing);

    const rule_value = doc.get("rule") orelse return error.SchemaInvalid;
    if (rule_value != .array) return error.SchemaInvalid;
    const arr = rule_value.array;

    var rules = arena.alloc(Rule, arr.items.items.len) catch return error.OutOfMemory;
    var n: usize = 0;

    for (arr.items.items) |entry| {
        if (entry != .table) return error.SchemaInvalid;
        const t = entry.table;
        rules[n] = parseOneRule(arena, t) catch |e| return e;
        n += 1;
    }

    return .{
        .rules = rules[0..n],
        .arena = arena_ptr,
    };
}

fn parseOneRule(arena: std.mem.Allocator, t: *toml.Table) LoadError!Rule {
    var r = Rule{
        .id = "",
        .summary = "",
        .message = "",
        .covers = "",
        .does_not_cover = "",
        .severity = .high,
        .confidence = .high,
        .gate = true,
        .kind = .line_match,
    };

    r.id = try requireString(arena, t, "id");
    r.summary = try optionalString(arena, t, "summary");
    r.message = try requireString(arena, t, "message");
    r.covers = try optionalString(arena, t, "covers");
    r.does_not_cover = try optionalString(arena, t, "does_not_cover");

    if (t.get("severity")) |v| {
        if (v != .string) return error.SchemaInvalid;
        r.severity = parseSeverity(v.string) orelse return error.SchemaInvalid;
    }
    if (t.get("confidence")) |v| {
        if (v != .string) return error.SchemaInvalid;
        r.confidence = Confidence.fromString(v.string) orelse return error.SchemaInvalid;
    }
    if (t.get("gate")) |v| {
        if (v != .boolean) return error.SchemaInvalid;
        r.gate = v.boolean;
    }
    if (t.get("kind")) |v| {
        if (v != .string) return error.SchemaInvalid;
        r.kind = RuleKind.fromString(v.string) orelse return error.SchemaInvalid;
    }
    if (t.get("window_lines")) |v| {
        if (v != .integer) return error.SchemaInvalid;
        r.window_lines = std.math.cast(u8, v.integer) orelse return error.SchemaInvalid;
    }
    if (t.get("require_secret_function")) |v| {
        if (v != .boolean) return error.SchemaInvalid;
        r.require_secret_function = v.boolean;
    }
    if (t.get("require_spawn_in_function")) |v| {
        if (v != .boolean) return error.SchemaInvalid;
        r.require_spawn_in_function = v.boolean;
    }

    r.contains_any = try optionalStringArray(arena, t, "contains_any");
    r.contains_ident_any = try optionalStringArray(arena, t, "contains_ident_any");
    r.not_contains_ident_any = try optionalStringArray(arena, t, "not_contains_ident_any");
    r.not_contains_any = try optionalStringArray(arena, t, "not_contains_any");
    r.window_contains_any = try optionalStringArray(arena, t, "window_contains_any");
    r.line_groups = try optionalGroupArray(arena, t, "line_groups");

    return r;
}

fn parseSeverity(s: []const u8) ?models.RiskLevel {
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "critical")) return .critical;
    return null;
}

fn requireString(arena: std.mem.Allocator, t: *toml.Table, key: []const u8) LoadError![]const u8 {
    const v = t.get(key) orelse return error.SchemaInvalid;
    if (v != .string) return error.SchemaInvalid;
    return arena.dupe(u8, v.string) catch return error.OutOfMemory;
}

fn optionalString(arena: std.mem.Allocator, t: *toml.Table, key: []const u8) LoadError![]const u8 {
    const v = t.get(key) orelse return "";
    if (v != .string) return error.SchemaInvalid;
    return arena.dupe(u8, v.string) catch return error.OutOfMemory;
}

fn optionalStringArray(arena: std.mem.Allocator, t: *toml.Table, key: []const u8) LoadError![][]const u8 {
    const v = t.get(key) orelse return &.{};
    if (v != .array) return error.SchemaInvalid;
    const items = v.array.items.items;
    var out = arena.alloc([]const u8, items.len) catch return error.OutOfMemory;
    for (items, 0..) |it, i| {
        if (it != .string) return error.SchemaInvalid;
        out[i] = arena.dupe(u8, it.string) catch return error.OutOfMemory;
    }
    return out;
}

fn optionalGroupArray(arena: std.mem.Allocator, t: *toml.Table, key: []const u8) LoadError![][][]const u8 {
    const v = t.get(key) orelse return &.{};
    if (v != .array) return error.SchemaInvalid;
    const groups = v.array.items.items;
    var out = arena.alloc([][]const u8, groups.len) catch return error.OutOfMemory;
    for (groups, 0..) |g, gi| {
        if (g != .array) return error.SchemaInvalid;
        const items = g.array.items.items;
        var inner = arena.alloc([]const u8, items.len) catch return error.OutOfMemory;
        for (items, 0..) |it, j| {
            if (it != .string) return error.SchemaInvalid;
            inner[j] = arena.dupe(u8, it.string) catch return error.OutOfMemory;
        }
        out[gi] = inner;
    }
    return out;
}

// ── Engine: scan a single line against a loaded ruleset ──────────

pub const ScanContext = struct {
    full_source: []const u8,
    report: *models.FileReport,
    /// Lookup of secret-named enclosing functions / spawn bodies.
    /// `null` means "not yet computed"; the engine fills these in
    /// lazily so unused rules don't pay for the analysis.
    enclosing_fn: ?*const models.FunctionInfo = null,
    enclosing_fn_secret_known: bool = false,
    enclosing_fn_is_secret: bool = false,
    enclosing_fn_spawn_known: bool = false,
    enclosing_fn_has_spawn: bool = false,
};

/// Match `rule` against `line`. Returns true if the rule fires.
/// Does NOT append the finding — the caller does that so it can
/// honor zig-lens-ignore directives.
pub fn ruleMatches(
    rule: *const Rule,
    ctx: *ScanContext,
    line: []const u8,
    line_number: u32,
    line_offset: usize,
) bool {
    return switch (rule.kind) {
        .line_match => lineFilterFires(rule, ctx.full_source, line, line_offset),
        .enclosing_fn => blk: {
            if (!lineFilterFires(rule, ctx.full_source, line, line_offset)) break :blk false;
            if (rule.require_secret_function) {
                resolveEnclosingFn(ctx, line_number);
                if (!ctx.enclosing_fn_is_secret) break :blk false;
            }
            break :blk true;
        },
        .enclosing_fn_with_body => blk: {
            if (!lineFilterFires(rule, ctx.full_source, line, line_offset)) break :blk false;
            if (rule.require_spawn_in_function) {
                resolveEnclosingFn(ctx, line_number);
                if (!ctx.enclosing_fn_has_spawn) break :blk false;
            }
            break :blk true;
        },
        .line_groups => groupsAllPresent(rule, line),
    };
}

fn lineFilterFires(rule: *const Rule, full_source: []const u8, line: []const u8, line_offset: usize) bool {
    // Exclude conditions first: if any "must not contain" identifier
    // shows up, the rule does not fire.
    for (rule.not_contains_ident_any) |excl| {
        if (containsIdent(line, excl)) return false;
    }
    // Substring negative match. Used for cases where the excluded
    // pattern is not a single identifier (e.g. "std.math.cast" or
    // ".len").
    for (rule.not_contains_any) |excl| {
        if (std.mem.indexOf(u8, line, excl) != null) return false;
    }

    // OR across contains_any (substring) + contains_ident_any (token).
    // The rule needs at least one match across the union of those
    // two arrays. If both arrays are empty the line filter is
    // considered open (window-only matching).
    var line_matched = false;
    if (rule.contains_any.len == 0 and rule.contains_ident_any.len == 0) {
        line_matched = true;
    } else {
        for (rule.contains_any) |needle| {
            if (std.mem.indexOf(u8, line, needle) != null) {
                line_matched = true;
                break;
            }
        }
        if (!line_matched) {
            for (rule.contains_ident_any) |ident| {
                if (containsIdent(line, ident)) {
                    line_matched = true;
                    break;
                }
            }
        }
    }
    if (!line_matched) return false;

    // Window lookahead (used by JSON-IN-FMT for multi-line format
    // strings). If `window_contains_any` is empty the window is a
    // no-op and the rule already matched.
    if (rule.window_contains_any.len == 0) return true;

    if (anyContainsAny(line, rule.window_contains_any)) return true;

    if (rule.window_lines == 0) return false;
    var pos = line_offset + line.len;
    var lines_checked: u8 = 0;
    while (pos < full_source.len and lines_checked < rule.window_lines) : (lines_checked += 1) {
        if (pos < full_source.len and full_source[pos] == '\n') pos += 1;
        const end = std.mem.indexOfScalarPos(u8, full_source, pos, '\n') orelse full_source.len;
        if (anyContainsAny(full_source[pos..end], rule.window_contains_any)) return true;
        pos = end;
    }
    return false;
}

fn anyContainsAny(slice: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, slice, n) != null) return true;
    }
    return false;
}

fn groupsAllPresent(rule: *const Rule, line: []const u8) bool {
    if (rule.line_groups.len == 0) return false;
    for (rule.line_groups) |group| {
        var hit = false;
        for (group) |needle| {
            if (std.mem.indexOf(u8, line, needle) != null) {
                hit = true;
                break;
            }
        }
        if (!hit) return false;
    }
    return true;
}

// ── Identifier-token matching (shared with hand-rolled scanner) ──

pub fn containsIdent(line: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_start, name)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(line[pos - 1]);
        const after = pos + name.len;
        const after_ok = after >= line.len or !isIdentChar(line[after]);
        if (before_ok and after_ok) return true;
        search_start = pos + 1;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ── Enclosing-function resolution ─────────────────────────────────

fn resolveEnclosingFn(ctx: *ScanContext, line_number: u32) void {
    if (ctx.enclosing_fn == null) {
        ctx.enclosing_fn = enclosingFunctionAt(ctx.report, line_number);
    }
    if (!ctx.enclosing_fn_secret_known) {
        ctx.enclosing_fn_secret_known = true;
        if (ctx.enclosing_fn) |fn_info| {
            ctx.enclosing_fn_is_secret = functionLooksSecretRelated(fn_info);
        }
    }
    if (!ctx.enclosing_fn_spawn_known) {
        ctx.enclosing_fn_spawn_known = true;
        if (ctx.enclosing_fn) |fn_info| {
            ctx.enclosing_fn_has_spawn = functionBodyMentionsSpawn(ctx.full_source, fn_info);
        }
    }
}

fn enclosingFunctionAt(report: *const models.FileReport, line: u32) ?*const models.FunctionInfo {
    var best: ?*const models.FunctionInfo = null;
    for (report.functions.items) |*f| {
        if (f.line <= line and line <= f.end_line) {
            if (best == null or f.line > best.?.line) best = f;
        }
    }
    return best;
}

fn functionBodyRange(source: []const u8, fn_info: *const models.FunctionInfo) []const u8 {
    if (fn_info.line == 0) return source[0..0];
    var line: u32 = 1;
    var start: usize = source.len;
    var end: usize = source.len;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (line == fn_info.line and start == source.len) start = i;
        if (source[i] == '\n') {
            line += 1;
            if (line > fn_info.end_line and end == source.len) {
                end = i;
                break;
            }
        }
    }
    return source[start..end];
}

fn functionBodyMentionsSpawn(source: []const u8, fn_info: *const models.FunctionInfo) bool {
    const body = functionBodyRange(source, fn_info);
    if (std.mem.indexOf(u8, body, "process.Child") != null) return true;
    if (std.mem.indexOf(u8, body, "process.run") != null) return true;
    if (std.mem.indexOf(u8, body, "Child.init") != null) return true;
    if (std.mem.indexOf(u8, body, "Child.spawn") != null) return true;
    if (containsIdent(body, "execve")) return true;
    if (containsIdent(body, "execvp")) return true;
    return false;
}

// ── Secret-named identifier detection (shared) ───────────────────

const secret_word_set = [_][]const u8{
    "signature",
    "signatures",
    "hmac",
    "password",
    "passwd",
    "secret",
    "nonce",
    "apikey",
};

const secret_pair_set = [_][2][]const u8{
    .{ "api", "key" },
    .{ "session", "token" },
    .{ "auth", "token" },
    .{ "bearer", "token" },
    .{ "csrf", "token" },
    .{ "access", "token" },
    .{ "refresh", "token" },
    .{ "verify", "token" },
    .{ "id", "token" },
};

const max_subtokens: usize = 16;

fn splitIdentSubtokens(ident: []const u8, out: *[max_subtokens][]const u8) []const []const u8 {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < ident.len) : (i += 1) {
        const c = ident[i];
        if (c == '_') {
            if (i > start and n < out.len) {
                out[n] = ident[start..i];
                n += 1;
            }
            start = i + 1;
        } else if (i > start and std.ascii.isUpper(c) and std.ascii.isLower(ident[i - 1])) {
            if (n < out.len) {
                out[n] = ident[start..i];
                n += 1;
            }
            start = i;
        } else if (i > start + 1 and std.ascii.isUpper(c) and std.ascii.isUpper(ident[i - 1]) and i + 1 < ident.len and std.ascii.isLower(ident[i + 1])) {
            if (n < out.len) {
                out[n] = ident[start..i];
                n += 1;
            }
            start = i;
        }
    }
    if (ident.len > start and n < out.len) {
        out[n] = ident[start..ident.len];
        n += 1;
    }
    return out[0..n];
}

fn subTokenIsSecret(sub: []const u8) bool {
    for (secret_word_set) |w| {
        if (std.ascii.eqlIgnoreCase(sub, w)) return true;
    }
    return false;
}

fn pairIsSecret(a: []const u8, b: []const u8) bool {
    for (secret_pair_set) |p| {
        if (std.ascii.eqlIgnoreCase(a, p[0]) and std.ascii.eqlIgnoreCase(b, p[1])) return true;
    }
    return false;
}

fn identNamesSecret(ident: []const u8) bool {
    var buf: [max_subtokens][]const u8 = undefined;
    const toks = splitIdentSubtokens(ident, &buf);
    for (toks) |t| {
        if (subTokenIsSecret(t)) return true;
    }
    var i: usize = 1;
    while (i < toks.len) : (i += 1) {
        if (pairIsSecret(toks[i - 1], toks[i])) return true;
    }
    return false;
}

fn paramsNameSecret(params: []const u8) bool {
    var start: ?usize = null;
    var i: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        const c = if (at_end) 0 else params[i];
        const is_ident = !at_end and isIdentChar(c);
        if (is_ident and start == null) start = i;
        if (!is_ident and start != null) {
            const ident = params[start.?..i];
            if (identNamesSecret(ident)) return true;
            start = null;
        }
    }
    return false;
}

fn functionLooksSecretRelated(fn_info: *const models.FunctionInfo) bool {
    if (identNamesSecret(fn_info.name)) return true;
    if (paramsNameSecret(fn_info.params)) return true;
    return false;
}

// ── Tests ────────────────────────────────────────────────────────

test "Confidence fromString roundtrip" {
    try std.testing.expectEqual(Confidence.high, Confidence.fromString("high").?);
    try std.testing.expectEqual(Confidence.medium, Confidence.fromString("medium").?);
    try std.testing.expectEqual(Confidence.low, Confidence.fromString("low").?);
    try std.testing.expect(Confidence.fromString("bogus") == null);
}

test "RuleKind fromString" {
    try std.testing.expectEqual(RuleKind.line_match, RuleKind.fromString("line_match").?);
    try std.testing.expectEqual(RuleKind.enclosing_fn, RuleKind.fromString("enclosing_fn").?);
    try std.testing.expectEqual(RuleKind.enclosing_fn_with_body, RuleKind.fromString("enclosing_fn_with_body").?);
    try std.testing.expectEqual(RuleKind.line_groups, RuleKind.fromString("line_groups").?);
    try std.testing.expect(RuleKind.fromString("bogus") == null);
}

test "loadFromToml: minimal one-rule document" {
    const source =
        \\[[rule]]
        \\id = "DEMO"
        \\summary = "demo"
        \\message = "demo finding"
        \\severity = "high"
        \\confidence = "high"
        \\gate = true
        \\kind = "line_match"
        \\contains_any = ["unsafe_thing"]
    ;
    var set = try loadFromToml(std.testing.allocator, source);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.rules.len);
    try std.testing.expectEqualStrings("DEMO", set.rules[0].id);
    try std.testing.expectEqual(Confidence.high, set.rules[0].confidence);
    try std.testing.expectEqual(true, set.rules[0].gate);
    try std.testing.expectEqual(RuleKind.line_match, set.rules[0].kind);
    try std.testing.expectEqual(@as(usize, 1), set.rules[0].contains_any.len);
    try std.testing.expectEqualStrings("unsafe_thing", set.rules[0].contains_any[0]);
}

test "loadFromToml: medium confidence parses, gate respected" {
    const source =
        \\[[rule]]
        \\id = "ADVISORY"
        \\message = "test advisory"
        \\severity = "medium"
        \\confidence = "medium"
        \\gate = false
        \\kind = "line_match"
        \\contains_any = ["spaghetti"]
    ;
    var set = try loadFromToml(std.testing.allocator, source);
    defer set.deinit();
    try std.testing.expectEqual(Confidence.medium, set.rules[0].confidence);
    try std.testing.expectEqual(false, set.rules[0].gate);
}

test "ruleMatches: line_match with contains_any" {
    var report = models.FileReport.init();
    defer report.functions.deinit(std.testing.allocator);
    defer report.security_findings.deinit(std.testing.allocator);
    defer report.structs.deinit(std.testing.allocator);
    defer report.enums.deinit(std.testing.allocator);
    defer report.unions.deinit(std.testing.allocator);
    defer report.constants.deinit(std.testing.allocator);
    defer report.tests.deinit(std.testing.allocator);
    defer report.imports.deinit(std.testing.allocator);
    defer report.unsafe_ops.deinit(std.testing.allocator);

    var contains = [_][]const u8{"verboten"};
    const rule = Rule{
        .id = "T",
        .summary = "",
        .message = "",
        .covers = "",
        .does_not_cover = "",
        .severity = .high,
        .confidence = .high,
        .gate = true,
        .kind = .line_match,
        .contains_any = &contains,
    };
    const source = "let x = verboten;\n";
    var ctx = ScanContext{ .full_source = source, .report = &report };
    try std.testing.expect(ruleMatches(&rule, &ctx, source[0..source.len - 1], 1, 0));
}

test "ruleMatches: line_groups requires all groups to hit" {
    var report = models.FileReport.init();
    defer report.functions.deinit(std.testing.allocator);
    defer report.security_findings.deinit(std.testing.allocator);
    defer report.structs.deinit(std.testing.allocator);
    defer report.enums.deinit(std.testing.allocator);
    defer report.unions.deinit(std.testing.allocator);
    defer report.constants.deinit(std.testing.allocator);
    defer report.tests.deinit(std.testing.allocator);
    defer report.imports.deinit(std.testing.allocator);
    defer report.unsafe_ops.deinit(std.testing.allocator);

    var g0 = [_][]const u8{ "\"sh\"", "\"bash\"" };
    var g1 = [_][]const u8{"\"-c\""};
    var groups = [_][]const []const u8{ &g0, &g1 };
    const rule = Rule{
        .id = "T",
        .summary = "",
        .message = "",
        .covers = "",
        .does_not_cover = "",
        .severity = .critical,
        .confidence = .high,
        .gate = true,
        .kind = .line_groups,
        .line_groups = @ptrCast(&groups),
    };

    const hit_line = ".{ \"sh\", \"-c\", cmd }";
    const miss_line_no_dashc = ".{ \"sh\", cmd }";
    const miss_line_no_shell = ".{ \"-c\", cmd }";

    var ctx = ScanContext{ .full_source = hit_line, .report = &report };
    try std.testing.expect(ruleMatches(&rule, &ctx, hit_line, 1, 0));
    try std.testing.expect(!ruleMatches(&rule, &ctx, miss_line_no_dashc, 1, 0));
    try std.testing.expect(!ruleMatches(&rule, &ctx, miss_line_no_shell, 1, 0));
}
