//! Zig Silicon - Educational Hardware Visualization
//!
//! CLI tool for visualizing how Zig code interacts with hardware.

const std = @import("std");
const svg = @import("svg.zig");
const bitfield_viz = @import("bitfield_viz.zig");

// Global IO context from init
var global_io: std.Io = undefined;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    global_io = init.io;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(allocator, arg) catch {
            std.debug.print("zig-silicon: failed to parse arguments\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "bitfield")) {
        bitfieldCommand(allocator, args[2..]) catch {
            std.debug.print("zig-silicon: bitfield command failed\n", .{});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "demo")) {
        demoCommand(allocator) catch {
            std.debug.print("zig-silicon: demo command failed\n", .{});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Zig Silicon - Hardware Visualization Tool
        \\
        \\Usage:
        \\  zig-silicon bitfield <name> <bits...>   Generate bitfield SVG
        \\  zig-silicon demo                        Generate demo visualizations
        \\  zig-silicon help                        Show this help
        \\
        \\Examples:
        \\  zig-silicon bitfield GPIO_MODER MODE0:2 MODE1:2 MODE2:2 ...
        \\  zig-silicon demo
        \\
    , .{});
}

fn bitfieldCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: zig-silicon bitfield <name> <field:bits>...\n", .{});
        return;
    }

    const name = args[0];
    var fields: std.ArrayListUnmanaged(bitfield_viz.Field) = .empty;
    defer fields.deinit(allocator);

    for (args[1..]) |arg| {
        var iter = std.mem.splitScalar(u8, arg, ':');
        const field_name = iter.next() orelse continue;
        const bits_str = iter.next() orelse "1";
        const bits = std.fmt.parseInt(u8, bits_str, 10) catch 1;

        try fields.append(allocator, .{
            .name = field_name,
            .bits = bits,
        });
    }

    const output = try bitfield_viz.generateSvg(allocator, name, fields.items);
    defer allocator.free(output);

    std.debug.print("{s}", .{output});
}

fn demoCommand(allocator: std.mem.Allocator) !void {
    const io = global_io;

    std.debug.print("Generating demo visualizations...\n\n", .{});

    // Demo 1: GPIO MODER register
    const gpio_moder_fields = [_]bitfield_viz.Field{
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

    const moder_svg = try bitfield_viz.generateSvg(allocator, "GPIO_MODER", &gpio_moder_fields);
    defer allocator.free(moder_svg);

    const file = try std.Io.Dir.cwd().createFile(io, "gpio_moder.svg", .{});
    defer file.close(io);
    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(moder_svg);
    try writer.interface.flush();

    std.debug.print("Created: gpio_moder.svg\n", .{});

    // Demo 2: RCC AHB1ENR register
    const ahb1enr_fields = [_]bitfield_viz.Field{
        .{ .name = "GPIOAEN", .bits = 1 },
        .{ .name = "GPIOBEN", .bits = 1 },
        .{ .name = "GPIOCEN", .bits = 1 },
        .{ .name = "GPIODEN", .bits = 1 },
        .{ .name = "GPIOEEN", .bits = 1 },
        .{ .name = "reserved", .bits = 2 },
        .{ .name = "GPIOHEN", .bits = 1 },
        .{ .name = "reserved", .bits = 4 },
        .{ .name = "CRCEN", .bits = 1 },
        .{ .name = "reserved", .bits = 5 },
        .{ .name = "BKPSRAMEN", .bits = 1 },
        .{ .name = "reserved", .bits = 1 },
        .{ .name = "CCMDATARAMEN", .bits = 1 },
        .{ .name = "DMA1EN", .bits = 1 },
        .{ .name = "DMA2EN", .bits = 1 },
        .{ .name = "reserved", .bits = 9 },
    };

    const ahb1enr_svg = try bitfield_viz.generateSvg(allocator, "RCC_AHB1ENR", &ahb1enr_fields);
    defer allocator.free(ahb1enr_svg);

    const file2 = try std.Io.Dir.cwd().createFile(io, "rcc_ahb1enr.svg", .{});
    defer file2.close(io);
    var write_buf2: [8192]u8 = undefined;
    var writer2 = file2.writer(io, &write_buf2);
    try writer2.interface.writeAll(ahb1enr_svg);
    try writer2.interface.flush();

    std.debug.print("Created: rcc_ahb1enr.svg\n", .{});

    std.debug.print("\nDone! Open the SVG files in a browser to view.\n", .{});
}

test "main compiles" {
    _ = svg;
    _ = bitfield_viz;
}

// Import comprehensive test module
test {
    _ = @import("tests.zig");
    _ = @import("bench.zig");
}
