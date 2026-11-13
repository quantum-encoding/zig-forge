// Copyright (c) 2026 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Redline sheet: a proofreading table that shows each fix as before → after.
//!
//! The caller passes plain text; the sheet word-diffs it (word_diff.zig) and
//! marks what changed. Two ways to show a change:
//!
//!   redline  — three columns, Where / Now / Should be. In "Now" the removed
//!              words are red, struck through, on light red; in "Should be"
//!              the added words are green and bold on light green. A note
//!              goes under the new text in grey italics.
//!   tracked  — Where / Change (/ Note). The change is real Word tracked
//!              changes (w:del / w:ins with an author and date), so the
//!              reader accepts or rejects each one in Word.
//!
//! Either way the page is A4 landscape (or portrait), fixes come in groups
//! with a dark row naming each group, the header row repeats on every page
//! and no row splits across a page.
//!
//! JSON input (every key but `groups`/`items` optional; colours are six hex
//! digits with or without `#`, or a name zig_docx's Markdown knows):
//!
//!   {
//!     "title": "Proofread: 12 Example Road",
//!     "key": "{--Struck through--} is the text now; {++marked like this++} is the suggested change.",
//!     "mode": "redline",                 // or "tracked"
//!     "author": "Reviewer",              // tracked changes only
//!     "date": "2026-11-13",              // tracked changes only; or a full xsd:dateTime
//!     "orientation": "landscape",        // or "portrait"
//!     "labels": { "where": "Where", "before": "Now", "after": "Should be",
//!                 "change": "Change", "note": "Note" },
//!     "colors": { "removed": "A00000", "removed_fill": "FDDADA",
//!                 "added": "006400", "added_fill": "D7F5D7", "note": "555555",
//!                 "group_fill": "222222", "group_text": "FFFFFF",
//!                 "header_fill": "EDEDED", "border": "BBBBBB" },
//!     "groups": [
//!       { "name": "Flat 1", "items": [
//!         { "where": "Action 3", "before": "kept free free from storage",
//!           "after": "kept free from storage", "note": "Word repeated." } ] } ]
//!   }
//!
//! `key` is inline Markdown (zig_docx's syntax, CriticMarkup in the sheet's
//! colours); leave it out for the default, set it to "" for none. A top-level
//! `items` array is one group with no name row.
//!
//! compareDocx builds the same sheet from two .docx files: their paragraphs
//! are lined up, and each paragraph that changed is one item, grouped under
//! the heading it falls under.

const std = @import("std");
const docx = @import("docx.zig");
const writer = @import("docx_writer.zig");
const md_parser = @import("md_parser.zig");
const word_diff = @import("word_diff.zig");
const zip = @import("zip.zig");

const Rgb = docx.Rgb;
const Allocator = std.mem.Allocator;
const Buf = std.ArrayListUnmanaged(u8);

// ─── Model ─────────────────────────────────────────────────────────

pub const Item = struct {
    where: []const u8 = "",
    before: []const u8 = "",
    after: []const u8 = "",
    note: []const u8 = "",
};

pub const Group = struct {
    /// Shown in a dark row above the items; "" for no row.
    name: []const u8 = "",
    items: []const Item = &.{},
};

pub const Mode = enum { redline, tracked };
pub const Orientation = enum { landscape, portrait };

pub const Labels = struct {
    where: []const u8 = "Where",
    before: []const u8 = "Now",
    after: []const u8 = "Should be",
    change: []const u8 = "Change",
    note: []const u8 = "Note",
};

pub const Colors = struct {
    removed: Rgb = "A00000".*,
    removed_fill: Rgb = "FDDADA".*,
    added: Rgb = "006400".*,
    added_fill: Rgb = "D7F5D7".*,
    note: Rgb = "555555".*,
    group_fill: Rgb = "222222".*,
    group_text: Rgb = "FFFFFF".*,
    header_fill: Rgb = "EDEDED".*,
    border: Rgb = "BBBBBB".*,

    /// The look of removed and added words, shared with Markdown's CriticMarkup.
    pub fn marks(self: Colors) md_parser.MarkColors {
        return .{
            .removed = self.removed,
            .removed_fill = self.removed_fill,
            .added = self.added,
            .added_fill = self.added_fill,
        };
    }
};

pub const Sheet = struct {
    title: []const u8 = "",
    /// Inline Markdown under the title. Null: the default for the mode.
    key: ?[]const u8 = null,
    mode: Mode = .redline,
    /// Who made the tracked changes.
    author: []const u8 = "Reviewer",
    /// When, as an xsd:dateTime ("2026-11-13T00:00:00Z"); "" leaves it out.
    date: []const u8 = "",
    orientation: Orientation = .landscape,
    labels: Labels = .{},
    colors: Colors = .{},
    groups: []const Group = &.{},
};

pub const default_redline_key = "{--Struck through--} is the text now; {++marked like this++} is the suggested change.";
pub const default_tracked_key = "Each change is a tracked change: accept or reject it in Word (Review, then Accept or Reject).";

