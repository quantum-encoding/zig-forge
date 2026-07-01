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
// Encryption — standard security handler, empty user password
// =============================================================================

const Md5 = std.crypto.hash.Md5;
const pdf_crypt = @import("pdf_crypt.zig");

/// The 32-byte password-padding string (ISO 32000-1 Algorithm 2).
const pad_string = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

const CryptMethod = enum { rc4, aesv2, aesv3, identity };

/// Decrypts the strings and streams of an encrypted PDF with the empty user
/// password. Supports the common standard-security-handler variants: RC4
/// (/V 1,2 and /V 4 with /V2), AES-128 (/V 4 with /AESV2), and AES-256
/// (/V 5 /R 6, key derived via the audited `pdf_crypt`).
const Decryptor = struct {
    file_key: [32]u8 = undefined,
    key_len: usize = 5, // bytes
    method: CryptMethod = .rc4,

    /// Algorithm 1: per-object key = MD5(file_key ++ obj# ++ gen [++ "sAlT"]),
    /// truncated to min(key_len+5, 16). Not used for AES-256 (/V 5).
    fn objectKey(self: *const Decryptor, num: u32, gen: u16, out: *[16]u8) usize {
        var h = Md5.init(.{});
        h.update(self.file_key[0..self.key_len]);
        h.update(&[_]u8{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16) });
        h.update(&[_]u8{ @truncate(gen), @truncate(gen >> 8) });
        if (self.method == .aesv2) h.update("sAlT");
        var digest: [16]u8 = undefined;
        h.final(&digest);
        const klen = @min(self.key_len + 5, @as(usize, 16));
        @memcpy(out[0..klen], digest[0..klen]);
        return klen;
    }

    fn decryptData(self: *const Decryptor, arena: std.mem.Allocator, num: u32, gen: u16, data: []const u8) ExtractError![]u8 {
        switch (self.method) {
            .identity => return arena.dupe(u8, data),
            .aesv3 => return aesCbcDecrypt(arena, self.file_key[0..32], data),
            .rc4 => {
                var key: [16]u8 = undefined;
                const klen = self.objectKey(num, gen, &key);
                const out = try arena.alloc(u8, data.len);
                rc4(key[0..klen], data, out);
                return out;
            },
            .aesv2 => {
                var key: [16]u8 = undefined;
                const klen = self.objectKey(num, gen, &key);
                return aesCbcDecrypt(arena, key[0..klen], data);
            },
        }
    }
};

fn rc4(key: []const u8, data: []const u8, out: []u8) void {
    if (key.len == 0) {
        @memcpy(out, data);
        return;
    }
    var s: [256]u8 = undefined;
    for (0..256) |i| s[i] = @truncate(i);
    var j: u8 = 0;
    for (0..256) |i| {
        j +%= s[i] +% key[i % key.len];
        std.mem.swap(u8, &s[i], &s[j]);
    }
    var a: u8 = 0;
    j = 0;
    for (0..data.len) |k| {
        a +%= 1;
        j +%= s[a];
        std.mem.swap(u8, &s[a], &s[j]);
        out[k] = data[k] ^ s[s[a] +% s[j]];
    }
}

/// AES-CBC decrypt where `data` = IV(16) ‖ ciphertext, PKCS#7-padded. Key length
/// selects AES-128 vs AES-256.
fn aesCbcDecrypt(arena: std.mem.Allocator, key: []const u8, data: []const u8) ExtractError![]u8 {
    if (data.len < 32 or (data.len - 16) % 16 != 0) return arena.dupe(u8, "");
    var iv: [16]u8 = undefined;
    @memcpy(&iv, data[0..16]);
    const ct = data[16..];
    const out = try arena.alloc(u8, ct.len);

    if (key.len >= 32) {
        var k: [32]u8 = undefined;
        @memcpy(&k, key[0..32]);
        cbcDecrypt(std.crypto.core.aes.Aes256.initDec(k), iv, ct, out);
    } else {
        var k: [16]u8 = [_]u8{0} ** 16;
        @memcpy(k[0..@min(key.len, 16)], key[0..@min(key.len, 16)]);
        cbcDecrypt(std.crypto.core.aes.Aes128.initDec(k), iv, ct, out);
    }

    // Strip PKCS#7 padding.
    if (out.len == 0) return out;
    const pad = out[out.len - 1];
    if (pad >= 1 and pad <= 16 and pad <= out.len) return out[0 .. out.len - pad];
    return out;
}

fn cbcDecrypt(ctx: anytype, iv_in: [16]u8, ct: []const u8, out: []u8) void {
    var prev = iv_in;
    var i: usize = 0;
    while (i + 16 <= ct.len) : (i += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, ct[i .. i + 16]);
        var dec: [16]u8 = undefined;
        ctx.decrypt(&dec, &block);
        for (0..16) |b| out[i + b] = dec[b] ^ prev[b];
        prev = block;
    }
}

/// Algorithm 2: derive the RC4/AES-128 file key for the empty user password.
fn computeFileKeyRC4(dec: *Decryptor, o_str: []const u8, p: i64, id0: []const u8, r: i64, enc_meta: bool) void {
    var h = Md5.init(.{});
    h.update(&pad_string); // empty password → padding only

    var o32: [32]u8 = [_]u8{0} ** 32;
    @memcpy(o32[0..@min(o_str.len, 32)], o_str[0..@min(o_str.len, 32)]);
    h.update(&o32);

    const p32: u32 = @bitCast(@as(i32, @truncate(p)));
    h.update(&[_]u8{ @truncate(p32), @truncate(p32 >> 8), @truncate(p32 >> 16), @truncate(p32 >> 24) });
    h.update(id0);
    if (r >= 4 and !enc_meta) h.update(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });

    var digest: [16]u8 = undefined;
    h.final(&digest);

    if (r >= 3) {
        var it: usize = 0;
        while (it < 50) : (it += 1) {
            var hh = Md5.init(.{});
            hh.update(digest[0..dec.key_len]);
            hh.final(&digest);
        }
    }
    @memcpy(dec.file_key[0..dec.key_len], digest[0..dec.key_len]);
}

/// Decrypt every string and stream inside `obj` in place (arena memory is
/// mutable), keyed by the owning indirect object's number/generation. Strings
/// nested in arrays/dicts are handled recursively.
fn decryptObjInPlace(doc: *Document, obj: Obj, num: u32, gen: u16, depth: usize) Obj {
    if (depth > 64) return obj;
    const dec = &(doc.decryptor orelse return obj);
    switch (obj) {
        .string => |s| {
            const out = dec.decryptData(doc.arena, num, gen, s) catch return obj;
            return Obj{ .string = out };
        },
        .array => |arr| {
            for (arr) |*it| it.* = decryptObjInPlace(doc, it.*, num, gen, depth + 1);
            return obj;
        },
        .dict => |d| {
            for (d.entries) |*e| e.val = decryptObjInPlace(doc, e.val, num, gen, depth + 1);
            return obj;
        },
        .stream => |st| {
            st.raw = dec.decryptData(doc.arena, num, gen, st.raw) catch st.raw;
            for (st.dict.entries) |*e| e.val = decryptObjInPlace(doc, e.val, num, gen, depth + 1);
            return obj;
        },
        else => return obj,
    }
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
    /// Set when the PDF is encrypted and the empty user password unlocked it.
    decryptor: ?Decryptor = null,
    /// The /Encrypt dictionary's own object number — never decrypted.
    encrypt_obj_num: ?u32 = null,

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

        // Encryption: try to unlock with the empty user password. On success a
        // decryptor is installed and `encrypted` stays true (callers can still
        // see the document was encrypted). On failure (real password required)
        // the decryptor stays null and extraction surfaces a clean signal.
        if (doc.trailer.get("Encrypt") != null) {
            doc.encrypted = true;
            doc.setupDecryption() catch {};
        }
        return doc;
    }

    /// Parse /Encrypt and derive the file key for the empty user password.
    fn setupDecryption(self: *Document) ExtractError!void {
        const enc_ref = self.trailer.get("Encrypt") orelse return;
        if (enc_ref == .ref) self.encrypt_obj_num = enc_ref.ref.num;
        const enc = (try self.resolve(enc_ref)).asDict() orelse return;

        const v = if (enc.get("V")) |o| (o.asInt() orelse 0) else 0;
        const r = if (enc.get("R")) |o| (o.asInt() orelse 0) else 0;
        const length_bits = if (enc.get("Length")) |o| (o.asInt() orelse 40) else 40;

        // /ID[0] — the first file identifier (not encrypted).
        var id0: []const u8 = "";
        if (self.trailer.get("ID")) |idobj| {
            if (idobj == .array and idobj.array.len >= 1 and idobj.array[0] == .string) {
                id0 = idobj.array[0].string;
            }
        }

        var dec = Decryptor{};

        if (v >= 5 or r >= 5) {
            // AES-256 (/V 5 /R 6): derive the file key via the audited pdf_crypt.
            const u_str = if (enc.get("U")) |o| (if (o == .string) o.string else "") else "";
            const ue_str = if (enc.get("UE")) |o| (if (o == .string) o.string else "") else "";
            if (u_str.len < 48 or ue_str.len < 32) return;
            var u_buf: [48]u8 = undefined;
            var ue_buf: [32]u8 = undefined;
            @memcpy(&u_buf, u_str[0..48]);
            @memcpy(&ue_buf, ue_str[0..32]);
            const fk = pdf_crypt.recoverFileKeyUser(self.arena, "", u_buf, ue_buf) catch return;
            const key = fk orelse return; // empty password rejected → leave locked
            @memcpy(dec.file_key[0..32], &key);
            dec.key_len = 32;
            dec.method = .aesv3;
            self.decryptor = dec;
            return;
        }

        // RC4 / AES-128 (/R 2,3,4).
        dec.key_len = if (r == 2) 5 else @intCast(@max(5, @divTrunc(length_bits, 8)));
        dec.method = .rc4;
        if (v == 4) {
            // Crypt-filter method: /CF /StdCF /CFM = /V2 (RC4) or /AESV2.
            if (try self.dictGet(enc, "CF")) |cf_obj| {
                if (cf_obj.asDict()) |cf| {
                    if (try self.dictGet(cf, "StdCF")) |std_cf| {
                        if (std_cf.asDict()) |scf| {
                            const cfm = if (scf.get("CFM")) |m| (if (m == .name) m.name else "") else "";
                            if (std.mem.eql(u8, cfm, "AESV2")) {
                                dec.method = .aesv2;
                                dec.key_len = 16;
                            } else if (std.mem.eql(u8, cfm, "V2")) {
                                dec.method = .rc4;
                            }
                        }
                    }
                }
            }
            // If streams use the Identity filter, nothing is encrypted.
            if (enc.get("StmF")) |sf| {
                if (sf == .name and std.mem.eql(u8, sf.name, "Identity")) dec.method = .identity;
            }
        }

        const o_str = if (enc.get("O")) |o| (if (o == .string) o.string else "") else "";
        const p_val: i64 = if (enc.get("P")) |o| (o.asInt() orelse 0) else 0;
        const enc_meta: bool = if (enc.get("EncryptMetadata")) |o| (o != .boolean or o.boolean) else true;

        computeFileKeyRC4(&dec, o_str, p_val, id0, r, enc_meta);
        self.decryptor = dec;
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
        if (self.cache.get(num)) |o| return o;
        const loc = self.xref.get(num) orelse return Obj{ .null = {} };
        // Pre-seed cache with null to break ref cycles.
        try self.cache.put(self.arena, num, .{ .null = {} });
        var obj = switch (loc) {
            .offset => |o| blk: {
                if (o >= self.file.len) break :blk Obj{ .null = {} };
                var parser = Parser.init(self.file, o, self.file, self.arena);
                break :blk parser.parseObject() catch Obj{ .null = {} };
            },
            .in_objstm => |c| try self.objectFromObjStm(c.stream_num, c.index, num),
        };
        // Decrypt directly-stored objects (objects inside an ObjStm are already
        // plaintext once the ObjStm stream itself was decrypted). The /Encrypt
        // dictionary is never decrypted.
        if (self.decryptor != null and loc == .offset and (self.encrypt_obj_num == null or num != self.encrypt_obj_num.?)) {
            obj = decryptObjInPlace(self, obj, num, gen, 0);
        }
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
        // The ObjStm stream itself is encrypted as a normal stream; decrypt its
        // raw bytes before decoding. The objects inside are NOT re-encrypted.
        if (self.decryptor) |*dec| {
            st.raw = dec.decryptData(self.arena, stream_num, 0, st.raw) catch st.raw;
        }
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
            } else if (std.mem.eql(u8, fname, "LZWDecode") or std.mem.eql(u8, fname, "LZW")) {
                // /EarlyChange defaults to 1 (PDF/TIFF default) when absent.
                const early_change: i64 = if (pd) |d|
                    (if (d.get("EarlyChange")) |e| (e.asInt() orelse 1) else 1)
                else
                    1;
                data = try lzwDecode(self.arena, data, early_change);
                data = try self.maybePredict(data, pd);
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
    /// One `<lo> <hi>` entry of an embedded CMap's codespace. `nbytes` is the
    /// byte length of the hex strings (1–4), which selects how many bytes a code
    /// of this range consumes during string splitting.
    pub const CodespaceRange = struct { low: u32, high: u32, nbytes: u8 };

    /// Result of consuming one variable-width code from a content-stream string.
    pub const NextCode = struct { code: u32, len: u8 };

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
    /// Embedded-CMap codespace ranges (empty → Identity / fixed-step behavior).
    codespace: []const CodespaceRange = &.{},
    /// Embedded-CMap code → CID map (empty → CID == code, i.e. Identity).
    cid_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    /// Decode one code's Unicode into `out`; returns whether a mapping existed.
    /// `code` is the original character code (key into /ToUnicode); `cid` is the
    /// resolved CID (code itself under Identity, else via the embedded CMap).
    fn appendUnicode(self: *Font, arena: std.mem.Allocator, code: u32, cid: u32, out: *std.ArrayListUnmanaged(u8)) ExtractError!bool {
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
        } else if (self.cid_map.count() > 0) {
            // Bounded, honest CID→Unicode fallback for Type0 fonts that carry an
            // embedded non-identity CMap but NO /ToUnicode. Only surface a CID
            // that lands in printable ASCII / Latin-1 — common in Identity-style
            // embedded subsets where CID≈Unicode. Never fabricate beyond that:
            // glyph-index CIDs outside this window stay unmapped (no text layer).
            if ((cid >= 0x20 and cid <= 0x7E) or (cid >= 0xA0 and cid <= 0xFF)) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cid), &buf) catch return false;
                try out.appendSlice(arena, buf[0..n]);
                return true;
            }
        }
        return false;
    }

    fn widthOf(self: *Font, cid: u32) f64 {
        return self.widths.get(cid) orelse self.default_width;
    }

    /// Consume the next code starting at `bytes[i]` (caller guarantees i < len).
    /// With no embedded codespace this reproduces the legacy fixed-step split
    /// (`bytes_per_code` bytes per code). With a codespace it matches the code
    /// against the per-byte range windows, preferring the longest matching
    /// range, and falls back to `bytes_per_code` (capped to the remaining
    /// bytes) then a single byte when nothing matches.
    fn nextCode(self: *Font, bytes: []const u8, i: usize) NextCode {
        const remaining = bytes.len - i;
        if (self.codespace.len == 0) {
            const step: u8 = if (self.bytes_per_code == 0) 1 else self.bytes_per_code;
            var code: u32 = bytes[i];
            if (step == 2 and i + 1 < bytes.len) code = (@as(u32, bytes[i]) << 8) | bytes[i + 1];
            return .{ .code = code, .len = step };
        }
        var best_len: u8 = 0;
        var best_code: u32 = 0;
        for (self.codespace) |r| {
            const L = r.nbytes;
            if (L == 0 or L > 4 or L > remaining) continue;
            var ok = true;
            var k: u8 = 0;
            while (k < L) : (k += 1) {
                const shift: u5 = @intCast(8 * (L - 1 - k));
                const lo_b: u8 = @truncate(r.low >> shift);
                const hi_b: u8 = @truncate(r.high >> shift);
                const b = bytes[i + k];
                if (b < lo_b or b > hi_b) {
                    ok = false;
                    break;
                }
            }
            if (ok and L > best_len) {
                best_len = L;
                best_code = @truncate(readBE(bytes[i .. i + L]));
            }
        }
        if (best_len > 0) return .{ .code = best_code, .len = best_len };
        var step: u8 = if (self.bytes_per_code == 0) 1 else self.bytes_per_code;
        if (step > remaining) step = 1;
        return .{ .code = @truncate(readBE(bytes[i .. i + step])), .len = step };
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
        // Type0: load CID widths from the descendant CIDFont's /W + /DW. Without
        // these, single-glyph-per-Tj layouts (common in hardware manuals) lose
        // every inter-word space because the default advance overshoots and the
        // gap-based space detector never fires.
        font.default_width = 1000;

        // /Encoding selects the code→CID mapping. A name (Identity-H/-V or a
        // predefined Adobe CMap) keeps the Identity fast path (CID == code, the
        // empty-codespace branch). An embedded stream is decoded and parsed into
        // explicit codespace + cid_map, which also enables variable-width code
        // splitting and the CID→Unicode fallback.
        if (try doc.dictGet(font_dict, "Encoding")) |enc| {
            switch (enc) {
                // Predefined CMap names: Identity-H/-V need no table (CID = code).
                // Other names (e.g. UniGB-UCS2-H) are external Adobe resource
                // files we do not ship; fall back to Identity rather than guess.
                .name => {},
                .stream => |st| {
                    const data = doc.decodeStreamRaw(st) catch &[_]u8{};
                    parseEncodingCMap(doc.arena, data, &font) catch {};
                },
                else => {},
            }
        }

        try loadType0Widths(doc, font_dict, &font);
        if (font.to_unicode.count() > 0 or font.cid_map.count() > 0) font.any_mapped = true;
    }

    return font;
}

