// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Streaming JSON writer with proper escaping and optional pretty-printing.

const std = @import("std");

pub const JsonWriter = struct {
    file: *std.c.FILE,
    pretty: bool,
    depth: usize,
    needs_comma: bool,
    needs_newline: bool, // true after opening a container
    in_key: bool,

    // Stack to track array/object nesting for comma handling
    stack: [64]ContainerType,
    stack_len: usize,

    const ContainerType = enum { object, array };

    pub fn init(file: *std.c.FILE, pretty: bool) JsonWriter {
        return .{
            .file = file,
            .pretty = pretty,
            .depth = 0,
            .needs_comma = false,
            .needs_newline = false,
            .in_key = false,
            .stack = undefined,
            .stack_len = 0,
        };
    }

    pub fn beginObject(self: *JsonWriter) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeChar('{');
        self.push(.object);
        self.depth += 1;
        self.needs_comma = false;
        self.needs_newline = true;
    }

    pub fn endObject(self: *JsonWriter) void {
        self.depth -= 1;
        if (self.needs_comma and self.pretty) {
            self.writeNewline();
            self.writeIndent();
        }
        self.writeChar('}');
        self.pop();
        self.needs_comma = true;
    }

    pub fn beginArray(self: *JsonWriter) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeChar('[');
        self.push(.array);
        self.depth += 1;
        self.needs_comma = false;
        self.needs_newline = true;
    }

    pub fn endArray(self: *JsonWriter) void {
        self.depth -= 1;
        if (self.needs_comma and self.pretty) {
            self.writeNewline();
            self.writeIndent();
        }
        self.writeChar(']');
        self.pop();
        self.needs_comma = true;
    }

    pub fn key(self: *JsonWriter, k: []const u8) void {
        self.writeCommaIfNeeded();
        self.writeEscapedString(k);
        self.writeChar(':');
        if (self.pretty) self.writeChar(' ');
        self.needs_comma = false;
        self.in_key = true;
    }

    pub fn string(self: *JsonWriter, s: []const u8) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeEscapedString(s);
        self.needs_comma = true;
    }

    pub fn number(self: *JsonWriter, n: []const u8) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeBytes(n);
        self.needs_comma = true;
    }

    pub fn writeNull(self: *JsonWriter) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeBytes("null");
        self.needs_comma = true;
    }

    pub fn writeBool(self: *JsonWriter, v: bool) void {
        if (!self.in_key) {
            self.writeCommaIfNeeded();
        }
        self.in_key = false;
        self.writeBytes(if (v) "true" else "false");
        self.needs_comma = true;
    }

    pub fn newline(self: *JsonWriter) void {
        self.writeChar('\n');
    }

    // ========================================================================
    // Internal
    // ========================================================================

    fn writeCommaIfNeeded(self: *JsonWriter) void {
        if (self.needs_comma) {
            self.writeChar(',');
        }
        if (self.pretty and !self.in_key and (self.needs_comma or self.needs_newline)) {
            self.writeNewline();
            self.writeIndent();
        }
        self.needs_newline = false;
    }

    fn writeEscapedString(self: *JsonWriter, s: []const u8) void {
        self.writeChar('"');
        for (s) |c| {
            switch (c) {
                '"' => self.writeBytes("\\\""),
                '\\' => self.writeBytes("\\\\"),
                '\n' => self.writeBytes("\\n"),
                '\r' => self.writeBytes("\\r"),
                '\t' => self.writeBytes("\\t"),
                0x08 => self.writeBytes("\\b"),
                0x0C => self.writeBytes("\\f"),
                else => {
                    if (c < 0x20) {
                        // Control character: \u00XX
                        var buf: [6]u8 = undefined;
                        buf[0] = '\\';
                        buf[1] = 'u';
                        buf[2] = '0';
                        buf[3] = '0';
                        buf[4] = hexDigit(c >> 4);
                        buf[5] = hexDigit(c & 0x0F);
                        self.writeBytes(&buf);
                    } else {
                        self.writeChar(c);
                    }
                },
            }
        }
        self.writeChar('"');
    }

    fn writeIndent(self: *JsonWriter) void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) {
            self.writeBytes("  ");
        }
    }

    fn writeNewline(self: *JsonWriter) void {
        self.writeChar('\n');
    }

    fn writeChar(self: *JsonWriter, c: u8) void {
        var buf = [1]u8{c};
        _ = std.c.fwrite(&buf, 1, 1, self.file);
    }

    fn writeBytes(self: *JsonWriter, bytes: []const u8) void {
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, self.file);
    }

    fn push(self: *JsonWriter, ct: ContainerType) void {
        if (self.stack_len < self.stack.len) {
            self.stack[self.stack_len] = ct;
            self.stack_len += 1;
        }
    }

    fn pop(self: *JsonWriter) void {
        if (self.stack_len > 0) self.stack_len -= 1;
    }
};

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}
