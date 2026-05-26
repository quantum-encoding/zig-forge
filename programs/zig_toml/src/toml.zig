//! Full TOML 1.0.0 parser.
//!
//! Bidirectional? No — this is a **read-only** parser. The directory name
//! `zig_toml` is grandfathered in; emission is not implemented. See
//! `/CLAUDE.md` rule #2; if a serializer is needed, add a separate
//! `zig_toml_writer` rather than overloading this module.
//!
//! ## Threat model
//!
//! This parser is designed to consume **untrusted input** safely:
//!
//!   * **Strict duplicate detection.** TOML 1.0 §Keys / §Tables forbids
//!     defining the same key or table twice. Every silent-overwrite path in
//!     the pre-audit version is now an explicit `DuplicateKey` /
//!     `DuplicateTable` / `DuplicateInlineKey` error.
//!   * **Depth-bounded recursion.** `max_depth` (default 512) caps the
//!     combined nesting of inline arrays and inline tables. A deeply-nested
//!     payload returns `MaxDepthExceeded` instead of overflowing the C stack.
//!   * **Exhaustive error cleanup.** Every duped string and partial table
//!     created during parsing is freed via `errdefer` if any subsequent step
//!     fails. The previous version leaked on every parse error.
//!   * **No fixed-capacity surprises.** Arrays grow dynamically; the
//!     pre-audit 256-element `appendAssumeCapacity` panic trap is gone.
//!
//! ## Feature coverage (TOML 1.0)
//!
//!   * Bare and quoted keys, dotted keys (`a.b.c = 1`)
//!   * Standard tables `[a.b]`, array-of-tables `[[a.b]]`
//!   * Strings: basic, literal, multiline basic, multiline literal
//!   * All escapes: `\b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX`. Unknown
//!     escapes (`\x`, `\z`, etc.) are rejected per spec.
//!   * Integers: decimal (with sign, with `_` separators), `0x` hex,
//!     `0o` octal, `0b` binary
//!   * Floats: decimal, exponent, `_` separators, `inf` / `nan` / `+inf` /
//!     `-inf` / `+nan` / `-nan`
//!   * Booleans, inline arrays, inline tables
//!   * Datetimes: offset, local, date-only, time-only (validated and stored
//!     as raw `[]const u8`; the caller may use `std.fmt`/`std.time` for
//!     structured decoding)
//!   * Comments
//!
//! ## Lifetime contract
//!
//! `parseToml` returns a `Table` value. The caller calls
//! `result.deinit(allocator)` to recursively free all strings, arrays, and
//! nested tables. Every `[]const u8` value (string, datetime, key) is owned
//! by the result tree — there are no zero-copy slices into the input
//! buffer, so the caller may free the input immediately after parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Public types
// ============================================================================

/// Maximum combined nesting of inline arrays and inline tables. Matches the
/// limit used by `zig_msgpack` and msgpack-c. Configurable via
/// `Parser.max_depth`.
pub const DEFAULT_MAX_DEPTH: u32 = 512;

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedCharacter,
    ExpectedEquals,
    ExpectedCloseBracket,
    ExpectedDoubleCloseBracket,
    ExpectedCommaOrBracket,
    ExpectedCommaOrBrace,
    ExpectedCloseBrace,
    InvalidKey,
    InvalidValue,
    InvalidBoolean,
    InvalidNumber,
    InvalidFloat,
    InvalidDateTime,
    InvalidEscape,
    InvalidUnicodeEscape,
    UnterminatedString,
    DuplicateKey,
    DuplicateInlineKey,
    DuplicateTable,
    CannotExtendInlineTable,
    CannotExtendStaticArray,
    MaxDepthExceeded,
    OutOfMemory,
    Overflow,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    InvalidCharacter,
};

/// A TOML table. Owns its entries (keys are duped, values are owned).
///
/// Internal state flags (kind) are used by the parser to enforce strict
/// duplicate/redefinition rules. After parsing completes the flags are
/// ignored by callers.
pub const Table = struct {
    entries: std.StringHashMap(Value),

    /// Parser-internal lifecycle tag. Tracks whether this table was created
    /// by `[a]`, `[[a]]`, dotted-key inference, header inference, or inline.
    /// Callers may ignore this.
    kind: Kind = .root,

    pub const Kind = enum {
        /// The top-level document table.
        root,
        /// Declared via `[a]`. Cannot be redefined.
        explicit_header,
        /// Inferred parent because `[a.b]` or `[[a.b]]` was seen. May later
        /// be upgraded to `explicit_header` by an `[a]` line.
        implicit_header,
        /// Inferred parent because `a.b.c = 1` introduced an intermediate
        /// `a` or `a.b` table. CANNOT later be promoted via `[a]` per spec.
        implicit_dotted,
        /// An element of an array-of-tables (the table appended for each
        /// `[[a]]` line).
        aot_element,
        /// Declared via `{ x = 1 }`. Cannot have keys added to it later by
        /// any syntax.
        inline_frozen,
    };

    pub fn init(allocator: Allocator) Table {
        return .{ .entries = std.StringHashMap(Value).init(allocator) };
    }

    pub fn deinit(self: *Table, allocator: Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit();
    }

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn count(self: *const Table) u32 {
        return self.entries.count();
    }

    pub fn iterator(self: *Table) std.StringHashMap(Value).Iterator {
        return self.entries.iterator();
    }
};

/// A TOML value. `array` and `table` own their contents (recursively).
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    /// Raw datetime literal, e.g. `1979-05-27T07:32:00-08:00`. Validated for
    /// shape but not parsed into a structured time type.
    datetime: []const u8,
    array: Array,
    /// Heap-allocated for pointer stability during construction.
    table: *Table,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .datetime => |s| allocator.free(s),
            .array => |*arr| arr.deinit(allocator),
            .table => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
            else => {},
        }
    }
};

/// Array of values. Owns its items (recursively).
///
/// `is_aot` distinguishes `[[a]]`-style arrays-of-tables (which may be
/// extended by later `[[a]]` lines) from static arrays `a = [...]` (which
/// are frozen at the closing `]`).
pub const Array = struct {
    items: std.ArrayListUnmanaged(Value),
    is_aot: bool = false,

    pub fn deinit(self: *Array, allocator: Allocator) void {
        for (self.items.items) |*v| v.deinit(allocator);
        self.items.deinit(allocator);
    }
};