/// Load CID glyph widths from a Type0 font's descendant CIDFont (/W ranges and
/// /DW default). CID is taken equal to the byte code (Identity encoding).
fn loadType0Widths(doc: *Document, font_dict: Dict, font: *Font) ExtractError!void {
    const desc_obj = try doc.dictGet(font_dict, "DescendantFonts") orelse return;
    // /DescendantFonts is a one-element array (or, rarely, a direct dict).
    const cid_dict: Dict = switch (desc_obj) {
        .array => |arr| blk: {
            if (arr.len == 0) return;
            break :blk (try doc.resolve(arr[0])).asDict() orelse return;
        },
        .dict => |d| d,
        .stream => |s| s.dict,
        else => return,
    };

    if (try doc.dictGet(cid_dict, "DW")) |dw| {
        if (dw.asNumber()) |v| font.default_width = v;
    }

    const w_obj = try doc.dictGet(cid_dict, "W") orelse return;
    if (w_obj != .array) return;
    const w = w_obj.array;

    var i: usize = 0;
    while (i < w.len) {
        const first = (try doc.resolve(w[i])).asInt() orelse break;
        if (i + 1 >= w.len) break;
        const second = try doc.resolve(w[i + 1]);
        if (second == .array) {
            // Form 1: `c [w_c w_{c+1} …]`
            for (second.array, 0..) |wo, k| {
                const wv = (try doc.resolve(wo)).asNumber() orelse continue;
                const cid: u32 = std.math.cast(u32, first + @as(i64, @intCast(k))) orelse continue;
                try font.widths.put(doc.arena, cid, wv);
            }
            i += 2;
        } else {
            // Form 2: `c_first c_last w`
            if (i + 2 >= w.len) break;
            const last = second.asInt() orelse break;
            const wv = (try doc.resolve(w[i + 2])).asNumber() orelse 0;
            var cid = first;
            var guard: usize = 0;
            while (cid <= last and guard < 70000) : (cid += 1) {
                const c: u32 = std.math.cast(u32, cid) orelse break;
                try font.widths.put(doc.arena, c, wv);
                guard += 1;
            }
            i += 3;
        }
    }
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

/// Parse an embedded /Encoding CMap stream (Type0/CID fonts). Fills the font's
/// `codespace` (from begincodespacerange) and `cid_map` (from begincidrange /
/// begincidchar), and derives `bytes_per_code` from the widest codespace range.
/// Malformed input never panics: every loop is bounded and unexpected tokens
/// end the current section.
fn parseEncodingCMap(arena: std.mem.Allocator, data: []const u8, font: *Font) ExtractError!void {
    var lex = Lexer.init(data, 0, arena);
    var ranges: std.ArrayListUnmanaged(Font.CodespaceRange) = .empty;
    while (true) {
        const t = lex.next() catch break;
        if (t.kind == .eof) break;
        if (t.kind != .keyword) continue;
        if (std.mem.eql(u8, t.text, "begincodespacerange")) {
            try parseCodespaceRange(arena, &lex, &ranges);
        } else if (std.mem.eql(u8, t.text, "begincidrange")) {
            try parseCidRange(arena, &lex, font);
        } else if (std.mem.eql(u8, t.text, "begincidchar")) {
            try parseCidChar(arena, &lex, font);
        }
    }
    font.codespace = ranges.items;
    var maxn: u8 = 0;
    for (ranges.items) |r| {
        if (r.nbytes > maxn) maxn = r.nbytes;
    }
    if (maxn > 0) font.bytes_per_code = maxn;
}

fn parseCodespaceRange(arena: std.mem.Allocator, lex: *Lexer, ranges: *std.ArrayListUnmanaged(Font.CodespaceRange)) ExtractError!void {
    var guard: usize = 0;
    while (guard < 65536) : (guard += 1) {
        const lo = lex.next() catch break;
        if (lo.kind == .keyword and std.mem.eql(u8, lo.text, "endcodespacerange")) break;
        if (lo.kind != .string) break;
        const hi = lex.next() catch break;
        if (hi.kind != .string) break;
        if (ranges.items.len >= 65536) continue; // cap stored ranges, keep draining
        const n = lo.text.len;
        if (n == 0 or n > 4) continue; // u32 holds at most 4 bytes
        try ranges.append(arena, .{
            .low = @truncate(readBE(lo.text)),
            .high = @truncate(readBE(hi.text)),
            .nbytes = @intCast(n),
        });
    }
}

fn parseCidRange(arena: std.mem.Allocator, lex: *Lexer, font: *Font) ExtractError!void {
    var guard: usize = 0;
    while (guard < 65536) : (guard += 1) {
        const lo = lex.next() catch break;
        if (lo.kind == .keyword and std.mem.eql(u8, lo.text, "endcidrange")) break;
        if (lo.kind != .string) break;
        const hi = lex.next() catch break;
        if (hi.kind != .string) break;
        const cidt = lex.next() catch break;
        if (cidt.kind != .integer) break; // destination CID is a base integer
        const lov: u32 = @truncate(readBE(lo.text));
        const hiv: u32 = @truncate(readBE(hi.text));
        if (hiv < lov or hiv - lov > 65536) continue; // bound per-range expansion
        if (font.cid_map.count() >= 1 << 20) continue; // global map cap
        const base = cidt.int_val;
        var code = lov;
        while (true) {
            const cid = std.math.cast(u32, base + @as(i64, @intCast(code - lov)));
            if (cid) |c| try font.cid_map.put(arena, code, c);
            if (code == hiv) break;
            code += 1;
        }
    }
}

fn parseCidChar(arena: std.mem.Allocator, lex: *Lexer, font: *Font) ExtractError!void {
    var guard: usize = 0;
    while (guard < 1 << 20) : (guard += 1) {
        const codet = lex.next() catch break;
        if (codet.kind == .keyword and std.mem.eql(u8, codet.text, "endcidchar")) break;
        if (codet.kind != .string) break;
        const cidt = lex.next() catch break;
        if (cidt.kind != .integer) break;
        const code: u32 = @truncate(readBE(codet.text));
        const cid = std.math.cast(u32, cidt.int_val) orelse continue;
        try font.cid_map.put(arena, code, cid);
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

/// LZWDecode (PDF/TIFF variant): variable-width MSB-first codes → bytes. Width
/// runs 9→12 bits; code 256 = ClearTable (reset dict + width to 9), 257 = EOD.
/// The dictionary seeds 0..255 as single bytes (258 is the first free code).
/// `early_change` (the /EarlyChange parm, default 1) bumps the width one code
/// early — width grows when next_code hits 2^width-1 rather than 2^width —
/// matching the PDF/TIFF default encoder. Bounded at 4096 dict entries (the dict
/// freezes on overflow until a ClearTable arrives) and 256 MiB output; malformed
/// or truncated input returns what was decoded rather than panicking.
fn lzwDecode(arena: std.mem.Allocator, data: []const u8, early_change: i64) ExtractError![]u8 {
    const max_output: usize = 256 * 1024 * 1024;
    const ec: usize = if (early_change == 0) 0 else 1;

    var out: std.ArrayListUnmanaged(u8) = .empty;

    // Single-byte slices for codes 0..255, kept stable for the dict to point at.
    const lits = try arena.alloc(u8, 256);
    for (lits, 0..) |*b, i| b.* = @intCast(i);
    var dict: [4096][]const u8 = undefined;
    var li: usize = 0;
    while (li < 256) : (li += 1) dict[li] = lits[li .. li + 1];

    var next_code: usize = 258;
    var width: u6 = 9;
    var prev: ?usize = null;

    var bitbuf: u32 = 0;
    var nbits: u6 = 0;
    var bi: usize = 0; // next input byte to consume

    while (true) {
        // Refill the bit buffer until a full code is available (MSB-first).
        while (nbits < width) {
            if (bi >= data.len) return out.items; // out of bits — stop cleanly
            bitbuf = (bitbuf << 8) | data[bi];
            bi += 1;
            nbits += 8;
        }
        nbits -= width;
        const code: usize = (bitbuf >> @as(u5, @intCast(nbits))) &
            ((@as(u32, 1) << @as(u5, @intCast(width))) - 1);

        if (code == 257) break; // EOD
        if (code == 256) { // ClearTable — reset dictionary and width.
            next_code = 258;
            width = 9;
            prev = null;
            continue;
        }

        var entry: []const u8 = undefined;
        if (prev == null) {
            // First data code after start/clear must be a single-byte literal.
            if (code >= 256) return out.items; // malformed — stop gracefully
            entry = dict[code];
        } else if (code < next_code) {
            entry = dict[code];
        } else if (code == next_code) {
            // KWKWK: code names the entry we are about to define.
            const p = dict[prev.?];
            const buf = try arena.alloc(u8, p.len + 1);
            @memcpy(buf[0..p.len], p);
            buf[p.len] = p[0];
            entry = buf;
        } else {
            return out.items; // code out of range — malformed, stop gracefully
        }

        if (out.items.len + entry.len > max_output) return ExtractError.UnsupportedFilter;
        try out.appendSlice(arena, entry);

        if (prev) |pc| {
            // Define dict[next_code] = dict[prev] ++ entry[0]. When the table is
            // full we freeze it (decode keeps going) until a ClearTable resets it.
            if (next_code < 4096) {
                const p = dict[pc];
                const buf = try arena.alloc(u8, p.len + 1);
                @memcpy(buf[0..p.len], p);
                buf[p.len] = entry[0];
                dict[next_code] = buf;
                next_code += 1;
                if (width < 12 and next_code + ec >= (@as(usize, 1) << @intCast(width))) width += 1;
            }
        }
        prev = code;
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

/// Map a point from PDF default user space into the *displayed* (post-/Rotate)
/// space. `w`/`h` are the unrotated MediaBox width/height. Per PDF 32000-1
/// §7.7.3.3 the page's `/Rotate` is a **clockwise** viewing rotation, so we
/// rotate each point the same way the viewer rotates the page. After this
/// transform the displayed page's "up" is +y and "right" is +x, so the normal
/// reading-order sort (y descending, then x ascending) yields visual order.
///
/// Deriving the 90° row: default user space puts the origin at the lower-left,
/// +x right, +y up, with page extent w×h. Rotating the page 90° clockwise for
/// display swaps the axes (the original top edge becomes the right edge), so the
/// displayed extent is h×w. Track the corners:
///   - lower-left  (0,0) → displayed upper-left  (0, w)
///   - lower-right (w,0) → displayed lower-left   (0, 0)
///   - upper-left  (0,h) → displayed upper-right  (h, w)
/// The unique affine map hitting those is (x,y) → (y, w − x). Composing one more
/// 90° clockwise turn gives 180° → (w − x, h − y), and a third gives
/// 270° → (h − y, x).
fn rotatePoint(x: f64, y: f64, rotate: i64, w: f64, h: f64) struct { x: f64, y: f64 } {
    return switch (rotate) {
        90 => .{ .x = y, .y = w - x },
        180 => .{ .x = w - x, .y = h - y },
        270 => .{ .x = h - y, .y = x },
        else => .{ .x = x, .y = y }, // 0 (and any non-quadrant value) → identity
    };
}

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

/// An image's encoded bytes plus the filename the MDX refers to it by.
const ImageBlob = struct {
    name: []const u8,
    bytes: []const u8,
};

const Interp = struct {
    doc: *Document,
    arena: std.mem.Allocator,
    fonts: *std.StringHashMapUnmanaged(*Font),
    geom: PageGeom,
    frags: *std.ArrayListUnmanaged(Frag),
    any_text: *bool,
    /// Page (or Form XObject) resources, for /XObject lookups via the Do op.
    resources: Dict = .{},
    image_count: *usize,
    /// Extracted image blobs (only collected when extract_images is set).
    images: *std.ArrayListUnmanaged(ImageBlob),
    extract_images: bool = false,
    depth: usize = 0, // Form-XObject recursion guard

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
        // XObjects.
        else if (std.mem.eql(u8, op, "Do")) {
            if (args.len >= 1 and args[args.len - 1] == .name) self.doXObject(args[args.len - 1].name) catch {};
        }
    }

    /// The `Do` operator: paint an XObject. Images are counted (and optionally
    /// extracted + marked in reading order); Form XObjects are recursed into so
    /// their text is not lost.
    fn doXObject(self: *Interp, name: []const u8) ExtractError!void {
        if (self.depth > 12) return; // bounded Form recursion
        const xobjs_obj = (try self.doc.dictGet(self.resources, "XObject")) orelse return;
        const xobjs = xobjs_obj.asDict() orelse return;
        const ref = xobjs.get(name) orelse return;
        const obj = try self.doc.resolve(ref);
        if (obj != .stream) return;
        const st = obj.stream;
        const subtype = if (st.dict.get("Subtype")) |s| (if (s == .name) s.name else "") else "";

        if (std.mem.eql(u8, subtype, "Image")) {
            self.image_count.* += 1;
            if (self.extract_images) try self.placeImage(st);
            return;
        }
        if (std.mem.eql(u8, subtype, "Form")) {
            // Recurse: run the form's content with its own resources/matrix.
            const content = self.doc.decodeStreamRaw(st) catch return;
            var form_res = self.resources;
            if (try self.doc.dictGet(st.dict, "Resources")) |r| {
                if (r.asDict()) |rd| form_res = rd;
            }
            var form_ctm = self.ctm;
            if (st.dict.get("Matrix")) |m| {
                if (m == .array and m.array.len >= 6) form_ctm = matFromArgs(m.array[0..6]).mul(self.ctm);
            }
            var form_fonts: std.StringHashMapUnmanaged(*Font) = .empty;
            buildPageFonts(self.doc, form_res, &form_fonts) catch {};

            var child = Interp{
                .doc = self.doc,
                .arena = self.arena,
                .fonts = &form_fonts,
                .geom = self.geom,
                .frags = self.frags,
                .any_text = self.any_text,
                .resources = form_res,
                .image_count = self.image_count,
                .images = self.images,
                .extract_images = self.extract_images,
                .depth = self.depth + 1,
                .ctm = form_ctm,
            };
            child.run(content) catch {};
        }
    }

    /// Record an image draw: count its position (image unit square mapped by the
    /// CTM) and, for directly-extractable encodings (JPEG/JPEG2000), collect its
    /// bytes and emit an inline Markdown image reference in reading order.
    fn placeImage(self: *Interp, st: *Stream) ExtractError!void {
        // Center of the unit image square in device space → reading-order y.
        const cy = 0.5 * self.ctm.b + 0.5 * self.ctm.d + self.ctm.f;
        const cx = 0.5 * self.ctm.a + 0.5 * self.ctm.c + self.ctm.e;

        const ext = imageExt(st.dict);
        var ref: []const u8 = "#";
        if (ext) |e| {
            // Codec bytes (JPEG/JPEG2000) are already a complete image file.
            const name = try std.fmt.allocPrint(self.arena, "img{d}.{s}", .{ self.image_count.*, e });
            const bytes = self.doc.decodeStreamRaw(st) catch &[_]u8{};
            if (bytes.len > 0) {
                try self.images.append(self.arena, .{ .name = name, .bytes = bytes });
                ref = try std.fmt.allocPrint(self.arena, "images/{s}", .{name});
            }
        } else if (self.pngFromImage(st)) |png| {
            // Raw / Flate samples → wrap as PNG. On any shape PNG can't represent
            // (CMYK, Indexed, odd bit depth, missing dims) pngFromImage returns
            // null and the `#` placeholder below is kept.
            const name = try std.fmt.allocPrint(self.arena, "img{d}.png", .{self.image_count.*});
            try self.images.append(self.arena, .{ .name = name, .bytes = png });
            ref = try std.fmt.allocPrint(self.arena, "images/{s}", .{name});
        }
        const marker = try std.fmt.allocPrint(self.arena, "![image]({s})", .{ref});
        try self.frags.append(self.arena, .{
            .x = cx,
            .y = cy,
            .end_x = cx + 1,
            .size = 8, // small → never treated as a heading
            .text = marker,
        });
    }

    /// Try to wrap a raw/Flate image XObject's decoded samples as a PNG. Returns
    /// null (→ `#` placeholder) on any unsupported colour space, bit depth,
    /// component count, missing dimensions, or decode failure. Never panics.
    fn pngFromImage(self: *Interp, st: *Stream) ?[]u8 {
        const w_obj = (self.doc.dictGet(st.dict, "Width") catch return null) orelse return null;
        const h_obj = (self.doc.dictGet(st.dict, "Height") catch return null) orelse return null;
        const width = std.math.cast(u32, w_obj.asInt() orelse return null) orelse return null;
        const height = std.math.cast(u32, h_obj.asInt() orelse return null) orelse return null;

        const bpc_obj = self.doc.dictGet(st.dict, "BitsPerComponent") catch return null;
        const bpc: u32 = if (bpc_obj) |b| (std.math.cast(u32, b.asInt() orelse 8) orelse 8) else 8;

        const cs_obj = (self.doc.dictGet(st.dict, "ColorSpace") catch return null) orelse return null;
        const ncomp = colorSpaceNComp(self.doc, cs_obj) orelse return null;

        const samples = self.doc.decodeStreamRaw(st) catch return null;
        return pngWrap(self.arena, width, height, bpc, ncomp, samples) catch null;
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

        var i: usize = 0;
        while (i < bytes.len) {
            // Variable-width split: nextCode honors an embedded codespace and
            // otherwise reproduces the legacy fixed `bytes_per_code` step.
            const nc: Font.NextCode = if (font) |fp| fp.nextCode(bytes, i) else .{ .code = bytes[i], .len = 1 };
            const code = nc.code;
            const len: usize = if (nc.len == 0) 1 else nc.len;

            var w0: f64 = 0.5;
            if (font) |fp| {
                // Resolve CID through the embedded CMap (identity when empty),
                // then key widths and the CID→Unicode fallback off the CID.
                const cid = fp.cid_map.get(code) orelse code;
                _ = fp.appendUnicode(self.arena, code, cid, &text) catch {};
                w0 = fp.widthOf(cid) / 1000.0;
            } else {
                // No font resource — best-effort WinAnsi for ASCII.
                const cp = winAnsiCodepoint(@truncate(code));
                if (cp != 0 and cp != 0xFFFD) {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &b) catch 0;
                    if (n > 0) try text.appendSlice(self.arena, b[0..n]);
                }
            }

            const is_space = (len == 1 and code == 32);
            const word = if (is_space) self.ts.word_spacing else 0;
            const tx = (w0 * self.ts.tf_size + self.ts.char_spacing + word) * self.ts.h_scale;
            self.ts.tm = Matrix.translation(tx, 0).mul(self.ts.tm);

            i += len;
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

/// Returns the file extension for an image stream whose encoding can be written
/// out directly (the codec's bytes are a complete image file), or null. A null
/// return is not "give up": raw/Flate sample streams are PNG-wrapped by
/// `Interp.pngFromImage`, which has the document handle needed to decode them.
fn imageExt(dict: Dict) ?[]const u8 {
    const f = dict.get("Filter") orelse return null;
    const last: []const u8 = switch (f) {
        .name => |n| n,
        .array => |arr| blk: {
            if (arr.len == 0) break :blk "";
            const lastobj = arr[arr.len - 1];
            break :blk if (lastobj == .name) lastobj.name else "";
        },
        else => "",
    };
    if (std.mem.eql(u8, last, "DCTDecode")) return "jpg";
    if (std.mem.eql(u8, last, "JPXDecode")) return "jp2";
    return null;
}

/// Component count for a PDF device colour-space name, or null if it isn't one
/// of the simple device families.
fn deviceNComp(n: []const u8) ?u32 {
    if (std.mem.eql(u8, n, "DeviceGray") or std.mem.eql(u8, n, "CalGray") or std.mem.eql(u8, n, "G")) return 1;
    if (std.mem.eql(u8, n, "DeviceRGB") or std.mem.eql(u8, n, "CalRGB") or std.mem.eql(u8, n, "RGB")) return 3;
    if (std.mem.eql(u8, n, "DeviceCMYK") or std.mem.eql(u8, n, "CMYK")) return 4;
    return null;
}

/// Resolve an image /ColorSpace object to its component count. Handles name
/// spaces (Device*/Cal*) and `[/ICCBased <stream>]` (via the stream's /N).
/// Indexed/Separation/DeviceN/Lab/Pattern are not v1-supported → null. CMYK
/// resolves to 4 so `pngWrap` is the single point that rejects it.
fn colorSpaceNComp(doc: *Document, cs: Obj) ?u32 {
    const r = doc.resolve(cs) catch return null;
    switch (r) {
        .name => |n| return deviceNComp(n),
        .array => |arr| {
            if (arr.len == 0) return null;
            const head = doc.resolve(arr[0]) catch return null;
            if (head != .name) return null;
            const fam = head.name;
            if (std.mem.eql(u8, fam, "ICCBased")) {
                if (arr.len < 2) return null;
                const stm = doc.resolve(arr[1]) catch return null;
                if (stm != .stream) return null;
                const nobj = (doc.dictGet(stm.stream.dict, "N") catch return null) orelse return null;
                const n = nobj.asInt() orelse return null;
                if (n == 1 or n == 3 or n == 4) return @intCast(n);
                return null;
            }
            return deviceNComp(fam);
        },
        else => return null,
    }
}

/// Wrap raw image samples in a minimal, valid PNG byte stream: 8-byte signature,
/// IHDR, a single zlib-compressed IDAT (filter-None scanlines), and IEND, each
/// chunk framed with a big-endian length and a CRC-32 over type+data.
///
/// Supported: 1-component grayscale (color type 0) and 3-component truecolor
/// (color type 2). 4-component (CMYK) cannot be represented in PNG → error, so
/// the caller emits the `#` placeholder rather than a corrupt file. Bit depths
/// are restricted to PNG's set (1/2/4/8/16; truecolor only 8/16). Short sample
/// buffers are zero-padded; over-long ones are truncated — never out-of-bounds.
fn pngWrap(
    arena: std.mem.Allocator,
    width: u32,
    height: u32,
    bits_per_component: u32,
    ncomp: u32,
    samples: []const u8,
) ExtractError![]u8 {
    const color_type: u8 = switch (ncomp) {
        1 => 0, // grayscale
        3 => 2, // truecolor
        else => return ExtractError.UnsupportedFilter, // CMYK / unsupported
    };
    const bit_depth: u8 = switch (bits_per_component) {
        1, 2, 4, 8, 16 => @intCast(bits_per_component),
        else => return ExtractError.UnsupportedFilter,
    };
    // PNG truecolor only permits 8- or 16-bit channels.
    if (color_type == 2 and bit_depth != 8 and bit_depth != 16) return ExtractError.UnsupportedFilter;
    if (width == 0 or height == 0) return ExtractError.MalformedObject;
    // Bound dimensions so the row/raster arithmetic can't overflow.
    if (width > (1 << 24) or height > (1 << 24)) return ExtractError.MalformedObject;

    // Bytes per scanline, rounded up to a byte boundary.
    const bits_per_row: u64 = @as(u64, width) * ncomp * bit_depth;
    const row_bytes: usize = @intCast((bits_per_row + 7) / 8);

    // Filtered raster: each row is a 0x00 filter byte (None) + row_bytes samples.
    const raster = try arena.alloc(u8, (row_bytes + 1) * height);
    @memset(raster, 0);
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const dst = raster[row * (row_bytes + 1) ..];
        dst[0] = 0; // filter type: None
        const src_off = row * row_bytes;
        if (src_off < samples.len) {
            const avail = @min(row_bytes, samples.len - src_off);
            @memcpy(dst[1 .. 1 + avail], samples[src_off .. src_off + avail]);
        }
    }

    // zlib-compress the raster for IDAT. Deflate output can't exceed the input
    // by more than the zlib header + stored-block framing; the slack below is a
    // safe ceiling. A too-small buffer would only fail the compress (→ caller
    // placeholder), never corrupt — but size it so real images don't trip it.
    const out_buf = try arena.alloc(u8, raster.len + raster.len / 512 + 512);
    var cw: std.Io.Writer = .fixed(out_buf);
    var window: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&cw, &window, .zlib, .level_6) catch return ExtractError.OutOfMemory;
    comp.writer.writeAll(raster) catch return ExtractError.UnsupportedFilter;
    comp.finish() catch return ExtractError.UnsupportedFilter;
    const idat = cw.buffered();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = bit_depth;
    ihdr[9] = color_type;
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter method: adaptive
    ihdr[12] = 0; // interlace: none
    try pngChunk(arena, &out, "IHDR", &ihdr);
    try pngChunk(arena, &out, "IDAT", idat);
    try pngChunk(arena, &out, "IEND", &[_]u8{});
    return out.items;
}

/// Append one PNG chunk: 4-byte big-endian length, 4-byte type, data, then a
/// 4-byte big-endian CRC-32 over (type ++ data).
fn pngChunk(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    typ: []const u8,
    data: []const u8,
) ExtractError!void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try out.appendSlice(arena, &len_be);
    try out.appendSlice(arena, typ);
    try out.appendSlice(arena, data);

    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try out.appendSlice(arena, &crc_be);
}

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

/// A hyperlink from a page /Annots /Link annotation, with its clickable
/// rectangle in default user space (≈ device space when the page CTM is
/// identity, which is the common case).
const LinkAnnot = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    uri: []const u8,
};

const Page = struct {
    resources: Dict,
    geom: PageGeom,
    content: []u8,
    links: []const LinkAnnot = &.{},
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
        const links = collectLinks(doc, node) catch &.{};
        try out.append(doc.arena, .{
            .resources = inh.resources orelse Dict{},
            .geom = .{ .media_w = inh.media_w, .media_h = inh.media_h, .rotate = inh.rotate },
            .content = content,
            .links = links,
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

/// Collect URI link annotations from a page's /Annots array.
fn collectLinks(doc: *Document, page: Dict) ExtractError![]LinkAnnot {
    const annots_obj = try doc.dictGet(page, "Annots") orelse return &.{};
    if (annots_obj != .array) return &.{};
    var out: std.ArrayListUnmanaged(LinkAnnot) = .empty;
    for (annots_obj.array) |a| {
        const annot = (try doc.resolve(a)).asDict() orelse continue;
        const sub = if (annot.get("Subtype")) |s| (if (s == .name) s.name else "") else "";
        if (!std.mem.eql(u8, sub, "Link")) continue;
        // /A action dict with /S /URI and a /URI string.
        const action = (try doc.dictGet(annot, "A")) orelse continue;
        const adict = action.asDict() orelse continue;
        const uri_obj = (try doc.dictGet(adict, "URI")) orelse continue;
        if (uri_obj != .string) continue;
        const rect_obj = (try doc.dictGet(annot, "Rect")) orelse continue;
        if (rect_obj != .array or rect_obj.array.len < 4) continue;
        const a0 = rect_obj.array[0].asNumber() orelse continue;
        const b0 = rect_obj.array[1].asNumber() orelse continue;
        const a1 = rect_obj.array[2].asNumber() orelse continue;
        const b1 = rect_obj.array[3].asNumber() orelse continue;
        try out.append(doc.arena, .{
            .x0 = @min(a0, a1),
            .y0 = @min(b0, b1),
            .x1 = @max(a0, a1),
            .y1 = @max(b0, b1),
            .uri = uri_obj.string,
        });
    }
    return out.items;
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

/// A horizontal segment of a line, separated from its neighbours by a gap wide
/// enough to look like a column break. Used for table-column alignment.
const Cell = struct {
    x: f64, // left edge of the cell
    end_x: f64,
    text: []const u8,
};

/// One assembled line of text plus the geometry needed for block inference.
const Line = struct {
    text: []const u8,
    y: f64,
    x: f64, // left edge
    size: f64, // representative (max) font size on the line
    cells: []Cell = &.{}, // text split at wide horizontal gaps (table columns)
    /// The line's fragments, left-to-right. Tables bin these into a *global*
    /// column model (see tryDetectTable/emitTable) so a row's columns don't
    /// depend on that row's own local gaps — the fix for invoice line-items
    /// where a tight price/value gap used to merge "7.03 63.27" into one cell.
    frags: []const Frag = &.{},
    /// Forces a paragraph break before this line regardless of vertical gap —
    /// set on the first line of each column and each page so reading order never
    /// runs the bottom of one column into the top of the next.
    break_before: bool = false,
};

/// Wrap `text` as a Markdown link when its cell box overlaps a /Link
/// annotation's rectangle; otherwise return it unchanged.
fn wrapLink(arena: std.mem.Allocator, links: []const LinkAnnot, x0: f64, x1: f64, y: f64, text: []const u8) ExtractError![]const u8 {
    if (text.len == 0 or links.len == 0) return text;
    for (links) |lk| {
        if (y < lk.y0 - 2.0 or y > lk.y1 + 2.0) continue;
        const cx = (x0 + x1) / 2.0;
        var hit = (cx >= lk.x0 and cx <= lk.x1);
        if (!hit) {
            const ov = @min(x1, lk.x1) - @max(x0, lk.x0);
            const w = x1 - x0;
            if (ov > 0 and w > 0 and ov / w > 0.5) hit = true;
        }
        if (hit) return std.fmt.allocPrint(arena, "[{s}]({s})", .{ text, sanitizeUri(arena, lk.uri) catch lk.uri }) catch text;
    }
    return text;
}

/// Percent-encode the few characters that would break a Markdown link target.
fn sanitizeUri(arena: std.mem.Allocator, uri: []const u8) ExtractError![]const u8 {
    const u = std.mem.trim(u8, uri, " \t\r\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (u) |c| {
        switch (c) {
            ' ' => try out.appendSlice(arena, "%20"),
            '(' => try out.appendSlice(arena, "%28"),
            ')' => try out.appendSlice(arena, "%29"),
            else => try out.append(arena, c),
        }
    }
    return out.items;
}

/// Assemble positioned fragments into reading-ordered lines. The sort comparator
/// defines a TOTAL order (CLAUDE.md §7 — an invalid comparator is exactly what
/// panicked the competitor). Cells overlapping a /Link annotation are wrapped as
/// Markdown links.
fn assembleLines(arena: std.mem.Allocator, frags: []Frag, links: []const LinkAnnot, out: *std.ArrayListUnmanaged(Line)) ExtractError!void {
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

        // Merge touching glyph runs. Subset fonts often emit a single word as
        // several runs ("WEDNESBUR" + "Y", "Inv" + "oice"); if a table gutter
        // later falls in that seam the word is split across two cells. Runs whose
        // gap is under ~a tenth of an em are the same word — join them directly.
        // The threshold is far below an inter-word/column gap, so distinct tokens
        // (and adjacent numeric columns) are never merged.
        line_frags.items = mergeGlyphRuns(arena, line_frags.items) catch line_frags.items;

        // Build the line as a sequence of cells. A small gap (> ~⅙ em) inserts a
        // space *within* a cell — within a word glyphs are contiguous, so any
        // clearly-positive gap is an inter-word space. A wide gap (> ~1.4 em)
        // starts a new cell, which is the signal a table column detector keys on.
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        var text: std.ArrayListUnmanaged(u8) = .empty; // whole-line text (cells + spaces)
        var cell_text: std.ArrayListUnmanaged(u8) = .empty;
        var cell_x: f64 = line_frags.items[0].x;
        var cell_end: f64 = line_frags.items[0].x;
        var prev_end: ?f64 = null;
        const left_x = line_frags.items[0].x;
        for (line_frags.items) |fr| {
            if (prev_end) |pe| {
                const gap = fr.x - pe;
                if (gap > fr.size * 1.4) {
                    // Column break → flush the current cell.
                    if (cell_text.items.len > 0) {
                        const ct = try wrapLink(arena, links, cell_x, cell_end, line_y, try trimTrailing(arena, cell_text.items));
                        try cells.append(arena, .{ .x = cell_x, .end_x = cell_end, .text = ct });
                        if (text.items.len > 0) try text.append(arena, ' ');
                        try text.appendSlice(arena, ct);
                    }
                    cell_text = .empty;
                    cell_x = fr.x;
                } else if (gap > fr.size * 0.17 and !endsWithSpace(cell_text.items) and cell_text.items.len > 0) {
                    try cell_text.append(arena, ' ');
                }
            }
            try cell_text.appendSlice(arena, fr.text);
            cell_end = fr.end_x;
            prev_end = fr.end_x;
        }
        if (cell_text.items.len > 0) {
            const ct = try wrapLink(arena, links, cell_x, cell_end, line_y, try trimTrailing(arena, cell_text.items));
            try cells.append(arena, .{ .x = cell_x, .end_x = cell_end, .text = ct });
            if (text.items.len > 0) try text.append(arena, ' ');
            try text.appendSlice(arena, ct);
        }

        try out.append(arena, .{
            .text = try trimTrailing(arena, text.items),
            .y = line_y,
            .x = left_x,
            .size = max_size,
            .cells = cells.items,
            .frags = line_frags.items, // already sorted left-to-right
        });
        i = j;
    }
}

/// Assemble one page's fragments into reading-ordered lines, detecting columns
/// first (spec §4.6). A multi-column page is split into bands at vertical
/// gutters, and each band is emitted top-to-bottom *in full* before the next —
/// this is what prevents the line-level interleaving of two-column papers.
/// Single-column pages collapse to one band (identical to `assembleLines`).
fn assemblePage(arena: std.mem.Allocator, frags: []Frag, links: []const LinkAnnot, out: *std.ArrayListUnmanaged(Line)) ExtractError!void {
    if (frags.len == 0) return;

    const cuts = try detectColumnCuts(arena, frags);
    const first_idx = out.items.len;

    if (cuts.len == 0) {
        try assembleLines(arena, frags, links, out);
    } else {
        // Build band boundaries: [left, cut0, cut1, …, right].
        var bounds: std.ArrayListUnmanaged(f64) = .empty;
        try bounds.append(arena, -std.math.inf(f64));
        for (cuts) |c| try bounds.append(arena, c);
        try bounds.append(arena, std.math.inf(f64));

        var b: usize = 0;
        while (b + 1 < bounds.items.len) : (b += 1) {
            const lo = bounds.items[b];
            const hi = bounds.items[b + 1];
            var band: std.ArrayListUnmanaged(Frag) = .empty;
            for (frags) |fr| {
                const mid = (fr.x + fr.end_x) / 2.0;
                if (mid >= lo and mid < hi) try band.append(arena, fr);
            }
            const band_start = out.items.len;
            try assembleLines(arena, band.items, links, out);
            // Mark the first line of each column (after the first) as a break.
            if (b > 0 and out.items.len > band_start) out.items[band_start].break_before = true;
        }
    }

    // The first line of the whole page always forces a paragraph break so pages
    // never run together.
    if (out.items.len > first_idx) out.items[first_idx].break_before = true;
}

/// Detect vertical column gutters and return the x-positions to cut at (empty →
/// single column). A gutter is a vertical strip that essentially no fragment
/// *straddles*; ragged line-ends don't create false gutters because a gutter
/// must be straddle-free over the strip, and a handful of full-width headers
/// (below the straddle threshold) don't block it.
fn detectColumnCuts(arena: std.mem.Allocator, frags: []const Frag) ExtractError![]f64 {
    if (frags.len < 8) return &.{};

    var left: f64 = std.math.inf(f64);
    var right: f64 = -std.math.inf(f64);
    for (frags) |fr| {
        if (fr.x < left) left = fr.x;
        if (fr.end_x > right) right = fr.end_x;
    }
    const width = right - left;
    if (!(width > 0) or !std.math.isFinite(width)) return &.{};

    const nbins: usize = 256;
    const bin_w = width / @as(f64, @floatFromInt(nbins));
    // Straddle coverage via a difference array: a fragment [x,end_x] straddles
    // every bin strictly interior to its span.
    var diff = try arena.alloc(i32, nbins + 1);
    @memset(diff, 0);
    for (frags) |fr| {
        var a = binOf(fr.x, left, bin_w, nbins) + 1;
        const e = binOf(fr.end_x, left, bin_w, nbins);
        if (a > e) a = e;
        if (a <= e and e <= nbins) {
            diff[a] += 1;
            diff[e] -= 1;
        }
    }
    var cov = try arena.alloc(i32, nbins);
    var running: i32 = 0;
    for (0..nbins) |k| {
        running += diff[k];
        cov[k] = running;
    }

    const straddle_thresh: i32 = @max(1, @as(i32, @intCast(frags.len / 50)));
    const min_gutter_bins: usize = @max(@as(usize, 3), nbins / 50); // ≥~2% of width

    // To tell a real reading-column gutter from intra-table whitespace, look at
    // what sits to the RIGHT of a candidate gap on the rows that cross it. In a
    // 2-column paper the right side is a full-width prose line (dense ink); in an
    // invoice it is a short value/price (sparse ink spread over the region). Group
    // fragments into baseline-y rows once, then per candidate gap measure the
    // right-side ink density of the crossing rows. Dropping this test made
    // detectColumnCuts tear invoice header labels from their values and lose the
    // rightmost money column.
    const yidx = try arena.alloc(usize, frags.len);
    for (yidx, 0..) |*v, i| v.* = i;
    std.sort.block(usize, yidx, frags, struct {
        fn less(f: []const Frag, a: usize, b: usize) bool {
            return f[a].y > f[b].y; // top-to-bottom
        }
    }.less);
    var starts: std.ArrayListUnmanaged(usize) = .empty; // row group boundaries in yidx
    {
        var i: usize = 0;
        while (i < yidx.len) {
            try starts.append(arena, i);
            const y0 = frags[yidx[i]].y;
            const rtol = @max(frags[yidx[i]].size * 0.5, 1.0);
            while (i < yidx.len and @abs(frags[yidx[i]].y - y0) <= rtol) i += 1;
        }
        try starts.append(arena, yidx.len); // end sentinel
    }
    const page_right = right;

    var cuts: std.ArrayListUnmanaged(f64) = .empty;
    var k: usize = 0;
    while (k < nbins) {
        if (cov[k] <= straddle_thresh) {
            const run_start = k;
            while (k < nbins and cov[k] <= straddle_thresh) k += 1;
            const run_end = k; // exclusive
            const run_len = run_end - run_start;
            // Ignore gutters touching the page edges (page margins, not columns).
            const at_edge = (run_start == 0) or (run_end == nbins);
            if (run_len >= min_gutter_bins and !at_edge) {
                const left_edge = left + @as(f64, @floatFromInt(run_start)) * bin_w;
                const right_edge = left + @as(f64, @floatFromInt(run_end)) * bin_w;
                // Require substantial text on BOTH sides of this gutter…
                if (hasTextOutside(cov, 0, run_start, straddle_thresh) and
                    hasTextOutside(cov, run_end, nbins, straddle_thresh))
                {
                    // …AND that crossing rows have a *dense* right side (prose),
                    // not a sparse one (table values). Count crossing rows whose
                    // right-of-gap ink fills < half the right region; if most do,
                    // the gap is a column separator, not a reading gutter.
                    const right_w = page_right - right_edge;
                    var crossing: usize = 0;
                    var sparse_right: usize = 0;
                    var ri: usize = 0;
                    while (ri + 1 < starts.items.len) : (ri += 1) {
                        var left_present = false;
                        var right_ink: f64 = 0;
                        var has_right = false;
                        for (yidx[starts.items[ri]..starts.items[ri + 1]]) |fi| {
                            const fr = frags[fi];
                            if (fr.end_x <= left_edge + 1.0) left_present = true;
                            if (fr.x >= right_edge - 1.0) {
                                has_right = true;
                                right_ink += fr.end_x - fr.x;
                            }
                        }
                        if (left_present and has_right) {
                            crossing += 1;
                            if (right_w > 0 and right_ink < 0.5 * right_w) sparse_right += 1;
                        }
                    }
                    // ≥40% of crossing rows sparse ⇒ a table column separator, not a
                    // reading gutter. Real 2-column prose sits well under this (≤~27%
                    // measured); invoice header/line-item gaps run 58–79%.
                    const tabular = crossing > 0 and (sparse_right * 100 / crossing >= 40);
                    if (!tabular) {
                        const cut_x = left + (@as(f64, @floatFromInt(run_start + run_len / 2)) * bin_w);
                        try cuts.append(arena, cut_x);
                    }
                }
            }
        } else k += 1;
    }
    return cuts.items;
}

fn binOf(x: f64, left: f64, bin_w: f64, nbins: usize) usize {
    if (bin_w <= 0) return 0;
    const idx = (x - left) / bin_w;
    if (idx < 0) return 0;
    const i: usize = @intFromFloat(idx);
    return @min(i, nbins);
}

/// True if some bin in [from,to) carries more than the straddle threshold of
/// coverage — i.e. there is real text on that side of a candidate gutter.
fn hasTextOutside(cov: []const i32, from: usize, to: usize, thresh: i32) bool {
    var k = from;
    while (k < to) : (k += 1) {
        if (cov[k] > thresh) return true;
    }
    return false;
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

/// Combine consecutive left-to-right fragments belonging to the same word — a
/// subset-font run seam where the gap is under ~a tenth of an em (far below an
/// inter-word or column gap, so distinct tokens and adjacent numeric columns are
/// never merged). Text is concatenated directly; the box spans both. Input must
/// be sorted left-to-right; returns the input unchanged when nothing merges.
fn mergeGlyphRuns(arena: std.mem.Allocator, frags: []Frag) ExtractError![]Frag {
    if (frags.len < 2) return frags;
    var out: std.ArrayListUnmanaged(Frag) = .empty;
    try out.append(arena, frags[0]);
    for (frags[1..]) |fr| {
        const last = &out.items[out.items.len - 1];
        const gap = fr.x - last.end_x;
        const thresh = @max(last.size, fr.size) * 0.1;
        if (gap < thresh and gap > -thresh) {
            const joined = arena.alloc(u8, last.text.len + fr.text.len) catch return frags;
            @memcpy(joined[0..last.text.len], last.text);
            @memcpy(joined[last.text.len..], fr.text);
            last.text = joined;
            if (fr.end_x > last.end_x) last.end_x = fr.end_x;
            if (fr.size > last.size) last.size = fr.size;
        } else {
            try out.append(arena, fr);
        }
    }
    return out.items;
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

/// An extracted image to be written to the `images/` sidecar directory.
pub const ExtractedImage = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const ExtractResult = struct {
    mdx: []u8,
    meta: ExtractionMeta,
    /// Populated only when ExtractOptions.extract_images is set. Owned by the
    /// caller (allocated with the same gpa as `mdx`); free each name+bytes plus
    /// the slice, or use freeResult.
    images: []ExtractedImage = &.{},

    /// Free everything in the result allocated with `gpa`.
    pub fn deinit(self: *ExtractResult, gpa: std.mem.Allocator) void {
        gpa.free(self.mdx);
        for (self.images) |img| {
            gpa.free(img.name);
            gpa.free(img.bytes);
        }
        gpa.free(self.images);
    }
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
    // Labelled data is not a heading, even in a big/bold font. A colon followed by
    // a number ("Invoice No.: 108988", "GOODS : 103.40") or a currency amount
    // ("Total £6,960.00") is a field/total — promoting it to a heading erased the
    // label/value distinction on invoices. A trailing colon with no value after it
    // (a real titled heading like "Pilar 1 – Abrazo Pélvico (AP):") is left alone.
    if (hasDigitAfterColon(text) or hasCurrencyAmount(text) or endsWithDecimal(text)) return null;
    const r = size / body;
    if (r >= 1.8) return 1;
    if (r >= 1.5) return 2;
    if (r >= 1.28) return 3;
    if (r >= 1.14) return 4;
    return null;
}

/// True if the line ends with a decimal number ("Net Total 104.45") — a labelled
/// total, not a heading. A heading ending in a bare integer ("Capítulo 1") or a
/// word is unaffected.
fn endsWithDecimal(s: []const u8) bool {
    var i = s.len;
    while (i > 0 and s[i - 1] == ' ') i -= 1;
    if (i == 0 or !(s[i - 1] >= '0' and s[i - 1] <= '9')) return false;
    var has_dot = false;
    var n: usize = 0;
    while (i > 0 and n < 20) : (i -= 1) {
        const c = s[i - 1];
        if (c >= '0' and c <= '9') {
            n += 1;
        } else if (c == '.') {
            has_dot = true;
        } else if (c == ',') {} else break;
    }
    return has_dot;
}

/// True if a ':' is followed later in the line by a digit — the "label: value"
/// shape of an invoice field or labelled total (not a titled heading).
fn hasDigitAfterColon(s: []const u8) bool {
    var seen_colon = false;
    for (s) |c| {
        if (c == ':') seen_colon = true else if (seen_colon and c >= '0' and c <= '9') return true;
    }
    return false;
}

/// True if the line carries a currency amount (a £/€/$ sign adjacent to a digit,
/// allowing a space): "£161.78", "$ 5.00". Such lines are totals/values, not headings.
fn hasCurrencyAmount(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        // £ = 0xC2 0xA3, € = 0xE2 0x82 0xAC in UTF-8; $ = 0x24.
        const is_sign = s[i] == '$' or
            (i + 1 < s.len and s[i] == 0xC2 and s[i + 1] == 0xA3) or
            (i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x82 and s[i + 2] == 0xAC);
        if (is_sign) {
            var j = i + 1;
            while (j < s.len and (s[j] == ' ' or s[j] == 0xC2 or s[j] == 0xA3 or s[j] == 0xE2 or s[j] == 0x82 or s[j] == 0xAC)) j += 1;
            if (j < s.len and s[j] >= '0' and s[j] <= '9') return true;
        }
    }
    return false;
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
    meta_tables: *usize,
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
    var list_base_x: ?f64 = null; // left edge of the current list (for nesting)
    var tables_found: usize = 0;

    var i: usize = 0;
    while (i < lines.len) {
        const ln = lines[i];
        if (ln.text.len == 0) {
            i += 1;
            continue;
        }

        // --- table region? (lookahead) ---
        if (opts.detect_tables) {
            if (tryDetectTable(arena, lines, i, body_size)) |tbl| {
                try flushPara(arena, w, &para);
                list_base_x = null;
                try emitTable(arena, w, lines[i..tbl.end], tbl.cuts);
                tables_found += 1;
                prev_y = lines[tbl.end - 1].y;
                prev_size = lines[tbl.end - 1].size;
                i = tbl.end;
                continue;
            }
        }

        const level = if (opts.detect_headings) headingLevel(ln.size, body_size, ln.text) else null;
        const marker = if (level == null) listMarker(ln.text) else null;

        // A large vertical gap ends the current paragraph; so does an explicit
        // column/page break (where the next line's y jumps back up).
        var gap_break = ln.break_before;
        if (prev_y) |py| {
            const gap = py - ln.y;
            if (gap > prev_size * 1.8) gap_break = true;
        }

        if (level != null or marker != null or gap_break) {
            try flushPara(arena, w, &para);
        }
        if (marker == null) list_base_x = null;

        if (level) |lv| {
            var h: usize = 0;
            while (h < lv) : (h += 1) w.writeAll("#") catch {};
            w.print(" {s}\n\n", .{ln.text}) catch {};
        } else if (marker) |m| {
            // List item. Indent level from x relative to the list's first item.
            if (list_base_x == null) list_base_x = ln.x;
            const indent = indentLevel(ln.x, list_base_x.?, ln.size);
            var s: usize = 0;
            while (s < indent) : (s += 1) w.writeAll("  ") catch {};
            if (m.ordered) {
                w.print("1. {s}\n", .{m.rest}) catch {};
            } else {
                w.print("- {s}\n", .{m.rest}) catch {};
            }
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
        i += 1;
    }
    try flushPara(arena, w, &para);

    meta_tables.* = tables_found;
    return aw.toOwnedSlice();
}

/// A detected list marker and the text following it.
const ListMarker = struct {
    ordered: bool,
    rest: []const u8,
};

/// Recognize a leading bullet glyph or an ordered marker (`12.` / `3)` followed
/// by a space). Returns the text after the marker, or null for non-list lines.
fn listMarker(text: []const u8) ?ListMarker {
    const bullets = [_][]const u8{
        "\xe2\x80\xa2", // •
        "\xe2\x80\xa3", // ‣
        "\xe2\x97\xa6", // ◦
        "\xe2\x96\xaa", // ▪
        "\xe2\x96\xab", // ▫
        "\xc2\xb7", // ·
        "\xe2\x88\x99", // ∙
    };
    for (bullets) |b| {
        if (std.mem.startsWith(u8, text, b)) {
            const rest = std.mem.trimStart(u8, text[b.len..], " \t");
            if (rest.len > 0) return .{ .ordered = false, .rest = rest };
        }
    }
    // ASCII bullet: "- ", "* ", "– " at the very start.
    if ((std.mem.startsWith(u8, text, "- ") or std.mem.startsWith(u8, text, "* "))) {
        const rest = std.mem.trimStart(u8, text[2..], " \t");
        if (rest.len > 0) return .{ .ordered = false, .rest = rest };
    }
    // Ordered: one or more digits then '.' or ')' then a space.
    var d: usize = 0;
    while (d < text.len and text[d] >= '0' and text[d] <= '9') d += 1;
    if (d > 0 and d <= 3 and d + 1 < text.len and (text[d] == '.' or text[d] == ')') and text[d + 1] == ' ') {
        const rest = std.mem.trimStart(u8, text[d + 1 ..], " \t");
        if (rest.len > 0) return .{ .ordered = true, .rest = rest };
    }
    return null;
}

fn indentLevel(x: f64, base: f64, size: f64) usize {
    if (x <= base + size) return 0;
    const lv: usize = @intFromFloat((x - base) / (size * 1.8));
    return @min(lv, 3);
}

const TableRegion = struct {
    end: usize, // exclusive line index
    cuts: []f64, // sorted x-positions of the column-separator gutters (cols = cuts+1)
};

/// Detect a table starting at `lines[start]`: a run of ≥2 consecutive,
/// regularly-spaced rows each with ≥2 cells whose x-positions align into ≥2
/// columns. Guard rail (spec §5): if alignment is weak, returns null so the rows
/// fall through to plain text — never a fabricated junk table.
fn tryDetectTable(arena: std.mem.Allocator, lines: []const Line, start: usize, body_size: f64) ?TableRegion {
    // The first line must itself look tabular, else this isn't a table start.
    if (lines[start].cells.len < 2 or lines[start].text.len == 0) return null;

    var end = start;
    var last_tab = start; // exclusive index of the last genuinely tabular row
    var prev_y: ?f64 = null;
    var skip: usize = 0;
    const max_skip: usize = 5; // bridge up to this many non-tabular lines in a row
    while (end < lines.len) {
        const ln = lines[end];
        if (end > start and ln.break_before) break; // hard: column/page break
        if (headingLevel(ln.size, body_size, ln.text) != null) break; // hard: heading
        if (prev_y) |py| {
            const gap = py - ln.y;
            if (gap < -1.0) break; // moved back up → new region
            if (gap > ln.size * 10.0) break; // large section gap → end of table
        }
        const tabular = ln.cells.len >= 2 and ln.text.len > 0;
        if (tabular) {
            skip = 0;
            end += 1;
            last_tab = end;
        } else {
            // Bridge a few non-tabular lines (a lone barcode / repeated code line
            // between items) so one line-item table doesn't shatter into per-item
            // fragments — each fragment would have too few rows to model columns.
            skip += 1;
            if (skip > max_skip) break;
            end += 1;
        }
        prev_y = ln.y;
        if (end - start > 1000) break;
    }
    end = last_tab; // don't let the table end on bridged filler
    const nrows = end - start;
    if (nrows < 2) return null;

    const cuts = detectTableColumns(arena, lines[start..end], body_size) catch return null;
    if (cuts.len < 1) return null; // need ≥2 columns (1 separator)
    return .{ .end = end, .cuts = cuts };
}

/// Find column separators as vertical whitespace gutters: x-bands that are empty
/// across (nearly) all rows. This is the pdftotext -layout principle and it is
/// robust where left-edge clustering is not — text flows continuously inside a
/// column so descriptions never split, while real columns are divided by
/// consistent empty bands. Returns the sorted gutter mid-x positions (the cuts);
/// column count is cuts.len + 1.
fn detectTableColumns(arena: std.mem.Allocator, rows: []const Line, body: f64) ExtractError![]f64 {
    var minx: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var nrows: usize = 0;
    for (rows) |ln| {
        if (ln.frags.len == 0) continue;
        nrows += 1;
        for (ln.frags) |fr| {
            if (fr.x < minx) minx = fr.x;
            if (fr.end_x > maxx) maxx = fr.end_x;
        }
    }
    if (nrows < 2 or maxx <= minx) return &.{};

    const nbins: usize = 512;
    const span = maxx - minx;
    const binw = span / @as(f64, @floatFromInt(nbins));
    if (binw <= 0) return &.{};

    // Per-bin distinct-row coverage: how many rows place any text over this x-band.
    const cov = try arena.alloc(u32, nbins);
    @memset(cov, 0);
    const rowbins = try arena.alloc(bool, nbins);
    for (rows) |ln| {
        if (ln.frags.len == 0) continue;
        @memset(rowbins, false);
        for (ln.frags) |fr| {
            var b0 = binOf(fr.x, minx, binw, nbins - 1);
            const b1 = binOf(fr.end_x, minx, binw, nbins - 1);
            while (b0 <= b1) : (b0 += 1) rowbins[b0] = true;
        }
        for (rowbins, 0..) |hit, bi| if (hit) {
            cov[bi] += 1;
        };
    }

    // A gutter bin is nearly empty (tolerate a few rows whose long text strays in).
    const gut_max: u32 = @intCast(@max(@as(usize, 1), nrows / 8));
    // A separator must be clearly wider than an inter-word space (~0.25 em) so a
    // description's normal spacing never splits it; sparse coincidental gutters are
    // pruned below by column population, not by width.
    const min_gutter: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@max(body * 0.7, 1.0) / binw)));

    var cuts: std.ArrayListUnmanaged(f64) = .empty;
    var bi: usize = 0;
    // Skip a leading gutter (left margin) — separators only count between text.
    while (bi < nbins and cov[bi] <= gut_max) bi += 1;
    while (bi < nbins) {
        if (cov[bi] <= gut_max) {
            const g0 = bi;
            while (bi < nbins and cov[bi] <= gut_max) bi += 1;
            const g1 = bi; // exclusive
            // A trailing gutter (nothing to its right) is the right margin, not a cut.
            if (g1 >= nbins) break;
            if (g1 - g0 >= min_gutter) {
                const mid = minx + (@as(f64, @floatFromInt(g0 + g1)) / 2.0) * binw;
                try cuts.append(arena, mid);
            }
        } else bi += 1;
    }
    if (cuts.items.len > 64) return &.{}; // implausible; treat as not-a-table
    if (cuts.items.len == 0) return &.{};

    // Prune spurious columns: count how many rows populate each column, then drop
    // any cut that would isolate a column present in too few rows — a coincidental
    // gutter behind a rarely-used spec (e.g. "TABLE X" on 2 of 15 rows) or an
    // always-empty band. Sparse columns merge into a dense neighbour; the columns
    // populated on most rows (code, qty, price, value) survive. Turns a noisy
    // 8-column split into a clean, uniform schema.
    const ncol0 = cuts.items.len + 1;
    const pop = try arena.alloc(usize, ncol0);
    @memset(pop, 0);
    const seen = try arena.alloc(bool, ncol0);
    for (rows) |ln| {
        if (ln.frags.len == 0) continue;
        @memset(seen, false);
        for (ln.frags) |fr| seen[columnOf(cuts.items, (fr.x + fr.end_x) / 2.0)] = true;
        for (seen, 0..) |s, ci| if (s) {
            pop[ci] += 1;
        };
    }
    const min_col_cov: usize = @max(@as(usize, 2), nrows / 5);
    var kept: std.ArrayListUnmanaged(f64) = .empty;
    var left_dense = pop[0] >= min_col_cov;
    for (cuts.items, 0..) |cx, i| {
        const right_dense = pop[i + 1] >= min_col_cov;
        if (right_dense and left_dense) {
            try kept.append(arena, cx); // both sides real → keep the separator
        } else {
            left_dense = left_dense or right_dense; // merge sparse column into the run
        }
    }
    return kept.items;
}

fn lessThanF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// Emit a GFM table with a *fixed* column count (cuts.len + 1) for every row.
/// Each fragment is placed in the column bounded by the gutter cuts on either
/// side of its center. Because columns come from whitespace gutters, a long
/// description stays whole and a merged price+value cell splits into its two
/// columns — giving consistent, machine-parseable rows.
fn emitTable(arena: std.mem.Allocator, w: *std.Io.Writer, rows: []const Line, cuts: []const f64) ExtractError!void {
    if (rows.len == 0) return;
    const ncol = cuts.len + 1;
    w.writeAll("\n") catch {};

    for (rows, 0..) |row, ri| {
        var buckets = try arena.alloc(std.ArrayListUnmanaged(u8), ncol);
        for (buckets) |*b| b.* = .empty;
        var bucket_end = try arena.alloc(f64, ncol); // last frag end_x per column, for intra-cell spacing
        for (bucket_end) |*e| e.* = -std.math.inf(f64);

        if (row.frags.len > 0) {
            for (row.frags) |fr| {
                const col = columnOf(cuts, (fr.x + fr.end_x) / 2.0);
                const b = &buckets[col];
                // Space between fragments sharing a column, mirroring line assembly.
                if (b.items.len > 0 and fr.x - bucket_end[col] > fr.size * 0.17 and !endsWithSpace(b.items)) {
                    try b.append(arena, ' ');
                }
                for (fr.text) |ch| {
                    if (ch == '|') try b.appendSlice(arena, "\\|") else try b.append(arena, ch);
                }
                bucket_end[col] = fr.end_x;
            }
        } else {
            // Fallback (lines without retained fragments): assign whole cells.
            for (row.cells) |c| {
                const col = columnOf(cuts, (c.x + c.end_x) / 2.0);
                if (buckets[col].items.len > 0) try buckets[col].append(arena, ' ');
                for (c.text) |ch| {
                    if (ch == '|') try buckets[col].appendSlice(arena, "\\|") else try buckets[col].append(arena, ch);
                }
            }
        }

        w.writeAll("|") catch {};
        for (buckets) |b| {
            w.print(" {s} |", .{std.mem.trimEnd(u8, b.items, " ")}) catch {};
        }
        w.writeAll("\n") catch {};

        // Header separator after the first row.
        if (ri == 0) {
            w.writeAll("|") catch {};
            for (0..ncol) |_| w.writeAll(" --- |") catch {};
            w.writeAll("\n") catch {};
        }
    }
    w.writeAll("\n") catch {};
}

/// The column index for center-x `cx` given sorted separator positions: the
/// number of cuts to the left of `cx`. Column 0 is left of the first cut.
fn columnOf(cuts: []const f64, cx: f64) usize {
    var col: usize = 0;
    for (cuts) |c| {
        if (cx > c) col += 1 else break;
    }
    return col;
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

    // Encrypted PDF that the empty user password could not unlock (a real
    // password is required) → honest stub, never a crash. If a decryptor was
    // installed, extraction proceeds normally below.
    if (doc.encrypted and doc.decryptor == null) {
        const note = "---\nextraction_method: zig-native\nhas_text_layer: false\nneeds_ocr: false\nencrypted: true\n---\n\n> This PDF is encrypted and requires a password to open.\n";
        return .{ .mdx = try gpa.dupe(u8, note), .meta = meta };
    }

    var pages: std.ArrayListUnmanaged(Page) = .empty;
    try collectPages(&doc, &pages);
    meta.pages = pages.items.len;

    var all_lines: std.ArrayListUnmanaged(Line) = .empty;
    var any_text = false;
    var image_count: usize = 0;
    var images: std.ArrayListUnmanaged(ImageBlob) = .empty;

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
            .resources = page.resources,
            .image_count = &image_count,
            .images = &images,
            .extract_images = opts.extract_images,
        };
        interp.run(page.content) catch {};

        // Apply the page's /Rotate so reading order + column detection run in the
        // *displayed* coordinate frame. The content interpreter produced frags
        // (and links arrived) in default user space, where "up" is +y and
        // "right" is +x. For /Rotate 90/180/270 the viewer rotates the page, so
        // we rotate every fragment and link rectangle into display space first;
        // for 90/270 this also swaps the effective page width/height, which the
        // extent-derived column detector then picks up automatically. No-op for
        // the overwhelmingly common /Rotate 0 case.
        var links_for_page = page.links;
        if (page.geom.rotate != 0) {
            const rot = page.geom.rotate;
            const w = page.geom.media_w;
            const h = page.geom.media_h;
            for (frags.items) |*fr| {
                // Rotate both endpoints; rotation can flip which is larger, so
                // re-derive x-min/x-max to keep end_x >= x. Use the start
                // point's rotated y as the fragment baseline.
                const p0 = rotatePoint(fr.x, fr.y, rot, w, h);
                const p1 = rotatePoint(fr.end_x, fr.y, rot, w, h);
                fr.x = @min(p0.x, p1.x);
                fr.end_x = @max(p0.x, p1.x);
                fr.y = p0.y;
            }
            if (page.links.len > 0) {
                const rl = try arena.alloc(LinkAnnot, page.links.len);
                for (page.links, 0..) |lk, li| {
                    // Rotate all four corners, then re-derive min/max so
                    // wrapLink's overlap test still sees x0<=x1, y0<=y1.
                    const c0 = rotatePoint(lk.x0, lk.y0, rot, w, h);
                    const c1 = rotatePoint(lk.x1, lk.y0, rot, w, h);
                    const c2 = rotatePoint(lk.x0, lk.y1, rot, w, h);
                    const c3 = rotatePoint(lk.x1, lk.y1, rot, w, h);
                    rl[li] = .{
                        .x0 = @min(@min(c0.x, c1.x), @min(c2.x, c3.x)),
                        .x1 = @max(@max(c0.x, c1.x), @max(c2.x, c3.x)),
                        .y0 = @min(@min(c0.y, c1.y), @min(c2.y, c3.y)),
                        .y1 = @max(@max(c0.y, c1.y), @max(c2.y, c3.y)),
                        .uri = lk.uri,
                    };
                }
                links_for_page = rl;
            }
        }

        var page_lines: std.ArrayListUnmanaged(Line) = .empty;
        assemblePage(arena, frags.items, links_for_page, &page_lines) catch {};
        try all_lines.appendSlice(arena, page_lines.items);
    }

    meta.has_text_layer = any_text;
    meta.needs_ocr = !any_text;
    meta.images_found = image_count;

    // /Info for the frontmatter.
    var info: Dict = .{};
    if (try doc.dictGet(doc.trailer, "Info")) |inf| {
        if (inf.asDict()) |id| info = id;
    }

    var tables_found: usize = 0;
    const mdx_arena = try emitMdx(arena, all_lines.items, info, &doc, pages.items.len, any_text, opts, &tables_found);
    meta.tables_found = tables_found;
    meta.extraction_method = "zig-native";

    // Copy extracted image blobs into the caller's allocator (the arena dies).
    var out_images: []ExtractedImage = &.{};
    if (opts.extract_images and images.items.len > 0) {
        out_images = try gpa.alloc(ExtractedImage, images.items.len);
        for (images.items, 0..) |img, ix| {
            out_images[ix] = .{
                .name = try gpa.dupe(u8, img.name),
                .bytes = try gpa.dupe(u8, img.bytes),
            };
        }
    }

    return .{ .mdx = try gpa.dupe(u8, mdx_arena), .meta = meta, .images = out_images };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "rotatePoint: /Rotate golden vectors" {
    // Unrotated MediaBox 600×800, a known point near the top-left of the page.
    const w: f64 = 600;
    const h: f64 = 800;
    const x: f64 = 100;
    const y: f64 = 700;

    const r0 = rotatePoint(x, y, 0, w, h); // identity
    try testing.expectEqual(@as(f64, 100), r0.x);
    try testing.expectEqual(@as(f64, 700), r0.y);

    const r90 = rotatePoint(x, y, 90, w, h); // (y, w-x) = (700, 500)
    try testing.expectEqual(@as(f64, 700), r90.x);
    try testing.expectEqual(@as(f64, 500), r90.y);

    const r180 = rotatePoint(x, y, 180, w, h); // (w-x, h-y) = (500, 100)
    try testing.expectEqual(@as(f64, 500), r180.x);
    try testing.expectEqual(@as(f64, 100), r180.y);

    const r270 = rotatePoint(x, y, 270, w, h); // (h-y, x) = (100, 100)
    try testing.expectEqual(@as(f64, 100), r270.x);
    try testing.expectEqual(@as(f64, 100), r270.y);
}

test "rotatePoint + assemblePage: /Rotate 90 fixes reading order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const w: f64 = 600;
    const h: f64 = 800;

    // Two visual lines, chosen so the UNROTATED sort (y descending) would emit
    // SECOND (content y=700) before FIRST (content y=100) — the wrong order.
    // After the /Rotate 90 transform: FIRST's displayed y = w - x = 600-100 =
    // 500, SECOND's = 600-400 = 200, so FIRST (higher displayed y) reads first.
    var frags = [_]Frag{
        .{ .x = 100, .y = 100, .end_x = 160, .size = 10, .text = "FIRST" },
        .{ .x = 400, .y = 700, .end_x = 460, .size = 10, .text = "SECOND" },
    };

    for (&frags) |*fr| {
        const p0 = rotatePoint(fr.x, fr.y, 90, w, h);
        const p1 = rotatePoint(fr.end_x, fr.y, 90, w, h);
        fr.x = @min(p0.x, p1.x);
        fr.end_x = @max(p0.x, p1.x);
        fr.y = p0.y;
    }

    var lines: std.ArrayListUnmanaged(Line) = .empty;
    try assemblePage(a, &frags, &.{}, &lines);

    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expect(std.mem.indexOf(u8, lines.items[0].text, "FIRST") != null);
    try testing.expect(std.mem.indexOf(u8, lines.items[1].text, "SECOND") != null);
}

test "LinkAnnot rotation re-min/maxes corners (/Rotate 90)" {
    const w: f64 = 600;
    const h: f64 = 800;
    const lk = LinkAnnot{ .x0 = 100, .y0 = 200, .x1 = 300, .y1 = 250, .uri = "https://example.com" };

    // Rotate all four corners (90°: x' = y, y' = w - x).
    const c0 = rotatePoint(lk.x0, lk.y0, 90, w, h); // (200, 500)
    const c1 = rotatePoint(lk.x1, lk.y0, 90, w, h); // (200, 300)
    const c2 = rotatePoint(lk.x0, lk.y1, 90, w, h); // (250, 500)
    const c3 = rotatePoint(lk.x1, lk.y1, 90, w, h); // (250, 300)

    const nx0 = @min(@min(c0.x, c1.x), @min(c2.x, c3.x));
    const nx1 = @max(@max(c0.x, c1.x), @max(c2.x, c3.x));
    const ny0 = @min(@min(c0.y, c1.y), @min(c2.y, c3.y));
    const ny1 = @max(@max(c0.y, c1.y), @max(c2.y, c3.y));

    try testing.expect(nx0 <= nx1);
    try testing.expect(ny0 <= ny1);
    // x-range from y ∈ [200,250]; y-range from w-x where x ∈ [100,300] → [300,500].
    try testing.expectEqual(@as(f64, 200), nx0);
    try testing.expectEqual(@as(f64, 250), nx1);
    try testing.expectEqual(@as(f64, 300), ny0);
    try testing.expectEqual(@as(f64, 500), ny1);
}

test "rotate == 0 leaves fragments untouched" {
    const w: f64 = 600;
    const h: f64 = 800;
    const rotate: i64 = 0;
    var frags = [_]Frag{
        .{ .x = 10, .y = 20, .end_x = 50, .size = 12, .text = "A" },
        .{ .x = 70, .y = 20, .end_x = 90, .size = 12, .text = "B" },
    };
    const orig = frags;
    // Mirror the production guard: with rotate == 0 the transform never runs.
    if (rotate != 0) {
        for (&frags) |*fr| {
            const p0 = rotatePoint(fr.x, fr.y, rotate, w, h);
            const p1 = rotatePoint(fr.end_x, fr.y, rotate, w, h);
            fr.x = @min(p0.x, p1.x);
            fr.end_x = @max(p0.x, p1.x);
            fr.y = p0.y;
        }
    }
    for (frags, orig) |f, o| {
        try testing.expectEqual(o.x, f.x);
        try testing.expectEqual(o.y, f.y);
        try testing.expectEqual(o.end_x, f.end_x);
    }
}

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

/// Test helper: locate a PNG chunk's data slice by 4-byte type, walking the
/// length/type/data/CRC framing from just past the signature.
fn findPngChunk(png: []const u8, typ: []const u8) ?[]const u8 {
    var i: usize = 8; // skip the 8-byte signature
    while (i + 8 <= png.len) {
        const len: usize = std.mem.readInt(u32, png[i..][0..4], .big);
        const data_start = i + 8;
        if (data_start + len + 4 > png.len) return null;
        if (std.mem.eql(u8, png[i + 4 .. i + 8], typ)) return png[data_start .. data_start + len];
        i = data_start + len + 4;
    }
    return null;
}

test "pngWrap: 2x2 DeviceRGB golden vector" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 2×2 RGB, 3 bytes/pixel, two 6-byte rows.
    const samples = [_]u8{
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, // red,  green
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, // blue, white
    };
    const png = try pngWrap(a, 2, 2, 8, 3, &samples);

    // Signature.
    try testing.expect(png.len > 8);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);

    // Required chunks present.
    const ihdr = findPngChunk(png, "IHDR") orelse return error.TestUnexpectedResult;
    try testing.expect(findPngChunk(png, "IDAT") != null);
    try testing.expect(findPngChunk(png, "IEND") != null);

    // IHDR width / height / bit-depth / colour-type.
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ihdr[0..4], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ihdr[4..8], .big));
    try testing.expectEqual(@as(u8, 8), ihdr[8]);
    try testing.expectEqual(@as(u8, 2), ihdr[9]); // truecolor

    // IDAT decompresses back to the filtered raster (0x00 filter byte per row).
    const idat = findPngChunk(png, "IDAT").?;
    const raw = try inflate(a, idat);
    const expected = [_]u8{
        0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00,
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    try testing.expectEqualSlices(u8, &expected, raw);
}

