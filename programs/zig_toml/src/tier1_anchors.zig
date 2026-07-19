//! Tier-1 externally-anchored vectors for the TOML 1.0 parser.
//!
//! Inputs and expected outcomes come from the [`toml-test`](https://github.com/toml-lang/toml-test)
//! cross-implementation corpus and the spec's worked examples. The
//! authoring party for every vector here is NOT this codebase — that is the
//! gate criterion from `/CLAUDE.md` rule #1. Roundtrip-only tests do not
//! count.
//!
//! Each valid-case test checks specific *bytes* of the parsed output (not
//! just "parser returned without error"); each invalid-case test asserts
//! the *kind* of error.
//!
//! Rule (from `/CLAUDE.md`): if you delete every roundtrip test in this
//! repo, the tier-1 file alone must still cover encode + decode for every
//! public function. Weakening or removing any anchor in this file requires
//! a re-audit with a citation, not a refactor.

const std = @import("std");
const toml = @import("zig_toml");

const testing = std.testing;

// ============================================================================
// Helpers
// ============================================================================

/// Parse, assert success, return the root table. Caller deinits.
fn parseOk(input: []const u8) !toml.Table {
    return toml.parseToml(testing.allocator, input);
}

/// Parse, assert it fails with `expected_error`, free any partial state.
fn parseErr(input: []const u8, expected_error: toml.ParseError) !void {
    const result = toml.parseToml(testing.allocator, input);
    if (result) |t| {
        var mut = t;
        mut.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

// ============================================================================
// Valid cases — spec & toml-test/valid/*
// ============================================================================

test "anchor: empty document" {
    var t = try parseOk("");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), t.count());
}

