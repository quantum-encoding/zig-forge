//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// emoji_sanitizer.zig - Emoji Steganography Detection & Sanitization
// Purpose: Detect and sanitize maliciously crafted emoji with hidden payloads
//
// Threat Model:
//   - Attackers embed extra bytes in emoji to hide shellcode, commands, or data
//   - Visual inspection fails because emoji renders normally
//   - Steganography bypasses traditional content filters
//
// Defense Strategy:
//   - Maintain canonical hashmap of emoji → expected UTF-8 byte length
//   - Validate all incoming emoji against canonical sizes
//   - Strip/replace emoji that don't match expected lengths
//   - Log anomalies for forensic analysis

const std = @import("std");
const time_compat = @import("time_compat.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const emoji_db = @import("emoji_database.zig");

/// Maximum UTF-8 bytes for any single emoji (accounting for ZWJ sequences)
pub const MAX_EMOJI_BYTES: usize = 32;

/// Result of emoji validation
pub const ValidationResult = enum {
    valid,           // Emoji matches canonical size
    oversized,       // Emoji has extra hidden bytes
    undersized,      // Emoji is truncated/malformed
    not_emoji,       // Not recognized as emoji
    zwc_smuggling,   // Dispersed zero-width character smuggling detected
    tag_smuggling,   // Unicode Tag-block (U+E0000–E007F) invisible-ASCII smuggling
};

/// Emoji validation info
pub const EmojiInfo = struct {
    codepoint: u32,           // Unicode codepoint (or first codepoint for sequences)
    expected_bytes: u8,       // Canonical UTF-8 byte length
    actual_bytes: usize,      // Actual bytes found
    result: ValidationResult,
    offset: usize = 0,        // Byte offset in text where found
    timestamp: i64 = 0,       // Unix timestamp of detection
    zwc_count: usize = 0,     // Zero-width character count
    zwc_density: f64 = 0.0,   // ZWC bytes / total bytes ratio
};

/// Get the expected byte length for an emoji (delegates to database)
pub fn getExpectedLength(emoji: []const u8) ?u8 {
    return emoji_db.getExpectedLength(emoji);
}

/// Get current Unix timestamp
fn getTimestamp() i64 {
    return time_compat.timestamp();
}

/// Validate a single emoji with optional offset and timestamp
pub fn validateEmoji(emoji: []const u8) EmojiInfo {
    return validateEmojiWithContext(emoji, 0);
}

/// Validate emoji with context (offset in text)
pub fn validateEmojiWithContext(emoji: []const u8, offset: usize) EmojiInfo {
    const actual_bytes = emoji.len;
    const timestamp = getTimestamp();

    // Strategy: Try to find a matching emoji prefix in the database
    // Start from longest possible match and work backwards
    var test_len: usize = @min(actual_bytes, MAX_EMOJI_BYTES);
    while (test_len > 0) : (test_len -= 1) {
        const test_slice = emoji[0..test_len];
        if (getExpectedLength(test_slice)) |expected| {
            // Found a match! Now check if actual input has extra bytes
            const result: ValidationResult = if (actual_bytes == expected)
                .valid
            else if (actual_bytes > expected)
                .oversized
            else
                .undersized;

            return EmojiInfo{
                .codepoint = getFirstCodepoint(test_slice) orelse 0,
                .expected_bytes = expected,
                .actual_bytes = actual_bytes,
                .result = result,
                .offset = offset,
                .timestamp = timestamp,
            };
        }
    }

    // Not in database - try to determine if it's emoji
    if (looksLikeEmoji(emoji)) {
        return EmojiInfo{
            .codepoint = getFirstCodepoint(emoji) orelse 0,
            .expected_bytes = @intCast(actual_bytes), // Assume current is correct
            .actual_bytes = actual_bytes,
            .result = .valid,
            .offset = offset,
            .timestamp = timestamp,
        };
    }

    return EmojiInfo{
        .codepoint = 0,
        .expected_bytes = 0,
        .actual_bytes = actual_bytes,
        .result = .not_emoji,
        .offset = offset,
        .timestamp = timestamp,
    };
}

/// Extract first Unicode codepoint from UTF-8 sequence
fn getFirstCodepoint(utf8: []const u8) ?u32 {
    if (utf8.len == 0) return null;

    const first_byte = utf8[0];

    // 1-byte (ASCII): 0xxxxxxx
    if (first_byte & 0x80 == 0) {
        return first_byte;
    }

    // 2-byte: 110xxxxx 10xxxxxx
    if (first_byte & 0xE0 == 0xC0 and utf8.len >= 2) {
        return (@as(u32, first_byte & 0x1F) << 6) |
               (@as(u32, utf8[1] & 0x3F));
    }

    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
    if (first_byte & 0xF0 == 0xE0 and utf8.len >= 3) {
        return (@as(u32, first_byte & 0x0F) << 12) |
               (@as(u32, utf8[1] & 0x3F) << 6) |
               (@as(u32, utf8[2] & 0x3F));
    }

    // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if (first_byte & 0xF8 == 0xF0 and utf8.len >= 4) {
        return (@as(u32, first_byte & 0x07) << 18) |
               (@as(u32, utf8[1] & 0x3F) << 12) |
               (@as(u32, utf8[2] & 0x3F) << 6) |
               (@as(u32, utf8[3] & 0x3F));
    }

    return null;
}

