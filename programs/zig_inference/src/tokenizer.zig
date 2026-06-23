const std = @import("std");
const Allocator = std.mem.Allocator;
const gguf_mod = @import("gguf.zig");

/// Tokenizer family. LLaMA-family GGUFs use SentencePiece (▁ space marker, merge
/// scores, <0xXX> byte fallback). Qwen3 / GPT-2 GGUFs use byte-level BPE (byte→unicode
/// map, merge-rank ordering, regex pre-tokenization).
pub const Kind = enum { sentencepiece, gpt2 };

pub const Tokenizer = struct {
    allocator: Allocator,
    kind: Kind,
    vocab: [][]const u8, // token ID -> string
    scores: []f32, // token ID -> merge priority score (SentencePiece)
    vocab_size: u32,
    vocab_map: std.StringHashMap(u32), // string -> token ID
    bos_id: u32,
    eos_id: u32,
    add_bos_default: bool,
    add_eos_default: bool,

    // SentencePiece scratch
    merge_buf: []u8,

    // GPT-2 byte-level BPE state
    merge_ranks: std.StringHashMap(u32), // "A B" -> rank (lower = higher priority)
    byte_str: [256][]const u8, // byte -> mapped-unicode UTF-8 string
    byte_buf: []u8, // backing storage for byte_str

    pub fn init(allocator: Allocator, gguf: *const gguf_mod.GGUFFile) !Tokenizer {
        const vs: u32 = gguf.vocab_size;
        const kind: Kind = if (std.mem.eql(u8, gguf.tokenizer_model, "gpt2")) .gpt2 else .sentencepiece;

        // Build vocab_map: string -> token ID
        var vocab_map = std.StringHashMap(u32).init(allocator);
        try vocab_map.ensureTotalCapacity(vs);
        for (0..vs) |i| {
            if (i < gguf.tokens.len) {
                // Last token wins on duplicate keys; GGUF vocabs are unique by construction.
                try vocab_map.put(gguf.tokens[i], @intCast(i));
            }
        }

        const merge_buf = try allocator.alloc(u8, 512);

        var self = Tokenizer{
            .allocator = allocator,
            .kind = kind,
            .vocab = gguf.tokens,
            .scores = gguf.scores,
            .vocab_size = vs,
            .vocab_map = vocab_map,
            .bos_id = gguf.bos_id,
            .eos_id = gguf.eos_id,
            .add_bos_default = gguf.add_bos,
            .add_eos_default = gguf.add_eos,
            .merge_buf = merge_buf,
            .merge_ranks = std.StringHashMap(u32).init(allocator),
            .byte_str = undefined,
            .byte_buf = &.{},
        };

        if (kind == .gpt2) {
            try self.buildByteToUnicode();
            try self.merge_ranks.ensureTotalCapacity(@intCast(gguf.merges.len));
            for (gguf.merges, 0..) |m, rank| {
                // Keys are slices into the mmap'd GGUF (stable for the file's lifetime).
                try self.merge_ranks.put(m, @intCast(rank));
            }
        }

        return self;
    }

    pub fn deinit(self: *Tokenizer) void {
        self.vocab_map.deinit();
        self.merge_ranks.deinit();
        self.allocator.free(self.merge_buf);
        if (self.byte_buf.len > 0) self.allocator.free(self.byte_buf);
    }

    /// GPT-2 byte→unicode mapping: printable byte ranges map to themselves, the rest map
    /// to codepoints 256+ (in increasing byte order). Avoids control/whitespace chars in
    /// the vocab. e.g. byte 0x20 (space) -> U+0120 'Ġ'.
    fn buildByteToUnicode(self: *Tokenizer) !void {
        // Worst-case 2 bytes UTF-8 per mapped char (max codepoint 0x143).
        self.byte_buf = try self.allocator.alloc(u8, 256 * 2);
        var off: usize = 0;
        var n: u21 = 0;
        for (0..256) |b| {
            const bb: u21 = @intCast(b);
            const printable = (bb >= 0x21 and bb <= 0x7E) or (bb >= 0xA1 and bb <= 0xAC) or (bb >= 0xAE and bb <= 0xFF);
            const cp: u21 = if (printable) bb else blk: {
                const v = 256 + n;
                n += 1;
                break :blk v;
            };
            const len = std.unicode.utf8Encode(cp, self.byte_buf[off..]) catch unreachable;
            self.byte_str[b] = self.byte_buf[off .. off + len];
            off += len;
        }
    }

    // ── Public encode ──

    /// Encode text to token IDs. `add_bos` requests a leading BOS, but it is only added if
    /// the model's tokenizer config opts into it (Qwen3 sets add_bos_token=false). EOS is
    /// never appended here — callers that need it (embeddings) append eos_id themselves.
    pub fn encode(self: *const Tokenizer, allocator: Allocator, text: []const u8, add_bos: bool) ![]u32 {
        return switch (self.kind) {
            .sentencepiece => self.encodeSentencePiece(allocator, text, add_bos),
            .gpt2 => self.encodeGpt2(allocator, text, add_bos and self.add_bos_default),
        };
    }

    // ── GPT-2 byte-level BPE ──

    fn encodeGpt2(self: *const Tokenizer, allocator: Allocator, text: []const u8, add_bos: bool) ![]u32 {
        var tokens: std.ArrayListUnmanaged(u32) = .empty;
        errdefer tokens.deinit(allocator);
        if (add_bos) try tokens.append(allocator, self.bos_id);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Pre-tokenize (Qwen2 regex, pragmatic implementation) then BPE each chunk.
        var i: usize = 0;
        while (i < text.len) {
            const chunk_end = self.nextChunk(text, i);
            std.debug.assert(chunk_end > i);
            try self.bpeChunk(allocator, arena, text[i..chunk_end], &tokens);
            _ = arena_state.reset(.retain_capacity);
            i = chunk_end;
        }

        return tokens.toOwnedSlice(allocator);
    }

    /// BPE-merge one pre-token chunk into token IDs appended to `tokens`.
    fn bpeChunk(self: *const Tokenizer, out_alloc: Allocator, arena: Allocator, chunk: []const u8, tokens: *std.ArrayListUnmanaged(u32)) !void {
        if (chunk.len == 0) return;

        // Initial symbols: one mapped-unicode string per original byte.
        var syms: std.ArrayListUnmanaged([]const u8) = .empty;
        for (chunk) |b| try syms.append(arena, self.byte_str[b]);

        var pair: std.ArrayListUnmanaged(u8) = .empty;
        while (syms.items.len > 1) {
            var best_rank: u32 = std.math.maxInt(u32);
            var best_i: ?usize = null;
            for (0..syms.items.len - 1) |k| {
                pair.clearRetainingCapacity();
                try pair.appendSlice(arena, syms.items[k]);
                try pair.append(arena, ' ');
                try pair.appendSlice(arena, syms.items[k + 1]);
                if (self.merge_ranks.get(pair.items)) |r| {
                    if (r < best_rank) {
                        best_rank = r;
                        best_i = k;
                    }
                }
            }
            const k = best_i orelse break;
            const merged = try arena.alloc(u8, syms.items[k].len + syms.items[k + 1].len);
            @memcpy(merged[0..syms.items[k].len], syms.items[k]);
            @memcpy(merged[syms.items[k].len..], syms.items[k + 1]);
            syms.items[k] = merged;
            _ = syms.orderedRemove(k + 1);
        }

        for (syms.items) |s| {
            if (self.vocab_map.get(s)) |id| {
                try tokens.append(out_alloc, id);
            }
            // Byte-level vocab always contains every single mapped byte, so a miss here can
            // only be a multi-byte symbol whose pieces are individually present — but since
            // BPE only merges via known merge rules, every final symbol is a real token.
        }
    }

    // ── Qwen2 pre-tokenizer (pragmatic) ──
    //
    // Approximates the Qwen2 regex:
    //   (?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])
    //   | [^\r\n\p{L}\p{N}]?\p{L}+ | \p{N}
    //   | ?[^\s\p{L}\p{N}]+[\r\n]* | \s*[\r\n]+ | \s+(?!\S) | \s+
    //
    // Letter classification: ASCII [A-Za-z] plus any non-ASCII codepoint (treated as a
    // letter). This is exact for ASCII text and a documented approximation for non-Latin
    // scripts that contain non-ASCII punctuation. Digits are ASCII [0-9], split per-char.

    /// Return the end index (exclusive) of the pre-token chunk starting at `start`.
    fn nextChunk(self: *const Tokenizer, text: []const u8, start: usize) usize {
        _ = self;
        const cp0 = decodeCp(text, start);

        // 1. Contractions: 's 't 're 've 'm 'll 'd (case-insensitive).
        if (cp0.cp == '\'' and start + 1 < text.len) {
            const a = text[start + 1];
            const a_lo = std.ascii.toLower(a);
            if (start + 2 < text.len) {
                const b_lo = std.ascii.toLower(text[start + 2]);
                if ((a_lo == 'r' and b_lo == 'e') or (a_lo == 'v' and b_lo == 'e') or (a_lo == 'l' and b_lo == 'l')) {
                    return start + 3;
                }
            }
            if (a_lo == 's' or a_lo == 't' or a_lo == 'm' or a_lo == 'd') return start + 2;
        }

        // 2. Optional single leading non-(letter/digit/newline) char, then letters+.
        {
            var j = start;
            var consumed_lead = false;
            if (!isLetter(cp0.cp) and !isDigit(cp0.cp) and !isNewline(cp0.cp)) {
                const nxt = j + cp0.len;
                if (nxt < text.len and isLetter(decodeCp(text, nxt).cp)) {
                    j = nxt;
                    consumed_lead = true;
                }
            }
            if (j < text.len and isLetter(decodeCp(text, j).cp)) {
                while (j < text.len) {
                    const c = decodeCp(text, j);
                    if (!isLetter(c.cp)) break;
                    j += c.len;
                }
                return j;
            }
            if (consumed_lead) {
                // lead consumed but no letters followed — fall through to other branches
            }
        }

        // 3. Single digit.
        if (isDigit(cp0.cp)) return start + cp0.len;

        // 4. Optional leading space, then a run of non-(space/letter/digit), then newlines.
        {
            var j = start;
            if (cp0.cp == ' ') {
                const nxt = start + 1;
                if (nxt < text.len) {
                    const c = decodeCp(text, nxt);
                    if (!isWhitespace(c.cp) and !isLetter(c.cp) and !isDigit(c.cp)) j = nxt;
                }
            }
            if (j < text.len) {
                const c = decodeCp(text, j);
                if (!isWhitespace(c.cp) and !isLetter(c.cp) and !isDigit(c.cp)) {
                    while (j < text.len) {
                        const cc = decodeCp(text, j);
                        if (isWhitespace(cc.cp) or isLetter(cc.cp) or isDigit(cc.cp)) break;
                        j += cc.len;
                    }
                    while (j < text.len) {
                        const cc = decodeCp(text, j);
                        if (!isNewline(cc.cp)) break;
                        j += cc.len;
                    }
                    return j;
                }
            }
        }

        // 5. Whitespace runs.
        if (isWhitespace(cp0.cp)) {
            var j = start;
            var has_newline = false;
            while (j < text.len) {
                const c = decodeCp(text, j);
                if (!isWhitespace(c.cp)) break;
                if (isNewline(c.cp)) has_newline = true;
                j += c.len;
            }
            // End-of-text run, newline-containing run, or single whitespace: emit whole.
            if (j >= text.len or has_newline) return j;
            // Run followed by a token: leave the last whitespace char to attach forward.
            const last = lastCharStart(text, start, j);
            if (last > start) return last;
            return j; // exactly one whitespace char before a token
        }

        // Fallback: consume one codepoint (never produces an empty chunk).
        return start + cp0.len;
    }

    // ── SentencePiece (LLaMA) — unchanged behavior ──

    const SP_SPACE: []const u8 = "\xe2\x96\x81"; // U+2581

    fn encodeSentencePiece(self: *const Tokenizer, allocator: Allocator, text: []const u8, add_bos: bool) ![]u32 {
        var tokens: std.ArrayListUnmanaged(u32) = .empty;

        if (add_bos) {
            try tokens.append(allocator, self.bos_id);
        }

        if (text.len == 0) return try tokens.toOwnedSlice(allocator);

        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        defer normalized.deinit(allocator);
        try normalized.appendSlice(allocator, SP_SPACE);
        for (text) |byte| {
            if (byte == ' ') {
                try normalized.appendSlice(allocator, SP_SPACE);
            } else {
                try normalized.append(allocator, byte);
            }
        }
        const norm_text = normalized.items;

        var i: usize = 0;
        while (i < norm_text.len) {
            const cp_len = utf8CharLen(norm_text[i]);
            const char_end = @min(i + cp_len, norm_text.len);
            const char_str = norm_text[i..char_end];

            if (self.vocab_map.get(char_str)) |id| {
                try tokens.append(allocator, id);
            } else {
                for (char_str) |byte| {
                    var byte_token: [6]u8 = undefined;
                    _ = try std.fmt.bufPrint(&byte_token, "<0x{X:0>2}>", .{byte});
                    if (self.vocab_map.get(&byte_token)) |id| {
                        try tokens.append(allocator, id);
                    }
                }
            }
            i = char_end;
        }

        if (self.scores.len > 0) {
            while (true) {
                var best_score: f32 = -std.math.inf(f32);
                var best_pos: ?usize = null;
                var best_id: u32 = 0;

                var pos: usize = 0;
                while (pos + 1 < tokens.items.len) : (pos += 1) {
                    const merged = self.tryMerge(tokens.items[pos], tokens.items[pos + 1]) orelse continue;
                    const score = if (merged < self.scores.len) self.scores[merged] else -std.math.inf(f32);
                    if (score > best_score) {
                        best_score = score;
                        best_pos = pos;
                        best_id = merged;
                    }
                }

                if (best_pos == null) break;

                tokens.items[best_pos.?] = best_id;
                _ = tokens.orderedRemove(best_pos.? + 1);
            }
        }

        return try tokens.toOwnedSlice(allocator);
    }

    fn tryMerge(self: *const Tokenizer, a: u32, b: u32) ?u32 {
        if (a >= self.vocab_size or b >= self.vocab_size) return null;
        const str_a = self.vocab[a];
        const str_b = self.vocab[b];
        if (str_a.len + str_b.len > self.merge_buf.len) return null;

        @memcpy(self.merge_buf[0..str_a.len], str_a);
        @memcpy(self.merge_buf[str_a.len..][0..str_b.len], str_b);
        const merged = self.merge_buf[0 .. str_a.len + str_b.len];

        return self.vocab_map.get(merged);
    }

    // ── Decode (shared) ──

    pub fn decodeToken(self: *const Tokenizer, token: u32) []const u8 {
        if (token >= self.vocab_size) return "";
        return self.vocab[token];
    }

    pub fn decode(self: *const Tokenizer, allocator: Allocator, tokens_list: []const u32) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        if (self.kind == .gpt2) {
            // Reverse the byte→unicode map: each vocab string is a sequence of mapped chars.
            for (tokens_list) |tok| {
                const piece = self.decodeToken(tok);
                try self.appendGpt2Piece(allocator, &out, piece);
            }
            return out.toOwnedSlice(allocator);
        }
        for (tokens_list) |tok| {
            const piece = self.decodeToken(tok);
            if (piece.len == 6 and piece[0] == '<' and piece[1] == '0' and piece[2] == 'x' and piece[5] == '>') {
                const byte = std.fmt.parseInt(u8, piece[3..5], 16) catch continue;
                try out.append(allocator, byte);
            } else {
                var j: usize = 0;
                while (j < piece.len) {
                    if (j + 3 <= piece.len and piece[j] == 0xE2 and piece[j + 1] == 0x96 and piece[j + 2] == 0x81) {
                        try out.append(allocator, ' ');
                        j += 3;
                    } else {
                        try out.append(allocator, piece[j]);
                        j += 1;
                    }
                }
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Map a GPT-2 token's mapped-unicode string back to the original bytes.
    fn appendGpt2Piece(self: *const Tokenizer, allocator: Allocator, out: *std.ArrayListUnmanaged(u8), piece: []const u8) !void {
        var j: usize = 0;
        while (j < piece.len) {
            const clen = utf8CharLen(piece[j]);
            const end = @min(j + clen, piece.len);
            const ch = piece[j..end];
            // Find which byte maps to this char (256-way table; small constant).
            var matched = false;
            for (0..256) |b| {
                if (std.mem.eql(u8, self.byte_str[b], ch)) {
                    try out.append(allocator, @intCast(b));
                    matched = true;
                    break;
                }
            }
            if (!matched) try out.appendSlice(allocator, ch);
            j = end;
        }
    }
};

// ── Codepoint helpers ──

const Cp = struct { cp: u21, len: usize };

fn decodeCp(text: []const u8, i: usize) Cp {
    const len = utf8CharLen(text[i]);
    const end = @min(i + len, text.len);
    const cp = std.unicode.utf8Decode(text[i..end]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = end - i };
}

/// Start index of the last codepoint within [start, end).
fn lastCharStart(text: []const u8, start: usize, end: usize) usize {
    var i = start;
    var last = start;
    while (i < end) {
        last = i;
        i += decodeCp(text, i).len;
    }
    return last;
}

fn isLetter(cp: u21) bool {
    if (cp < 0x80) return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z');
    // Non-ASCII: treat as a letter (approximation — see nextChunk note), excluding the
    // common Unicode whitespace codepoints handled by isWhitespace.
    return !isWhitespace(cp);
}

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn isNewline(cp: u21) bool {
    return cp == '\n' or cp == '\r';
}

fn isWhitespace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C or cp == 0xA0;
}

fn utf8CharLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}
