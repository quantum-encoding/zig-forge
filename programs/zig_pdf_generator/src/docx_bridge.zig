//! Bridges between Word documents (via zig_docx) and the letter engine.
//!
//!   docxToLetter            DOCX + letter frame JSON → letter PDF
//!   docxToLegendTemplate    DOCX → zig_legend template + the placeholders it
//!                           uses + a draft legend, so a letter written in Word
//!                           with {CLIENT_NAME}-style fields becomes a template
//!   legendLetterToDocx      legend-letter input → editable .docx
//!
//! A Word body is converted to the Markdown dialect `markdown.zig` renders:
//! headings, paragraphs with bold/italic/links, bullet items, pipe tables, and
//! images on their own line (carried as in-memory body images, never files).
//!
//! Word stores a paragraph as a sequence of runs and splits text between runs
//! wherever an edit, a spelling mark or a formatting change happened, so a
//! placeholder typed as "{CLIENT_NAME}" can arrive as "{CLI" + "ENT_NAME}",
//! possibly with the two halves formatted differently, and autocorrect turns
//! straight quotes inside a tag into curly ones. The template conversion joins
//! each paragraph's runs, then for every `{…}` tag: gives the whole tag the
//! formatting of its opening brace (so no `**` lands inside it), maps curly
//! quotes to straight ones, non-breaking spaces to spaces, drops zero-width
//! characters and soft hyphens, trims spaces just inside the braces, and
//! accepts full-width braces. Text outside tags is left as written.

const std = @import("std");
const zdocx = @import("zig_docx");
const zl = @import("zig_legend");
const markdown = @import("markdown.zig");
const letter = @import("letter.zig");
const legend_letter = @import("legend_letter.zig");
const image_lib = @import("image.zig");

pub const Diagnostic = legend_letter.Diagnostic;

pub const Error = error{
    /// The bytes are not a DOCX: not a ZIP, or no word/document.xml.
    NotDocx,
    /// A JSON argument is malformed.
    InvalidInput,
    /// The converted template does not parse as a zig_legend template.
    TemplateInvalid,
    /// The legend letter did not render (see legend_letter.Error).
    RenderFailed,
    /// The letter engine failed to lay out the PDF.
    PdfFailed,
    /// zig_docx failed to write the .docx.
    DocxFailed,
    OutOfMemory,
};

/// A Word body as Markdown plus the images it shows.
pub const Converted = struct {
    markdown: []const u8,
    images: []const markdown.BodyImage,
};

pub const Mode = enum {
    /// Braces are ordinary text.
    letter,
    /// `{…}` tags are repaired for zig_legend (see the file comment).
    template,
};

// ---------------------------------------------------------------------------
// DOCX → Markdown
// ---------------------------------------------------------------------------

/// Convert DOCX bytes to Markdown. Everything is allocated from `arena`.
pub fn docxToMarkdown(arena: std.mem.Allocator, bytes: []const u8, mode: Mode, diag: *Diagnostic) Error!Converted {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
        diag.set("input is not a DOCX file (no ZIP signature)", .{});
        return error.NotDocx;
    }
    // ZipArchive takes ownership of its buffer; the arena owns the copy.
    const data = try arena.dupe(u8, bytes);
    var archive = zdocx.zip.ZipArchive.openFromMemory(arena, data) catch {
        diag.set("input is not a readable DOCX (ZIP) archive", .{});
        return error.NotDocx;
    };
    const doc = zdocx.parseDocument(arena, &archive) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDocx => {
            diag.set("input has no word/document.xml, so it is not a Word document", .{});
            return error.NotDocx;
        },
        else => {
            diag.set("could not read the Word document: {s}", .{@errorName(err)});
            return error.NotDocx;
        },
    };

    var c = Converter{ .arena = arena, .doc = &doc, .mode = mode };
    for (doc.elements) |*elem| switch (elem.*) {
        .paragraph => |*p| try c.paragraph(p),
        .table => |*t| try c.table(t),
    };
    return .{
        .markdown = try c.out.toOwnedSlice(arena),
        .images = try c.images.toOwnedSlice(arena),
    };
}