/// Heuristic check if bytes look like emoji
fn looksLikeEmoji(utf8: []const u8) bool {
    const codepoint = getFirstCodepoint(utf8) orelse return false;

    // Common emoji ranges
    // Emoticons: U+1F600-1F64F
    // Miscellaneous Symbols: U+2600-26FF
    // Dingbats: U+2700-27BF
    // Miscellaneous Symbols and Pictographs: U+1F300-1F5FF
    // Transport and Map: U+1F680-1F6FF
    // Supplemental Symbols: U+1F900-1F9FF

    if (codepoint >= 0x1F600 and codepoint <= 0x1F64F) return true; // Emoticons
    if (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) return true; // Misc symbols
    if (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) return true; // Transport
    if (codepoint >= 0x1F900 and codepoint <= 0x1F9FF) return true; // Supplemental
    if (codepoint >= 0x2600 and codepoint <= 0x26FF) return true;   // Misc symbols
    if (codepoint >= 0x2700 and codepoint <= 0x27BF) return true;   // Dingbats

    return false;
}

// ============================================================
// ZERO-WIDTH CHARACTER SMUGGLING DETECTION
// Defense against dispersed payload attacks via U+200B, U+200C, etc.
// ============================================================

/// Check if position in text is a zero-width character
fn isZeroWidthChar(text: []const u8, pos: usize) bool {
    if (pos + 2 >= text.len) return false;

    const b1 = text[pos];
    const b2 = text[pos + 1];
    const b3 = text[pos + 2];

    // U+200B (Zero Width Space): E2 80 8B
    // U+200C (Zero Width Non-Joiner): E2 80 8C
    // U+200D (Zero Width Joiner): E2 80 8D
    if (b1 == 0xE2 and b2 == 0x80 and (b3 == 0x8B or b3 == 0x8C or b3 == 0x8D)) {
        return true;
    }

    // U+FEFF (Zero Width No-Break Space / BOM): EF BB BF
    if (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF) {
        return true;
    }

    return false;
}

// ============================================================
// UNICODE TAG-BLOCK SMUGGLING DETECTION
// Defense against invisible ASCII hidden in U+E0000–U+E007F "Tag" characters —
// the best-known text-smuggling vector (an entire hidden instruction can ride
// inside what renders as a single visible glyph, defeating human review).
// ============================================================

/// Is the 4-byte UTF-8 sequence at `pos` a Unicode Tag character
/// (U+E0000–U+E007F, encoded F3 A0 {80,81} {80–BF})?
fn isUnicodeTagChar(text: []const u8, pos: usize) bool {
    if (pos + 3 >= text.len) return false;
    return text[pos] == 0xF3 and text[pos + 1] == 0xA0 and
        (text[pos + 2] == 0x80 or text[pos + 2] == 0x81) and
        (text[pos + 3] >= 0x80 and text[pos + 3] <= 0xBF);
}

pub const TagScan = struct {
    /// Total Tag characters seen.
    count: usize = 0,
    /// True if any Tag character appears OUTSIDE a well-formed emoji tag
    /// sequence (the only legitimate use).
    suspicious: bool = false,
};