test "pngWrap: grayscale 1-component" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const samples = [_]u8{ 0x10, 0x20, 0x30, 0x40 }; // 2×2 gray
    const png = try pngWrap(a, 2, 2, 8, 1, &samples);

    const ihdr = findPngChunk(png, "IHDR") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0), ihdr[9]); // grayscale

    const idat = findPngChunk(png, "IDAT") orelse return error.TestUnexpectedResult;
    const raw = try inflate(a, idat);
    const expected = [_]u8{ 0x00, 0x10, 0x20, 0x00, 0x30, 0x40 };
    try testing.expectEqualSlices(u8, &expected, raw);
}

test "pngWrap: CMYK (4 components) returns error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const samples = [_]u8{0} ** 16; // 2×2 CMYK
    try testing.expectError(ExtractError.UnsupportedFilter, pngWrap(a, 2, 2, 8, 4, &samples));
}

test "pngWrap: truncated samples pad without crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Claim 2×2 RGB (needs 12 bytes) but supply only 5 — must zero-pad, not OOB.
    const samples = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    const png = try pngWrap(a, 2, 2, 8, 3, &samples);

    const idat = findPngChunk(png, "IDAT") orelse return error.TestUnexpectedResult;
    const raw = try inflate(a, idat);
    const expected = [_]u8{
        0x00, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, raw);
    try testing.expect(findPngChunk(png, "IEND") != null);
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
    _ = try font.appendUnicode(a, 0x41, 0x41, &out); // A
    _ = try font.appendUnicode(a, 0x42, 0x42, &out); // B
    _ = try font.appendUnicode(a, 0x43, 0x43, &out); // C
    _ = try font.appendUnicode(a, 0x44, 0x44, &out); // D
    try testing.expectEqualStrings("ABCD", out.items);
}

