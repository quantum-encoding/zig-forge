//! Shannon Entropy Calculator
//!
//! Calculates entropy of strings to detect high-randomness data that might be secrets.
//! Secrets typically have high entropy (random characters) compared to normal text.

const std = @import("std");

/// Calculate Shannon entropy of a byte slice
/// Returns value between 0.0 (no entropy, all same char) and 1.0 (maximum entropy)
pub fn calculate(data: []const u8) f32 {
    if (data.len == 0) return 0.0;

    // Count byte frequencies
    var freq: [256]u32 = [_]u32{0} ** 256;
    for (data) |b| {
        freq[b] += 1;
    }

    // Calculate entropy
    const len_f: f32 = @floatFromInt(data.len);
    var entropy: f32 = 0.0;

    for (freq) |count| {
        if (count > 0) {
            const p: f32 = @as(f32, @floatFromInt(count)) / len_f;
            entropy -= p * @log2(p);
        }
    }

    // Normalize to 0.0-1.0 range (max entropy is 8 bits for byte data)
    return entropy / 8.0;
}

/// Calculate entropy for only alphanumeric characters (ignoring special chars)
pub fn calculateAlphanumeric(data: []const u8) f32 {
    if (data.len == 0) return 0.0;

    var freq: [62]u32 = [_]u32{0} ** 62; // 26 lower + 26 upper + 10 digits
    var count: u32 = 0;

    for (data) |c| {
        const idx = charToIndex(c);
        if (idx) |i| {
            freq[i] += 1;
            count += 1;
        }
    }

    if (count == 0) return 0.0;

    const len_f: f32 = @floatFromInt(count);
    var entropy: f32 = 0.0;

    for (freq) |f| {
        if (f > 0) {
            const p: f32 = @as(f32, @floatFromInt(f)) / len_f;
            entropy -= p * @log2(p);
        }
    }

    // Max entropy for 62 chars is log2(62) ≈ 5.95
    return entropy / 5.95;
}

/// Calculate entropy for base64 characters
pub fn calculateBase64(data: []const u8) f32 {
    if (data.len == 0) return 0.0;

    var freq: [64]u32 = [_]u32{0} ** 64;
    var count: u32 = 0;

    for (data) |c| {
        const idx = base64Index(c);
        if (idx) |i| {
            freq[i] += 1;
            count += 1;
        }
    }

    if (count == 0) return 0.0;

    const len_f: f32 = @floatFromInt(count);
    var entropy: f32 = 0.0;

    for (freq) |f| {
        if (f > 0) {
            const p: f32 = @as(f32, @floatFromInt(f)) / len_f;
            entropy -= p * @log2(p);
        }
    }

    // Max entropy for 64 chars is 6 bits
    return entropy / 6.0;
}

/// Calculate entropy for hex characters
pub fn calculateHex(data: []const u8) f32 {
    if (data.len == 0) return 0.0;

    var freq: [16]u32 = [_]u32{0} ** 16;
    var count: u32 = 0;

    for (data) |c| {
        const idx = hexIndex(c);
        if (idx) |i| {
            freq[i] += 1;
            count += 1;
        }
    }

    if (count == 0) return 0.0;

    const len_f: f32 = @floatFromInt(count);
    var entropy: f32 = 0.0;

    for (freq) |f| {
        if (f > 0) {
            const p: f32 = @as(f32, @floatFromInt(f)) / len_f;
            entropy -= p * @log2(p);
        }
    }

    // Max entropy for 16 chars is 4 bits
    return entropy / 4.0;
}

/// Check if a string looks like high-entropy secret material
pub fn looksLikeSecret(data: []const u8, threshold: f32) bool {
    if (data.len < 8) return false;

    // Try different entropy calculations based on character composition
    const has_special = hasSpecialChars(data);
    const mostly_hex = isMostlyHex(data);
    const mostly_base64 = isMostlyBase64(data);

    const entropy = if (mostly_hex)
        calculateHex(data)
    else if (mostly_base64)
        calculateBase64(data)
    else if (!has_special)
        calculateAlphanumeric(data)
    else
        calculate(data);

    return entropy >= threshold;
}