pub const Error = error{
    InvalidJson,
    ExpectedObject,
    ExpectedArray,
    ExpectedString,
    InvalidColor,
    InvalidDate,
    InvalidMode,
    InvalidOrientation,
};

// ─── JSON ──────────────────────────────────────────────────────────

/// Parse a sheet from JSON (see the file header). Every string in the
/// result lives in `arena`, which must outlive the Sheet.
pub fn parseJson(arena: Allocator, json: []const u8) (Error || Allocator.Error)!Sheet {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (root != .object) return error.ExpectedObject;
    const obj = root.object;

    var sheet = try parseOptions(arena, obj);

    var groups: std.ArrayListUnmanaged(Group) = .empty;
    if (obj.get("items")) |v| {
        if (v != .null) try groups.append(arena, .{ .items = try parseItems(arena, v) });
    }
    if (obj.get("groups")) |v| {
        if (v != .null) {
            if (v != .array) return error.ExpectedArray;
            for (v.array.items) |g| {
                if (g != .object) return error.ExpectedObject;
                try groups.append(arena, .{
                    .name = try str(g.object, "name") orelse "",
                    .items = if (g.object.get("items")) |iv| try parseItems(arena, iv) else &.{},
                });
            }
        }
    }
    sheet.groups = try groups.toOwnedSlice(arena);
    return sheet;
}

/// Everything but the groups: what compareDocx takes as its options.
pub fn parseOptionsJson(arena: Allocator, json: []const u8) (Error || Allocator.Error)!Sheet {
    if (std.mem.trim(u8, json, " \t\r\n").len == 0) return .{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (root != .object) return error.ExpectedObject;
    return parseOptions(arena, root.object);
}

fn parseOptions(arena: Allocator, obj: std.json.ObjectMap) (Error || Allocator.Error)!Sheet {
    var sheet = Sheet{};
    if (try str(obj, "title")) |v| sheet.title = v;
    if (try str(obj, "key")) |v| sheet.key = v;
    if (try str(obj, "author")) |v| sheet.author = v;
    if (try str(obj, "date")) |v| sheet.date = try normalizeDate(arena, v);
    if (try str(obj, "mode")) |v| {
        sheet.mode = std.meta.stringToEnum(Mode, v) orelse return error.InvalidMode;
    }
    if (try str(obj, "orientation")) |v| {
        sheet.orientation = std.meta.stringToEnum(Orientation, v) orelse return error.InvalidOrientation;
    }
    if (obj.get("labels")) |lv| {
        if (lv != .null) {
            if (lv != .object) return error.ExpectedObject;
            inline for (comptime std.meta.fieldNames(Labels)) |name| {
                if (try str(lv.object, name)) |v| @field(sheet.labels, name) = v;
            }
        }
    }
    if (obj.get("colors")) |cv| {
        if (cv != .null) {
            if (cv != .object) return error.ExpectedObject;
            inline for (comptime std.meta.fieldNames(Colors)) |name| {
                if (try str(cv.object, name)) |v| {
                    @field(sheet.colors, name) = docx.parseRgb(v) orelse
                        md_parser.parseColor(v) orelse return error.InvalidColor;
                }
            }
        }
    }
    return sheet;
}

fn parseItems(arena: Allocator, v: std.json.Value) (Error || Allocator.Error)![]const Item {
    if (v == .null) return &.{};
    if (v != .array) return error.ExpectedArray;
    const items = try arena.alloc(Item, v.array.items.len);
    for (v.array.items, items) |iv, *item| {
        if (iv != .object) return error.ExpectedObject;
        item.* = .{
            .where = try str(iv.object, "where") orelse "",
            .before = try str(iv.object, "before") orelse "",
            .after = try str(iv.object, "after") orelse "",
            .note = try str(iv.object, "note") orelse "",
        };
    }
    return items;
}

/// The string at `key`: null when absent or JSON null, an error for any
/// other type.
fn str(obj: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.ExpectedString,
    };
}

/// `date` as the xsd:dateTime Word reads in w:date. A bare date gains
/// midnight UTC; a timestamp must be YYYY-MM-DDTHH:MM[:SS[.fff]] with an
/// optional Z or ±HH:MM. "" stays "" (the attribute is left out).
pub fn normalizeDate(arena: Allocator, date: []const u8) (Error || Allocator.Error)![]const u8 {
    if (date.len == 0) return date;
    if (date.len < 10 or !digits(date[0..4]) or date[4] != '-' or !digits(date[5..7]) or
        date[7] != '-' or !digits(date[8..10])) return error.InvalidDate;
    if (date.len == 10) return std.mem.concat(arena, u8, &.{ date, "T00:00:00Z" });

    var i: usize = 10;
    if (date[i] != 'T') return error.InvalidDate;
    i += 1;
    if (date.len < i + 5 or !digits(date[i .. i + 2]) or date[i + 2] != ':' or !digits(date[i + 3 .. i + 5]))
        return error.InvalidDate;
    i += 5;
    var has_seconds = false;
    if (i < date.len and date[i] == ':') {
        if (date.len < i + 3 or !digits(date[i + 1 .. i + 3])) return error.InvalidDate;
        i += 3;
        has_seconds = true;
        if (i < date.len and date[i] == '.') {
            i += 1;
            const frac_start = i;
            while (i < date.len and std.ascii.isDigit(date[i])) i += 1;
            if (i == frac_start) return error.InvalidDate;
        }
    }
    const zone = date[i..];
    const zone_ok = zone.len == 0 or std.mem.eql(u8, zone, "Z") or
        (zone.len == 6 and (zone[0] == '+' or zone[0] == '-') and digits(zone[1..3]) and zone[3] == ':' and digits(zone[4..6]));
    if (!zone_ok) return error.InvalidDate;
    if (has_seconds) return date;
    // xsd:dateTime requires seconds.
    return std.mem.concat(arena, u8, &.{ date[0..i], ":00", zone });
}

