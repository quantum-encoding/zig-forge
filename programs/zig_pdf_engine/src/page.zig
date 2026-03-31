const std = @import("std");
const lexer = @import("lexer.zig");
const objects = @import("objects.zig");
const filters = @import("filters.zig");
const text_extract = @import("extract/text.zig");

const Lexer = lexer.Lexer;
const Object = objects.Object;
const ObjectRef = objects.ObjectRef;
const DictParser = objects.DictParser;
const TextExtractor = text_extract.TextExtractor;

/// Represents a single page in a PDF document
pub const Page = struct {
    doc_data: []const u8, // Reference to mmap'd document
    page_dict: []const u8, // Raw dict bytes for this page
    allocator: std.mem.Allocator,
    xref_getter: *const fn (u32) ?u64, // Function to get object offsets

    // Cached values
    media_box: ?[4]f64 = null,
    rotation: u16 = 0,

    /// Get the content stream data (decompressed)
    pub fn getContentStream(self: *Page) ![]u8 {
        var parser = DictParser.init(self.page_dict);

        // Get /Contents - can be a reference or array of references
        const contents_obj = parser.get("Contents") orelse return error.NoContents;

        switch (contents_obj) {
            .reference => |ref| {
                return self.getStreamDataForRef(ref);
            },
            .array => |array_bytes| {
                // Multiple content streams - concatenate them
                return self.concatenateStreams(array_bytes);
            },
            else => return error.InvalidContents,
        }
    }

    /// Extract text from this page
    pub fn extractText(self: *Page) ![]u8 {
        const content_stream = try self.getContentStream();
        defer self.allocator.free(content_stream);

        var extractor = TextExtractor.init(self.allocator);
        return extractor.extract(content_stream);
    }

    /// Get MediaBox [x1, y1, x2, y2]
    pub fn getMediaBox(self: *Page) ?[4]f64 {
        if (self.media_box) |box| return box;

        var parser = DictParser.init(self.page_dict);
        const box_obj = parser.get("MediaBox") orelse return null;

        switch (box_obj) {
            .array => |array_bytes| {
                var box: [4]f64 = .{ 0, 0, 612, 792 }; // Default letter size
                var arr_lex = Lexer.init(array_bytes);
                var i: usize = 0;

                while (arr_lex.next()) |token| {
                    if (i >= 4) break;
                    if (token.tag == .number) {
                        box[i] = token.asFloat() orelse @floatFromInt(token.asInt() orelse 0);
                        i += 1;
                    }
                }

                return box;
            },
            else => return null,
        }
    }

    /// Get page width in points
    pub fn getWidth(self: *Page) f64 {
        const box = self.getMediaBox() orelse return 612;
        return box[2] - box[0];
    }

    /// Get page height in points
    pub fn getHeight(self: *Page) f64 {
        const box = self.getMediaBox() orelse return 792;
        return box[3] - box[1];
    }

    // === Private helpers ===

    fn getStreamDataForRef(self: *Page, ref: ObjectRef) ![]u8 {
        const offset = self.xref_getter(ref.obj_num) orelse return error.ObjectNotFound;

        var lex = Lexer.initAt(self.doc_data, @intCast(offset));

        // Skip "obj_num gen_num obj"
        _ = lex.next(); // obj_num
        _ = lex.next(); // gen_num
        _ = lex.next(); // obj

        const obj = try Object.parse(&lex);

        switch (obj) {
            .stream => |stream| {
                return self.decompressStream(stream.dict, stream.data);
            },
            else => return error.NotAStream,
        }
    }

    fn decompressStream(self: *Page, dict_bytes: []const u8, data: []const u8) ![]u8 {
        var parser = DictParser.init(dict_bytes);

        // Check for /Filter
        if (parser.get("Filter")) |filter_obj| {
            switch (filter_obj) {
                .name => |filter_name| {
                    return self.applyFilter(filter_name, data);
                },
                .array => |filter_array| {
                    // Multiple filters - apply in order
                    return self.applyFilterChain(filter_array, data);
                },
                else => {},
            }
        }

        // No filter - return copy
        return self.allocator.dupe(u8, data);
    }

    fn applyFilter(self: *Page, filter_name: []const u8, data: []const u8) ![]u8 {
        if (std.mem.eql(u8, filter_name, "FlateDecode") or std.mem.eql(u8, filter_name, "Fl")) {
            return filters.FlateDecode.decode(self.allocator, data);
        } else if (std.mem.eql(u8, filter_name, "ASCII85Decode") or std.mem.eql(u8, filter_name, "A85")) {
            return filters.Ascii85Decode.decode(self.allocator, data);
        } else if (std.mem.eql(u8, filter_name, "ASCIIHexDecode") or std.mem.eql(u8, filter_name, "AHx")) {
            return filters.AsciiHexDecode.decode(self.allocator, data);
        } else if (std.mem.eql(u8, filter_name, "LZWDecode") or std.mem.eql(u8, filter_name, "LZW")) {
            // LZWDecode requires a complete LZW decompression implementation
            // For now, return unfiltered data with a note that decoding is needed
            return self.allocator.dupe(u8, data);
        } else {
            return error.UnsupportedFilter;
        }
    }

    fn applyFilterChain(self: *Page, filter_array: []const u8, data: []const u8) ![]u8 {
        var current = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(current);

        var lex = Lexer.init(filter_array);
        while (lex.next()) |token| {
            if (token.tag == .name) {
                const new_data = try self.applyFilter(token.nameValue(), current);
                self.allocator.free(current);
                current = new_data;
            }
        }

        return current;
    }

    fn concatenateStreams(self: *Page, array_bytes: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var lex = Lexer.init(array_bytes);

        while (true) {
            // Parse reference
            const num_tok = lex.next() orelse break;
            if (num_tok.tag != .number) continue;

            const gen_tok = lex.next() orelse break;
            if (gen_tok.tag != .number) continue;

            const r_tok = lex.next() orelse break;
            if (r_tok.tag != .keyword_ref) continue;

            const ref = ObjectRef{
                .obj_num = @intCast(num_tok.asInt() orelse continue),
                .gen_num = @intCast(gen_tok.asInt() orelse continue),
            };

            const stream_data = self.getStreamDataForRef(ref) catch continue;
            defer self.allocator.free(stream_data);

            try result.appendSlice(self.allocator, stream_data);
            try result.append(self.allocator, '\n'); // Separate streams
        }

        return result.toOwnedSlice(self.allocator);
    }
};