/// Extract potential secret from a line around a keyword
pub fn extractSecret(line: []const u8, keyword_pos: usize, keyword_len: usize) ?[]const u8 {
    if (keyword_pos + keyword_len >= line.len) return null;

    // Look for value after keyword
    var start = keyword_pos + keyword_len;

    // Skip common separators: = : " ' spaces
    while (start < line.len) {
        const c = line[start];
        if (c == '=' or c == ':' or c == '"' or c == '\'' or c == ' ' or c == '\t') {
            start += 1;
        } else {
            break;
        }
    }

    if (start >= line.len) return null;

    // Find end of potential secret
    var end = start;
    const quote_char: ?u8 = if (start > 0 and (line[start - 1] == '"' or line[start - 1] == '\''))
        line[start - 1]
    else
        null;

    while (end < line.len) {
        const c = line[end];
        if (quote_char) |q| {
            if (c == q) break;
        } else {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                c == '"' or c == '\'' or c == ',' or c == ';' or
                c == ')' or c == '}' or c == ']')
            {
                break;
            }
        }
        end += 1;
    }

    if (end <= start) return null;
    return line[start..end];
}

// Helper functions

fn charToIndex(c: u8) ?usize {
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c >= 'A' and c <= 'Z') return 26 + (c - 'A');
    if (c >= '0' and c <= '9') return 52 + (c - '0');
    return null;
}

fn base64Index(c: u8) ?usize {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return 26 + (c - 'a');
    if (c >= '0' and c <= '9') return 52 + (c - '0');
    if (c == '+' or c == '-') return 62;
    if (c == '/' or c == '_') return 63;
    return null;
}

fn hexIndex(c: u8) ?usize {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return null;
}

fn hasSpecialChars(data: []const u8) bool {
    for (data) |c| {
        if (!std.ascii.isAlphanumeric(c)) return true;
    }
    return false;
}

fn isMostlyHex(data: []const u8) bool {
    if (data.len < 4) return false;
    var hex_count: usize = 0;
    for (data) |c| {
        if (hexIndex(c) != null) hex_count += 1;
    }
    return hex_count * 100 / data.len >= 90;
}

fn isMostlyBase64(data: []const u8) bool {
    if (data.len < 4) return false;
    var b64_count: usize = 0;
    for (data) |c| {
        if (base64Index(c) != null or c == '=') b64_count += 1;
    }
    return b64_count * 100 / data.len >= 90;
}

// =============================================================================
// Tests
// =============================================================================

test "entropy of uniform data" {
    const uniform = "aaaaaaaaaa";
    const entropy = calculate(uniform);
    try std.testing.expect(entropy < 0.05);
}

test "entropy of random-looking data" {
    const random = "aB3xK9mQ2pL7nR5";
    const entropy = calculate(random);
    try std.testing.expect(entropy > 0.4);
}

test "entropy of hex string" {
    const hex = "a1b2c3d4e5f6a7b8c9d0";
    const entropy = calculateHex(hex);
    try std.testing.expect(entropy > 0.7);
}

test "looks like secret" {
    // High entropy string should be flagged
    const secret = "ghp_xK9mQ2pL7nR5aB3j8hY6wE4tI0oU";
    try std.testing.expect(looksLikeSecret(secret, 0.5));

    // Low entropy string should not be flagged (use higher threshold)
    const not_secret = "hellohellohello";
    try std.testing.expect(!looksLikeSecret(not_secret, 0.5));
}

test "extract secret" {
    const line = "API_KEY=sk_live_abc123xyz789";
    const secret = extractSecret(line, 0, 7);
    try std.testing.expect(secret != null);
    try std.testing.expectEqualStrings("sk_live_abc123xyz789", secret.?);
}

test "extract quoted secret" {
    const line = "password: \"super_secret_123\"";
    const secret = extractSecret(line, 0, 8);
    try std.testing.expect(secret != null);
    try std.testing.expectEqualStrings("super_secret_123", secret.?);
}