const Fmt = packed struct { bold: bool = false, italic: bool = false };

const Converter = struct {
    arena: std.mem.Allocator,
    doc: *const zdocx.Document,
    mode: Mode,
    out: std.ArrayList(u8) = .empty,
    images: std.ArrayList(markdown.BodyImage) = .empty,

    fn paragraph(self: *Converter, p: *const zdocx.Paragraph) !void {
        // Images first, each on its own line, in document order.
        for (p.runs) |run| if (run.image_rel_id) |rid| try self.image(rid);

        var text: std.ArrayList(u8) = .empty;
        var fmts: std.ArrayList(Fmt) = .empty;
        var links: std.ArrayList(?[]const u8) = .empty;
        for (p.runs) |run| {
            if (run.image_rel_id != null) continue;
            const link: ?[]const u8 = if (run.hyperlink_url) |u| (if (zdocx.mdx.isSafeLinkUrl(u)) u else null) else null;
            for (run.text) |ch| {
                try text.append(self.arena, ch);
                try fmts.append(self.arena, .{ .bold = run.bold, .italic = run.italic });
                try links.append(self.arena, link);
            }
        }
        if (self.mode == .template) try repairTags(self.arena, &text, &fmts, &links);

        // A line break inside a paragraph starts a new Markdown paragraph
        // (markdown.zig joins wrapped lines with a space).
        var start: usize = 0;
        while (start <= text.items.len) {
            const nl = std.mem.indexOfScalarPos(u8, text.items, start, '\n') orelse text.items.len;
            const line = text.items[start..nl];
            if (std.mem.trim(u8, line, " \t").len > 0) {
                const prefix: []const u8 = switch (p.style) {
                    .heading1, .title => "# ",
                    .heading2, .subtitle => "## ",
                    .heading3 => "### ",
                    .heading4, .heading5, .heading6 => "#### ",
                    else => if (p.is_list_item or p.style == .list_paragraph) "- " else "",
                };
                try self.out.appendSlice(self.arena, prefix);
                try self.inline_(line, fmts.items[start..nl], links.items[start..nl], false);
                try self.out.appendSlice(self.arena, "\n\n");
            }
            start = nl + 1;
        }
    }

    fn table(self: *Converter, t: *const zdocx.Table) !void {
        if (t.rows.len == 0) return;
        for (t.rows, 0..) |row, ri| {
            try self.out.append(self.arena, '|');
            for (row.cells) |cell| {
                try self.out.append(self.arena, ' ');
                for (cell.paragraphs, 0..) |*cp, pi| {
                    if (pi > 0) try self.out.append(self.arena, ' ');
                    var text: std.ArrayList(u8) = .empty;
                    var fmts: std.ArrayList(Fmt) = .empty;
                    var links: std.ArrayList(?[]const u8) = .empty;
                    for (cp.runs) |run| {
                        if (run.image_rel_id != null) continue;
                        for (run.text) |ch| {
                            try text.append(self.arena, if (ch == '\n' or ch == '\t') ' ' else ch);
                            try fmts.append(self.arena, .{ .bold = run.bold, .italic = run.italic });
                            try links.append(self.arena, null);
                        }
                    }
                    if (self.mode == .template) try repairTags(self.arena, &text, &fmts, &links);
                    try self.inline_(text.items, fmts.items, links.items, true);
                }
                try self.out.appendSlice(self.arena, " |");
            }
            try self.out.append(self.arena, '\n');
            if (ri == 0) {
                try self.out.append(self.arena, '|');
                for (row.cells) |_| try self.out.appendSlice(self.arena, "---|");
                try self.out.append(self.arena, '\n');
            }
        }
        try self.out.append(self.arena, '\n');
    }

    /// Emit text grouped by formatting and link. Whitespace at the edges of
    /// a formatted group goes outside its markers, where Markdown needs it.
    /// In a table cell, a `|` outside a tag would end the cell, so it
    /// becomes `/`.
    fn inline_(self: *Converter, text: []const u8, fmts: []const Fmt, links: []const ?[]const u8, in_cell: bool) !void {
        var tag_depth: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            var j = i + 1;
            while (j < text.len and fmts[j] == fmts[i] and eqlLink(links[j], links[i])) j += 1;
            const seg = text[i..j];
            const f = fmts[i];
            const marker: []const u8 = if (f.bold and f.italic) "***" else if (f.bold) "**" else if (f.italic) "*" else "";
            const lead = seg.len - std.mem.trimStart(u8, seg, " \t").len;
            const core = std.mem.trim(u8, seg, " \t");
            const trail = seg.len - lead - core.len;
            try self.spaces(seg[0..lead]);
            if (core.len > 0) {
                if (links[i] != null) try self.out.append(self.arena, '[');
                try self.out.appendSlice(self.arena, marker);
                for (core) |ch| {
                    if (ch == '{') tag_depth += 1;
                    if (ch == '}' and tag_depth > 0) tag_depth -= 1;
                    const out_ch: u8 = if (ch == '\t') ' ' else if (in_cell and ch == '|' and tag_depth == 0) '/' else ch;
                    try self.out.append(self.arena, out_ch);
                }
                try self.out.appendSlice(self.arena, marker);
                if (links[i]) |url| {
                    try self.out.appendSlice(self.arena, "](");
                    for (url) |ch| switch (ch) {
                        ' ' => try self.out.appendSlice(self.arena, "%20"),
                        '(' => try self.out.appendSlice(self.arena, "%28"),
                        ')' => try self.out.appendSlice(self.arena, "%29"),
                        else => try self.out.append(self.arena, ch),
                    };
                    try self.out.append(self.arena, ')');
                }
            }
            try self.spaces(seg[seg.len - trail ..]);
            i = j;
        }
    }

    fn spaces(self: *Converter, ws: []const u8) !void {
        for (ws) |_| try self.out.append(self.arena, ' ');
    }

    fn image(self: *Converter, rid: []const u8) !void {
        const rel = zdocx.rels.findRelById(self.doc.relationships, rid) orelse return;
        var bytes: ?[]const u8 = null;
        for (self.doc.media) |m| {
            if (zdocx.mediaNameMatches(m.name, rel.target)) {
                bytes = m.data;
                break;
            }
        }
        const data = bytes orelse return;
        const base = zdocx.mediaBasename(rel.target);
        const name = try std.fmt.allocPrint(self.arena, "{d}-{s}", .{ self.images.items.len + 1, base });
        try self.images.append(self.arena, .{ .name = name, .bytes = data });
        try self.out.print(self.arena, "![Image {d}]({s})\n\n", .{ self.images.items.len, name });
    }
};

