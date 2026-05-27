// Security anti-pattern scanner.
//
// This analyzer flags specific anti-patterns. Each rule has a stable
// id so CI / pre-commit hooks can grep for it, and each rule
// explicitly declares what it COVERS and what it DOES NOT COVER —
// see `rule_coverage` below. The coverage is surfaced in terminal +
// JSON output so a clean scan never reads as "this class is
// handled" — every rule has gaps, and the gaps must be visible.
//
// Why the coverage notes matter: when a scanner becomes a trusted
// CI gate, its false negatives are dangerous in a way a linter's
// aren't — a green --strict reads as "checked," and a finding-
// shaped class the rule doesn't actually catch becomes invisible.
// JSON-IN-FMT catches hand-formatted JSON, but the underlying class
// is "interpolating untrusted values into ANY structured format
// without escaping." SQL, XML, YAML, URL segments, HTML, shell
// strings outside process.Child — every sibling needs its own rule
// or its own review. Treat a clean scan as "the rules we have
// passed," not "no injection vulnerabilities."
//
// Inline suppression: when human review has confirmed a finding is
// a false positive, the line (or the line above) can carry the
// directive
//
//   // zig-lens-ignore: <RULE-ID> <reason text>
//
// The reason is REQUIRED — undocumented suppressions are silent
// bug nests. CI can grep `zig-lens-ignore:` to enumerate every
// active waiver and periodically reconfirm. The suppression is
// rule-id-specific, so a future-added rule that catches a real
// bug on the same line still surfaces.

const std = @import("std");
const models = @import("../models.zig");

// ── Coverage declarations ────────────────────────────────────────
//
// Public table — each rule states what it catches and what it does
// not. The terminal/JSON output prints this for every rule whether
// or not it fired, so the operator can see exactly which classes
// the scan addressed and which it punted on.

pub const RuleCoverage = struct {
    id: []const u8,
    summary: []const u8,
    /// What this rule reliably catches.
    covers: []const u8,
    /// Sibling shapes the rule does NOT catch. The whole point of
    /// surfacing this is that a clean scan is not certification.
    does_not_cover: []const u8,
};