test "anchor: comments-only document" {
    var t = try parseOk("# a comment\n# another\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), t.count());
}

test "anchor: spec example - title" {
    // From the TOML 1.0 spec front page.
    var t = try parseOk("title = \"TOML Example\"\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "TOML Example", t.get("title").?.string);
}

test "anchor: spec example - bare key with hyphen" {
    var t = try parseOk("first-name = \"Tom\"\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "Tom", t.get("first-name").?.string);
}

test "anchor: spec example - quoted key with dots" {
    // The TOML spec example: "1.2.3" as a single dotted-looking key.
    var t = try parseOk("\"127.0.0.1\" = \"value\"\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "value", t.get("127.0.0.1").?.string);
}

test "anchor: dotted keys with deep nesting (spec example)" {
    // From TOML 1.0 §Keys.
    var t = try parseOk("apple.color = \"red\"\napple.taste.sweet = true\n");
    defer t.deinit(testing.allocator);
    const apple = t.get("apple").?.table;
    try testing.expectEqualSlices(u8, "red", apple.get("color").?.string);
    try testing.expectEqual(true, apple.get("taste").?.table.get("sweet").?.boolean);
}

test "anchor: spec example - explicit [a.b.c] header" {
    // From TOML 1.0 §Tables.
    var t = try parseOk("[dog.\"tater.man\"]\ntype.name = \"pug\"\n");
    defer t.deinit(testing.allocator);
    const inner = t.get("dog").?.table.get("tater.man").?.table;
    try testing.expectEqualSlices(u8, "pug", inner.get("type").?.table.get("name").?.string);
}

test "anchor: array-of-tables [[products]] from spec" {
    // From TOML 1.0 §Array-of-Tables, lightly trimmed.
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]  # empty table within the array
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
        \\color = "gray"
        \\
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    const products = t.get("products").?.array;
    try testing.expectEqual(@as(usize, 3), products.items.items.len);
    try testing.expectEqualSlices(u8, "Hammer", products.items.items[0].table.get("name").?.string);
    try testing.expectEqual(@as(u32, 0), products.items.items[1].table.count());
    try testing.expectEqualSlices(u8, "Nail", products.items.items[2].table.get("name").?.string);
    try testing.expectEqualSlices(u8, "gray", products.items.items[2].table.get("color").?.string);
}

test "anchor: nested [[a.b]] array of tables" {
    // toml-test/valid/inline-table/nested.toml flavor.
    const input =
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]
        \\color = "red"
        \\shape = "round"
        \\
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
        \\[[fruits.varieties]]
        \\name = "plantain"
        \\
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    const fruits = t.get("fruits").?.array;
    try testing.expectEqual(@as(usize, 2), fruits.items.items.len);

    const apple = fruits.items.items[0].table;
    try testing.expectEqualSlices(u8, "apple", apple.get("name").?.string);
    try testing.expectEqualSlices(u8, "red", apple.get("physical").?.table.get("color").?.string);
    try testing.expectEqual(@as(usize, 2), apple.get("varieties").?.array.items.items.len);
    try testing.expectEqualSlices(u8, "red delicious", apple.get("varieties").?.array.items.items[0].table.get("name").?.string);

    const banana = fruits.items.items[1].table;
    try testing.expectEqualSlices(u8, "banana", banana.get("name").?.string);
    try testing.expectEqualSlices(u8, "plantain", banana.get("varieties").?.array.items.items[0].table.get("name").?.string);
}

test "anchor: basic string with all standard escapes" {
    var t = try parseOk("s = \"\\b\\t\\n\\f\\r\\\"\\\\\"\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "\x08\t\n\x0c\r\"\\", t.get("s").?.string);
}

test "anchor: \\uXXXX 4-digit unicode escape" {
    var t = try parseOk("s = \"\\u00E9\"\n");
    defer t.deinit(testing.allocator);
    // U+00E9 = é (2 bytes in UTF-8: 0xC3 0xA9)
    try testing.expectEqualSlices(u8, "\xC3\xA9", t.get("s").?.string);
}

test "anchor: \\UXXXXXXXX 8-digit unicode escape" {
    var t = try parseOk("s = \"\\U0001F600\"\n");
    defer t.deinit(testing.allocator);
    // U+1F600 = 😀 (4 bytes in UTF-8: 0xF0 0x9F 0x98 0x80)
    try testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", t.get("s").?.string);
}

test "anchor: literal string (no escape interpretation)" {
    // toml-test/valid/string/raw.toml — literal strings disable escapes.
    var t = try parseOk("s = 'C:\\Users\\nodejs\\templates'\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "C:\\Users\\nodejs\\templates", t.get("s").?.string);
}

test "anchor: multiline basic string trims leading newline" {
    // toml-test/valid/string/multiline.toml.
    const input =
        \\s = """
        \\Roses are red
        \\Violets are blue"""
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "Roses are red\nViolets are blue", t.get("s").?.string);
}

test "anchor: multiline literal string trims leading newline" {
    const input =
        \\s = '''
        \\1 < 2 \n
        \\3 > 4'''
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    // Literal: backslashes are not interpreted, so "\n" stays as two chars.
    try testing.expectEqualSlices(u8, "1 < 2 \\n\n3 > 4", t.get("s").?.string);
}

test "anchor: line-ending backslash joins lines in multiline basic" {
    // toml-test/valid/string/multiline-backslash.toml.
    const input =
        \\s = """\
        \\       The quick brown \
        \\       fox jumps over \
        \\       the lazy dog."""
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "The quick brown fox jumps over the lazy dog.", t.get("s").?.string);
}

test "anchor: integer formats - decimal" {
    var t = try parseOk("a = 0\nb = 99\nc = -17\nd = +42\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), t.get("a").?.integer);
    try testing.expectEqual(@as(i64, 99), t.get("b").?.integer);
    try testing.expectEqual(@as(i64, -17), t.get("c").?.integer);
    try testing.expectEqual(@as(i64, 42), t.get("d").?.integer);
}

test "anchor: integer formats - hex/oct/bin (spec)" {
    // From TOML 1.0 §Integer.
    var t = try parseOk(
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\hex3 = 0xdead_beef
        \\oct1 = 0o01234567
        \\oct2 = 0o755
        \\bin1 = 0b11010110
        \\
    );
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), t.get("hex1").?.integer);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), t.get("hex2").?.integer);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), t.get("hex3").?.integer);
    try testing.expectEqual(@as(i64, 0o01234567), t.get("oct1").?.integer);
    try testing.expectEqual(@as(i64, 0o755), t.get("oct2").?.integer);
    try testing.expectEqual(@as(i64, 0b11010110), t.get("bin1").?.integer);
}

