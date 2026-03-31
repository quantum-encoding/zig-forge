//! JWT Benchmark

const std = @import("std");
const Io = std.Io;
const jwt = @import("jwt");

/// Timer implementation using libc clock_gettime for Zig 0.16 compatibility
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\nJWT Benchmark\n", .{});
    try stdout.print("═════════════════════════════════════════════════════════════\n\n", .{});

    const iterations: usize = 10000;
    const secret = "benchmark-secret-key-for-testing-performance";

    // Benchmark HS256 signing
    {
        var timer = try Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const token = try jwt.quickSign(allocator, "benchuser", "benchapp", 3600, .HS256, secret);
            allocator.free(token);
        }
        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stdout.print("HS256 Sign:   {d:>10.0} ops/sec ({d:>8.3} ms total)\n", .{ ops_per_sec, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    // Create a token for verification benchmarks
    const test_token = try jwt.quickSign(allocator, "verifyuser", "verifyapp", 3600, .HS256, secret);
    defer allocator.free(test_token);

    // Benchmark HS256 verification
    {
        var timer = try Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var claims = try jwt.quickVerify(allocator, test_token, .HS256, secret);
            claims.deinit();
        }
        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stdout.print("HS256 Verify: {d:>10.0} ops/sec ({d:>8.3} ms total)\n", .{ ops_per_sec, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    // Benchmark HS384 signing
    {
        var timer = try Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const token = try jwt.quickSign(allocator, "benchuser", "benchapp", 3600, .HS384, secret);
            allocator.free(token);
        }
        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stdout.print("HS384 Sign:   {d:>10.0} ops/sec ({d:>8.3} ms total)\n", .{ ops_per_sec, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    // Benchmark HS512 signing
    {
        var timer = try Timer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const token = try jwt.quickSign(allocator, "benchuser", "benchapp", 3600, .HS512, secret);
            allocator.free(token);
        }
        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stdout.print("HS512 Sign:   {d:>10.0} ops/sec ({d:>8.3} ms total)\n", .{ ops_per_sec, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    // Benchmark Base64URL encoding
    {
        const data = "This is some test data that we want to encode in base64url format for benchmarking purposes";
        var timer = try Timer.start();
        var i: usize = 0;
        while (i < iterations * 10) : (i += 1) {
            const encoded = try jwt.base64UrlEncode(allocator, data);
            allocator.free(encoded);
        }
        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations * 10)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

        try stdout.print("Base64 Enc:   {d:>10.0} ops/sec ({d:>8.3} ms total)\n", .{ ops_per_sec, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    try stdout.print("\nBenchmark complete ({} iterations per test)\n\n", .{iterations});
    try stdout.flush();
}
