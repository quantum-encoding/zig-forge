//! Prometheus text-exposition escaping helpers.
//!
//! The Prometheus text format requires escaping certain characters when a
//! caller-controlled string is spliced into the exposition output. Splicing
//! raw label values or HELP text via `{s}` corrupts the whole scrape page the
//! moment the value contains a `"`, `\`, or newline (the scraper rejects the
//! entire exposition, or series get misattributed) — the exposition-format
//! analog of JSON injection.
//!
//! Escaping rules (Prometheus text format / OpenMetrics):
//!   - label values: escape `\` -> `\\`, `"` -> `\"`, LF -> `\n`
//!   - HELP text:    escape `\` -> `\\`, LF -> `\n`  (double quotes are literal)

const std = @import("std");

/// Write a label value with Prometheus label-value escaping. The surrounding
/// double quotes are NOT written here — the caller emits them.
pub fn writeEscapedLabelValue(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write HELP text with Prometheus HELP escaping (backslash and newline only).
pub fn writeEscapedHelp(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            else => try writer.writeByte(c),
        }
    }
}

test "label value escaping" {
    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeEscapedLabelValue(&writer.writer, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", writer.written());
}

test "help escaping" {
    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    // Double quotes are literal in HELP; backslash and newline are escaped.
    try writeEscapedHelp(&writer.writer, "he\"llo\\wor\nld");
    try std.testing.expectEqualStrings("he\"llo\\\\wor\\nld", writer.written());
}
