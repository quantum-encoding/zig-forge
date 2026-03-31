const std = @import("std");
const models = @import("../models.zig");

pub const JsonWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    compact: bool,
    indent_level: u32,

    pub fn init(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), compact: bool) JsonWriter {
        return .{
            .buf = buf,
            .allocator = allocator,
            .compact = compact,
            .indent_level = 0,
        };
    }

    fn write(self: *JsonWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn writeByte(self: *JsonWriter, c: u8) !void {
        try self.buf.append(self.allocator, c);
    }

    fn newline(self: *JsonWriter) !void {
        if (self.compact) return;
        try self.writeByte('\n');
        for (0..self.indent_level * 2) |_| {
            try self.writeByte(' ');
        }
    }

    fn sep(self: *JsonWriter) !void {
        if (self.compact) {
            return;
        } else {
            try self.writeByte(' ');
        }
    }

    pub fn beginObject(self: *JsonWriter) !void {
        try self.writeByte('{');
        self.indent_level += 1;
    }

    pub fn endObject(self: *JsonWriter) !void {
        self.indent_level -= 1;
        try self.newline();
        try self.writeByte('}');
    }

    pub fn beginArray(self: *JsonWriter) !void {
        try self.writeByte('[');
        self.indent_level += 1;
    }

    pub fn endArray(self: *JsonWriter) !void {
        self.indent_level -= 1;
        try self.newline();
        try self.writeByte(']');
    }

    pub fn key(self: *JsonWriter, name: []const u8, first: bool) !void {
        if (!first) try self.writeByte(',');
        try self.newline();
        try self.writeByte('"');
        try self.write(name);
        try self.writeByte('"');
        try self.writeByte(':');
        try self.sep();
    }

    pub fn comma(self: *JsonWriter) !void {
        try self.writeByte(',');
    }

    pub fn writeString(self: *JsonWriter, s: []const u8) !void {
        try self.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                else => {
                    if (c < 0x20) {
                        try self.write("\\u00");
                        try self.writeByte("0123456789abcdef"[c >> 4]);
                        try self.writeByte("0123456789abcdef"[c & 0xf]);
                    } else {
                        try self.writeByte(c);
                    }
                },
            }
        }
        try self.writeByte('"');
    }

    pub fn writeInt(self: *JsonWriter, val: anytype) !void {
        var num_buf: [20]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch return;
        try self.write(num);
    }

    pub fn writeBool(self: *JsonWriter, val: bool) !void {
        try self.write(if (val) "true" else "false");
    }
};

pub fn writeProjectReport(allocator: std.mem.Allocator, report: *const models.ProjectReport, compact: bool) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = JsonWriter.init(allocator, &buf, compact);

    try w.beginObject();

    try w.key("project", true);
    try w.writeString(report.name);

    try w.key("root_path", false);
    try w.writeString(report.root_path);

    // Summary
    try w.key("summary", false);
    try w.beginObject();
    {
        const s = &report.summary;
        try w.key("files", true);
        try w.writeInt(s.total_files);
        try w.key("loc", false);
        try w.writeInt(s.total_loc);
        try w.key("blank_lines", false);
        try w.writeInt(s.total_blank);
        try w.key("comment_lines", false);
        try w.writeInt(s.total_comments);
        try w.key("functions", false);
        try w.writeInt(s.total_functions);
        try w.key("pub_functions", false);
        try w.writeInt(s.total_pub_functions);
        try w.key("structs", false);
        try w.writeInt(s.total_structs);
        try w.key("enums", false);
        try w.writeInt(s.total_enums);
        try w.key("unions", false);
        try w.writeInt(s.total_unions);
        try w.key("constants", false);
        try w.writeInt(s.total_constants);
        try w.key("tests", false);
        try w.writeInt(s.total_tests);
        try w.key("imports", false);
        try w.writeInt(s.total_imports);
        try w.key("unsafe_ops", false);
        try w.writeInt(s.total_unsafe_ops);
        if (s.parse_errors > 0) {
            try w.key("parse_errors", false);
            try w.writeInt(s.parse_errors);
        }
    }
    try w.endObject();

    if (!compact) {
        // Full mode: include per-file details
        try w.key("files", false);
        try w.beginArray();
        for (report.files.items, 0..) |*file, fi| {
            if (fi > 0) try w.comma();
            try writeFileReport(&w, file);
        }
        try w.endArray();
    } else {
        // Compact mode: key types, pub functions, dependency graph, warnings
        try writeCompactData(&w, report);
    }

    try w.endObject();
    try w.writeByte('\n');

    return buf.items;
}

