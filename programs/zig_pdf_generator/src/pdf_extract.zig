//! PDF → MDX extractor (the inverse of the generator in this package).
//!
//! Reads an arbitrary digital (text-layer) PDF and emits MDX — GitHub-flavoured
//! Markdown with a YAML frontmatter block — matching the output contract of the
//! sibling `zig_docx` tool. Pure Zig, no external dependencies, WASM-able.
//!
//! Pipeline: parse COS objects → resolve xref/ObjStm → decode content streams →
//! interpret text-showing operators into positioned glyph fragments → recover
//! reading order → infer block structure → emit MDX.
//!
//! Scope (P1): digital single-column PDFs. Classic + cross-reference-stream xref,
//! object streams, FlateDecode (+ PNG/TIFF predictors), simple fonts with
//! WinAnsi/Standard/MacRoman encodings and /ToUnicode CMaps. Multi-column,
//! tables, Type0/CID fonts, encryption and image extraction are later phases.
//!
//! Hard rule (see CLAUDE.md §7): NO PANICS. Every failure path returns an
//! `error.X`; there are no `unreachable`s on attacker-controlled input, no
//! unchecked slicing, and every sort comparator defines a total order. A
//! malformed PDF yields a clean error or an honest empty-but-not-garbage result,
//! never a crash.

const std = @import("std");

// =============================================================================
// Errors
// =============================================================================

pub const ExtractError = error{
    NotAPdf,
    BrokenXref,
    UnsupportedFilter,
    EncryptedUnsupported,
    MalformedObject,
    MissingCatalog,
    OutOfMemory,
};

// =============================================================================
// COS object model
// =============================================================================

pub const Ref = struct {
    num: u32,
    gen: u16,
};

pub const Entry = struct {
    key: []const u8, // decoded name, without the leading '/'
    val: Obj,
};

/// A PDF dictionary — a small set of name→object entries. PDFs keep these tiny,
/// so a linear scan is faster than a hash map and needs no allocation churn.
pub const Dict = struct {
    entries: []Entry = &.{},

    pub fn get(self: Dict, key: []const u8) ?Obj {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.val;
        }
        return null;
    }
};

pub const Stream = struct {
    dict: Dict,
    /// Raw (still-encoded) stream bytes, as they appear between `stream` and
    /// `endstream`. Filters are applied on demand by the document layer.
    raw: []const u8,
};

pub const Obj = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8, // decoded bytes (escapes/hex resolved)
    name: []const u8, // decoded, without leading '/'
    array: []Obj,
    dict: Dict,
    stream: *Stream, // boxed so Obj stays small
    ref: Ref,

    pub fn asInt(self: Obj) ?i64 {
        return switch (self) {
            .integer => |v| v,
            .real => |v| @intFromFloat(v),
            else => null,
        };
    }

    pub fn asNumber(self: Obj) ?f64 {
        return switch (self) {
            .integer => |v| @floatFromInt(v),
            .real => |v| v,
            else => null,
        };
    }

    pub fn asDict(self: Obj) ?Dict {
        return switch (self) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }
};

// =============================================================================
// Lexer — tokenizes COS syntax
// =============================================================================

