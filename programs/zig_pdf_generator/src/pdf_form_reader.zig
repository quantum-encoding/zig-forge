//! Reads the values in a PDF's fillable form (AcroForm): what a person typed
//! into its text boxes and which checkboxes they ticked.
//!
//! `readFormFields` walks the catalog's /AcroForm /Fields tree, then every
//! page's widget annotations for any field the tree leaves out, and returns
//! each terminal field under its fully qualified name (partial names joined
//! with '.'), in document order:
//!
//!   text field (/FT /Tx)          → its /V text; left out when /V is absent
//!   checkbox (/FT /Btn)           → true when /V names a state other than Off
//!   radio group (/FT /Btn, Radio) → the chosen option; left out when none is
//!   choice (/FT /Ch)              → its /V text, or a list for a multi-select
//!
//! A button's value is its /V alone (a name, or a string as PDFKit writes it);
//! no /V is Off. A widget's /AS is not consulted: PDFKit, and so macOS Preview,
//! saves a changed checkbox by setting or removing /V and leaves /AS as it was.
//!
//! Push buttons and signature fields hold no typed value and are skipped. When
//! two fields share a qualified name, the first one in document order wins.
//!
//! Objects are read through `pdf_extract.Document`, so incremental updates
//! (the newest revision of each object wins), cross-reference streams, object
//! streams, a damaged xref (rebuilt by scanning) and documents encrypted with
//! an empty user password all read. A document that needs a real password is
//! refused with error.EncryptedUnsupported.
//!
//! Text comes back as UTF-8: PDF text strings are decoded from UTF-16BE (FE FF
//! byte-order mark), UTF-8 (EF BB BF, PDF 2.0) or PDFDocEncoding.

const std = @import("std");
const pdf_extract = @import("pdf_extract.zig");

const Document = pdf_extract.Document;
const Obj = pdf_extract.Obj;

pub const ReadError = pdf_extract.ExtractError;

pub const Value = union(enum) {
    text: []const u8,
    checked: bool,
    list: []const []const u8,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// Field flags (/Ff): PDF 32000-1:2008, "Field flags specific to button fields".
const FF_RADIO: i64 = 1 << 15;
const FF_PUSHBUTTON: i64 = 1 << 16;

/// Deepest field tree or /Parent chain followed; deeper nesting is malformed.
const max_depth = 32;

/// Read every form field's value. All returned memory belongs to `arena`.
pub fn readFormFields(arena: std.mem.Allocator, pdf: []const u8) ReadError![]Field {
    var doc = try Document.parse(arena, pdf);
    if (doc.encrypted and doc.decryptor == null) return ReadError.EncryptedUnsupported;

    var w = Walker{ .doc = &doc, .arena = arena };
    const cat = try doc.catalog();

    if (try doc.dictGet(cat, "AcroForm")) |af_obj| {
        if (af_obj.asDict()) |af| {
            if (try doc.dictGet(af, "Fields")) |fields| {
                if (fields == .array) {
                    for (fields.array) |f| try w.walkField(f, "", .{}, 0);
                }
            }
        }
    }

    // Widgets whose field is missing from /Fields (or a form with no
    // /AcroForm at all): climb each one's /Parent chain to its top field.
    if (try doc.dictGet(cat, "Pages")) |pages| try w.walkPageTree(pages, 0);

    return w.out.items;
}

/// Read every form field's value as a JSON object, `{ "name": value, … }`,
/// in document order. Caller owns the returned bytes (allocated with `gpa`).
pub fn readFormFieldsJson(gpa: std.mem.Allocator, pdf: []const u8) ReadError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const fields = try readFormFields(arena_state.allocator(), pdf);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeJson(&aw.writer, fields) catch return ReadError.OutOfMemory;
    return aw.toOwnedSlice() catch ReadError.OutOfMemory;
}

