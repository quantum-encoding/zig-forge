// PDF Editor - Incremental update and modification support
//
// Design: PDF editing uses "incremental updates" - new objects are appended
// to the end of the file with a new xref table pointing to modified objects.
// This preserves the original PDF and allows edits without full rewrite.

const std = @import("std");
const document = @import("document.zig");
const objects = @import("objects.zig");
const lexer = @import("lexer.zig");

const Document = document.Document;
const Object = objects.Object;
const ObjectRef = objects.ObjectRef;
const DictParser = objects.DictParser;

/// PDF Editor for modifying existing documents
pub const Editor = struct {
    allocator: std.mem.Allocator,
    doc: *Document,

    // New/modified objects (obj_num -> serialized object data)
    modified_objects: std.AutoHashMap(u32, []u8),

    // New object counter (starts after last object in original)
    next_obj_num: u32,

    // Pending metadata updates
    new_metadata: Metadata,
    metadata_changed: bool,

    // Content additions per page (page_index -> list of content operations)
    page_additions: std.AutoHashMap(usize, std.ArrayList(ContentAddition)),

    pub const Metadata = struct {
        title: ?[]const u8 = null,
        author: ?[]const u8 = null,
        subject: ?[]const u8 = null,
        keywords: ?[]const u8 = null,
        creator: ?[]const u8 = null,
        producer: ?[]const u8 = null,
    };

    pub const ContentAddition = struct {
        content_type: ContentType,
        data: []const u8,
        x: f32,
        y: f32,
        font_size: f32 = 12.0,
        font_name: []const u8 = "Helvetica",

        pub const ContentType = enum {
            text,
            line,
            rectangle,
            image_ref,
        };
    };

    /// Initialize editor with an open document
    pub fn init(allocator: std.mem.Allocator, doc: *Document) Editor {
        const last_obj = doc.xref_table.getMaxObjectNum();

        return .{
            .allocator = allocator,
            .doc = doc,
            .modified_objects = std.AutoHashMap(u32, []u8).init(allocator),
            .next_obj_num = last_obj + 1,
            .new_metadata = .{},
            .metadata_changed = false,
            .page_additions = std.AutoHashMap(usize, std.ArrayList(ContentAddition)).init(allocator),
        };
    }

    /// Clean up editor resources
    pub fn deinit(self: *Editor) void {
        var obj_iter = self.modified_objects.valueIterator();
        while (obj_iter.next()) |data| {
            self.allocator.free(data.*);
        }
        self.modified_objects.deinit();

        var page_iter = self.page_additions.valueIterator();
        while (page_iter.next()) |additions| {
            for (additions.items) |add| {
                self.allocator.free(add.data);
            }
            additions.deinit(self.allocator);
        }
        self.page_additions.deinit();

        // Free metadata strings
        if (self.new_metadata.title) |t| self.allocator.free(t);
        if (self.new_metadata.author) |a| self.allocator.free(a);
        if (self.new_metadata.subject) |s| self.allocator.free(s);
        if (self.new_metadata.keywords) |k| self.allocator.free(k);
        if (self.new_metadata.creator) |c| self.allocator.free(c);
        if (self.new_metadata.producer) |p| self.allocator.free(p);
    }

    // =========================================================================
    // Metadata Editing
    // =========================================================================

    /// Set document title
    pub fn setTitle(self: *Editor, title: []const u8) !void {
        self.new_metadata.title = try self.allocator.dupe(u8, title);
        self.metadata_changed = true;
    }

    /// Set document author
    pub fn setAuthor(self: *Editor, author: []const u8) !void {
        self.new_metadata.author = try self.allocator.dupe(u8, author);
        self.metadata_changed = true;
    }

    /// Set document subject
    pub fn setSubject(self: *Editor, subject: []const u8) !void {
        self.new_metadata.subject = try self.allocator.dupe(u8, subject);
        self.metadata_changed = true;
    }

    /// Set document keywords
    pub fn setKeywords(self: *Editor, keywords: []const u8) !void {
        self.new_metadata.keywords = try self.allocator.dupe(u8, keywords);
        self.metadata_changed = true;
    }

    /// Set document creator application
    pub fn setCreator(self: *Editor, creator: []const u8) !void {
        self.new_metadata.creator = try self.allocator.dupe(u8, creator);
        self.metadata_changed = true;
    }

    /// Set document producer
    pub fn setProducer(self: *Editor, producer: []const u8) !void {
        self.new_metadata.producer = try self.allocator.dupe(u8, producer);
        self.metadata_changed = true;
    }

    // =========================================================================
    // Content Addition
    // =========================================================================

    /// Add text to a page at specified position
    pub fn addText(self: *Editor, page_index: usize, x: f32, y: f32, text: []const u8) !void {
        try self.addTextWithStyle(page_index, x, y, text, 12.0, "Helvetica");
    }

    /// Add text with font size and name
    pub fn addTextWithStyle(
        self: *Editor,
        page_index: usize,
        x: f32,
        y: f32,
        text: []const u8,
        font_size: f32,
        font_name: []const u8,
    ) !void {
        const result = try self.page_additions.getOrPut(page_index);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }

        try result.value_ptr.append(self.allocator, .{
            .content_type = .text,
            .data = try self.allocator.dupe(u8, text),
            .x = x,
            .y = y,
            .font_size = font_size,
            .font_name = font_name,
        });
    }

    /// Add a line between two points
    pub fn addLine(self: *Editor, page_index: usize, x1: f32, y1: f32, x2: f32, y2: f32) !void {
        const result = try self.page_additions.getOrPut(page_index);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }

        var line_data: std.ArrayList(u8) = .empty;
        try appendFmt(self.allocator, &line_data, "{d} {d} {d} {d}", .{ x1, y1, x2, y2 });

        try result.value_ptr.append(self.allocator, .{
            .content_type = .line,
            .data = try line_data.toOwnedSlice(self.allocator),
            .x = x1,
            .y = y1,
        });
    }

    /// Add a rectangle
    pub fn addRectangle(self: *Editor, page_index: usize, x: f32, y: f32, width: f32, height: f32) !void {
        const result = try self.page_additions.getOrPut(page_index);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }

        var rect_data: std.ArrayList(u8) = .empty;
        try appendFmt(self.allocator, &rect_data, "{d} {d}", .{ width, height });

        try result.value_ptr.append(self.allocator, .{
            .content_type = .rectangle,
            .data = try rect_data.toOwnedSlice(self.allocator),
            .x = x,
            .y = y,
        });
    }

    // =========================================================================
    // Serialization
    // =========================================================================

    /// Write modified PDF to a new file (incremental update)
    pub fn save(self: *Editor, output_path: []const u8) !void {
        // Convert path to null-terminated for posix
        var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (output_path.len >= std.fs.max_path_bytes) return error.NameTooLong;
        @memcpy(path_z[0..output_path.len], output_path);
        path_z[output_path.len] = 0;

        // Create a sentinel-terminated slice
        const path_sentinel: [:0]const u8 = path_z[0..output_path.len :0];

        const fd = try std.posix.open(path_sentinel, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        defer _ = std.c.close(fd);

        try self.writeToFd(fd);
    }

    /// Write modified PDF to file descriptor
    fn writeToFd(self: *Editor, fd: std.posix.fd_t) !void {
        // Build the entire output in memory
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        // 1. Copy original PDF content
        try buf.appendSlice(self.allocator, self.doc.data);

        // Ensure we start on a new line
        if (self.doc.data.len > 0 and self.doc.data[self.doc.data.len - 1] != '\n') {
            try buf.append(self.allocator, '\n');
        }

        // Track offset for new xref
        var current_offset = self.doc.size;
        if (self.doc.data[self.doc.data.len - 1] != '\n') {
            current_offset += 1;
        }

        // 2. Write new/modified objects
        var new_xref_entries: std.ArrayList(XrefEntry) = .empty;
        defer new_xref_entries.deinit(self.allocator);

        // Write metadata object if changed
        if (self.metadata_changed) {
            const info_obj_num = self.next_obj_num;
            self.next_obj_num += 1;

            const obj_data = try self.serializeInfoDict();
            defer self.allocator.free(obj_data);

            try new_xref_entries.append(self.allocator, .{
                .obj_num = info_obj_num,
                .offset = current_offset,
                .gen = 0,
            });

            const obj_line = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n{s}\nendobj\n", .{ info_obj_num, obj_data });
            defer self.allocator.free(obj_line);
            try buf.appendSlice(self.allocator, obj_line);
            current_offset += obj_line.len;
        }

        // Write page content additions
        var page_iter = self.page_additions.iterator();
        while (page_iter.next()) |entry| {
            const page_index = entry.key_ptr.*;
            const additions = entry.value_ptr.*;

            if (additions.items.len > 0) {
                const stream_obj_num = self.next_obj_num;
                self.next_obj_num += 1;

                const stream_data = try self.serializeContentAdditions(additions.items);
                defer self.allocator.free(stream_data);

                try new_xref_entries.append(self.allocator, .{
                    .obj_num = stream_obj_num,
                    .offset = current_offset,
                    .gen = 0,
                });

                // Build stream object
                const header = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ stream_obj_num, stream_data.len });
                defer self.allocator.free(header);
                try buf.appendSlice(self.allocator, header);
                try buf.appendSlice(self.allocator, stream_data);
                try buf.appendSlice(self.allocator, "\nendstream\nendobj\n");

                _ = page_index; // Will be used when we modify the page's Contents array
                current_offset += header.len + stream_data.len + 18; // 18 = "\nendstream\nendobj\n".len
            }
        }

        // 3. Write new xref table
        const xref_offset = current_offset;
        try buf.appendSlice(self.allocator, "xref\n");

        if (new_xref_entries.items.len > 0) {
            // Sort entries by object number
            std.mem.sort(XrefEntry, new_xref_entries.items, {}, struct {
                fn lessThan(_: void, a: XrefEntry, b: XrefEntry) bool {
                    return a.obj_num < b.obj_num;
                }
            }.lessThan);

            // Write xref subsections
            var i: usize = 0;
            while (i < new_xref_entries.items.len) {
                const start = new_xref_entries.items[i].obj_num;
                var count: u32 = 1;

                // Count consecutive objects
                while (i + count < new_xref_entries.items.len and
                    new_xref_entries.items[i + count].obj_num == start + count)
                {
                    count += 1;
                }

                try appendFmt(self.allocator, &buf, "{d} {d}\n", .{ start, count });

                for (0..count) |j| {
                    const entry = new_xref_entries.items[i + j];
                    try appendFmt(self.allocator, &buf, "{d:0>10} {d:0>5} n \n", .{ entry.offset, entry.gen });
                }

                i += count;
            }
        } else {
            try buf.appendSlice(self.allocator, "0 0\n");
        }

        // 4. Write trailer
        try buf.appendSlice(self.allocator, "trailer\n<<\n");
        try appendFmt(self.allocator, &buf, "  /Size {d}\n", .{self.next_obj_num});
        try appendFmt(self.allocator, &buf, "  /Root {d} 0 R\n", .{self.doc.xref_table.trailer.root.obj_num});
        try appendFmt(self.allocator, &buf, "  /Prev {d}\n", .{self.doc.xref_table.startxref_offset});

        if (self.metadata_changed) {
            // Point to our new Info dictionary
            try appendFmt(self.allocator, &buf, "  /Info {d} 0 R\n", .{self.next_obj_num - 1});
        } else if (self.doc.xref_table.trailer.info) |info| {
            try appendFmt(self.allocator, &buf, "  /Info {d} 0 R\n", .{info.obj_num});
        }

        try buf.appendSlice(self.allocator, ">>\n");

        // 5. Write startxref
        try appendFmt(self.allocator, &buf, "startxref\n{d}\n%%EOF\n", .{xref_offset});

        // Write everything to file
        _ = try std.posix.write(fd, buf.items);
    }

    /// Serialize new Info dictionary
    fn serializeInfoDict(self: *Editor) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "<<");

        if (self.new_metadata.title) |t| {
            try buf.appendSlice(self.allocator, "\n  /Title (");
            try appendPdfString(self.allocator, &buf, t);
            try buf.appendSlice(self.allocator, ")");
        }
        if (self.new_metadata.author) |a| {
            try buf.appendSlice(self.allocator, "\n  /Author (");
            try appendPdfString(self.allocator, &buf, a);
            try buf.appendSlice(self.allocator, ")");
        }
        if (self.new_metadata.subject) |s| {
            try buf.appendSlice(self.allocator, "\n  /Subject (");
            try appendPdfString(self.allocator, &buf, s);
            try buf.appendSlice(self.allocator, ")");
        }
        if (self.new_metadata.keywords) |k| {
            try buf.appendSlice(self.allocator, "\n  /Keywords (");
            try appendPdfString(self.allocator, &buf, k);
            try buf.appendSlice(self.allocator, ")");
        }
        if (self.new_metadata.creator) |c| {
            try buf.appendSlice(self.allocator, "\n  /Creator (");
            try appendPdfString(self.allocator, &buf, c);
            try buf.appendSlice(self.allocator, ")");
        }
        if (self.new_metadata.producer) |p| {
            try buf.appendSlice(self.allocator, "\n  /Producer (");
            try appendPdfString(self.allocator, &buf, p);
            try buf.appendSlice(self.allocator, ")");
        }

        // Add modification date
        try buf.appendSlice(self.allocator, "\n  /ModDate (D:");
        try appendCurrentDate(self.allocator, &buf);
        try buf.appendSlice(self.allocator, ")");

        try buf.appendSlice(self.allocator, "\n>>");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Serialize content additions to PDF content stream
    fn serializeContentAdditions(self: *Editor, additions: []const ContentAddition) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // Save graphics state
        try buf.appendSlice(self.allocator, "q\n");

        for (additions) |add| {
            switch (add.content_type) {
                .text => {
                    try buf.appendSlice(self.allocator, "BT\n");
                    try appendFmt(self.allocator, &buf, "/{s} {d} Tf\n", .{ add.font_name, add.font_size });
                    try appendFmt(self.allocator, &buf, "{d} {d} Td\n", .{ add.x, add.y });
                    try buf.appendSlice(self.allocator, "(");
                    try appendPdfString(self.allocator, &buf, add.data);
                    try buf.appendSlice(self.allocator, ") Tj\n");
                    try buf.appendSlice(self.allocator, "ET\n");
                },
                .line => {
                    // Parse x2, y2 from data
                    try appendFmt(self.allocator, &buf, "{d} {d} m\n", .{ add.x, add.y });
                    try buf.appendSlice(self.allocator, add.data);
                    try buf.appendSlice(self.allocator, " l\nS\n");
                },
                .rectangle => {
                    try appendFmt(self.allocator, &buf, "{d} {d} ", .{ add.x, add.y });
                    try buf.appendSlice(self.allocator, add.data);
                    try buf.appendSlice(self.allocator, " re\nS\n");
                },
                .image_ref => {
                    // Image XObject reference
                    try appendFmt(self.allocator, &buf, "q\n{s} Do\nQ\n", .{add.data});
                },
            }
        }

        // Restore graphics state
        try buf.appendSlice(self.allocator, "Q\n");

        return buf.toOwnedSlice(self.allocator);
    }

    const XrefEntry = struct {
        obj_num: u32,
        offset: usize,
        gen: u16,
    };
};