pub const rule_coverage = [_]RuleCoverage{
    .{
        .id = "JSON-IN-FMT",
        .summary = "Hand-formatted JSON in printf-style format strings",
        .covers =
        \\allocPrint / bufPrint where the format string contains JSON
        \\shape markers ({{"…":"…"}}, ":[, etc.).
        ,
        .does_not_cover =
        \\Hand-built SQL ("WHERE id={s}"), XML, YAML, URL path segments,
        \\HTML, shell-command strings outside std.process.Child, JSON
        \\construction through std.ArrayList.appendSlice + literals
        \\("\"name\":\"" then escape-less write), or any other
        \\structured format. Each is a sibling injection class that
        \\needs its own rule. A green JSON-IN-FMT scan does NOT mean
        \\injection-safe.
        ,
    },
    .{
        .id = "MBEDTLS-VERIFY-NONE",
        .summary = "mbedTLS certificate validation disabled by literal flag",
        .covers =
        \\Any source line referencing the MBEDTLS_SSL_VERIFY_NONE token
        \\(outside of comments and multi-line string fixtures).
        ,
        .does_not_cover =
        \\Equivalent disablements via numeric literal 0 passed to
        \\mbedtls_ssl_conf_authmode, custom verify callbacks that
        \\always return 0, or runtime config that selects VERIFY_NONE
        \\indirectly (e.g. through an env-var-driven int). Also
        \\language-specific equivalents in OpenSSL / LibreSSL / Rust
        \\rustls / Go crypto/tls (InsecureSkipVerify) — none scanned.
        ,
    },
    .{
        .id = "EQL-FOR-SECRETS",
        .summary = "Non-constant-time comparison in auth-context functions",
        .covers =
        \\std.mem.eql / memcmp called within a function whose NAME or
        \\PARAMETER list contains a recognized secret. Token matching
        \\splits identifiers on camelCase and snake_case boundaries:
        \\
        \\  Single sub-tokens (case-insensitive equality):
        \\    signature, hmac, password, passwd, secret, nonce, apikey
        \\
        \\  Adjacent sub-token pairs:
        \\    api/key, session/token, auth/token, bearer/token,
        \\    csrf/token, access/token, refresh/token, verify/token,
        \\    id/token
        \\
        \\So `verifyHmacSha256` matches (single `Hmac`),
        \\`verifyAuthToken` matches (pair `Auth`+`Token`), and
        \\`signature_b64` matches (single `signature`). `main_token` /
        \\`tokenize` / `machine` / `mac_address` / `secretary` do NOT
        \\match. Scope is the ENCLOSING function looked up via
        \\report.functions, not line proximity.
        ,
        .does_not_cover =
        \\Auth-context functions whose identifiers don't contain a
        \\keyword (e.g. `compare`, `validate`, `checkBearer` — Bearer
        \\alone is not in the set). Comparisons through indirection
        \\(function A calls helper B which does the eql). Hand-rolled
        \\loops over byte arrays. Comparisons via the `!=` operator
        \\on slices. Cross-file flow (the eql is in a different file
        \\than the function whose name signals the secret context).
        \\For these the gate cannot replace human review.
        ,
    },
    .{
        .id = "SHELL-CHILD",
        .summary = "Shell invocation in argv-mode process spawn",
        .covers =
        \\Literal "/bin/sh" or "/bin/bash" string appearing in the body
        \\of a function that also references std.process.Child /
        \\process.run / Child.init / execve / execvp / system. Plus
        \\the "sh"+"-c" or "bash"+"-c" literal pair on the same argv
        \\line (independent of enclosing function).
        ,
        .does_not_cover =
        \\Shell invocations via $SHELL / getenv("SHELL") indirection
        \\(the literal "/bin/sh" never appears in source). argv[0]
        \\bound to a runtime-discovered binary that happens to be a
        \\shell. popen / posix_spawn / system() / Rust
        \\Command::new("sh") if not preceded by "/bin/sh" literal.
        \\Cross-function flow where the argv is built in one fn and
        \\spawned in another.
        ,
    },
};

pub fn coverageFor(id: []const u8) ?*const RuleCoverage {
    for (&rule_coverage) |*r| {
        if (std.mem.eql(u8, r.id, id)) return r;
    }
    return null;
}

// ── Scanner entry point ──────────────────────────────────────────

/// Run the security-pattern scan against `source` and append findings
/// to `report.security_findings`. The scanner consults
/// `report.functions` (already populated by the structure analyzer
/// upstream) to scope EQL-FOR-SECRETS and SHELL-CHILD to the
/// enclosing function instead of using line proximity.
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

const max_snippet_bytes: usize = 200;

fn snippetOf(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const t = trimmed(line);
    const n = @min(t.len, max_snippet_bytes);
    return try allocator.dupe(u8, t[0..n]);
}

fn appendFinding(
    allocator: std.mem.Allocator,
    report: *models.FileReport,
    full_source: []const u8,
    line_offset: usize,
    rule_id: []const u8,
    severity: models.RiskLevel,
    message: []const u8,
    line: []const u8,
    line_number: u32,
) !void {
    // Inline suppression: respect `// zig-lens-ignore: <RULE-ID> <reason>`
    // on the same line OR the line immediately above. See
    // hasIgnoreDirective for the exact contract — every suppression
    // requires a non-empty reason so CI / audit can grep
    // `zig-lens-ignore:` to find them all and re-review periodically.
    if (hasIgnoreDirective(full_source, line_offset, line, rule_id)) return;

    const snip = try snippetOf(allocator, line);
    try report.security_findings.append(allocator, .{
        .rule_id = rule_id,
        .line = line_number,
        .severity = severity,
        .message = try allocator.dupe(u8, message),
        .snippet = snip,
    });
}

// ── Inline suppression directive ─────────────────────────────────
//
// Syntax:
//   // zig-lens-ignore: <RULE-ID> <reason text>
//
// Placement: either on the same source line as the finding (trailing
// comment) OR on the line immediately above. The `<reason text>`
// MUST be present (at least 4 non-whitespace chars after the rule
// id) — undocumented suppressions are silent bug nests; CI can
// grep `zig-lens-ignore:` to enumerate every active waiver and
// periodically reconfirm the reasons still hold.
//
// Rule-id-specific: a suppression for EQL-FOR-SECRETS does NOT
// suppress, say, a SHELL-CHILD finding on the same line. So a
// future-added rule that catches a real bug still surfaces.

const ignore_tag: []const u8 = "zig-lens-ignore:";

fn hasIgnoreDirective(
    full_source: []const u8,
    line_offset: usize,
    line: []const u8,
    rule_id: []const u8,
) bool {
    if (lineIgnoresRule(line, rule_id)) return true;

    // Walk back one line.
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
    // Require a separator (space, tab, dash, em-dash byte sequence).
    // A bare `zig-lens-ignore: EQL-FOR-SECRETS` with nothing after
    // is rejected — the reason is mandatory.
    if (rest.len == 0) return false;
    const first = rest[0];
    if (first != ' ' and first != '\t' and first != '-' and first != ':') return false;
    // Trim leading whitespace + separator characters and any UTF-8
    // em-dash bytes (— = 0xE2 0x80 0x94). Then require at least 4
    // non-whitespace characters of explanation.
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

fn scanLine(
    allocator: std.mem.Allocator,
    full_source: []const u8,
    line: []const u8,
    line_number: u32,
    line_offset: usize,
    report: *models.FileReport,
) !void {
    const t = trimmed(line);
    // Comment lines (Zig //, Python/shell #) carry pattern text as
    // documentation, not as code. Skip them.
    if (std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#")) return;
    // Zig multi-line string continuations (`\\…`) carry test
    // fixtures / golden outputs, not active code. Skip.
    if (std.mem.startsWith(u8, t, "\\\\")) return;

    // ── Rule: MBEDTLS-VERIFY-NONE ─────────────────────────────────
    // zig-lens-ignore: MBEDTLS-VERIFY-NONE scanner pattern definition, not a real mbedTLS call site
    if (std.mem.indexOf(u8, line, "MBEDTLS_SSL_VERIFY_NONE") != null) {
        try appendFinding(
            allocator,
            report,
            full_source,
            line_offset,
            "MBEDTLS-VERIFY-NONE",
            .critical,
            // zig-lens-ignore: MBEDTLS-VERIFY-NONE this string is the finding message text, not an mbedTLS call
            "MBEDTLS_SSL_VERIFY_NONE disables certificate validation — never use in production",
            line,
            line_number,
        );
    }

    // ── Rule: JSON-IN-FMT ─────────────────────────────────────────
    // Anchor on the function-name token AND require at least one
    // JSON-shape marker to keep false-positive rate manageable on
    // legitimate format strings. Scans this line plus the next 4
    // (the format-string literal often wraps onto the next line).
    if (containsIdent(line, "allocPrint") or containsIdent(line, "bufPrint")) {
        if (lineHasJsonShape(full_source, line_offset, line)) {
            try appendFinding(
                allocator,
                report,
                full_source,
                line_offset,
                "JSON-IN-FMT",
                .high,
                "allocPrint/bufPrint used to build JSON — hand-formatted JSON does not escape interpolated values (use std.json.Stringify)",
                line,
                line_number,
            );
        }
    }

    // ── Rule: EQL-FOR-SECRETS ────────────────────────────────────
    //
    // Scope: the ENCLOSING function (looked up via report.functions
    // populated by structure.analyze upstream). NOT line proximity.
    //
    // Previous design used a ±5-line proximity check with a
    // substring fallback (lineMentionsSecret used both
    // containsIdent AND indexOfIgnoreCase, plus a hand-maintained
    // blocklist for "machine" / "Machine" to suppress noise from
    // substring matches). That fell over two ways: (1) any verify
    // function where the eql sits >5 lines from the function-name
    // declaration was missed — the COMMON shape — and (2) the
    // substring fallback re-opened the noise hole the blocklist
    // tried to close. Together it errs toward false-negative-by-
    // design, which is backwards for a CI gate: a clean scan
    // shipped timing-unsafe compares under a green check.
    //
    // The new rule: tokenize the enclosing function's NAME and
    // PARAMS string into camel/snake sub-tokens, then check each
    // sub-token against a small set of secret words. No
    // substring fallback. Sub-token equality is case-insensitive.
    const has_mem_eql = std.mem.indexOf(u8, line, "std.mem.eql") != null or
        containsIdent(line, "memcmp");
    if (has_mem_eql and !containsIdent(line, "constantTimeEql") and !containsIdent(line, "timing_safe")) {
        if (enclosingFunctionAt(report, line_number)) |fn_info| {
            if (functionLooksSecretRelated(fn_info)) {
                try appendFinding(
                    allocator,
                    report,
                    full_source,
                    line_offset,
                    "EQL-FOR-SECRETS",
                    .high,
                    "non-constant-time comparison in a function whose name or parameters identify a secret — use std.crypto.timing_safe.eql or security.constantTimeEql",
                    line,
                    line_number,
                );
            }
        }
    }

    // ── Rule: SHELL-CHILD ─────────────────────────────────────────
    // Same enclosing-function-scope discipline as EQL-FOR-SECRETS:
    // look for the shell-binary literal AND a spawn primitive in
    // the same function body. Drops the previous ±5-line proximity
    // check.
    if (std.mem.indexOf(u8, line, "\"/bin/sh\"") != null or
        std.mem.indexOf(u8, line, "\"/bin/bash\"") != null or
        std.mem.indexOf(u8, line, "\"/usr/bin/env\"") != null)
    {
        if (enclosingFunctionAt(report, line_number)) |fn_info| {
            if (functionBodyMentionsSpawn(full_source, fn_info)) {
                try appendFinding(
                    allocator,
                    report,
                    full_source,
                    line_offset,
                    "SHELL-CHILD",
                    .critical,
                    "process.Child / process.run / execve invoked via /bin/sh — argv-mode exec exists specifically to avoid shell metacharacter injection",
                    line,
                    line_number,
                );
            }
        }
    }

    // Catch the `"sh"` / `"bash"` + `"-c"` pair on the same line
    // (very common argv-array literal pattern). Independent of
    // enclosing-function scope because the pair itself is a strong
    // signal.
    const has_sh = std.mem.indexOf(u8, line, "\"sh\"") != null or
        std.mem.indexOf(u8, line, "\"bash\"") != null or
        std.mem.indexOf(u8, line, "\"zsh\"") != null;
    const has_dash_c = std.mem.indexOf(u8, line, "\"-c\"") != null;
    if (has_sh and has_dash_c) {
        try appendFinding(
            allocator,
            report,
            full_source,
            line_offset,
            "SHELL-CHILD",
            .critical,
            "shell -c pattern in argv — re-introduces metacharacter injection that argv-mode exec was designed to prevent",
            line,
            line_number,
        );
    }
}

// ── Helpers: identifier-token matching ───────────────────────────

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

// ── Helpers: JSON shape detection ────────────────────────────────

fn lineHasJsonShape(full_source: []const u8, line_offset: usize, line: []const u8) bool {
    if (jsonShapeIn(line)) return true;
    var pos = line_offset + line.len;
    var lines_checked: u8 = 0;
    while (pos < full_source.len and lines_checked < 4) : (lines_checked += 1) {
        if (pos < full_source.len and full_source[pos] == '\n') pos += 1;
        const end = std.mem.indexOfScalarPos(u8, full_source, pos, '\n') orelse full_source.len;
        if (jsonShapeIn(full_source[pos..end])) return true;
        pos = end;
    }
    return false;
}

fn jsonShapeIn(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "{{\\\"") != null) return true;
    if (std.mem.indexOf(u8, s, "\\\":\\\"") != null) return true;
    if (std.mem.indexOf(u8, s, "\\\":{") != null) return true;
    if (std.mem.indexOf(u8, s, ",\\\"") != null) return true;
    return false;
}

// ── Helpers: enclosing-function lookup ───────────────────────────
//
// Both EQL-FOR-SECRETS and SHELL-CHILD scope to the enclosing
// function instead of line proximity. The function table is
// populated by structure.analyze (Zig) or the language-specific
// line-based analyzers (Rust / C / Python / JS / Go) before
// security_patterns runs, so this is a cheap O(F) lookup per
// finding candidate.

fn enclosingFunctionAt(report: *const models.FileReport, line: u32) ?*const models.FunctionInfo {
    var best: ?*const models.FunctionInfo = null;
    for (report.functions.items) |*f| {
        if (f.line <= line and line <= f.end_line) {
            // Inner function wins when functions nest (the structure
            // analyzer flattens nested decls into the same list, so
            // an inner fn's range is contained in the outer's; the
            // inner has a higher start line, so prefer max start).
            if (best == null or f.line > best.?.line) best = f;
        }
    }
    return best;
}

// ── Helpers: function-body byte range + spawn detection ──────────

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
    // Token-aware: `process.run`, `Child.init`, etc. are all
    // multi-character literals — substring is fine because they're
    // unambiguous (no English word contains "process.Child").
    if (std.mem.indexOf(u8, body, "process.Child") != null) return true;
    if (std.mem.indexOf(u8, body, "process.run") != null) return true;
    if (std.mem.indexOf(u8, body, "Child.init") != null) return true;
    if (std.mem.indexOf(u8, body, "Child.spawn") != null) return true;
    if (containsIdent(body, "execve")) return true;
    if (containsIdent(body, "execvp")) return true;
    return false;
}

