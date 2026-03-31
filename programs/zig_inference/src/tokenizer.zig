const std = @import("std");
const Allocator = std.mem.Allocator;
const gguf_mod = @import("gguf.zig");

pub const Tokenizer = struct {
    allocator: Allocator,
    vocab: [][]const u8, // token ID -> string
    scores: []f32, // token ID -> merge priority score
    vocab_size: u32,
    vocab_map: std.StringHashMap(u32), // string -> token ID
    bos_id: u32,
    eos_id: u32,

    // Scratch buffer for encode
    merge_buf: []u8,

    pub fn init(allocator: Allocator, gguf: *const gguf_mod.GGUFFile) !Tokenizer {
        const vs: u32 = gguf.vocab_size;

        // Build vocab_map: string -> token ID
        var vocab_map = std.StringHashMap(u32).init(allocator);
        try vocab_map.ensureTotalCapacity(vs);
        for (0..vs) |i| {
            if (i < gguf.tokens.len) {
                vocab_map.putAssumeCapacity(gguf.tokens[i], @intCast(i));
            }
        }

        const merge_buf = try allocator.alloc(u8, 512);

        return Tokenizer{
            .allocator = allocator,
            .vocab = gguf.tokens,
            .scores = gguf.scores,
            .vocab_size = vs,
            .vocab_map = vocab_map,
            .bos_id = gguf.bos_id,
            .eos_id = gguf.eos_id,
            .merge_buf = merge_buf,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.vocab_map.deinit();
        self.allocator.free(self.merge_buf);
    }

    // SentencePiece uses ▁ (U+2581) to represent spaces in the vocabulary
    const SP_SPACE: []const u8 = "\xe2\x96\x81"; // U+2581 in UTF-8

    /// Encode text to token IDs using SentencePiece-style BPE
    pub fn encode(self: *const Tokenizer, allocator: Allocator, text: []const u8, add_bos: bool) ![]u32 {
        var tokens: std.ArrayListUnmanaged(u32) = .empty;

        if (add_bos) {
            try tokens.append(allocator, self.bos_id);
        }

        if (text.len == 0) return try tokens.toOwnedSlice(allocator);

        // SentencePiece normalization: prepend space and replace spaces with ▁
        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        defer normalized.deinit(allocator);
        // Prepend ▁ (sentencepiece adds leading space)
        try normalized.appendSlice(allocator, SP_SPACE);
        for (text) |byte| {
            if (byte == ' ') {
                try normalized.appendSlice(allocator, SP_SPACE);
            } else {
                try normalized.append(allocator, byte);
            }
        }
        const norm_text = normalized.items;

        // Step 1: Initial tokenization -- try each UTF-8 character as a token
        var i: usize = 0;
        while (i < norm_text.len) {
            const cp_len = utf8CharLen(norm_text[i]);
            const char_end = @min(i + cp_len, norm_text.len);
            const char_str = norm_text[i..char_end];

            if (self.vocab_map.get(char_str)) |id| {
                try tokens.append(allocator, id);
            } else {
                // Byte fallback: encode each byte as <0xXX>
                for (char_str) |byte| {
                    var byte_token: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&byte_token, "<0x{X:0>2}>", .{byte}) catch unreachable;
                    if (self.vocab_map.get(&byte_token)) |id| {
                        try tokens.append(allocator, id);
                    }
                }
            }
            i = char_end;
        }

        // Step 2: BPE merges -- repeatedly merge best adjacent pair
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

    pub fn decodeToken(self: *const Tokenizer, token: u32) []const u8 {
        if (token >= self.vocab_size) return "";
        return self.vocab[token];
    }

    pub fn decode(self: *const Tokenizer, allocator: Allocator, tokens_list: []const u32) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (tokens_list) |tok| {
            const piece = self.decodeToken(tok);

            if (piece.len == 6 and piece[0] == '<' and piece[1] == '0' and piece[2] == 'x' and piece[5] == '>') {
                const byte = std.fmt.parseInt(u8, piece[3..5], 16) catch continue;
                try out.append(allocator, byte);
            } else {
                // Replace ▁ with space in output
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
};

fn utf8CharLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}
