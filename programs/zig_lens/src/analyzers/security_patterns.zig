// Security anti-pattern scanner.
//
// This analyzer flags specific, high-confidence anti-patterns whose
// presence in source code is almost always a bug. Each rule has a
// stable id so CI / pre-commit hooks can grep for it.
//
// Rules:
//
//   JSON-IN-FMT       — `std.fmt.allocPrint` / `bufPrint` with a JSON-
//                       shaped format string (e.g. `"{{\"{s}\":\"{s}\"}}"`).
//                       Hand-formatted JSON does NOT escape interpolated
//                       values, so a single hostile `{s}` argument can
//                       inject sibling JSON fields into the output —
//                       the entire C5 audit class from the
//                       zig_ai_server review. Use std.json.Stringify
//                       on an anonymous struct instead.
//
//   MBEDTLS-VERIFY-NONE — `MBEDTLS_SSL_VERIFY_NONE` token anywhere in
//                       source. Disables certificate validation in
//                       mbedTLS, which is never what production code
//                       wants. Even in test code the constant should
//                       not appear — use a mock CA chain instead.
//
//   EQL-FOR-SECRETS   — `std.mem.eql` or `memcmp` called within a
//                       function that names a secret (signature,
//                       token, hmac, mac, password, secret, api_key).
//                       Non-constant-time comparison on secrets is a
//                       timing side-channel; use `constantTimeEql` /
//                       `std.crypto.timing_safe.eql`.
//
//   SHELL-CHILD       — `/bin/sh`, `/bin/bash`, or `bash -c` / `sh -c`
//                       string literals where `std.process.Child`
//                       appears nearby. Shell wrappers re-introduce
//                       metacharacter injection that argv-mode exec
//                       was designed to avoid.
//
// All rules operate on the source bytes (not the AST), so they work
// for every language zig_lens scans (Zig, Rust, C, Python, JS/TS, Go).
// Some rules are intrinsically language-specific (MBEDTLS for C-ish,
// std.mem.eql for Zig) and simply do not fire on other inputs.

const std = @import("std");
const models = @import("../models.zig");

/// Run the security-pattern scan against `source` and append findings
/// to `report.security_findings`.
pub fn analyze(
    allocator: std.mem.Allocator,
    source: []const u8,
    report: *models.FileReport,
) !void {
    if (source.len == 0) return;

    // Iterate one line at a time so we can compute line numbers and
    // capture the trimmed line as the finding snippet.
    var line_start: usize = 0;
    var line_number: u32 = 1;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            const line_end = i;
            const line = source[line_start..line_end];

            try scanLine(allocator, source, line, line_number, line_start, report);

            line_number += 1;
            line_start = i + 1;
        }
    }
}

fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// Snippet capped to keep terminal output readable.
const max_snippet_bytes: usize = 200;

fn snippetOf(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const t = trimmed(line);
    const n = @min(t.len, max_snippet_bytes);
    return try allocator.dupe(u8, t[0..n]);
}

fn appendFinding(
    allocator: std.mem.Allocator,
    report: *models.FileReport,
    rule_id: []const u8,
    severity: models.RiskLevel,
    message: []const u8,
    line: []const u8,
    line_number: u32,
) !void {
    const snip = try snippetOf(allocator, line);
    try report.security_findings.append(allocator, .{
        .rule_id = rule_id,
        .line = line_number,
        .severity = severity,
        .message = try allocator.dupe(u8, message),
        .snippet = snip,
    });
}