fn eqlLink(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------
// Placeholder repair
// ---------------------------------------------------------------------------

const max_tag_len = 256;

/// Brace at `s[i..]`: 1 for ASCII, 3 for the full-width form, 0 for none.
fn braceLen(s: []const u8, i: usize, open: bool) usize {
    if (s[i] == (if (open) @as(u8, '{') else '}')) return 1;
    const fw = if (open) "\u{FF5B}" else "\u{FF5D}";
    if (std.mem.startsWith(u8, s[i..], fw)) return fw.len;
    return 0;
}

/// Rewrite every `{…}` tag in a paragraph (see the file comment), keeping
/// the per-byte formatting and link arrays aligned with the text.
fn repairTags(a: std.mem.Allocator, text: *std.ArrayList(u8), fmts: *std.ArrayList(Fmt), links: *std.ArrayList(?[]const u8)) !void {
    const s = text.items;
    var out_t: std.ArrayList(u8) = .empty;
    var out_f: std.ArrayList(Fmt) = .empty;
    var out_l: std.ArrayList(?[]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const ob = braceLen(s, i, true);
        if (ob == 0) {
            try out_t.append(a, s[i]);
            try out_f.append(a, fmts.items[i]);
            try out_l.append(a, links.items[i]);
            i += 1;
            continue;
        }
        // `{{` is a literal brace; copy both.
        if (ob == 1 and i + 1 < s.len and s[i + 1] == '{') {
            for (0..2) |k| {
                try out_t.append(a, s[i + k]);
                try out_f.append(a, fmts.items[i + k]);
                try out_l.append(a, links.items[i + k]);
            }
            i += 2;
            continue;
        }
        // Find the closing brace on the same line, before any other opening.
        var j = i + ob;
        var close_len: usize = 0;
        while (j < s.len and j - i <= max_tag_len) : (j += 1) {
            if (s[j] == '\n' or braceLen(s, j, true) != 0) break;
            close_len = braceLen(s, j, false);
            if (close_len != 0) break;
        }
        if (close_len == 0) {
            // Not a tag: copy the brace through unchanged.
            for (0..ob) |k| {
                try out_t.append(a, s[i + k]);
                try out_f.append(a, fmts.items[i]);
                try out_l.append(a, links.items[i]);
            }
            i += ob;
            continue;
        }
        const inner = try normalizeTagInner(a, s[i + ob .. j]);
        const f = fmts.items[i];
        const l = links.items[i];
        try out_t.append(a, '{');
        try out_t.appendSlice(a, inner);
        try out_t.append(a, '}');
        for (0..inner.len + 2) |_| {
            try out_f.append(a, f);
            try out_l.append(a, l);
        }
        i = j + close_len;
    }
    text.* = out_t;
    fmts.* = out_f;
    links.* = out_l;
}

/// Undo Word's typing aids inside a tag: curly quotes → straight, no-break
/// spaces → spaces, zero-width characters and soft hyphens dropped, spaces
/// just inside the braces trimmed.
fn normalizeTagInner(a: std.mem.Allocator, inner: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(inner).iterator();
    while (it.nextCodepointSlice()) |cps| {
        const cp = std.unicode.utf8Decode(cps) catch {
            try out.appendSlice(a, cps);
            continue;
        };
        switch (cp) {
            0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0xFF02 => try out.append(a, '"'),
            0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0xFF07 => try out.append(a, '\''),
            0x00A0, 0x202F, 0x2007, 0x3000 => try out.append(a, ' '),
            0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD => {},
            0xFF1D => try out.append(a, '='),
            0xFF5C => try out.append(a, '|'),
            else => try out.appendSlice(a, cps),
        }
    }
    return std.mem.trim(u8, out.items, " \t");
}

// ---------------------------------------------------------------------------
// DOCX → legend template
// ---------------------------------------------------------------------------

pub const TemplateResult = struct {
    template: []const u8,
    /// Every name the template reads, in first-use order.
    placeholders: []const []const u8,
    /// A legend declaring each placeholder, typed from how the template uses
    /// it; review before use.
    legend_toml: []const u8,
    images: []const markdown.BodyImage,
};

/// DOCX → zig_legend template. Fails with the parser's reason when the
/// repaired text is not a valid template (e.g. an unclosed `{?…}` block).
pub fn docxToLegendTemplate(arena: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!TemplateResult {
    const conv = try docxToMarkdown(arena, bytes, .template, diag);
    var ld = zl.Diag{};
    const tpl = zl.template.parse(arena, conv.markdown, .{}, &ld) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("the Word text is not a valid template: {s}", .{ld.text()});
            return error.TemplateInvalid;
        },
    };
    const names = try tpl.variables(arena);
    return .{
        .template = conv.markdown,
        .placeholders = names,
        .legend_toml = try draftLegend(arena, &tpl, names),
        .images = conv.images,
    };
}