fn isWhitespace(c: u8) bool {
    return switch (c) {
        0x00, 0x09, 0x0a, 0x0c, 0x0d, 0x20 => true,
        else => false,
    };
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

fn isRegular(c: u8) bool {
    return !isWhitespace(c) and !isDelimiter(c);
}

pub const TokenKind = enum {
    integer,
    real,
    string,
    name,
    keyword, // obj, endobj, stream, R, true, false, null, BT, Tj, ...
    array_open, // [
    array_close, // ]
    dict_open, // <<
    dict_close, // >>
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    /// For integer/real: the raw numeric text. For string/name: the *decoded*
    /// bytes (the lexer owns the decoded buffer in the arena). For keyword: the
    /// keyword text. Otherwise empty.
    text: []const u8 = &.{},
    int_val: i64 = 0,
    real_val: f64 = 0,

    /// Interpret an integer token as a non-negative byte offset.
    pub fn asOffset(self: Token) ?usize {
        if (self.kind != .integer) return null;
        if (self.int_val < 0) return null;
        return @intCast(self.int_val);
    }
};

/// Streaming lexer over a byte buffer. Decoded strings/names are allocated in
/// the supplied arena allocator; the lexer never frees (the arena owns it all).
pub const Lexer = struct {
    buf: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    pub fn init(buf: []const u8, pos: usize, arena: std.mem.Allocator) Lexer {
        return .{ .buf = buf, .pos = pos, .arena = arena };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.buf.len) return null;
        return self.buf[self.pos];
    }

    fn at(self: *Lexer, off: usize) ?u8 {
        const i = self.pos + off;
        if (i >= self.buf.len) return null;
        return self.buf[i];
    }

    /// Skip whitespace and `%` comments (to end of line).
    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '%') {
                // Comment to EOL.
                while (self.pos < self.buf.len and self.buf[self.pos] != '\n' and self.buf[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else break;
        }
    }

    pub fn next(self: *Lexer) ExtractError!Token {
        self.skipWhitespace();
        const c = self.peek() orelse return .{ .kind = .eof };

        switch (c) {
            '[' => {
                self.pos += 1;
                return .{ .kind = .array_open };
            },
            ']' => {
                self.pos += 1;
                return .{ .kind = .array_close };
            },
            '<' => {
                if (self.at(1) == @as(u8, '<')) {
                    self.pos += 2;
                    return .{ .kind = .dict_open };
                }
                return self.lexHexString();
            },
            '>' => {
                if (self.at(1) == @as(u8, '>')) {
                    self.pos += 2;
                    return .{ .kind = .dict_close };
                }
                // Stray '>' — treat as keyword to avoid a hard stop.
                self.pos += 1;
                return .{ .kind = .keyword, .text = ">" };
            },
            '(' => return self.lexLiteralString(),
            '/' => return self.lexName(),
            '{', '}' => {
                // PostScript function delimiters — surface as keywords; the
                // object parser ignores them outside content streams.
                self.pos += 1;
                return .{ .kind = .keyword, .text = self.buf[self.pos - 1 .. self.pos] };
            },
            '+', '-', '.', '0'...'9' => return self.lexNumber(),
            else => return self.lexKeyword(),
        }
    }

    fn lexNumber(self: *Lexer) ExtractError!Token {
        const start = self.pos;
        var is_real = false;
        if (self.peek() == @as(u8, '+') or self.peek() == @as(u8, '-')) self.pos += 1;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
            } else if (c == '.') {
                is_real = true;
                self.pos += 1;
            } else if (c == '-' or c == '+' or c == 'e' or c == 'E') {
                // Tolerate malformed exponents / embedded signs.
                is_real = true;
                self.pos += 1;
            } else break;
        }
        const text = self.buf[start..self.pos];
        if (is_real) {
            const v = std.fmt.parseFloat(f64, text) catch 0;
            return .{ .kind = .real, .text = text, .real_val = v };
        }
        const v = std.fmt.parseInt(i64, text, 10) catch {
            // Overlong/garbled integer → fall back to float parse, else 0.
            const f = std.fmt.parseFloat(f64, text) catch 0;
            return .{ .kind = .real, .text = text, .real_val = f };
        };
        return .{ .kind = .integer, .text = text, .int_val = v };
    }

    fn lexName(self: *Lexer) ExtractError!Token {
        self.pos += 1; // consume '/'
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (!isRegular(c)) break;
            if (c == '#' and self.pos + 2 < self.buf.len) {
                const hi = hexVal(self.buf[self.pos + 1]);
                const lo = hexVal(self.buf[self.pos + 2]);
                if (hi != null and lo != null) {
                    try out.append(self.arena, hi.? * 16 + lo.?);
                    self.pos += 3;
                    continue;
                }
            }
            try out.append(self.arena, c);
            self.pos += 1;
        }
        return .{ .kind = .name, .text = out.items };
    }

    fn lexLiteralString(self: *Lexer) ExtractError!Token {
        self.pos += 1; // consume '('
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var depth: usize = 1;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            self.pos += 1;
            switch (c) {
                '\\' => {
                    const e = self.peek() orelse break;
                    self.pos += 1;
                    switch (e) {
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        'b' => try out.append(self.arena, 0x08),
                        'f' => try out.append(self.arena, 0x0c),
                        '(' => try out.append(self.arena, '('),
                        ')' => try out.append(self.arena, ')'),
                        '\\' => try out.append(self.arena, '\\'),
                        '\r' => {
                            // line continuation: \<CR><LF>? → nothing
                            if (self.peek() == @as(u8, '\n')) self.pos += 1;
                        },
                        '\n' => {}, // line continuation
                        '0'...'7' => {
                            // up to 3 octal digits, first already in `e`
                            var val: u16 = e - '0';
                            var n: usize = 0;
                            while (n < 2) : (n += 1) {
                                const d = self.peek() orelse break;
                                if (d < '0' or d > '7') break;
                                val = val * 8 + (d - '0');
                                self.pos += 1;
                            }
                            try out.append(self.arena, @truncate(val));
                        },
                        else => try out.append(self.arena, e),
                    }
                },
                '(' => {
                    depth += 1;
                    try out.append(self.arena, c);
                },
                ')' => {
                    depth -= 1;
                    if (depth == 0) break;
                    try out.append(self.arena, c);
                },
                else => try out.append(self.arena, c),
            }
        }
        return .{ .kind = .string, .text = out.items };
    }

    fn lexHexString(self: *Lexer) ExtractError!Token {
        self.pos += 1; // consume '<'
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var hi: ?u8 = null;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            self.pos += 1;
            if (c == '>') break;
            const v = hexVal(c) orelse continue; // skip whitespace/garbage
            if (hi) |h| {
                try out.append(self.arena, h * 16 + v);
                hi = null;
            } else {
                hi = v;
            }
        }
        if (hi) |h| try out.append(self.arena, h * 16); // odd digit → low nibble 0
        return .{ .kind = .string, .text = out.items };
    }

    fn lexKeyword(self: *Lexer) ExtractError!Token {
        const start = self.pos;
        while (self.pos < self.buf.len and isRegular(self.buf[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) {
            // Non-regular, non-delimiter byte we didn't handle — consume one to
            // guarantee forward progress (no infinite loop on garbage).
            self.pos += 1;
            return .{ .kind = .keyword, .text = self.buf[start..self.pos] };
        }
        return .{ .kind = .keyword, .text = self.buf[start..self.pos] };
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// =============================================================================
// Object parser — builds Obj trees from tokens
// =============================================================================

/// Parses a single object starting at `lex`'s current position. Handles the
/// `N G R` indirect-reference and `N G obj … endobj` forms, dicts, arrays, and
/// streams. `whole_file` is the full PDF buffer, needed to slice raw stream
/// bytes (which are binary and not tokenizable).
pub const Parser = struct {
    lex: Lexer,
    whole_file: []const u8,
    arena: std.mem.Allocator,

    pub fn init(buf: []const u8, pos: usize, whole_file: []const u8, arena: std.mem.Allocator) Parser {
        return .{ .lex = Lexer.init(buf, pos, arena), .whole_file = whole_file, .arena = arena };
    }

    /// Parse one object value. Resolves the `int int R` reference and the
    /// `int int obj` indirect-object wrappers; numbers that aren't part of those
    /// patterns are returned as plain integers/reals.
    pub fn parseObject(self: *Parser) ExtractError!Obj {
        const tok = try self.lex.next();
        return self.parseFromToken(tok);
    }

    fn parseFromToken(self: *Parser, tok: Token) ExtractError!Obj {
        switch (tok.kind) {
            .eof => return Obj{ .null = {} },
            .integer => {
                // Could be: plain int, `N G R`, or `N G obj`. Look ahead.
                const save = self.lex.pos;
                const t2 = try self.lex.next();
                if (t2.kind == .integer) {
                    const save2 = self.lex.pos;
                    const t3 = try self.lex.next();
                    if (t3.kind == .keyword and std.mem.eql(u8, t3.text, "R")) {
                        return Obj{ .ref = .{
                            .num = std.math.cast(u32, tok.int_val) orelse 0,
                            .gen = std.math.cast(u16, t2.int_val) orelse 0,
                        } };
                    }
                    if (t3.kind == .keyword and std.mem.eql(u8, t3.text, "obj")) {
                        // Indirect object wrapper: parse the inner object.
                        return self.parseObject();
                    }
                    // Not a ref/obj — rewind to right after the first integer.
                    _ = save2;
                    self.lex.pos = save;
                    return Obj{ .integer = tok.int_val };
                }
                self.lex.pos = save;
                return Obj{ .integer = tok.int_val };
            },
            .real => return Obj{ .real = tok.real_val },
            .string => return Obj{ .string = tok.text },
            .name => return Obj{ .name = tok.text },
            .array_open => return self.parseArray(),
            .dict_open => return self.parseDictOrStream(),
            .keyword => {
                if (std.mem.eql(u8, tok.text, "true")) return Obj{ .boolean = true };
                if (std.mem.eql(u8, tok.text, "false")) return Obj{ .boolean = false };
                if (std.mem.eql(u8, tok.text, "null")) return Obj{ .null = {} };
                // Unknown keyword in object context — treat as null.
                return Obj{ .null = {} };
            },
            else => return Obj{ .null = {} },
        }
    }

    fn parseArray(self: *Parser) ExtractError!Obj {
        var items: std.ArrayListUnmanaged(Obj) = .empty;
        while (true) {
            const tok = try self.lex.next();
            if (tok.kind == .array_close or tok.kind == .eof) break;
            const obj = try self.parseFromToken(tok);
            try items.append(self.arena, obj);
            if (items.items.len > 200_000) break; // sanity cap
        }
        return Obj{ .array = items.items };
    }

    fn parseDictOrStream(self: *Parser) ExtractError!Obj {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        while (true) {
            const ktok = try self.lex.next();
            if (ktok.kind == .dict_close or ktok.kind == .eof) break;
            if (ktok.kind != .name) {
                // Malformed: value without a name key. Skip it and continue so
                // one bad entry doesn't abort the whole dict.
                continue;
            }
            const val = try self.parseObject();
            try entries.append(self.arena, .{ .key = ktok.text, .val = val });
            if (entries.items.len > 100_000) break;
        }
        const dict = Dict{ .entries = entries.items };

        // A dict may be followed by `stream` → it's a stream object.
        const save = self.lex.pos;
        const after = try self.lex.next();
        if (after.kind == .keyword and std.mem.eql(u8, after.text, "stream")) {
            return self.finishStream(dict);
        }
        self.lex.pos = save;
        return Obj{ .dict = dict };
    }

    /// After the `stream` keyword: data begins after the EOL marker (CRLF or LF;
    /// a bare CR is also tolerated). The length comes from /Length when it's a
    /// direct integer, otherwise we scan forward to `endstream`.
    fn finishStream(self: *Parser, dict: Dict) ExtractError!Obj {
        var p = self.lex.pos;
        // PDF spec: `stream` is followed by CRLF or LF.
        if (p < self.lex.buf.len and self.lex.buf[p] == '\r') p += 1;
        if (p < self.lex.buf.len and self.lex.buf[p] == '\n') p += 1;
        const data_start = p;

        var data_end: usize = self.lex.buf.len;
        if (dict.get("Length")) |len_obj| {
            if (len_obj.asInt()) |n| {
                if (n >= 0) {
                    const end = data_start + @as(usize, @intCast(n));
                    if (end <= self.lex.buf.len) {
                        // Verify `endstream` follows (within a small slack of
                        // whitespace); if not, the Length was wrong/indirect.
                        if (verifyEndstream(self.lex.buf, end)) {
                            data_end = end;
                        } else {
                            data_end = scanEndstream(self.lex.buf, data_start);
                        }
                    } else {
                        data_end = scanEndstream(self.lex.buf, data_start);
                    }
                } else {
                    data_end = scanEndstream(self.lex.buf, data_start);
                }
            } else {
                // Indirect /Length — scan.
                data_end = scanEndstream(self.lex.buf, data_start);
            }
        } else {
            data_end = scanEndstream(self.lex.buf, data_start);
        }

        const raw = self.lex.buf[data_start..data_end];
        // Advance lexer past `endstream` (and ideally `endobj`).
        self.lex.pos = data_end;
        // Skip the endstream keyword if present.
        var lx = self.lex;
        const t = lx.next() catch Token{ .kind = .eof };
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "endstream")) {
            self.lex.pos = lx.pos;
        }

        const box = try self.arena.create(Stream);
        box.* = .{ .dict = dict, .raw = raw };
        return Obj{ .stream = box };
    }
};

/// True if `endstream` appears at `pos` after at most a couple of EOL bytes.
fn verifyEndstream(buf: []const u8, pos: usize) bool {
    var p = pos;
    // Allow a trailing EOL between data and `endstream`.
    var slack: usize = 0;
    while (p < buf.len and slack < 2 and (buf[p] == '\r' or buf[p] == '\n')) : (slack += 1) p += 1;
    const kw = "endstream";
    if (p + kw.len > buf.len) return false;
    return std.mem.eql(u8, buf[p .. p + kw.len], kw);
}

/// Scan forward from `from` for the `endstream` keyword; return the index of the
/// EOL immediately preceding it (so the EOL is excluded from the data).
fn scanEndstream(buf: []const u8, from: usize) usize {
    const idx = std.mem.indexOfPos(u8, buf, from, "endstream") orelse return buf.len;
    var end = idx;
    // Trim one preceding EOL (CRLF / LF / CR).
    if (end > from and buf[end - 1] == '\n') end -= 1;
    if (end > from and buf[end - 1] == '\r') end -= 1;
    return end;
}

// =============================================================================
// Document — xref resolution, object cache, stream decoding
// =============================================================================

/// Where an indirect object lives.
const XrefLoc = union(enum) {
    /// Byte offset of `N G obj` in the file.
    offset: usize,
    /// Compressed inside an object stream: which ObjStm and the index within it.
    in_objstm: struct { stream_num: u32, index: u32 },
};

pub const Document = struct {
    file: []const u8,
    arena: std.mem.Allocator,
    xref: std.AutoHashMapUnmanaged(u32, XrefLoc) = .empty,
    cache: std.AutoHashMapUnmanaged(u32, Obj) = .empty,
    /// Decoded ObjStm payloads, keyed by stream object number (lazy, cached).
    objstm_cache: std.AutoHashMapUnmanaged(u32, ObjStm) = .empty,
    trailer: Dict = .{},
    encrypted: bool = false,

    const ObjStm = struct {
        /// (object number, byte offset within `data`) pairs.
        offsets: []OffEntry,
        data: []const u8,
        const OffEntry = struct { num: u32, off: usize };
    };

    pub fn parse(arena: std.mem.Allocator, file: []const u8) ExtractError!Document {
        if (std.mem.indexOf(u8, file[0..@min(file.len, 1024)], "%PDF-") == null) {
            // Not a PDF header in the first KB → reject.
            return ExtractError.NotAPdf;
        }
        var doc = Document{ .file = file, .arena = arena };
        doc.buildXref() catch {
            // Any xref failure → brute-scan rebuild.
            doc.xref.clearRetainingCapacity();
            try doc.rebuildXref();
        };
        if (doc.xref.count() == 0) try doc.rebuildXref();

        // Detect encryption (P1 doesn't decrypt — surface a clean signal).
        if (doc.trailer.get("Encrypt") != null) doc.encrypted = true;
        return doc;
    }

    // --- xref construction ----------------------------------------------------

    fn buildXref(self: *Document) ExtractError!void {
        const sx = std.mem.lastIndexOf(u8, self.file, "startxref") orelse return ExtractError.BrokenXref;
        var lex = Lexer.init(self.file, sx + "startxref".len, self.arena);
        const tok = try lex.next();
        const start = tok.asOffset() orelse return ExtractError.BrokenXref;

        var offset: ?usize = start;
        var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var guard: usize = 0;
        while (offset) |off| {
            if (off >= self.file.len) break;
            if (visited.contains(off)) break; // cycle guard
            try visited.put(self.arena, off, {});
            guard += 1;
            if (guard > 1024) break;

            const next_off = try self.parseXrefAt(off);
            offset = next_off;
        }
    }

    /// Parse the xref section at `off` (classic table or xref stream). Returns
    /// the /Prev offset to follow next, if any.
    fn parseXrefAt(self: *Document, off: usize) ExtractError!?usize {
        var lex = Lexer.init(self.file, off, self.arena);
        const save = lex.pos;
        const first = try lex.next();
        if (first.kind == .keyword and std.mem.eql(u8, first.text, "xref")) {
            return self.parseClassicXref(&lex);
        }
        // Otherwise it should be `N G obj << /Type /XRef … >> stream`.
        lex.pos = save;
        return self.parseXrefStream(off);
    }

    fn parseClassicXref(self: *Document, lex: *Lexer) ExtractError!?usize {
        while (true) {
            const save = lex.pos;
            const t = try lex.next();
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "trailer")) break;
            if (t.kind != .integer) {
                lex.pos = save;
                break;
            }
            const start_num: u32 = std.math.cast(u32, t.int_val) orelse return ExtractError.BrokenXref;
            const count_tok = try lex.next();
            const count: u32 = std.math.cast(u32, count_tok.int_val) orelse 0;

            var k: u32 = 0;
            while (k < count) : (k += 1) {
                const o = try lex.next();
                const g = try lex.next();
                const ty = try lex.next();
                _ = g;
                const obj_off = o.asOffset() orelse continue;
                if (ty.kind == .keyword and ty.text.len > 0 and ty.text[0] == 'n') {
                    const num = start_num + k;
                    if (!self.xref.contains(num)) {
                        try self.xref.put(self.arena, num, .{ .offset = obj_off });
                    }
                }
            }
        }
        // trailer dict
        var parser = Parser.init(self.file, lex.pos, self.file, self.arena);
        const tobj = try parser.parseObject();
        const tdict = tobj.asDict() orelse Dict{};
        if (self.trailer.entries.len == 0) self.trailer = tdict;

        // Hybrid-reference files: a classic trailer may point at a parallel
        // xref stream via /XRefStm — fold it in.
        if (tdict.get("XRefStm")) |xs| {
            if (xs.asInt()) |xo| {
                if (xo >= 0) _ = self.parseXrefStream(@intCast(xo)) catch null;
            }
        }
        if (tdict.get("Prev")) |prev| {
            if (prev.asInt()) |po| {
                if (po >= 0) return @intCast(po);
            }
        }
        return null;
    }

    fn parseXrefStream(self: *Document, off: usize) ExtractError!?usize {
        var parser = Parser.init(self.file, off, self.file, self.arena);
        const obj = try parser.parseObject();
        if (obj != .stream) return ExtractError.BrokenXref;
        const st = obj.stream;
        const dict = st.dict;

        const decoded = try self.decodeStreamRaw(st);

        const w_arr = (dict.get("W") orelse return ExtractError.BrokenXref).array;
        if (w_arr.len < 3) return ExtractError.BrokenXref;
        const w0: usize = @intCast(@max(0, w_arr[0].asInt() orelse 0));
        const w1: usize = @intCast(@max(0, w_arr[1].asInt() orelse 0));
        const w2: usize = @intCast(@max(0, w_arr[2].asInt() orelse 0));
        const rec_len = w0 + w1 + w2;
        if (rec_len == 0) return ExtractError.BrokenXref;

        const size: i64 = if (dict.get("Size")) |s| (s.asInt() orelse 0) else 0;

        // /Index defaults to [0 Size].
        var index_pairs: std.ArrayListUnmanaged([2]i64) = .empty;
        if (dict.get("Index")) |idx| {
            const ia = idx.array;
            var i: usize = 0;
            while (i + 1 < ia.len) : (i += 2) {
                try index_pairs.append(self.arena, .{ ia[i].asInt() orelse 0, ia[i + 1].asInt() orelse 0 });
            }
        } else {
            try index_pairs.append(self.arena, .{ 0, size });
        }

        var pos: usize = 0;
        for (index_pairs.items) |pair| {
            const start_num = pair[0];
            const cnt = pair[1];
            var k: i64 = 0;
            while (k < cnt) : (k += 1) {
                if (pos + rec_len > decoded.len) break;
                const f0 = readBE(decoded[pos .. pos + w0]);
                const f1 = readBE(decoded[pos + w0 .. pos + w0 + w1]);
                const f2 = readBE(decoded[pos + w0 + w1 .. pos + rec_len]);
                pos += rec_len;

                const ty: u64 = if (w0 == 0) 1 else f0; // default type 1
                const num: u32 = std.math.cast(u32, start_num + k) orelse continue;
                if (self.xref.contains(num)) continue;
                switch (ty) {
                    1 => try self.xref.put(self.arena, num, .{ .offset = @intCast(f1) }),
                    2 => try self.xref.put(self.arena, num, .{ .in_objstm = .{
                        .stream_num = std.math.cast(u32, f1) orelse continue,
                        .index = std.math.cast(u32, f2) orelse continue,
                    } }),
                    else => {}, // type 0 = free
                }
            }
        }

        if (self.trailer.entries.len == 0) self.trailer = dict;
        if (dict.get("Prev")) |prev| {
            if (prev.asInt()) |po| {
                if (po >= 0) return @intCast(po);
            }
        }
        return null;
    }

    /// Last-resort recovery: scan the whole file for `N G obj` markers and the
    /// trailer's /Root. Malformed xref is the #1 cause of competitor panics, so
    /// we never fully trust it — this always produces a usable object map.
    fn rebuildXref(self: *Document) ExtractError!void {
        var i: usize = 0;
        while (i < self.file.len) {
            const rel = std.mem.indexOfPos(u8, self.file, i, " obj") orelse break;
            // Walk back over "N G" before " obj".
            var j = rel;
            while (j > 0 and isWhitespace(self.file[j - 1])) j -= 1;
            const g_end = j;
            while (j > 0 and self.file[j - 1] >= '0' and self.file[j - 1] <= '9') j -= 1;
            const g_start = j;
            while (j > 0 and isWhitespace(self.file[j - 1])) j -= 1;
            const n_end = j;
            while (j > 0 and self.file[j - 1] >= '0' and self.file[j - 1] <= '9') j -= 1;
            const n_start = j;
            if (g_start < g_end and n_start < n_end) {
                const num = std.fmt.parseInt(u32, self.file[n_start..n_end], 10) catch {
                    i = rel + 4;
                    continue;
                };
                // Later definitions win (incremental updates) → overwrite.
                try self.xref.put(self.arena, num, .{ .offset = n_start });
            }
            i = rel + 4;
        }

        // Find a trailer with /Root by scanning backwards for "trailer".
        if (std.mem.lastIndexOf(u8, self.file, "trailer")) |toff| {
            var parser = Parser.init(self.file, toff + "trailer".len, self.file, self.arena);
            const tobj = parser.parseObject() catch Obj{ .null = {} };
            if (tobj.asDict()) |td| self.trailer = td;
        }
        // If still no /Root, hunt for any object whose dict has /Type /Catalog.
        if (self.trailer.get("Root") == null) {
            var it = self.xref.iterator();
            while (it.next()) |e| {
                const obj = self.resolveRef(e.key_ptr.*, 0) catch continue;
                if (obj.asDict()) |d| {
                    if (d.get("Type")) |t| {
                        if (t == .name and std.mem.eql(u8, t.name, "Catalog")) {
                            const ent = try self.arena.alloc(Entry, 1);
                            ent[0] = .{ .key = "Root", .val = .{ .ref = .{ .num = e.key_ptr.*, .gen = 0 } } };
                            self.trailer = .{ .entries = ent };
                            break;
                        }
                    }
                }
            }
        }
    }

    // --- object resolution ----------------------------------------------------

    /// Resolve an indirect reference to its object, caching the result. Returns
    /// null object on any failure (never panics).
    pub fn resolveRef(self: *Document, num: u32, gen: u16) ExtractError!Obj {
        _ = gen;
        if (self.cache.get(num)) |o| return o;
        const loc = self.xref.get(num) orelse return Obj{ .null = {} };
        // Pre-seed cache with null to break ref cycles.
        try self.cache.put(self.arena, num, .{ .null = {} });
        const obj = switch (loc) {
            .offset => |o| blk: {
                if (o >= self.file.len) break :blk Obj{ .null = {} };
                var parser = Parser.init(self.file, o, self.file, self.arena);
                break :blk parser.parseObject() catch Obj{ .null = {} };
            },
            .in_objstm => |c| try self.objectFromObjStm(c.stream_num, c.index, num),
        };
        try self.cache.put(self.arena, num, obj);
        return obj;
    }

    /// Resolve `obj` if it's a reference (one hop), else return it as-is.
    pub fn resolve(self: *Document, obj: Obj) ExtractError!Obj {
        var cur = obj;
        var hops: usize = 0;
        while (cur == .ref and hops < 32) : (hops += 1) {
            cur = try self.resolveRef(cur.ref.num, cur.ref.gen);
        }
        return cur;
    }

    /// Look up a dict key and resolve it through any indirect reference.
    pub fn dictGet(self: *Document, dict: Dict, key: []const u8) ExtractError!?Obj {
        const v = dict.get(key) orelse return null;
        return try self.resolve(v);
    }

    fn objectFromObjStm(self: *Document, stream_num: u32, index: u32, want_num: u32) ExtractError!Obj {
        const os = try self.loadObjStm(stream_num);
        if (index >= os.offsets.len) return Obj{ .null = {} };
        const entry = os.offsets[index];
        _ = want_num;
        if (entry.off > os.data.len) return Obj{ .null = {} };
        var parser = Parser.init(os.data, entry.off, os.data, self.arena);
        return parser.parseObject() catch Obj{ .null = {} };
    }

    fn loadObjStm(self: *Document, stream_num: u32) ExtractError!ObjStm {
        if (self.objstm_cache.get(stream_num)) |os| return os;

        const loc = self.xref.get(stream_num) orelse return ExtractError.BrokenXref;
        const off = switch (loc) {
            .offset => |o| o,
            .in_objstm => return ExtractError.BrokenXref, // ObjStm can't nest
        };
        var parser = Parser.init(self.file, off, self.file, self.arena);
        const obj = parser.parseObject() catch return ExtractError.BrokenXref;
        if (obj != .stream) return ExtractError.BrokenXref;
        const st = obj.stream;
        const n: usize = @intCast(@max(0, (st.dict.get("N") orelse Obj{ .integer = 0 }).asInt() orelse 0));
        const first: usize = @intCast(@max(0, (st.dict.get("First") orelse Obj{ .integer = 0 }).asInt() orelse 0));
        const data = try self.decodeStreamRaw(st);

        // Header: N pairs of (objnum offset) integers.
        var offsets = try self.arena.alloc(ObjStm.OffEntry, n);
        var hlex = Lexer.init(data, 0, self.arena);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const num_tok = hlex.next() catch break;
            const off_tok = hlex.next() catch break;
            const onum = std.math.cast(u32, num_tok.int_val) orelse 0;
            const ooff = first + @as(usize, @intCast(@max(0, off_tok.int_val)));
            offsets[idx] = .{ .num = onum, .off = ooff };
        }
        const os = ObjStm{ .offsets = offsets, .data = data };
        try self.objstm_cache.put(self.arena, stream_num, os);
        return os;
    }

    // --- stream decoding ------------------------------------------------------

    /// Apply the /Filter chain (+ /DecodeParms predictors) to a stream's raw
    /// bytes, resolving any indirect filter/parms references.
    pub fn decodeStreamRaw(self: *Document, st: *Stream) ExtractError![]u8 {
        var data: []const u8 = st.raw;

        // /Filter: a name or an array of names.
        const filter_obj = try self.dictGet(st.dict, "Filter") orelse return self.arena.dupe(u8, data);
        const parms_obj = try self.dictGet(st.dict, "DecodeParms");

        var filters: std.ArrayListUnmanaged([]const u8) = .empty;
        var parms: std.ArrayListUnmanaged(?Dict) = .empty;
        switch (filter_obj) {
            .name => |nm| {
                try filters.append(self.arena, nm);
                try parms.append(self.arena, if (parms_obj) |p| (try self.resolve(p)).asDict() else null);
            },
            .array => |arr| {
                for (arr, 0..) |f, fi| {
                    const fr = try self.resolve(f);
                    if (fr == .name) try filters.append(self.arena, fr.name);
                    var pd: ?Dict = null;
                    if (parms_obj) |p| {
                        if (p == .array and fi < p.array.len) {
                            pd = (try self.resolve(p.array[fi])).asDict();
                        } else if (p == .dict) pd = p.dict;
                    }
                    try parms.append(self.arena, pd);
                }
            },
            else => return self.arena.dupe(u8, data),
        }

        for (filters.items, 0..) |fname, fi| {
            const pd: ?Dict = if (fi < parms.items.len) parms.items[fi] else null;
            if (std.mem.eql(u8, fname, "FlateDecode") or std.mem.eql(u8, fname, "Fl")) {
                data = try inflate(self.arena, data);
                data = try self.maybePredict(data, pd);
            } else if (std.mem.eql(u8, fname, "ASCIIHexDecode") or std.mem.eql(u8, fname, "AHx")) {
                data = try asciiHexDecode(self.arena, data);
            } else if (std.mem.eql(u8, fname, "ASCII85Decode") or std.mem.eql(u8, fname, "A85")) {
                data = try ascii85Decode(self.arena, data);
            } else if (std.mem.eql(u8, fname, "RunLengthDecode") or std.mem.eql(u8, fname, "RL")) {
                data = try runLengthDecode(self.arena, data);
            } else if (std.mem.eql(u8, fname, "DCTDecode") or std.mem.eql(u8, fname, "JPXDecode") or
                std.mem.eql(u8, fname, "JBIG2Decode") or std.mem.eql(u8, fname, "CCITTFaxDecode"))
            {
                // Image data — not text. Leave as-is (caller treats as opaque).
                return self.arena.dupe(u8, data);
            } else {
                // Unknown/unsupported filter (e.g. LZWDecode in P1) — return raw.
                return self.arena.dupe(u8, data);
            }
        }
        return @constCast(data);
    }

    fn maybePredict(self: *Document, data: []const u8, pd: ?Dict) ExtractError![]u8 {
        const d = pd orelse return @constCast(data);
        const predictor = if (d.get("Predictor")) |p| (p.asInt() orelse 1) else 1;
        if (predictor <= 1) return @constCast(data);
        return applyPredictor(self.arena, data, .{
            .predictor = predictor,
            .colors = if (d.get("Colors")) |c| (c.asInt() orelse 1) else 1,
            .bits_per_component = if (d.get("BitsPerComponent")) |b| (b.asInt() orelse 8) else 8,
            .columns = if (d.get("Columns")) |c| (c.asInt() orelse 1) else 1,
        });
    }

    /// Resolve /Root → catalog dict.
    pub fn catalog(self: *Document) ExtractError!Dict {
        const root = try self.dictGet(self.trailer, "Root") orelse return ExtractError.MissingCatalog;
        return root.asDict() orelse ExtractError.MissingCatalog;
    }
};