// ── Helpers: identifier sub-token matching for secret context ────

/// Secret words (case-insensitive equality against a single sub-token).
/// Sub-token splitting handles camelCase + snake_case, so
/// "tokenize" / "tokenizer" / "machine" / "mac_address" / "secretary"
/// stay as single tokens and don't match — only the camel/snake
/// component patterns like "Hmac" inside "verifyHmac" do.
///
/// `token` is deliberately NOT here even though it looks like a
/// secret word: the Zig AST and many parsers use `main_token` /
/// `name_token` / `next_token` as parameter names, and splitting
/// them to `[main, token]` matched here. The auth shapes that
/// matter are caught via the compound pair set below
/// (`verify/token`, `auth/token`, `session/token`, etc.) — those
/// require an ADJACENT sub-token, which AST parameter names don't
/// satisfy.
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

/// Adjacent sub-token pairs that name a secret (case-insensitive on
/// each side). Catches "api_key" → tokens `["api","key"]`, "apiKey"
/// → tokens `["api","Key"]`, etc.
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

/// Maximum sub-tokens an identifier can split into. 16 covers any
/// real-world function name; longer names just get truncated at
/// the buffer boundary (still a partial match — never silently OK).
const max_subtokens: usize = 16;

/// Split `ident` into camelCase + snake_case sub-tokens. Returns
/// slices into `ident` (zero-copy). Up to `max_subtokens` results.
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
            // camelCase boundary: lower → Upper.
            if (n < out.len) {
                out[n] = ident[start..i];
                n += 1;
            }
            start = i;
        } else if (i > start + 1 and std.ascii.isUpper(c) and std.ascii.isUpper(ident[i - 1]) and i + 1 < ident.len and std.ascii.isLower(ident[i + 1])) {
            // ACRONYMBoundary: `H` in `HMACSomething` would otherwise
            // run `HMACS` together. Detect a run of uppercase
            // followed by a lowercase and split before the last
            // uppercase. Example: "HMACSha" splits at S → "HMAC",
            // "Sha".
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

/// True if any camel/snake sub-token of `ident` is a secret word, or
/// any adjacent pair forms a secret pair.
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

/// Extract identifier tokens from a function's params textual form
/// (e.g. "expected: []const u8,computed: []const u8") and test each
/// one. The params string is whatever shape the structure analyzer
/// produced; we just scan all identifier-shaped runs and check each.
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

// ============================================================================
// Tests
// ============================================================================

fn runOnWithFns(allocator: std.mem.Allocator, source: []const u8, fns: []const models.FunctionInfo) !models.FileReport {
    var report = models.FileReport.init();
    for (fns) |f| try report.functions.append(allocator, f);
    try analyze(allocator, source, &report);
    return report;
}

fn runOn(allocator: std.mem.Allocator, source: []const u8) !models.FileReport {
    return runOnWithFns(allocator, source, &.{});
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

test "splitIdentSubtokens: camelCase splits at lower→Upper" {
    var buf: [max_subtokens][]const u8 = undefined;
    const toks = splitIdentSubtokens("verifyHmacSha256", &buf);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("verify", toks[0]);
    try std.testing.expectEqualStrings("Hmac", toks[1]);
    try std.testing.expectEqualStrings("Sha256", toks[2]);
}

test "splitIdentSubtokens: snake_case splits at _" {
    var buf: [max_subtokens][]const u8 = undefined;
    const toks = splitIdentSubtokens("verify_session_token", &buf);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("verify", toks[0]);
    try std.testing.expectEqualStrings("session", toks[1]);
    try std.testing.expectEqualStrings("token", toks[2]);
}

test "splitIdentSubtokens: single-word identifiers stay one token" {
    var buf: [max_subtokens][]const u8 = undefined;
    {
        const toks = splitIdentSubtokens("tokenize", &buf);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqualStrings("tokenize", toks[0]);
    }
    {
        const toks = splitIdentSubtokens("machine", &buf);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqualStrings("machine", toks[0]);
    }
    {
        const toks = splitIdentSubtokens("secretary", &buf);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqualStrings("secretary", toks[0]);
    }
}

test "identNamesSecret: positive shapes" {
    try std.testing.expect(identNamesSecret("verifyHmac"));
    try std.testing.expect(identNamesSecret("verify_hmac"));
    try std.testing.expect(identNamesSecret("checkSignature"));
    try std.testing.expect(identNamesSecret("hmac_sha256"));
    try std.testing.expect(identNamesSecret("apiKey"));
    try std.testing.expect(identNamesSecret("api_key"));
    try std.testing.expect(identNamesSecret("session_token"));
    try std.testing.expect(identNamesSecret("verifyPassword"));
}

test "identNamesSecret: negative shapes (no substring false-positives)" {
    // The old substring fallback used to flag these. The new rule
    // must NOT flag them — that's the whole point.
    try std.testing.expect(!identNamesSecret("machine"));
    try std.testing.expect(!identNamesSecret("machineLearning"));
    try std.testing.expect(!identNamesSecret("tokenize"));
    try std.testing.expect(!identNamesSecret("tokenizer"));
    try std.testing.expect(!identNamesSecret("secretary"));
    try std.testing.expect(!identNamesSecret("mac_address")); // mac is not in single-word set
    try std.testing.expect(!identNamesSecret("openssl_init"));

    // Regression: AST/parser code uses `main_token`, `name_token`,
    // `next_token` etc. as parameter names. With `token` in the
    // singles set these matched and the scanner blew up on every
    // parser-touching function. The compound pair forms catch the
    // real auth shapes (verifyToken, sessionToken) instead.
    try std.testing.expect(!identNamesSecret("main_token"));
    try std.testing.expect(!identNamesSecret("name_token"));
    try std.testing.expect(!identNamesSecret("next_token"));
    try std.testing.expect(!identNamesSecret("token_index"));
    try std.testing.expect(!identNamesSecret("tokenIndex"));
}

test "identNamesSecret: pair forms still catch auth tokens" {
    try std.testing.expect(identNamesSecret("verifyToken"));   // pair verify/Token
    try std.testing.expect(identNamesSecret("verify_token"));  // pair verify/token
    try std.testing.expect(identNamesSecret("sessionToken"));  // pair session/Token
    try std.testing.expect(identNamesSecret("bearer_token"));
    try std.testing.expect(identNamesSecret("authToken"));
    try std.testing.expect(identNamesSecret("verifyAuthToken")); // adjacent Auth/Token
}

test "EQL-FOR-SECRETS: fires only when enclosing function names a secret" {
    const allocator = std.testing.allocator;

    const source =
        \\fn verifySignature(expected: []const u8, computed: []const u8) bool {
        \\    // ten lines of unrelated code first to defeat ±5 proximity
        \\    var i: usize = 0;
        \\    while (i < 10) : (i += 1) {
        \\        std.debug.print("noise {d}\n", .{i});
        \\    }
        \\    return std.mem.eql(u8, expected, computed);
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "verifySignature",
            .line = 1,
            .end_line = 8,
            .body_lines = 7,
            .params = "expected: []const u8,computed: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);

    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) found = true;
    }
    try std.testing.expect(found);
}

test "EQL-FOR-SECRETS: ignored in unrelated function (no substring noise)" {
    const allocator = std.testing.allocator;

    // The string "secretary" is the ONLY thing nearby that could
    // trip a substring search. It must not.
    const source =
        \\fn secretaryDeskCheck(left: []const u8, right: []const u8) bool {
        \\    return std.mem.eql(u8, left, right);
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "secretaryDeskCheck",
            .line = 1,
            .end_line = 3,
            .body_lines = 2,
            .params = "left: []const u8,right: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);

    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) return error.TestUnexpectedFinding;
    }
}