// ============================================================================
// Top-level entry point
// ============================================================================

/// Parse a TOML document. Returns the root table; caller calls
/// `result.deinit(allocator)` to free. Errors free any partial state before
/// returning.
pub fn parseToml(allocator: Allocator, input: []const u8) ParseError!Table {
    var parser = try Parser.init(allocator, input);
    defer parser.deinitParserState();
    return try parser.parse();
}

// ============================================================================
// Parser
// ============================================================================

pub const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    /// Combined depth of inline arrays and inline tables. Bumped on entry to
    /// `parseArray` / `parseInlineTable`; checked against `max_depth`.
    depth: u32,
    /// Cap on `depth`. Set by `init`; callers may override before `parse`.
    max_depth: u32,

    /// Parser-internal: pointer to the table that subsequent key=value lines
    /// write into. Repointed when a `[header]` or `[[header]]` line appears.
    current_table: *Table,

    /// Parser-internal: root of the document tree, heap-allocated for the
    /// same pointer-stability reason that nested tables are. Returned to the
    /// caller (by value) at the end of `parse`; on error, freed by the
    /// outer `errdefer` in `parse`.
    root_table: *Table,

    pub fn init(allocator: Allocator, input: []const u8) ParseError!Parser {
        const root = try allocator.create(Table);
        errdefer allocator.destroy(root);
        root.* = Table.init(allocator);
        root.kind = .root;

        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .depth = 0,
            .max_depth = DEFAULT_MAX_DEPTH,
            .current_table = root,
            .root_table = root,
        };
    }

    /// Free parser-internal state. The returned `Table` (if `parse`
    /// succeeded) is owned by the caller and is NOT freed here.
    pub fn deinitParserState(self: *Parser) void {
        _ = self;
        // (no parser-internal heap state beyond root_table; root_table
        //  ownership is handled by parse() — success transfers it to the
        //  caller, error frees it via errdefer.)
    }

    pub fn parse(self: *Parser) ParseError!Table {
        // If we exit via error, free the whole tree (including the heap
        // wrapper for the root).
        errdefer {
            self.root_table.deinit(self.allocator);
            self.allocator.destroy(self.root_table);
        }

        try self.parseDocument();

        // Detach root from its heap wrapper. We return Table by value so
        // the caller doesn't have to worry about an extra `destroy` step.
        const out = self.root_table.*;
        self.allocator.destroy(self.root_table);
        return out;
    }

    // ----------------------------------------------------------------------
    // Document-level parsing
    // ----------------------------------------------------------------------

    fn parseDocument(self: *Parser) ParseError!void {
        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.eof()) break;

            const ch = self.peek();
            if (ch == '#') {
                self.skipComment();
                continue;
            }

            if (ch == '[') {
                if (self.peekAt(1) == '[') {
                    try self.parseArrayOfTablesHeader();
                } else {
                    try self.parseTableHeader();
                }
                continue;
            }

            try self.parseKeyValueLine(self.current_table, .top_level);
        }
    }

    fn parseTableHeader(self: *Parser) ParseError!void {
        self.advance(); // skip '['
        self.skipWhitespaceLine();

        var segments = try self.parseDottedKey();
        defer freeSegments(self.allocator, &segments);

        self.skipWhitespaceLine();
        if (self.eof() or self.peek() != ']') return error.ExpectedCloseBracket;
        self.advance(); // skip ']'

        // Newline-or-EOF-or-comment must follow.
        try self.expectLineEnd();

        // Walk the dotted segments, creating implicit_header intermediates
        // as needed; the final segment is the declared table.
        const parent = try self.walkPathThroughImplicitHeaders(segments.items[0 .. segments.items.len - 1]);
        const leaf = segments.items[segments.items.len - 1];

        // Now resolve the final segment.
        if (parent.entries.getEntry(leaf)) |entry| {
            const val = entry.value_ptr;
            switch (val.*) {
                .table => |t| {
                    switch (t.kind) {
                        .implicit_header => {
                            // Upgrade implicit-header to explicit.
                            t.kind = .explicit_header;
                            self.current_table = t;
                        },
                        .explicit_header, .root, .aot_element => return error.DuplicateTable,
                        .implicit_dotted => return error.DuplicateTable,
                        .inline_frozen => return error.CannotExtendInlineTable,
                    }
                },
                .array => return error.DuplicateTable,
                else => return error.DuplicateKey,
            }
        } else {
            // Create new explicit-header table.
            const new_table = try self.allocator.create(Table);
            errdefer self.allocator.destroy(new_table);
            new_table.* = Table.init(self.allocator);
            new_table.kind = .explicit_header;
            errdefer new_table.deinit(self.allocator);

            const key_dup = try self.allocator.dupe(u8, leaf);
            errdefer self.allocator.free(key_dup);

            try parent.entries.put(key_dup, .{ .table = new_table });
            self.current_table = new_table;
        }
    }

    fn parseArrayOfTablesHeader(self: *Parser) ParseError!void {
        self.advance(); // first '['
        self.advance(); // second '['
        self.skipWhitespaceLine();

        var segments = try self.parseDottedKey();
        defer freeSegments(self.allocator, &segments);

        self.skipWhitespaceLine();
        if (self.eof() or self.peek() != ']') return error.ExpectedDoubleCloseBracket;
        self.advance();
        if (self.eof() or self.peek() != ']') return error.ExpectedDoubleCloseBracket;
        self.advance();

        try self.expectLineEnd();

        const parent = try self.walkPathThroughImplicitHeaders(segments.items[0 .. segments.items.len - 1]);
        const leaf = segments.items[segments.items.len - 1];

        if (parent.entries.getEntry(leaf)) |entry| {
            const val = entry.value_ptr;
            switch (val.*) {
                .array => |*arr| {
                    if (!arr.is_aot) return error.CannotExtendStaticArray;
                    // Append a new aot_element.
                    const new_table = try self.allocator.create(Table);
                    errdefer self.allocator.destroy(new_table);
                    new_table.* = Table.init(self.allocator);
                    new_table.kind = .aot_element;
                    errdefer new_table.deinit(self.allocator);

                    try arr.items.append(self.allocator, .{ .table = new_table });
                    self.current_table = new_table;
                },
                .table => return error.DuplicateTable,
                else => return error.DuplicateKey,
            }
        } else {
            // Create new array with one aot_element.
            const new_table = try self.allocator.create(Table);
            errdefer self.allocator.destroy(new_table);
            new_table.* = Table.init(self.allocator);
            new_table.kind = .aot_element;
            errdefer new_table.deinit(self.allocator);

            var items: std.ArrayListUnmanaged(Value) = .empty;
            errdefer items.deinit(self.allocator);
            try items.append(self.allocator, .{ .table = new_table });

            const key_dup = try self.allocator.dupe(u8, leaf);
            errdefer self.allocator.free(key_dup);

            try parent.entries.put(key_dup, .{ .array = .{ .items = items, .is_aot = true } });
            self.current_table = new_table;
        }
    }

    /// Walk the dotted path through tables, creating `implicit_header`
    /// intermediates for missing segments. For `[[a.b]]`-style traversal
    /// passing through an existing array-of-tables, descend into its LAST
    /// element. Used by both `[a.b.c]` and `[[a.b.c]]` headers.
    fn walkPathThroughImplicitHeaders(self: *Parser, segments: [][]const u8) ParseError!*Table {
        var current = self.root_table;
        for (segments) |segment| {
            if (current.kind == .inline_frozen) return error.CannotExtendInlineTable;

            if (current.entries.getEntry(segment)) |entry| {
                switch (entry.value_ptr.*) {
                    .table => |t| {
                        switch (t.kind) {
                            .inline_frozen => return error.CannotExtendInlineTable,
                            .implicit_dotted => return error.DuplicateTable,
                            else => current = t,
                        }
                    },
                    .array => |*arr| {
                        if (!arr.is_aot or arr.items.items.len == 0) return error.DuplicateKey;
                        const last = &arr.items.items[arr.items.items.len - 1];
                        switch (last.*) {
                            .table => |t| current = t,
                            else => return error.DuplicateKey,
                        }
                    },
                    else => return error.DuplicateKey,
                }
            } else {
                // Create implicit_header intermediate.
                const new_table = try self.allocator.create(Table);
                errdefer self.allocator.destroy(new_table);
                new_table.* = Table.init(self.allocator);
                new_table.kind = .implicit_header;
                errdefer new_table.deinit(self.allocator);

                const key_dup = try self.allocator.dupe(u8, segment);
                errdefer self.allocator.free(key_dup);

                try current.entries.put(key_dup, .{ .table = new_table });
                current = new_table;
            }
        }
        return current;
    }

    // ----------------------------------------------------------------------
    // Key / value parsing
    // ----------------------------------------------------------------------

    /// Where a `key = value` line is being parsed from.
    /// `top_level` lines have stricter formatting than `inline_table`
    /// entries (newline required vs comma/brace).
    const LineContext = enum { top_level, inline_table };

    fn parseKeyValueLine(self: *Parser, table: *Table, ctx: LineContext) ParseError!void {
        var segments = try self.parseDottedKey();
        defer freeSegments(self.allocator, &segments);

        self.skipWhitespaceLine();
        if (self.eof() or self.peek() != '=') return error.ExpectedEquals;
        self.advance(); // '='
        self.skipWhitespaceLine();

        // Walk through dotted-key implicits (NOT implicit_header — these are
        // implicit_dotted), placing the value at the leaf segment.
        const parent = try self.walkPathThroughImplicitDotted(table, segments.items[0 .. segments.items.len - 1]);
        const leaf = segments.items[segments.items.len - 1];

        if (parent.kind == .inline_frozen) return error.CannotExtendInlineTable;

        // Parse the value before doing the duplicate check, so the position
        // is past the value if the value itself fails — but ALSO so that we
        // never end up with a stale half-walked path. The duplicate check
        // is against the leaf parent, which is set up by the walk above.
        if (parent.entries.contains(leaf)) {
            return switch (ctx) {
                .top_level => error.DuplicateKey,
                .inline_table => error.DuplicateInlineKey,
            };
        }

        var value = try self.parseValue();
        // From here, any error must `deinit` the parsed value.
        errdefer value.deinit(self.allocator);

        // After a top-level value, the line must end with whitespace + (EOF,
        // newline, or comment). Inline-table values get their delimiter check
        // handled by the caller.
        if (ctx == .top_level) {
            try self.expectLineEnd();
        }

        const key_dup = try self.allocator.dupe(u8, leaf);
        errdefer self.allocator.free(key_dup);

        try parent.entries.put(key_dup, value);
    }

    /// For dotted-key assignment, walk through intermediate segments,
    /// creating `implicit_dotted` tables as needed. These tables CANNOT be
    /// later promoted to `explicit_header` (per the TOML 1.0 rule "using
    /// dotted keys to redefine tables already defined in [table] form is
    /// not allowed" — and its inverse).
    fn walkPathThroughImplicitDotted(self: *Parser, root: *Table, segments: [][]const u8) ParseError!*Table {
        var current = root;
        for (segments) |segment| {
            if (current.kind == .inline_frozen) return error.CannotExtendInlineTable;

            if (current.entries.getEntry(segment)) |entry| {
                switch (entry.value_ptr.*) {
                    .table => |t| {
                        switch (t.kind) {
                            .inline_frozen => return error.CannotExtendInlineTable,
                            .explicit_header => return error.DuplicateTable,
                            .aot_element => return error.DuplicateTable,
                            // implicit_header or implicit_dotted: descend.
                            else => current = t,
                        }
                    },
                    else => return error.DuplicateKey,
                }
            } else {
                const new_table = try self.allocator.create(Table);
                errdefer self.allocator.destroy(new_table);
                new_table.* = Table.init(self.allocator);
                new_table.kind = .implicit_dotted;
                errdefer new_table.deinit(self.allocator);

                const key_dup = try self.allocator.dupe(u8, segment);
                errdefer self.allocator.free(key_dup);

                try current.entries.put(key_dup, .{ .table = new_table });
                current = new_table;
            }
        }
        return current;
    }

    /// Parse a dotted key like `a.b."quoted with spaces".d` into a list of
    /// segments. Caller frees each segment + the list.
    fn parseDottedKey(self: *Parser) ParseError!std.ArrayListUnmanaged([]const u8) {
        var segments: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer freeSegments(self.allocator, &segments);

        while (true) {
            self.skipWhitespaceLine();
            const segment = try self.parseKeySegment();
            try segments.append(self.allocator, segment);
            self.skipWhitespaceLine();

            if (self.eof()) break;
            if (self.peek() != '.') break;
            self.advance();
        }

        if (segments.items.len == 0) return error.InvalidKey;
        return segments;
    }

    fn parseKeySegment(self: *Parser) ParseError![]const u8 {
        if (self.eof()) return error.UnexpectedEnd;
        const ch = self.peek();
        if (ch == '"') return self.parseBasicStringRaw();
        if (ch == '\'') return self.parseLiteralStringRaw();
        if (isBareKeyChar(ch)) {
            const start = self.pos;
            while (!self.eof() and isBareKeyChar(self.peek())) self.advance();
            return try self.allocator.dupe(u8, self.input[start..self.pos]);
        }
        return error.InvalidKey;
    }

    // ----------------------------------------------------------------------
    // Value parsing
    // ----------------------------------------------------------------------

    fn parseValue(self: *Parser) ParseError!Value {
        if (self.eof()) return error.UnexpectedEnd;
        const ch = self.peek();

        // Strings
        if (ch == '"') {
            if (self.startsWith("\"\"\"")) return self.parseMultilineBasicString();
            const s = try self.parseBasicStringRaw();
            return Value{ .string = s };
        }
        if (ch == '\'') {
            if (self.startsWith("'''")) return self.parseMultilineLiteralString();
            const s = try self.parseLiteralStringRaw();
            return Value{ .string = s };
        }

        // Arrays / inline tables (depth-tracked)
        if (ch == '[') return self.parseArray();
        if (ch == '{') return self.parseInlineTable();

        // Booleans
        if (ch == 't' or ch == 'f') return self.parseBoolean();

        // inf/nan (positive form; signed forms handled in parseNumber)
        if (ch == 'i' or ch == 'n') return self.parseInfOrNan(false);

        // Numbers and datetimes
        if (ch == '+' or ch == '-' or (ch >= '0' and ch <= '9')) {
            // Datetime detection: 4 digits + '-' or 2 digits + ':'
            if (self.looksLikeDateTime()) return self.parseDateTime();
            return self.parseNumber();
        }

        return error.InvalidValue;
    }

    // ----------------------------------------------------------------------
    // Strings
    // ----------------------------------------------------------------------

    /// Parse a basic string `"..."` and return the unescaped contents as an
    /// owned slice.
    fn parseBasicStringRaw(self: *Parser) ParseError![]u8 {
        self.advance(); // opening "
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            if (self.eof()) return error.UnterminatedString;
            const c = self.peek();
            if (c == '"') {
                self.advance();
                return out.toOwnedSlice(self.allocator);
            }
            if (c == '\n' or c == '\r') return error.UnterminatedString;
            if (c == '\\') {
                self.advance();
                try self.consumeEscape(&out, false);
            } else {
                try out.append(self.allocator, c);
                self.advance();
            }
        }
    }

    fn parseLiteralStringRaw(self: *Parser) ParseError![]u8 {
        self.advance(); // opening '
        const start = self.pos;
        while (true) {
            if (self.eof()) return error.UnterminatedString;
            const c = self.peek();
            if (c == '\'') {
                const out = try self.allocator.dupe(u8, self.input[start..self.pos]);
                self.advance();
                return out;
            }
            if (c == '\n' or c == '\r') return error.UnterminatedString;
            self.advance();
        }
    }

    fn parseMultilineBasicString(self: *Parser) ParseError!Value {
        self.advance();
        self.advance();
        self.advance(); // skip """

        // Per spec, a newline immediately after opening """ is trimmed.
        if (!self.eof() and self.peek() == '\r') self.advance();
        if (!self.eof() and self.peek() == '\n') self.advance();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            if (self.eof()) return error.UnterminatedString;

            // Closing delimiter — but allow 1 or 2 quotes before it as
            // content. (Per spec, """X"""" is X + ".)
            if (self.startsWith("\"\"\"")) {
                // Consume any additional quotes (up to 2) as content.
                self.advance();
                self.advance();
                self.advance();
                if (!self.eof() and self.peek() == '"') {
                    try out.append(self.allocator, '"');
                    self.advance();
                    if (!self.eof() and self.peek() == '"') {
                        try out.append(self.allocator, '"');
                        self.advance();
                    }
                }
                return Value{ .string = try out.toOwnedSlice(self.allocator) };
            }

            const c = self.peek();
            if (c == '\\') {
                // Either an escape or a line-ending backslash (trim
                // whitespace through the next newline).
                if (self.isLineEndingBackslash()) {
                    self.advance(); // '\'
                    while (!self.eof()) {
                        const w = self.peek();
                        if (w == ' ' or w == '\t' or w == '\n' or w == '\r') {
                            self.advance();
                        } else break;
                    }
                    continue;
                }
                self.advance(); // '\'
                try self.consumeEscape(&out, false);
            } else {
                try out.append(self.allocator, c);
                self.advance();
            }
        }
    }

    fn parseMultilineLiteralString(self: *Parser) ParseError!Value {
        self.advance();
        self.advance();
        self.advance(); // skip '''

        // Trim a single leading newline per spec.
        if (!self.eof() and self.peek() == '\r') self.advance();
        if (!self.eof() and self.peek() == '\n') self.advance();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            if (self.eof()) return error.UnterminatedString;
            if (self.startsWith("'''")) {
                self.advance();
                self.advance();
                self.advance();
                if (!self.eof() and self.peek() == '\'') {
                    try out.append(self.allocator, '\'');
                    self.advance();
                    if (!self.eof() and self.peek() == '\'') {
                        try out.append(self.allocator, '\'');
                        self.advance();
                    }
                }
                return Value{ .string = try out.toOwnedSlice(self.allocator) };
            }
            try out.append(self.allocator, self.peek());
            self.advance();
        }
    }

    /// Detect `\` + (optional whitespace) + newline in a multiline basic
    /// string. The library consumes the backslash + all subsequent
    /// whitespace (including the newline) and emits no output, per the spec.
    fn isLineEndingBackslash(self: *Parser) bool {
        // self.peek() == '\\' is assumed by caller.
        var i = self.pos + 1;
        while (i < self.input.len) : (i += 1) {
            const c = self.input[i];
            if (c == ' ' or c == '\t') continue;
            if (c == '\n') return true;
            if (c == '\r') {
                if (i + 1 < self.input.len and self.input[i + 1] == '\n') return true;
                return false;
            }
            return false;
        }
        return false;
    }

    /// Consume a TOML escape sequence into `out`, starting after the
    /// backslash. `multiline` selects whether ASCII-newline escapes are
    /// also permitted (they aren't in basic strings).
    fn consumeEscape(self: *Parser, out: *std.ArrayListUnmanaged(u8), multiline: bool) ParseError!void {
        _ = multiline;
        if (self.eof()) return error.InvalidEscape;
        const c = self.peek();
        switch (c) {
            'b' => {
                try out.append(self.allocator, 0x08);
                self.advance();
            },
            't' => {
                try out.append(self.allocator, '\t');
                self.advance();
            },
            'n' => {
                try out.append(self.allocator, '\n');
                self.advance();
            },
            'f' => {
                try out.append(self.allocator, 0x0c);
                self.advance();
            },
            'r' => {
                try out.append(self.allocator, '\r');
                self.advance();
            },
            '"' => {
                try out.append(self.allocator, '"');
                self.advance();
            },
            '\\' => {
                try out.append(self.allocator, '\\');
                self.advance();
            },
            'u' => {
                self.advance();
                try self.appendUnicodeEscape(out, 4);
            },
            'U' => {
                self.advance();
                try self.appendUnicodeEscape(out, 8);
            },
            // TOML 1.0 §5.4 — any other escape sequence is invalid.
            else => return error.InvalidEscape,
        }
    }

    fn appendUnicodeEscape(self: *Parser, out: *std.ArrayListUnmanaged(u8), digits: u8) ParseError!void {
        if (self.pos + digits > self.input.len) return error.InvalidUnicodeEscape;
        const hex = self.input[self.pos .. self.pos + digits];
        for (hex) |h| {
            if (!isHexDigit(h)) return error.InvalidUnicodeEscape;
        }
        const codepoint_u32 = std.fmt.parseInt(u32, hex, 16) catch return error.InvalidUnicodeEscape;
        if (codepoint_u32 > 0x10FFFF) return error.CodepointTooLarge;
        if (codepoint_u32 >= 0xD800 and codepoint_u32 <= 0xDFFF) return error.Utf8CannotEncodeSurrogateHalf;

        const codepoint: u21 = @intCast(codepoint_u32);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try out.appendSlice(self.allocator, buf[0..len]);
        // advance over the consumed hex digits
        var i: usize = 0;
        while (i < digits) : (i += 1) self.advance();
    }

    // ----------------------------------------------------------------------
    // Numbers / inf / nan / datetimes
    // ----------------------------------------------------------------------

    /// Disambiguate "datetime starts here" from "number starts here".
    /// Datetime markers per RFC 3339: 4 digits + `-`, or 2 digits + `:`.
    fn looksLikeDateTime(self: *Parser) bool {
        // 4-digit year: positions p, p+1, p+2, p+3 are digits, p+4 is '-'
        if (self.pos + 4 < self.input.len) {
            if (isDigit(self.input[self.pos]) and
                isDigit(self.input[self.pos + 1]) and
                isDigit(self.input[self.pos + 2]) and
                isDigit(self.input[self.pos + 3]) and
                self.input[self.pos + 4] == '-')
                return true;
        }
        // 2-digit hour: p, p+1 are digits, p+2 is ':'
        if (self.pos + 2 < self.input.len) {
            if (isDigit(self.input[self.pos]) and
                isDigit(self.input[self.pos + 1]) and
                self.input[self.pos + 2] == ':')
                return true;
        }
        return false;
    }

    fn parseDateTime(self: *Parser) ParseError!Value {
        const start = self.pos;
        // We don't fully tokenize; just walk while the chars look RFC-3339-ish:
        // digits, '-', ':', 'T', 't', ' ' (between date and time), '.', '+', 'Z', 'z'.
        while (!self.eof()) {
            const c = self.peek();
            if (isDigit(c) or c == '-' or c == ':' or c == '.' or c == 'T' or c == 't' or c == 'Z' or c == 'z' or c == '+') {
                self.advance();
                continue;
            }
            // A space between date and time is allowed once. Only consume it
            // if a digit follows (otherwise it's regular trailing whitespace).
            if (c == ' ' and self.pos + 1 < self.input.len and isDigit(self.input[self.pos + 1])) {
                self.advance();
                continue;
            }
            break;
        }
        if (self.pos == start) return error.InvalidDateTime;
        const slice = self.input[start..self.pos];
        // Minimal validation: a datetime needs at least YYYY-MM-DD or HH:MM:SS
        // shape — i.e. >= 8 chars.
        if (slice.len < 8) return error.InvalidDateTime;
        const owned = try self.allocator.dupe(u8, slice);
        return Value{ .datetime = owned };
    }

    fn parseInfOrNan(self: *Parser, negative: bool) ParseError!Value {
        if (self.startsWith("inf")) {
            self.pos += 3;
            self.col += 3;
            return Value{ .float = if (negative) -std.math.inf(f64) else std.math.inf(f64) };
        }
        if (self.startsWith("nan")) {
            self.pos += 3;
            self.col += 3;
            // Sign on NaN is preserved per IEEE-754 but TOML doesn't make a
            // semantic distinction; we emit canonical nan().
            return Value{ .float = std.math.nan(f64) };
        }
        return error.InvalidNumber;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        var negative = false;

        if (self.peek() == '+' or self.peek() == '-') {
            negative = self.peek() == '-';
            self.advance();
            if (self.eof()) return error.InvalidNumber;
            // +inf / -inf / +nan / -nan
            if (self.peek() == 'i' or self.peek() == 'n') return self.parseInfOrNan(negative);
        }

        // Detect base prefix: 0x, 0o, 0b. TOML 1.0 disallows signs on
        // based integers (`+0xff` and `-0xff` are both invalid), so we
        // dispatch only if no sign char was consumed (i.e. `start == self.pos`).
        if (start == self.pos and self.pos + 1 < self.input.len and self.peek() == '0') {
            const prefix = self.input[self.pos + 1];
            if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
                return self.parseBasedInteger();
            }
        }

        // Decimal integer or float.
        // Reject leading zero for multi-digit integers: 042 is invalid.
        if (self.peek() == '0' and self.pos + 1 < self.input.len) {
            const next = self.input[self.pos + 1];
            if (isDigit(next)) return error.InvalidNumber;
        }

        // Consume digit run with `_` separators between digits.
        try self.consumeDigitsWithUnderscores(10);

        var is_float = false;

        if (!self.eof() and self.peek() == '.') {
            is_float = true;
            self.advance();
            if (self.eof() or !isDigit(self.peek())) return error.InvalidFloat;
            try self.consumeDigitsWithUnderscores(10);
        }

        if (!self.eof() and (self.peek() == 'e' or self.peek() == 'E')) {
            is_float = true;
            self.advance();
            if (!self.eof() and (self.peek() == '+' or self.peek() == '-')) self.advance();
            if (self.eof() or !isDigit(self.peek())) return error.InvalidFloat;
            try self.consumeDigitsWithUnderscores(10);
        }

        const raw = self.input[start..self.pos];
        // Strip `_` for the actual parse (TOML allows underscores between digits).
        const cleaned = try stripUnderscores(self.allocator, raw);
        defer self.allocator.free(cleaned);

        if (is_float) {
            const f = std.fmt.parseFloat(f64, cleaned) catch return error.InvalidFloat;
            return Value{ .float = f };
        } else {
            const i = std.fmt.parseInt(i64, cleaned, 10) catch |e| switch (e) {
                error.Overflow => return error.Overflow,
                else => return error.InvalidNumber,
            };
            return Value{ .integer = i };
        }
    }

    fn parseBasedInteger(self: *Parser) ParseError!Value {
        // Caller has positioned self.pos at '0' and verified next char is one
        // of x/o/b. Consume both.
        self.advance(); // '0'
        const base_char = self.peek();
        self.advance(); // base prefix letter
        const base: u8 = switch (base_char) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => return error.InvalidNumber,
        };

        const start = self.pos;
        try self.consumeDigitsWithUnderscores(base);
        const raw = self.input[start..self.pos];
        if (raw.len == 0) return error.InvalidNumber;
        const cleaned = try stripUnderscores(self.allocator, raw);
        defer self.allocator.free(cleaned);

        const parsed = std.fmt.parseInt(i64, cleaned, base) catch |e| switch (e) {
            error.Overflow => return error.Overflow,
            else => return error.InvalidNumber,
        };
        return Value{ .integer = parsed };
    }

    fn consumeDigitsWithUnderscores(self: *Parser, base: u8) ParseError!void {
        var last_was_digit = false;
        while (!self.eof()) {
            const c = self.peek();
            if (isDigitForBase(c, base)) {
                last_was_digit = true;
                self.advance();
                continue;
            }
            if (c == '_') {
                if (!last_was_digit) return error.InvalidNumber;
                // The char AFTER `_` must also be a digit.
                if (self.pos + 1 >= self.input.len or !isDigitForBase(self.input[self.pos + 1], base))
                    return error.InvalidNumber;
                last_was_digit = false;
                self.advance();
                continue;
            }
            break;
        }
    }

    fn parseBoolean(self: *Parser) ParseError!Value {
        if (self.startsWith("true")) {
            self.pos += 4;
            self.col += 4;
            return Value{ .boolean = true };
        }
        if (self.startsWith("false")) {
            self.pos += 5;
            self.col += 5;
            return Value{ .boolean = false };
        }
        return error.InvalidBoolean;
    }

    // ----------------------------------------------------------------------
    // Arrays and inline tables — depth-tracked
    // ----------------------------------------------------------------------

    fn parseArray(self: *Parser) ParseError!Value {
        if (self.depth >= self.max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        self.advance(); // '['

        var items: std.ArrayListUnmanaged(Value) = .empty;
        errdefer {
            for (items.items) |*v| v.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        // Whitespace, newlines, and comments all allowed inside arrays.
        self.skipWhitespaceAndNewlinesAndComments();

        while (!self.eof() and self.peek() != ']') {
            var value = try self.parseValue();
            // From here, on error we must deinit `value`.
            errdefer value.deinit(self.allocator);

            try items.append(self.allocator, value);

            self.skipWhitespaceAndNewlinesAndComments();
            if (self.eof()) return error.ExpectedCommaOrBracket;
            if (self.peek() == ',') {
                self.advance();
                self.skipWhitespaceAndNewlinesAndComments();
            } else if (self.peek() != ']') {
                return error.ExpectedCommaOrBracket;
            }
        }

        if (self.eof() or self.peek() != ']') return error.ExpectedCloseBracket;
        self.advance();

        return Value{ .array = .{ .items = items, .is_aot = false } };
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        if (self.depth >= self.max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        self.advance(); // '{'

        const table = try self.allocator.create(Table);
        errdefer self.allocator.destroy(table);
        table.* = Table.init(self.allocator);
        // NOTE: kind stays at the default (.root) during construction so the
        // inline_frozen check in parseKeyValueLine doesn't reject our own
        // initial population. The freeze is applied below, right before we
        // return — at that point further extension via `[a.b]` headers or
        // dotted keys IS forbidden by the spec.
        errdefer table.deinit(self.allocator);

        self.skipWhitespaceLine();

        // Empty inline table: {}
        if (!self.eof() and self.peek() == '}') {
            self.advance();
            table.kind = .inline_frozen;
            return Value{ .table = table };
        }

        while (true) {
            self.skipWhitespaceLine();
            if (self.eof()) return error.UnexpectedEnd;
            if (self.peek() == '\n' or self.peek() == '\r') {
                // Per TOML 1.0 §Inline-Tables: no newlines inside { }.
                return error.UnexpectedCharacter;
            }

            try self.parseKeyValueLine(table, .inline_table);

            self.skipWhitespaceLine();
            if (self.eof()) return error.ExpectedCommaOrBrace;
            if (self.peek() == ',') {
                self.advance();
                continue;
            }
            if (self.peek() == '}') {
                self.advance();
                table.kind = .inline_frozen;
                return Value{ .table = table };
            }
            return error.ExpectedCommaOrBrace;
        }
    }

    // ----------------------------------------------------------------------
    // Whitespace / lookahead helpers
    // ----------------------------------------------------------------------

    fn eof(self: *const Parser) bool {
        return self.pos >= self.input.len;
    }

    fn peek(self: *const Parser) u8 {
        if (self.eof()) return 0;
        return self.input[self.pos];
    }

    fn peekAt(self: *const Parser, offset: usize) u8 {
        if (self.pos + offset >= self.input.len) return 0;
        return self.input[self.pos + offset];
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos .. self.pos + prefix.len], prefix);
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    /// Skip spaces and tabs only (not newlines).
    fn skipWhitespaceLine(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t') self.advance() else break;
        }
    }

    /// Skip spaces, tabs, AND newlines.
    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.advance() else break;
        }
    }

    /// Skip whitespace, newlines, and `# ...\n` comments (used inside
    /// arrays).
    fn skipWhitespaceAndNewlinesAndComments(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '#') {
                self.skipComment();
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Parser) void {
        while (!self.eof() and self.peek() != '\n') self.advance();
        if (!self.eof()) self.advance(); // consume newline
    }

    /// Require: trailing whitespace, then EOF / newline / comment.
    fn expectLineEnd(self: *Parser) ParseError!void {
        self.skipWhitespaceLine();
        if (self.eof()) return;
        const c = self.peek();
        if (c == '\n' or c == '\r') {
            self.advance();
            return;
        }
        if (c == '#') {
            self.skipComment();
            return;
        }
        return error.UnexpectedCharacter;
    }
};

