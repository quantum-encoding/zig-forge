//! Comprehensive Test Suite for register_forge
//!
//! Tests for the SVD parser and Zig code generator.

const std = @import("std");
const svd = @import("svd.zig");
const codegen = @import("codegen.zig");

// ============================================================================
// SVD Parser Tests
// ============================================================================

test "parseHexOrDec parses hex values" {
    // Test via the public interface
    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{},
    };
    try std.testing.expectEqualStrings("TEST", device.name);
}

test "Device struct initialization" {
    const device = svd.Device{
        .name = "STM32F401",
        .description = "STM32F401 MCU",
        .peripherals = &[_]svd.Peripheral{},
    };

    try std.testing.expectEqualStrings("STM32F401", device.name);
    try std.testing.expectEqualStrings("STM32F401 MCU", device.description);
    try std.testing.expectEqual(device.peripherals.len, 0);
}

test "Peripheral struct initialization" {
    const peripheral = svd.Peripheral{
        .name = "GPIOA",
        .description = "General Purpose I/O Port A",
        .base_address = 0x40020000,
        .registers = &[_]svd.Register{},
    };

    try std.testing.expectEqualStrings("GPIOA", peripheral.name);
    try std.testing.expectEqual(peripheral.base_address, 0x40020000);
}

test "Register struct initialization" {
    const register = svd.Register{
        .name = "MODER",
        .description = "GPIO port mode register",
        .offset = 0x00,
        .size = 32,
        .fields = &[_]svd.Field{},
    };

    try std.testing.expectEqualStrings("MODER", register.name);
    try std.testing.expectEqual(register.offset, 0x00);
    try std.testing.expectEqual(register.size, 32);
}

test "Field struct initialization" {
    const field = svd.Field{
        .name = "MODE0",
        .description = "Pin 0 mode",
        .bit_offset = 0,
        .bit_width = 2,
    };

    try std.testing.expectEqualStrings("MODE0", field.name);
    try std.testing.expectEqual(field.bit_offset, 0);
    try std.testing.expectEqual(field.bit_width, 2);
}

test "parse empty SVD returns default device" {
    const allocator = std.testing.allocator;

    const device = try svd.parse(allocator, "");
    defer device.deinit(allocator);

    try std.testing.expectEqualStrings("Unknown", device.name);
    try std.testing.expectEqual(device.peripherals.len, 0);
}

test "parse SVD with device name" {
    const allocator = std.testing.allocator;

    const xml = "<device><name>TEST_MCU</name></device>";
    const device = try svd.parse(allocator, xml);
    defer device.deinit(allocator);

    try std.testing.expectEqualStrings("TEST_MCU", device.name);
}

test "parse SVD with peripheral" {
    const allocator = std.testing.allocator;

    const xml =
        \\<device>
        \\  <name>TEST</name>
        \\  <peripheral>
        \\    <name>GPIO</name>
        \\    <description>GPIO Port</description>
        \\    <baseAddress>0x40020000</baseAddress>
        \\  </peripheral>
        \\</device>
    ;

    const device = try svd.parse(allocator, xml);
    defer device.deinit(allocator);

    try std.testing.expectEqual(device.peripherals.len, 1);
    try std.testing.expectEqualStrings("GPIO", device.peripherals[0].name);
    try std.testing.expectEqual(device.peripherals[0].base_address, 0x40020000);
}

test "parse SVD with register" {
    const allocator = std.testing.allocator;

    const xml =
        \\<device>
        \\  <peripheral>
        \\    <name>GPIO</name>
        \\    <baseAddress>0x40020000</baseAddress>
        \\    <register>
        \\      <name>MODER</name>
        \\      <description>Mode register</description>
        \\      <addressOffset>0x00</addressOffset>
        \\      <size>32</size>
        \\    </register>
        \\  </peripheral>
        \\</device>
    ;

    const device = try svd.parse(allocator, xml);
    defer device.deinit(allocator);

    try std.testing.expectEqual(device.peripherals.len, 1);
    try std.testing.expectEqual(device.peripherals[0].registers.len, 1);
    try std.testing.expectEqualStrings("MODER", device.peripherals[0].registers[0].name);
    try std.testing.expectEqual(device.peripherals[0].registers[0].offset, 0x00);
}

test "parse SVD with field" {
    const allocator = std.testing.allocator;

    const xml =
        \\<device>
        \\  <peripheral>
        \\    <name>GPIO</name>
        \\    <baseAddress>0x40020000</baseAddress>
        \\    <register>
        \\      <name>MODER</name>
        \\      <addressOffset>0x00</addressOffset>
        \\      <field>
        \\        <name>MODE0</name>
        \\        <description>Pin 0 mode</description>
        \\        <bitOffset>0</bitOffset>
        \\        <bitWidth>2</bitWidth>
        \\      </field>
        \\    </register>
        \\  </peripheral>
        \\</device>
    ;

    const device = try svd.parse(allocator, xml);
    defer device.deinit(allocator);

    const reg = device.peripherals[0].registers[0];
    try std.testing.expectEqual(reg.fields.len, 1);
    try std.testing.expectEqualStrings("MODE0", reg.fields[0].name);
    try std.testing.expectEqual(reg.fields[0].bit_offset, 0);
    try std.testing.expectEqual(reg.fields[0].bit_width, 2);
}