/// Page tree navigator - handles the /Pages tree structure
pub const PageTree = struct {
    doc_data: []const u8,
    allocator: std.mem.Allocator,
    xref_getter: *const fn (u32) ?u64,
    page_refs: std.ArrayList(ObjectRef),

    /// Explicit error set to avoid recursive inference
    pub const TraverseError = error{
        ObjectNotFound,
        UnexpectedEof,
        InvalidObject,
        InvalidDict,
        InvalidNumber,
        UnexpectedToken,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, doc_data: []const u8, xref_getter: *const fn (u32) ?u64) PageTree {
        return .{
            .doc_data = doc_data,
            .allocator = allocator,
            .xref_getter = xref_getter,
            .page_refs = std.ArrayList(ObjectRef).empty,
        };
    }

    pub fn deinit(self: *PageTree) void {
        self.page_refs.deinit(self.allocator);
    }

    /// Build flat list of page references from tree
    pub fn buildPageList(self: *PageTree, root_ref: ObjectRef) TraverseError!void {
        try self.traverseNode(root_ref);
    }

    fn traverseNode(self: *PageTree, ref: ObjectRef) TraverseError!void {
        const offset = self.xref_getter(ref.obj_num) orelse return error.ObjectNotFound;

        var lex = Lexer.initAt(self.doc_data, @intCast(offset));

        // Skip "obj_num gen_num obj"
        _ = lex.next();
        _ = lex.next();
        _ = lex.next();

        const obj = try Object.parse(&lex);

        switch (obj) {
            .dict => |dict_bytes| {
                var parser = DictParser.init(dict_bytes);

                // Check /Type
                const type_obj = parser.get("Type") orelse return;
                const type_name = type_obj.asName() orelse return;

                if (std.mem.eql(u8, type_name, "Pages")) {
                    // Intermediate node - recurse into /Kids
                    const kids_obj = parser.get("Kids") orelse return;
                    switch (kids_obj) {
                        .array => |kids_bytes| {
                            try self.traverseKids(kids_bytes);
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, type_name, "Page")) {
                    // Leaf node - add to list
                    try self.page_refs.append(self.allocator, ref);
                }
            },
            else => {},
        }
    }

    fn traverseKids(self: *PageTree, kids_bytes: []const u8) TraverseError!void {
        var lex = Lexer.init(kids_bytes);

        while (true) {
            const num_tok = lex.next() orelse break;
            if (num_tok.tag != .number) continue;

            const gen_tok = lex.next() orelse break;
            if (gen_tok.tag != .number) continue;

            const r_tok = lex.next() orelse break;
            if (r_tok.tag != .keyword_ref) continue;

            const ref = ObjectRef{
                .obj_num = @intCast(num_tok.asInt() orelse continue),
                .gen_num = @intCast(gen_tok.asInt() orelse continue),
            };

            try self.traverseNode(ref);
        }
    }

    /// Get page count
    pub fn count(self: *const PageTree) usize {
        return self.page_refs.items.len;
    }

    /// Get page at index
    pub fn getPage(self: *PageTree, index: usize) ?Page {
        if (index >= self.page_refs.items.len) return null;

        const ref = self.page_refs.items[index];
        const offset = self.xref_getter(ref.obj_num) orelse return null;

        var lex = Lexer.initAt(self.doc_data, @intCast(offset));

        // Skip "obj_num gen_num obj"
        _ = lex.next();
        _ = lex.next();
        _ = lex.next();

        const obj = Object.parse(&lex) catch return null;

        switch (obj) {
            .dict => |dict_bytes| {
                return Page{
                    .doc_data = self.doc_data,
                    .page_dict = dict_bytes,
                    .allocator = self.allocator,
                    .xref_getter = self.xref_getter,
                };
            },
            else => return null,
        }
    }
};
