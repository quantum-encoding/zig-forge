const std = @import("std");
const sha256d = @import("crypto/sha256d.zig");

// Zig 0.16 compatible Timer using clock_gettime
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

pub fn main() !void {
    // Use global single-threaded Io context
    const io = std.Io.Threaded.global_single_threaded.io();

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        \\
        \\═══════════════════════════════════════
        \\  SHA256d Benchmark Suite
        \\═══════════════════════════════════════
        \\
        \\
    );

    // Benchmark parameters
    const test_sizes = [_]u64{ 100_000, 1_000_000, 10_000_000 };

    for (test_sizes) |iterations| {
        try benchmarkScalar(stdout, iterations);
    }

    try stdout.writeAll("\n✨ Benchmark complete!\n");

    // Flush before exit
    try std.Io.Writer.flush(&stdout_writer.interface);
}

fn benchmarkScalar(writer: anytype, iterations: u64) !void {
    var input = [_]u8{0} ** 80;
    var output: [32]u8 = undefined;

    // Warmup
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        sha256d.sha256d(&input, &output);
    }

    // Actual benchmark
    var timer = try Timer.start();
    const start = timer.read();

    i = 0;
    while (i < iterations) : (i += 1) {
        sha256d.sha256d(&input, &output);
    }

    const elapsed_ns = timer.read() - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const hashes_per_sec = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    const mhashes_per_sec = hashes_per_sec / 1_000_000.0;

    try writer.print(
        \\📊 Scalar Implementation
        \\   Iterations: {d}
        \\   Time:       {d:.3}s
        \\   Hashrate:   {d:.2} MH/s
        \\   ns/hash:    {d:.2}
        \\
        \\
    , .{
        iterations,
        elapsed_s,
        mhashes_per_sec,
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)),
    });
}