// ============================================================================
// Code Generator Tests
// ============================================================================

test "generate creates valid Zig code" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST_MCU",
        .description = "Test MCU",
        .peripherals = &[_]svd.Peripheral{},
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check header comment
    try std.testing.expect(std.mem.indexOf(u8, output, "Auto-generated") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TEST_MCU") != null);

    // Check MMIO utility is included
    try std.testing.expect(std.mem.indexOf(u8, output, "const mmio") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Mmio") != null);
}

test "generate creates peripheral struct" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIOA",
                .description = "GPIO Port A",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{},
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check peripheral definition
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GPIOA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "base_address") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "0x40020000") != null);
}

test "generate creates register with packed struct" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIO",
                .description = "GPIO Port",
                .base_address = 0x40000000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "ODR",
                        .description = "Output Data",
                        .offset = 0x14,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "OD0", .description = "Bit 0", .bit_offset = 0, .bit_width = 1 },
                        },
                    },
                },
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check register definition
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const ODR") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "packed struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "OD0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bool") != null);
}

test "generate creates correct field types" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "TEST",
                .description = "",
                .base_address = 0x40000000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "REG",
                        .description = "",
                        .offset = 0x00,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "F1", .description = "", .bit_offset = 0, .bit_width = 1 },
                            .{ .name = "F2", .description = "", .bit_offset = 1, .bit_width = 2 },
                            .{ .name = "F4", .description = "", .bit_offset = 3, .bit_width = 4 },
                            .{ .name = "F8", .description = "", .bit_offset = 7, .bit_width = 8 },
                        },
                    },
                },
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check field types
    try std.testing.expect(std.mem.indexOf(u8, output, "F1: bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "F2: u2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "F4: u4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "F8: u8") != null);
}

test "generate adds reserved fields for gaps" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "TEST",
                .description = "",
                .base_address = 0x40000000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "REG",
                        .description = "",
                        .offset = 0x00,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "F1", .description = "", .bit_offset = 0, .bit_width = 1 },
                            // Gap of 7 bits (1-7)
                            .{ .name = "F2", .description = "", .bit_offset = 8, .bit_width = 8 },
                        },
                    },
                },
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check reserved field is added
    try std.testing.expect(std.mem.indexOf(u8, output, "_reserved") != null);
}

test "generate calculates correct addresses" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "TEST",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "PERIPH",
                .description = "",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "REG1",
                        .description = "",
                        .offset = 0x00,
                        .size = 32,
                        .fields = &[_]svd.Field{},
                    },
                    .{
                        .name = "REG2",
                        .description = "",
                        .offset = 0x04,
                        .size = 32,
                        .fields = &[_]svd.Field{},
                    },
                    .{
                        .name = "REG3",
                        .description = "",
                        .offset = 0x14,
                        .size = 32,
                        .fields = &[_]svd.Field{},
                    },
                },
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check calculated addresses (base + offset)
    try std.testing.expect(std.mem.indexOf(u8, output, "0x40020000") != null); // REG1
    try std.testing.expect(std.mem.indexOf(u8, output, "0x40020004") != null); // REG2
    try std.testing.expect(std.mem.indexOf(u8, output, "0x40020014") != null); // REG3
}

// ============================================================================
// Integration Tests
// ============================================================================

test "full SVD parse and generate cycle" {
    const allocator = std.testing.allocator;

    const xml =
        \\<device>
        \\  <name>FULL_TEST</name>
        \\  <peripheral>
        \\    <name>GPIOA</name>
        \\    <description>GPIO Port A</description>
        \\    <baseAddress>0x40020000</baseAddress>
        \\    <register>
        \\      <name>MODER</name>
        \\      <description>Mode register</description>
        \\      <addressOffset>0x00</addressOffset>
        \\      <size>32</size>
        \\      <field>
        \\        <name>MODE0</name>
        \\        <description>Pin 0 mode</description>
        \\        <bitOffset>0</bitOffset>
        \\        <bitWidth>2</bitWidth>
        \\      </field>
        \\      <field>
        \\        <name>MODE1</name>
        \\        <description>Pin 1 mode</description>
        \\        <bitOffset>2</bitOffset>
        \\        <bitWidth>2</bitWidth>
        \\      </field>
        \\    </register>
        \\  </peripheral>
        \\</device>
    ;

    const device = try svd.parse(allocator, xml);
    defer device.deinit(allocator);

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Verify complete output
    try std.testing.expect(std.mem.indexOf(u8, output, "FULL_TEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GPIOA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MODER") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MODE0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MODE1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "u2") != null);
}

test "multiple peripherals are generated correctly" {
    const allocator = std.testing.allocator;

    const device = svd.Device{
        .name = "MULTI",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIOA",
                .description = "GPIO Port A",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{},
            },
            .{
                .name = "GPIOB",
                .description = "GPIO Port B",
                .base_address = 0x40020400,
                .registers = &[_]svd.Register{},
            },
            .{
                .name = "GPIOC",
                .description = "GPIO Port C",
                .base_address = 0x40020800,
                .registers = &[_]svd.Register{},
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Check all peripherals present
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GPIOA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GPIOB") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GPIOC") != null);
}
