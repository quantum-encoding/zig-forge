// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Streaming JSON writer.
//!
//! Writes JSON to any `*std.Io.Writer` sink (file, stdout, in-memory buffer).
//! No libc, no fixed-capacity buffers, no silent error swallowing. Enforces
//! RFC 8259 grammar for numbers and matches every opening container with its
//! matching closer — calling `endArray` when the current container is an
//! object (or vice versa) returns `WrongContainer`, not silently corrupt
//! JSON.
//!
//! Audit-driven changes from the previous version:
//!   * Replaced `*std.c.FILE` + `fwrite` with `*std.Io.Writer`. Returns
//!     `!void` so I/O errors propagate (was: silently dropped).
//!   * Removed the 64-deep fixed stack. Uses a growable
//!     `ArrayListUnmanaged(ContainerType)` (caller passes an allocator).
//!   * `number(s)` validates `s` against the RFC 8259 number grammar.
//!     `"007"`, `"1."`, `".5"`, `"NaN"`, `"Infinity"`, empty — all rejected.
//!   * `endObject` / `endArray` verify the top container matches and the
//!     stack is non-empty.

const std = @import("std");

pub const ContainerType = enum { object, array };

pub const Error = std.Io.Writer.Error || error{
    OutOfMemory,
    /// `endObject` / `endArray` called with no open container.
    UnbalancedClose,
    /// `endObject` called inside an array, or `endArray` inside an object.
    WrongContainer,
    /// `number(s)` called with bytes that don't form a valid JSON number per
    /// RFC 8259 §6 (e.g. leading zeros, NaN, Infinity, empty, malformed).
    InvalidNumber,
};

pub const JsonWriter = struct {
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pretty: bool,

    stack: std.ArrayListUnmanaged(ContainerType),
    needs_comma: bool,
    needs_newline: bool,
    in_key: bool,

    pub fn init(allocator: std.mem.Allocator, out: *std.Io.Writer, pretty: bool) JsonWriter {
        return .{
            .out = out,
            .allocator = allocator,
            .pretty = pretty,
            .stack = .empty,
            .needs_comma = false,
            .needs_newline = false,
            .in_key = false,
        };
    }

    pub fn deinit(self: *JsonWriter) void {
        self.stack.deinit(self.allocator);
    }

    // ------------------------------------------------------------------
    // Public structural methods
    // ------------------------------------------------------------------

    pub fn beginObject(self: *JsonWriter) Error!void {
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.out.writeByte('{');
        try self.stack.append(self.allocator, .object);
        self.needs_comma = false;
        self.needs_newline = true;
    }

    pub fn endObject(self: *JsonWriter) Error!void {
        const top = self.stack.pop() orelse return Error.UnbalancedClose;
        if (top != .object) return Error.WrongContainer;

        if (self.needs_comma and self.pretty) {
            try self.writeNewline();
            try self.writeIndent();
        }
        try self.out.writeByte('}');
        self.needs_comma = true;
    }

    pub fn beginArray(self: *JsonWriter) Error!void {
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.out.writeByte('[');
        try self.stack.append(self.allocator, .array);
        self.needs_comma = false;
        self.needs_newline = true;
    }

    pub fn endArray(self: *JsonWriter) Error!void {
        const top = self.stack.pop() orelse return Error.UnbalancedClose;
        if (top != .array) return Error.WrongContainer;

        if (self.needs_comma and self.pretty) {
            try self.writeNewline();
            try self.writeIndent();
        }
        try self.out.writeByte(']');
        self.needs_comma = true;
    }

    // ------------------------------------------------------------------
    // Public value methods
    // ------------------------------------------------------------------

    pub fn key(self: *JsonWriter, k: []const u8) Error!void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(k);
        try self.out.writeByte(':');
        if (self.pretty) try self.out.writeByte(' ');
        self.needs_comma = false;
        self.in_key = true;
    }

    pub fn string(self: *JsonWriter, s: []const u8) Error!void {
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.writeEscapedString(s);
        self.needs_comma = true;
    }

    /// Write `n` as a JSON number after validating it against RFC 8259 §6.
    /// Returns `InvalidNumber` for anything else (leading zeros, NaN,
    /// Infinity, `1.`, `.5`, empty, embedded letters, etc.).
    pub fn number(self: *JsonWriter, n: []const u8) Error!void {
        if (!isValidJsonNumber(n)) return Error.InvalidNumber;
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.out.writeAll(n);
        self.needs_comma = true;
    }

    pub fn writeNull(self: *JsonWriter) Error!void {
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.out.writeAll("null");
        self.needs_comma = true;
    }

    pub fn writeBool(self: *JsonWriter, v: bool) Error!void {
        if (!self.in_key) try self.writeCommaIfNeeded();
        self.in_key = false;
        try self.out.writeAll(if (v) "true" else "false");
        self.needs_comma = true;
    }

    /// Emit a final newline. Useful as the last write of a document.
    pub fn newline(self: *JsonWriter) Error!void {
        try self.out.writeByte('\n');
    }

    /// Returns true if the writer has no open containers — i.e. the document
    /// is properly closed. Callers can assert this before flush as a final
    /// sanity check.
    pub fn isBalanced(self: *const JsonWriter) bool {
        return self.stack.items.len == 0;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    fn writeCommaIfNeeded(self: *JsonWriter) Error!void {
        if (self.needs_comma) {
            try self.out.writeByte(',');
        }
        if (self.pretty and !self.in_key and (self.needs_comma or self.needs_newline)) {
            try self.writeNewline();
            try self.writeIndent();
        }
        self.needs_newline = false;
    }

    fn writeEscapedString(self: *JsonWriter, s: []const u8) Error!void {
        try self.out.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.out.writeAll("\\\""),
                '\\' => try self.out.writeAll("\\\\"),
                '\n' => try self.out.writeAll("\\n"),
                '\r' => try self.out.writeAll("\\r"),
                '\t' => try self.out.writeAll("\\t"),
                0x08 => try self.out.writeAll("\\b"),
                0x0C => try self.out.writeAll("\\f"),
                else => {
                    if (c < 0x20) {
                        // RFC 8259 §7 requires \u escaping for U+0000..U+001F.
                        var buf: [6]u8 = .{ '\\', 'u', '0', '0', undefined, undefined };
                        buf[4] = hexDigit(c >> 4);
                        buf[5] = hexDigit(c & 0x0F);
                        try self.out.writeAll(&buf);
                    } else {
                        try self.out.writeByte(c);
                    }
                },
            }
        }
        try self.out.writeByte('"');
    }

    fn writeIndent(self: *JsonWriter) Error!void {
        var i: usize = 0;
        while (i < self.stack.items.len) : (i += 1) {
            try self.out.writeAll("  ");
        }
    }

    fn writeNewline(self: *JsonWriter) Error!void {
        try self.out.writeByte('\n');
    }
};

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