test "EQL-FOR-SECRETS: matches when only the parameter name signals secret" {
    const allocator = std.testing.allocator;

    // Function name is generic; the secret signal comes from a
    // parameter named `signature_b64`. This is the JWT-verify
    // pattern: `verify(token, alg, secret)` where the fn name
    // tells you nothing.
    const source =
        \\fn verify(token: []const u8, signature_b64: []const u8) bool {
        \\    return std.mem.eql(u8, token, signature_b64);
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "verify",
            .line = 1,
            .end_line = 3,
            .body_lines = 2,
            .params = "token: []const u8,signature_b64: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);

    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) found = true;
    }
    try std.testing.expect(found);
}

test "MBEDTLS-VERIFY-NONE: still flagged on raw token" {
    const allocator = std.testing.allocator;
    var r = try runOn(allocator,
        \\fn setupTls() void {
        \\    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        \\}
        \\
    );
    defer freeReport(allocator, &r);
    try std.testing.expect(r.security_findings.items.len >= 1);
}

test "JSON-IN-FMT: still flagged" {
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

test "SHELL-CHILD: enclosing-fn scope catches /bin/sh + Child.init" {
    const allocator = std.testing.allocator;

    const source =
        \\fn spawn(allocator: std.mem.Allocator) !void {
        \\    const argv = [_][]const u8{ "/bin/sh", "-c", "echo hi" };
        \\    var child = std.process.Child.init(&argv, allocator);
        \\    _ = try child.spawnAndWait();
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "spawn",
            .line = 1,
            .end_line = 5,
            .body_lines = 4,
            .params = "allocator: std.mem.Allocator",
            .return_type = "!void",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);

    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "SHELL-CHILD")) found = true;
    }
    try std.testing.expect(found);
}

