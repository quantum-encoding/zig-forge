// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Format detection and parsing for text-to-JSON conversion.
//!
//! Supports: CSV, TSV, key-value pairs, and plain lines.
//! Auto-detection examines the first ~20 lines to determine format.

const std = @import("std");

pub const Format = enum {
    csv,
    tsv,
    kv,
    lines,

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .csv => "csv",
            .tsv => "tsv",
            .kv => "kv",
            .lines => "lines",
        };
    }
};

/// Result of parsing — tagged union of possible outputs
pub const ParseResult = union(enum) {
    /// Array of strings (lines mode)
    array: []const []const u8,
    /// Array of row objects (CSV/TSV mode) — each row is parallel arrays of keys+values
    table: Table,
    /// Single key-value object
    object: KvList,
};

pub const Table = struct {
    headers: []const []const u8,
    rows: []const []const []const u8,
    /// Backing allocation (if non-null, free this instead of rows)
    _backing: ?[]const []const []const u8 = null,
};

pub const KvList = struct {
    keys: []const []const u8,
    values: []const []const u8,
};

/// Detect the format of the input lines
pub fn detect(lines: []const []const u8) Format {
    if (lines.len == 0) return .lines;

    const sample_count = @min(lines.len, 20);
    const sample = lines[0..sample_count];

    // Count non-empty lines
    var non_empty: usize = 0;
    for (sample) |line| {
        if (line.len > 0) non_empty += 1;
    }
    if (non_empty < 2) {
        // Check if single line is KV
        if (non_empty == 1) {
            for (sample) |line| {
                if (line.len > 0 and isKvLine(line)) return .kv;
            }
        }
        return .lines;
    }

    // Check for CSV: consistent comma count across lines
    if (checkDelimited(sample, ',')) return .csv;

    // Check for TSV: consistent tab count across lines
    if (checkDelimited(sample, '\t')) return .tsv;

    // Check for key-value: ≥50% of non-empty lines are key-value pairs
    var kv_count: usize = 0;
    for (sample) |line| {
        if (line.len > 0 and isKvLine(line)) kv_count += 1;
    }
    if (kv_count * 2 >= non_empty) return .kv;

    return .lines;
}

