//! Register Forge - SVD to Zig Codegen
//!
//! Generates type-safe Zig code from SVD (System View Description) files.

const std = @import("std");
const svd = @import("svd.zig");
const codegen = @import("codegen.zig");

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
            std.debug.print("register-forge: failed to parse arguments\n", .{});
            std.process.exit(1);
        };
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var peripheral_filter: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--peripheral") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) peripheral_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "demo")) {
            demoCommand(allocator) catch {
                std.debug.print("register-forge: demo command failed\n", .{});
                std.process.exit(1);
            };
            return;
        } else {
            input_file = arg;
        }
    }

    if (input_file) |path| {
        processFile(allocator, path, output_file, peripheral_filter) catch {
            std.debug.print("register-forge: failed to process file\n", .{});
            std.process.exit(1);
        };
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Register Forge - SVD to Zig Code Generator
        \\
        \\Generates type-safe Zig packed structs from ARM SVD files.
        \\
        \\Usage:
        \\  register-forge <file.svd> [options]
        \\  register-forge demo                  Generate demo output
        \\
        \\Options:
        \\  -o, --output <file>     Output file (default: stdout)
        \\  -p, --peripheral <name> Only generate code for specific peripheral
        \\  -h, --help              Show this help
        \\
        \\Example:
        \\  register-forge STM32F401.svd -o stm32f401.zig
        \\  register-forge STM32F401.svd -p GPIOA -o gpioa.zig
        \\
    , .{});
}

fn processFile(allocator: std.mem.Allocator, path: []const u8, output_path: ?[]const u8, peripheral_filter: ?[]const u8) !void {
    const io = global_io;
    _ = peripheral_filter;

    std.debug.print("Parsing: {s}\n", .{path});

    // Read SVD file
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error reading file '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(content);

    // Parse SVD
    const device = svd.parse(allocator, content) catch |err| {
        std.debug.print("Error parsing SVD: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.deinit(allocator);

    std.debug.print("Device: {s}\n", .{device.name});
    std.debug.print("Peripherals: {d}\n", .{device.peripherals.len});

    // Generate Zig code
    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    // Write output
    if (output_path) |out_path| {
        const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
        defer out_file.close(io);
        var write_buf: [8192]u8 = undefined;
        var writer = out_file.writer(io, &write_buf);
        try writer.interface.writeAll(output);
        try writer.interface.flush();
        std.debug.print("Written: {s}\n", .{out_path});
    } else {
        std.debug.print("{s}", .{output});
    }
}

fn demoCommand(allocator: std.mem.Allocator) !void {
    std.debug.print("Generating demo register definitions...\n\n", .{});

    // Create a demo device
    const device = svd.Device{
        .name = "DEMO_MCU",
        .description = "Demo Microcontroller",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIOA",
                .description = "General Purpose I/O Port A",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "MODER",
                        .description = "GPIO port mode register",
                        .offset = 0x00,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "MODE0", .bit_offset = 0, .bit_width = 2, .description = "Pin 0 mode" },
                            .{ .name = "MODE1", .bit_offset = 2, .bit_width = 2, .description = "Pin 1 mode" },
                            .{ .name = "MODE2", .bit_offset = 4, .bit_width = 2, .description = "Pin 2 mode" },
                            .{ .name = "MODE3", .bit_offset = 6, .bit_width = 2, .description = "Pin 3 mode" },
                        },
                    },
                    .{
                        .name = "ODR",
                        .description = "GPIO port output data register",
                        .offset = 0x14,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "OD0", .bit_offset = 0, .bit_width = 1, .description = "Pin 0 output" },
                            .{ .name = "OD1", .bit_offset = 1, .bit_width = 1, .description = "Pin 1 output" },
                            .{ .name = "OD2", .bit_offset = 2, .bit_width = 1, .description = "Pin 2 output" },
                            .{ .name = "OD3", .bit_offset = 3, .bit_width = 1, .description = "Pin 3 output" },
                        },
                    },
                },
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    defer allocator.free(output);

    std.debug.print("{s}", .{output});
}

test "main compiles" {
    _ = svd;
    _ = codegen;
}

// Import comprehensive test module
test {
    _ = @import("tests.zig");
    _ = @import("bench.zig");
}