const Usage = struct {
    kind: enum { string, date, money, list, bool, enum_ } = .string,
    values: std.ArrayList([]const u8) = .empty,
};

fn noteUsage(a: std.mem.Allocator, nodes: []const zl.template.Node, names: []const []const u8, uses: []Usage) !void {
    for (nodes) |n| switch (n) {
        .text => {},
        .variable => |v| {
            const u = &uses[indexOf(names, v.name)];
            for (v.filters) |f| {
                const k: ?@TypeOf(u.kind) = if (eq(f.name, "long") or eq(f.name, "us") or eq(f.name, "uk"))
                    .date
                else if (eq(f.name, "plain"))
                    .money
                else if (eq(f.name, "bullets") or eq(f.name, "lines") or eq(f.name, "count"))
                    .list
                else
                    null;
                if (k) |kind| if (u.kind == .string or u.kind == .bool) {
                    u.kind = kind;
                };
            }
        },
        .cond => |c| {
            const u = &uses[indexOf(names, c.name)];
            switch (c.op) {
                .truthy => if (u.kind == .string) {
                    u.kind = .bool;
                },
                .eq, .ne => {
                    u.kind = .enum_;
                    for (u.values.items) |existing| {
                        if (eq(existing, c.value)) break;
                    } else try u.values.append(a, c.value);
                },
            }
            try noteUsage(a, c.then_nodes, names, uses);
            try noteUsage(a, c.else_nodes, names, uses);
        },
    };
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn indexOf(names: []const []const u8, name: []const u8) usize {
    for (names, 0..) |n, i| if (eq(n, name)) return i;
    unreachable; // names come from the same template
}

/// A TOML legend for the placeholders: `{?X=v}` makes X an enum of the values
/// compared against, `{?X}` a bool, `|long` a date, `|plain` money (GBP), a
/// list filter a list; everything else a string. All are required.
fn draftLegend(a: std.mem.Allocator, tpl: *const zl.Template, names: []const []const u8) ![]const u8 {
    const uses = try a.alloc(Usage, names.len);
    for (uses) |*u| u.* = .{};
    try noteUsage(a, tpl.nodes, names, uses);

    var w = std.Io.Writer.Allocating.init(a);
    writeLegend(&w.writer, names, uses) catch return error.OutOfMemory;
    return w.toOwnedSlice() catch error.OutOfMemory;
}

fn writeLegend(out: *std.Io.Writer, names: []const []const u8, uses: []const Usage) !void {
    try out.print("# Drafted from the {d} placeholder(s) in a Word template. Check each type,\n# add descriptions and defaults, and add [[scenario]] tables as needed.\n", .{names.len});
    for (names, uses) |name, u| {
        try out.print("\n[[var]]\nname = \"{s}\"\n", .{name});
        switch (u.kind) {
            .string => try out.writeAll("type = \"string\"\n"),
            .date => try out.writeAll("type = \"date\"\n"),
            .money => try out.writeAll("type = \"money\"\ncurrency = \"GBP\"\n"),
            .list => try out.writeAll("type = \"list\"\n"),
            .bool => try out.writeAll("type = \"bool\"\n"),
            .enum_ => {
                try out.writeAll("type = \"enum\"\nvalues = [");
                for (u.values.items, 0..) |v, i| {
                    if (i > 0) try out.writeAll(", ");
                    try std.json.Stringify.value(v, .{}, out);
                }
                try out.writeAll("]\n");
            },
        }
        try out.writeAll("required = true\n");
    }
}

/// The template result as JSON: `{"template", "placeholders", "legend_toml",
/// "images": [{"name", "data": "data:image/…;base64,…"}]}`.
pub fn docxToLegendTemplateJson(allocator: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try docxToLegendTemplate(arena, bytes, diag);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeTemplateJson(arena, &s, r) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeTemplateJson(arena: std.mem.Allocator, s: *std.json.Stringify, r: TemplateResult) !void {
    try s.beginObject();
    try s.objectField("template");
    try s.write(r.template);
    try s.objectField("placeholders");
    try s.write(r.placeholders);
    try s.objectField("legend_toml");
    try s.write(r.legend_toml);
    try s.objectField("images");
    try s.beginArray();
    for (r.images) |img| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(img.name);
        try s.objectField("data");
        try s.write(try dataUrl(arena, img.bytes));
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn dataUrl(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const mime = if (image_lib.detectFormat(bytes)) |f| switch (f) {
        .jpeg => "image/jpeg",
        else => "image/png",
    } else "application/octet-stream";
    const enc = std.base64.standard.Encoder;
    const prefix = try std.fmt.allocPrint(a, "data:{s};base64,", .{mime});
    const buf = try a.alloc(u8, prefix.len + enc.calcSize(bytes.len));
    @memcpy(buf[0..prefix.len], prefix);
    _ = enc.encode(buf[prefix.len..], bytes);
    return buf;
}

// ---------------------------------------------------------------------------
// DOCX → letter PDF
// ---------------------------------------------------------------------------

/// A Word document's body laid out as a letter. `letter_json` is the letter
/// frame (the `zigpdf_generate_letter` fields other than `body_markdown`;
/// may be empty for none). The Word images come across as body images.
pub fn docxToLetter(allocator: std.mem.Allocator, bytes: []const u8, letter_json: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const conv = try docxToMarkdown(arena, bytes, .letter, diag);
    var in = markdown.LetterInput{};
    var images: std.ArrayList(markdown.BodyImage) = .empty;
    try images.appendSlice(arena, conv.images);
    if (std.mem.trim(u8, letter_json, " \t\r\n").len > 0) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, letter_json, .{}) catch {
            diag.set("letter JSON is not valid JSON", .{});
            return error.InvalidInput;
        };
        if (root != .object) {
            diag.set("letter JSON must be an object", .{});
            return error.InvalidInput;
        }
        in = letter.letterInputFromObject(root.object);
        try images.appendSlice(arena, try letter.bodyImagesFromObject(arena, root.object));
    }
    in.body_markdown = conv.markdown;
    in.images = images.items;
    return markdown.generateLetter(allocator, in) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            diag.set("letter layout failed: {s}", .{@errorName(err)});
            return error.PdfFailed;
        },
    };
}