test "embedded CMap: codespacerange + cidrange parse (golden)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Minimal embedded CID CMap: one full 2-byte codespace and one cidrange that
    // maps codes 0x0041..0x005A → CID 1..26 (A..Z), plus one explicit cidchar.
    const cmap =
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n" ++
        "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "1 begincidrange\n<0041> <005A> 1\nendcidrange\n" ++
        "1 begincidchar\n<0061> 100\nendcidchar\n" ++
        "endcmap end end";
    var font = Font{};
    try parseEncodingCMap(a, cmap, &font);

    // Codespace: exactly one range, 2 bytes wide, low 0x0000 high 0xFFFF.
    try testing.expectEqual(@as(usize, 1), font.codespace.len);
    try testing.expectEqual(@as(u32, 0x0000), font.codespace[0].low);
    try testing.expectEqual(@as(u32, 0xFFFF), font.codespace[0].high);
    try testing.expectEqual(@as(u8, 2), font.codespace[0].nbytes);
    try testing.expectEqual(@as(u8, 2), font.bytes_per_code);

    // cidrange: 26 codes (A..Z) + 1 cidchar = 27 entries, hand-verified samples.
    try testing.expectEqual(@as(usize, 27), font.cid_map.count());
    try testing.expectEqual(@as(u32, 1), font.cid_map.get(0x0041).?); // A → 1
    try testing.expectEqual(@as(u32, 26), font.cid_map.get(0x005A).?); // Z → 26
    try testing.expectEqual(@as(u32, 14), font.cid_map.get(0x004E).?); // N → 14
    try testing.expectEqual(@as(u32, 100), font.cid_map.get(0x0061).?); // cidchar a → 100
    try testing.expect(font.cid_map.get(0x0040) == null); // below range, unmapped
    try testing.expect(font.cid_map.get(0x005B) == null); // above range, unmapped
}