/// PDF Writer for creating new PDFs from scratch
pub const Writer = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(WrittenObject),
    pages: std.ArrayList(PageDef),
    metadata: Editor.Metadata,
    next_obj_num: u32,

    const WrittenObject = struct {
        obj_num: u32,
        data: []u8,
    };

    const PageDef = struct {
        width: f32,
        height: f32,
        content: []u8,
        resources: ?[]u8,
    };

    /// Create a new PDF writer
    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .allocator = allocator,
            .objects = .{},
            .pages = .{},
            .metadata = .{},
            .next_obj_num = 1,
        };
    }

    /// Clean up writer resources
    pub fn deinit(self: *Writer) void {
        for (self.objects.items) |obj| {
            self.allocator.free(obj.data);
        }
        self.objects.deinit(self.allocator);

        for (self.pages.items) |page| {
            self.allocator.free(page.content);
            if (page.resources) |r| self.allocator.free(r);
        }
        self.pages.deinit(self.allocator);

        // Free metadata strings
        if (self.metadata.title) |t| self.allocator.free(t);
        if (self.metadata.author) |a| self.allocator.free(a);
        if (self.metadata.subject) |s| self.allocator.free(s);
        if (self.metadata.keywords) |k| self.allocator.free(k);
        if (self.metadata.creator) |c| self.allocator.free(c);
        if (self.metadata.producer) |p| self.allocator.free(p);
    }

    /// Set document title
    pub fn setTitle(self: *Writer, title: []const u8) !void {
        self.metadata.title = try self.allocator.dupe(u8, title);
    }

    /// Set document author
    pub fn setAuthor(self: *Writer, author: []const u8) !void {
        self.metadata.author = try self.allocator.dupe(u8, author);
    }

    /// Add a page with content stream
    pub fn addPage(self: *Writer, width: f32, height: f32, content: []const u8) !void {
        try self.pages.append(self.allocator, .{
            .width = width,
            .height = height,
            .content = try self.allocator.dupe(u8, content),
            .resources = null,
        });
    }

    /// Add a blank page
    pub fn addBlankPage(self: *Writer, width: f32, height: f32) !void {
        try self.addPage(width, height, "");
    }

    /// Add a page with text content
    pub fn addTextPage(self: *Writer, width: f32, height: f32, text: []const u8, x: f32, y: f32) !void {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "BT\n/F1 12 Tf\n");
        try appendFmt(self.allocator, &content, "{d} {d} Td\n(", .{ x, y });
        try appendPdfString(self.allocator, &content, text);
        try content.appendSlice(self.allocator, ") Tj\nET\n");

        try self.pages.append(self.allocator, .{
            .width = width,
            .height = height,
            .content = try content.toOwnedSlice(self.allocator),
            .resources = try self.allocator.dupe(u8, "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"),
        });
    }

    /// Write the PDF to a file
    pub fn save(self: *Writer, path: []const u8) !void {
        // Convert path to null-terminated for posix
        var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= std.fs.max_path_bytes) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        // Create a sentinel-terminated slice
        const path_sentinel: [:0]const u8 = path_z[0..path.len :0];

        const fd = try std.posix.open(path_sentinel, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        defer _ = std.c.close(fd);

        try self.writeToFd(fd);
    }

    /// Write PDF to file descriptor
    fn writeToFd(self: *Writer, fd: std.posix.fd_t) !void {
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(self.allocator);

        // Build the entire PDF in memory first
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        // PDF Header
        try buf.appendSlice(self.allocator, "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");

        // Track offsets
        var offset: usize = 15;

        // Object 1: Catalog
        const catalog_num = self.allocObjOffset(&offsets, offset);
        const catalog = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n<< /Type /Catalog /Pages {d} 0 R >>\nendobj\n", .{ catalog_num, catalog_num + 1 });
        defer self.allocator.free(catalog);
        try buf.appendSlice(self.allocator, catalog);
        offset += catalog.len;

        // Object 2: Pages
        const pages_num = self.allocObjOffset(&offsets, offset);
        var pages_kids: std.ArrayList(u8) = .empty;
        defer pages_kids.deinit(self.allocator);

        const first_page_num = pages_num + 1;
        for (0..self.pages.items.len) |i| {
            if (i > 0) try pages_kids.appendSlice(self.allocator, " ");
            try appendFmt(self.allocator, &pages_kids, "{d} 0 R", .{first_page_num + i * 2});
        }

        const pages_obj = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n<< /Type /Pages /Kids [{s}] /Count {d} >>\nendobj\n", .{ pages_num, pages_kids.items, self.pages.items.len });
        defer self.allocator.free(pages_obj);
        try buf.appendSlice(self.allocator, pages_obj);
        offset += pages_obj.len;

        // Write each page
        for (self.pages.items) |page| {
            const page_num = self.allocObjOffset(&offsets, offset);
            const content_num = page_num + 1;

            const resources = page.resources orelse "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>";

            const page_obj = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 {d} {d}] /Contents {d} 0 R /Resources {s} >>\nendobj\n", .{ page_num, pages_num, page.width, page.height, content_num, resources });
            defer self.allocator.free(page_obj);
            try buf.appendSlice(self.allocator, page_obj);
            offset += page_obj.len;

            _ = self.allocObjOffset(&offsets, offset);
            const content_obj = try std.fmt.allocPrint(self.allocator, "{d} 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ content_num, page.content.len, page.content });
            defer self.allocator.free(content_obj);
            try buf.appendSlice(self.allocator, content_obj);
            offset += content_obj.len;
        }

        // Info dictionary
        var info_num: u32 = 0;
        if (self.metadata.title != null or self.metadata.author != null) {
            info_num = self.allocObjOffset(&offsets, offset);
            var info: std.ArrayList(u8) = .empty;
            defer info.deinit(self.allocator);

            try appendFmt(self.allocator, &info, "{d} 0 obj\n<<", .{info_num});
            if (self.metadata.title) |t| {
                try info.appendSlice(self.allocator, "\n  /Title (");
                try appendPdfString(self.allocator, &info, t);
                try info.appendSlice(self.allocator, ")");
            }
            if (self.metadata.author) |a| {
                try info.appendSlice(self.allocator, "\n  /Author (");
                try appendPdfString(self.allocator, &info, a);
                try info.appendSlice(self.allocator, ")");
            }
            try info.appendSlice(self.allocator, "\n  /Producer (ZigPDF 1.0)");
            try info.appendSlice(self.allocator, "\n>>\nendobj\n");

            try buf.appendSlice(self.allocator, info.items);
            offset += info.items.len;
        }

        // Xref table
        const xref_offset = offset;
        try buf.appendSlice(self.allocator, "xref\n");
        try appendFmt(self.allocator, &buf, "0 {d}\n", .{offsets.items.len + 1});
        try buf.appendSlice(self.allocator, "0000000000 65535 f \n");

        for (offsets.items) |off| {
            try appendFmt(self.allocator, &buf, "{d:0>10} 00000 n \n", .{off});
        }

        // Trailer
        try buf.appendSlice(self.allocator, "trailer\n<<\n");
        try appendFmt(self.allocator, &buf, "  /Size {d}\n", .{offsets.items.len + 1});
        try appendFmt(self.allocator, &buf, "  /Root {d} 0 R\n", .{catalog_num});
        if (info_num > 0) {
            try appendFmt(self.allocator, &buf, "  /Info {d} 0 R\n", .{info_num});
        }
        try buf.appendSlice(self.allocator, ">>\n");

        try appendFmt(self.allocator, &buf, "startxref\n{d}\n%%EOF\n", .{xref_offset});

        // Write everything
        _ = try std.posix.write(fd, buf.items);
    }

    fn allocObjOffset(self: *Writer, offsets: *std.ArrayList(usize), offset: usize) u32 {
        offsets.append(self.allocator, offset) catch {};
        const num = self.next_obj_num;
        self.next_obj_num += 1;
        return num;
    }
};