fn digits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ─── Page geometry ─────────────────────────────────────────────────

/// A4 in twentieths of a point, and the margin on every side.
const A4_SHORT: u16 = 11906;
const A4_LONG: u16 = 16838;
const MARGIN: u16 = 720;

fn textWidth(o: Orientation) u16 {
    return (if (o == .landscape) A4_LONG else A4_SHORT) - 2 * MARGIN;
}

/// Column widths: Where takes 17% of the text width, the rest is shared.
fn columnWidths(sheet: *const Sheet, has_notes: bool, out: *[3]u16) []const u16 {
    const total = textWidth(sheet.orientation);
    const where: u16 = @intCast(@as(u32, total) * 17 / 100);
    out[0] = where;
    switch (sheet.mode) {
        .redline => {
            out[1] = (total - where) / 2;
            out[2] = total - where - out[1];
            return out[0..3];
        },
        .tracked => {
            if (!has_notes) {
                out[1] = total - where;
                return out[0..2];
            }
            out[1] = @intCast(@as(u32, total - where) * 7 / 10);
            out[2] = total - where - out[1];
            return out[0..3];
        },
    }
}

// ─── Generation ────────────────────────────────────────────────────

/// The sheet as .docx bytes, allocated with `allocator` (the caller frees
/// them). The sheet is laid out as a docx.Document and written by
/// docx_writer, the writer every other document here goes through; working
/// memory is an arena released before returning.
pub fn generate(allocator: Allocator, sheet: *const Sheet) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try buildDocument(arena, sheet);
    const bytes = try writer.generateDocx(arena, &doc, .{
        .title = sheet.title,
        .author = sheet.author,
        .style = .sheet,
        .a4 = true,
        .landscape = sheet.orientation == .landscape,
        .margin = MARGIN,
        .revision_author = sheet.author,
        .revision_date = sheet.date,
    });
    return allocator.dupe(u8, bytes);
}

fn hasNonSpace(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return true;
    }
    return false;
}

/// Builds the sheet's elements; everything lives in the arena.
const Builder = struct {
    arena: Allocator,

    fn paragraph(self: Builder, runs: []const docx.Run, opts: struct { keep_next: bool = false, after: ?u16 = null }) !docx.Paragraph {
        return .{
            .runs = try self.arena.dupe(docx.Run, runs),
            .keep_next = opts.keep_next,
            .spacing_after = opts.after,
        };
    }

    /// `runs` with each stretch of neighbours that look the same joined into one.
    fn joined(self: Builder, runs: []const docx.Run) ![]docx.Run {
        var out: std.ArrayListUnmanaged(docx.Run) = .empty;
        var i: usize = 0;
        while (i < runs.len) {
            var j = i + 1;
            while (j < runs.len and runs[j].revision == runs[i].revision and md_parser.sameLook(runs[i], runs[j])) j += 1;
            var run = runs[i];
            if (j - i > 1) {
                var text: Buf = .empty;
                for (runs[i..j]) |r| try text.appendSlice(self.arena, r.text);
                run.text = text.items;
            }
            try out.append(self.arena, run);
            i = j;
        }
        return out.toOwnedSlice(self.arena);
    }

    fn cell(self: Builder, paragraphs: []const docx.Paragraph, fill: ?[]const u8, span: u16) !docx.TableCell {
        return .{ .paragraphs = try self.arena.dupe(docx.Paragraph, paragraphs), .shading = fill, .col_span = span };
    }
};

