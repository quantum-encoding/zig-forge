const std = @import("std");
const zig_toml = @import("zig_toml");
const Allocator = std.mem.Allocator;

/// Custom Timer implementation for Zig 0.16+ compatibility.
/// Uses libc clock_gettime with CLOCK_MONOTONIC for high-resolution timing.
const Timer = struct {
    start_time: std.c.timespec,

    const Self = @This();

    pub fn start() error{}!Self {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return Self{ .start_time = ts };
    }

    pub fn read(self: *Self) u64 {
        var end_time: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &end_time);

        const start_ns: u64 = @as(u64, @intCast(self.start_time.sec)) * 1_000_000_000 + @as(u64, @intCast(self.start_time.nsec));
        const end_ns: u64 = @as(u64, @intCast(end_time.sec)) * 1_000_000_000 + @as(u64, @intCast(end_time.nsec));
        return end_ns - start_ns;
    }
};

const BenchResult = struct {
    name: []const u8,
    iterations: u32,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.flush() catch {};
    const stdout = &stdout_writer.interface;

    try stdout.print("=== TOML Parser Benchmarks ===\n\n", .{});

    var results: [10]?BenchResult = [_]?BenchResult{null} ** 10;
    var result_count: usize = 0;

    // Benchmark 1: Simple key-value parsing
    const simple_toml = "name = \"John\"\nage = 30\nemail = \"john@example.com\"\n";
    results[result_count] = try benchmarkParse(allocator, "Simple key-value", simple_toml, 1000);
    result_count += 1;

    // Benchmark 2: Array parsing
    const array_toml = "numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\nstrings = [\"a\", \"b\", \"c\", \"d\", \"e\"]\n";
    results[result_count] = try benchmarkParse(allocator, "Array parsing", array_toml, 500);
    result_count += 1;

    // Benchmark 3: Table parsing
    const table_toml = "[database]\nhost = \"localhost\"\nport = 5432\nuser = \"admin\"\n[server]\naddress = \"0.0.0.0\"\nport = 8080\n";
    results[result_count] = try benchmarkParse(allocator, "Table parsing", table_toml, 500);
    result_count += 1;

    // Benchmark 4: Inline table parsing
    const inline_table_toml = "point = { x = 1, y = 2, z = 3 }\ncolor = { r = 255, g = 128, b = 0 }\n";
    results[result_count] = try benchmarkParse(allocator, "Inline table parsing", inline_table_toml, 500);
    result_count += 1;

    // Benchmark 5: Complex document
    const complex_toml =
        \\# Configuration file
        \\title = "TOML Example"
        \\[owner]
        \\name = "Tom Preston-Werner"
        \\dob = "1979-05-27T07:32:00-08:00"
        \\[database]
        \\server = "192.168.1.1"
        \\ports = [ 8000, 8001, 8002 ]
        \\connection_max = 5000
        \\enabled = true
    ;
    results[result_count] = try benchmarkParse(allocator, "Complex document", complex_toml, 300);
    result_count += 1;

    // Benchmark 6: Strings with escapes
    const string_toml = "path = \"C:\\\\Users\\\\name\\\\file.txt\"\nmessage = \"Line 1\\nLine 2\\tTabbed\"\n";
    results[result_count] = try benchmarkParse(allocator, "String escapes", string_toml, 800);
    result_count += 1;

    // Benchmark 7: Floats and scientific notation
    const float_toml = "pi = 3.14159\ntemp = -273.15\nsmall = 1.23e-10\nlarge = 6.02e23\n";
    results[result_count] = try benchmarkParse(allocator, "Float parsing", float_toml, 1000);
    result_count += 1;

    // Benchmark 8: Boolean values
    const bool_toml = "enabled = true\ndisabled = false\nactive = true\ninactive = false\n";
    results[result_count] = try benchmarkParse(allocator, "Boolean parsing", bool_toml, 2000);
    result_count += 1;

    // Print results
    try stdout.print("Benchmark Results:\n", .{});
    try stdout.print("==================\n\n", .{});

    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        if (results[i]) |res| {
            try stdout.print("Test: {s}\n", .{res.name});
            try stdout.print("  Iterations: {}\n", .{res.iterations});
            try stdout.print("  Total:      {} ns\n", .{res.total_ns});
            try stdout.print("  Average:    {} ns\n", .{res.avg_ns});
            try stdout.print("  Min:        {} ns\n", .{res.min_ns});
            try stdout.print("  Max:        {} ns\n\n", .{res.max_ns});
        }
    }
}

fn benchmarkParse(allocator: Allocator, name: []const u8, input: []const u8, iterations: u32) !BenchResult {
    var times: [1000]u64 = undefined;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var timer = try Timer.start();

        var result = zig_toml.parseToml(allocator, input) catch {
            return error.ParseFailed;
        };

        const elapsed = timer.read();

        defer {
            var iter = result.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            result.deinit();
        }

        if (i < 1000) {
            times[i] = elapsed;
        }

        if (elapsed < min_ns) {
            min_ns = elapsed;
        }
        if (elapsed > max_ns) {
            max_ns = elapsed;
        }
        total_ns += elapsed;
    }

    const avg_ns = total_ns / iterations;

    return BenchResult{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}