fn readBE(bytes: []const u8) u64 {
    var v: u64 = 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

// =============================================================================
// Fonts — byte → Unicode mapping
// =============================================================================

/// WinAnsiEncoding (≈ Windows-1252) byte → Unicode codepoint. ASCII and the
/// Latin-1 high range map 1:1; only 0x80–0x9F carry the CP1252 specials.
fn winAnsiCodepoint(b: u8) u21 {
    return switch (b) {
        0x00...0x1f => 0,
        0x80 => 0x20AC, // €
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026, // …
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152, // Œ
        0x8E => 0x017D,
        0x91 => 0x2018, // ‘
        0x92 => 0x2019, // ’
        0x93 => 0x201C, // “
        0x94 => 0x201D, // ”
        0x95 => 0x2022, // •
        0x96 => 0x2013, // –
        0x97 => 0x2014, // —
        0x98 => 0x02DC,
        0x99 => 0x2122, // ™
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153, // œ
        0x9E => 0x017E,
        0x9F => 0x0178,
        0x81, 0x8D, 0x8F, 0x90, 0x9D => 0xFFFD, // undefined in CP1252
        else => b, // 0x20–0x7F and 0xA0–0xFF
    };
}

pub const Font = struct {
    /// code → Unicode string (UTF-8). Built from /ToUnicode, then /Encoding.
    to_unicode: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// code → glyph advance width, in 1/1000 em (glyph space).
    widths: std.AutoHashMapUnmanaged(u32, f64) = .empty,
    default_width: f64 = 500,
    /// True if at least one byte produced a real Unicode mapping. A page whose
    /// fonts are all unmapped is treated as a no-text-layer page.
    any_mapped: bool = false,
    /// Composite (Type0) fonts consume 2 bytes per code; simple fonts consume 1.
    bytes_per_code: u8 = 1,

    /// Decode one code's Unicode into `out`; returns whether a mapping existed.
    fn appendUnicode(self: *Font, arena: std.mem.Allocator, code: u32, out: *std.ArrayListUnmanaged(u8)) ExtractError!bool {
        if (self.to_unicode.get(code)) |u| {
            try out.appendSlice(arena, u);
            return true;
        }
        if (self.bytes_per_code == 1) {
            const cp = winAnsiCodepoint(@truncate(code));
            if (cp != 0 and cp != 0xFFFD) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return false;
                try out.appendSlice(arena, buf[0..n]);
                return true;
            }
        }
        return false;
    }

    fn widthOf(self: *Font, code: u32) f64 {
        return self.widths.get(code) orelse self.default_width;
    }
};