fn buildDocument(arena: Allocator, sheet: *const Sheet) !docx.Document {
    const b = Builder{ .arena = arena };
    const marks = sheet.colors.marks();
    var elements: std.ArrayListUnmanaged(docx.Element) = .empty;

    if (sheet.title.len > 0) {
        try elements.append(arena, .{ .paragraph = try b.paragraph(&.{.{ .text = sheet.title, .bold = true, .half_points = 30 }}, .{ .after = 120 }) });
    }

    const key = sheet.key orelse switch (sheet.mode) {
        .redline => default_redline_key,
        .tracked => default_tracked_key,
    };
    if (key.len > 0) {
        const runs = try md_parser.parseInlineMarked(arena, key, marks);
        // The sheet has no relationships for links or pictures: their text stays.
        for (runs) |*r| {
            r.hyperlink_url = null;
            r.image_rel_id = null;
        }
        try elements.append(arena, .{ .paragraph = .{ .runs = runs, .spacing_after = 160 } });
    }

    var has_notes = false;
    for (sheet.groups) |g| {
        for (g.items) |it| {
            if (it.note.len > 0) has_notes = true;
        }
    }
    var widths_buf: [3]u16 = undefined;
    const widths = columnWidths(sheet, has_notes, &widths_buf);
    const columns: u16 = @intCast(widths.len);

    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;

    // Header row, repeated at the top of every page.
    const labels = sheet.labels;
    const header_texts: [3][]const u8 = switch (sheet.mode) {
        .redline => .{ labels.where, labels.before, labels.after },
        .tracked => .{ labels.where, labels.change, labels.note },
    };
    var header_cells: [3]docx.TableCell = undefined;
    for (header_cells[0..widths.len], header_texts[0..widths.len]) |*c, text| {
        c.* = try b.cell(&.{try b.paragraph(&.{.{ .text = text, .bold = true }}, .{})}, &sheet.colors.header_fill, 1);
    }
    try rows.append(arena, .{ .cells = try arena.dupe(docx.TableCell, header_cells[0..widths.len]), .header = true, .cant_split = true });

    var runs: std.ArrayListUnmanaged(docx.Run) = .empty;
    for (sheet.groups) |group| {
        if (group.name.len > 0) {
            // keepNext holds the name row on the page of the first item under it.
            const name_para = try b.paragraph(&.{.{ .text = group.name, .bold = true, .fg = sheet.colors.group_text }}, .{ .keep_next = true });
            try rows.append(arena, .{
                .cells = try arena.dupe(docx.TableCell, &.{try b.cell(&.{name_para}, &sheet.colors.group_fill, columns)}),
                .cant_split = true,
            });
        }
        for (group.items) |item| {
            const segs = try word_diff.diffWords(arena, item.before, item.after);
            const where = try b.cell(&.{try b.paragraph(&.{.{ .text = item.where, .bold = true }}, .{})}, null, 1);
            const note: ?docx.Paragraph = if (item.note.len > 0)
                try b.paragraph(&.{.{ .text = item.note, .italic = true, .fg = sheet.colors.note, .half_points = 17 }}, .{})
            else
                null;

            var cells: std.ArrayListUnmanaged(docx.TableCell) = .empty;
            try cells.append(arena, where);
            switch (sheet.mode) {
                .redline => {
                    // Now: kept words plain, removed words in the removed look.
                    runs.clearRetainingCapacity();
                    for (segs) |s| {
                        if (s.before.len == 0) continue;
                        const base = docx.Run{ .text = s.before };
                        try runs.append(arena, if (s.kind == .changed and hasNonSpace(s.before)) marks.removedLook(base) else base);
                    }
                    try cells.append(arena, try b.cell(&.{.{ .runs = try b.joined(runs.items) }}, null, 1));

                    // Should be: kept words plain, added words in the added look, then the note.
                    runs.clearRetainingCapacity();
                    for (segs) |s| {
                        if (s.after.len == 0) continue;
                        const base = docx.Run{ .text = s.after };
                        try runs.append(arena, if (s.kind == .changed and hasNonSpace(s.after)) marks.addedLook(base) else base);
                    }
                    const after_para = docx.Paragraph{ .runs = try b.joined(runs.items) };
                    try cells.append(arena, if (note) |n| try b.cell(&.{ after_para, n }, null, 1) else try b.cell(&.{after_para}, null, 1));
                },
                .tracked => {
                    // Change: the old text with each change as a tracked
                    // deletion and insertion; accepting all gives the new text.
                    runs.clearRetainingCapacity();
                    for (segs) |s| {
                        if (s.kind == .same) {
                            try runs.append(arena, .{ .text = s.before });
                            continue;
                        }
                        if (s.before.len > 0) try runs.append(arena, .{ .text = s.before, .revision = .deleted });
                        if (s.after.len > 0) try runs.append(arena, .{ .text = s.after, .revision = .inserted });
                    }
                    try cells.append(arena, try b.cell(&.{.{ .runs = try b.joined(runs.items) }}, null, 1));
                    if (widths.len == 3) {
                        try cells.append(arena, if (note) |n| try b.cell(&.{n}, null, 1) else try b.cell(&.{.{}}, null, 1));
                    }
                },
            }
            try rows.append(arena, .{ .cells = try cells.toOwnedSlice(arena), .cant_split = true });
        }
    }

    try elements.append(arena, .{ .table = .{
        .rows = try rows.toOwnedSlice(arena),
        .col_widths = try arena.dupe(u16, widths),
        .border_color = &sheet.colors.border,
        .fixed_layout = true,
        .cell_margins = .{ .top = 50, .left = 90, .bottom = 50, .right = 90 },
    } });
    // Word keeps a paragraph after a closing table; so does the sheet.
    try elements.append(arena, .{ .paragraph = .{} });

    return .{
        .elements = try elements.toOwnedSlice(arena),
        .media = &.{},
        .allocator = arena,
    };
}