test "anchor: number underscores between digits (spec)" {
    var t = try parseOk("a = 5_349_221\nb = 1_2_3_4_5\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 5_349_221), t.get("a").?.integer);
    try testing.expectEqual(@as(i64, 12345), t.get("b").?.integer);
}

test "anchor: float formats (spec)" {
    var t = try parseOk(
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\flt7 = 6.626e-34
        \\flt8 = 9_224_617.445_991_228_313
        \\
    );
    defer t.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 1.0), t.get("flt1").?.float, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3.1415), t.get("flt2").?.float, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.01), t.get("flt3").?.float, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5e22), t.get("flt4").?.float, 1e10);
    try testing.expectApproxEqAbs(@as(f64, 1e6), t.get("flt5").?.float, 1.0);
    try testing.expectApproxEqAbs(@as(f64, -2e-2), t.get("flt6").?.float, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 6.626e-34), t.get("flt7").?.float, 1e-44);
}

test "anchor: float inf/nan (spec)" {
    var t = try parseOk("a = inf\nb = +inf\nc = -inf\nd = nan\ne = +nan\nf = -nan\n");
    defer t.deinit(testing.allocator);
    try testing.expect(std.math.isPositiveInf(t.get("a").?.float));
    try testing.expect(std.math.isPositiveInf(t.get("b").?.float));
    try testing.expect(std.math.isNegativeInf(t.get("c").?.float));
    try testing.expect(std.math.isNan(t.get("d").?.float));
    try testing.expect(std.math.isNan(t.get("e").?.float));
    try testing.expect(std.math.isNan(t.get("f").?.float));
}

test "anchor: booleans" {
    var t = try parseOk("a = true\nb = false\n");
    defer t.deinit(testing.allocator);
    try testing.expect(t.get("a").?.boolean);
    try testing.expect(!t.get("b").?.boolean);
}

test "anchor: offset datetime (spec)" {
    var t = try parseOk("odt1 = 1979-05-27T07:32:00Z\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1979-05-27T07:32:00Z", t.get("odt1").?.datetime);
}

test "anchor: offset datetime with explicit offset" {
    var t = try parseOk("odt = 1979-05-27T00:32:00-07:00\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1979-05-27T00:32:00-07:00", t.get("odt").?.datetime);
}

test "anchor: local date" {
    var t = try parseOk("ld = 1979-05-27\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1979-05-27", t.get("ld").?.datetime);
}

test "anchor: local time" {
    var t = try parseOk("lt = 07:32:00\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "07:32:00", t.get("lt").?.datetime);
}

test "anchor: spec example - integers array" {
    var t = try parseOk("integers = [ 1, 2, 3 ]\n");
    defer t.deinit(testing.allocator);
    const arr = t.get("integers").?.array;
    try testing.expectEqual(@as(usize, 3), arr.items.items.len);
    try testing.expectEqual(@as(i64, 1), arr.items.items[0].integer);
    try testing.expectEqual(@as(i64, 3), arr.items.items[2].integer);
}

test "anchor: mixed-type array (TOML 1.0 allows)" {
    var t = try parseOk("a = [1, \"two\", 3.0, true]\n");
    defer t.deinit(testing.allocator);
    const arr = t.get("a").?.array;
    try testing.expectEqual(@as(i64, 1), arr.items.items[0].integer);
    try testing.expectEqualSlices(u8, "two", arr.items.items[1].string);
    try testing.expectApproxEqAbs(@as(f64, 3.0), arr.items.items[2].float, 1e-12);
    try testing.expect(arr.items.items[3].boolean);
}

test "anchor: array with newlines and trailing comma" {
    const input =
        \\arr = [
        \\  1,
        \\  2,
        \\  3,
        \\]
        \\
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), t.get("arr").?.array.items.items.len);
}

