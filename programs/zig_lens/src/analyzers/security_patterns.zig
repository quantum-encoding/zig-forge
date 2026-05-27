// Security anti-pattern scanner — data-driven via TOML ruleset.
//
// Historically the rules were hardcoded in this file. They now live
// in `default_rules.toml` (embedded into the binary via @embedFile)
// and load through `analyzers/rule_engine.zig`. The `--rules <path>`
// CLI flag passes a caller-supplied TOML document instead, letting
// audit teams ship organization-specific rulesets without
// recompiling.
//
// This file's responsibilities now:
//   1. Maintain the global "active rule set" used by analyze().
//   2. Provide `loadDefault()` / `loadCustom()` for main.zig.
//   3. Run the per-line scan against the active rule set, honoring
//      the inline `// zig-lens-ignore:` suppression directive.
//   4. Expose `rule_coverage` (as `[]const RuleCoverage`) so the
//      terminal + JSON outputs can render coverage notes for every
//      rule whether or not it fired.
//
// Inline suppression: when human review has confirmed a finding is
// a false positive, the line (or the line above) can carry
//
//   // zig-lens-ignore: <RULE-ID> <reason text>
//
// The reason is REQUIRED — undocumented suppressions are silent bug
// nests. CI can grep `zig-lens-ignore:` to enumerate every active
// waiver and re-review periodically. Suppressions are rule-id-
// specific, so a future-added rule that catches a real bug on the
// same line still surfaces.

const std = @import("std");
const models = @import("../models.zig");
const engine = @import("rule_engine.zig");

// ── Embedded default ruleset ──────────────────────────────────────

pub const default_rules_toml = @embedFile("default_rules.toml");

// ── Active ruleset (process-global) ───────────────────────────────
//
// Cached so analyze() doesn't re-parse on every file. main.zig calls
// `loadDefault()` once at startup (or `loadCustom()` for --rules).
// Tests that want a custom set call setForTesting().

var active_set: ?engine.RuleSet = null;
var active_coverage: []RuleCoverage = &[_]RuleCoverage{};
var active_arena: ?*std.heap.ArenaAllocator = null;

pub fn loadDefault(allocator: std.mem.Allocator) !void {
    try setFromToml(allocator, default_rules_toml);
}

pub fn loadCustom(allocator: std.mem.Allocator, toml_source: []const u8) !void {
    try setFromToml(allocator, toml_source);
}

fn setFromToml(allocator: std.mem.Allocator, toml_source: []const u8) !void {
    // Free any previous set.
    if (active_set) |*s| s.deinit();
    active_set = null;
    if (active_arena) |a| {
        const backing = a.child_allocator;
        a.deinit();
        backing.destroy(a);
    }
    active_arena = null;
    active_coverage = &[_]RuleCoverage{};

    var set = try engine.loadFromToml(allocator, toml_source);
    errdefer set.deinit();

    // Build a coverage table aligned with the loaded rules. We keep
    // one entry per UNIQUE rule id (rules can share an id for
    // complementary detection shapes — e.g. SHELL-CHILD a + b — and
    // the operator only wants to see one coverage block per id).
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_ptr.deinit();
        allocator.destroy(arena_ptr);
    }
    const arena = arena_ptr.allocator();

    var unique: std.ArrayListUnmanaged(RuleCoverage) = .empty;
    outer: for (set.rules) |*r| {
        for (unique.items) |existing| {
            if (std.mem.eql(u8, existing.id, r.id)) continue :outer;
        }
        try unique.append(arena, .{
            .id = r.id,
            .summary = r.summary,
            .covers = r.covers,
            .does_not_cover = r.does_not_cover,
            .confidence = r.confidence.toString(),
            .gate = r.gate,
        });
    }

    active_set = set;
    active_arena = arena_ptr;
    active_coverage = unique.toOwnedSlice(arena) catch &[_]RuleCoverage{};
}

/// Replace the active ruleset for tests. Caller supplies a slice that
/// outlives the test. NO arena is owned in this case.
pub fn setForTesting(rules: []engine.Rule) void {
    // Reset any prior loader-owned state.
    if (active_set) |*s| s.deinit();
    if (active_arena) |a| {
        const backing = a.child_allocator;
        a.deinit();
        backing.destroy(a);
    }
    active_arena = null;
    active_coverage = &[_]RuleCoverage{};
    active_set = .{ .rules = rules, .arena = null };
}

// ── Public coverage table ────────────────────────────────────────
//
// Same shape as the previous hardcoded table. Now populated from the
// loaded rules so the terminal + JSON outputs reflect whichever
// ruleset is actually in use.

