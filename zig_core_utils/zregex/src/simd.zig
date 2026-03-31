//! SIMD-accelerated string search primitives
//! Uses 256-bit vectors (32 bytes) for maximum throughput on modern CPUs

const std = @import("std");

/// Vector size for SIMD operations (256-bit = 32 bytes)
pub const VECTOR_SIZE = 32;
const Vec = @Vector(VECTOR_SIZE, u8);

/// SIMD-accelerated memchr - find first occurrence of byte in slice
/// Returns index of first match, or null if not found
pub fn memchr(haystack: []const u8, needle: u8) ?usize {
    const len = haystack.len;
    if (len == 0) return null;

    // Broadcast needle to all lanes
    const needle_vec: Vec = @splat(needle);

    // Process 32 bytes at a time
    var i: usize = 0;
    while (i + VECTOR_SIZE <= len) : (i += VECTOR_SIZE) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const matches = chunk == needle_vec;

        // Convert bool vector to bitmask
        const mask = @as(u32, @bitCast(matches));
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Handle remaining bytes (scalar fallback)
    while (i < len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }

    return null;
}

/// Find first occurrence of needle byte starting from offset
pub fn memchrFrom(haystack: []const u8, needle: u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (memchr(haystack[start..], needle)) |rel_pos| {
        return start + rel_pos;
    }
    return null;
}

/// SIMD-accelerated two-byte search
/// Useful for patterns starting with 2+ literal chars
pub fn memchr2(haystack: []const u8, b0: u8, b1: u8) ?usize {
    if (haystack.len < 2) return null;

    const b0_vec: Vec = @splat(b0);
    const b1_vec: Vec = @splat(b1);

    var i: usize = 0;
    while (i + VECTOR_SIZE + 1 <= haystack.len) : (i += VECTOR_SIZE) {
        const chunk0: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const chunk1: Vec = haystack[i + 1 ..][0..VECTOR_SIZE].*;

        const match0 = chunk0 == b0_vec;
        const match1 = chunk1 == b1_vec;
        // Use @select to combine boolean vectors (AND operation)
        const combined = @select(bool, match0, match1, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(combined));
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar fallback for remaining bytes
    while (i + 1 < haystack.len) : (i += 1) {
        if (haystack[i] == b0 and haystack[i + 1] == b1) return i;
    }

    return null;
}

/// SIMD-accelerated literal string search (memmem)
/// Uses SIMD to find first byte candidates, then verifies full match
pub fn memmem(haystack: []const u8, needle: []const u8) ?usize {
    return memmemFrom(haystack, needle, 0);
}

/// Find literal string starting from offset
pub fn memmemFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len) return null;
    if (needle.len > haystack.len - start) return null;

    // For single byte, use memchr
    if (needle.len == 1) {
        return memchrFrom(haystack, needle[0], start);
    }

    // For two bytes, use specialized two-byte search
    if (needle.len == 2) {
        if (memchr2(haystack[start..], needle[0], needle[1])) |rel| {
            return start + rel;
        }
        return null;
    }

    // For longer needles, use SIMD to find first byte candidates,
    // then verify full match with optimized comparison
    const first_byte = needle[0];
    const last_byte = needle[needle.len - 1];
    const first_vec: Vec = @splat(first_byte);
    const last_vec: Vec = @splat(last_byte);

    var i: usize = start;
    const end = haystack.len - needle.len + 1;

    // SIMD loop: find positions where first AND last bytes match
    while (i + VECTOR_SIZE <= end) {
        const chunk_first: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const chunk_last: Vec = haystack[i + needle.len - 1 ..][0..VECTOR_SIZE].*;

        const match_first = chunk_first == first_vec;
        const match_last = chunk_last == last_vec;
        // Use @select to combine boolean vectors (AND operation)
        const candidates = @select(bool, match_first, match_last, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        var mask = @as(u32, @bitCast(candidates));
        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const pos = i + bit_pos;

            // Verify full match
            if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
                return pos;
            }

            // Clear this bit and continue
            mask &= mask - 1;
        }

        i += VECTOR_SIZE;
    }

    // Scalar fallback for remaining positions
    while (i < end) : (i += 1) {
        if (haystack[i] == first_byte and
            haystack[i + needle.len - 1] == last_byte and
            std.mem.eql(u8, haystack[i..][0..needle.len], needle))
        {
            return i;
        }
    }

    return null;
}

/// Count occurrences of a byte in a slice using SIMD
pub fn countByte(haystack: []const u8, needle: u8) usize {
    var count: usize = 0;
    const needle_vec: Vec = @splat(needle);

    var i: usize = 0;
    while (i + VECTOR_SIZE <= haystack.len) : (i += VECTOR_SIZE) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const matches = chunk == needle_vec;
        count += @popCount(@as(u32, @bitCast(matches)));
    }

    // Scalar fallback
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) count += 1;
    }

    return count;
}

