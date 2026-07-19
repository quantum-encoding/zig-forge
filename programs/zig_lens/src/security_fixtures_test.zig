// External-anchored security-rule fixture corpus.
//
// zig_lens is the repo's own enforcement scanner (zig-forge/CLAUDE.md
// "High-signal anti-patterns"). The 100+ inline unit tests assert the
// analyzers against snippets the authors wrote — internal
// self-consistency. Per the repo's four-point golden rule (§1), that is
// exactly the trap that let zig_base58 ship a wrong checksum for two
// months: every test passed because every test was self-referential.
//
// This module is the external-vector layer for the scanner. Each rule
// class is pinned by TWO fixture files under `src/security_fixtures/`:
//
//   positive/<class>.fixture — a minimized copy of a REAL vulnerable
//       shape drawn from the campaign zig-forge/CLAUDE.md documents
//       (the Stratum buildJson JSON-IN-FMT, the vertex.zig /bin/sh -c
//       SHELL-CHILD, the oidc.zig nonce EQL-FOR-SECRETS, …). The rule
//       MUST fire.
//   negative/<class>.fixture — the CORRECTIVE shape CLAUDE.md
//       prescribes (std.json.Stringify, argv-mode Child.init,
//       std.crypto.timing_safe.eql, …). The rule MUST NOT fire.
//
// The inputs (real bug shapes) and the expected verdicts come from the
// anti-pattern catalog in CLAUDE.md, authored independently of the
// scanner code — the external anchor the golden rule asks for. If a
// rule silently regresses (stops firing on a real bug, or starts firing
// on the corrective shape), one of these tests goes red.
//
// The fixtures use the `.fixture` extension ON PURPOSE: the scanner's
// language detection (scanner.zig `detectLanguage`) only recognizes
// real source extensions, so `zig-lens programs/` never scans them and
// the known-positive vulnerable shapes cannot pollute the repo-wide
// --strict gate. The corpus is loaded here via @embedFile and driven
// through the exact same pipeline main.zig runs on a real Zig file:
// parse → structure.analyze → security_patterns.analyze.

const std = @import("std");
const models = @import("models.zig");
const structure = @import("analyzers/structure.zig");
const security_patterns = @import("analyzers/security_patterns.zig");

/// Run a fixture through the full Zig analysis pipeline. Everything is
/// allocated on `arena` so the caller frees the whole run in one shot.
fn analyzeFixture(arena: std.mem.Allocator, source: [:0]const u8) !models.FileReport {
    var report = models.FileReport.init();
    report.language = .zig;

    var ast = try std.zig.Ast.parse(arena, source, .zig);
    // Populate report.functions so the enclosing-fn rules
    // (EQL-FOR-SECRETS, SHELL-CHILD shape (a)) can resolve scope
    // exactly as they do on a real file.
    try structure.analyze(arena, &ast, &report);
    try security_patterns.analyze(arena, source, &report);
    return report;
}

fn findingCount(report: *const models.FileReport, rule_id: []const u8) usize {
    var n: usize = 0;
    for (report.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, rule_id)) n += 1;
    }
    return n;
}

/// Assert the rule fired at least once as a GATING finding
/// (confidence=high AND gate=true — the combination --strict acts on).
fn expectGating(report: *const models.FileReport, rule_id: []const u8) !void {
    var saw = false;
    for (report.security_findings.items) |f| {
        if (!std.mem.eql(u8, f.rule_id, rule_id)) continue;
        try std.testing.expectEqual(models.FindingConfidence.high, f.confidence);
        try std.testing.expectEqual(true, f.gate);
        saw = true;
    }
    if (!saw) {
        std.debug.print("expected gating finding '{s}' but none fired\n", .{rule_id});
        return error.RuleDidNotFire;
    }
}

/// Assert the rule fired at least once as an ADVISORY finding
/// (gate=false — surfaces as a WARN, never contributes to --strict).
fn expectAdvisory(report: *const models.FileReport, rule_id: []const u8) !void {
    var saw = false;
    for (report.security_findings.items) |f| {
        if (!std.mem.eql(u8, f.rule_id, rule_id)) continue;
        try std.testing.expectEqual(false, f.gate);
        saw = true;
    }
    if (!saw) {
        std.debug.print("expected advisory finding '{s}' but none fired\n", .{rule_id});
        return error.RuleDidNotFire;
    }
}