test "embedded CMap: mixed-width codespace splits codes correctly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 1-byte range <00>..<80> AND 2-byte range <8140>..<FFFF> (Shift-JIS-shaped).
    const cmap =
        "begincmap\n" ++
        "2 begincodespacerange\n<00> <80>\n<8140> <FFFF>\nendcodespacerange\n" ++
        "endcmap";
    var font = Font{};
    try parseEncodingCMap(a, cmap, &font);
    try testing.expectEqual(@as(usize, 2), font.codespace.len);
    try testing.expectEqual(@as(u8, 2), font.bytes_per_code); // widest range

    // Crafted bytes: 0x41 (1B) | 0x81 0x40 (2B) | 0x7F (1B) | 0x82 0xFF (2B).
    const bytes = [_]u8{ 0x41, 0x81, 0x40, 0x7F, 0x82, 0xFF };
    const expect = [_]struct { code: u32, len: u8 }{
        .{ .code = 0x41, .len = 1 },
        .{ .code = 0x8140, .len = 2 },
        .{ .code = 0x7F, .len = 1 },
        .{ .code = 0x82FF, .len = 2 },
    };
    var i: usize = 0;
    var n: usize = 0;
    while (i < bytes.len) : (n += 1) {
        const nc = font.nextCode(&bytes, i);
        try testing.expectEqual(expect[n].code, nc.code);
        try testing.expectEqual(expect[n].len, nc.len);
        i += nc.len;
    }
    try testing.expectEqual(@as(usize, 4), n);
}