// ============================================================================
// RFC 8259 §6 number grammar
//
//   number  = [ minus ] int [ frac ] [ exp ]
//   minus   = %x2D                                ; "-"
//   int     = zero / ( digit1-9 *DIGIT )           ; NO LEADING ZEROS
//   zero    = %x30                                ; "0"
//   digit1-9= %x31-39
//   frac    = decimal-point 1*DIGIT                ; at least one digit
//   exp     = e [ minus / plus ] 1*DIGIT           ; at least one digit
//
// Notable: "01", "1.", ".5", "1e", "1e+", "NaN", "Infinity" are all rejected.
// ============================================================================

pub fn isValidJsonNumber(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;

    // Optional minus
    if (s[i] == '-') {
        i += 1;
        if (i >= s.len) return false;
    }

    // int: "0" or "1-9" followed by zero+ digits
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    } else {
        return false;
    }

    // Optional frac: must be ".DIGIT+"
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }

    // Optional exp: must be (e|E) [+|-] DIGIT+
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }

    return i == s.len;
}

// ============================================================================
// Tests
//
// Organized into three tiers per the standardization rule:
//   Tier 1: externally-anchored vectors (RFC 8259 grammar, exact JSON output)
//   Tier 2: failure-mode tests (bracket mismatch, invalid numbers, etc.)
//   Tier 3: internal-consistency tests (roundtrips, smoke)
// ============================================================================

const testing = std.testing;

