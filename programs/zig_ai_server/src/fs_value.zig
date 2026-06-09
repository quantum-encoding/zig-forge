// Firestore typed-value ↔ JSON conversion.
//
// Firestore's REST wire format wraps every field value in a typed envelope:
//   "abc"  → {"stringValue":"abc"}
//   42     → {"integerValue":"42"}   (int64 sent as a STRING)
//   3.14   → {"doubleValue":3.14}
//   true   → {"booleanValue":true}
//   null   → {"nullValue":null}
//   {...}  → {"mapValue":{"fields":{...}}}
//   [...]  → {"arrayValue":{"values":[...]}}
//
// This module converts between that envelope and plain `std.json.Value`, so
// the generic CRUD layer (crud.zig) can store/read arbitrary client JSON
// documents without hand-modelling each collection's schema. All string
// values are written via std.json.Stringify (escaped) — no hand-formatted
// JSON (JSON-IN-FMT).

const std = @import("std");

/// Write a JSON value as a Firestore typed Value envelope.
pub fn writeTyped(jw: *std.json.Stringify, v: std.json.Value) !void {
    switch (v) {
        .null => {
            try jw.beginObject();
            try jw.objectField("nullValue");
            try jw.write(@as(?bool, null));
            try jw.endObject();
        },
        .bool => |b| {
            try jw.beginObject();
            try jw.objectField("booleanValue");
            try jw.write(b);
            try jw.endObject();
        },
        .integer => |i| {
            try jw.beginObject();
            try jw.objectField("integerValue"); // int64 → string
            var buf: [24]u8 = undefined;
            try jw.write(try std.fmt.bufPrint(&buf, "{d}", .{i}));
            try jw.endObject();
        },
        .float => |f| {
            try jw.beginObject();
            try jw.objectField("doubleValue");
            try jw.write(f);
            try jw.endObject();
        },
        .number_string => |s| {
            // Parsed as a number too large/precise for i64/f64 — keep as string.
            try jw.beginObject();
            try jw.objectField("stringValue");
            try jw.write(s);
            try jw.endObject();
        },
        .string => |s| {
            try jw.beginObject();
            try jw.objectField("stringValue");
            try jw.write(s);
            try jw.endObject();
        },
        .array => |arr| {
            try jw.beginObject();
            try jw.objectField("arrayValue");
            try jw.beginObject();
            try jw.objectField("values");
            try jw.beginArray();
            for (arr.items) |item| try writeTyped(jw, item);
            try jw.endArray();
            try jw.endObject();
            try jw.endObject();
        },
        .object => |o| {
            try jw.beginObject();
            try jw.objectField("mapValue");
            try jw.beginObject();
            try jw.objectField("fields");
            try jw.beginObject();
            var it = o.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .null) continue; // omit nulls in maps
                try jw.objectField(e.key_ptr.*);
                try writeTyped(jw, e.value_ptr.*);
            }
            try jw.endObject();
            try jw.endObject();
            try jw.endObject();
        },
    }
}

/// Write a full Firestore document body: {"fields":{ name:{typedValue}, … }}.
/// `obj` must be a JSON object; null fields are omitted.
pub fn writeDocument(jw: *std.json.Stringify, obj: std.json.Value) !void {
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    if (obj == .object) {
        var it = obj.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .null) continue;
            try jw.objectField(e.key_ptr.*);
            try writeTyped(jw, e.value_ptr.*);
        }
    }
    try jw.endObject();
    try jw.endObject();
}

/// Allocate a document body string from a JSON object value.
pub fn documentAlloc(allocator: std.mem.Allocator, obj: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try writeDocument(&jw, obj);
    return aw.toOwnedSlice();
}

/// Convert one Firestore typed Value into a plain JSON value (arena-allocated).
pub fn typedToPlain(arena: std.mem.Allocator, typed: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    if (typed != .object) return typed;
    const o = typed.object;
    if (o.get("stringValue")) |s| return s;
    if (o.get("booleanValue")) |b| return b;
    if (o.get("doubleValue")) |d| return d;
    if (o.get("timestampValue")) |t| return t;
    if (o.get("integerValue")) |iv| {
        if (iv == .string) return .{ .integer = std.fmt.parseInt(i64, iv.string, 10) catch 0 };
        return iv;
    }
    if (o.get("nullValue")) |_| return .null;
    if (o.get("mapValue")) |mv| {
        const fields = if (mv == .object) mv.object.get("fields") else null;
        return fieldsToPlain(arena, fields orelse std.json.Value{ .null = {} });
    }
    if (o.get("arrayValue")) |av| {
        var out = std.json.Array.init(arena);
        if (av == .object) if (av.object.get("values")) |vals| {
            if (vals == .array) for (vals.array.items) |item| {
                try out.append(try typedToPlain(arena, item));
            };
        };
        return .{ .array = out };
    }
    return .null;
}

/// Convert a Firestore `fields` object ({name:{typedValue}}) into a plain JSON
/// object value.
pub fn fieldsToPlain(arena: std.mem.Allocator, fields: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    if (fields == .object) {
        var it = fields.object.iterator();
        while (it.next()) |e| {
            try obj.put(arena, e.key_ptr.*, try typedToPlain(arena, e.value_ptr.*));
        }
    }
    return .{ .object = obj };
}