/// Build a Font from its dict. Reads /ToUnicode CMap, /Widths, and /Encoding.
fn buildFont(doc: *Document, font_dict: Dict) ExtractError!Font {
    var font = Font{};

    const subtype = if (font_dict.get("Subtype")) |s| (if (s == .name) s.name else "") else "";
    const is_type0 = std.mem.eql(u8, subtype, "Type0");
    if (is_type0) font.bytes_per_code = 2;

    // /ToUnicode (preferred — handles subset fonts like ABCDEF+Arial).
    if (try doc.dictGet(font_dict, "ToUnicode")) |tu| {
        if (tu == .stream) {
            const data = doc.decodeStreamRaw(tu.stream) catch &[_]u8{};
            parseToUnicode(doc.arena, data, &font) catch {};
        }
    }

    // For a simple font, seed the encoding table for any code not in ToUnicode.
    if (!is_type0) {
        try seedSimpleEncoding(doc, font_dict, &font);
        try loadSimpleWidths(doc, font_dict, &font);
    } else {
        // Type0: width default + /DescendantFonts /W is P3; advance with default.
        font.default_width = 1000;
        if (font.to_unicode.count() > 0) font.any_mapped = true;
    }

    return font;
}

/// Populate code→Unicode for a simple font from /Encoding (base + /Differences),
/// defaulting to WinAnsi. Only fills codes not already mapped by /ToUnicode.
fn seedSimpleEncoding(doc: *Document, font_dict: Dict, font: *Font) ExtractError!void {
    // Differences override specific codes by glyph name.
    if (try doc.dictGet(font_dict, "Encoding")) |enc| {
        if (enc == .dict) {
            if (enc.dict.get("Differences")) |diffs_obj| {
                const diffs = (try doc.resolve(diffs_obj));
                if (diffs == .array) {
                    var code: u32 = 0;
                    for (diffs.array) |item| {
                        const it = try doc.resolve(item);
                        switch (it) {
                            .integer => |v| code = std.math.cast(u32, v) orelse code,
                            .name => |gname| {
                                if (font.to_unicode.get(code) == null) {
                                    if (glyphNameToUnicode(gname)) |cp| {
                                        var buf: [4]u8 = undefined;
                                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                                        if (n > 0) {
                                            const owned = try doc.arena.dupe(u8, buf[0..n]);
                                            try font.to_unicode.put(doc.arena, code, owned);
                                            font.any_mapped = true;
                                        }
                                    }
                                }
                                code += 1;
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }
    // The WinAnsi base layer is applied lazily in Font.appendUnicode, so any
    // ASCII/Latin-1 code already resolves even without explicit entries.
    font.any_mapped = true;
}

fn loadSimpleWidths(doc: *Document, font_dict: Dict, font: *Font) ExtractError!void {
    const first_char: i64 = if (try doc.dictGet(font_dict, "FirstChar")) |fc| (fc.asInt() orelse 0) else 0;
    if (try doc.dictGet(font_dict, "Widths")) |w| {
        if (w == .array) {
            for (w.array, 0..) |wo, i| {
                const wr = try doc.resolve(wo);
                if (wr.asNumber()) |val| {
                    const code: u32 = std.math.cast(u32, first_char + @as(i64, @intCast(i))) orelse continue;
                    try font.widths.put(doc.arena, code, val);
                }
            }
        }
    }
    if (try doc.dictGet(font_dict, "FontDescriptor")) |fd| {
        if (fd.asDict()) |fdd| {
            if (fdd.get("MissingWidth")) |mw| {
                if (mw.asNumber()) |v| font.default_width = v;
            }
        }
    }
}

/// Parse a /ToUnicode CMap: beginbfchar / beginbfrange sections mapping codes to
/// UTF-16BE destination strings.
fn parseToUnicode(arena: std.mem.Allocator, data: []const u8, font: *Font) ExtractError!void {
    var lex = Lexer.init(data, 0, arena);
    while (true) {
        const t = lex.next() catch break;
        if (t.kind == .eof) break;
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "beginbfchar")) {
            try parseBfChar(arena, &lex, font);
        } else if (t.kind == .keyword and std.mem.eql(u8, t.text, "beginbfrange")) {
            try parseBfRange(arena, &lex, font);
        }
    }
}

fn utf16beToUtf8(arena: std.mem.Allocator, bytes: []const u8) ExtractError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var cp: u21 = @as(u21, bytes[i]) << 8 | bytes[i + 1];
        // Surrogate pair.
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 3 < bytes.len) {
            const lo: u21 = @as(u21, bytes[i + 2]) << 8 | bytes[i + 3];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}

fn parseBfChar(arena: std.mem.Allocator, lex: *Lexer, font: *Font) ExtractError!void {
    while (true) {
        const src = lex.next() catch break;
        if (src.kind == .keyword and std.mem.eql(u8, src.text, "endbfchar")) break;
        if (src.kind != .string) break;
        const dst = lex.next() catch break;
        if (dst.kind != .string) break;
        const code: u32 = @truncate(readBE(src.text));
        const utf8 = try utf16beToUtf8(arena, dst.text);
        if (utf8.len > 0) {
            try font.to_unicode.put(arena, code, utf8);
            font.any_mapped = true;
        }
    }
}

fn parseBfRange(arena: std.mem.Allocator, lex: *Lexer, font: *Font) ExtractError!void {
    while (true) {
        const lo_t = lex.next() catch break;
        if (lo_t.kind == .keyword and std.mem.eql(u8, lo_t.text, "endbfrange")) break;
        if (lo_t.kind != .string) break;
        const hi_t = lex.next() catch break;
        if (hi_t.kind != .string) break;
        const lo: u32 = @truncate(readBE(lo_t.text));
        const hi: u32 = @truncate(readBE(hi_t.text));

        const third = lex.next() catch break;
        if (third.kind == .string) {
            // Incrementing destination: dst, dst+1, …
            const base = try utf16beToUtf8(arena, third.text);
            // Only increment if a single codepoint; otherwise repeat base.
            var code = lo;
            var counter: u32 = 0;
            while (code <= hi and counter < 65536) : (code += 1) {
                const mapped = try incrementUtf8(arena, base, code - lo);
                if (mapped.len > 0) {
                    try font.to_unicode.put(arena, code, mapped);
                    font.any_mapped = true;
                }
                counter += 1;
                if (code == hi) break;
            }
        } else if (third.kind == .array_open) {
            var code = lo;
            while (true) {
                const el = lex.next() catch break;
                if (el.kind == .array_close) break;
                if (el.kind != .string) break;
                const utf8 = try utf16beToUtf8(arena, el.text);
                if (utf8.len > 0) {
                    try font.to_unicode.put(arena, code, utf8);
                    font.any_mapped = true;
                }
                code += 1;
            }
        } else break;
    }
}

/// Add `delta` to the last codepoint of a UTF-8 string (for bfrange).
fn incrementUtf8(arena: std.mem.Allocator, base: []const u8, delta: u32) ExtractError![]const u8 {
    if (delta == 0) return base;
    const view = std.unicode.Utf8View.init(base) catch return base;
    var it = view.iterator();
    var last: u21 = 0;
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        last = cp;
        count += 1;
    }
    if (count != 1) return base; // multi-cp ranges: keep base
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(@as(u32, last) + delta), &buf) catch return base;
    return arena.dupe(u8, buf[0..n]);
}

/// Minimal Adobe Glyph List support: algorithmic `uniXXXX`/`uXXXXXX` plus a
/// compact table of the most common names. Unknown names → null (recorded as a
/// gap, never emitted as `cid:NNN` garbage).
fn glyphNameToUnicode(name: []const u8) ?u21 {
    if (name.len == 0) return null;
    if (std.mem.startsWith(u8, name, "uni") and name.len >= 7) {
        return std.fmt.parseInt(u21, name[3..7], 16) catch null;
    }
    if (name.len >= 2 and name[0] == 'u') {
        if (std.fmt.parseInt(u21, name[1..], 16)) |v| return v else |_| {}
    }
    // Single-letter / digit glyph names map to their ASCII value.
    if (name.len == 1) return name[0];
    const common = std.StaticStringMap(u21).initComptime(.{
        .{ "space", 0x20 },     .{ "exclam", 0x21 },   .{ "quotedbl", 0x22 },
        .{ "numbersign", 0x23 }, .{ "dollar", 0x24 },  .{ "percent", 0x25 },
        .{ "ampersand", 0x26 }, .{ "quotesingle", 0x27 }, .{ "parenleft", 0x28 },
        .{ "parenright", 0x29 }, .{ "asterisk", 0x2A }, .{ "plus", 0x2B },
        .{ "comma", 0x2C },     .{ "hyphen", 0x2D },   .{ "period", 0x2E },
        .{ "slash", 0x2F },     .{ "colon", 0x3A },    .{ "semicolon", 0x3B },
        .{ "less", 0x3C },      .{ "equal", 0x3D },    .{ "greater", 0x3E },
        .{ "question", 0x3F },  .{ "at", 0x40 },       .{ "bracketleft", 0x5B },
        .{ "backslash", 0x5C }, .{ "bracketright", 0x5D }, .{ "underscore", 0x5F },
        .{ "braceleft", 0x7B }, .{ "bar", 0x7C },      .{ "braceright", 0x7D },
        .{ "quoteleft", 0x2018 }, .{ "quoteright", 0x2019 },
        .{ "quotedblleft", 0x201C }, .{ "quotedblright", 0x201D },
        .{ "bullet", 0x2022 },  .{ "endash", 0x2013 }, .{ "emdash", 0x2014 },
        .{ "fi", 0xFB01 },      .{ "fl", 0xFB02 },     .{ "ellipsis", 0x2026 },
        .{ "trademark", 0x2122 }, .{ "degree", 0xB0 }, .{ "copyright", 0xA9 },
        .{ "registered", 0xAE }, .{ "nbspace", 0xA0 }, .{ "periodcentered", 0xB7 },
    });
    return common.get(name);
}

// =============================================================================
// Stream filters
// =============================================================================

const flate = std.compress.flate;

/// zlib/deflate inflate. PDF /FlateDecode is nominally a zlib stream, but real
/// files sometimes omit the 2-byte zlib header — so we try zlib first and fall
/// back to a raw deflate stream.
fn inflate(arena: std.mem.Allocator, data: []const u8) ExtractError![]u8 {
    if (inflateContainer(arena, data, .zlib)) |out| return out else |_| {}
    if (inflateContainer(arena, data, .raw)) |out| return out else |_| {}
    return ExtractError.UnsupportedFilter;
}

fn inflateContainer(arena: std.mem.Allocator, data: []const u8, container: flate.Container) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, container, &window);
    var aw: std.Io.Writer.Allocating = .init(arena);
    errdefer aw.deinit();
    _ = dec.reader.streamRemaining(&aw.writer) catch |e| {
        // A truncated/corrupt tail still leaves useful decoded bytes in `aw`;
        // accept what we got rather than dropping the whole stream.
        if (aw.written().len == 0) return e;
    };
    return aw.toOwnedSlice();
}