fn writeJson(writer: *std.Io.Writer, fields: []const Field) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = writer };
    try s.beginObject();
    for (fields) |f| {
        try s.objectField(f.name);
        switch (f.value) {
            .text => |t| try s.write(t),
            .checked => |c| try s.write(c),
            .list => |items| {
                try s.beginArray();
                for (items) |it| try s.write(it);
                try s.endArray();
            },
        }
    }
    try s.endObject();
}

/// Attributes a field passes to its kids: PDF 32000-1:2008 marks /FT, /Ff,
/// /V and a button's /Opt inheritable.
const Inherited = struct {
    ft: []const u8 = "",
    ff: i64 = 0,
    v: ?Obj = null,
    opt: ?Obj = null,
};

const Walker = struct {
    doc: *Document,
    arena: std.mem.Allocator,
    out: std.ArrayListUnmanaged(Field) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Object numbers of field nodes already walked, so a field reached both
    /// from /Fields and from a page's /Annots is read once, and cycles end.
    seen_fields: std.AutoHashMapUnmanaged(u32, void) = .empty,
    seen_pages: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn walkField(self: *Walker, node: Obj, parent_name: []const u8, inherited: Inherited, depth: usize) ReadError!void {
        if (depth > max_depth) return;
        if (node == .ref) {
            if (self.seen_fields.contains(node.ref.num)) return;
            try self.seen_fields.put(self.arena, node.ref.num, {});
        }
        const d = (try self.doc.resolve(node)).asDict() orelse return;

        var name = parent_name;
        if (try self.doc.dictGet(d, "T")) |t| {
            if (t == .string) {
                const partial = try decodeTextString(self.arena, t.string);
                name = if (parent_name.len == 0)
                    partial
                else
                    try std.mem.concat(self.arena, u8, &.{ parent_name, ".", partial });
            }
        }

        var here = inherited;
        if (try self.doc.dictGet(d, "FT")) |ft| {
            if (ft == .name) here.ft = ft.name;
        }
        if (try self.doc.dictGet(d, "Ff")) |ff| {
            if (ff.asInt()) |v| here.ff = v;
        }
        if (try self.doc.dictGet(d, "V")) |v| here.v = v;
        if (try self.doc.dictGet(d, "Opt")) |o| here.opt = o;

        // A kid with its own /T or /Kids is a child field; any other kid is a
        // widget annotation of this field. With no kids, the field and its
        // single widget share this dictionary.
        var has_child_fields = false;
        if (try self.doc.dictGet(d, "Kids")) |kids| {
            if (kids == .array) {
                for (kids.array) |kid| {
                    const kd = (try self.doc.resolve(kid)).asDict() orelse continue;
                    if (kd.get("T") != null or kd.get("Kids") != null) {
                        has_child_fields = true;
                        try self.walkField(kid, name, here, depth + 1);
                    } else if (kid == .ref) {
                        try self.seen_fields.put(self.arena, kid.ref.num, {});
                    }
                }
            }
        }
        if (has_child_fields or name.len == 0) return;
        try self.emit(name, here);
    }

    fn emit(self: *Walker, name: []const u8, attrs: Inherited) ReadError!void {
        if (self.names.contains(name)) return;
        const value: Value = blk: {
            if (std.mem.eql(u8, attrs.ft, "Tx")) {
                const v = attrs.v orelse return;
                break :blk .{ .text = (try self.textValue(v)) orelse return };
            }
            if (std.mem.eql(u8, attrs.ft, "Btn")) {
                if (attrs.ff & FF_PUSHBUTTON != 0) return;
                const state = try self.buttonState(attrs.v);
                const on = state != null and !std.mem.eql(u8, state.?, "Off");
                if (attrs.ff & FF_RADIO != 0) {
                    if (!on) return;
                    break :blk .{ .text = try self.exportValue(state.?, attrs.opt) };
                }
                break :blk .{ .checked = on };
            }
            if (std.mem.eql(u8, attrs.ft, "Ch")) {
                const v = attrs.v orelse return;
                if (v == .array) {
                    var items: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (v.array) |item| {
                        const r = try self.doc.resolve(item);
                        if (r == .string) try items.append(self.arena, try decodeTextString(self.arena, r.string));
                    }
                    break :blk .{ .list = items.items };
                }
                break :blk .{ .text = (try self.textValue(v)) orelse return };
            }
            return; // /Sig, or no field type at all
        };
        try self.names.put(self.arena, name, {});
        try self.out.append(self.arena, .{ .name = name, .value = value });
    }

    /// A text value: a text string, or (rich text) a stream holding one.
    fn textValue(self: *Walker, v: Obj) ReadError!?[]const u8 {
        return switch (v) {
            .string => |s| try decodeTextString(self.arena, s),
            .stream => |st| try decodeTextString(self.arena, try self.doc.decodeStreamRaw(st)),
            else => null,
        };
    }

    /// The option a radio state stands for. With /Opt (PDF 1.4) the state
    /// names may be the widgets' positions, /0, /1, …, and /Opt holds the
    /// option text for each position; otherwise the state name is the option.
    fn exportValue(self: *Walker, state: []const u8, opt: ?Obj) ReadError![]const u8 {
        if (opt) |o| {
            if (o == .array) {
                if (std.fmt.parseInt(usize, state, 10)) |idx| {
                    if (idx < o.array.len) {
                        const entry = try self.doc.resolve(o.array[idx]);
                        if (entry == .string) return decodeTextString(self.arena, entry.string);
                    }
                } else |_| {}
            }
        }
        return sanitizeUtf8(self.arena, state);
    }

    /// A button's state name from its /V: a name, or a string as PDFKit
    /// writes it. Null when there is no /V.
    fn buttonState(self: *Walker, v: ?Obj) ReadError!?[]const u8 {
        const val = v orelse return null;
        return switch (val) {
            .name => |n| n,
            .string => |s| try decodeTextString(self.arena, s),
            else => null,
        };
    }

    fn walkPageTree(self: *Walker, node: Obj, depth: usize) ReadError!void {
        if (depth > max_depth) return;
        if (node == .ref) {
            if (self.seen_pages.contains(node.ref.num)) return;
            try self.seen_pages.put(self.arena, node.ref.num, {});
        }
        const d = (try self.doc.resolve(node)).asDict() orelse return;
        if (try self.doc.dictGet(d, "Kids")) |kids| {
            if (kids == .array) {
                for (kids.array) |kid| try self.walkPageTree(kid, depth + 1);
            }
            return;
        }
        const annots = (try self.doc.dictGet(d, "Annots")) orelse return;
        if (annots != .array) return;
        for (annots.array) |a| {
            if (a != .ref) continue; // a field is always an indirect object
            const ad = (try self.doc.resolve(a)).asDict() orelse continue;
            const sub = ad.get("Subtype") orelse continue;
            if (sub != .name or !std.mem.eql(u8, sub.name, "Widget")) continue;
            if (self.seen_fields.contains(a.ref.num)) continue;
            try self.walkField(try self.topField(a), "", .{}, 0);
        }
    }

    /// The top of a widget's /Parent chain: the root of its field tree.
    fn topField(self: *Walker, widget: Obj) ReadError!Obj {
        var cur = widget;
        var hops: usize = 0;
        while (hops < max_depth) : (hops += 1) {
            const d = (try self.doc.resolve(cur)).asDict() orelse break;
            const parent = d.get("Parent") orelse break;
            if (parent != .ref) break;
            cur = parent;
        }
        return cur;
    }
};