/// Scan for Unicode Tag characters and decide whether any are used for
/// smuggling. The ONLY legitimate use of Tag chars is an emoji tag sequence
/// (regional-subdivision flags like 🏴󠁧󠁢󠁳󠁣󠁴󠁿): a 🏴 base (U+1F3F4, bytes
/// F0 9F 8F B4) followed by ≤6 Tag chars and a U+E007F cancel tag (F3 A0 81 BF).
/// A Tag run that isn't preceded by 🏴, isn't cancel-terminated, or is longer
/// than a flag sequence is treated as smuggling.
pub fn scanUnicodeTags(text: []const u8) TagScan {
    var scan: TagScan = .{};
    var i: usize = 0;
    while (i < text.len) {
        if (!isUnicodeTagChar(text, i)) {
            i += 1;
            continue;
        }
        const preceded_by_black_flag = i >= 4 and
            text[i - 4] == 0xF0 and text[i - 3] == 0x9F and
            text[i - 2] == 0x8F and text[i - 1] == 0xB4;
        var run: usize = 0;
        var ends_with_cancel = false;
        while (i < text.len and isUnicodeTagChar(text, i)) {
            // U+E007F cancel tag = F3 A0 81 BF
            ends_with_cancel = text[i + 2] == 0x81 and text[i + 3] == 0xBF;
            run += 1;
            scan.count += 1;
            i += 4;
        }
        if (!(preceded_by_black_flag and ends_with_cancel and run <= 7)) {
            scan.suspicious = true;
        }
    }
    return scan;
}

/// Count zero-width characters in text
pub fn countZeroWidthChars(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (isZeroWidthChar(text, i)) {
            count += 1;
            i += 3; // Skip the 3-byte ZWC sequence
        } else {
            i += 1;
        }
    }

    return count;
}

/// Calculate zero-width character density (ZWC bytes / total bytes)
pub fn calculateZWCDensity(text: []const u8) f64 {
    if (text.len == 0) return 0.0;

    const zwc_count = countZeroWidthChars(text);
    const zwc_bytes = zwc_count * 3; // Each ZWC = 3 UTF-8 bytes

    return @as(f64, @floatFromInt(zwc_bytes)) / @as(f64, @floatFromInt(text.len));
}

/// Scan text and find all suspicious emoji
pub fn scanText(allocator: std.mem.Allocator, text: []const u8) ![]const EmojiInfo {
    var anomalies = std.ArrayList(EmojiInfo).empty;

    // CRITICAL: Check for zero-width character smuggling FIRST
    // This detects dispersed payload attacks (e.g., unicode-injector --disperse)
    const zwc_count = countZeroWidthChars(text);
    const zwc_density = calculateZWCDensity(text);

    // Thresholds based on adversarial emulation results:
    // - Normal text: ~0-1 ZWC (joiners in emoji)
    // - Smuggled payload: 78+ ZWC with 91.8% density
    const ZWC_COUNT_THRESHOLD: usize = 5;      // Flag if >5 ZWC
    const ZWC_DENSITY_THRESHOLD: f64 = 0.10;   // Flag if >10% density

    if (zwc_count > ZWC_COUNT_THRESHOLD or zwc_density > ZWC_DENSITY_THRESHOLD) {
        // THREAT DETECTED: Dispersed payload smuggling
        try anomalies.append(allocator, EmojiInfo{
            .codepoint = 0x200B, // Representative ZWC codepoint
            .expected_bytes = 0,
            .actual_bytes = text.len,
            .result = .zwc_smuggling,
            .offset = 0,
            .timestamp = getTimestamp(),
            .zwc_count = zwc_count,
            .zwc_density = zwc_density,
        });
    }

    // CRITICAL: Check for Unicode Tag-block smuggling (U+E0000–E007F).
    // Unlike ZWCs these are 4-byte codepoints outside the emoji ranges, so the
    // per-emoji scan below never sees them; a single flag of a non-emoji Tag
    // run is enough (legitimate 🏴 flag sequences are excluded by scanUnicodeTags).
    const tag_scan = scanUnicodeTags(text);
    if (tag_scan.suspicious) {
        const tag_bytes = tag_scan.count * 4;
        try anomalies.append(allocator, EmojiInfo{
            .codepoint = 0xE0000, // Representative Tag-block codepoint
            .expected_bytes = 0,
            .actual_bytes = tag_bytes,
            .result = .tag_smuggling,
            .offset = 0,
            .timestamp = getTimestamp(),
            .zwc_count = tag_scan.count,
            .zwc_density = if (text.len > 0)
                @as(f64, @floatFromInt(tag_bytes)) / @as(f64, @floatFromInt(text.len))
            else
                0.0,
        });
    }

    var i: usize = 0;
    while (i < text.len) {
        const remaining = text[i..];
        const first_byte = remaining[0];

        // Check if this looks like an emoji codepoint
        const seq_len = getUtf8SequenceLength(first_byte);
        if (seq_len == 0) {
            i += 1;
            continue;
        }

        if (i + seq_len > text.len) break;

        // Check if first codepoint is emoji-range
        _ = getFirstCodepoint(remaining[0..seq_len]) orelse {
            i += 1;
            continue;
        };

        if (!looksLikeEmoji(remaining[0..seq_len])) {
            i += 1;
            continue;
        }

        // This is an emoji! Extract maximum window for steganography detection
        var window_len = seq_len;

        // Extend to include variation selectors, ZWJ sequences, modifiers
        // Keep going until we hit a clear boundary
        while (window_len < remaining.len and window_len < MAX_EMOJI_BYTES) {
            const next_byte = remaining[window_len];

            // Stop at ASCII whitespace/punctuation (clear boundaries)
            if (next_byte == ' ' or next_byte == '!' or next_byte == '.' or
                next_byte == ',' or next_byte == '\n' or next_byte == '\t' or
                next_byte == '?' or next_byte == ';' or next_byte == ':') {
                break;
            }

            // Stop if we hit another emoji-like start
            if (next_byte >= 0xF0 and (next_byte & 0xF8) == 0xF0) {
                // This is a 4-byte UTF-8 start (likely another emoji)
                break;
            }

            window_len += 1;
        }

        const sequence = remaining[0..window_len];
        const info = validateEmojiWithContext(sequence, i);

        // Report anomalies
        if (info.result == .oversized or info.result == .undersized) {
            try anomalies.append(allocator, info);
        }

        // Advance by the expected emoji length if known
        i += if (info.expected_bytes > 0) info.expected_bytes else seq_len;
    }

    return anomalies.toOwnedSlice(allocator);
}