fn scanLine(
    allocator: std.mem.Allocator,
    full_source: []const u8,
    line: []const u8,
    line_number: u32,
    line_offset: usize,
    report: *models.FileReport,
) !void {
    // Skip the obvious cases of comments that mention these patterns:
    // a line that *starts* with `//` is a comment (after trim) and the
    // anti-pattern there is documentation, not code.
    const t = trimmed(line);
    if (std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#")) return;
    // Multi-line string literal continuation in Zig (`\\foo bar`).
    // These show up in test fixtures and golden-output strings; the
    // brackets/keywords inside are payload, not code. Skipping them
    // eliminates analyzer-self-matches from this file's own tests
    // and reduces noise on any project that embeds expected-output
    // fixtures.
    if (std.mem.startsWith(u8, t, "\\\\")) return;

    // ── Rule: MBEDTLS-VERIFY-NONE ─────────────────────────────────
    if (std.mem.indexOf(u8, line, "MBEDTLS_SSL_VERIFY_NONE") != null) {
        try appendFinding(
            allocator,
            report,
            "MBEDTLS-VERIFY-NONE",
            .critical,
            "MBEDTLS_SSL_VERIFY_NONE disables certificate validation — never use in production",
            line,
            line_number,
        );
    }

    // ── Rule: JSON-IN-FMT ─────────────────────────────────────────
    // Match when a line invokes `allocPrint` or `bufPrint` AND the
    // line (or a small window around it) contains a JSON-shaped
    // format-string marker. We anchor on the function-name token and
    // require at least one strong JSON signal to avoid false
    // positives on legitimate format strings.
    if (containsIdent(line, "allocPrint") or containsIdent(line, "bufPrint")) {
        if (lineHasJsonShape(full_source, line_offset, line)) {
            try appendFinding(
                allocator,
                report,
                "JSON-IN-FMT",
                .high,
                "allocPrint/bufPrint used to build JSON — hand-formatted JSON does not escape interpolated values (use std.json.Stringify)",
                line,
                line_number,
            );
        }
    }

    // ── Rule: EQL-FOR-SECRETS ────────────────────────────────────
    // `std.mem.eql` or `memcmp` called in a function whose name (or
    // the surrounding ±5 lines) refers to a secret. The check is a
    // line-proximity heuristic rather than a full data-flow
    // analysis; it catches the common bug class without per-call AST
    // tracing.
    const has_mem_eql = std.mem.indexOf(u8, line, "std.mem.eql") != null or
        containsIdent(line, "memcmp");
    if (has_mem_eql and !containsIdent(line, "constantTimeEql") and !containsIdent(line, "timing_safe")) {
        if (proximityHasSecretContext(full_source, line_offset)) {
            try appendFinding(
                allocator,
                report,
                "EQL-FOR-SECRETS",
                .high,
                "non-constant-time comparison near a secret (signature/token/hmac/password) — use std.crypto.timing_safe.eql or security.constantTimeEql",
                line,
                line_number,
            );
        }
    }

    // ── Rule: SHELL-CHILD ─────────────────────────────────────────
    // String literals that explicitly invoke a shell to run a
    // command. Either the literal "/bin/sh" / "/bin/bash" anywhere,
    // or a `sh`/`bash` literal in proximity to a `-c` literal (the
    // classic shell-out pattern, which re-introduces every shell
    // metacharacter as an injection vector). The proximity rule
    // requires `Child` or `process.run` to also be near, so a string
    // like "bash -c" in documentation comments isn't flagged.
    if (std.mem.indexOf(u8, line, "\"/bin/sh\"") != null or
        std.mem.indexOf(u8, line, "\"/bin/bash\"") != null or
        std.mem.indexOf(u8, line, "\"/usr/bin/env\"") != null)
    {
        if (proximityHasProcessChild(full_source, line_offset)) {
            try appendFinding(
                allocator,
                report,
                "SHELL-CHILD",
                .critical,
                "process.Child invoked via /bin/sh — argv-mode exec exists specifically to avoid shell metacharacter injection",
                line,
                line_number,
            );
        }
    }

    // Catch the `"sh"` or `"bash"` + `"-c"` pair on the same line
    // (very common pattern for spawning a shell), independent of
    // proximity to Child.
    const has_sh = std.mem.indexOf(u8, line, "\"sh\"") != null or
        std.mem.indexOf(u8, line, "\"bash\"") != null or
        std.mem.indexOf(u8, line, "\"zsh\"") != null;
    const has_dash_c = std.mem.indexOf(u8, line, "\"-c\"") != null;
    if (has_sh and has_dash_c) {
        try appendFinding(
            allocator,
            report,
            "SHELL-CHILD",
            .critical,
            "shell -c pattern in argv — re-introduces metacharacter injection that argv-mode exec was designed to prevent",
            line,
            line_number,
        );
    }
}

/// True if `line` contains `name` as a whole-identifier token (the
/// adjacent characters are not identifier chars). Avoids matching
/// e.g. `bufPrint` inside `someBufPrintLikeThing` or comments that
/// inlude the substring.
fn containsIdent(line: []const u8, name: []const u8) bool {
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

/// Heuristic: a format-string literal contains JSON shape if it has
/// `{{` (literal `{` inside a Zig format string) or escaped quote
/// pairs `\"…\"`. We don't try to parse the format string fully —
/// the goal is "obvious JSON construction", and these markers are
/// strong signals in real-world code. We also scan the *next*
/// source line so a wrapped `allocPrint(\n  "…")` call still pairs
/// the function name with its format string.
fn lineHasJsonShape(full_source: []const u8, line_offset: usize, line: []const u8) bool {
    // Check the calling line itself.
    if (jsonShapeIn(line)) return true;
    // Plus up to 4 following lines (the format string is often on
    // the next line after the function name).
    var pos = line_offset + line.len;
    var lines_checked: u8 = 0;
    while (pos < full_source.len and lines_checked < 4) : (lines_checked += 1) {
        // Skip newline
        if (pos < full_source.len and full_source[pos] == '\n') pos += 1;
        const end = std.mem.indexOfScalarPos(u8, full_source, pos, '\n') orelse full_source.len;
        if (jsonShapeIn(full_source[pos..end])) return true;
        pos = end;
    }
    return false;
}

fn jsonShapeIn(s: []const u8) bool {
    // Strong markers in a Zig format-string literal that *very
    // likely* indicate hand-formatted JSON:
    //   {{"           start of a JSON object literal (escaped `{`)
    //   \":\"         JSON field separator with interpolation
    //   ,\"           comma followed by JSON field name
    //   \":{          field with object/numeric interpolation
    if (std.mem.indexOf(u8, s, "{{\\\"") != null) return true;
    if (std.mem.indexOf(u8, s, "\\\":\\\"") != null) return true;
    if (std.mem.indexOf(u8, s, "\\\":{") != null) return true;
    if (std.mem.indexOf(u8, s, ",\\\"") != null) return true;
    return false;
}

const secret_keywords = [_][]const u8{
    "signature", "Signature",
    "hmac",      "HMAC",     "Hmac",
    "mac",
    "password",  "Password",
    "secret",    "Secret",
    "api_key",   "apiKey",   "ApiKey",
    "session_token",
    "auth_token",
    "verify_token",
    "verifySignature",
    "verifyHmac",
    "verifyMac",
    "checkSignature",
    "checkHmac",
    "compareSignature",
    "compareHmac",
};

const non_secret_blocklist = [_][]const u8{
    // Words that *contain* a secret keyword as a substring but are
    // NOT actually secret-related — exclude them so we don't flag
    // every line in the file.
    "macro",
    "Macro",
    "machine",
    "Machine",
};

fn lineMentionsSecret(line: []const u8) bool {
    for (non_secret_blocklist) |bl| {
        if (std.mem.indexOf(u8, line, bl) != null) {
            // Only treat as blocked if the secret keyword we'd
            // otherwise match is the same substring. Cheap check:
            // if the blocklist token covers any secret-keyword hit
            // we'd find, prefer "not a secret". This is approximate
            // but errs on the side of false negatives, which is
            // safer for a security scanner that bails CI.
            for (secret_keywords) |sk| {
                if (std.mem.indexOf(u8, bl, sk) != null) return false;
            }
        }
    }
    for (secret_keywords) |sk| {
        if (containsIdent(line, sk)) return true;
        // Some keywords appear as substrings of longer identifiers
        // we want to catch (e.g. verifyHmacSha256). Match by case-
        // insensitive substring as well.
        if (std.ascii.indexOfIgnoreCase(line, sk) != null) return true;
    }
    return false;
}

/// True if any of the ±5 source lines around `line_offset` mention a
/// secret keyword (signature, token, hmac, …). Used by EQL-FOR-SECRETS.
fn proximityHasSecretContext(full_source: []const u8, line_offset: usize) bool {
    return proximityHasKeyword(full_source, line_offset, lineMentionsSecret);
}

fn lineMentionsProcessChild(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "process.Child") != null) return true;
    if (std.mem.indexOf(u8, line, "process.run") != null) return true;
    if (std.mem.indexOf(u8, line, "Child.init") != null) return true;
    if (std.mem.indexOf(u8, line, "Child.spawn") != null) return true;
    if (containsIdent(line, "execve")) return true;
    if (containsIdent(line, "system")) return true;
    return false;
}