// =========================================================================
// Helper Functions
// =========================================================================

/// Format and append to ArrayList (Zig 0.16 compatible)
fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buf.appendSlice(allocator, formatted);
}

/// Escape special characters for PDF strings
fn appendPdfString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '(' => try buf.appendSlice(allocator, "\\("),
            ')' => try buf.appendSlice(allocator, "\\)"),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Append current date in PDF format
fn appendCurrentDate(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    // Use clock_gettime for current timestamp
    const ts = std.posix.clock_gettime(.REALTIME) catch {
        // Fallback to a placeholder date if clock unavailable
        try buf.appendSlice(allocator, "20260101000000");
        return;
    };

    const secs: u64 = @intCast(ts.sec);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    try appendFmt(allocator, buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month) + 1, // month is 0-indexed
        month_day.day_index + 1, // day_index is 0-indexed
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Count digits in a number
fn countDigits(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var num = n;
    while (num > 0) : (num /= 10) {
        count += 1;
    }
    return count;
}

// =========================================================================
// Tests
// =========================================================================

test "writer creates valid PDF" {
    const allocator = std.testing.allocator;

    var writer = Writer.init(allocator);
    defer writer.deinit();

    try writer.setTitle("Test Document");
    try writer.setAuthor("Test Author");
    try writer.addTextPage(612, 792, "Hello, World!", 72, 720);

    // Write to temporary file
    const tmp_path = "/tmp/zigpdf_test_output.pdf";
    try writer.save(tmp_path);

    // Verify file was created and has content - read first 200 bytes
    const fd = try std.posix.open("/tmp/zigpdf_test_output.pdf", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    var buf: [200]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expect(n > 100);
    // Verify PDF header
    try std.testing.expectEqualStrings("%PDF-1.7", buf[0..8]);
    // Note: skip cleanup - file will be overwritten on next test run
}

test "pdf string escaping" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try appendPdfString(allocator, &buf, "Hello (World)");
    try std.testing.expectEqualStrings("Hello \\(World\\)", buf.items);
}