// ─── Comparing two documents ───────────────────────────────────────

const Para = struct {
    text: []const u8,
    heading: bool,
};

/// The non-empty paragraphs of a parsed document in reading order, table
/// cells included, each as the plain text of its runs.
fn paragraphsOf(arena: Allocator, doc: *const docx.Document) ![]Para {
    var out: std.ArrayListUnmanaged(Para) = .empty;
    for (doc.elements) |el| switch (el) {
        .paragraph => |p| try appendPara(arena, &out, &p),
        .table => |t| for (t.rows) |row| for (row.cells) |cell| for (cell.paragraphs) |p| {
            try appendPara(arena, &out, &p);
        },
    };
    return out.toOwnedSlice(arena);
}

fn appendPara(arena: Allocator, out: *std.ArrayListUnmanaged(Para), p: *const docx.Paragraph) !void {
    var text: Buf = .empty;
    for (p.runs) |r| {
        if (r.image_rel_id == null) try text.appendSlice(arena, r.text);
    }
    const t = std.mem.trim(u8, text.items, " \t\r\n");
    if (t.len == 0) return;
    const heading = switch (p.style) {
        .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .title => true,
        else => false,
    };
    try out.append(arena, .{ .text = t, .heading = heading });
}

/// Two paragraphs this alike, or more, are one paragraph edited rather than
/// one removed and another added.
const PAIR_SIMILARITY: f32 = 0.4;

/// A sheet listing what changed from `before_docx` to `after_docx`, with the
/// title, key, mode, labels and colours of `options` (its groups are
/// ignored). Paragraphs are lined up by their text; each one that changed is
/// an item, and items are grouped under the heading (in the first document)
/// they fall beneath. Everything lives in `arena`.
pub fn compareDocx(arena: Allocator, before_docx: []const u8, after_docx: []const u8, options: Sheet) !Sheet {
    var a_zip = try zip.ZipArchive.openFromMemory(arena, before_docx);
    const a_doc = try docx.parseDocument(arena, &a_zip);
    var b_zip = try zip.ZipArchive.openFromMemory(arena, after_docx);
    const b_doc = try docx.parseDocument(arena, &b_zip);

    const pa = try paragraphsOf(arena, &a_doc);
    const pb = try paragraphsOf(arena, &b_doc);
    const ta = try arena.alloc([]const u8, pa.len);
    for (pa, ta) |p, *t| t.* = p.text;
    const tb = try arena.alloc([]const u8, pb.len);
    for (pb, tb) |p, *t| t.* = p.text;

    const ops = try word_diff.diffTokens(arena, ta, tb);

    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var group_name: []const u8 = "";
    var ia: usize = 0;
    var ib: usize = 0;
    var k: usize = 0;
    while (k < ops.len) {
        if (ops[k] == .same) {
            if (pa[ia].heading) {
                try closeGroup(arena, &groups, &items, group_name);
                group_name = pa[ia].text;
            }
            ia += 1;
            ib += 1;
            k += 1;
            continue;
        }
        // One stretch of removed and added paragraphs.
        const a0 = ia;
        const b0 = ib;
        while (k < ops.len and ops[k] != .same) : (k += 1) {
            if (ops[k] == .removed) ia += 1 else ib += 1;
        }
        // Pair each removed paragraph with the next added one most like it
        // (in order); what is left over was removed or added outright.
        var next_b = b0;
        for (a0..ia) |ra| {
            var best: ?usize = null;
            var best_score: f32 = PAIR_SIMILARITY;
            for (next_b..ib) |cb| {
                const score = try word_diff.similarity(arena, ta[ra], tb[cb]);
                if (score >= best_score) {
                    best = cb;
                    best_score = score;
                }
            }
            if (best) |cb| {
                for (next_b..cb) |added| try items.append(arena, try addedItem(arena, tb[added], ra));
                try items.append(arena, .{ .where = try paragraphLabel(arena, ra), .before = ta[ra], .after = tb[cb] });
                next_b = cb + 1;
            } else {
                try items.append(arena, .{ .where = try paragraphLabel(arena, ra), .before = ta[ra] });
            }
        }
        for (next_b..ib) |added| try items.append(arena, try addedItem(arena, tb[added], ia));
        // A heading among the removed paragraphs starts a group too.
        for (a0..ia) |ra| {
            if (pa[ra].heading) {
                try closeGroup(arena, &groups, &items, group_name);
                group_name = pa[ra].text;
            }
        }
    }
    try closeGroup(arena, &groups, &items, group_name);

    var sheet = options;
    sheet.groups = try groups.toOwnedSlice(arena);
    return sheet;
}

fn closeGroup(arena: Allocator, groups: *std.ArrayListUnmanaged(Group), items: *std.ArrayListUnmanaged(Item), name: []const u8) !void {
    if (items.items.len == 0) return;
    try groups.append(arena, .{ .name = name, .items = try items.toOwnedSlice(arena) });
}