/// True if any of the ±5 source lines around `line_offset` mention
/// `process.Child` or related exec primitives. Used by SHELL-CHILD.
fn proximityHasProcessChild(full_source: []const u8, line_offset: usize) bool {
    return proximityHasKeyword(full_source, line_offset, lineMentionsProcessChild);
}

const proximity_lines: usize = 5;

fn proximityHasKeyword(
    full_source: []const u8,
    line_offset: usize,
    predicate: *const fn (line: []const u8) bool,
) bool {
    // Walk backward up to `proximity_lines` lines from line_offset.
    var back_pos: usize = line_offset;
    var lines_back: usize = 0;
    while (lines_back < proximity_lines and back_pos > 0) : (lines_back += 1) {
        // Move back past the previous newline.
        if (back_pos > 0 and full_source[back_pos - 1] == '\n') back_pos -= 1;
        var prev = back_pos;
        while (prev > 0 and full_source[prev - 1] != '\n') prev -= 1;
        if (predicate(full_source[prev..back_pos])) return true;
        back_pos = prev;
    }

    // Walk forward up to `proximity_lines` lines from line_offset.
    var pos = line_offset;
    // Move forward past the line containing line_offset first.
    const start_line_end = std.mem.indexOfScalarPos(u8, full_source, pos, '\n') orelse full_source.len;
    // Check the starting line itself too.
    if (predicate(full_source[pos..start_line_end])) return true;
    pos = start_line_end;
    var lines_forward: usize = 0;
    while (lines_forward < proximity_lines and pos < full_source.len) : (lines_forward += 1) {
        if (pos < full_source.len and full_source[pos] == '\n') pos += 1;
        const end = std.mem.indexOfScalarPos(u8, full_source, pos, '\n') orelse full_source.len;
        if (predicate(full_source[pos..end])) return true;
        pos = end;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

fn runOn(allocator: std.mem.Allocator, source: []const u8) !models.FileReport {
    var report = models.FileReport.init();
    try analyze(allocator, source, &report);
    return report;
}

fn freeReport(allocator: std.mem.Allocator, report: *models.FileReport) void {
    for (report.security_findings.items) |f| {
        allocator.free(f.message);
        allocator.free(f.snippet);
    }
    report.security_findings.deinit(allocator);
    report.functions.deinit(allocator);
    report.structs.deinit(allocator);
    report.enums.deinit(allocator);
    report.unions.deinit(allocator);
    report.constants.deinit(allocator);
    report.tests.deinit(allocator);
    report.imports.deinit(allocator);
    report.unsafe_ops.deinit(allocator);
}

test "MBEDTLS-VERIFY-NONE: flagged on raw token" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn setupTls() void {
        \\    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    try std.testing.expect(r.security_findings.items.len == 1);
    try std.testing.expectEqualStrings("MBEDTLS-VERIFY-NONE", r.security_findings.items[0].rule_id);
}

test "MBEDTLS-VERIFY-NONE: ignored in comment" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\// don't ever pass MBEDTLS_SSL_VERIFY_NONE here
        \\fn x() void {}
        \\
    );
    defer freeReport(allocator, &r);
    try std.testing.expectEqual(@as(usize, 0), r.security_findings.items.len);
}

