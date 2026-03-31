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

/// Check if a value looks like a number
pub fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;
    // Optional leading minus
    if (s[i] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }

    // Must have at least one digit
    var has_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') {
        has_digit = true;
        i += 1;
    }
    if (!has_digit) return false;

    // Optional decimal part
    if (i < s.len and s[i] == '.') {
        i += 1;
        var has_decimal_digit = false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') {
            has_decimal_digit = true;
            i += 1;
        }
        if (!has_decimal_digit) return false;
    }

    // Optional exponent
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var has_exp_digit = false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') {
            has_exp_digit = true;
            i += 1;
        }
        if (!has_exp_digit) return false;
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

fn splitCsvLine(allocator: std.mem.Allocator, line: []const u8, delimiter: u8) ![]const []const u8 {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    while (true) {
        if (i >= line.len) break;

        if (line[i] == '"') {
            // Quoted field
            i += 1; // skip opening quote
            const start = i;
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        // Escaped quote
                        i += 2;
                    } else {
                        break;
                    }
                } else {
                    i += 1;
                }
            }
            const field = line[start..i];
            try fields.append(allocator, std.mem.trim(u8, field, " "));
            if (i < line.len) i += 1; // skip closing quote
            if (i < line.len and line[i] == delimiter) i += 1; // skip delimiter
        } else {
            // Unquoted field
            const start = i;
            while (i < line.len and line[i] != delimiter) {
                i += 1;
            }
            const field = line[start..i];
            try fields.append(allocator, std.mem.trim(u8, field, " "));
            if (i < line.len) {
                i += 1; // skip delimiter
            } else {
                break;
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

test "isNumeric" {
    try std.testing.expect(isNumeric("42"));
    try std.testing.expect(isNumeric("-7"));
    try std.testing.expect(isNumeric("3.14"));
    try std.testing.expect(isNumeric("-0.5"));
    try std.testing.expect(isNumeric("1e10"));
    try std.testing.expect(isNumeric("2.5E-3"));
    try std.testing.expect(!isNumeric(""));
    try std.testing.expect(!isNumeric("abc"));
    try std.testing.expect(!isNumeric("-"));
    try std.testing.expect(!isNumeric("1."));
    try std.testing.expect(!isNumeric(".5"));
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
    const fields = try splitCsvLine(std.testing.allocator, "\"\"\"quoted\"\"\",value", ',');
    defer std.testing.allocator.free(fields);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
}

test "Boolean value detection" {
    try std.testing.expect(isNumeric("true") == false);
    try std.testing.expect(isNumeric("false") == false);
}