// ============================================================================
// Free helpers
// ============================================================================

fn freeSegments(allocator: Allocator, segments: *std.ArrayListUnmanaged([]const u8)) void {
    for (segments.items) |s| allocator.free(s);
    segments.deinit(allocator);
}

fn isBareKeyChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isHexDigit(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn isDigitForBase(ch: u8, base: u8) bool {
    return switch (base) {
        2 => ch == '0' or ch == '1',
        8 => ch >= '0' and ch <= '7',
        10 => isDigit(ch),
        16 => isHexDigit(ch),
        else => false,
    };
}

fn stripUnderscores(allocator: Allocator, s: []const u8) ParseError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c != '_') try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Tier 2 + Tier 3 tests
//
// Tier 1 (externally-anchored toml-test corpus vectors) lives in
// `tier1_anchors.zig`. The tests here cover:
//   * Tier 2 — failure modes the audit identified (duplicate key, deep
//     nesting, unterminated multiline, reserved escape, leading zero, etc.)
//   * Tier 3 — happy-path roundtrips for each value type.
// ============================================================================

const testing = std.testing;

fn parseAndFree(input: []const u8) !void {
    var t = try parseToml(testing.allocator, input);
    defer t.deinit(testing.allocator);
}

// ----- Tier 2: failure modes -----