/// Forensic logging: Write anomaly to JSON log
pub fn logAnomaly(writer: anytype, info: EmojiInfo, source: []const u8) !void {
    try writer.interface.print("{{\"event\":\"emoji_anomaly\",", .{});
    try writer.interface.print("\"timestamp\":{d},", .{info.timestamp});
    try writer.interface.print("\"codepoint\":\"U+{X:0>4}\",", .{info.codepoint});
    try writer.interface.print("\"expected_bytes\":{d},", .{info.expected_bytes});
    try writer.interface.print("\"actual_bytes\":{d},", .{info.actual_bytes});
    try writer.interface.print("\"result\":\"{s}\",", .{@tagName(info.result)});
    try writer.interface.print("\"offset\":{d},", .{info.offset});
    try writer.interface.print("\"source\":\"{s}\"", .{source});
    try writer.interface.print("}}\n", .{});
}

/// Forensic logging: Write all anomalies to file
pub fn logAnomalies(allocator: std.mem.Allocator, anomalies: []const EmojiInfo, log_path: []const u8, source: []const u8) !void {
    _ = allocator;
    // Create null-terminated path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (log_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..log_path.len], log_path);
    path_buf[log_path.len] = 0;

    // Open file for append (create if doesn't exist)
    const fd = c.open(@ptrCast(&path_buf), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenError;
    defer _ = c.close(fd);

    // Format and write each anomaly directly
    for (anomalies) |anomaly| {
        var codepoint_buf: [16]u8 = undefined;
        const codepoint_str = try std.fmt.bufPrint(&codepoint_buf, "U+{X:0>4}", .{anomaly.codepoint});

        var line_buf: [512]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&line_buf);
        var jw: std.json.Stringify = .{ .writer = &fbs, .options = .{} };
        try jw.write(.{
            .event = "emoji_anomaly",
            .timestamp = anomaly.timestamp,
            .codepoint = codepoint_str,
            .expected_bytes = anomaly.expected_bytes,
            .actual_bytes = anomaly.actual_bytes,
            .result = @tagName(anomaly.result),
            .offset = anomaly.offset,
            .source = source,
        });
        try fbs.writeByte('\n');
        const written = fbs.buffered();

        const write_result = c.write(fd, written.ptr, written.len);
        if (write_result < 0) return error.WriteError;
    }
}

/// Get UTF-8 sequence length from first byte
fn getUtf8SequenceLength(first_byte: u8) usize {
    if (first_byte & 0x80 == 0) return 1;      // 0xxxxxxx
    if (first_byte & 0xE0 == 0xC0) return 2;   // 110xxxxx
    if (first_byte & 0xF0 == 0xE0) return 3;   // 1110xxxx
    if (first_byte & 0xF8 == 0xF0) return 4;   // 11110xxx
    return 0; // Invalid
}