/// Decode a PDF text string (PDF 32000-1:2008 §7.9.2.2) to UTF-8.
pub fn decodeTextString(arena: std.mem.Allocator, bytes: []const u8) ReadError![]const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF) return utf16beToUtf8(arena, bytes[2..]);
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) return sanitizeUtf8(arena, bytes[3..]);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len);
    for (bytes) |b| try appendCodepoint(arena, &out, pdf_doc_encoding[b]);
    return out.items;
}

/// UTF-16BE to UTF-8; an unpaired surrogate or a dangling odd byte becomes
/// U+FFFD rather than being dropped.
fn utf16beToUtf8(arena: std.mem.Allocator, bytes: []const u8) ReadError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const unit: u21 = @as(u21, bytes[i]) << 8 | bytes[i + 1];
        var cp: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            cp = 0xFFFD;
            if (i + 3 < bytes.len) {
                const lo: u21 = @as(u21, bytes[i + 2]) << 8 | bytes[i + 3];
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    cp = 0x10000 + ((unit - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            cp = 0xFFFD;
        }
        try appendCodepoint(arena, &out, cp);
    }
    if (bytes.len % 2 == 1) try appendCodepoint(arena, &out, 0xFFFD);
    return out.items;
}

/// `bytes` when it is valid UTF-8, else a copy with each bad byte as U+FFFD.
fn sanitizeUtf8(arena: std.mem.Allocator, bytes: []const u8) ReadError![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try appendCodepoint(arena, &out, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + n <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i .. i + n])) |cp| {
                try appendCodepoint(arena, &out, cp);
                i += n;
                continue;
            } else |_| {}
        }
        try appendCodepoint(arena, &out, 0xFFFD);
        i += 1;
    }
    return out.items;
}

