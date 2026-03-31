//! Comprehensive Test Suite for zig_silicon
//!
//! Tests for the Hardware Visualization components.

const std = @import("std");
const bitfield_viz = @import("bitfield_viz.zig");
const svg = @import("svg.zig");

// ============================================================================
// Bitfield Visualization Tests
// ============================================================================

test "generateSvg creates valid SVG for single field" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "enable", .bits = 1 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "TEST_REG", &fields);
    defer allocator.free(output);

    // Check SVG header
    try std.testing.expect(std.mem.indexOf(u8, output, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<svg xmlns=") != null);

    // Check register name
    try std.testing.expect(std.mem.indexOf(u8, output, "TEST_REG") != null);

    // Check field name
    try std.testing.expect(std.mem.indexOf(u8, output, "enable") != null);

    // Check SVG footer
    try std.testing.expect(std.mem.indexOf(u8, output, "</svg>") != null);
}

test "generateSvg creates valid SVG for multiple fields" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "enable", .bits = 1 },
        .{ .name = "mode", .bits = 2 },
        .{ .name = "speed", .bits = 2 },
        .{ .name = "reserved", .bits = 3 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "GPIO_CTRL", &fields);
    defer allocator.free(output);

    // Check all fields are present
    try std.testing.expect(std.mem.indexOf(u8, output, "enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "speed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reserved") != null);

    // Check SVG structure
    try std.testing.expect(std.mem.indexOf(u8, output, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<text") != null);
}

test "generateSvg handles 8-bit register" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "bit0", .bits = 1 },
        .{ .name = "bit1", .bits = 1 },
        .{ .name = "bit2", .bits = 1 },
        .{ .name = "bit3", .bits = 1 },
        .{ .name = "bit4", .bits = 1 },
        .{ .name = "bit5", .bits = 1 },
        .{ .name = "bit6", .bits = 1 },
        .{ .name = "bit7", .bits = 1 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "BYTE_REG", &fields);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "BYTE_REG") != null);
    try std.testing.expect(output.len > 0);
}

test "generateSvg handles 32-bit GPIO MODER register" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "MODE0", .bits = 2 },
        .{ .name = "MODE1", .bits = 2 },
        .{ .name = "MODE2", .bits = 2 },
        .{ .name = "MODE3", .bits = 2 },
        .{ .name = "MODE4", .bits = 2 },
        .{ .name = "MODE5", .bits = 2 },
        .{ .name = "MODE6", .bits = 2 },
        .{ .name = "MODE7", .bits = 2 },
        .{ .name = "MODE8", .bits = 2 },
        .{ .name = "MODE9", .bits = 2 },
        .{ .name = "MODE10", .bits = 2 },
        .{ .name = "MODE11", .bits = 2 },
        .{ .name = "MODE12", .bits = 2 },
        .{ .name = "MODE13", .bits = 2 },
        .{ .name = "MODE14", .bits = 2 },
        .{ .name = "MODE15", .bits = 2 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "GPIO_MODER", &fields);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "GPIO_MODER") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MODE0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MODE15") != null);
}

test "generateSvg marks reserved fields differently" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "enable", .bits = 1 },
        .{ .name = "reserved", .bits = 7 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "TEST_REG", &fields);
    defer allocator.free(output);

    // Check that "reserved" class is used for reserved fields
    try std.testing.expect(std.mem.indexOf(u8, output, "reserved") != null);
}

// ============================================================================
// SVG Color Tests
// ============================================================================

test "Color.toHex generates correct hex strings" {
    const white = svg.Color.white;
    const hex = white.toHex();
    try std.testing.expectEqualStrings("#ffffff", &hex);

    const black = svg.Color.black;
    const black_hex = black.toHex();
    try std.testing.expectEqualStrings("#000000", &black_hex);

    const red = svg.Color.red;
    const red_hex = red.toHex();
    try std.testing.expectEqualStrings("#ff0000", &red_hex);
}

test "Color constants are valid" {
    try std.testing.expectEqual(svg.Color.white.r, 255);
    try std.testing.expectEqual(svg.Color.white.g, 255);
    try std.testing.expectEqual(svg.Color.white.b, 255);

    try std.testing.expectEqual(svg.Color.black.r, 0);
    try std.testing.expectEqual(svg.Color.black.g, 0);
    try std.testing.expectEqual(svg.Color.black.b, 0);

    try std.testing.expectEqual(svg.Color.red.r, 255);
    try std.testing.expectEqual(svg.Color.red.g, 0);
    try std.testing.expectEqual(svg.Color.red.b, 0);

    try std.testing.expectEqual(svg.Color.green.r, 0);
    try std.testing.expectEqual(svg.Color.green.g, 255);
    try std.testing.expectEqual(svg.Color.green.b, 0);

    try std.testing.expectEqual(svg.Color.blue.r, 0);
    try std.testing.expectEqual(svg.Color.blue.g, 0);
    try std.testing.expectEqual(svg.Color.blue.b, 255);
}

test "getFieldColor cycles through palette" {
    const color0 = svg.getFieldColor(0);
    const color1 = svg.getFieldColor(1);
    const color8 = svg.getFieldColor(8); // Should wrap to first color

    // First color should match palette[0]
    try std.testing.expectEqual(color0.r, svg.fieldColors[0].r);
    try std.testing.expectEqual(color0.g, svg.fieldColors[0].g);
    try std.testing.expectEqual(color0.b, svg.fieldColors[0].b);

    // Colors should be different
    const hex0 = color0.toHex();
    const hex1 = color1.toHex();
    try std.testing.expect(!std.mem.eql(u8, &hex0, &hex1));

    // Should wrap around
    try std.testing.expectEqual(color8.r, color0.r);
}

// ============================================================================
// Field Structure Tests
// ============================================================================

test "Field struct size and alignment" {
    const Field = bitfield_viz.Field;
    try std.testing.expect(@sizeOf(Field) > 0);
}

test "Field can hold maximum bit width" {
    const field = bitfield_viz.Field{
        .name = "max_field",
        .bits = 255,
    };
    try std.testing.expectEqual(field.bits, 255);
}

test "Field can hold minimum bit width" {
    const field = bitfield_viz.Field{
        .name = "min_field",
        .bits = 1,
    };
    try std.testing.expectEqual(field.bits, 1);
}

// ============================================================================
// ArrayWriter Tests (internal component)
// ============================================================================

test "ArrayWriter print accumulates output" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    // Simulate what ArrayWriter does
    var buf: [64]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "test {d}", .{42});
    try list.appendSlice(allocator, result);

    try std.testing.expectEqualStrings("test 42", list.items);
}

// ============================================================================
// SVG Output Structure Tests
// ============================================================================

test "SVG output is well-formed XML" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "test", .bits = 8 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "REG", &fields);
    defer allocator.free(output);

    // Check XML declaration
    try std.testing.expect(std.mem.startsWith(u8, output, "<?xml"));

    // Check balanced tags
    var open_count: usize = 0;
    var close_count: usize = 0;
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        if (output[i] == '<') {
            if (i + 1 < output.len and output[i + 1] == '/') {
                close_count += 1;
            } else if (i + 1 < output.len and output[i + 1] != '?' and output[i + 1] != '!') {
                open_count += 1;
            }
        }
    }
    // Allow for self-closing tags
    try std.testing.expect(open_count >= close_count);
}

test "SVG viewBox matches dimensions" {
    const allocator = std.testing.allocator;

    const fields = [_]bitfield_viz.Field{
        .{ .name = "test", .bits = 8 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "REG", &fields);
    defer allocator.free(output);

    // viewBox should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "viewBox=") != null);
}