/// ASCIIHexDecode: hex digits → bytes, terminated by '>'.
fn asciiHexDecode(arena: std.mem.Allocator, data: []const u8) ExtractError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var hi: ?u8 = null;
    for (data) |c| {
        if (c == '>') break;
        const v = hexVal(c) orelse continue;
        if (hi) |h| {
            try out.append(arena, h * 16 + v);
            hi = null;
        } else hi = v;
    }
    if (hi) |h| try out.append(arena, h * 16);
    return out.items;
}

/// ASCII85Decode: groups of 5 chars (85^4) → 4 bytes; 'z' → 4 zero bytes;
/// terminated by '~>'.
fn ascii85Decode(arena: std.mem.Allocator, data: []const u8) ExtractError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var tuple: [5]u8 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == '~') break;
        if (isWhitespace(c)) continue;
        if (c == 'z' and count == 0) {
            try out.appendSlice(arena, &.{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') continue; // out of range — skip
        tuple[count] = c - '!';
        count += 1;
        if (count == 5) {
            var val: u32 = 0;
            for (tuple) |t| val = val *% 85 +% t;
            try out.append(arena, @truncate(val >> 24));
            try out.append(arena, @truncate(val >> 16));
            try out.append(arena, @truncate(val >> 8));
            try out.append(arena, @truncate(val));
            count = 0;
        }
    }
    if (count > 0) {
        // Pad the final partial group with 'u' (84) per the spec.
        var j = count;
        while (j < 5) : (j += 1) tuple[j] = 84;
        var val: u32 = 0;
        for (tuple) |t| val = val *% 85 +% t;
        var k: usize = 0;
        while (k < count - 1) : (k += 1) {
            try out.append(arena, @truncate(val >> @intCast(24 - k * 8)));
        }
    }
    return out.items;
}

/// RunLengthDecode: length byte L. 0–127 → copy next L+1 bytes; 129–255 → repeat
/// next byte 257-L times; 128 → EOD.
fn runLengthDecode(arena: std.mem.Allocator, data: []const u8) ExtractError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        const len = data[i];
        i += 1;
        if (len == 128) break;
        if (len < 128) {
            const n = @as(usize, len) + 1;
            const end = @min(i + n, data.len);
            try out.appendSlice(arena, data[i..end]);
            i = end;
        } else {
            if (i >= data.len) break;
            const n = 257 - @as(usize, len);
            const b = data[i];
            i += 1;
            try out.appendSlice(arena, &.{});
            var k: usize = 0;
            while (k < n) : (k += 1) try out.append(arena, b);
        }
    }
    return out.items;
}

const PredictorParams = struct {
    predictor: i64 = 1,
    colors: i64 = 1,
    bits_per_component: i64 = 8,
    columns: i64 = 1,
};

/// Apply a PNG (predictor ≥10) or TIFF (predictor 2) row predictor. The data is
/// laid out as rows of `row_len` bytes; PNG rows carry a leading filter-type
/// byte. Returns the de-predicted bytes.
fn applyPredictor(arena: std.mem.Allocator, data: []const u8, p: PredictorParams) ExtractError![]u8 {
    if (p.predictor <= 1) return @constCast(data);

    const colors: usize = @max(1, std.math.cast(usize, p.colors) orelse 1);
    const bpc: usize = @max(1, std.math.cast(usize, p.bits_per_component) orelse 8);
    const columns: usize = @max(1, std.math.cast(usize, p.columns) orelse 1);
    const bpp: usize = @max(1, (colors * bpc + 7) / 8); // bytes per pixel
    const row_len: usize = (colors * bpc * columns + 7) / 8;
    if (row_len == 0) return @constCast(data);

    if (p.predictor == 2) {
        // TIFF predictor 2 — horizontal differencing (8-bit components only;
        // sub-byte components are rare and skipped to avoid corrupting output).
        if (bpc != 8) return @constCast(data);
        var out = try arena.dupe(u8, data);
        var row: usize = 0;
        while (row * row_len < out.len) : (row += 1) {
            const base = row * row_len;
            var i: usize = bpp;
            while (i < row_len and base + i < out.len) : (i += 1) {
                out[base + i] = out[base + i] +% out[base + i - bpp];
            }
        }
        return out;
    }

    // PNG predictors: each row is 1 filter byte + row_len data bytes.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var prev_row = try arena.alloc(u8, row_len);
    @memset(prev_row, 0);
    var cur = try arena.alloc(u8, row_len);

    var off: usize = 0;
    while (off + 1 <= data.len) {
        const ftype = data[off];
        off += 1;
        const avail = @min(row_len, data.len - off);
        @memcpy(cur[0..avail], data[off .. off + avail]);
        if (avail < row_len) @memset(cur[avail..], 0);
        off += avail;

        var i: usize = 0;
        while (i < row_len) : (i += 1) {
            const a: u16 = if (i >= bpp) cur[i - bpp] else 0; // left
            const b: u16 = prev_row[i]; // up
            const c: u16 = if (i >= bpp) prev_row[i - bpp] else 0; // upper-left
            const x: u16 = cur[i];
            const recon: u8 = switch (ftype) {
                0 => @truncate(x),
                1 => @truncate(x + a),
                2 => @truncate(x + b),
                3 => @truncate(x + (a + b) / 2),
                4 => @truncate(x + paeth(a, b, c)),
                else => @truncate(x), // unknown filter → pass through
            };
            cur[i] = recon;
        }
        try out.appendSlice(arena, cur);
        const tmp = prev_row;
        prev_row = cur;
        cur = tmp;
        if (avail < row_len) break;
    }
    return out.items;
}

fn paeth(a: u16, b: u16, c: u16) u16 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// =============================================================================
// Geometry — affine matrices
// =============================================================================

const Matrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    /// `self` applied first, then `n` (row-vector convention: [x y 1]·self·n).
    fn mul(self: Matrix, n: Matrix) Matrix {
        return .{
            .a = self.a * n.a + self.b * n.c,
            .b = self.a * n.b + self.b * n.d,
            .c = self.c * n.a + self.d * n.c,
            .d = self.c * n.b + self.d * n.d,
            .e = self.e * n.a + self.f * n.c + n.e,
            .f = self.e * n.b + self.f * n.d + n.f,
        };
    }

    fn translation(tx: f64, ty: f64) Matrix {
        return .{ .e = tx, .f = ty };
    }
};

// =============================================================================
// Content-stream interpreter → positioned text fragments
// =============================================================================

/// A run of text placed on the page in device space. `x`/`y` are the baseline
/// origin of the first glyph; `end_x` is where the run ends (for gap analysis).
const Frag = struct {
    x: f64,
    y: f64,
    end_x: f64,
    size: f64,
    text: []const u8,
};

const PageGeom = struct {
    media_w: f64,
    media_h: f64,
    rotate: i64,
};

const TextState = struct {
    tm: Matrix = .{},
    tlm: Matrix = .{},
    tf_size: f64 = 0,
    leading: f64 = 0,
    char_spacing: f64 = 0,
    word_spacing: f64 = 0,
    h_scale: f64 = 1.0, // Tz / 100
    rise: f64 = 0,
    font: ?*Font = null,
};