test "tier2: duplicate top-level key is rejected" {
    try testing.expectError(error.DuplicateKey, parseAndFree("name = \"A\"\nname = \"B\"\n"));
}

test "tier2: duplicate table header is rejected" {
    try testing.expectError(error.DuplicateTable, parseAndFree("[a]\nb = 1\n[a]\nc = 2\n"));
}

test "tier2: duplicate inline-table key is rejected" {
    try testing.expectError(error.DuplicateInlineKey, parseAndFree("p = { x = 1, x = 2 }\n"));
}

test "tier2: redefining [a] as [[a]] is rejected" {
    try testing.expectError(error.DuplicateTable, parseAndFree("[a]\nb = 1\n[[a]]\nc = 2\n"));
}

test "tier2: redefining [[a]] as [a] is rejected" {
    try testing.expectError(error.DuplicateTable, parseAndFree("[[a]]\nb = 1\n[a]\nc = 2\n"));
}

test "tier2: extending an inline table is rejected" {
    try testing.expectError(error.CannotExtendInlineTable, parseAndFree("a = { b = 1 }\n[a.c]\nd = 2\n"));
}

test "tier2: deeply-nested inline arrays trigger MaxDepthExceeded" {
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "x = ");
    var i: usize = 0;
    while (i < 5_000) : (i += 1) try input.append(testing.allocator, '[');
    while (i > 0) : (i -= 1) try input.append(testing.allocator, ']');
    try testing.expectError(error.MaxDepthExceeded, parseAndFree(input.items));
}