/// Assert the rule did NOT fire anywhere in the report.
fn expectAbsent(report: *const models.FileReport, rule_id: []const u8) !void {
    const n = findingCount(report, rule_id);
    if (n != 0) {
        std.debug.print("expected no '{s}' finding but {d} fired\n", .{ rule_id, n });
        return error.RuleFiredUnexpectedly;
    }
}

const Case = struct { arena: std.heap.ArenaAllocator };

fn open() !Case {
    try security_patterns.loadDefault(std.testing.allocator);
    return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
}

fn close(c: *Case) void {
    c.arena.deinit();
    security_patterns.unload();
}

// ── Positive fixtures: the real bug shape MUST fire ──────────────────

test "fixture/positive JSON-IN-FMT fires (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/json_in_fmt.fixture"));
    try expectGating(&report, "JSON-IN-FMT");
}

test "fixture/positive MBEDTLS-VERIFY-NONE fires (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/mbedtls_verify_none.fixture"));
    try expectGating(&report, "MBEDTLS-VERIFY-NONE");
}

test "fixture/positive EQL-FOR-SECRETS fires in secret-named fn (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/eql_for_secrets.fixture"));
    try expectGating(&report, "EQL-FOR-SECRETS");
}

test "fixture/positive SHELL-CHILD fires on /bin/sh + spawn (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/shell_child_bin_sh.fixture"));
    try expectGating(&report, "SHELL-CHILD");
}

test "fixture/positive SHELL-CHILD fires on sh -c argv pair (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/shell_child_sh_dash_c.fixture"));
    try expectGating(&report, "SHELL-CHILD");
}

test "fixture/positive SHELL-CHILD fires on libc system() (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/shell_child_libc_system.fixture"));
    try expectGating(&report, "SHELL-CHILD");
}

test "fixture/positive CATCH-UNREACHABLE fires (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/catch_unreachable.fixture"));
    try expectGating(&report, "CATCH-UNREACHABLE");
}

test "fixture/positive ASSUME-CAPACITY fires (gating)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/assume_capacity.fixture"));
    try expectGating(&report, "ASSUME-CAPACITY");
}

test "fixture/positive NAKED-POINTER-CAST fires (advisory)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/naked_pointer_cast.fixture"));
    try expectAdvisory(&report, "NAKED-POINTER-CAST");
}

test "fixture/positive FLOAT-OBSESSION fires (advisory)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/float_obsession.fixture"));
    try expectAdvisory(&report, "FLOAT-OBSESSION");
}

test "fixture/positive BLIND-CAST fires (advisory)" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/positive/blind_cast.fixture"));
    try expectAdvisory(&report, "BLIND-CAST");
}

// ── Negative fixtures: the corrective shape MUST NOT fire ────────────

test "fixture/negative JSON-IN-FMT clean on Stringify" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/json_in_fmt.fixture"));
    try expectAbsent(&report, "JSON-IN-FMT");
}

test "fixture/negative MBEDTLS-VERIFY-NONE clean on VERIFY_REQUIRED" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/mbedtls_verify_none.fixture"));
    try expectAbsent(&report, "MBEDTLS-VERIFY-NONE");
}

test "fixture/negative EQL-FOR-SECRETS clean on timing_safe + non-secret fn" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/eql_for_secrets.fixture"));
    try expectAbsent(&report, "EQL-FOR-SECRETS");
}

test "fixture/negative SHELL-CHILD clean on argv-mode spawn" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/shell_child_argv.fixture"));
    try expectAbsent(&report, "SHELL-CHILD");
}

test "fixture/negative CATCH-UNREACHABLE clean on catch return" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/catch_unreachable.fixture"));
    try expectAbsent(&report, "CATCH-UNREACHABLE");
}

test "fixture/negative ASSUME-CAPACITY clean on allocating append" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/assume_capacity.fixture"));
    try expectAbsent(&report, "ASSUME-CAPACITY");
}

test "fixture/negative NAKED-POINTER-CAST clean on plain reference" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/naked_pointer_cast.fixture"));
    try expectAbsent(&report, "NAKED-POINTER-CAST");
}

test "fixture/negative FLOAT-OBSESSION clean on non-tell float fields" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/float_obsession.fixture"));
    try expectAbsent(&report, "FLOAT-OBSESSION");
}

test "fixture/negative BLIND-CAST clean on std.math.cast" {
    var c = try open();
    defer close(&c);
    var report = try analyzeFixture(c.arena.allocator(), @embedFile("security_fixtures/negative/blind_cast.fixture"));
    try expectAbsent(&report, "BLIND-CAST");
}