const Interp = struct {
    doc: *Document,
    arena: std.mem.Allocator,
    fonts: *std.StringHashMapUnmanaged(*Font),
    geom: PageGeom,
    frags: *std.ArrayListUnmanaged(Frag),
    any_text: *bool,

    ctm: Matrix = .{},
    ctm_stack: std.ArrayListUnmanaged(Matrix) = .empty,
    ts: TextState = .{},

    fn run(self: *Interp, content: []const u8) ExtractError!void {
        var lex = Lexer.init(content, 0, self.arena);
        var operands: std.ArrayListUnmanaged(Obj) = .empty;
        var guard: usize = 0;

        while (true) {
            guard += 1;
            if (guard > 50_000_000) break; // pathological-stream backstop
            const tok = lex.next() catch break;
            switch (tok.kind) {
                .eof => break,
                .integer => try operands.append(self.arena, .{ .integer = tok.int_val }),
                .real => try operands.append(self.arena, .{ .real = tok.real_val }),
                .string => try operands.append(self.arena, .{ .string = tok.text }),
                .name => try operands.append(self.arena, .{ .name = tok.text }),
                .array_open => {
                    const arr = try self.collectArray(&lex);
                    try operands.append(self.arena, arr);
                },
                .dict_open => {
                    // Inline-image/dict operand — skip its contents.
                    try self.skipDict(&lex);
                },
                .array_close, .dict_close => {},
                .keyword => {
                    self.execOp(tok.text, operands.items) catch {};
                    operands.clearRetainingCapacity();
                },
            }
            if (operands.items.len > 64) operands.clearRetainingCapacity();
        }
    }

    fn collectArray(self: *Interp, lex: *Lexer) ExtractError!Obj {
        var items: std.ArrayListUnmanaged(Obj) = .empty;
        while (true) {
            const t = lex.next() catch break;
            switch (t.kind) {
                .array_close, .eof => break,
                .integer => try items.append(self.arena, .{ .integer = t.int_val }),
                .real => try items.append(self.arena, .{ .real = t.real_val }),
                .string => try items.append(self.arena, .{ .string = t.text }),
                .name => try items.append(self.arena, .{ .name = t.text }),
                else => {},
            }
            if (items.items.len > 100_000) break;
        }
        return .{ .array = items.items };
    }

    fn skipDict(self: *Interp, lex: *Lexer) ExtractError!void {
        _ = self;
        var depth: usize = 1;
        while (depth > 0) {
            const t = lex.next() catch break;
            switch (t.kind) {
                .dict_open => depth += 1,
                .dict_close => depth -= 1,
                .eof => break,
                .keyword => if (std.mem.eql(u8, t.text, "ID")) {
                    // Inline image data follows raw until EI — bail to be safe.
                    break;
                },
                else => {},
            }
        }
    }

    fn execOp(self: *Interp, op: []const u8, args: []const Obj) ExtractError!void {
        if (op.len == 0) return;
        // Graphics state.
        if (std.mem.eql(u8, op, "q")) {
            try self.ctm_stack.append(self.arena, self.ctm);
        } else if (std.mem.eql(u8, op, "Q")) {
            if (self.ctm_stack.pop()) |m| self.ctm = m;
        } else if (std.mem.eql(u8, op, "cm")) {
            if (args.len >= 6) self.ctm = matFromArgs(args[args.len - 6 ..]).mul(self.ctm);
        }
        // Text object.
        else if (std.mem.eql(u8, op, "BT")) {
            self.ts.tm = .{};
            self.ts.tlm = .{};
        } else if (std.mem.eql(u8, op, "ET")) {
            // nothing
        } else if (std.mem.eql(u8, op, "Tf")) {
            if (args.len >= 2) {
                const fname = if (args[args.len - 2] == .name) args[args.len - 2].name else "";
                self.ts.tf_size = args[args.len - 1].asNumber() orelse self.ts.tf_size;
                self.ts.font = self.fonts.get(fname);
            }
        } else if (std.mem.eql(u8, op, "Td")) {
            if (args.len >= 2) self.applyTd(args[args.len - 2].asNumber() orelse 0, args[args.len - 1].asNumber() orelse 0);
        } else if (std.mem.eql(u8, op, "TD")) {
            if (args.len >= 2) {
                const ty = args[args.len - 1].asNumber() orelse 0;
                self.ts.leading = -ty;
                self.applyTd(args[args.len - 2].asNumber() orelse 0, ty);
            }
        } else if (std.mem.eql(u8, op, "Tm")) {
            if (args.len >= 6) {
                self.ts.tlm = matFromArgs(args[args.len - 6 ..]);
                self.ts.tm = self.ts.tlm;
            }
        } else if (std.mem.eql(u8, op, "T*")) {
            self.applyTd(0, -self.ts.leading);
        } else if (std.mem.eql(u8, op, "TL")) {
            if (args.len >= 1) self.ts.leading = args[args.len - 1].asNumber() orelse 0;
        } else if (std.mem.eql(u8, op, "Tc")) {
            if (args.len >= 1) self.ts.char_spacing = args[args.len - 1].asNumber() orelse 0;
        } else if (std.mem.eql(u8, op, "Tw")) {
            if (args.len >= 1) self.ts.word_spacing = args[args.len - 1].asNumber() orelse 0;
        } else if (std.mem.eql(u8, op, "Tz")) {
            if (args.len >= 1) self.ts.h_scale = (args[args.len - 1].asNumber() orelse 100) / 100.0;
        } else if (std.mem.eql(u8, op, "Ts")) {
            if (args.len >= 1) self.ts.rise = args[args.len - 1].asNumber() orelse 0;
        }
        // Show text.
        else if (std.mem.eql(u8, op, "Tj")) {
            if (args.len >= 1 and args[args.len - 1] == .string) try self.showText(args[args.len - 1].string);
        } else if (std.mem.eql(u8, op, "'")) {
            self.applyTd(0, -self.ts.leading);
            if (args.len >= 1 and args[args.len - 1] == .string) try self.showText(args[args.len - 1].string);
        } else if (std.mem.eql(u8, op, "\"")) {
            if (args.len >= 3) {
                self.ts.word_spacing = args[args.len - 3].asNumber() orelse 0;
                self.ts.char_spacing = args[args.len - 2].asNumber() orelse 0;
                self.applyTd(0, -self.ts.leading);
                if (args[args.len - 1] == .string) try self.showText(args[args.len - 1].string);
            }
        } else if (std.mem.eql(u8, op, "TJ")) {
            if (args.len >= 1 and args[args.len - 1] == .array) try self.showTJ(args[args.len - 1].array);
        }
    }

    fn applyTd(self: *Interp, tx: f64, ty: f64) void {
        self.ts.tlm = Matrix.translation(tx, ty).mul(self.ts.tlm);
        self.ts.tm = self.ts.tlm;
    }

    /// The text-rendering matrix for the current state.
    fn renderMatrix(self: *Interp) Matrix {
        const params = Matrix{
            .a = self.ts.tf_size * self.ts.h_scale,
            .d = self.ts.tf_size,
            .f = self.ts.rise,
        };
        return params.mul(self.ts.tm).mul(self.ctm);
    }

    fn showTJ(self: *Interp, arr: []const Obj) ExtractError!void {
        for (arr) |el| {
            switch (el) {
                .string => |s| try self.showText(s),
                .integer, .real => {
                    const adj = el.asNumber() orelse 0;
                    // Negative adjustment moves text right (a gap). Apply in text
                    // space; geometry in the fragment list turns big gaps into
                    // spaces during line assembly.
                    const tx = (-adj / 1000.0) * self.ts.tf_size * self.ts.h_scale;
                    self.ts.tm = Matrix.translation(tx, 0).mul(self.ts.tm);
                },
                else => {},
            }
        }
    }

    fn showText(self: *Interp, bytes: []const u8) ExtractError!void {
        const font = self.ts.font;
        const trm_start = self.renderMatrix();
        const start_x = trm_start.e;
        const start_y = trm_start.f;
        const size = @max(@abs(@sqrt(trm_start.c * trm_start.c + trm_start.d * trm_start.d)), 0.01);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        const step: usize = if (font) |fp| fp.bytes_per_code else 1;

        var i: usize = 0;
        while (i < bytes.len) : (i += step) {
            var code: u32 = bytes[i];
            if (step == 2 and i + 1 < bytes.len) code = (@as(u32, bytes[i]) << 8) | bytes[i + 1];

            var w0: f64 = 0.5;
            if (font) |fp| {
                _ = fp.appendUnicode(self.arena, code, &text) catch {};
                w0 = fp.widthOf(code) / 1000.0;
            } else {
                // No font resource — best-effort WinAnsi for ASCII.
                const cp = winAnsiCodepoint(@truncate(code));
                if (cp != 0 and cp != 0xFFFD) {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &b) catch 0;
                    if (n > 0) try text.appendSlice(self.arena, b[0..n]);
                }
            }

            const is_space = (step == 1 and code == 32);
            const word = if (is_space) self.ts.word_spacing else 0;
            const tx = (w0 * self.ts.tf_size + self.ts.char_spacing + word) * self.ts.h_scale;
            self.ts.tm = Matrix.translation(tx, 0).mul(self.ts.tm);
        }

        const end_x = self.renderMatrix().e;
        if (text.items.len > 0) {
            self.any_text.* = true;
            try self.frags.append(self.arena, .{
                .x = start_x,
                .y = start_y,
                .end_x = end_x,
                .size = size,
                .text = text.items,
            });
        }
    }
};

fn matFromArgs(a: []const Obj) Matrix {
    return .{
        .a = a[0].asNumber() orelse 1,
        .b = a[1].asNumber() orelse 0,
        .c = a[2].asNumber() orelse 0,
        .d = a[3].asNumber() orelse 1,
        .e = a[4].asNumber() orelse 0,
        .f = a[5].asNumber() orelse 0,
    };
}

// =============================================================================
// Page tree
// =============================================================================

const Page = struct {
    resources: Dict,
    geom: PageGeom,
    content: []u8,
};

/// Walk /Root /Pages, inheriting /Resources, /MediaBox, /Rotate down the tree,
/// and collect each leaf page's concatenated, decoded content stream.
fn collectPages(doc: *Document, out: *std.ArrayListUnmanaged(Page)) ExtractError!void {
    const cat = try doc.catalog();
    const pages_obj = try doc.dictGet(cat, "Pages") orelse return ExtractError.MissingCatalog;
    const pages = pages_obj.asDict() orelse return ExtractError.MissingCatalog;

    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try walkPageNode(doc, pages, .{}, &visited, out, 0);
}

const Inherited = struct {
    resources: ?Dict = null,
    media_w: f64 = 612,
    media_h: f64 = 792,
    rotate: i64 = 0,
};

fn walkPageNode(
    doc: *Document,
    node: Dict,
    inh_in: Inherited,
    visited: *std.AutoHashMapUnmanaged(u32, void),
    out: *std.ArrayListUnmanaged(Page),
    depth: usize,
) ExtractError!void {
    if (depth > 200) return; // bounded recursion
    if (out.items.len > 100_000) return;

    var inh = inh_in;
    if (try doc.dictGet(node, "Resources")) |r| {
        if (r.asDict()) |rd| inh.resources = rd;
    }
    if (try doc.dictGet(node, "MediaBox")) |mb| {
        if (mb == .array and mb.array.len >= 4) {
            const x0 = mb.array[0].asNumber() orelse 0;
            const y0 = mb.array[1].asNumber() orelse 0;
            const x1 = mb.array[2].asNumber() orelse 612;
            const y1 = mb.array[3].asNumber() orelse 792;
            inh.media_w = @abs(x1 - x0);
            inh.media_h = @abs(y1 - y0);
        }
    }
    if (try doc.dictGet(node, "Rotate")) |rot| {
        if (rot.asInt()) |r| inh.rotate = @mod(r, 360);
    }

    const node_type = if (node.get("Type")) |t| (if (t == .name) t.name else "") else "";
    const kids_obj = try doc.dictGet(node, "Kids");

    if (kids_obj == null or std.mem.eql(u8, node_type, "Page")) {
        // Leaf page.
        const content = try collectPageContent(doc, node);
        try out.append(doc.arena, .{
            .resources = inh.resources orelse Dict{},
            .geom = .{ .media_w = inh.media_w, .media_h = inh.media_h, .rotate = inh.rotate },
            .content = content,
        });
        return;
    }

    const kids = kids_obj.?;
    if (kids != .array) return;
    for (kids.array) |kid_ref| {
        if (kid_ref == .ref) {
            if (visited.contains(kid_ref.ref.num)) continue;
            try visited.put(doc.arena, kid_ref.ref.num, {});
        }
        const kid = try doc.resolve(kid_ref);
        if (kid.asDict()) |kd| try walkPageNode(doc, kd, inh, visited, out, depth + 1);
    }
}

