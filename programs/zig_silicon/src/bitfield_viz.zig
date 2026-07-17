//! Bitfield Visualization
//!
//! Generates SVG diagrams showing the bit layout of hardware registers.
//! Each field is shown as a colored box with its name and bit range.

const std = @import("std");

pub const Field = struct {
    name: []const u8,
    bits: u8,
};

/// Simple writer wrapper for ArrayListUnmanaged
const ArrayWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn print(self: *ArrayWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch return error.BufferOverflow;
        try self.list.appendSlice(self.allocator, result);
    }

    pub fn writeAll(self: *ArrayWriter, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }

    /// Write `data` with XML metacharacters (& < > " ') escaped to their
    /// entity references, so caller-supplied names cannot break out of the
    /// surrounding element or inject markup into the SVG.
    pub fn writeEscapedXml(self: *ArrayWriter, data: []const u8) !void {
        for (data) |c| {
            switch (c) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                '"' => try self.writeAll("&quot;"),
                '\'' => try self.writeAll("&apos;"),
                else => try self.list.append(self.allocator, c),
            }
        }
    }
};

/// Generate an SVG visualization of a register's bit layout
pub fn generateSvg(allocator: std.mem.Allocator, name: []const u8, fields: []const Field) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var writer = ArrayWriter{ .list = &output, .allocator = allocator };

    // Calculate total bits. A zero-width field is rejected up front: it would
    // later drive `bit_pos - 1` below zero, panicking (Debug/ReleaseSafe) or
    // wrapping to a huge value (ReleaseFast) when the running bit position has
    // already reached 0.
    var total_bits: u32 = 0;
    for (fields) |f| {
        if (f.bits == 0) return error.InvalidField;
        total_bits += f.bits;
    }
    if (total_bits == 0) return error.InvalidField;

    // SVG dimensions
    const bit_width: u32 = 30;
    const height: u32 = 80;
    const padding: u32 = 20;
    const width = total_bits * bit_width + padding * 2;

    // SVG header
    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d} {d}" width="{d}" height="{d}">
        \\  <style>
        \\    .field {{ stroke: #333; stroke-width: 1; }}
        \\    .field-name {{ font-family: monospace; font-size: 10px; fill: #333; }}
        \\    .bit-num {{ font-family: monospace; font-size: 8px; fill: #666; }}
        \\    .title {{ font-family: sans-serif; font-size: 14px; font-weight: bold; fill: #000; }}
        \\    .reserved {{ fill: #ddd; }}
        \\    .active {{ fill: #90EE90; }}
        \\  </style>
        \\
        \\  <!-- Title -->
        \\  <text x="{d}" y="15" class="title" text-anchor="middle">
    , .{ width, height + 40, width, height + 40, width / 2 });
    try writer.writeEscapedXml(name);
    try writer.writeAll("</text>\n");

    // Draw fields from MSB to LSB (left to right)
    var x: u32 = padding;
    var bit_pos: u32 = total_bits;

    for (fields) |field| {
        const field_width = @as(u32, field.bits) * bit_width;
        const start_bit = bit_pos - 1;
        const end_bit = bit_pos - field.bits;
        bit_pos -= field.bits;

        // Determine fill color
        const fill_class = if (std.mem.eql(u8, field.name, "reserved"))
            "reserved"
        else
            "active";

        // Draw field box
        try writer.print(
            \\  <rect x="{d}" y="25" width="{d}" height="40" class="field {s}"/>
            \\
        , .{ x, field_width, fill_class });

        // Draw field name (centered)
        const text_x = x + field_width / 2;
        try writer.print(
            \\  <text x="{d}" y="50" class="field-name" text-anchor="middle">
        , .{text_x});
        try writer.writeEscapedXml(field.name);
        try writer.writeAll("</text>\n");

        // Draw bit numbers
        if (field.bits == 1) {
            try writer.print(
                \\  <text x="{d}" y="75" class="bit-num" text-anchor="middle">{d}</text>
                \\
            , .{ text_x, start_bit });
        } else {
            try writer.print(
                \\  <text x="{d}" y="75" class="bit-num" text-anchor="middle">{d}:{d}</text>
                \\
            , .{ text_x, start_bit, end_bit });
        }

        x += field_width;
    }

    // Draw bit position markers at top
    try writer.writeAll("  <!-- Bit positions -->\n");
    x = padding;
    bit_pos = total_bits;
    for (0..total_bits) |_| {
        bit_pos -= 1;
        if (bit_pos % 4 == 3) {
            try writer.print(
                \\  <text x="{d}" y="22" class="bit-num" text-anchor="middle">{d}</text>
                \\
            , .{ x + bit_width / 2, bit_pos });
        }
        x += bit_width;
    }

    // SVG footer
    try writer.writeAll("</svg>\n");

    return output.toOwnedSlice(allocator);
}

test "generateSvg basic" {
    const allocator = std.testing.allocator;

    const fields = [_]Field{
        .{ .name = "enable", .bits = 1 },
        .{ .name = "mode", .bits = 2 },
        .{ .name = "reserved", .bits = 5 },
    };

    const output = try generateSvg(allocator, "TEST_REG", &fields);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "TEST_REG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<svg") != null);
}

test "generateSvg rejects a zero-width field (underflow guard)" {
    const allocator = std.testing.allocator;

    // Zero-width field after real bits: previously underflowed `bit_pos - 1`.
    const fields = [_]Field{
        .{ .name = "a", .bits = 8 },
        .{ .name = "b", .bits = 0 },
    };
    try std.testing.expectError(error.InvalidField, generateSvg(allocator, "R", &fields));

    // Lone zero-width field: total_bits == 0.
    const lone = [_]Field{.{ .name = "a", .bits = 0 }};
    try std.testing.expectError(error.InvalidField, generateSvg(allocator, "R", &lone));
}

test "generateSvg rejects an empty field list" {
    const allocator = std.testing.allocator;
    const empty = [_]Field{};
    try std.testing.expectError(error.InvalidField, generateSvg(allocator, "R", &empty));
}

test "generateSvg XML-escapes register and field names" {
    const allocator = std.testing.allocator;

    const fields = [_]Field{
        .{ .name = "R&W<x>\"'", .bits = 2 },
    };
    const output = try generateSvg(allocator, "A&B<C>\"'", &fields);
    defer allocator.free(output);

    // Raw metacharacters from the names must not survive into element text.
    try std.testing.expect(std.mem.indexOf(u8, output, "A&B") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "R&W") == null);
    // Escaped entity forms must be present for every metacharacter.
    try std.testing.expect(std.mem.indexOf(u8, output, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&apos;") != null);
}