/// Append `cp` as UTF-8; a code point UTF-8 cannot carry (a surrogate half)
/// is written as U+FFFD.
fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) ReadError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return out.appendSlice(arena, "\u{FFFD}");
    try out.appendSlice(arena, buf[0..n]);
}

/// PDFDocEncoding → Unicode, PDF 32000-1:2008 annex D table D.2. Bytes the
/// table leaves undefined (0x7F, 0x9F, 0xAD) map to U+FFFD.
const pdf_doc_encoding: [256]u21 = blk: {
    var t: [256]u21 = undefined;
    for (&t, 0..) |*e, i| e.* = i;
    t[0x18] = 0x02D8; // breve
    t[0x19] = 0x02C7; // caron
    t[0x1A] = 0x02C6; // circumflex
    t[0x1B] = 0x02D9; // dot above
    t[0x1C] = 0x02DD; // double acute
    t[0x1D] = 0x02DB; // ogonek
    t[0x1E] = 0x02DA; // ring above
    t[0x1F] = 0x02DC; // small tilde
    t[0x7F] = 0xFFFD;
    t[0x80] = 0x2022; // bullet
    t[0x81] = 0x2020; // dagger
    t[0x82] = 0x2021; // double dagger
    t[0x83] = 0x2026; // ellipsis
    t[0x84] = 0x2014; // em dash
    t[0x85] = 0x2013; // en dash
    t[0x86] = 0x0192; // florin
    t[0x87] = 0x2044; // fraction slash
    t[0x88] = 0x2039; // single left angle quote
    t[0x89] = 0x203A; // single right angle quote
    t[0x8A] = 0x2212; // minus
    t[0x8B] = 0x2030; // per mille
    t[0x8C] = 0x201E; // double low-9 quote
    t[0x8D] = 0x201C; // left double quote
    t[0x8E] = 0x201D; // right double quote
    t[0x8F] = 0x2018; // left single quote
    t[0x90] = 0x2019; // right single quote
    t[0x91] = 0x201A; // single low-9 quote
    t[0x92] = 0x2122; // trade mark
    t[0x93] = 0xFB01; // fi ligature
    t[0x94] = 0xFB02; // fl ligature
    t[0x95] = 0x0141; // L with stroke
    t[0x96] = 0x0152; // OE
    t[0x97] = 0x0160; // S with caron
    t[0x98] = 0x0178; // Y with diaeresis
    t[0x99] = 0x017D; // Z with caron
    t[0x9A] = 0x0131; // dotless i
    t[0x9B] = 0x0142; // l with stroke
    t[0x9C] = 0x0153; // oe
    t[0x9D] = 0x0161; // s with caron
    t[0x9E] = 0x017E; // z with caron
    t[0x9F] = 0xFFFD;
    t[0xA0] = 0x20AC; // euro
    t[0xAD] = 0xFFFD;
    break :blk t;
};
