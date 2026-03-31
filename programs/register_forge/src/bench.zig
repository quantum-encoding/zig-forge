//! Benchmark Suite for register_forge
//!
//! Performance benchmarks for SVD parsing and code generation.

const std = @import("std");
const svd = @import("svd.zig");
const codegen = @import("codegen.zig");

// ============================================================================
// Benchmark Utilities
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn runBenchAlloc(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime iterations: u64,
    func: *const fn (std.mem.Allocator) anyerror!void,
) BenchResult {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..10) |_| {
        func(allocator) catch {};
    }

    // Benchmark
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        func(allocator) catch {};
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = total_ns / iterations,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

fn printResult(result: BenchResult) void {
    std.debug.print(
        \\{s}:
        \\  Iterations: {d}
        \\  Total: {d}ns ({d:.2}ms)
        \\  Average: {d}ns ({d:.3}ms)
        \\  Min: {d}ns
        \\  Max: {d}ns
        \\
    , .{
        result.name,
        result.iterations,
        result.total_ns,
        @as(f64, @floatFromInt(result.total_ns)) / 1_000_000.0,
        result.avg_ns,
        @as(f64, @floatFromInt(result.avg_ns)) / 1_000_000.0,
        result.min_ns,
        result.max_ns,
    });
}

// ============================================================================
// Sample SVD Data
// ============================================================================

const small_svd =
    \\<device>
    \\  <name>SMALL</name>
    \\  <peripheral>
    \\    <name>GPIO</name>
    \\    <baseAddress>0x40020000</baseAddress>
    \\  </peripheral>
    \\</device>
;

const medium_svd =
    \\<device>
    \\  <name>MEDIUM</name>
    \\  <peripheral>
    \\    <name>GPIOA</name>
    \\    <baseAddress>0x40020000</baseAddress>
    \\    <register>
    \\      <name>MODER</name>
    \\      <addressOffset>0x00</addressOffset>
    \\      <size>32</size>
    \\      <field><name>MODE0</name><bitOffset>0</bitOffset><bitWidth>2</bitWidth></field>
    \\      <field><name>MODE1</name><bitOffset>2</bitOffset><bitWidth>2</bitWidth></field>
    \\    </register>
    \\    <register>
    \\      <name>ODR</name>
    \\      <addressOffset>0x14</addressOffset>
    \\      <size>32</size>
    \\    </register>
    \\  </peripheral>
    \\</device>
;

const large_svd =
    \\<device>
    \\  <name>LARGE</name>
    \\  <peripheral>
    \\    <name>GPIOA</name>
    \\    <baseAddress>0x40020000</baseAddress>
    \\    <register>
    \\      <name>MODER</name>
    \\      <addressOffset>0x00</addressOffset>
    \\      <size>32</size>
    \\      <field><name>MODE0</name><bitOffset>0</bitOffset><bitWidth>2</bitWidth></field>
    \\      <field><name>MODE1</name><bitOffset>2</bitOffset><bitWidth>2</bitWidth></field>
    \\      <field><name>MODE2</name><bitOffset>4</bitOffset><bitWidth>2</bitWidth></field>
    \\      <field><name>MODE3</name><bitOffset>6</bitOffset><bitWidth>2</bitWidth></field>
    \\    </register>
    \\    <register>
    \\      <name>ODR</name>
    \\      <addressOffset>0x14</addressOffset>
    \\      <size>32</size>
    \\      <field><name>OD0</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth></field>
    \\      <field><name>OD1</name><bitOffset>1</bitOffset><bitWidth>1</bitWidth></field>
    \\    </register>
    \\  </peripheral>
    \\  <peripheral>
    \\    <name>GPIOB</name>
    \\    <baseAddress>0x40020400</baseAddress>
    \\    <register>
    \\      <name>MODER</name>
    \\      <addressOffset>0x00</addressOffset>
    \\      <size>32</size>
    \\    </register>
    \\  </peripheral>
    \\</device>
;

// ============================================================================
// Benchmarks
// ============================================================================

fn benchParseSmall(allocator: std.mem.Allocator) !void {
    const device = try svd.parse(allocator, small_svd);
    device.deinit(allocator);
}

fn benchParseMedium(allocator: std.mem.Allocator) !void {
    const device = try svd.parse(allocator, medium_svd);
    device.deinit(allocator);
}

fn benchParseLarge(allocator: std.mem.Allocator) !void {
    const device = try svd.parse(allocator, large_svd);
    device.deinit(allocator);
}

fn benchCodegenSmall(allocator: std.mem.Allocator) !void {
    const device = svd.Device{
        .name = "SMALL",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIO",
                .description = "",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{},
            },
        },
    };

    const output = try codegen.generate(allocator, device);
    allocator.free(output);
}

fn benchCodegenMedium(allocator: std.mem.Allocator) !void {
    const device = svd.Device{
        .name = "MEDIUM",
        .description = "",
        .peripherals = &[_]svd.Peripheral{
            .{
                .name = "GPIOA",
                .description = "",
                .base_address = 0x40020000,
                .registers = &[_]svd.Register{
                    .{
                        .name = "MODER",
                        .description = "",
                        .offset = 0x00,
                        .size = 32,
                        .fields = &[_]svd.Field{
                            .{ .name = "MODE0", .description = "", .bit_offset = 0, .bit_width = 2 },
                            .{ .name = "MODE1", .description = "", .bit_offset = 2, .bit_width = 2 },
                        },
                    },
                    .{
                        .name = "ODR",
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
    allocator.free(output);
}

fn benchFullCycle(allocator: std.mem.Allocator) !void {
    const device = try svd.parse(allocator, medium_svd);
    defer device.deinit(allocator);

    const output = try codegen.generate(allocator, device);
    allocator.free(output);
}

// ============================================================================
// Benchmark Runner
// ============================================================================

pub fn runAllBenchmarks(allocator: std.mem.Allocator) void {
    std.debug.print("\n=== register_forge Benchmarks ===\n\n", .{});

    const results = [_]BenchResult{
        runBenchAlloc(allocator, "Parse small SVD", 1000, benchParseSmall),
        runBenchAlloc(allocator, "Parse medium SVD", 1000, benchParseMedium),
        runBenchAlloc(allocator, "Parse large SVD", 500, benchParseLarge),
        runBenchAlloc(allocator, "Codegen small device", 1000, benchCodegenSmall),
        runBenchAlloc(allocator, "Codegen medium device", 1000, benchCodegenMedium),
        runBenchAlloc(allocator, "Full parse+generate cycle", 500, benchFullCycle),
    };

    for (results) |result| {
        printResult(result);
        std.debug.print("\n", .{});
    }
}

test "benchmark compiles" {
    const allocator = std.testing.allocator;
    try benchParseSmall(allocator);
    try benchCodegenSmall(allocator);
}
