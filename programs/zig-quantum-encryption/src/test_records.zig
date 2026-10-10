//! Reader for the `key=value` record files under testdata/ (test-only).
//!
//! A record is a run of `key=value` lines; records are separated by blank lines and `#` lines
//! are comments. The files are verbatim extracts of published vector sets (see the header of
//! each file and tools/extract_acvp.py), so this reader computes nothing: it only splits text.

const std = @import("std");

pub const Record = struct {
    lines: []const u8,

    pub fn get(self: Record, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.lines, '\n');
        while (it.next()) |line| {
            if (line.len > key.len and line[key.len] == '=' and std.mem.startsWith(u8, line, key))
                return line[key.len + 1 ..];
        }
        return null;
    }

    pub fn str(self: Record, key: []const u8) []const u8 {
        return self.get(key) orelse std.debug.panic("record lacks key '{s}':\n{s}", .{ key, self.lines });
    }

    pub fn flag(self: Record, key: []const u8) bool {
        return std.mem.eql(u8, self.str(key), "true");
    }

    /// Decode a hex field into a fixed-size array; the length must match exactly.
    pub fn fixed(self: Record, comptime n: usize, key: []const u8) ![n]u8 {
        const h = self.str(key);
        if (h.len != 2 * n) return error.WrongVectorLength;
        var out: [n]u8 = undefined;
        _ = try std.fmt.hexToBytes(&out, h);
        return out;
    }

    /// Decode a hex field of any length; caller frees.
    pub fn bytes(self: Record, a: std.mem.Allocator, key: []const u8) ![]u8 {
        const h = self.str(key);
        if (h.len % 2 != 0) return error.OddHexLength;
        const out = try a.alloc(u8, h.len / 2);
        errdefer a.free(out);
        _ = try std.fmt.hexToBytes(out, h);
        return out;
    }
};

pub const Iterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *Iterator) ?Record {
        // Skip blank and comment lines.
        while (self.pos < self.text.len) {
            const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            const line = self.text[self.pos..end];
            if (line.len != 0 and line[0] != '#') break;
            self.pos = @min(end + 1, self.text.len);
        }
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        const stop = std.mem.indexOfPos(u8, self.text, self.pos, "\n\n") orelse self.text.len;
        self.pos = @min(stop + 2, self.text.len);
        return .{ .lines = self.text[start..stop] };
    }
};

pub fn iterate(text: []const u8) Iterator {
    return .{ .text = text };
}

/// Number of records in `text`; tests assert it so a truncated file cannot pass vacuously.
pub fn count(text: []const u8) usize {
    var it = iterate(text);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}