fn writeFileReport(w: *JsonWriter, file: *const models.FileReport) !void {
    try w.newline();
    try w.beginObject();

    try w.key("path", true);
    try w.writeString(file.relative_path);
    try w.key("loc", false);
    try w.writeInt(file.loc);
    try w.key("size_bytes", false);
    try w.writeInt(file.size_bytes);

    if (file.functions.items.len > 0) {
        try w.key("functions", false);
        try w.beginArray();
        for (file.functions.items, 0..) |*f, fi| {
            if (fi > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(f.name);
            try w.key("line", false);
            try w.writeInt(f.line);
            try w.key("lines", false);
            try w.writeInt(f.body_lines);
            if (f.is_pub) {
                try w.key("pub", false);
                try w.writeBool(true);
            }
            if (f.is_extern) {
                try w.key("extern", false);
                try w.writeBool(true);
            }
            if (f.params.len > 0) {
                try w.key("params", false);
                try w.writeString(f.params);
            }
            if (f.return_type.len > 0) {
                try w.key("return", false);
                try w.writeString(f.return_type);
            }
            if (f.doc_comment.len > 0) {
                try w.key("doc", false);
                try w.writeString(f.doc_comment);
            }
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.structs.items.len > 0) {
        try w.key("structs", false);
        try w.beginArray();
        for (file.structs.items, 0..) |*s, si| {
            if (si > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(s.name);
            try w.key("line", false);
            try w.writeInt(s.line);
            try w.key("fields", false);
            try w.writeInt(s.fields_count);
            try w.key("methods", false);
            try w.writeInt(s.methods_count);
            if (s.kind != .@"struct") {
                try w.key("kind", false);
                try w.writeString(@tagName(s.kind));
            }
            if (s.doc_comment.len > 0) {
                try w.key("doc", false);
                try w.writeString(s.doc_comment);
            }
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.enums.items.len > 0) {
        try w.key("enums", false);
        try w.beginArray();
        for (file.enums.items, 0..) |*e, ei| {
            if (ei > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(e.name);
            try w.key("line", false);
            try w.writeInt(e.line);
            try w.key("variants", false);
            try w.writeInt(e.variants_count);
            try w.key("methods", false);
            try w.writeInt(e.methods_count);
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.unions.items.len > 0) {
        try w.key("unions", false);
        try w.beginArray();
        for (file.unions.items, 0..) |*u_info, ui| {
            if (ui > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(u_info.name);
            try w.key("line", false);
            try w.writeInt(u_info.line);
            try w.key("fields", false);
            try w.writeInt(u_info.fields_count);
            try w.key("methods", false);
            try w.writeInt(u_info.methods_count);
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.imports.items.len > 0) {
        try w.key("imports", false);
        try w.beginArray();
        for (file.imports.items, 0..) |*imp, ii| {
            if (ii > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("path", true);
            try w.writeString(imp.path);
            try w.key("kind", false);
            try w.writeString(@tagName(imp.kind));
            if (imp.binding_name.len > 0) {
                try w.key("as", false);
                try w.writeString(imp.binding_name);
            }
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.tests.items.len > 0) {
        try w.key("tests", false);
        try w.beginArray();
        for (file.tests.items, 0..) |*t, ti| {
            if (ti > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(t.name);
            try w.key("line", false);
            try w.writeInt(t.line);
            try w.endObject();
        }
        try w.endArray();
    }

    if (file.unsafe_ops.items.len > 0) {
        try w.key("unsafe_ops", false);
        try w.beginArray();
        for (file.unsafe_ops.items, 0..) |*op, oi| {
            if (oi > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("op", true);
            try w.writeString(op.operation);
            try w.key("line", false);
            try w.writeInt(op.line);
            try w.key("risk", false);
            try w.writeString(@tagName(op.risk_level));
            try w.endObject();
        }
        try w.endArray();
    }

    try w.endObject();
}

fn writeCompactData(w: *JsonWriter, report: *const models.ProjectReport) !void {
    // Key types (structs with most fields/methods)
    try w.key("key_types", false);
    try w.beginArray();
    var type_count: u32 = 0;
    for (report.files.items) |*file| {
        for (file.structs.items) |*s| {
            if (type_count > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(s.name);
            try w.key("file", false);
            try w.writeString(file.relative_path);
            try w.key("fields", false);
            try w.writeInt(s.fields_count);
            try w.key("methods", false);
            try w.writeInt(s.methods_count);
            if (s.doc_comment.len > 0) {
                try w.key("doc", false);
                try w.writeString(s.doc_comment);
            }
            try w.endObject();
            type_count += 1;
        }
        for (file.enums.items) |*e| {
            if (type_count > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(e.name);
            try w.key("file", false);
            try w.writeString(file.relative_path);
            try w.key("kind", false);
            try w.writeString("enum");
            try w.key("variants", false);
            try w.writeInt(e.variants_count);
            try w.endObject();
            type_count += 1;
        }
    }
    try w.endArray();

    // Public functions
    try w.key("pub_functions", false);
    try w.beginArray();
    var fn_count: u32 = 0;
    for (report.files.items) |*file| {
        for (file.functions.items) |*f| {
            if (!f.is_pub) continue;
            if (fn_count > 0) try w.comma();
            try w.newline();
            try w.beginObject();
            try w.key("name", true);
            try w.writeString(f.name);
            try w.key("file", false);
            try w.writeString(file.relative_path);
            if (f.params.len > 0) {
                try w.key("params", false);
                try w.writeString(f.params);
            }
            if (f.return_type.len > 0) {
                try w.key("return", false);
                try w.writeString(f.return_type);
            }
            if (f.doc_comment.len > 0) {
                try w.key("doc", false);
                try w.writeString(f.doc_comment);
            }
            try w.endObject();
            fn_count += 1;
        }
    }
    try w.endArray();

    // Dependency graph (imports per file)
    try w.key("dependency_graph", false);
    try w.beginObject();
    var first_dep = true;
    for (report.files.items) |*file| {
        if (file.imports.items.len == 0) continue;
        try w.key(file.relative_path, first_dep);
        first_dep = false;
        try w.beginArray();
        for (file.imports.items, 0..) |*imp, ii| {
            if (ii > 0) try w.comma();
            try w.writeString(imp.path);
        }
        try w.endArray();
    }
    try w.endObject();

    // Warnings (unsafe ops, high complexity functions)
    try w.key("warnings", false);
    try w.beginArray();
    var warn_count: u32 = 0;
    for (report.files.items) |*file| {
        for (file.unsafe_ops.items) |*op| {
            if (op.risk_level == .critical or op.risk_level == .high) {
                if (warn_count > 0) try w.comma();
                try w.newline();
                try w.beginObject();
                try w.key("type", true);
                try w.writeString("unsafe_op");
                try w.key("file", false);
                try w.writeString(file.relative_path);
                try w.key("line", false);
                try w.writeInt(op.line);
                try w.key("op", false);
                try w.writeString(op.operation);
                try w.key("risk", false);
                try w.writeString(@tagName(op.risk_level));
                try w.endObject();
                warn_count += 1;
            }
        }
        // Warn about large functions (>50 lines)
        for (file.functions.items) |*f| {
            if (f.body_lines > 50) {
                if (warn_count > 0) try w.comma();
                try w.newline();
                try w.beginObject();
                try w.key("type", true);
                try w.writeString("high_complexity");
                try w.key("file", false);
                try w.writeString(file.relative_path);
                try w.key("function", false);
                try w.writeString(f.name);
                try w.key("lines", false);
                try w.writeInt(f.body_lines);
                try w.endObject();
                warn_count += 1;
            }
        }
    }
    try w.endArray();
}