test "JSON-IN-FMT: allocPrint with JSON object" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn bad(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        \\    return std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{name});
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "JSON-IN-FMT")) found = true;
    }
    try std.testing.expect(found);
}

test "JSON-IN-FMT: bufPrint with JSON field separator" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn bad(buf: []u8, n: u32) ![]u8 {
        \\    return std.fmt.bufPrint(buf, "{{\"count\":{d}}}", .{n});
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "JSON-IN-FMT")) found = true;
    }
    try std.testing.expect(found);
}

test "JSON-IN-FMT: allocPrint of plain text not flagged" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn ok(allocator: std.mem.Allocator, n: u32) ![]u8 {
        \\    return std.fmt.allocPrint(allocator, "value: {d}", .{n});
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "JSON-IN-FMT")) return error.TestUnexpectedFinding;
    }
}

test "EQL-FOR-SECRETS: std.mem.eql in verifySignature context" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn verifySignature(expected: []const u8, computed: []const u8) bool {
        \\    return std.mem.eql(u8, expected, computed);
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) found = true;
    }
    try std.testing.expect(found);
}

test "EQL-FOR-SECRETS: std.mem.eql on unrelated data not flagged" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn isHello(s: []const u8) bool {
        \\    return std.mem.eql(u8, s, "hello");
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) return error.TestUnexpectedFinding;
    }
}

test "EQL-FOR-SECRETS: constantTimeEql on same line not flagged" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn verifyHmac(expected: []const u8, computed: []const u8) bool {
        \\    return security.constantTimeEql(expected, computed);
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) return error.TestUnexpectedFinding;
    }
}

test "SHELL-CHILD: /bin/sh next to process.Child" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn bad(allocator: std.mem.Allocator) !void {
        \\    var child = std.process.Child.init(&.{"/bin/sh", "-c", "echo hi"}, allocator);
        \\    try child.spawn();
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "SHELL-CHILD")) found = true;
    }
    try std.testing.expect(found);
}

test "SHELL-CHILD: bash -c pair on argv line" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn bad() !void {
        \\    const argv = [_][]const u8{"bash", "-c", "rm -rf $HOME"};
        \\    _ = argv;
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "SHELL-CHILD")) found = true;
    }
    try std.testing.expect(found);
}

test "SHELL-CHILD: zig keyword 'comptime' not mistaken for shell" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\const x = comptime blk: {
        \\    break :blk 1;
        \\};
        \\
    );
    defer freeReport(allocator, &r);
    try std.testing.expectEqual(@as(usize, 0), r.security_findings.items.len);
}