test "anchor: inline table (spec)" {
    var t = try parseOk("name = { first = \"Tom\", last = \"Preston-Werner\" }\n");
    defer t.deinit(testing.allocator);
    const name = t.get("name").?.table;
    try testing.expectEqualSlices(u8, "Tom", name.get("first").?.string);
    try testing.expectEqualSlices(u8, "Preston-Werner", name.get("last").?.string);
}

test "anchor: empty inline table" {
    var t = try parseOk("empty = {}\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), t.get("empty").?.table.count());
}

test "anchor: cargo-toml-shaped document (subset)" {
    // A miniature Cargo.toml. If this fails, the audit's "dotted keys +
    // [[arrayoftables]] not supported" finding has regressed.
    const input =
        \\[package]
        \\name = "my-crate"
        \\version = "0.1.0"
        \\edition = "2021"
        \\
        \\[dependencies]
        \\serde = { version = "1.0", features = ["derive"] }
        \\
        \\[[bin]]
        \\name = "main"
        \\path = "src/main.rs"
        \\
        \\[[bin]]
        \\name = "tool"
        \\path = "src/tool.rs"
        \\
    ;
    var t = try parseOk(input);
    defer t.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, "my-crate", t.get("package").?.table.get("name").?.string);
    try testing.expectEqualSlices(u8, "2021", t.get("package").?.table.get("edition").?.string);

    const serde = t.get("dependencies").?.table.get("serde").?.table;
    try testing.expectEqualSlices(u8, "1.0", serde.get("version").?.string);
    try testing.expectEqualSlices(u8, "derive", serde.get("features").?.array.items.items[0].string);

    const bins = t.get("bin").?.array;
    try testing.expectEqual(@as(usize, 2), bins.items.items.len);
    try testing.expectEqualSlices(u8, "main", bins.items.items[0].table.get("name").?.string);
    try testing.expectEqualSlices(u8, "src/tool.rs", bins.items.items[1].table.get("path").?.string);
}

// ============================================================================
// Invalid cases — toml-test/invalid/*
// ============================================================================

test "anchor invalid: duplicate top-level key" {
    try parseErr("name = \"A\"\nname = \"B\"\n", error.DuplicateKey);
}

test "anchor invalid: duplicate table header" {
    try parseErr("[a]\n[a]\n", error.DuplicateTable);
}

test "anchor invalid: duplicate inline-table key" {
    try parseErr("a = { b = 1, b = 2 }\n", error.DuplicateInlineKey);
}

test "anchor invalid: inline table redefined as [a.x]" {
    try parseErr("a = { b = 1 }\n[a.c]\nd = 2\n", error.CannotExtendInlineTable);
}

test "anchor invalid: [a] then [[a]] (kind conflict)" {
    try parseErr("[a]\nb = 1\n[[a]]\nc = 2\n", error.DuplicateTable);
}

test "anchor invalid: [[a]] then [a] (kind conflict)" {
    try parseErr("[[a]]\nb = 1\n[a]\nc = 2\n", error.DuplicateTable);
}

test "anchor invalid: dotted key conflicts with [header] redefine" {
    try parseErr("a.b = 1\n[a.b]\nc = 2\n", error.DuplicateTable);
}

test "anchor invalid: extending static array via [[name]]" {
    try parseErr("xs = [1, 2, 3]\n[[xs]]\nx = 1\n", error.CannotExtendStaticArray);
}

test "anchor invalid: leading-zero integer" {
    try parseErr("a = 042\n", error.InvalidNumber);
}