pub const RuleCoverage = struct {
    id: []const u8,
    summary: []const u8,
    covers: []const u8,
    does_not_cover: []const u8,
    confidence: []const u8,
    gate: bool,
};

pub fn ruleCoverage() []const RuleCoverage {
    return active_coverage;
}

pub fn coverageFor(id: []const u8) ?*const RuleCoverage {
    for (active_coverage) |*r| {
        if (std.mem.eql(u8, r.id, id)) return r;
    }
    return null;
}

// ── Scanner entry point ──────────────────────────────────────────

/// Run the security-pattern scan against `source` and append findings
/// to `report.security_findings`. The scanner consults
/// `report.functions` (already populated by the structure analyzer
/// upstream) to scope enclosing-fn rules.
///
/// If no ruleset has been loaded, this is a no-op — callers must
/// invoke `loadDefault()` or `loadCustom()` before scanning.
pub fn analyze(
    allocator: std.mem.Allocator,
    source: []const u8,
    report: *models.FileReport,
) !void {
    if (source.len == 0) return;
    const set = active_set orelse return;
    if (set.rules.len == 0) return;

    var ctx = engine.ScanContext{
        .full_source = source,
        .report = report,
    };

    var line_start: usize = 0;
    var line_number: u32 = 1;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            const line_end = i;
            const line = source[line_start..line_end];

            // Reset per-line context state. The enclosing-function
            // cache is line-scoped: the same line can match
            // multiple rules, but the enclosing fn is only looked
            // up once.
            ctx.enclosing_fn = null;
            ctx.enclosing_fn_secret_known = false;
            ctx.enclosing_fn_is_secret = false;
            ctx.enclosing_fn_spawn_known = false;
            ctx.enclosing_fn_has_spawn = false;

            try scanLine(allocator, &ctx, set.rules, line, line_number, line_start);

            line_number += 1;
            line_start = i + 1;
        }
    }
}