/// Sanitize text by replacing malicious emoji with placeholders
pub fn sanitizeText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;

    var i: usize = 0;
    while (i < text.len) {
        const remaining = text[i..];
        const seq_len = getUtf8SequenceLength(remaining[0]);

        if (seq_len == 0) {
            try result.append(allocator, remaining[0]);
            i += 1;
            continue;
        }

        if (i + seq_len > text.len) break;

        // Extract a larger window to catch steganography attacks. Break only at
        // a clear boundary (ASCII whitespace/punctuation) or the start of
        // another base emoji (4-byte UTF-8 start) — the SAME rule detectAnomalies
        // uses above. Crucially, do NOT break at 3-byte UTF-8 start bytes: a
        // variation selector (U+FE0F: EF B8 8F) or ZWJ (U+200D: E2 80 8D) is part
        // of THIS emoji. Breaking there split the emoji from its trailing bytes
        // and let a `<emoji>\x00\x00<payload>` steganography sequence slip past
        // validateEmoji as a bare (valid) base emoji, unredacted.
        var window_len = seq_len;
        while (window_len < remaining.len and window_len < MAX_EMOJI_BYTES) {
            const next_byte = remaining[window_len];
            // Stop at ASCII whitespace/punctuation (clear boundaries)
            if (next_byte == ' ' or next_byte == '!' or next_byte == '.' or
                next_byte == ',' or next_byte == '\n' or next_byte == '\t' or
                next_byte == '?' or next_byte == ';' or next_byte == ':') {
                break;
            }
            // Stop at the start of another base emoji (4-byte UTF-8 start)
            if (next_byte >= 0xF0 and (next_byte & 0xF8) == 0xF0) {
                break;
            }
            window_len += 1;
        }

        const sequence = remaining[0..window_len];
        const info = validateEmoji(sequence);

        // Replace suspicious emoji with [REDACTED]
        if (info.result == .oversized or info.result == .undersized) {
            try result.appendSlice(allocator, "[REDACTED]");
            // Skip the entire malicious sequence
            i += window_len;
        } else {
            // Keep the valid emoji (use expected_bytes if available)
            const safe_len = if (info.expected_bytes > 0) info.expected_bytes else seq_len;
            try result.appendSlice(allocator, remaining[0..safe_len]);
            i += safe_len;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================
// Tests
// ============================================================

test "validate known emoji" {
    const shield = validateEmoji("🛡️");
    try std.testing.expectEqual(ValidationResult.valid, shield.result);
    try std.testing.expectEqual(@as(u8, 7), shield.expected_bytes);
}

test "detect oversized emoji" {
    // Simulate emoji with hidden payload
    const malicious = "🛡️\x00\x00\x00PAYLOAD";
    const info = validateEmoji(malicious);
    try std.testing.expectEqual(ValidationResult.oversized, info.result);
}

test "sanitize malicious text" {
    const allocator = std.testing.allocator;
    const dirty = "Hello 🛡️\x00\x00HIDDEN world!";
    const clean = try sanitizeText(allocator, dirty);
    defer allocator.free(clean);

    try std.testing.expect(std.mem.indexOf(u8, clean, "[REDACTED]") != null);
}

test "detect unicode tag smuggling" {
    // "hi" hidden as Tag characters U+E0068 U+E0069 (F3 A0 81 A8 / F3 A0 81 A9)
    // — invisible ASCII with no 🏴 base and no cancel terminator. This is the
    // canonical Unicode tag-smuggling encoding used to hide instructions/data
    // inside otherwise-innocuous text.
    const smuggled = "review this\xF3\xA0\x81\xA8\xF3\xA0\x81\xA9";
    const scan = scanUnicodeTags(smuggled);
    try std.testing.expect(scan.suspicious);
    try std.testing.expectEqual(@as(usize, 2), scan.count);
}

test "legitimate flag tag sequence is not smuggling" {
    // Scotland flag 🏴󠁧󠁢󠁳󠁣󠁴󠁿: 🏴 base (F0 9F 8F B4) + Tag chars g/b/s/c/t +
    // U+E007F cancel tag (F3 A0 81 BF). A well-formed emoji tag sequence must
    // NOT be flagged — this guards against false positives on regional flags.
    const scotland = "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xB3\xF3\xA0\x81\xA3\xF3\xA0\x81\xB4\xF3\xA0\x81\xBF";
    const scan = scanUnicodeTags(scotland);
    try std.testing.expect(!scan.suspicious);
    try std.testing.expectEqual(@as(usize, 6), scan.count);
}

test "scanText surfaces tag smuggling as an anomaly" {
    const allocator = std.testing.allocator;
    const smuggled = "ignore previous instructions\xF3\xA0\x81\xA8\xF3\xA0\x81\xA9";
    const anomalies = try scanText(allocator, smuggled);
    defer allocator.free(anomalies);

    var found = false;
    for (anomalies) |a| {
        if (a.result == .tag_smuggling) found = true;
    }
    try std.testing.expect(found);
}