test "anchor invalid: reserved escape \\x" {
    try parseErr("a = \"\\xab\"\n", error.InvalidEscape);
}

test "anchor invalid: reserved escape \\z" {
    try parseErr("a = \"\\z\"\n", error.InvalidEscape);
}

test "anchor invalid: \\u with non-hex digits" {
    try parseErr("a = \"\\uXYZW\"\n", error.InvalidUnicodeEscape);
}

test "anchor invalid: \\u truncated at EOF" {
    try parseErr("a = \"\\u00\"\n", error.InvalidUnicodeEscape);
}

test "anchor invalid: \\U truncated" {
    try parseErr("a = \"\\U0001F60\"\n", error.InvalidUnicodeEscape);
}

test "anchor invalid: unicode surrogate half rejected" {
    try parseErr("a = \"\\uD800\"\n", error.Utf8CannotEncodeSurrogateHalf);
}

test "anchor invalid: codepoint above U+10FFFF" {
    try parseErr("a = \"\\U00FFFFFF\"\n", error.CodepointTooLarge);
}

test "anchor invalid: unterminated basic string" {
    try parseErr("a = \"abc\n", error.UnterminatedString);
}

test "anchor invalid: unterminated multiline basic string" {
    try parseErr("a = \"\"\"abc\n", error.UnterminatedString);
}

test "anchor invalid: trailing underscore in number" {
    try parseErr("a = 1_\n", error.InvalidNumber);
}

test "anchor invalid: leading underscore in number" {
    try parseErr("a = _1\n", error.InvalidValue);
}

test "anchor invalid: double underscore in number" {
    try parseErr("a = 1__0\n", error.InvalidNumber);
}

test "anchor invalid: newline inside inline table" {
    try parseErr("a = { b = 1,\n  c = 2 }\n", error.UnexpectedCharacter);
}

// ============================================================================
// DoS regression — depth limit
// ============================================================================

test "anchor DoS: 5,000-deep inline array errors with MaxDepthExceeded" {
    // 5,000 levels of `[` followed by 5,000 `]`. Pre-audit would crash via
    // stack overflow; the depth cap (default 512) makes it a clean error.
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "x = ");
    var i: usize = 0;
    while (i < 5_000) : (i += 1) try input.append(testing.allocator, '[');
    while (i > 0) : (i -= 1) try input.append(testing.allocator, ']');
    try parseErr(input.items, error.MaxDepthExceeded);
}

test "anchor DoS: 5,000-deep inline table errors with MaxDepthExceeded" {
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "x = ");
    var i: usize = 0;
    while (i < 5_000) : (i += 1) try input.appendSlice(testing.allocator, "{ a = ");
    try input.append(testing.allocator, '1');
    while (i > 0) : (i -= 1) try input.append(testing.allocator, '}');
    try parseErr(input.items, error.MaxDepthExceeded);
}

test "anchor DoS: 5,000-segment dotted key errors with MaxDepthExceeded" {
    // `a.a.a.….a = 1` with 5,000 segments. Pre-fix this built a 5,000-deep
    // table chain from ~10 KB of input (no cap on dotted-key nesting), and the
    // caller's mandatory `deinit` overflowed the C stack tearing it down. Now
    // the header/dotted-key depth cap rejects it up front (mirrors the inline
    // array/table caps), and the iterative `deinit` frees any legitimate deep
    // tree without recursing.
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        if (i != 0) try input.append(testing.allocator, '.');
        try input.append(testing.allocator, 'a');
    }
    try input.appendSlice(testing.allocator, " = 1\n");
    try parseErr(input.items, error.MaxDepthExceeded);
}

test "anchor DoS: 5,000-segment table header errors with MaxDepthExceeded" {
    // `[a.a.a.….a]` with 5,000 segments — same stack-overflow-on-teardown DoS
    // via a table header instead of a dotted key.
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.append(testing.allocator, '[');
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        if (i != 0) try input.append(testing.allocator, '.');
        try input.append(testing.allocator, 'a');
    }
    try input.appendSlice(testing.allocator, "]\n");
    try parseErr(input.items, error.MaxDepthExceeded);
}

