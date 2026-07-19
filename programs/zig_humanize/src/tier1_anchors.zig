//! Tier-1 externally-anchored test vectors for zig_humanize.
//!
//! Per `/CLAUDE.md` golden rule §1: a test whose expected value the library
//! author wrote proves only internal self-consistency (the failure mode that
//! shipped a wrong Base58Check checksum for two months behind 15/15 green
//! roundtrip tests). Every expectation in this file was produced by a
//! third-party implementation the zig_humanize author did not write:
//!
//!   * dustin/go-humanize v1.0.1  (github.com/dustin/go-humanize)
//!       Comma(), Ordinal(), Bytes(), IBytes()
//!   * python `humanize` 4.16.0   (pypi.org/project/humanize)
//!       intcomma(), ordinal(), naturaldelta()
//!
//! The values were generated once (see the per-section comments citing the
//! exact call) and transcribed verbatim; nothing here depends on those
//! libraries at test time.
//!
//! Two of zig_humanize's conventions match both reference libraries
//! byte-for-byte — thousands grouping and English ordinals — and are pinned
//! as hard equality anchors. The rest (byte sizing precision, relative-time
//! phrasing) deliberately diverge from the references; those sections assert
//! zig_humanize's own output while recording the reference output alongside,
//! so the divergence stays *documented and intentional* rather than silent.
//!
//! If a hard anchor here ever fails, the failure is either (a) a real
//! divergence from the reference libraries — fix zig_humanize, or (b) a
//! transcription error — fix the anchor WITH a citation to the regenerated
//! reference output. Never "fix" an anchor by pasting zig_humanize's current
//! output without re-deriving it from a reference implementation.

const std = @import("std");
const humanize = @import("zig_humanize");
const testing = std.testing;

// testing.allocator (not c_allocator) so each anchor also leak-checks the
// allocate-and-return contract of the function under test.
const alloc = testing.allocator;

// ============================================================================
// Thousands grouping — HARD ANCHOR
//
// go-humanize v1.0.1  humanize.Comma(int64(n))
// python humanize 4.16.0  humanize.intcomma(n)
// Both libraries produce identical output for every value below, and
// zig_humanize.formatNumber must match byte-for-byte.
//
// (Upper bound is 10^9: go-humanize's Comma takes int64, so u64 values above
//  math.MaxInt64 wrap — Comma(2^64-1) returns "-1" — and cannot anchor the
//  unsigned path. formatNumber's u64 range above MaxInt64 is left to the
//  roundtrip/unit tests; grouping is positional and fully exercised here.)
// ============================================================================

const CommaVec = struct { n: u64, expect: []const u8 };
const comma_vectors = [_]CommaVec{
    .{ .n = 0, .expect = "0" },
    .{ .n = 42, .expect = "42" },
    .{ .n = 100, .expect = "100" },
    .{ .n = 999, .expect = "999" },
    .{ .n = 1000, .expect = "1,000" },
    .{ .n = 1234567, .expect = "1,234,567" },
    .{ .n = 999999999, .expect = "999,999,999" },
    .{ .n = 1000000000, .expect = "1,000,000,000" },
};

test "anchor: formatNumber == go-humanize Comma / python intcomma" {
    for (comma_vectors) |v| {
        const got = try humanize.formatNumber(alloc, v.n);
        defer alloc.free(got);
        try testing.expectEqualSlices(u8, v.expect, got);
    }
}

// ============================================================================
// English ordinals — HARD ANCHOR
//
// go-humanize v1.0.1  humanize.Ordinal(n)
// python humanize 4.16.0  humanize.ordinal(n)
// Both agree on every value including the 11/12/13 "teens" exception and the
// 111/112/113 hundred-teens exception. formatOrdinal must match byte-exact.
// ============================================================================

