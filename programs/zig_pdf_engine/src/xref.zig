const std = @import("std");
const lexer = @import("lexer.zig");
const objects = @import("objects.zig");
const filters = @import("filters.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const Object = objects.Object;
const DictParser = objects.DictParser;

/// Cross-reference table entry
pub const XRefEntry = struct {
    offset: u64, // Byte offset in file (for 'n' entries)
    gen_num: u16, // Generation number
    in_use: bool, // true = 'n' (in use), false = 'f' (free)
    compressed: bool, // true if object is in an object stream
    stream_obj: u32, // If compressed: object number of containing stream
    stream_idx: u16, // If compressed: index within stream
};

/// XRef table - maps object numbers to file offsets
pub const XRefTable = struct {
    entries: std.AutoHashMap(u32, XRefEntry),
    trailer: TrailerInfo,
    allocator: std.mem.Allocator,
    startxref_offset: u64 = 0, // Location of startxref in original file

    pub const TrailerInfo = struct {
        size: u32, // Total number of objects
        root: objects.ObjectRef, // Catalog reference
        info: ?objects.ObjectRef, // Document info dict (optional)
        id: ?[2][]const u8, // File identifiers (optional)
        prev: ?u64, // Previous xref offset (for incremental updates)
        encrypt: ?objects.ObjectRef, // Encryption dict (optional)
    };

    pub const ParseError = error{
        UnexpectedEof,
        InvalidXref,
        InvalidNumber,
        InvalidXrefEntry,
        InvalidTrailer,
        MissingTrailerSize,
        MissingTrailerRoot,
        InvalidTrailerSize,
        InvalidTrailerRoot,
        InvalidXrefStream,
        InvalidXrefStreamW,
        InvalidXrefStreamIndex,
        XrefDecompressFailed,
        OutOfMemory,
        UnexpectedToken,
    };

    pub fn init(allocator: std.mem.Allocator) XRefTable {
        return .{
            .entries = std.AutoHashMap(u32, XRefEntry).init(allocator),
            .trailer = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *XRefTable) void {
        self.entries.deinit();
    }

    /// Get offset for an object
    pub fn getOffset(self: *const XRefTable, obj_num: u32) ?u64 {
        const entry = self.entries.get(obj_num) orelse return null;
        if (!entry.in_use or entry.compressed) return null;
        return entry.offset;
    }

    /// Get entry for an object
    pub fn getEntry(self: *const XRefTable, obj_num: u32) ?XRefEntry {
        return self.entries.get(obj_num);
    }

    /// Number of entries
    pub fn count(self: *const XRefTable) usize {
        return self.entries.count();
    }

    /// Get maximum object number in the table
    pub fn getMaxObjectNum(self: *const XRefTable) u32 {
        var max: u32 = 0;
        var iter = self.entries.keyIterator();
        while (iter.next()) |key| {
            if (key.* > max) max = key.*;
        }
        return max;
    }

    /// Parse xref from PDF data, starting from the end
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !XRefTable {
        var table = XRefTable.init(allocator);
        errdefer table.deinit();

        // Find startxref from end of file
        const startxref_offset = try findStartXref(data);
        const xref_offset = try parseStartXrefValue(data, startxref_offset);

        // Store the offset for incremental updates
        table.startxref_offset = xref_offset;

        // Parse xref section(s)
        try table.parseXrefAt(data, xref_offset);

        return table;
    }

    fn parseXrefAt(self: *XRefTable, data: []const u8, offset: u64) ParseError!void {
        var lex = Lexer.initAt(data, @intCast(offset));

        const first_token = lex.next() orelse return error.UnexpectedEof;

        if (first_token.tag == .keyword_xref) {
            // Traditional xref table
            try self.parseTraditionalXref(&lex, data);
        } else if (first_token.tag == .number) {
            // Could be xref stream (PDF 1.5+)
            try self.parseXrefStream(&lex, data, first_token);
        } else {
            return error.InvalidXref;
        }
    }

    fn parseIdArray(self: *XRefTable, arr_bytes: []const u8) ParseError![2][]const u8 {
        _ = self; // Not used, but part of method signature for consistency
        var lex = Lexer.init(arr_bytes);
        var ids: [2][]const u8 = .{ "", "" };
        var idx: usize = 0;

        while (lex.next()) |tok| {
            if (idx >= 2) break;

            switch (tok.tag) {
                .literal_string => {
                    ids[idx] = tok.stringContent();
                    idx += 1;
                },
                .hex_string => {
                    ids[idx] = tok.hexContent();
                    idx += 1;
                },
                else => {},
            }
        }

        // Return the array if we got both IDs
        if (idx == 2) {
            return ids;
        }
        return error.InvalidXref;
    }

    fn parseTraditionalXref(self: *XRefTable, lex: *Lexer, data: []const u8) ParseError!void {
        // Parse subsections: "start_obj count" followed by entries
        while (true) {
            const token = lex.next() orelse return error.UnexpectedEof;

            if (token.tag == .keyword_trailer) {
                // Parse trailer dictionary
                try self.parseTrailer(lex, data);
                return;
            }

            if (token.tag != .number) return error.InvalidXref;
            const start_obj = token.asInt() orelse return error.InvalidNumber;

            const count_token = lex.next() orelse return error.UnexpectedEof;
            if (count_token.tag != .number) return error.InvalidXref;
            const entry_count = count_token.asInt() orelse return error.InvalidNumber;

            // Parse entries
            var obj_num: u32 = @intCast(start_obj);
            var i: i64 = 0;
            while (i < entry_count) : (i += 1) {
                const offset_tok = lex.next() orelse return error.UnexpectedEof;
                const gen_tok = lex.next() orelse return error.UnexpectedEof;
                const type_tok = lex.next() orelse return error.UnexpectedEof;

                if (offset_tok.tag != .number or gen_tok.tag != .number) {
                    return error.InvalidXrefEntry;
                }

                const offset_val = offset_tok.asInt() orelse return error.InvalidNumber;
                const gen_val = gen_tok.asInt() orelse return error.InvalidNumber;

                const in_use = if (type_tok.tag == .name and type_tok.data.len > 0)
                    type_tok.data[type_tok.data.len - 1] == 'n'
                else if (type_tok.data.len > 0)
                    type_tok.data[0] == 'n'
                else
                    false;

                try self.entries.put(obj_num, .{
                    .offset = @intCast(offset_val),
                    .gen_num = @intCast(gen_val),
                    .in_use = in_use,
                    .compressed = false,
                    .stream_obj = 0,
                    .stream_idx = 0,
                });

                obj_num += 1;
            }
        }
    }

    fn parseXrefStream(self: *XRefTable, lex: *Lexer, data: []const u8, first_token: Token) ParseError!void {
        // xref stream format: "obj_num gen_num obj << /Type /XRef /Size N /W [w1 w2 w3] /Index [start count ...] >> stream ... endstream endobj"
        _ = first_token; // Already consumed (the object number)

        // Skip generation number
        const gen_tok = lex.next() orelse return error.UnexpectedEof;
        if (gen_tok.tag != .number) return error.InvalidXref;

        // Skip "obj" keyword
        const obj_tok = lex.next() orelse return error.UnexpectedEof;
        if (obj_tok.tag != .keyword_obj) return error.InvalidXref;

        // Parse the stream object (dictionary + stream data)
        const obj = Object.parse(lex) catch return error.InvalidXrefStream;

        switch (obj) {
            .stream => |stream| {
                try self.parseXrefStreamContents(stream.dict, stream.data, data);
            },
            else => return error.InvalidXrefStream,
        }
    }

    fn parseXrefStreamContents(self: *XRefTable, dict_bytes: []const u8, stream_data: []const u8, full_data: []const u8) ParseError!void {
        var parser = DictParser.init(dict_bytes);

        // Verify /Type /XRef (optional but should be present)
        if (parser.get("Type")) |type_obj| {
            const type_name = type_obj.asName() orelse return error.InvalidXrefStream;
            if (!std.mem.eql(u8, type_name, "XRef")) return error.InvalidXrefStream;
        }

        // /Size (required) - total number of objects
        const size_obj = parser.get("Size") orelse return error.MissingTrailerSize;
        const size_val: u32 = @intCast(size_obj.asInt() orelse return error.InvalidTrailerSize);

        // /W (required) - array of 3 integers specifying field widths
        const w_obj = parser.get("W") orelse return error.InvalidXrefStreamW;
        var w_widths: [3]u8 = undefined;
        switch (w_obj) {
            .array => |arr_bytes| {
                var arr_lex = Lexer.init(arr_bytes);
                var idx: usize = 0;
                while (arr_lex.next()) |tok| {
                    if (idx >= 3) break;
                    if (tok.tag == .number) {
                        w_widths[idx] = @intCast(tok.asInt() orelse 0);
                        idx += 1;
                    }
                }
                if (idx != 3) return error.InvalidXrefStreamW;
            },
            else => return error.InvalidXrefStreamW,
        }

        // /Index (optional) - array of pairs [start count start count ...]
        // Default is [0 Size]
        var index_pairs = std.ArrayList([2]u32).empty;
        defer index_pairs.deinit(self.allocator);

        if (parser.get("Index")) |index_obj| {
            switch (index_obj) {
                .array => |arr_bytes| {
                    var arr_lex = Lexer.init(arr_bytes);
                    var nums: [2]u32 = undefined;
                    var num_idx: usize = 0;

                    while (arr_lex.next()) |tok| {
                        if (tok.tag == .number) {
                            nums[num_idx] = @intCast(tok.asInt() orelse 0);
                            num_idx += 1;
                            if (num_idx == 2) {
                                try index_pairs.append(self.allocator, nums);
                                num_idx = 0;
                            }
                        }
                    }
                },
                else => return error.InvalidXrefStreamIndex,
            }
        } else {
            // Default: [0 Size]
            try index_pairs.append(self.allocator, .{ 0, size_val });
        }

        // Decompress stream data if filtered
        var decompressed: ?[]u8 = null;
        defer if (decompressed) |d| self.allocator.free(d);

        const xref_data = blk: {
            if (parser.get("Filter")) |filter_obj| {
                const filter_name = filter_obj.asName() orelse break :blk stream_data;
                if (std.mem.eql(u8, filter_name, "FlateDecode")) {
                    decompressed = filters.FlateDecode.decode(self.allocator, stream_data) catch return error.XrefDecompressFailed;
                    break :blk decompressed.?;
                }
            }
            break :blk stream_data;
        };

        // Parse the binary xref entries
        const entry_size = @as(usize, w_widths[0]) + w_widths[1] + w_widths[2];
        var data_pos: usize = 0;

        for (index_pairs.items) |pair| {
            const start_obj = pair[0];
            const entry_count = pair[1];

            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                if (data_pos + entry_size > xref_data.len) break;

                // Read field 1: type (default 1 if width is 0)
                const field1 = readXrefField(xref_data[data_pos..], w_widths[0]);
                data_pos += w_widths[0];

                // Read field 2: depends on type
                const field2 = readXrefField(xref_data[data_pos..], w_widths[1]);
                data_pos += w_widths[1];

                // Read field 3: depends on type
                const field3 = readXrefField(xref_data[data_pos..], w_widths[2]);
                data_pos += w_widths[2];

                const obj_num = start_obj + i;
                const entry_type: u8 = if (w_widths[0] == 0) 1 else @intCast(field1);

                switch (entry_type) {
                    0 => {
                        // Free object: field2 = next free object, field3 = generation
                        try self.entries.put(obj_num, .{
                            .offset = 0,
                            .gen_num = @intCast(field3),
                            .in_use = false,
                            .compressed = false,
                            .stream_obj = 0,
                            .stream_idx = 0,
                        });
                    },
                    1 => {
                        // Uncompressed object: field2 = offset, field3 = generation
                        try self.entries.put(obj_num, .{
                            .offset = field2,
                            .gen_num = @intCast(field3),
                            .in_use = true,
                            .compressed = false,
                            .stream_obj = 0,
                            .stream_idx = 0,
                        });
                    },
                    2 => {
                        // Compressed object: field2 = object stream number, field3 = index in stream
                        try self.entries.put(obj_num, .{
                            .offset = 0,
                            .gen_num = 0,
                            .in_use = true,
                            .compressed = true,
                            .stream_obj = @intCast(field2),
                            .stream_idx = @intCast(field3),
                        });
                    },
                    else => {
                        // Unknown type - skip
                    },
                }
            }
        }

        // Store trailer info from stream dictionary
        self.trailer.size = size_val;

        // /Root (required)
        const root_obj = parser.get("Root") orelse return error.MissingTrailerRoot;
        self.trailer.root = root_obj.asRef() orelse return error.InvalidTrailerRoot;

        // /Info (optional)
        self.trailer.info = if (parser.get("Info")) |info_obj| info_obj.asRef() else null;

        // /Encrypt (optional)
        self.trailer.encrypt = if (parser.get("Encrypt")) |enc_obj| enc_obj.asRef() else null;

        // /ID (optional) - array of two byte strings
        self.trailer.id = null;
        if (parser.get("ID")) |id_obj| {
            switch (id_obj) {
                .array => |arr_bytes| {
                    self.trailer.id = try self.parseIdArray(arr_bytes);
                },
                else => {},
            }
        }

        // /Prev (optional - for incremental updates)
        if (parser.get("Prev")) |prev_obj| {
            const prev_offset: u64 = @intCast(prev_obj.asInt() orelse 0);
            if (prev_offset > 0) {
                self.trailer.prev = prev_offset;
                try self.parseXrefAt(full_data, prev_offset);
            } else {
                self.trailer.prev = null;
            }
        } else {
            self.trailer.prev = null;
        }
    }

    fn parseTrailer(self: *XRefTable, lex: *Lexer, data: []const u8) ParseError!void {
        const obj = Object.parse(lex) catch return error.InvalidTrailer;

        switch (obj) {
            .dict => |dict_bytes| {
                var parser = DictParser.init(dict_bytes);

                // /Size (required)
                const size_obj = parser.get("Size") orelse return error.MissingTrailerSize;
                self.trailer.size = @intCast(size_obj.asInt() orelse return error.InvalidTrailerSize);

                // /Root (required)
                const root_obj = parser.get("Root") orelse return error.MissingTrailerRoot;
                self.trailer.root = root_obj.asRef() orelse return error.InvalidTrailerRoot;

                // /Info (optional)
                if (parser.get("Info")) |info_obj| {
                    self.trailer.info = info_obj.asRef();
                } else {
                    self.trailer.info = null;
                }

                // /Prev (optional - for incremental updates)
                if (parser.get("Prev")) |prev_obj| {
                    self.trailer.prev = @intCast(prev_obj.asInt() orelse 0);

                    // Parse previous xref table
                    if (self.trailer.prev) |prev_offset| {
                        try self.parseXrefAt(data, prev_offset);
                    }
                } else {
                    self.trailer.prev = null;
                }

                // /Encrypt (optional)
                if (parser.get("Encrypt")) |enc_obj| {
                    self.trailer.encrypt = enc_obj.asRef();
                } else {
                    self.trailer.encrypt = null;
                }

                // /ID (optional) - array of two byte strings
                self.trailer.id = null;
                if (parser.get("ID")) |id_obj| {
                    switch (id_obj) {
                        .array => |arr_bytes| {
                            self.trailer.id = try self.parseIdArray(arr_bytes);
                        },
                        else => {},
                    }
                }
            },
            else => return error.InvalidTrailer,
        }
    }
};

/// Read a big-endian integer field from xref stream data
fn readXrefField(data: []const u8, width: u8) u64 {
    if (width == 0) return 0;
    if (width > data.len) return 0;

    var result: u64 = 0;
    var i: usize = 0;
    while (i < width) : (i += 1) {
        result = (result << 8) | data[i];
    }
    return result;
}

/// Find "startxref" keyword from end of file
fn findStartXref(data: []const u8) !usize {
    // Search backwards from end (startxref is in last 1024 bytes typically)
    const search_len = @min(data.len, 1024);
    const search_start = data.len - search_len;
    const needle = "startxref";

    if (search_len < needle.len) return error.StartXrefNotFound;

    var i: usize = search_len - needle.len;
    while (true) {
        if (std.mem.eql(u8, data[search_start + i ..][0..needle.len], needle)) {
            return search_start + i;
        }
        if (i == 0) break;
        i -= 1;
    }
    return error.StartXrefNotFound;
}

/// Parse the offset value after "startxref"
fn parseStartXrefValue(data: []const u8, startxref_pos: usize) !u64 {
    var lex = Lexer.initAt(data, startxref_pos);

    // Skip "startxref" keyword
    const kw = lex.next() orelse return error.UnexpectedEof;
    if (kw.tag != .keyword_startxref) return error.InvalidStartXref;

    // Get offset
    const offset_token = lex.next() orelse return error.UnexpectedEof;
    if (offset_token.tag != .number) return error.InvalidStartXref;

    return @intCast(offset_token.asInt() orelse return error.InvalidNumber);
}

/// Find PDF version from header
pub fn findPdfVersion(data: []const u8) ?[]const u8 {
    // PDF header: %PDF-1.x
    if (data.len < 8) return null;
    if (!std.mem.startsWith(u8, data, "%PDF-")) return null;

    var end: usize = 5;
    while (end < @min(data.len, 10) and data[end] != '\n' and data[end] != '\r') {
        end += 1;
    }
    return data[5..end];
}

// === Tests ===

test "find startxref" {
    const data = "%PDF-1.4\n...content...\nstartxref\n12345\n%%EOF";
    const pos = try findStartXref(data);
    try std.testing.expect(std.mem.eql(u8, data[pos..][0..9], "startxref"));
}

test "parse startxref value" {
    const data = "startxref\n12345\n%%EOF";
    const offset = try parseStartXrefValue(data, 0);
    try std.testing.expectEqual(@as(u64, 12345), offset);
}

test "find PDF version" {
    const data = "%PDF-1.7\n";
    const version = findPdfVersion(data);
    try std.testing.expectEqualStrings("1.7", version.?);
}