fn collectPageContent(doc: *Document, page: Dict) ExtractError![]u8 {
    const contents = try doc.dictGet(page, "Contents") orelse return &[_]u8{};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    switch (contents) {
        .stream => |s| {
            const d = doc.decodeStreamRaw(s) catch &[_]u8{};
            try buf.appendSlice(doc.arena, d);
        },
        .array => |arr| {
            for (arr) |item| {
                const r = try doc.resolve(item);
                if (r == .stream) {
                    const d = doc.decodeStreamRaw(r.stream) catch &[_]u8{};
                    try buf.appendSlice(doc.arena, d);
                    try buf.append(doc.arena, '\n'); // separate streams
                }
            }
        },
        else => {},
    }
    return buf.items;
}

/// Build the per-page font table from /Resources /Font.
fn buildPageFonts(doc: *Document, resources: Dict, fonts: *std.StringHashMapUnmanaged(*Font)) ExtractError!void {
    const font_dict_obj = try doc.dictGet(resources, "Font") orelse return;
    const font_dict = font_dict_obj.asDict() orelse return;
    for (font_dict.entries) |e| {
        const fobj = try doc.resolve(e.val);
        const fd = fobj.asDict() orelse continue;
        const fptr = try doc.arena.create(Font);
        fptr.* = buildFont(doc, fd) catch Font{};
        try fonts.put(doc.arena, e.key, fptr);
    }
}

// =============================================================================
// Reading order — fragments → lines → blocks
// =============================================================================

/// One assembled line of text plus the geometry needed for block inference.
const Line = struct {
    text: []const u8,
    y: f64,
    x: f64, // left edge
    size: f64, // representative (max) font size on the line
};

/// Assemble positioned fragments into reading-ordered lines (single column,
/// P1). The sort comparator defines a TOTAL order (see CLAUDE.md §7 — an
/// invalid comparator is exactly what panicked the competitor).
fn assembleLines(arena: std.mem.Allocator, frags: []Frag, out: *std.ArrayListUnmanaged(Line)) ExtractError!void {
    if (frags.len == 0) return;

    // Sort top-to-bottom (descending device y), then left-to-right.
    std.sort.block(Frag, frags, {}, fragLess);

    var i: usize = 0;
    while (i < frags.len) {
        // Gather all fragments on the same line as frags[i].
        const line_y = frags[i].y;
        const tol = @max(frags[i].size * 0.35, 1.0);
        var j = i;
        var max_size: f64 = 0;
        var line_frags: std.ArrayListUnmanaged(Frag) = .empty;
        while (j < frags.len and @abs(frags[j].y - line_y) <= tol) : (j += 1) {
            try line_frags.append(arena, frags[j]);
            if (frags[j].size > max_size) max_size = frags[j].size;
        }

        // Sort this line strictly left-to-right.
        std.sort.block(Frag, line_frags.items, {}, fragLeftLess);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        var prev_end: ?f64 = null;
        const left_x = line_frags.items[0].x;
        for (line_frags.items) |fr| {
            if (prev_end) |pe| {
                const gap = fr.x - pe;
                // Insert a space when the gap exceeds ~¼ em and the existing
                // text doesn't already end in whitespace.
                if (gap > fr.size * 0.25 and !endsWithSpace(text.items)) {
                    try text.append(arena, ' ');
                }
            }
            try text.appendSlice(arena, fr.text);
            prev_end = fr.end_x;
        }

        try out.append(arena, .{
            .text = try trimTrailing(arena, text.items),
            .y = line_y,
            .x = left_x,
            .size = max_size,
        });
        i = j;
    }
}

fn fragLess(_: void, a: Frag, b: Frag) bool {
    // Total order: primary key descending y (bucketed to avoid jitter), then x,
    // then a stable tiebreak on the raw y so equal keys never compare equal-both-ways.
    const ay = @round(a.y * 2.0);
    const by = @round(b.y * 2.0);
    if (ay != by) return ay > by;
    if (a.x != b.x) return a.x < b.x;
    return a.y > b.y;
}

fn fragLeftLess(_: void, a: Frag, b: Frag) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.end_x < b.end_x;
}

fn endsWithSpace(s: []const u8) bool {
    return s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t');
}

fn trimTrailing(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    var start: usize = 0;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    return arena.dupe(u8, s[start..end]);
}

// =============================================================================
// MDX emission
// =============================================================================

pub const ExtractOptions = struct {
    extract_images: bool = false,
    detect_tables: bool = true,
    detect_headings: bool = true,
    /// Optional source filename for the frontmatter `source:` field.
    source_name: []const u8 = "",
};

pub const ExtractionMeta = struct {
    pages: usize = 0,
    has_text_layer: bool = false,
    needs_ocr: bool = false,
    images_found: usize = 0,
    tables_found: usize = 0,
    extraction_method: []const u8 = "zig-native",
    encrypted: bool = false,
};

pub const ExtractResult = struct {
    mdx: []u8,
    meta: ExtractionMeta,
};

/// The most common rounded font size across all lines — the body text size,
/// used as the baseline for heading detection.
fn modalBodySize(lines: []const Line) f64 {
    if (lines.len == 0) return 12;
    var counts: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer counts.deinit(std.heap.page_allocator);
    var best_size: f64 = 12;
    var best_count: usize = 0;
    for (lines) |ln| {
        const key: u32 = @intFromFloat(@round(ln.size));
        const gop = counts.getOrPut(std.heap.page_allocator, key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += ln.text.len; // weight by text length (body dominates)
        if (gop.value_ptr.* > best_count) {
            best_count = gop.value_ptr.*;
            best_size = @floatFromInt(key);
        }
    }
    return @max(best_size, 1);
}

/// Infer a heading level from a line's font size relative to the modal body
/// size. A heading must also be *short* — long lines at a slightly larger size
/// are emphasised body text, not headings, and labelling them inflates the
/// outline with junk `####` lines.
fn headingLevel(size: f64, body: f64, text: []const u8) ?u8 {
    // Real headings are short; a "heading" that runs on is a paragraph.
    if (text.len > 80 or wordCount(text) > 12) return null;
    const r = size / body;
    if (r >= 1.8) return 1;
    if (r >= 1.5) return 2;
    if (r >= 1.28) return 3;
    if (r >= 1.14) return 4;
    return null;
}

fn wordCount(s: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (s) |c| {
        if (c == ' ' or c == '\t') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
    }
    return n;
}

/// Emit MDX (YAML frontmatter + Markdown body) from assembled lines, matching
/// the `zig_docx` output contract.
fn emitMdx(
    arena: std.mem.Allocator,
    lines: []const Line,
    info: Dict,
    doc: *Document,
    page_count: usize,
    has_text: bool,
    opts: ExtractOptions,
) ExtractError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    const title = try infoString(arena, doc, info, "Title");
    const author = try infoString(arena, doc, info, "Author");

    // --- frontmatter ---
    w.writeAll("---\n") catch return ExtractError.OutOfMemory;
    if (title) |t| {
        if (t.len > 0) w.print("title: \"{s}\"\n", .{yamlEscape(arena, t) catch t}) catch {};
    } else if (lines.len > 0 and has_text) {
        // Fall back to the first heading-ish line as the title.
        const body = modalBodySize(lines);
        for (lines) |ln| {
            if (ln.text.len > 0 and headingLevel(ln.size, body, ln.text) != null) {
                w.print("title: \"{s}\"\n", .{yamlEscape(arena, ln.text) catch ln.text}) catch {};
                break;
            }
        }
    }
    if (author) |a| {
        if (a.len > 0) w.print("author: \"{s}\"\n", .{yamlEscape(arena, a) catch a}) catch {};
    }
    if (opts.source_name.len > 0) w.print("source: \"{s}\"\n", .{opts.source_name}) catch {};
    w.print("pages: {d}\n", .{page_count}) catch {};
    w.writeAll("extraction_method: zig-native\n") catch {};
    w.print("has_text_layer: {s}\n", .{if (has_text) "true" else "false"}) catch {};
    if (!has_text) w.writeAll("needs_ocr: true\n") catch {};
    w.writeAll("---\n\n") catch {};

    if (!has_text) {
        w.writeAll("> No extractable text layer was found in this PDF (it appears to be scanned or image-only). Route it to OCR.\n") catch {};
        return aw.toOwnedSlice();
    }

    // --- body ---
    const body_size = modalBodySize(lines);
    var para: std.ArrayListUnmanaged(u8) = .empty;
    var prev_y: ?f64 = null;
    var prev_size: f64 = body_size;

    for (lines) |ln| {
        if (ln.text.len == 0) continue;

        const level = if (opts.detect_headings) headingLevel(ln.size, body_size, ln.text) else null;

        // A large vertical gap ends the current paragraph.
        var gap_break = false;
        if (prev_y) |py| {
            const gap = py - ln.y;
            if (gap > prev_size * 1.8) gap_break = true;
        }

        if (level != null or gap_break) {
            try flushPara(arena, w, &para);
        }

        if (level) |lv| {
            // Heading: emit on its own line.
            var h: usize = 0;
            while (h < lv) : (h += 1) w.writeAll("#") catch {};
            w.print(" {s}\n\n", .{ln.text}) catch {};
        } else {
            // Append to the running paragraph, de-hyphenating soft breaks.
            if (para.items.len > 0) {
                if (endsWithHyphen(para.items) and continuesWord(ln.text)) {
                    _ = para.pop(); // drop the hyphen, join directly
                } else if (!endsWithSpace(para.items)) {
                    try para.append(arena, ' ');
                }
            }
            try para.appendSlice(arena, ln.text);
        }

        prev_y = ln.y;
        prev_size = ln.size;
    }
    try flushPara(arena, w, &para);

    return aw.toOwnedSlice();
}

fn flushPara(arena: std.mem.Allocator, w: *std.Io.Writer, para: *std.ArrayListUnmanaged(u8)) ExtractError!void {
    if (para.items.len == 0) return;
    w.print("{s}\n\n", .{para.items}) catch return ExtractError.OutOfMemory;
    para.clearRetainingCapacity();
    _ = arena;
}

fn endsWithHyphen(s: []const u8) bool {
    if (s.len < 2) return false;
    const last = s[s.len - 1];
    const before = s[s.len - 2];
    return last == '-' and ((before >= 'a' and before <= 'z') or (before >= 'A' and before <= 'Z'));
}

fn continuesWord(s: []const u8) bool {
    return s.len > 0 and ((s[0] >= 'a' and s[0] <= 'z') or (s[0] >= 'A' and s[0] <= 'Z'));
}

fn infoString(arena: std.mem.Allocator, doc: *Document, info: Dict, key: []const u8) ExtractError!?[]const u8 {
    const v = (try doc.dictGet(info, key)) orelse return null;
    if (v == .string) {
        // /Info strings may be UTF-16BE (BOM FE FF) or PDFDoc/ASCII.
        const s = v.string;
        if (s.len >= 2 and s[0] == 0xFE and s[1] == 0xFF) {
            return try utf16beToUtf8(arena, s[2..]);
        }
        return s;
    }
    return null;
}

fn yamlEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n', '\r' => try out.append(arena, ' '),
            else => try out.append(arena, c),
        }
    }
    return out.items;
}

// =============================================================================
// Public API
// =============================================================================