test "tier2: unterminated multiline string returns UnterminatedString" {
    try testing.expectError(error.UnterminatedString, parseAndFree("a = \"\"\"oh no"));
}

test "tier2: reserved escape \\x is rejected" {
    try testing.expectError(error.InvalidEscape, parseAndFree("a = \"\\x42\"\n"));
}

test "tier2: leading-zero integer is rejected" {
    try testing.expectError(error.InvalidNumber, parseAndFree("a = 042\n"));
}

test "tier2: \\u with bad hex digit is rejected" {
    try testing.expectError(error.InvalidUnicodeEscape, parseAndFree("a = \"\\u00GG\"\n"));
}

test "tier2: \\u with insufficient digits is rejected" {
    try testing.expectError(error.InvalidUnicodeEscape, parseAndFree("a = \"\\u00\"\n"));
}

test "tier2: surrogate halves are rejected" {
    try testing.expectError(error.Utf8CannotEncodeSurrogateHalf, parseAndFree("a = \"\\uD800\"\n"));
}

test "tier2: newline inside inline table is rejected" {
    try testing.expectError(error.UnexpectedCharacter, parseAndFree("p = { x = 1,\n  y = 2 }\n"));
}

// ----- Tier 3: happy-path roundtrips -----

test "tier3: simple key/value" {
    var t = try parseToml(testing.allocator, "name = \"John\"\nage = 30\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "John", t.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), t.get("age").?.integer);
}

test "tier3: booleans" {
    var t = try parseToml(testing.allocator, "a = true\nb = false\n");
    defer t.deinit(testing.allocator);
    try testing.expect(t.get("a").?.boolean);
    try testing.expect(!t.get("b").?.boolean);
}

test "tier3: floats with sign and exponent" {
    var t = try parseToml(testing.allocator, "a = 3.14\nb = -0.5\nc = 1.5e10\n");
    defer t.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 3.14), t.get("a").?.float, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), t.get("b").?.float, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.5e10), t.get("c").?.float, 1.0);
}

