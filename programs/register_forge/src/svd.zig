//! SVD (System View Description) Parser
//!
//! Parses ARM CMSIS-SVD files which describe microcontroller peripherals.
//! SVD is an XML-based format standardized by ARM.

const std = @import("std");

pub const Device = struct {
    name: []const u8,
    description: []const u8,
    peripherals: []const Peripheral,

    pub fn deinit(self: *const Device, allocator: std.mem.Allocator) void {
        // Free all nested allocations
        for (self.peripherals) |peripheral| {
            for (peripheral.registers) |register| {
                if (register.fields.len > 0) {
                    allocator.free(register.fields);
                }
            }
            if (peripheral.registers.len > 0) {
                allocator.free(peripheral.registers);
            }
        }
        if (self.peripherals.len > 0) {
            allocator.free(self.peripherals);
        }
    }
};

pub const Peripheral = struct {
    name: []const u8,
    description: []const u8,
    base_address: u32,
    registers: []const Register,
};

pub const Register = struct {
    name: []const u8,
    description: []const u8,
    offset: u32,
    size: u8, // bits (typically 8, 16, or 32)
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    description: []const u8,
    bit_offset: u8,
    bit_width: u8,
};

/// Parse SVD XML content into a Device structure
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Device {
    // Simplified XML parsing - in production would use proper XML parser
    var device = Device{
        .name = "Unknown",
        .description = "",
        .peripherals = &[_]Peripheral{},
    };

    var peripherals: std.ArrayListUnmanaged(Peripheral) = .empty;
    errdefer peripherals.deinit(allocator);

    // Find device name
    if (findTagContent(content, "name")) |name| {
        device.name = name;
    }

    // Find peripherals
    var periph_iter = TagIterator.init(content, "peripheral");
    while (periph_iter.next()) |periph_content| {
        const peripheral = try parsePeripheral(allocator, periph_content);
        try peripherals.append(allocator, peripheral);
    }

    device.peripherals = try peripherals.toOwnedSlice(allocator);
    return device;
}

fn parsePeripheral(allocator: std.mem.Allocator, content: []const u8) !Peripheral {
    var peripheral = Peripheral{
        .name = findTagContent(content, "name") orelse "Unknown",
        .description = findTagContent(content, "description") orelse "",
        .base_address = 0,
        .registers = &[_]Register{},
    };

    // Parse base address
    if (findTagContent(content, "baseAddress")) |addr_str| {
        peripheral.base_address = parseHexOrDec(addr_str);
    }

    // Parse registers
    var registers: std.ArrayListUnmanaged(Register) = .empty;
    errdefer registers.deinit(allocator);

    var reg_iter = TagIterator.init(content, "register");
    while (reg_iter.next()) |reg_content| {
        const register = try parseRegister(allocator, reg_content);
        try registers.append(allocator, register);
    }

    peripheral.registers = try registers.toOwnedSlice(allocator);
    return peripheral;
}

fn parseRegister(allocator: std.mem.Allocator, content: []const u8) !Register {
    var register = Register{
        .name = findTagContent(content, "name") orelse "Unknown",
        .description = findTagContent(content, "description") orelse "",
        .offset = 0,
        .size = 32,
        .fields = &[_]Field{},
    };

    // Parse offset
    if (findTagContent(content, "addressOffset")) |offset_str| {
        register.offset = parseHexOrDec(offset_str);
    }

    // Parse size
    if (findTagContent(content, "size")) |size_str| {
        register.size = @truncate(parseHexOrDec(size_str));
    }

    // Parse fields
    var fields: std.ArrayListUnmanaged(Field) = .empty;
    errdefer fields.deinit(allocator);

    var field_iter = TagIterator.init(content, "field");
    while (field_iter.next()) |field_content| {
        const field = parseField(field_content);
        try fields.append(allocator, field);
    }

    register.fields = try fields.toOwnedSlice(allocator);
    return register;
}

fn parseField(content: []const u8) Field {
    var field = Field{
        .name = findTagContent(content, "name") orelse "Unknown",
        .description = findTagContent(content, "description") orelse "",
        .bit_offset = 0,
        .bit_width = 1,
    };

    // Parse bit offset
    if (findTagContent(content, "bitOffset")) |offset_str| {
        field.bit_offset = @truncate(parseHexOrDec(offset_str));
    } else if (findTagContent(content, "lsb")) |lsb_str| {
        field.bit_offset = @truncate(parseHexOrDec(lsb_str));
    }

    // Parse bit width
    if (findTagContent(content, "bitWidth")) |width_str| {
        field.bit_width = @truncate(parseHexOrDec(width_str));
    } else if (findTagContent(content, "msb")) |msb_str| {
        const msb = parseHexOrDec(msb_str);
        field.bit_width = @truncate(msb - field.bit_offset + 1);
    }

    return field;
}

/// Simple tag content finder
fn findTagContent(xml: []const u8, tag: []const u8) ?[]const u8 {
    const open_tag_start = std.mem.indexOf(u8, xml, "<") orelse return null;
    _ = open_tag_start;

    // Build search strings
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;

    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;

    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOf(u8, xml[start..], close) orelse return null;

    return xml[start..][0..end];
}

/// Iterator for finding all instances of a tag
const TagIterator = struct {
    content: []const u8,
    tag: []const u8,
    pos: usize,

    pub fn init(content: []const u8, tag: []const u8) TagIterator {
        return .{
            .content = content,
            .tag = tag,
            .pos = 0,
        };
    }

    pub fn next(self: *TagIterator) ?[]const u8 {
        var open_buf: [64]u8 = undefined;
        var close_buf: [64]u8 = undefined;

        const open = std.fmt.bufPrint(&open_buf, "<{s}", .{self.tag}) catch return null;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{self.tag}) catch return null;

        const remaining = self.content[self.pos..];
        const start = std.mem.indexOf(u8, remaining, open) orelse return null;
        const content_start = start + open.len;

        const end_rel = std.mem.indexOf(u8, remaining[content_start..], close) orelse return null;
        const end = content_start + end_rel + close.len;

        self.pos += end;

        return remaining[start..end];
    }
};

/// Parse hex (0x...) or decimal number
fn parseHexOrDec(str: []const u8) u32 {
    const trimmed = std.mem.trim(u8, str, " \t\n\r");

    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return std.fmt.parseInt(u32, trimmed[2..], 16) catch 0;
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

test "parseHexOrDec" {
    try std.testing.expectEqual(parseHexOrDec("0x40020000"), 0x40020000);
    try std.testing.expectEqual(parseHexOrDec("123"), 123);
    try std.testing.expectEqual(parseHexOrDec("0X10"), 16);
}

test "findTagContent" {
    const xml = "<device><name>STM32F401</name><version>1.0</version></device>";
    try std.testing.expectEqualStrings("STM32F401", findTagContent(xml, "name").?);
    try std.testing.expectEqualStrings("1.0", findTagContent(xml, "version").?);
}