fn paragraphLabel(arena: Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "Paragraph {d}", .{index + 1});
}

/// An added paragraph, placed by how many paragraphs of the first document
/// come before it.
fn addedItem(arena: Allocator, text: []const u8, before_count: usize) !Item {
    const where = if (before_count == 0)
        "New, at the start"
    else
        try std.fmt.allocPrint(arena, "New, after paragraph {d}", .{before_count});
    return .{ .where = where, .after = text };
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn countOf(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

/// word/document.xml of the sheet, generated in full.
fn documentXml(arena: Allocator, sheet: *const Sheet) ![]const u8 {
    return documentOf(arena, try generate(arena, sheet));
}

/// word/document.xml of a generated .docx.
fn documentOf(arena: Allocator, bytes: []const u8) ![]const u8 {
    var archive = try zip.ZipArchive.openFromMemory(arena, bytes);
    const entry = archive.findEntry("word/document.xml") orelse return error.TestUnexpectedResult;
    return archive.extract(entry);
}

/// Every start tag has its end tag, in order: the part is well nested.
fn expectBalanced(xml_text: []const u8) !void {
    const xml = @import("xml.zig");
    var p = xml.XmlParser.init(xml_text);
    var stack: [64][]const u8 = undefined;
    var depth: usize = 0;
    var names: [64][256]u8 = undefined;
    while (p.next()) |ev| switch (ev) {
        .element_start => |es| {
            try testing.expect(depth < stack.len);
            const n = @min(es.name.len, 256);
            @memcpy(names[depth][0..n], es.name[0..n]);
            stack[depth] = names[depth][0..n];
            depth += 1;
        },
        .element_end => |name| {
            try testing.expect(depth > 0);
            depth -= 1;
            try testing.expectEqualStrings(stack[depth], name);
        },
        .text => {},
    };
    try testing.expectEqual(@as(usize, 0), depth);
}

test "a fix renders removed words struck in red and added words green" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sheet = Sheet{
        .title = "Proofread",
        .groups = &.{.{ .name = "Flat 1", .items = &.{.{
            .where = "Action 3",
            .before = "kept free free from storage",
            .after = "kept free from storage",
            .note = "Word repeated.",
        }} }},
    };
    const xml = try documentXml(arena, &sheet);
    try expectBalanced(xml);

    // Removed: struck, red, on light red, in schema order.
    try testing.expect(contains(xml, "<w:rPr><w:strike/><w:color w:val=\"A00000\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FDDADA\"/></w:rPr><w:t xml:space=\"preserve\">free </w:t>"));
    // The note, grey italic 8.5pt.
    try testing.expect(contains(xml, "<w:rPr><w:i/><w:color w:val=\"555555\"/><w:sz w:val=\"17\"/><w:szCs w:val=\"17\"/></w:rPr><w:t xml:space=\"preserve\">Word repeated.</w:t>"));
    // Landscape A4, a repeated header row, rows that do not split, a dark group row over three columns.
    try testing.expect(contains(xml, "<w:pgSz w:w=\"16838\" w:h=\"11906\" w:orient=\"landscape\"/>"));
    try testing.expect(contains(xml, "<w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>"));
    try testing.expectEqual(@as(usize, 3), countOf(xml, "<w:cantSplit/>"));
    try testing.expect(contains(xml, "<w:gridSpan w:val=\"3\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"222222\"/>"));
    // The default key shows both looks.
    try testing.expect(contains(xml, "Struck through"));
    try testing.expect(contains(xml, "<w:b/><w:color w:val=\"006400\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"D7F5D7\"/></w:rPr><w:t xml:space=\"preserve\">marked like this</w:t>"));
}

test "added words are bold green on light green, kept words plain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sheet = Sheet{ .key = "", .groups = &.{.{ .items = &.{.{ .where = "Q", .before = "No  5", .after = "No  7" }} }} };
    const xml = try documentXml(arena, &sheet);
    try expectBalanced(xml);
    try testing.expect(contains(xml, "<w:r><w:rPr></w:rPr><w:t xml:space=\"preserve\">No  </w:t></w:r>"));
    try testing.expect(contains(xml, "<w:rPr><w:strike/><w:color w:val=\"A00000\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FDDADA\"/></w:rPr><w:t xml:space=\"preserve\">5</w:t>"));
    try testing.expect(contains(xml, "<w:rPr><w:b/><w:color w:val=\"006400\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"D7F5D7\"/></w:rPr><w:t xml:space=\"preserve\">7</w:t>"));
    // No group name: no group row. key "": no key paragraph.
    try testing.expect(!contains(xml, "gridSpan"));
    try testing.expect(!contains(xml, "Struck through"));
}