test "anchor DoS: deeply-nested tree frees without stack overflow" {
    // A legitimately deep tree (built right at the cap) must be freeable by the
    // mandatory `deinit` on any stack size — this exercises the iterative
    // teardown path. `max_depth`-1 dotted segments parse successfully; if
    // `deinit` were still recursive this would risk overflow on constrained
    // stacks. Success here means the whole chain was freed iteratively.
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    var i: usize = 0;
    const depth = 500; // < DEFAULT_MAX_DEPTH (512)
    while (i < depth) : (i += 1) {
        if (i != 0) try input.append(testing.allocator, '.');
        try input.append(testing.allocator, 'a');
    }
    try input.appendSlice(testing.allocator, " = 1\n");
    var t = try parseOk(input.items);
    t.deinit(testing.allocator);
}

// ============================================================================
// Raw control characters (toml-test invalid/control/*)
//
// TOML 1.0 forbids unescaped control chars (U+0000–U+0008, U+000A–U+001F,
// U+007F) in basic/literal strings (tab excepted) and in comments. Inputs and
// expected-invalid outcomes are the toml-test corpus's `invalid/control/*`
// cases; the specific byte values (NUL, US = U+001F, DEL = U+007F) are theirs.
// ============================================================================

test "anchor invalid control: NUL in basic string (string-null)" {
    try parseErr("a = \"\x00\"\n", error.ControlCharacterInString);
}

test "anchor invalid control: unit separator in basic string (string-us)" {
    try parseErr("a = \"\x1f\"\n", error.ControlCharacterInString);
}

test "anchor invalid control: DEL in basic string (string-del)" {
    try parseErr("a = \"\x7f\"\n", error.ControlCharacterInString);
}

test "anchor invalid control: NUL in literal string (rawstring-null)" {
    try parseErr("a = '\x00'\n", error.ControlCharacterInString);
}

test "anchor invalid control: DEL in literal string (rawstring-del)" {
    try parseErr("a = '\x7f'\n", error.ControlCharacterInString);
}

test "anchor invalid control: NUL in multiline basic string (multi-null)" {
    try parseErr("a = \"\"\"\x00\"\"\"\n", error.ControlCharacterInString);
}

test "anchor invalid control: unit separator in multiline literal (rawmulti-us)" {
    try parseErr("a = '''\x1f'''\n", error.ControlCharacterInString);
}

test "anchor invalid control: NUL in comment (comment-null)" {
    try parseErr("# \x00\n", error.ControlCharacterInComment);
}

test "anchor invalid control: unit separator in comment (comment-us)" {
    try parseErr("# \x1f\n", error.ControlCharacterInComment);
}

test "anchor invalid control: DEL in comment (comment-del)" {
    try parseErr("# \x7f\n", error.ControlCharacterInComment);
}