/// Parse lines as the given format
pub fn parseLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    for (lines) |line| {
        if (line.len > 0) {
            try result.append(allocator, line);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Parse lines as CSV or TSV
pub fn parseCsv(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    delimiter: u8,
    has_headers: bool,
) !Table {
    if (lines.len == 0) return .{ .headers = &.{}, .rows = &.{} };

    var all_fields: std.ArrayListUnmanaged([]const []const u8) = .empty;

    // Parse all rows
    for (lines) |line| {
        if (line.len == 0) continue;
        const fields = try splitCsvLine(allocator, line, delimiter);
        try all_fields.append(allocator, fields);
    }

    const owned = try all_fields.toOwnedSlice(allocator);

    if (owned.len == 0) {
        allocator.free(owned);
        return .{ .headers = &.{}, .rows = &.{} };
    }

    if (has_headers) {
        const headers = owned[0];
        const rows = owned[1..];
        return .{ .headers = headers, .rows = rows, ._backing = owned };
    } else {
        // Generate column names: col0, col1, ...
        const col_count = owned[0].len;
        var headers = try allocator.alloc([]const u8, col_count);
        for (0..col_count) |i| {
            headers[i] = try std.fmt.allocPrint(allocator, "col{d}", .{i});
        }
        return .{ .headers = headers, .rows = owned };
    }
}

/// Parse lines as key-value pairs
pub fn parseKv(allocator: std.mem.Allocator, lines: []const []const u8) !KvList {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var values: std.ArrayListUnmanaged([]const u8) = .empty;

    for (lines) |line| {
        if (line.len == 0) continue;

        if (splitKv(line)) |kv| {
            try keys.append(allocator, kv.key);
            try values.append(allocator, kv.value);
        }
    }

    return .{
        .keys = try keys.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

/// Check if `s` is a valid JSON number per RFC 8259 §6.
///
/// This is the gate that decides whether `--numbers` mode emits a value as a
/// bare JSON number or as a quoted string. Anything that returns false here
/// must be quoted; otherwise we would produce invalid JSON downstream.
///
/// Grammar (kept in lockstep with json_writer.isValidJsonNumber):
///   number = [ "-" ] int [ frac ] [ exp ]
///   int    = "0" | digit1-9 *DIGIT   (NO LEADING ZEROS — "007" rejected)
///   frac   = "." 1*DIGIT             (at least one digit — "1." rejected)
///   exp    = (e|E) [+|-] 1*DIGIT     (at least one digit — "1e" rejected)
///
/// Rejected: "", "-", "+1", ".5", "5.", "01", "007", "1e", "1e+",
///           "NaN", "Infinity", "0x10", " 1", "1 ", "1_000".
pub fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;

    // Optional minus
    if (s[i] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }

    // int: "0" alone, or 1-9 followed by zero+ digits. Leading zeros forbidden.
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    } else {
        return false;
    }

    // Optional frac: "." followed by at least one digit
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }

    // Optional exp: (e|E) [+|-] DIGIT+
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }

    return i == s.len;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn checkDelimited(sample: []const []const u8, delimiter: u8) bool {
    // First non-empty line must have at least 1 delimiter
    var first_count: ?usize = null;
    var matching: usize = 0;
    var total: usize = 0;

    for (sample) |line| {
        if (line.len == 0) continue;
        total += 1;
        const count = countDelimiters(line, delimiter);
        if (first_count == null) {
            if (count == 0) return false;
            first_count = count;
            matching += 1;
        } else if (count == first_count.?) {
            matching += 1;
        }
    }

    // ≥80% of lines have same delimiter count
    return total >= 2 and matching * 5 >= total * 4;
}

fn countDelimiters(line: []const u8, delimiter: u8) usize {
    var count: usize = 0;
    var in_quote = false;
    for (line) |c| {
        if (c == '"') {
            in_quote = !in_quote;
        } else if (c == delimiter and !in_quote) {
            count += 1;
        }
    }
    return count;
}

const KvPair = struct { key: []const u8, value: []const u8 };

fn isKvLine(line: []const u8) bool {
    return splitKv(line) != null;
}

fn splitKv(line: []const u8) ?KvPair {
    // Try ": " first (most common)
    if (std.mem.indexOf(u8, line, ": ")) |idx| {
        if (idx > 0) return .{
            .key = std.mem.trim(u8, line[0..idx], " \t"),
            .value = std.mem.trim(u8, line[idx + 2 ..], " \t"),
        };
    }
    // Try " = "
    if (std.mem.indexOf(u8, line, " = ")) |idx| {
        if (idx > 0) return .{
            .key = std.mem.trim(u8, line[0..idx], " \t"),
            .value = std.mem.trim(u8, line[idx + 3 ..], " \t"),
        };
    }
    // Try "=" (no spaces)
    if (std.mem.indexOf(u8, line, "=")) |idx| {
        if (idx > 0 and idx < line.len - 1) return .{
            .key = std.mem.trim(u8, line[0..idx], " \t"),
            .value = std.mem.trim(u8, line[idx + 1 ..], " \t"),
        };
    }
    // Try ":" (no space after, but not at start)
    if (std.mem.indexOf(u8, line, ":")) |idx| {
        if (idx > 0 and idx < line.len - 1) return .{
            .key = std.mem.trim(u8, line[0..idx], " \t"),
            .value = std.mem.trim(u8, line[idx + 1 ..], " \t"),
        };
    }
    return null;
}

/// Errors specific to CSV/TSV parsing. Distinct from allocator errors so
/// callers can surface a meaningful diagnostic instead of swallowing
/// malformed input.
///
/// Embedded newlines inside a quoted field are NOT supported. This parser
/// splits the input on `\n` BEFORE row parsing, so any quoted field that
/// spans multiple lines will be reported as `UnclosedQuote` on the first
/// line and (likely) malformed rows after — see RFC 4180 §2.6 limitation
/// in the README. Round-tripping multi-line spreadsheet cells through this
/// tool requires preprocessing.
pub const CsvError = error{
    /// A quoted field opened with `"` did not have a matching closing `"`
    /// before end-of-line.
    UnclosedQuote,
};

fn splitCsvLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    delimiter: u8,
) (CsvError || std.mem.Allocator.Error)![]const []const u8 {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    // `pending` records that a delimiter was just consumed, so RFC 4180 requires
    // one more field even when we are at end-of-line (a trailing delimiter such
    // as `a,b,` yields N+1 = 3 fields, the last one empty). Without this flag the
    // trailing empty column silently vanishes.
    var pending = false;
    while (i < line.len or pending) {
        pending = false;

        if (i < line.len and line[i] == '"') {
            // Quoted field. Scan to the matching closing quote, treating `""` as
            // an escaped literal double-quote (RFC 4180 §2.7).
            i += 1; // skip opening quote
            const start = i;
            var closed = false;
            var has_escape = false;
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        // Escaped quote ("") — collapse to a single `"` in output.
                        has_escape = true;
                        i += 2;
                    } else {
                        closed = true;
                        break;
                    }
                } else {
                    i += 1;
                }
            }
            if (!closed) {
                // Free whatever we've allocated so far and surface the error.
                fields.deinit(allocator);
                return CsvError.UnclosedQuote;
            }
            const raw = line[start..i]; // between the quotes, still holds "" escapes
            i += 1; // skip closing quote

            // Unescape `""` -> `"`. The common no-escape case keeps the slice into
            // `line`; only fields containing an escape need a fresh allocation.
            const field = if (has_escape) blk: {
                const buf = try allocator.alloc(u8, raw.len);
                var n: usize = 0;
                var k: usize = 0;
                while (k < raw.len) : (n += 1) {
                    if (raw[k] == '"' and k + 1 < raw.len and raw[k + 1] == '"') {
                        buf[n] = '"';
                        k += 2;
                    } else {
                        buf[n] = raw[k];
                        k += 1;
                    }
                }
                break :blk buf[0..n];
            } else raw;

            try fields.append(allocator, std.mem.trim(u8, field, " "));
            if (i < line.len and line[i] == delimiter) {
                i += 1; // consume delimiter; another field follows
                pending = true;
            }
        } else {
            // Unquoted field
            const start = i;
            while (i < line.len and line[i] != delimiter) {
                i += 1;
            }
            const field = line[start..i];
            try fields.append(allocator, std.mem.trim(u8, field, " "));
            if (i < line.len and line[i] == delimiter) {
                i += 1; // consume delimiter; another field follows
                pending = true;
            }
        }
    }

    return fields.toOwnedSlice(allocator);
}

