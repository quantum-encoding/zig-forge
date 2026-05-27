//! zig_msgpack Benchmarks

const std = @import("std");
const Io = std.Io;
const msgpack = @import("msgpack");

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
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\n=== zig_msgpack Benchmarks ===\n\n", .{});

    const iterations: usize = 1_000_000;

    // Benchmark encoding
    try stdout.print("--- Encoding ---\n", .{});

    // Small integer
    {
        var buffer: [16]u8 = undefined;
        var timer = try Timer.start();
        for (0..iterations) |i| {
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeInt(@intCast(i % 128));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("encode fixint:    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Large integer
    {
        var buffer: [16]u8 = undefined;
        var timer = try Timer.start();
        for (0..iterations) |i| {
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeInt(@intCast(i + 1000000));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("encode int32:     {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // String
    {
        var buffer: [64]u8 = undefined;
        const test_str = "Hello, MessagePack!";
        var timer = try Timer.start();
        for (0..iterations) |_| {
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeString(test_str);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("encode string:    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Float
    {
        var buffer: [16]u8 = undefined;
        var timer = try Timer.start();
        for (0..iterations) |i| {
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeFloat64(@as(f64, @floatFromInt(i)) * 0.001);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("encode float64:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Map with 3 entries
    {
        var buffer: [128]u8 = undefined;
        var timer = try Timer.start();
        for (0..iterations) |_| {
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeMapHeader(3);
            try enc.writeString("name");
            try enc.writeString("Alice");
            try enc.writeString("age");
            try enc.writeInt(30);
            try enc.writeString("active");
            try enc.writeBool(true);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("encode map(3):    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark decoding
    try stdout.print("\n--- Decoding ---\n", .{});

    // Decode fixint
    {
        const data = [_]u8{0x2a}; // 42
        var timer = try Timer.start();
        for (0..iterations) |_| {
            var dec = msgpack.Decoder.init(&data);
            _ = try dec.read();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("decode fixint:    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Decode string
    {
        var enc_buf: [64]u8 = undefined;
        var enc = msgpack.Encoder.init(&enc_buf);
        try enc.writeString("Hello, MessagePack!");
        const data = enc.getWritten();

        var timer = try Timer.start();
        for (0..iterations) |_| {
            var dec = msgpack.Decoder.init(data);
            _ = try dec.read();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("decode string:    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Decode map
    {
        var enc_buf: [128]u8 = undefined;
        var enc = msgpack.Encoder.init(&enc_buf);
        try enc.writeMapHeader(3);
        try enc.writeString("name");
        try enc.writeString("Alice");
        try enc.writeString("age");
        try enc.writeInt(30);
        try enc.writeString("active");
        try enc.writeBool(true);
        const data = enc.getWritten();

        var timer = try Timer.start();
        for (0..iterations) |_| {
            var dec = msgpack.Decoder.init(data);
            const value = try dec.read();
            var m = value.map;
            while (try m.next()) |_| {}
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("decode map(3):    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Roundtrip
    try stdout.print("\n--- Roundtrip ---\n", .{});
    {
        var buffer: [128]u8 = undefined;
        var timer = try Timer.start();
        for (0..iterations) |i| {
            // Encode
            var enc = msgpack.Encoder.init(&buffer);
            try enc.writeMapHeader(2);
            try enc.writeString("id");
            try enc.writeInt(@intCast(i));
            try enc.writeString("val");
            try enc.writeFloat64(@as(f64, @floatFromInt(i)) * 0.1);
            const data = enc.getWritten();

            // Decode
            var dec = msgpack.Decoder.init(data);
            const value = try dec.read();
            var m = value.map;
            while (try m.next()) |_| {}
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("roundtrip map(2): {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout.print("\n", .{});
    try stdout.flush();
}