test "coverageFor: every rule has coverage notes" {
    try std.testing.expect(coverageFor("JSON-IN-FMT") != null);
    try std.testing.expect(coverageFor("MBEDTLS-VERIFY-NONE") != null);
    try std.testing.expect(coverageFor("EQL-FOR-SECRETS") != null);
    try std.testing.expect(coverageFor("SHELL-CHILD") != null);
    try std.testing.expect(coverageFor("BOGUS-RULE") == null);
}

// ── Suppression directive tests ─────────────────────────────────

test "lineIgnoresRule: same-line trailing directive with reason" {
    try std.testing.expect(lineIgnoresRule(
        "    if (std.mem.eql(u8, a, b)) return; // zig-lens-ignore: EQL-FOR-SECRETS public status string, not a secret",
        "EQL-FOR-SECRETS",
    ));
}

test "lineIgnoresRule: rule-id-specific (mismatched id is NOT suppressed)" {
    try std.testing.expect(!lineIgnoresRule(
        "// zig-lens-ignore: JSON-IN-FMT we built JSON by hand here for performance",
        "EQL-FOR-SECRETS",
    ));
}

test "lineIgnoresRule: empty reason is REJECTED (silent suppression is a bug nest)" {
    try std.testing.expect(!lineIgnoresRule(
        "// zig-lens-ignore: EQL-FOR-SECRETS",
        "EQL-FOR-SECRETS",
    ));
    try std.testing.expect(!lineIgnoresRule(
        "// zig-lens-ignore: EQL-FOR-SECRETS    ",
        "EQL-FOR-SECRETS",
    ));
    // Just a separator (dash) with no reason text
    try std.testing.expect(!lineIgnoresRule(
        "// zig-lens-ignore: EQL-FOR-SECRETS —",
        "EQL-FOR-SECRETS",
    ));
}