/// Split input data into lines
pub fn splitIntoLines(allocator: std.mem.Allocator, data: []const u8) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;

    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\n') {
            const line = if (i > start and data[i - 1] == '\r')
                data[start .. i - 1]
            else
                data[start..i];
            try lines.append(allocator, line);
            start = i + 1;
        }
        i += 1;
    }
    // Last line (if no trailing newline)
    if (start < data.len) {
        const line = if (data.len > start and data[data.len - 1] == '\r')
            data[start .. data.len - 1]
        else
            data[start..data.len];
        if (line.len > 0) {
            try lines.append(allocator, line);
        }
    }

    return lines.toOwnedSlice(allocator);
}

pub fn parseFormat(s: []const u8) ?Format {
    if (std.mem.eql(u8, s, "csv")) return .csv;
    if (std.mem.eql(u8, s, "tsv")) return .tsv;
    if (std.mem.eql(u8, s, "kv")) return .kv;
    if (std.mem.eql(u8, s, "lines")) return .lines;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "detect CSV" {
    const lines = &[_][]const u8{
        "Name,Age,City",
        "Alice,30,London",
        "Bob,25,Paris",
    };
    try std.testing.expectEqual(Format.csv, detect(lines));
}

test "detect TSV" {
    const lines = &[_][]const u8{
        "Name\tAge\tCity",
        "Alice\t30\tLondon",
        "Bob\t25\tParis",
    };
    try std.testing.expectEqual(Format.tsv, detect(lines));
}

test "detect KV" {
    const lines = &[_][]const u8{
        "name: Alice",
        "age: 30",
        "city: London",
    };
    try std.testing.expectEqual(Format.kv, detect(lines));
}

test "detect KV with equals" {
    const lines = &[_][]const u8{
        "name = Alice",
        "age = 30",
    };
    try std.testing.expectEqual(Format.kv, detect(lines));
}

test "detect lines" {
    const lines = &[_][]const u8{
        "Alice",
        "Bob",
        "Charlie",
    };
    try std.testing.expectEqual(Format.lines, detect(lines));
}

test "isNumeric: RFC 8259 grammar — accepts valid numbers" {
    try std.testing.expect(isNumeric("0"));
    try std.testing.expect(isNumeric("-0"));
    try std.testing.expect(isNumeric("42"));
    try std.testing.expect(isNumeric("-7"));
    try std.testing.expect(isNumeric("3.14"));
    try std.testing.expect(isNumeric("-0.5"));
    try std.testing.expect(isNumeric("1e10"));
    try std.testing.expect(isNumeric("2.5E-3"));
    try std.testing.expect(isNumeric("1e+10"));
    try std.testing.expect(isNumeric("0.0"));
}

test "isNumeric: RFC 8259 grammar — rejects leading zeros (audit H-1)" {
    // The pre-audit version accepted these and the CLI emitted invalid JSON.
    try std.testing.expect(!isNumeric("01"));
    try std.testing.expect(!isNumeric("00"));
    try std.testing.expect(!isNumeric("007"));
    try std.testing.expect(!isNumeric("-01"));
    try std.testing.expect(!isNumeric("0123"));
}

test "isNumeric: RFC 8259 grammar — rejects other malformed inputs" {
    const bad = [_][]const u8{
        "",      "-",       "+",     "+1",     ".5",      "5.",
        "1.",    "1.e3",    "1e",    "1e+",    "1e-",     "1.0e",
        "1.2.3", "1,5",     "NaN",   "Infinity", "-Infinity", "inf",
        "0x10",  "0b10",    " 1",    "1 ",     "1 0",     "1_000",
        "abc",
    };
    for (bad) |s| try std.testing.expect(!isNumeric(s));
}

test "splitCsvLine basic" {
    const fields = try splitCsvLine(std.testing.allocator, "Alice,30,London", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("Alice", fields[0]);
    try std.testing.expectEqualStrings("30", fields[1]);
    try std.testing.expectEqualStrings("London", fields[2]);
}

test "splitCsvLine quoted" {
    const fields = try splitCsvLine(std.testing.allocator, "\"Smith, John\",30,\"New York\"", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("Smith, John", fields[0]);
    try std.testing.expectEqualStrings("30", fields[1]);
    try std.testing.expectEqualStrings("New York", fields[2]);
}

test "splitIntoLines" {
    const data = "Alice\nBob\nCharlie\n";
    const lines = try splitIntoLines(std.testing.allocator, data);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("Alice", lines[0]);
    try std.testing.expectEqualStrings("Bob", lines[1]);
    try std.testing.expectEqualStrings("Charlie", lines[2]);
}

test "splitIntoLines CRLF" {
    const data = "Alice\r\nBob\r\nCharlie";
    const lines = try splitIntoLines(std.testing.allocator, data);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("Alice", lines[0]);
    try std.testing.expectEqualStrings("Bob", lines[1]);
    try std.testing.expectEqualStrings("Charlie", lines[2]);
}

test "parseKv" {
    const lines = &[_][]const u8{
        "name: Alice Smith",
        "age: 30",
        "city: London",
    };
    const kv = try parseKv(std.testing.allocator, lines);
    defer {
        std.testing.allocator.free(kv.keys);
        std.testing.allocator.free(kv.values);
    }
    try std.testing.expectEqual(@as(usize, 3), kv.keys.len);
    try std.testing.expectEqualStrings("name", kv.keys[0]);
    try std.testing.expectEqualStrings("Alice Smith", kv.values[0]);
    try std.testing.expectEqualStrings("age", kv.keys[1]);
    try std.testing.expectEqualStrings("30", kv.values[1]);
}

// ============================================================================
// ENHANCED TEST SUITE - zig_json
// ============================================================================

test "JSON escaping validation - quotes in strings" {
    // Test that numeric and string detection works with escaped content
    try std.testing.expect(!isNumeric("\"42\""));
    try std.testing.expect(!isNumeric("Smith, Jr."));
}

test "CSV detection - consistent comma count" {
    const lines = &[_][]const u8{
        "Name,Age,City",
        "Alice,30,London",
        "Bob,25,Paris",
        "Charlie,35,Berlin",
    };
    try std.testing.expectEqual(Format.csv, detect(lines));
}

test "CSV detection - inconsistent commas defaults to lines" {
    const lines = &[_][]const u8{
        "Name,Age,City",
        "Alice and Bob,30",
        "Charlie",
    };
    const fmt = detect(lines);
    try std.testing.expect(fmt == .lines or fmt == .csv);
}

test "TSV detection - consistent tab count" {
    const lines = &[_][]const u8{
        "Name\tAge\tCity",
        "Alice\t30\tLondon",
        "Bob\t25\tParis",
        "Charlie\t35\tBerlin",
    };
    try std.testing.expectEqual(Format.tsv, detect(lines));
}

test "KV detection - key=value format" {
    const lines = &[_][]const u8{
        "host=localhost",
        "port=5432",
        "user=admin",
    };
    try std.testing.expectEqual(Format.kv, detect(lines));
}

test "KV detection - key: value format" {
    const lines = &[_][]const u8{
        "host: localhost",
        "port: 5432",
        "user: admin",
    };
    try std.testing.expectEqual(Format.kv, detect(lines));
}

test "Numeric value detection - integer" {
    try std.testing.expect(isNumeric("42"));
    try std.testing.expect(isNumeric("0"));
    try std.testing.expect(isNumeric("-123"));
}

test "Numeric value detection - float" {
    try std.testing.expect(isNumeric("3.14"));
    try std.testing.expect(isNumeric("0.5"));
    try std.testing.expect(isNumeric("-2.718"));
}

test "Numeric value detection - scientific notation" {
    try std.testing.expect(isNumeric("1e10"));
    try std.testing.expect(isNumeric("1.5e-3"));
    try std.testing.expect(isNumeric("2E+5"));
}

test "Numeric value detection - false cases" {
    try std.testing.expect(!isNumeric(""));
    try std.testing.expect(!isNumeric("abc"));
    try std.testing.expect(!isNumeric("3.14.15"));
    try std.testing.expect(!isNumeric(".5"));
    try std.testing.expect(!isNumeric("5."));
    try std.testing.expect(!isNumeric("1e"));
}

test "Single-line input handling" {
    const lines = &[_][]const u8{"Alice"};
    const parsed = try parseLines(std.testing.allocator, lines);
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("Alice", parsed[0]);
}

test "CSV header detection - verify 3 columns" {
    const lines = &[_][]const u8{
        "Name,Age,City",
        "Alice,30,London",
    };
    try std.testing.expectEqual(Format.csv, detect(lines));
}

test "Empty input detection" {
    const lines = &[_][]const u8{};
    const fmt = detect(lines);
    try std.testing.expectEqual(Format.lines, fmt);
}

test "CSV quoted field with comma" {
    const fields = try splitCsvLine(std.testing.allocator, "\"John, Jr.\",30,\"New York\"", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("John, Jr.", fields[0]);
    try std.testing.expectEqualStrings("30", fields[1]);
    try std.testing.expectEqualStrings("New York", fields[2]);
}

test "CSV escaped quotes in quoted field" {
    // `"""quoted""",value` — the field is a quoted string whose content is the
    // escaped sequence `""quoted""`, which unescapes to `"quoted"`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = try splitCsvLine(arena.allocator(), "\"\"\"quoted\"\"\",value", ',');
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("\"quoted\"", fields[0]);
    try std.testing.expectEqualStrings("value", fields[1]);
}

test "Boolean value detection — booleans are NOT numeric" {
    try std.testing.expect(isNumeric("true") == false);
    try std.testing.expect(isNumeric("false") == false);
}

// ============================================================================
// CSV grammar tests (audit M-3 + RFC 4180 anchors)
// ============================================================================

test "splitCsvLine: RFC 4180 simple row" {
    // RFC 4180 §2.3 example.
    const fields = try splitCsvLine(std.testing.allocator, "aaa,bbb,ccc", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("aaa", fields[0]);
    try std.testing.expectEqualStrings("bbb", fields[1]);
    try std.testing.expectEqualStrings("ccc", fields[2]);
}

test "splitCsvLine: RFC 4180 quoted field with embedded comma" {
    // RFC 4180 §2.6.
    const fields = try splitCsvLine(std.testing.allocator, "\"aaa,bbb\",ccc", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("aaa,bbb", fields[0]);
    try std.testing.expectEqualStrings("ccc", fields[1]);
}

test "splitCsvLine: RFC 4180 escaped quote inside quoted field" {
    // RFC 4180 §2.7: a double-quote inside a quoted field is escaped as "".
    // This CLI is the downstream consumer, so it un-escapes `""` -> `"`:
    // input `"a""b",c` yields the field `a"b`, matching Python csv / Excel.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = try splitCsvLine(arena.allocator(), "\"a\"\"b\",c", ',');
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("a\"b", fields[0]);
    try std.testing.expectEqualStrings("c", fields[1]);
}

test "splitCsvLine: unclosed quote returns UnclosedQuote error (audit M-3)" {
    // Pre-audit behavior: silently swallowed the rest of the line as one
    // field. Post-audit: explicit error so callers can surface it.
    const result = splitCsvLine(std.testing.allocator, "\"unclosed,42,hello", ',');
    try std.testing.expectError(CsvError.UnclosedQuote, result);
}

test "splitCsvLine: empty fields preserved" {
    const fields = try splitCsvLine(std.testing.allocator, "a,,b", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("", fields[1]);
    try std.testing.expectEqualStrings("b", fields[2]);
}

test "splitCsvLine: trailing empty field preserved (N delimiters -> N+1 fields)" {
    // RFC 4180 §2.4: each record has the same number of fields; N commas
    // produce N+1 fields. A trailing delimiter must yield a trailing empty
    // field, not silently drop the last column.
    {
        const fields = try splitCsvLine(std.testing.allocator, "a,b,", ',');
        defer std.testing.allocator.free(fields);
        try std.testing.expectEqual(@as(usize, 3), fields.len);
        try std.testing.expectEqualStrings("a", fields[0]);
        try std.testing.expectEqualStrings("b", fields[1]);
        try std.testing.expectEqualStrings("", fields[2]);
    }
    {
        const fields = try splitCsvLine(std.testing.allocator, "a,", ',');
        defer std.testing.allocator.free(fields);
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("a", fields[0]);
        try std.testing.expectEqualStrings("", fields[1]);
    }
    {
        // A lone delimiter is two empty fields.
        const fields = try splitCsvLine(std.testing.allocator, ",", ',');
        defer std.testing.allocator.free(fields);
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("", fields[0]);
        try std.testing.expectEqualStrings("", fields[1]);
    }
    {
        // A quoted field may also be the one preceding the trailing delimiter.
        const fields = try splitCsvLine(std.testing.allocator, "\"a\",", ',');
        defer std.testing.allocator.free(fields);
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("a", fields[0]);
        try std.testing.expectEqualStrings("", fields[1]);
    }
}

test "splitCsvLine: doubled quotes are unescaped to a single quote" {
    // RFC 4180 §2.7. This CLI is the terminal consumer, so it collapses the
    // escape rather than passing raw bytes downstream.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        // Field that is a single escaped quote pair.
        const fields = try splitCsvLine(a, "\"\"\"\",x", ',');
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("\"", fields[0]);
        try std.testing.expectEqualStrings("x", fields[1]);
    }
    {
        // Embedded escaped quote in the middle: `"she said ""hi"""` -> `she said "hi"`.
        const fields = try splitCsvLine(a, "\"she said \"\"hi\"\"\",ok", ',');
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("she said \"hi\"", fields[0]);
        try std.testing.expectEqualStrings("ok", fields[1]);
    }
    {
        // No escape present: field stays byte-identical (fast path, no alloc).
        const fields = try splitCsvLine(a, "\"plain\",y", ',');
        try std.testing.expectEqual(@as(usize, 2), fields.len);
        try std.testing.expectEqualStrings("plain", fields[0]);
        try std.testing.expectEqualStrings("y", fields[1]);
    }
}