test "empty codespace reproduces fixed-step splitting (regression)" {
    // 2-byte Identity case: nextCode must match the legacy `step = 2` split,
    // including the trailing-odd-byte advance, byte-for-byte.
    {
        var font = Font{ .bytes_per_code = 2 };
        const bytes = [_]u8{ 0x00, 0x41, 0x12, 0x34, 0x05 }; // last byte is odd
        var i: usize = 0;
        var codes: [8]u32 = undefined;
        var n: usize = 0;
        while (i < bytes.len) {
            const nc = font.nextCode(&bytes, i);
            codes[n] = nc.code;
            n += 1;
            i += nc.len;
        }
        // Legacy: 0x0041, 0x1234, then trailing 0x05 (single byte, step advances 2).
        try testing.expectEqual(@as(usize, 3), n);
        try testing.expectEqual(@as(u32, 0x0041), codes[0]);
        try testing.expectEqual(@as(u32, 0x1234), codes[1]);
        try testing.expectEqual(@as(u32, 0x05), codes[2]);
    }
    // 1-byte simple case: one code per byte.
    {
        var font = Font{ .bytes_per_code = 1 };
        const bytes = [_]u8{ 0x48, 0x69, 0x21 }; // "Hi!"
        var i: usize = 0;
        var codes: [4]u32 = undefined;
        var n: usize = 0;
        while (i < bytes.len) {
            const nc = font.nextCode(&bytes, i);
            try testing.expectEqual(@as(u8, 1), nc.len);
            codes[n] = nc.code;
            n += 1;
            i += nc.len;
        }
        try testing.expectEqual(@as(usize, 3), n);
        try testing.expectEqual(@as(u32, 0x48), codes[0]);
        try testing.expectEqual(@as(u32, 0x69), codes[1]);
        try testing.expectEqual(@as(u32, 0x21), codes[2]);
    }
}