test "tracked mode writes w:del and w:ins with author and date" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sheet = Sheet{
        .mode = .tracked,
        .author = "A & B",
        .date = "2026-11-13T09:30:00Z",
        .groups = &.{.{ .items = &.{
            .{ .where = "One", .before = "No  5", .after = "No  7" },
            .{ .where = "Two", .before = "the old text", .after = "the old text, extended" },
        } }},
    };
    const xml = try documentXml(arena, &sheet);
    try expectBalanced(xml);

    // A deletion holds w:delText; an insertion holds w:t. Ids are unique.
    try testing.expect(contains(xml, "<w:del w:id=\"1\" w:author=\"A &amp; B\" w:date=\"2026-11-13T09:30:00Z\"><w:r><w:rPr></w:rPr><w:delText xml:space=\"preserve\">5</w:delText></w:r></w:del>"));
    try testing.expect(contains(xml, "<w:ins w:id=\"2\" w:author=\"A &amp; B\" w:date=\"2026-11-13T09:30:00Z\"><w:r><w:rPr></w:rPr><w:t xml:space=\"preserve\">7</w:t></w:r></w:ins>"));
    // "text" → "text, extended" is the second item's one change.
    try testing.expect(contains(xml, "<w:del w:id=\"3\""));
    try testing.expect(contains(xml, "<w:ins w:id=\"4\""));
    try testing.expect(!contains(xml, "w:id=\"5\""));
    // Tracked runs carry no redline colours: accepted text is plain.
    try testing.expect(!contains(xml, "<w:strike/>"));
    // No notes: two columns, Where and Change.
    try testing.expectEqual(@as(usize, 2), countOf(xml, "<w:gridCol "));
    try testing.expect(contains(xml, ">Change</w:t>"));
}

test "dates are normalised to an xsd:dateTime" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("2026-11-13T00:00:00Z", try normalizeDate(arena, "2026-11-13"));
    try testing.expectEqualStrings("2026-11-13T09:30:00", try normalizeDate(arena, "2026-11-13T09:30"));
    try testing.expectEqualStrings("2026-11-13T09:30:00+01:00", try normalizeDate(arena, "2026-11-13T09:30+01:00"));
    try testing.expectEqualStrings("2026-11-13T09:30:15.5Z", try normalizeDate(arena, "2026-11-13T09:30:15.5Z"));
    try testing.expectEqualStrings("", try normalizeDate(arena, ""));
    try testing.expectError(error.InvalidDate, normalizeDate(arena, "13/11/2026"));
    try testing.expectError(error.InvalidDate, normalizeDate(arena, "2026-11-13 09:30"));
    try testing.expectError(error.InvalidDate, normalizeDate(arena, "2026-11-13T09:30\"/>"));
}

test "JSON sets labels, colours and mode, and rejects bad values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sheet = try parseJson(arena,
        \\{"title": "T", "mode": "tracked", "orientation": "portrait", "date": "2026-01-02",
        \\ "labels": {"before": "Was", "after": "Is"},
        \\ "colors": {"removed": "#123abc", "added_fill": "lightgreen"},
        \\ "items": [{"where": "w", "before": "a", "after": "b", "note": null}],
        \\ "groups": [{"name": "G", "items": [{"before": "x"}]}]}
    );
    try testing.expectEqual(Mode.tracked, sheet.mode);
    try testing.expectEqual(Orientation.portrait, sheet.orientation);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", sheet.date);
    try testing.expectEqualStrings("Was", sheet.labels.before);
    try testing.expectEqualStrings("Where", sheet.labels.where);
    try testing.expectEqualStrings("123ABC", &sheet.colors.removed);
    try testing.expectEqualStrings("DCFCE7", &sheet.colors.added_fill);
    try testing.expectEqual(@as(usize, 2), sheet.groups.len);
    try testing.expectEqualStrings("", sheet.groups[0].name);
    try testing.expectEqualStrings("G", sheet.groups[1].name);
    try testing.expectEqualStrings("x", sheet.groups[1].items[0].before);

    try testing.expectError(error.InvalidColor, parseJson(arena, "{\"colors\": {\"removed\": \"red\\\"/>\"}}"));
    try testing.expectError(error.InvalidMode, parseJson(arena, "{\"mode\": \"loud\"}"));
    try testing.expectError(error.ExpectedString, parseJson(arena, "{\"title\": 3}"));
    try testing.expectError(error.InvalidJson, parseJson(arena, "{not json"));
    try testing.expectError(error.ExpectedObject, parseJson(arena, "[]"));
}

test "user text is escaped everywhere it lands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sheet = Sheet{
        .title = "<script>&",
        .labels = .{ .where = "W<" },
        .groups = &.{.{ .name = "G\"&", .items = &.{.{ .where = "]]>", .before = "a < b", .after = "a > b", .note = "x&y" }} }},
    };
    const xml = try documentXml(arena, &sheet);
    try expectBalanced(xml);
    try testing.expect(!contains(xml, "<script>"));
    try testing.expect(contains(xml, "&lt;script&gt;&amp;"));
    try testing.expect(contains(xml, "G&quot;&amp;"));
    try testing.expect(contains(xml, "]]&gt;"));
}