/// Find newline positions efficiently (useful for line-by-line processing)
pub fn findNewline(haystack: []const u8, start: usize) ?usize {
    return memchrFrom(haystack, '\n', start);
}

// ============================================================================
// SIMD Character Class Span Functions
// These find spans of consecutive characters matching a character class
// ============================================================================

/// Find the length of a span of digits [0-9] starting at pos
/// Returns the number of consecutive digits
pub fn findDigitSpan(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len) return 0;

    const zero_vec: Vec = @splat('0');
    const nine_vec: Vec = @splat('9');

    var i: usize = start;

    // SIMD loop: check 32 bytes at a time
    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;

        // Check if each byte is in range '0'-'9'
        // A byte is a digit if: byte >= '0' AND byte <= '9'
        const ge_zero = chunk >= zero_vec;
        const le_nine = chunk <= nine_vec;
        const is_digit = @select(bool, ge_zero, le_nine, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(is_digit));
        if (mask != 0xFFFFFFFF) {
            // Found a non-digit, count leading digits
            const non_digit_pos = @ctz(~mask);
            return (i - start) + non_digit_pos;
        }
        i += VECTOR_SIZE;
    }

    // Scalar fallback for remaining bytes
    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        if (c < '0' or c > '9') break;
    }

    return i - start;
}

/// Find the length of a span of lowercase letters [a-z] starting at pos
pub fn findLowerSpan(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len) return 0;

    const a_vec: Vec = @splat('a');
    const z_vec: Vec = @splat('z');

    var i: usize = start;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const ge_a = chunk >= a_vec;
        const le_z = chunk <= z_vec;
        const is_lower = @select(bool, ge_a, le_z, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(is_lower));
        if (mask != 0xFFFFFFFF) {
            return (i - start) + @ctz(~mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        if (c < 'a' or c > 'z') break;
    }

    return i - start;
}

/// Find the length of a span of uppercase letters [A-Z] starting at pos
pub fn findUpperSpan(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len) return 0;

    const a_vec: Vec = @splat('A');
    const z_vec: Vec = @splat('Z');

    var i: usize = start;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const ge_a = chunk >= a_vec;
        const le_z = chunk <= z_vec;
        const is_upper = @select(bool, ge_a, le_z, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(is_upper));
        if (mask != 0xFFFFFFFF) {
            return (i - start) + @ctz(~mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        if (c < 'A' or c > 'Z') break;
    }

    return i - start;
}

/// Find the length of a span of word characters [a-zA-Z0-9_] starting at pos
/// This is equivalent to \w+ in regex
pub fn findWordCharSpan(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len) return 0;

    const a_lower: Vec = @splat('a');
    const z_lower: Vec = @splat('z');
    const a_upper: Vec = @splat('A');
    const z_upper: Vec = @splat('Z');
    const zero: Vec = @splat('0');
    const nine: Vec = @splat('9');
    const underscore: Vec = @splat('_');

    var i: usize = start;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;

        // Check lowercase: a-z
        const is_lower = @select(bool, chunk >= a_lower, chunk <= z_lower, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check uppercase: A-Z
        const is_upper = @select(bool, chunk >= a_upper, chunk <= z_upper, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check digit: 0-9
        const is_digit = @select(bool, chunk >= zero, chunk <= nine, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check underscore
        const is_underscore = chunk == underscore;

        // Combine: is_lower OR is_upper OR is_digit OR is_underscore
        const is_word_1 = @select(bool, is_lower, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_upper);
        const is_word_2 = @select(bool, is_digit, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_underscore);
        const is_word = @select(bool, is_word_1, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_word_2);

        const mask = @as(u32, @bitCast(is_word));
        if (mask != 0xFFFFFFFF) {
            return (i - start) + @ctz(~mask);
        }
        i += VECTOR_SIZE;
    }

    // Scalar fallback
    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        const is_word_char = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!is_word_char) break;
    }

    return i - start;
}