// ---------------------------------------------------------------------------
// Legend letter → DOCX
// ---------------------------------------------------------------------------

/// Render a legend letter (same input as `legend_letter.generate`) and write
/// it as an editable .docx: letterhead (an image from
/// `letter.letterhead_image`, else the company name, address and contact as
/// text), date, reference, recipient, subject, body, closing and signature.
/// Body images in `letter.images` are embedded. Bytes owned by `allocator`.
pub fn legendLetterToDocx(allocator: std.mem.Allocator, json_str: []const u8, diag: *Diagnostic) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = legend_letter.renderText(arena, json_str, diag) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidInput => error.InvalidInput,
        else => error.RenderFailed,
    };
    const L = r.input;

    // The letterhead image, if the frame carries one.
    var letterhead: ?[]const u8 = null;
    var letterhead_ext: [:0]const u8 = "png";
    if (letterheadSource(arena, json_str)) |src| {
        const raw = image_lib.decodeBase64(arena, src) catch {
            diag.set("letter.letterhead_image is not base64 or a data: URL", .{});
            return error.InvalidInput;
        };
        const fmt = image_lib.detectFormat(raw) orelse {
            diag.set("letter.letterhead_image is not a PNG or JPEG", .{});
            return error.InvalidInput;
        };
        letterhead = raw;
        letterhead_ext = if (fmt == .jpeg) "jpg" else "png";
    }

    var md: std.ArrayList(u8) = .empty;
    const w = struct {
        fn para(a: std.mem.Allocator, list: *std.ArrayList(u8), prefix: []const u8, text: []const u8, suffix: []const u8) !void {
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
            try list.appendSlice(a, prefix);
            try list.appendSlice(a, text);
            try list.appendSlice(a, suffix);
            try list.appendSlice(a, "\n\n");
        }
        fn lines(a: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8, bold_first: bool) !void {
            const sep: u8 = if (std.mem.indexOfScalar(u8, text, '\n') != null) '\n' else '|';
            var it = std.mem.splitScalar(u8, text, sep);
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                try para(a, list, if (first and bold_first) "**" else "", line, if (first and bold_first) "**" else "");
                first = false;
            }
        }
    };
    if (letterhead == null) {
        try w.para(arena, &md, "# ", L.company_name, "");
        var addr: std.ArrayList(u8) = .empty;
        const sep: u8 = if (std.mem.indexOfScalar(u8, L.company_address, '\n') != null) '\n' else '|';
        var it = std.mem.splitScalar(u8, L.company_address, sep);
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (addr.items.len > 0) try addr.appendSlice(arena, ", ");
            try addr.appendSlice(arena, line);
        }
        try w.para(arena, &md, "", addr.items, "");
        try w.para(arena, &md, "", L.sender_contact, "");
    }
    try w.para(arena, &md, "", L.date, "");
    try w.para(arena, &md, "Ref: ", L.reference, "");
    try w.lines(arena, &md, if (L.recipient_address.len > 0)
        try std.fmt.allocPrint(arena, "{s}|{s}", .{ L.recipient_name, pipeLines(arena, L.recipient_address) catch return error.OutOfMemory })
    else
        L.recipient_name, true);
    try w.para(arena, &md, "**Re: ", L.subject, "**");
    try md.appendSlice(arena, r.body_markdown);
    try md.appendSlice(arena, "\n\n");
    try w.para(arena, &md, "", L.closing, "");
    try w.para(arena, &md, "**", L.signature_name, "**");
    try w.para(arena, &md, "", L.signature_title, "");

    // Body images: decoded host images matched by name, as zig_docx expects.
    var host: std.ArrayList(zdocx.ffi.ZigDocxInputImage) = .empty;
    for (L.images) |img| {
        const raw = if (img.bytes.len > 0) img.bytes else image_lib.decodeBase64(arena, img.base64) catch continue;
        try host.append(arena, .{ .name = try arena.dupeZ(u8, img.name), .data = raw.ptr, .len = raw.len });
    }

    const opts = zdocx.ffi.ZigDocxOptions{
        .title = try arena.dupeZ(u8, L.subject),
        .author = try arena.dupeZ(u8, L.company_name),
        .date = try arena.dupeZ(u8, L.date),
        .letterhead_data = if (letterhead) |lh| lh.ptr else null,
        .letterhead_len = if (letterhead) |lh| lh.len else 0,
        .letterhead_ext = letterhead_ext.ptr,
    };
    const res = zdocx.ffi.zig_docx_md_to_docx_with_images(md.items.ptr, md.items.len, &opts, host.items.ptr, host.items.len);
    if (res.data == null) {
        const msg: []const u8 = if (res.error_msg) |e| std.mem.span(e) else "unknown error";
        diag.set("writing the .docx failed: {s}", .{msg});
        if (res.error_msg) |e| zdocx.ffi.zig_docx_free_string(@constCast(e));
        return error.DocxFailed;
    }
    defer zdocx.ffi.zig_docx_free(res.data, res.len);
    return allocator.dupe(u8, res.data.?[0..res.len]);
}

/// `letter.letterhead_image` from a legend-letter input, if present.
fn letterheadSource(arena: std.mem.Allocator, json_str: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch return null;
    if (root != .object) return null;
    const lv = root.object.get("letter") orelse return null;
    if (lv != .object) return null;
    const v = lv.object.get("letterhead_image") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// Address lines separated by newlines or `|`, as `|`-separated text.
fn pipeLines(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try a.dupe(u8, text);
    for (out) |*c| if (c.* == '\n') {
        c.* = '|';
    };
    return out;
}