test "golden: the reference sheet from a JSON fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = @embedFile("testdata/redline_sheet.json");
    const sheet = try parseJson(arena, json);
    const bytes = try generate(testing.allocator, &sheet);
    defer testing.allocator.free(bytes);

    // The package opens with the library's own reader, every part is there
    // and its CRC checks out (the reader verifies each entry it extracts).
    var archive = try zip.ZipArchive.openFromMemory(arena, bytes);
    for ([_][]const u8{ "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels", "word/styles.xml", "docProps/core.xml" }) |part| {
        const entry = archive.findEntry(part) orelse return error.TestUnexpectedResult;
        const data = try archive.extract(entry);
        try expectBalanced(data);
    }

    const xml = try documentOf(arena, bytes);
    var group_count: usize = 0;
    var item_count: usize = 0;
    for (sheet.groups) |g| {
        if (g.name.len > 0) group_count += 1;
        item_count += g.items.len;
    }
    try testing.expectEqual(@as(usize, 4), group_count);
    try testing.expectEqual(@as(usize, 9), item_count);
    // One group row per group, one row per item plus the header, none split.
    try testing.expectEqual(group_count, countOf(xml, "<w:gridSpan w:val=\"3\"/>"));
    try testing.expectEqual(1 + group_count + item_count, countOf(xml, "<w:cantSplit/>"));
    try testing.expectEqual(@as(usize, 1), countOf(xml, "<w:tblHeader/>"));
    try testing.expect(contains(xml, "w:orient=\"landscape\""));

    // Read back through the DOCX reader: the text of every cell survives
    // and the struck and added runs keep their look.
    var doc = try docx.parseDocument(arena, &archive);
    _ = &doc;
    var struck: usize = 0;
    var added: usize = 0;
    var saw_title = false;
    for (doc.elements) |el| switch (el) {
        .paragraph => |p| for (p.runs) |r| {
            if (std.mem.startsWith(u8, r.text, "Proofread:")) saw_title = true;
        },
        .table => |t| for (t.rows) |row| for (row.cells) |cell| for (cell.paragraphs) |p| for (p.runs) |r| {
            if (r.strike) {
                struck += 1;
                try testing.expectEqualStrings("A00000", &r.fg.?);
                try testing.expectEqualStrings("FDDADA", &r.bg.?);
            }
            if (r.fg != null and std.mem.eql(u8, &r.fg.?, "006400")) {
                added += 1;
                try testing.expect(r.bold);
            }
        },
    };
    try testing.expect(saw_title);
    try testing.expect(struck >= item_count - 1); // one item only adds words
    try testing.expect(added >= item_count - 1); // one item only removes words
}

test "comparing two documents lists the paragraphs that changed under their headings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before_md =
        \\# Escape routes
        \\
        \\The stair is kept clear of storage.
        \\
        \\Doors close fully onto the rebate.
        \\
        \\# Lighting
        \\
        \\Emergency lights are tested monthly.
        \\
        \\This line goes away entirely.
    ;
    const after_md =
        \\# Escape routes
        \\
        \\The stair is kept clear of all storage.
        \\
        \\Doors close fully onto the rebate.
        \\
        \\# Lighting
        \\
        \\Emergency lights are tested every month.
        \\
        \\A brand new paragraph about signage.
    ;
    const before_docx = try mdToDocx(arena, before_md);
    const after_docx = try mdToDocx(arena, after_md);

    const sheet = try compareDocx(arena, before_docx, after_docx, .{ .title = "Changes" });
    try testing.expectEqual(@as(usize, 2), sheet.groups.len);
    try testing.expectEqualStrings("Escape routes", sheet.groups[0].name);
    try testing.expectEqual(@as(usize, 1), sheet.groups[0].items.len);
    try testing.expectEqualStrings("Paragraph 2", sheet.groups[0].items[0].where);
    try testing.expectEqualStrings("The stair is kept clear of storage.", sheet.groups[0].items[0].before);
    try testing.expectEqualStrings("The stair is kept clear of all storage.", sheet.groups[0].items[0].after);

    try testing.expectEqualStrings("Lighting", sheet.groups[1].name);
    const lit = sheet.groups[1].items;
    try testing.expectEqual(@as(usize, 3), lit.len);
    try testing.expectEqualStrings("Emergency lights are tested every month.", lit[0].after);
    try testing.expectEqualStrings("This line goes away entirely.", lit[1].before);
    try testing.expectEqualStrings("", lit[1].after);
    try testing.expectEqualStrings("", lit[2].before);
    try testing.expectEqualStrings("A brand new paragraph about signage.", lit[2].after);
    try testing.expectEqualStrings("New, after paragraph 6", lit[2].where);

    const bytes = try generate(testing.allocator, &sheet);
    defer testing.allocator.free(bytes);
    try expectBalanced(try documentOf(arena, bytes));
}

fn mdToDocx(arena: Allocator, md: []const u8) ![]u8 {
    var parsed = try md_parser.parseMarkdown(arena, md);
    _ = &parsed;
    return writer.generateDocx(arena, &parsed.document, .{});
}