test "anchor valid control: tab is permitted in a basic string" {
    // Tab (U+0009) is the one control char TOML allows unescaped in strings.
    var t = try parseOk("a = \"x\ty\"\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "x\ty", t.get("a").?.string);
}

// ============================================================================
// Datetime field-range validation (toml-test valid/datetime/* and
// invalid/datetime/*)
//
// TOML 1.0 §Date-Time = RFC 3339. The parser lexes the raw slice and now
// validates field ranges. Inputs and expected outcomes are the toml-test
// corpus's `datetime` cases (the specific values — `1987-07-05T17:45:00.6Z`,
// the `2006-01-01T24:00:00Z` hour-over case, the `2006-01-32` mday-over case,
// month-over, second-over, and the `2100-02-29` non-leap-Feb-29 — are theirs).
// ============================================================================

test "anchor valid datetime: offset with fractional seconds (datetime)" {
    var t = try parseOk("odt = 1987-07-05T17:45:00.6Z\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1987-07-05T17:45:00.6Z", t.get("odt").?.datetime);
}

test "anchor valid datetime: space separator between date and time (datetime)" {
    // RFC 3339 §5.6 NOTE / toml-test valid/datetime/datetime.toml permit a
    // single space in place of 'T'.
    var t = try parseOk("odt = 1987-07-05 17:45:00Z\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1987-07-05 17:45:00Z", t.get("odt").?.datetime);
}

test "anchor valid datetime: local date-time (no offset)" {
    var t = try parseOk("ldt = 1979-05-27T07:32:00\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1979-05-27T07:32:00", t.get("ldt").?.datetime);
}

test "anchor valid datetime: leap day in a leap year (2020-02-29)" {
    var t = try parseOk("ld = 2020-02-29\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "2020-02-29", t.get("ld").?.datetime);
}

test "anchor valid datetime: second 60 (leap second)" {
    var t = try parseOk("odt = 1990-12-31T23:59:60Z\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1990-12-31T23:59:60Z", t.get("odt").?.datetime);
}

test "anchor invalid datetime: hour 24 (hour-over)" {
    try parseErr("d = 2006-01-01T24:00:00Z\n", error.InvalidDateTime);
}

test "anchor invalid datetime: minute 61 (minute-over)" {
    try parseErr("d = 2006-01-01T00:61:00Z\n", error.InvalidDateTime);
}

test "anchor invalid datetime: second 61 (second-over)" {
    try parseErr("d = 2006-01-01T00:00:61Z\n", error.InvalidDateTime);
}

test "anchor invalid datetime: day 32 (mday-over)" {
    try parseErr("d = 2006-01-32T00:00:00Z\n", error.InvalidDateTime);
}

test "anchor invalid datetime: month 13 (month-over)" {
    try parseErr("d = 2006-13-01T00:00:00Z\n", error.InvalidDateTime);
}

test "anchor invalid datetime: Feb 30 does not exist" {
    try parseErr("d = 2021-02-30\n", error.InvalidDateTime);
}

test "anchor invalid datetime: Feb 29 in a non-leap century year (2100)" {
    // 2100 is divisible by 100 but not 400 → not a leap year.
    try parseErr("d = 2100-02-29\n", error.InvalidDateTime);
}

// ============================================================================
// UTF-8 document validation (toml-test invalid/encoding/*)
//
// TOML 1.0: "A TOML file must be a valid UTF-8 encoded Unicode document." The
// parser validates the whole input before parsing. The byte sequences below
// (a lone 0xFF, a truncated two-byte lead 0xC3 with a non-continuation 0x28,
// a bare continuation byte 0x80) are the classic ill-formed-UTF-8 shapes the
// corpus's `invalid/encoding/bad-utf8-*` cases exercise.
// ============================================================================

test "anchor invalid utf8: lone 0xFF byte in a basic string" {
    try parseErr("a = \"\xff\"\n", error.InvalidUtf8);
}

test "anchor invalid utf8: truncated two-byte sequence (0xC3 0x28) in a string" {
    try parseErr("a = \"\xc3\x28\"\n", error.InvalidUtf8);
}

test "anchor invalid utf8: bare continuation byte (0x80) in a string" {
    try parseErr("a = \"\x80\"\n", error.InvalidUtf8);
}

test "anchor invalid utf8: ill-formed byte in a comment" {
    // Whole-document validation catches it regardless of where it sits.
    try parseErr("# \xff\n", error.InvalidUtf8);
}

test "anchor valid utf8: multi-byte content in a literal string is preserved" {
    // Snowman U+2603 (0xE2 0x98 0x83) — valid UTF-8, must pass validation and
    // round-trip verbatim in a literal string.
    var t = try parseOk("a = '\xe2\x98\x83'\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "\xe2\x98\x83", t.get("a").?.string);
}