fn scanLine(
    allocator: std.mem.Allocator,
    ctx: *engine.ScanContext,
    rules: []const engine.Rule,
    line: []const u8,
    line_number: u32,
    line_offset: usize,
) !void {
    const t = std.mem.trim(u8, line, " \t\r");
    // Comment lines (Zig //, Python/shell #) carry pattern text as
    // documentation, not as code. Skip them.
    if (std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#")) return;
    // Zig multi-line string continuations (`\\…`) carry test
    // fixtures / golden outputs, not active code. Skip.
    if (std.mem.startsWith(u8, t, "\\\\")) return;

    for (rules) |*rule| {
        if (engine.ruleMatches(rule, ctx, line, line_number, line_offset)) {
            try appendFinding(allocator, rule, ctx, line, line_number, line_offset);
        }
    }
}

fn appendFinding(
    allocator: std.mem.Allocator,
    rule: *const engine.Rule,
    ctx: *engine.ScanContext,
    line: []const u8,
    line_number: u32,
    line_offset: usize,
) !void {
    if (hasIgnoreDirective(ctx.full_source, line_offset, line, rule.id)) return;

    const snip = try snippetOf(allocator, line);
    const conf: models.FindingConfidence = switch (rule.confidence) {
        .high => .high,
        .medium => .medium,
        .low => .low,
    };
    try ctx.report.security_findings.append(allocator, .{
        .rule_id = rule.id,
        .line = line_number,
        .severity = rule.severity,
        .confidence = conf,
        .gate = rule.gate,
        .message = try allocator.dupe(u8, rule.message),
        .snippet = snip,
    });
}

const max_snippet_bytes: usize = 200;

fn snippetOf(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    const n = @min(t.len, max_snippet_bytes);
    return try allocator.dupe(u8, t[0..n]);
}

// ── Inline suppression directive ─────────────────────────────────

const ignore_tag: []const u8 = "zig-lens-ignore:";

fn hasIgnoreDirective(
    full_source: []const u8,
    line_offset: usize,
    line: []const u8,
    rule_id: []const u8,
) bool {
    if (lineIgnoresRule(line, rule_id)) return true;

    if (line_offset == 0) return false;
    var prev_end = line_offset;
    if (full_source[prev_end - 1] == '\n') prev_end -= 1;
    if (prev_end == 0) return false;
    var prev_start = prev_end;
    while (prev_start > 0 and full_source[prev_start - 1] != '\n') prev_start -= 1;
    return lineIgnoresRule(full_source[prev_start..prev_end], rule_id);
}

fn lineIgnoresRule(line: []const u8, rule_id: []const u8) bool {
    const at = std.mem.indexOf(u8, line, ignore_tag) orelse return false;
    var rest = std.mem.trimStart(u8, line[at + ignore_tag.len ..], " \t");
    if (!std.mem.startsWith(u8, rest, rule_id)) return false;
    rest = rest[rule_id.len..];
    if (rest.len == 0) return false;
    const first = rest[0];
    if (first != ' ' and first != '\t' and first != '-' and first != ':') return false;
    var reason_start: usize = 0;
    while (reason_start < rest.len) {
        const c = rest[reason_start];
        if (c == ' ' or c == '\t' or c == '-' or c == ':') {
            reason_start += 1;
            continue;
        }
        if (reason_start + 2 < rest.len and c == 0xE2 and rest[reason_start + 1] == 0x80 and rest[reason_start + 2] == 0x94) {
            reason_start += 3;
            continue;
        }
        break;
    }
    const reason = std.mem.trimEnd(u8, rest[reason_start..], " \t\r\n");
    return reason.len >= 4;
}

// ── Tests ────────────────────────────────────────────────────────

test "loadDefault: parses embedded ruleset, 5 entries, 4 unique ids" {
    try loadDefault(std.testing.allocator);
    defer {
        if (active_set) |*s| s.deinit();
        active_set = null;
        if (active_arena) |a| {
            const backing = a.child_allocator;
            a.deinit();
            backing.destroy(a);
        }
        active_arena = null;
        active_coverage = &[_]RuleCoverage{};
    }
    try std.testing.expectEqual(@as(usize, 5), active_set.?.rules.len);
    try std.testing.expectEqual(@as(usize, 4), active_coverage.len);
}

test "analyze: default rules still flag JSON-IN-FMT" {
    try loadDefault(std.testing.allocator);
    defer {
        if (active_set) |*s| s.deinit();
        active_set = null;
        if (active_arena) |a| {
            const backing = a.child_allocator;
            a.deinit();
            backing.destroy(a);
        }
        active_arena = null;
        active_coverage = &[_]RuleCoverage{};
    }

    var report = models.FileReport.init();
    defer {
        for (report.security_findings.items) |f| {
            std.testing.allocator.free(f.message);
            std.testing.allocator.free(f.snippet);
        }
        report.security_findings.deinit(std.testing.allocator);
        report.functions.deinit(std.testing.allocator);
        report.structs.deinit(std.testing.allocator);
        report.enums.deinit(std.testing.allocator);
        report.unions.deinit(std.testing.allocator);
        report.constants.deinit(std.testing.allocator);
        report.tests.deinit(std.testing.allocator);
        report.imports.deinit(std.testing.allocator);
        report.unsafe_ops.deinit(std.testing.allocator);
    }

    const source =
        \\const x = std.fmt.allocPrint(a, "{{\"key\":\"{s}\"}}", .{v});
    ;
    try analyze(std.testing.allocator, source, &report);
    try std.testing.expect(report.security_findings.items.len >= 1);
    var saw_json = false;
    for (report.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "JSON-IN-FMT")) saw_json = true;
        try std.testing.expectEqual(true, f.gate);
        try std.testing.expectEqual(models.FindingConfidence.high, f.confidence);
    }
    try std.testing.expect(saw_json);
}

test "inline ignore directive suppresses finding" {
    try loadDefault(std.testing.allocator);
    defer {
        if (active_set) |*s| s.deinit();
        active_set = null;
        if (active_arena) |a| {
            const backing = a.child_allocator;
            a.deinit();
            backing.destroy(a);
        }
        active_arena = null;
        active_coverage = &[_]RuleCoverage{};
    }

    var report = models.FileReport.init();
    defer {
        for (report.security_findings.items) |f| {
            std.testing.allocator.free(f.message);
            std.testing.allocator.free(f.snippet);
        }
        report.security_findings.deinit(std.testing.allocator);
        report.functions.deinit(std.testing.allocator);
        report.structs.deinit(std.testing.allocator);
        report.enums.deinit(std.testing.allocator);
        report.unions.deinit(std.testing.allocator);
        report.constants.deinit(std.testing.allocator);
        report.tests.deinit(std.testing.allocator);
        report.imports.deinit(std.testing.allocator);
        report.unsafe_ops.deinit(std.testing.allocator);
    }

    const source =
        \\// zig-lens-ignore: JSON-IN-FMT this is a documented false positive
        \\const x = std.fmt.allocPrint(a, "{{\"key\":\"{s}\"}}", .{v});
    ;
    try analyze(std.testing.allocator, source, &report);
    try std.testing.expectEqual(@as(usize, 0), report.security_findings.items.len);
}