test "lineIgnoresRule: em-dash separator after rule id" {
    try std.testing.expect(lineIgnoresRule(
        "// zig-lens-ignore: EQL-FOR-SECRETS — JWT iss is a public URL, not a secret",
        "EQL-FOR-SECRETS",
    ));
}

test "lineIgnoresRule: colon separator after rule id" {
    try std.testing.expect(lineIgnoresRule(
        "// zig-lens-ignore: EQL-FOR-SECRETS: chat-role string, API metadata not secret",
        "EQL-FOR-SECRETS",
    ));
}

test "EQL-FOR-SECRETS: suppression on same line skips the finding" {
    const allocator = std.testing.allocator;
    const source =
        \\fn verifySignature(expected: []const u8, computed: []const u8) bool {
        \\    return std.mem.eql(u8, expected, computed); // zig-lens-ignore: EQL-FOR-SECRETS reviewed: prefix-check not a timing-side-channel
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "verifySignature",
            .line = 1,
            .end_line = 3,
            .body_lines = 2,
            .params = "expected: []const u8,computed: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) return error.SuppressedFindingStillFired;
    }
}

test "EQL-FOR-SECRETS: suppression on the line ABOVE skips the finding" {
    const allocator = std.testing.allocator;
    const source =
        \\fn verifySignature(expected: []const u8, computed: []const u8) bool {
        \\    // zig-lens-ignore: EQL-FOR-SECRETS reviewed: caller wraps this in timing_safe.eql at boundary
        \\    return std.mem.eql(u8, expected, computed);
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "verifySignature",
            .line = 1,
            .end_line = 4,
            .body_lines = 3,
            .params = "expected: []const u8,computed: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) return error.SuppressedFindingStillFired;
    }
}

test "EQL-FOR-SECRETS: suppression for wrong rule ID does NOT silence the finding" {
    const allocator = std.testing.allocator;
    // Author tried to silence EQL-FOR-SECRETS with a JSON-IN-FMT
    // suppression — the rule should still fire (rule-id specific).
    const source =
        \\fn verifySignature(expected: []const u8, computed: []const u8) bool {
        \\    return std.mem.eql(u8, expected, computed); // zig-lens-ignore: JSON-IN-FMT wrong-rule, should still fire
        \\}
        \\
    ;
    var r = try runOnWithFns(allocator, source, &.{
        .{
            .name = "verifySignature",
            .line = 1,
            .end_line = 3,
            .body_lines = 2,
            .params = "expected: []const u8,computed: []const u8",
            .return_type = "bool",
            .is_pub = false,
            .is_extern = false,
            .is_export = false,
            .doc_comment = "",
        },
    });
    defer freeReport(allocator, &r);
    var found = false;
    for (r.security_findings.items) |f| {
        if (std.mem.eql(u8, f.rule_id, "EQL-FOR-SECRETS")) found = true;
    }
    try std.testing.expect(found);
}