test "tier3: hex/oct/bin integers" {
    var t = try parseToml(testing.allocator, "h = 0xff\no = 0o755\nb = 0b1010\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 255), t.get("h").?.integer);
    try testing.expectEqual(@as(i64, 493), t.get("o").?.integer);
    try testing.expectEqual(@as(i64, 10), t.get("b").?.integer);
}

test "tier3: underscore separators in numbers" {
    var t = try parseToml(testing.allocator, "a = 1_000_000\nb = 0xff_ff\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1_000_000), t.get("a").?.integer);
    try testing.expectEqual(@as(i64, 0xffff), t.get("b").?.integer);
}

test "tier3: inf and nan" {
    var t = try parseToml(testing.allocator, "p = inf\nm = -inf\nn = nan\n");
    defer t.deinit(testing.allocator);
    try testing.expect(std.math.isPositiveInf(t.get("p").?.float));
    try testing.expect(std.math.isNegativeInf(t.get("m").?.float));
    try testing.expect(std.math.isNan(t.get("n").?.float));
}

test "tier3: array of integers" {
    var t = try parseToml(testing.allocator, "xs = [1, 2, 3, 4, 5]\n");
    defer t.deinit(testing.allocator);
    const arr = t.get("xs").?.array;
    try testing.expectEqual(@as(usize, 5), arr.items.items.len);
    try testing.expectEqual(@as(i64, 3), arr.items.items[2].integer);
}

test "tier3: array with whitespace, newlines, comments" {
    const input =
        \\xs = [
        \\  1, # one
        \\  2,
        \\  3,
        \\]
        \\
    ;
    var t = try parseToml(testing.allocator, input);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), t.get("xs").?.array.items.items.len);
}