/// Helper that builds a JsonWriter against an in-memory sink, runs a closure,
/// and returns the produced bytes. The caller frees them.
fn writeTo(
    allocator: std.mem.Allocator,
    pretty: bool,
    f: anytype,
) ![]u8 {
    var alloc: std.Io.Writer.Allocating = .init(allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(allocator, &alloc.writer, pretty);
    defer jw.deinit();

    try f(&jw);
    try testing.expect(jw.isBalanced());

    return try alloc.toOwnedSlice();
}

// ----- Tier 1: RFC 8259 number grammar -----

test "tier1: isValidJsonNumber accepts canonical RFC 8259 numbers" {
    const ok = [_][]const u8{
        "0",         "-0",     "1",      "-1",       "42",
        "100",       "-100",   "3.14",   "-3.14",    "0.5",
        "-0.5",      "1e10",   "1E10",   "1e+10",    "1e-10",
        "1.5e10",    "2.5E-3", "0e0",    "0.0e0",    "-0.0",
        "123456789012345678901234567890", // big int — syntactically valid
    };
    for (ok) |n| {
        try testing.expect(isValidJsonNumber(n));
    }
}

test "tier1: isValidJsonNumber rejects RFC 8259 violators" {
    const bad = [_][]const u8{
        "",       "-",     "+",     "+1",   ".5",
        "5.",     "1.",    "1.e3",  "01",   "00",
        "007",    "-01",   "1e",    "1e+",  "1e-",
        "1.0e",   "1.2.3", "1,5",   "NaN",  "nan",
        "Infinity", "-Infinity", "inf", "0x10", "0b10",
        " 1",     "1 ",    "1 0",   "1_000",
    };
    for (bad) |n| {
        try testing.expect(!isValidJsonNumber(n));
    }
}

test "tier1: JsonWriter emits exact RFC 8259 object syntax" {
    const out = try writeTo(testing.allocator, false, struct {
        fn run(jw: *JsonWriter) !void {
            try jw.beginObject();
            try jw.key("a");
            try jw.number("1");
            try jw.key("b");
            try jw.string("hi");
            try jw.endObject();
        }
    }.run);
    defer testing.allocator.free(out);

    try testing.expectEqualSlices(u8, "{\"a\":1,\"b\":\"hi\"}", out);
}

test "tier1: JsonWriter emits exact RFC 8259 array syntax" {
    const out = try writeTo(testing.allocator, false, struct {
        fn run(jw: *JsonWriter) !void {
            try jw.beginArray();
            try jw.number("1");
            try jw.number("2");
            try jw.number("3");
            try jw.endArray();
        }
    }.run);
    defer testing.allocator.free(out);

    try testing.expectEqualSlices(u8, "[1,2,3]", out);
}

test "tier1: JsonWriter pretty-prints with stable 2-space indent" {
    const out = try writeTo(testing.allocator, true, struct {
        fn run(jw: *JsonWriter) !void {
            try jw.beginArray();
            try jw.beginObject();
            try jw.key("k");
            try jw.number("1");
            try jw.endObject();
            try jw.endArray();
        }
    }.run);
    defer testing.allocator.free(out);

    const expected =
        \\[
        \\  {
        \\    "k": 1
        \\  }
        \\]
    ;
    try testing.expectEqualSlices(u8, expected, out);
}

test "tier1: string escapes per RFC 8259 §7" {
    const out = try writeTo(testing.allocator, false, struct {
        fn run(jw: *JsonWriter) !void {
            try jw.string("\"\\\n\r\t\x08\x0c\x00\x01");
        }
    }.run);
    defer testing.allocator.free(out);

    // Quote, backslash, newline, CR, tab, BS, FF, U+0000, U+0001.
    try testing.expectEqualSlices(u8, "\"\\\"\\\\\\n\\r\\t\\b\\f\\u0000\\u0001\"", out);
}

// ----- Tier 2: failure modes -----

test "tier2: number() rejects leading zeros" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try jw.beginArray();
    try testing.expectError(Error.InvalidNumber, jw.number("007"));
}

test "tier2: number() rejects NaN/Infinity" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try jw.beginArray();
    try testing.expectError(Error.InvalidNumber, jw.number("NaN"));
    try testing.expectError(Error.InvalidNumber, jw.number("Infinity"));
}

test "tier2: number() rejects empty input" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try jw.beginArray();
    try testing.expectError(Error.InvalidNumber, jw.number(""));
}

test "tier2: endObject inside array returns WrongContainer" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try jw.beginArray();
    try testing.expectError(Error.WrongContainer, jw.endObject());
}

test "tier2: endArray inside object returns WrongContainer" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try jw.beginObject();
    try testing.expectError(Error.WrongContainer, jw.endArray());
}

test "tier2: endObject with no open container returns UnbalancedClose" {
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    try testing.expectError(Error.UnbalancedClose, jw.endObject());
}

test "tier2: stack grows past the old 64-deep silent-truncation point" {
    // Old code silently capped at depth 64. New code uses a growable
    // ArrayList — verify a depth of 200 nested arrays round-trips.
    var alloc: std.Io.Writer.Allocating = .init(testing.allocator);
    defer alloc.deinit();

    var jw = JsonWriter.init(testing.allocator, &alloc.writer, false);
    defer jw.deinit();

    const N = 200;
    var i: usize = 0;
    while (i < N) : (i += 1) try jw.beginArray();
    try testing.expectEqual(@as(usize, N), jw.stack.items.len);

    i = 0;
    while (i < N) : (i += 1) try jw.endArray();
    try testing.expect(jw.isBalanced());

    const bytes = try alloc.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 2 * N), bytes.len);
    var k: usize = 0;
    while (k < N) : (k += 1) try testing.expectEqual(@as(u8, '['), bytes[k]);
    while (k < 2 * N) : (k += 1) try testing.expectEqual(@as(u8, ']'), bytes[k]);
}

// ----- Tier 3: roundtrip via std.json -----

test "tier3: output parses cleanly under std.json" {
    // Anchor the writer against an independent reader (Zig's std.json).
    // If our writer ever emits something std.json rejects, this fails —
    // catching grammar drift on the writer side.
    const out = try writeTo(testing.allocator, false, struct {
        fn run(jw: *JsonWriter) !void {
            try jw.beginObject();
            try jw.key("nums");
            try jw.beginArray();
            try jw.number("1");
            try jw.number("-2.5");
            try jw.number("1e10");
            try jw.endArray();
            try jw.key("name");
            try jw.string("Alice");
            try jw.key("flag");
            try jw.writeBool(true);
            try jw.key("none");
            try jw.writeNull();
            try jw.endObject();
        }
    }.run);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("nums").? == .array);
    try testing.expectEqualStrings("Alice", parsed.value.object.get("name").?.string);
    try testing.expectEqual(true, parsed.value.object.get("flag").?.bool);
    try testing.expect(parsed.value.object.get("none").? == .null);
}