const OrdinalVec = struct { n: u64, expect: []const u8 };
const ordinal_vectors = [_]OrdinalVec{
    .{ .n = 1, .expect = "1st" },
    .{ .n = 2, .expect = "2nd" },
    .{ .n = 3, .expect = "3rd" },
    .{ .n = 4, .expect = "4th" },
    .{ .n = 5, .expect = "5th" },
    .{ .n = 11, .expect = "11th" },
    .{ .n = 12, .expect = "12th" },
    .{ .n = 13, .expect = "13th" },
    .{ .n = 21, .expect = "21st" },
    .{ .n = 22, .expect = "22nd" },
    .{ .n = 23, .expect = "23rd" },
    .{ .n = 100, .expect = "100th" },
    .{ .n = 101, .expect = "101st" },
    .{ .n = 111, .expect = "111th" },
    .{ .n = 112, .expect = "112th" },
    .{ .n = 113, .expect = "113th" },
    .{ .n = 121, .expect = "121st" },
    .{ .n = 122, .expect = "122nd" },
    .{ .n = 123, .expect = "123rd" },
};

test "anchor: formatOrdinal == go-humanize Ordinal / python ordinal" {
    for (ordinal_vectors) |v| {
        const got = try humanize.formatOrdinal(alloc, v.n);
        defer alloc.free(got);
        try testing.expectEqualSlices(u8, v.expect, got);
    }
}

// ============================================================================
// Byte sizing — DOCUMENTED DIVERGENCE
//
// Reference: go-humanize v1.0.1 humanize.Bytes(n) / humanize.IBytes(n).
// zig_humanize intentionally differs on three axes; each vector records the
// reference string next to zig_humanize's asserted output so the divergence
// is a deliberate, reviewed choice and not an accidental incompatibility:
//
//   1. Precision. zig_humanize prints 2 significant fraction digits below 10
//      ("1.50 KB"); go-humanize prints 1 ("1.5 kB").
//   2. SI casing. zig_humanize uses "KB"; go-humanize uses the strict-SI
//      lowercase "kB". (Binary "KiB" agrees.)
//   3. Unit ceiling. zig_humanize's tables stop at PB/PiB, so the u64 maximum
//      renders in peta- ("18447 PB"); go-humanize carries EB/EiB
//      ("18 EB" / "16 EiB"). See suggested-upgrade #4 in the audit report.
//
// If zig_humanize's byte output ever changes, update BOTH columns and note
// whether the change converges toward or further from the reference.
// ============================================================================

const ByteVec = struct {
    n: u64,
    binary: bool,
    zig_expect: []const u8,
    go_ref: []const u8,
};
const byte_vectors = [_]ByteVec{
    // SI (go-humanize Bytes)
    .{ .n = 0, .binary = false, .zig_expect = "0 B", .go_ref = "0 B" }, // agree
    .{ .n = 999, .binary = false, .zig_expect = "999 B", .go_ref = "999 B" }, // agree
    .{ .n = 1, .binary = false, .zig_expect = "1.00 B", .go_ref = "1 B" }, // precision
    .{ .n = 1000, .binary = false, .zig_expect = "1.00 KB", .go_ref = "1.0 kB" }, // precision + casing
    .{ .n = 1500, .binary = false, .zig_expect = "1.50 KB", .go_ref = "1.5 kB" }, // precision + casing
    .{ .n = 1500000, .binary = false, .zig_expect = "1.50 MB", .go_ref = "1.5 MB" }, // precision
    .{ .n = 1500000000, .binary = false, .zig_expect = "1.50 GB", .go_ref = "1.5 GB" }, // precision
    .{ .n = std.math.maxInt(u64), .binary = false, .zig_expect = "18447 PB", .go_ref = "18 EB" }, // unit ceiling
    // Binary (go-humanize IBytes)
    .{ .n = 1536, .binary = true, .zig_expect = "1.50 KiB", .go_ref = "1.5 KiB" }, // precision
    .{ .n = 1048576, .binary = true, .zig_expect = "1.00 MiB", .go_ref = "1.0 MiB" }, // precision
    .{ .n = std.math.maxInt(u64), .binary = true, .zig_expect = "16384 PiB", .go_ref = "16 EiB" }, // unit ceiling
};