/// Find the length of a span matching a single character range [lo-hi]
pub fn findRangeSpan(haystack: []const u8, start: usize, lo: u8, hi: u8) usize {
    if (start >= haystack.len) return 0;

    const lo_vec: Vec = @splat(lo);
    const hi_vec: Vec = @splat(hi);

    var i: usize = start;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const ge_lo = chunk >= lo_vec;
        const le_hi = chunk <= hi_vec;
        const in_range = @select(bool, ge_lo, le_hi, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(in_range));
        if (mask != 0xFFFFFFFF) {
            return (i - start) + @ctz(~mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        if (c < lo or c > hi) break;
    }

    return i - start;
}

/// Find first position where a digit [0-9] occurs
pub fn findFirstDigit(haystack: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;

    const zero_vec: Vec = @splat('0');
    const nine_vec: Vec = @splat('9');

    var i: usize = start;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;
        const ge_zero = chunk >= zero_vec;
        const le_nine = chunk <= nine_vec;
        const is_digit = @select(bool, ge_zero, le_nine, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        const mask = @as(u32, @bitCast(is_digit));
        if (mask != 0) {
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        if (c >= '0' and c <= '9') return i;
    }

    return null;
}

/// Find first position where a word character [a-zA-Z0-9_] occurs
/// SIMD-optimized version using vector operations for speed
pub fn findFirstWordChar(haystack: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;

    // Create comparison vectors for range boundaries
    const a_lower: Vec = @splat('a');
    const z_lower: Vec = @splat('z');
    const a_upper: Vec = @splat('A');
    const z_upper: Vec = @splat('Z');
    const zero: Vec = @splat('0');
    const nine: Vec = @splat('9');
    const underscore: Vec = @splat('_');

    var i: usize = start;

    // SIMD loop: process 32 bytes at a time
    while (i + VECTOR_SIZE <= haystack.len) : (i += VECTOR_SIZE) {
        const chunk: Vec = haystack[i..][0..VECTOR_SIZE].*;

        // Check lowercase: a-z
        const is_lower = @select(bool, chunk >= a_lower, chunk <= z_lower, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check uppercase: A-Z
        const is_upper = @select(bool, chunk >= a_upper, chunk <= z_upper, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check digit: 0-9
        const is_digit = @select(bool, chunk >= zero, chunk <= nine, @as(@Vector(VECTOR_SIZE, bool), @splat(false)));

        // Check underscore
        const is_underscore = chunk == underscore;

        // Combine: is_lower OR is_upper OR is_digit OR is_underscore
        const is_word_1 = @select(bool, is_lower, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_upper);
        const is_word_2 = @select(bool, is_digit, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_underscore);
        const is_word = @select(bool, is_word_1, @as(@Vector(VECTOR_SIZE, bool), @splat(true)), is_word_2);

        const mask = @as(u32, @bitCast(is_word));
        if (mask != 0) {
            // Found a word char, return its position
            return i + @ctz(mask);
        }
    }

    // Scalar fallback for remaining bytes
    while (i < haystack.len) : (i += 1) {
        const c = haystack[i];
        const is_word_char = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (is_word_char) return i;
    }

    return null;
}

// Tests
test "memchr basic" {
    const data = "hello world";
    try std.testing.expectEqual(@as(?usize, 0), memchr(data, 'h'));
    try std.testing.expectEqual(@as(?usize, 4), memchr(data, 'o'));
    try std.testing.expectEqual(@as(?usize, 6), memchr(data, 'w'));
    try std.testing.expectEqual(@as(?usize, null), memchr(data, 'x'));
}

test "memchr large" {
    // Test with data larger than vector size
    var data: [100]u8 = undefined;
    @memset(&data, 'a');
    data[50] = 'X';
    data[99] = 'Y';

    try std.testing.expectEqual(@as(?usize, 50), memchr(&data, 'X'));
    try std.testing.expectEqual(@as(?usize, 99), memchr(&data, 'Y'));
    try std.testing.expectEqual(@as(?usize, null), memchr(&data, 'Z'));
}

test "memchr2" {
    const data = "the quick brown fox";
    try std.testing.expectEqual(@as(?usize, 0), memchr2(data, 't', 'h'));
    try std.testing.expectEqual(@as(?usize, 4), memchr2(data, 'q', 'u'));
    try std.testing.expectEqual(@as(?usize, 16), memchr2(data, 'f', 'o'));
    try std.testing.expectEqual(@as(?usize, null), memchr2(data, 'x', 'y'));
}

test "memmem basic" {
    const data = "the quick brown fox jumps over the lazy dog";
    try std.testing.expectEqual(@as(?usize, 0), memmem(data, "the"));
    try std.testing.expectEqual(@as(?usize, 4), memmem(data, "quick"));
    try std.testing.expectEqual(@as(?usize, 16), memmem(data, "fox"));
    try std.testing.expectEqual(@as(?usize, null), memmem(data, "cat"));
}

test "memmem from offset" {
    const data = "hello hello hello";
    try std.testing.expectEqual(@as(?usize, 0), memmemFrom(data, "hello", 0));
    try std.testing.expectEqual(@as(?usize, 6), memmemFrom(data, "hello", 1));
    try std.testing.expectEqual(@as(?usize, 12), memmemFrom(data, "hello", 7));
    try std.testing.expectEqual(@as(?usize, null), memmemFrom(data, "hello", 13));
}

test "memmem large" {
    // Test with data larger than vector size
    var data: [200]u8 = undefined;
    @memset(&data, 'x');
    @memcpy(data[150..157], "NEEDLE!");

    try std.testing.expectEqual(@as(?usize, 150), memmem(&data, "NEEDLE!"));
    try std.testing.expectEqual(@as(?usize, null), memmem(&data, "NOTFOUND"));
}

test "countByte" {
    const data = "banana";
    try std.testing.expectEqual(@as(usize, 3), countByte(data, 'a'));
    try std.testing.expectEqual(@as(usize, 2), countByte(data, 'n'));
    try std.testing.expectEqual(@as(usize, 1), countByte(data, 'b'));
    try std.testing.expectEqual(@as(usize, 0), countByte(data, 'x'));
}

// Character class span tests
test "findDigitSpan basic" {
    try std.testing.expectEqual(@as(usize, 3), findDigitSpan("123abc", 0));
    try std.testing.expectEqual(@as(usize, 0), findDigitSpan("abc123", 0));
    try std.testing.expectEqual(@as(usize, 3), findDigitSpan("abc123def", 3));
    try std.testing.expectEqual(@as(usize, 6), findDigitSpan("123456", 0));
    try std.testing.expectEqual(@as(usize, 0), findDigitSpan("", 0));
}

test "findDigitSpan large" {
    // Test with data larger than SIMD vector (32 bytes)
    var data: [100]u8 = undefined;
    @memset(&data, '5'); // All digits
    data[50] = 'X'; // Non-digit at position 50

    try std.testing.expectEqual(@as(usize, 50), findDigitSpan(&data, 0));

    // All digits
    @memset(&data, '9');
    try std.testing.expectEqual(@as(usize, 100), findDigitSpan(&data, 0));
}

test "findLowerSpan basic" {
    try std.testing.expectEqual(@as(usize, 5), findLowerSpan("hello123", 0));
    try std.testing.expectEqual(@as(usize, 0), findLowerSpan("HELLO", 0));
    try std.testing.expectEqual(@as(usize, 5), findLowerSpan("world", 0));
}

test "findUpperSpan basic" {
    try std.testing.expectEqual(@as(usize, 5), findUpperSpan("HELLO123", 0));
    try std.testing.expectEqual(@as(usize, 0), findUpperSpan("hello", 0));
    try std.testing.expectEqual(@as(usize, 5), findUpperSpan("WORLD", 0));
}

test "findWordCharSpan basic" {
    try std.testing.expectEqual(@as(usize, 11), findWordCharSpan("hello_world!", 0));
    try std.testing.expectEqual(@as(usize, 5), findWordCharSpan("test1 test2", 0));
    try std.testing.expectEqual(@as(usize, 5), findWordCharSpan("test1 test2", 6));
    try std.testing.expectEqual(@as(usize, 8), findWordCharSpan("var_name", 0));
    try std.testing.expectEqual(@as(usize, 0), findWordCharSpan("!@#$%", 0));
}

test "findWordCharSpan large" {
    var data: [100]u8 = undefined;
    @memset(&data, 'a'); // All word chars
    data[75] = ' '; // Space (non-word) at 75

    try std.testing.expectEqual(@as(usize, 75), findWordCharSpan(&data, 0));
}

test "findRangeSpan" {
    // Hex digits 0-9
    try std.testing.expectEqual(@as(usize, 4), findRangeSpan("1234xyz", 0, '0', '9'));
    // Hex letters a-f
    try std.testing.expectEqual(@as(usize, 4), findRangeSpan("abcd123", 0, 'a', 'f'));
    // Custom range
    try std.testing.expectEqual(@as(usize, 3), findRangeSpan("ABC123", 0, 'A', 'Z'));
}

test "findFirstDigit" {
    try std.testing.expectEqual(@as(?usize, 5), findFirstDigit("hello123world", 0));
    try std.testing.expectEqual(@as(?usize, 0), findFirstDigit("123abc", 0));
    try std.testing.expectEqual(@as(?usize, null), findFirstDigit("abcdef", 0));
    try std.testing.expectEqual(@as(?usize, 5), findFirstDigit("hello123", 1));
}

test "findFirstDigit large" {
    var data: [100]u8 = undefined;
    @memset(&data, 'x');
    data[67] = '5';

    try std.testing.expectEqual(@as(?usize, 67), findFirstDigit(&data, 0));
    try std.testing.expectEqual(@as(?usize, null), findFirstDigit(&data, 68));
}

test "findFirstWordChar" {
    try std.testing.expectEqual(@as(?usize, 0), findFirstWordChar("hello", 0));
    try std.testing.expectEqual(@as(?usize, 3), findFirstWordChar("   word", 0));
    try std.testing.expectEqual(@as(?usize, 2), findFirstWordChar("!!test", 0));
    try std.testing.expectEqual(@as(?usize, null), findFirstWordChar("!@#$%", 0));
}