/// Extract MDX from PDF bytes. All allocation happens in an internal arena; the
/// returned `mdx` slice is copied into `gpa` so the arena can be released. The
/// caller owns and must free `result.mdx`.
pub fn extractToMdx(gpa: std.mem.Allocator, pdf: []const u8, opts: ExtractOptions) ExtractError!ExtractResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = try Document.parse(arena, pdf);

    var meta = ExtractionMeta{ .encrypted = doc.encrypted };

    // Encrypted PDFs are P3 — surface a clean, honest result, never a crash.
    if (doc.encrypted) {
        const note = "---\nextraction_method: zig-native\nhas_text_layer: false\nneeds_ocr: false\nencrypted: true\n---\n\n> This PDF is encrypted; decryption is not yet supported.\n";
        return .{ .mdx = try gpa.dupe(u8, note), .meta = meta };
    }

    var pages: std.ArrayListUnmanaged(Page) = .empty;
    try collectPages(&doc, &pages);
    meta.pages = pages.items.len;

    var all_lines: std.ArrayListUnmanaged(Line) = .empty;
    var any_text = false;

    for (pages.items) |page| {
        var fonts: std.StringHashMapUnmanaged(*Font) = .empty;
        buildPageFonts(&doc, page.resources, &fonts) catch {};

        var frags: std.ArrayListUnmanaged(Frag) = .empty;
        var interp = Interp{
            .doc = &doc,
            .arena = arena,
            .fonts = &fonts,
            .geom = page.geom,
            .frags = &frags,
            .any_text = &any_text,
        };
        interp.run(page.content) catch {};

        var page_lines: std.ArrayListUnmanaged(Line) = .empty;
        assembleLines(arena, frags.items, &page_lines) catch {};
        try all_lines.appendSlice(arena, page_lines.items);
    }

    meta.has_text_layer = any_text;
    meta.needs_ocr = !any_text;

    // /Info for the frontmatter.
    var info: Dict = .{};
    if (try doc.dictGet(doc.trailer, "Info")) |inf| {
        if (inf.asDict()) |id| info = id;
    }

    const mdx_arena = try emitMdx(arena, all_lines.items, info, &doc, pages.items.len, any_text, opts);
    meta.extraction_method = "zig-native";

    return .{ .mdx = try gpa.dupe(u8, mdx_arena), .meta = meta };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ascii hex decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try asciiHexDecode(a, "48 65 6C 6C 6F>");
    try testing.expectEqualStrings("Hello", out);
}

test "ascii85 decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // "Man " encodes to "9jqo^" in ascii85.
    const out = try ascii85Decode(a, "9jqo^~>");
    try testing.expectEqualStrings("Man ", out);
}

test "inflate round-trips zlib" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const original = "Hello, PDF world! Hello, PDF world! Hello, PDF world!";
    // Compress with std to get a zlib stream.
    var cbuf: [512]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cbuf);
    var window: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&cw, &window, .zlib, .level_6);
    try comp.writer.writeAll(original);
    try comp.finish();
    const compressed = cw.buffered();

    const out = try inflate(a, compressed);
    try testing.expectEqualStrings(original, out);
}

test "document: classic xref + catalog + page tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A minimal hand-authored PDF: catalog → pages → one page, classic xref.
    const pdf =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R /Size 4 >>\n" ++
        "startxref\n0\n%%EOF\n";

    var doc = try Document.parse(a, pdf);
    const cat = try doc.catalog();
    try testing.expectEqualStrings("Catalog", cat.get("Type").?.name);
    const pages = (try doc.dictGet(cat, "Pages")).?;
    try testing.expectEqualStrings("Pages", pages.asDict().?.get("Type").?.name);
    try testing.expectEqual(@as(i64, 1), pages.asDict().?.get("Count").?.integer);
}

test "ToUnicode bfchar + bfrange" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cmap =
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n" ++
        "1 beginbfchar\n<41> <0041>\nendbfchar\n" ++
        "1 beginbfrange\n<42> <44> <0042>\nendbfrange\n" ++
        "endcmap end end";
    var font = Font{};
    try parseToUnicode(a, cmap, &font);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    _ = try font.appendUnicode(a, 0x41, &out); // A
    _ = try font.appendUnicode(a, 0x42, &out); // B
    _ = try font.appendUnicode(a, 0x43, &out); // C
    _ = try font.appendUnicode(a, 0x44, &out); // D
    try testing.expectEqualStrings("ABCD", out.items);
}

test "WinAnsi fallback decodes ASCII + specials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var font = Font{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    _ = try font.appendUnicode(a, 'H', &out);
    _ = try font.appendUnicode(a, 'i', &out);
    _ = try font.appendUnicode(a, 0x97, &out); // em dash —
    try testing.expectEqualStrings("Hi\xe2\x80\x94", out.items);
}

test "end-to-end: extract text from a minimal PDF" {
    const a = testing.allocator;

    // Catalog → Pages → Page with a content stream that shows two lines via a
    // base-14 Helvetica font (WinAnsiEncoding, no /ToUnicode).
    const pdf =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " ++
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n" ++
        "4 0 obj\n<< /Length 86 >>\nstream\n" ++
        "BT /F1 24 Tf 72 700 Td (Hello World) Tj ET\n" ++
        "BT /F1 12 Tf 72 670 Td (This is body text.) Tj ET\n" ++
        "endstream\nendobj\n" ++
        "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R /Size 6 >>\nstartxref\n0\n%%EOF\n";

    const result = try extractToMdx(a, pdf, .{ .source_name = "test.pdf" });
    defer a.free(result.mdx);

    try testing.expect(result.meta.has_text_layer);
    try testing.expectEqual(@as(usize, 1), result.meta.pages);
    try testing.expect(std.mem.indexOf(u8, result.mdx, "Hello World") != null);
    try testing.expect(std.mem.indexOf(u8, result.mdx, "This is body text.") != null);
    // 24pt vs 12pt body → "Hello World" should be a heading.
    try testing.expect(std.mem.indexOf(u8, result.mdx, "# Hello World") != null);
    // Frontmatter present.
    try testing.expect(std.mem.startsWith(u8, result.mdx, "---\n"));
    try testing.expect(std.mem.indexOf(u8, result.mdx, "extraction_method: zig-native") != null);
}

test "xref stream (PDF 1.5) resolves objects via /Type /XRef" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Build a PDF whose only cross-reference is an *unfiltered* xref stream
    // (W=[1 2 2]), tracking real byte offsets so the test exercises
    // parseXrefStream + the type-1/type-2 record dispatch (not the brute-scan).
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, "%PDF-1.5\n");

    const off1 = buf.items.len;
    try buf.appendSlice(a, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    const off2 = buf.items.len;
    try buf.appendSlice(a, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
    const off3 = buf.items.len;
    try buf.appendSlice(a, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n");

    const off4 = buf.items.len;
    // Records for objects 0..4, each = 1 type byte + 2 field2 + 2 field3.
    const Rec = struct { t: u8, f2: u32, f3: u32 };
    const recs = [_]Rec{
        .{ .t = 0, .f2 = 0, .f3 = 0xFFFF }, // 0: free head
        .{ .t = 1, .f2 = @intCast(off1), .f3 = 0 },
        .{ .t = 1, .f2 = @intCast(off2), .f3 = 0 },
        .{ .t = 1, .f2 = @intCast(off3), .f3 = 0 },
        .{ .t = 1, .f2 = @intCast(off4), .f3 = 0 }, // 4: the xref stream itself
    };
    var stream_bytes: std.ArrayListUnmanaged(u8) = .empty;
    for (recs) |r| {
        try stream_bytes.append(a, r.t);
        try stream_bytes.append(a, @truncate(r.f2 >> 8));
        try stream_bytes.append(a, @truncate(r.f2));
        try stream_bytes.append(a, @truncate(r.f3 >> 8));
        try stream_bytes.append(a, @truncate(r.f3));
    }

    var hdr: std.ArrayListUnmanaged(u8) = .empty;
    try hdr.print(a, "4 0 obj\n<< /Type /XRef /Size 5 /W [1 2 2] /Root 1 0 R /Length {d} >>\nstream\n", .{stream_bytes.items.len});
    try buf.appendSlice(a, hdr.items);
    try buf.appendSlice(a, stream_bytes.items);
    try buf.appendSlice(a, "\nendstream\nendobj\n");

    try buf.print(a, "startxref\n{d}\n%%EOF\n", .{off4});

    var doc = try Document.parse(a, buf.items);
    // The xref-stream parser must have placed obj 1 at exactly off1.
    const loc = doc.xref.get(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(off1, loc.offset);
    const cat = try doc.catalog();
    try testing.expectEqualStrings("Catalog", cat.get("Type").?.name);
}

test "scanned PDF (no text) → needs_ocr, no garbage" {
    const a = testing.allocator;
    const pdf =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R /Size 4 >>\nstartxref\n0\n%%EOF\n";
    const result = try extractToMdx(a, pdf, .{});
    defer a.free(result.mdx);
    try testing.expect(!result.meta.has_text_layer);
    try testing.expect(result.meta.needs_ocr);
    try testing.expect(std.mem.indexOf(u8, result.mdx, "needs_ocr: true") != null);
}

test "png predictor up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 2 columns, 1 color, 8 bpc → row_len 2, stride 3.
    // Row0: filter 0 (None): bytes [10, 20]
    // Row1: filter 2 (Up):   deltas [1, 2] → reconstruct [11, 22]
    const data = [_]u8{ 0, 10, 20, 2, 1, 2 };
    const out = try applyPredictor(a, &data, .{ .predictor = 12, .columns = 2 });
    try testing.expectEqualSlices(u8, &.{ 10, 20, 11, 22 }, out);
}

test "lex integers, reals, names, strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src = "42 -3.14 /Type (hello\\n) <48656C6C6F>";
    var lex = Lexer.init(src, 0, a);

    const t1 = try lex.next();
    try testing.expectEqual(TokenKind.integer, t1.kind);
    try testing.expectEqual(@as(i64, 42), t1.int_val);

    const t2 = try lex.next();
    try testing.expectEqual(TokenKind.real, t2.kind);
    try testing.expectApproxEqAbs(@as(f64, -3.14), t2.real_val, 1e-9);

    const t3 = try lex.next();
    try testing.expectEqual(TokenKind.name, t3.kind);
    try testing.expectEqualStrings("Type", t3.text);

    const t4 = try lex.next();
    try testing.expectEqual(TokenKind.string, t4.kind);
    try testing.expectEqualStrings("hello\n", t4.text);

    const t5 = try lex.next();
    try testing.expectEqual(TokenKind.string, t5.kind);
    try testing.expectEqualStrings("Hello", t5.text);
}

test "name with hex escape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lex = Lexer.init("/A#20B", 0, a);
    const t = try lex.next();
    try testing.expectEqual(TokenKind.name, t.kind);
    try testing.expectEqualStrings("A B", t.text);
}

test "parse dict and array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "<< /Type /Page /Count 3 /Kids [1 0 R 2 0 R] >>";
    var p = Parser.init(src, 0, src, a);
    const obj = try p.parseObject();
    const d = obj.asDict() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Page", (d.get("Type").?).name);
    try testing.expectEqual(@as(i64, 3), d.get("Count").?.integer);
    const kids = d.get("Kids").?.array;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(@as(u32, 1), kids[0].ref.num);
    try testing.expectEqual(@as(u32, 2), kids[1].ref.num);
}

test "parse stream with direct length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "<< /Length 5 >>\nstream\nABCDE\nendstream";
    var p = Parser.init(src, 0, src, a);
    const obj = try p.parseObject();
    try testing.expect(obj == .stream);
    try testing.expectEqualStrings("ABCDE", obj.stream.raw);
}

test "indirect object wrapper unwrapped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "12 0 obj << /A 1 >> endobj";
    var p = Parser.init(src, 0, src, a);
    const obj = try p.parseObject();
    const d = obj.asDict() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), d.get("A").?.integer);
}