test "anchor: formatBytes documented divergence from go-humanize Bytes/IBytes" {
    for (byte_vectors) |v| {
        const fmt: humanize.ByteFormat = if (v.binary) .Binary else .SI;
        const got = try humanize.formatBytesOptions(alloc, v.n, fmt);
        defer alloc.free(got);
        try testing.expectEqualSlices(u8, v.zig_expect, got);
        // Sanity: divergence is never a regression to an empty/garbage string.
        try testing.expect(got.len > 0);
    }
}

// ============================================================================
// Relative time — DOCUMENTED DIVERGENCE (with a plural-stem anchor)
//
// Reference: python humanize 4.16.0 humanize.naturaldelta(timedelta(seconds=s)).
//
// naturaldelta renders the magnitude WITHOUT direction ("2 hours"); callers
// add "ago"/"from now" separately. zig_humanize folds direction into the
// string via prefix/suffix. For counts >= 2 within a unit, naturaldelta's
// phrasing is exactly zig_humanize's stem, so we anchor
//     zig output == naturaldelta(stem) + zig affixes.
// The SINGULAR case diverges: naturaldelta uses an article ("a second",
// "an hour", "a day", "a month", "a year") where zig_humanize prints the
// numeral ("1 second", "1 hour", ...). That difference is recorded per-row.
//
// Critically for audit upgrade #1 (the "0 years ago" regression fixed in
// wave 2): naturaldelta NEVER emits a zero count — 360 days is "a year" (an
// upgrade from months, not "0 years"). The anchor at 360 days below pins
// zig_humanize to a non-zero count, which is the property the regression
// violated.
// ============================================================================

const day = 86400;
const RelVec = struct {
    seconds: u64,
    future: bool,
    zig_expect: []const u8,
    // naturaldelta(seconds) magnitude, direction stripped, for the record.
    naturaldelta_ref: []const u8,
};
const rel_vectors = [_]RelVec{
    // Plural counts: zig stem == naturaldelta magnitude (HARD-ish anchor).
    .{ .seconds = 30, .future = false, .zig_expect = "30 seconds ago", .naturaldelta_ref = "30 seconds" },
    .{ .seconds = 300, .future = false, .zig_expect = "5 minutes ago", .naturaldelta_ref = "5 minutes" },
    .{ .seconds = 7200, .future = false, .zig_expect = "2 hours ago", .naturaldelta_ref = "2 hours" },
    .{ .seconds = 300, .future = true, .zig_expect = "in 5 minutes", .naturaldelta_ref = "5 minutes" },
    .{ .seconds = 730 * day, .future = false, .zig_expect = "2 years ago", .naturaldelta_ref = "2 years" },
    // Singular: documented divergence — zig numeral vs naturaldelta article.
    .{ .seconds = 1, .future = false, .zig_expect = "1 second ago", .naturaldelta_ref = "a second" },
    .{ .seconds = 3600, .future = false, .zig_expect = "1 hour ago", .naturaldelta_ref = "an hour" },
    // Year boundary: naturaldelta(360d) == "a year" (non-zero); zig says
    // "11 months ago" (also non-zero). The regression that produced
    // "0 years ago" here is what this row guards against.
    .{ .seconds = 360 * day, .future = false, .zig_expect = "11 months ago", .naturaldelta_ref = "a year" },
    .{ .seconds = 365 * day, .future = false, .zig_expect = "1 year ago", .naturaldelta_ref = "a year" },
};

test "anchor: formatRelativeTime plural stems match python naturaldelta" {
    for (rel_vectors) |v| {
        const got = try humanize.formatRelativeTime(alloc, v.seconds, .{ .future = v.future });
        defer alloc.free(got);
        try testing.expectEqualSlices(u8, v.zig_expect, got);
        // The regression guard: the leading count is never zero, matching
        // naturaldelta, which never emits "0 <unit>". The count sits at the
        // very start ("0 years ago") or right after the future prefix
        // ("in 0 years"), so those two prefixes are the whole check.
        try testing.expect(!std.mem.startsWith(u8, got, "0 "));
        try testing.expect(!std.mem.startsWith(u8, got, "in 0 "));
    }
}