test "embedded CMap: CID->Unicode printable fallback, no ToUnicode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Type0 font, no /ToUnicode, embedded cidrange mapping code 0x0001 → CID 0x41
    // ('A', printable) and code 0x0002 → CID 0x2000 (non-printable glyph index).
    const cmap =
        "begincmap\n" ++
        "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "1 begincidchar\n<0001> 65\nendcidchar\n" ++
        "1 begincidchar\n<0002> 8192\nendcidchar\n" ++
        "endcmap";
    var font = Font{ .bytes_per_code = 2 };
    try parseEncodingCMap(a, cmap, &font);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    // Printable CID 0x41 → surfaced as "A".
    const m1 = try font.appendUnicode(a, 0x0001, font.cid_map.get(0x0001).?, &out);
    try testing.expect(m1);
    try testing.expectEqualStrings("A", out.items);
    // Non-printable CID 0x2000 → left unmapped (no fabricated text).
    out.clearRetainingCapacity();
    const m2 = try font.appendUnicode(a, 0x0002, font.cid_map.get(0x0002).?, &out);
    try testing.expect(!m2);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Identity-H Type0 without CMap surfaces no fabricated unicode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // No codespace, no cid_map, no ToUnicode — code is a glyph index, must NOT
    // be surfaced as if it were Unicode.
    var font = Font{ .bytes_per_code = 2 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const mapped = try font.appendUnicode(a, 0x0041, 0x0041, &out);
    try testing.expect(!mapped);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "WinAnsi fallback decodes ASCII + specials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var font = Font{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    _ = try font.appendUnicode(a, 'H', 'H', &out);
    _ = try font.appendUnicode(a, 'i', 'i', &out);
    _ = try font.appendUnicode(a, 0x97, 0x97, &out); // em dash —
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

test "column detection: two-column page → one cut; single column → none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two columns: left band x∈[50,250], right band x∈[350,550], clear gutter
    // at ~300. Ten lines each.
    var two: std.ArrayListUnmanaged(Frag) = .empty;
    var row: usize = 0;
    while (row < 10) : (row += 1) {
        const y = 700.0 - @as(f64, @floatFromInt(row)) * 14.0;
        try two.append(a, .{ .x = 50, .y = y, .end_x = 250, .size = 12, .text = "L" });
        try two.append(a, .{ .x = 350, .y = y, .end_x = 550, .size = 12, .text = "R" });
    }
    const cuts2 = try detectColumnCuts(a, two.items);
    try testing.expectEqual(@as(usize, 1), cuts2.len);
    try testing.expect(cuts2[0] > 250 and cuts2[0] < 350);

    // Single column: full-width lines, no gutter.
    var one: std.ArrayListUnmanaged(Frag) = .empty;
    row = 0;
    while (row < 10) : (row += 1) {
        const y = 700.0 - @as(f64, @floatFromInt(row)) * 14.0;
        try one.append(a, .{ .x = 50, .y = y, .end_x = 550, .size = 12, .text = "full" });
    }
    const cuts1 = try detectColumnCuts(a, one.items);
    try testing.expectEqual(@as(usize, 0), cuts1.len);
}