test "tier3: dotted key creates intermediate table" {
    var t = try parseToml(testing.allocator, "a.b.c = 42\n");
    defer t.deinit(testing.allocator);
    const a = t.get("a").?.table;
    const b = a.get("b").?.table;
    try testing.expectEqual(@as(i64, 42), b.get("c").?.integer);
}

test "tier3: explicit table header [a.b.c]" {
    var t = try parseToml(testing.allocator, "[a.b.c]\nx = 1\n");
    defer t.deinit(testing.allocator);
    const c = t.get("a").?.table.get("b").?.table.get("c").?.table;
    try testing.expectEqual(@as(i64, 1), c.get("x").?.integer);
}

test "tier3: array of tables [[products]]" {
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
        \\
    ;
    var t = try parseToml(testing.allocator, input);
    defer t.deinit(testing.allocator);
    const arr = t.get("products").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.items.len);
    try testing.expectEqualSlices(u8, "Hammer", arr.items.items[0].table.get("name").?.string);
    try testing.expectEqualSlices(u8, "Nail", arr.items.items[1].table.get("name").?.string);
}

test "tier3: inline table" {
    var t = try parseToml(testing.allocator, "point = { x = 1, y = 2 }\n");
    defer t.deinit(testing.allocator);
    const p = t.get("point").?.table;
    try testing.expectEqual(@as(i64, 1), p.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), p.get("y").?.integer);
}

test "tier3: multiline basic string with leading-newline trim" {
    var t = try parseToml(testing.allocator,
        \\msg = """
        \\Line 1
        \\Line 2"""
    );
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "Line 1\nLine 2", t.get("msg").?.string);
}

test "tier3: line-ending backslash collapses whitespace" {
    var t = try parseToml(testing.allocator,
        \\msg = """foo \
        \\        bar"""
    );
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "foo bar", t.get("msg").?.string);
}

test "tier3: \\u and \\U escapes both work" {
    var t = try parseToml(testing.allocator, "a = \"\\u0041\\U0001F600\"\n");
    defer t.deinit(testing.allocator);
    // 0x41 = "A"; U+1F600 = 😀 (4 UTF-8 bytes: F0 9F 98 80)
    try testing.expectEqualSlices(u8, "A\xF0\x9F\x98\x80", t.get("a").?.string);
}

test "tier3: datetime is captured as a raw string" {
    var t = try parseToml(testing.allocator, "dob = 1979-05-27T07:32:00-08:00\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "1979-05-27T07:32:00-08:00", t.get("dob").?.datetime);
}

test "tier3: quoted key with dot inside is one segment" {
    var t = try parseToml(testing.allocator, "\"a.b\" = 1\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1), t.get("a.b").?.integer);
}

test "tier3: comments are skipped" {
    var t = try parseToml(testing.allocator, "# top comment\nkey = 1 # inline\n# trailing\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1), t.get("key").?.integer);
}

test "tier3: empty input parses to empty table" {
    var t = try parseToml(testing.allocator, "");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), t.count());
}

test "tier3: [a] then [a.b] does NOT trip duplicate-detection" {
    // a is implicit_header after [a.b], but if [a] was already explicit it
    // stays explicit; if [a] came LATER and a was already implicit, it
    // upgrades to explicit. Both orders should be fine.
    var t = try parseToml(testing.allocator, "[a]\nx = 1\n[a.b]\ny = 2\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1), t.get("a").?.table.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), t.get("a").?.table.get("b").?.table.get("y").?.integer);
}

test "tier3: [a.b] then [a] upgrades a from implicit to explicit" {
    var t = try parseToml(testing.allocator, "[a.b]\ny = 2\n[a]\nx = 1\n");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1), t.get("a").?.table.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), t.get("a").?.table.get("b").?.table.get("y").?.integer);
}