test "link wrapping: overlapping cell → markdown link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const links = [_]LinkAnnot{.{ .x0 = 40, .y0 = 695, .x1 = 160, .y1 = 710, .uri = "https://example.com/a b" }};
    // Cell centred at x=100, y=700 → inside the rect → wrapped (URI space encoded).
    const hit = try wrapLink(a, &links, 50, 150, 700, "click here");
    try testing.expectEqualStrings("[click here](https://example.com/a%20b)", hit);
    // A cell far away → unchanged.
    const miss = try wrapLink(a, &links, 300, 400, 700, "plain");
    try testing.expectEqualStrings("plain", miss);
    // Right y but wrong line → unchanged.
    const wrong_y = try wrapLink(a, &links, 50, 150, 600, "plain");
    try testing.expectEqualStrings("plain", wrong_y);
}

test "image extension by codec" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const jpg = Dict{ .entries = try a.dupe(Entry, &.{.{ .key = "Filter", .val = .{ .name = "DCTDecode" } }}) };
    try testing.expectEqualStrings("jpg", imageExt(jpg).?);

    const jp2 = Dict{ .entries = try a.dupe(Entry, &.{.{ .key = "Filter", .val = .{ .name = "JPXDecode" } }}) };
    try testing.expectEqualStrings("jp2", imageExt(jp2).?);

    // Flate (raw samples) is not directly writable as an image file.
    const flate_img = Dict{ .entries = try a.dupe(Entry, &.{.{ .key = "Filter", .val = .{ .name = "FlateDecode" } }}) };
    try testing.expect(imageExt(flate_img) == null);
}

test "RC4 known-answer vector + self-inverse" {
    // Classic vector: key "Key", "Plaintext" → BBF316E8D940AF0AD3.
    const key = "Key";
    const pt = "Plaintext";
    var ct: [9]u8 = undefined;
    rc4(key, pt, &ct);
    try testing.expectEqualSlices(u8, &.{ 0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3 }, &ct);
    // RC4 is its own inverse.
    var back: [9]u8 = undefined;
    rc4(key, &ct, &back);
    try testing.expectEqualStrings(pt, &back);
}

test "list marker recognition" {
    try testing.expect(listMarker("\xe2\x80\xa2 Item one").?.ordered == false);
    try testing.expectEqualStrings("Item one", listMarker("\xe2\x80\xa2 Item one").?.rest);
    try testing.expect(listMarker("1. First").?.ordered == true);
    try testing.expectEqualStrings("First", listMarker("1. First").?.rest);
    try testing.expect(listMarker("23) Twenty-three").?.ordered == true);
    try testing.expect(listMarker("- dash item").?.ordered == false);
    // Non-lists.
    try testing.expect(listMarker("Just a sentence.") == null);
    try testing.expect(listMarker("2.1Poweron") == null); // section number, no space
    try testing.expect(listMarker("1.BIOSdataaddress") == null); // TOC entry, no space
}

test "table detection: aligned cells → GFM, prose → none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const mk = struct {
        fn cell(x: f64, t: []const u8) Cell {
            return .{ .x = x, .end_x = x + 40, .text = t };
        }
        fn frag(x: f64, y: f64, t: []const u8) Frag {
            return .{ .x = x, .y = y, .end_x = x + 40, .size = 10, .text = t };
        }
    };
    var rows: std.ArrayListUnmanaged(Line) = .empty;
    // Two columns separated by a wide gutter (x≈90 → 200). Cols detected from the
    // whitespace band between them; column count is cuts.len + 1.
    const ca = [_]Cell{ mk.cell(50, "Name"), mk.cell(200, "Qty") };
    const cb = [_]Cell{ mk.cell(50, "Widget"), mk.cell(200, "3") };
    const cc = [_]Cell{ mk.cell(50, "Gadget"), mk.cell(200, "7") };
    const fa = [_]Frag{ mk.frag(50, 700, "Name"), mk.frag(200, 700, "Qty") };
    const fb = [_]Frag{ mk.frag(50, 686, "Widget"), mk.frag(200, 686, "3") };
    const fc = [_]Frag{ mk.frag(50, 672, "Gadget"), mk.frag(200, 672, "7") };
    try rows.append(a, .{ .text = "Name Qty", .y = 700, .x = 50, .size = 10, .cells = try a.dupe(Cell, &ca), .frags = try a.dupe(Frag, &fa) });
    try rows.append(a, .{ .text = "Widget 3", .y = 686, .x = 50, .size = 10, .cells = try a.dupe(Cell, &cb), .frags = try a.dupe(Frag, &fb) });
    try rows.append(a, .{ .text = "Gadget 7", .y = 672, .x = 50, .size = 10, .cells = try a.dupe(Cell, &cc), .frags = try a.dupe(Frag, &fc) });

    const tbl = tryDetectTable(a, rows.items, 0, 10) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), tbl.end);
    try testing.expectEqual(@as(usize, 1), tbl.cuts.len); // 2 columns → 1 separator gutter

    var aw: std.Io.Writer.Allocating = .init(a);
    try emitTable(a, &aw.writer, rows.items, tbl.cuts);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "| Name | Qty |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| --- | --- |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| Widget | 3 |") != null);

    // A single prose line (one cell) is not a table.
    var prose: std.ArrayListUnmanaged(Line) = .empty;
    const one = [_]Cell{mk.cell(50, "just text")};
    const onef = [_]Frag{mk.frag(50, 700, "just text")};
    try prose.append(a, .{ .text = "just text", .y = 700, .x = 50, .size = 10, .cells = try a.dupe(Cell, &one), .frags = try a.dupe(Frag, &onef) });
    try testing.expect(tryDetectTable(a, prose.items, 0, 10) == null);
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

/// MSB-first variable-width bit packer for the LZW tests below.
const LzwBitPacker = struct {
    out: *std.ArrayListUnmanaged(u8),
    a: std.mem.Allocator,
    bitbuf: u32 = 0,
    nbits: u6 = 0,

    fn emit(self: *LzwBitPacker, code: u16, width: u6) !void {
        self.bitbuf = (self.bitbuf << @as(u5, @intCast(width))) | code;
        self.nbits += width;
        while (self.nbits >= 8) {
            self.nbits -= 8;
            try self.out.append(self.a, @intCast((self.bitbuf >> @as(u5, @intCast(self.nbits))) & 0xFF));
        }
    }

    fn flush(self: *LzwBitPacker) !void {
        if (self.nbits > 0) {
            try self.out.append(self.a, @intCast((self.bitbuf << @as(u5, @intCast(8 - self.nbits))) & 0xFF));
            self.nbits = 0;
        }
    }
};

/// Reference PDF/TIFF LZW encoder (test-only) — mirrors `lzwDecode`'s width and
/// EarlyChange rules so the two can be round-tripped against each other.
fn lzwEncodeForTest(a: std.mem.Allocator, input: []const u8, early_change: i64) ![]u8 {
    const ec: usize = if (early_change == 0) 0 else 1;
    var map = std.StringHashMap(u16).init(a);
    defer map.deinit();
    var s: usize = 0;
    while (s < 256) : (s += 1) {
        const k = try a.dupe(u8, &[_]u8{@intCast(s)});
        try map.put(k, @intCast(s));
    }
    var next_code: usize = 258;
    var width: u6 = 9;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var bp = LzwBitPacker{ .out = &out, .a = a };
    try bp.emit(256, width); // leading ClearTable, exactly as a real PDF stream

    var w: []const u8 = "";
    for (input) |c| {
        const wc = try std.mem.concat(a, u8, &.{ w, &[_]u8{c} });
        if (map.get(wc) != null) {
            w = wc;
        } else {
            try bp.emit(map.get(w).?, width);
            if (next_code < 4096) {
                try map.put(wc, @intCast(next_code));
                next_code += 1;
                // The decoder defines its entries one code later (it needs the
                // next code's first byte), so the encoder — running one entry
                // ahead — must bump the width one code later in its own count.
                if (width < 12 and next_code + ec >= (@as(usize, 1) << @intCast(width)) + 1) width += 1;
            }
            w = try a.dupe(u8, &[_]u8{c});
        }
    }
    if (w.len > 0) try bp.emit(map.get(w).?, width);
    try bp.emit(257, width); // EOD
    try bp.flush();
    return out.items;
}

test "lzw decode: PDF spec golden vector (-----A---B)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // PDF 32000-1:2008 §7.4.4.2 worked example. EarlyChange = 1 (the default).
    const encoded = [_]u8{ 0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01 };
    const expected = [_]u8{ 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x41, 0x2D, 0x2D, 0x2D, 0x42 };
    const out = try lzwDecode(a, &encoded, 1);
    try testing.expectEqualSlices(u8, &expected, out);
}

test "lzw encode matches the PDF spec golden bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Anchors the reference encoder to the same spec example, so the round-trip
    // tests below are trustworthy and not merely self-consistent.
    const input = [_]u8{ 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x41, 0x2D, 0x2D, 0x2D, 0x42 };
    const expected = [_]u8{ 0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01 };
    const enc = try lzwEncodeForTest(a, &input, 1);
    try testing.expectEqualSlices(u8, &expected, enc);
}

test "lzw round-trips a long input across all code widths (ec=1 and ec=0)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ~6 KiB of deterministic pseudo-random bytes: forces the dictionary past
    // 511/1023/2047 (9→12-bit widths) and into the 4096-entry freeze.
    var input: [6000]u8 = undefined;
    var seed: u32 = 0x1234_5678;
    for (&input) |*b| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = @intCast((seed >> 24) & 0xFF);
    }
    inline for (.{ @as(i64, 1), @as(i64, 0) }) |ec| {
        const enc = try lzwEncodeForTest(a, &input, ec);
        const dec = try lzwDecode(a, enc, ec);
        try testing.expectEqualSlices(u8, &input, dec);
    }
}

test "lzw ClearTable mid-stream resets the dictionary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Hand-packed 9-bit codes (all < 512, so width never grows):
    //   256 Clear, 'A', 'B' (defines 258='AB'), 256 Clear (drops 258), 'C', 257 EOD
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    var bp = LzwBitPacker{ .out = &bytes, .a = a };
    for ([_]u16{ 256, 'A', 'B', 256, 'C', 257 }) |code| try bp.emit(code, 9);
    try bp.flush();
    const out = try lzwDecode(a, bytes.items, 1);
    try testing.expectEqualStrings("ABC", out);
}

test "lzw EarlyChange=1 vs 0 produce the documented width-bump difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Input long enough to cross the 511/512 boundary, so the code width bumps
    // at a different code under ec=1 vs ec=0 — yielding distinct byte streams.
    var input: [4000]u8 = undefined;
    var seed: u32 = 0x0BADC0DE;
    for (&input) |*b| {
        seed = seed *% 1103515245 +% 12345;
        b.* = @intCast((seed >> 16) & 0xFF);
    }
    const enc1 = try lzwEncodeForTest(a, &input, 1);
    const enc0 = try lzwEncodeForTest(a, &input, 0);
    try testing.expect(!std.mem.eql(u8, enc1, enc0)); // documented difference
    // Each still decodes losslessly under its own EarlyChange setting.
    try testing.expectEqualSlices(u8, &input, try lzwDecode(a, enc1, 1));
    try testing.expectEqualSlices(u8, &input, try lzwDecode(a, enc0, 0));
}

test "lzw malformed/truncated input never crashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Garbage: first 9-bit code is 511 (>= next free, no prior literal) → stop empty.
    const garbage = try lzwDecode(a, &[_]u8{ 0xFF, 0xFF, 0xFF }, 1);
    try testing.expectEqual(@as(usize, 0), garbage.len);
    // Empty input → empty output.
    const empty = try lzwDecode(a, &[_]u8{}, 1);
    try testing.expectEqual(@as(usize, 0), empty.len);
    // Truncated tail of the spec vector: must return a (partial) prefix, no panic.
    const truncated = try lzwDecode(a, &[_]u8{ 0x80, 0x0B, 0x60, 0x50 }, 1);
    try testing.expect(std.mem.startsWith(u8, truncated, "-"));
}
