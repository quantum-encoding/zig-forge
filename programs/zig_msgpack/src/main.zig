//! zig_msgpack CLI Demo
//!
//! Demonstrates MessagePack encoding and decoding.

const std = @import("std");
const Io = std.Io;
const msgpack = @import("msgpack");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║           zig_msgpack - MessagePack Demo                     ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    try demoBasicTypes(stdout);
    try demoArrays(stdout);
    try demoMaps(stdout);
    try demoComplexStructure(stdout);
    try demoSizeComparison(stdout);

    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("All demos completed!\n\n", .{});
    try stdout.flush();
}

fn demoBasicTypes(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 1: Basic Types                                         │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var buffer: [256]u8 = undefined;
    var enc = msgpack.Encoder.init(&buffer);

    // Encode various types
    try enc.writeNil();
    try enc.writeBool(true);
    try enc.writeBool(false);
    try enc.writeInt(42);
    try enc.writeInt(-17);
    try enc.writeFloat64(3.14159);
    try enc.writeString("Hello, MessagePack!");

    const encoded = enc.getWritten();
    try stdout.print("Encoded {} bytes:\n", .{encoded.len});
    try printHex(stdout, encoded);

    // Decode
    try stdout.print("\nDecoded values:\n", .{});
    var dec = msgpack.Decoder.init(encoded);

    const nil = try dec.read();
    try stdout.print("  nil:    {s}\n", .{if (nil == .nil) "nil" else "error"});

    const t = try dec.read();
    try stdout.print("  bool:   {}\n", .{t.bool});

    const f = try dec.read();
    try stdout.print("  bool:   {}\n", .{f.bool});

    const num = try dec.read();
    try stdout.print("  int:    {}\n", .{num.uint});

    const neg = try dec.read();
    try stdout.print("  int:    {}\n", .{neg.int});

    const float = try dec.read();
    try stdout.print("  float:  {d:.5}\n", .{float.float64});

    const str = try dec.read();
    try stdout.print("  string: \"{s}\"\n\n", .{str.string});
}

fn demoArrays(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 2: Arrays                                              │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var buffer: [256]u8 = undefined;
    var enc = msgpack.Encoder.init(&buffer);

    // Encode array [1, 2, 3, "four", 5.0]
    try enc.writeArrayHeader(5);
    try enc.writeInt(1);
    try enc.writeInt(2);
    try enc.writeInt(3);
    try enc.writeString("four");
    try enc.writeFloat64(5.0);

    const encoded = enc.getWritten();
    try stdout.print("Encoded array ({} bytes):\n", .{encoded.len});
    try printHex(stdout, encoded);

    // Decode
    try stdout.print("\nDecoded array:\n  [", .{});
    var dec = msgpack.Decoder.init(encoded);
    const value = try dec.read();
    var arr = value.array;
    var first = true;
    while (try arr.next()) |elem| {
        if (!first) try stdout.print(", ", .{});
        first = false;
        switch (elem) {
            .uint => |n| try stdout.print("{}", .{n}),
            .int => |n| try stdout.print("{}", .{n}),
            .string => |s| try stdout.print("\"{s}\"", .{s}),
            .float64 => |f| try stdout.print("{d:.1}", .{f}),
            .float32 => |f| try stdout.print("{d:.1}", .{f}),
            else => try stdout.print("?", .{}),
        }
    }
    try stdout.print("]\n\n", .{});
}

fn demoMaps(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 3: Maps                                                │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var buffer: [256]u8 = undefined;
    var enc = msgpack.Encoder.init(&buffer);

    // Encode map {"name": "Alice", "age": 30, "active": true}
    try enc.writeMapHeader(3);
    try enc.writeString("name");
    try enc.writeString("Alice");
    try enc.writeString("age");
    try enc.writeInt(30);
    try enc.writeString("active");
    try enc.writeBool(true);

    const encoded = enc.getWritten();
    try stdout.print("Encoded map ({} bytes):\n", .{encoded.len});
    try printHex(stdout, encoded);

    // Decode
    try stdout.print("\nDecoded map:\n  {{\n", .{});
    var dec = msgpack.Decoder.init(encoded);
    const value = try dec.read();
    var m = value.map;
    while (try m.next()) |entry| {
        try stdout.print("    \"{s}\": ", .{entry.key.string});
        switch (entry.value) {
            .string => |s| try stdout.print("\"{s}\"", .{s}),
            .uint => |n| try stdout.print("{}", .{n}),
            .bool => |b| try stdout.print("{}", .{b}),
            else => try stdout.print("?", .{}),
        }
        try stdout.print(",\n", .{});
    }
    try stdout.print("  }}\n\n", .{});
}

fn demoComplexStructure(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 4: Complex Nested Structure                            │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var buffer: [512]u8 = undefined;
    var enc = msgpack.Encoder.init(&buffer);

    // Encode: {"users": [{"name": "Alice", "score": 100}, {"name": "Bob", "score": 85}]}
    try enc.writeMapHeader(1);
    try enc.writeString("users");
    try enc.writeArrayHeader(2);

    // User 1
    try enc.writeMapHeader(2);
    try enc.writeString("name");
    try enc.writeString("Alice");
    try enc.writeString("score");
    try enc.writeInt(100);

    // User 2
    try enc.writeMapHeader(2);
    try enc.writeString("name");
    try enc.writeString("Bob");
    try enc.writeString("score");
    try enc.writeInt(85);

    const encoded = enc.getWritten();
    try stdout.print("Nested structure encoded in {} bytes\n", .{encoded.len});
    try printHex(stdout, encoded);

    // Compare to JSON
    const json_equiv = "{\"users\":[{\"name\":\"Alice\",\"score\":100},{\"name\":\"Bob\",\"score\":85}]}";
    try stdout.print("\nEquivalent JSON ({} bytes):\n  {s}\n", .{ json_equiv.len, json_equiv });
    try stdout.print("\nMessagePack is {d:.1}% smaller!\n\n", .{
        (1.0 - @as(f64, @floatFromInt(encoded.len)) / @as(f64, @floatFromInt(json_equiv.len))) * 100,
    });
}

fn demoSizeComparison(stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 5: Size Comparison                                     │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var buffer: [1024]u8 = undefined;

    const test_cases = [_]struct { name: []const u8, json_size: usize, encode_fn: *const fn (*msgpack.Encoder) anyerror!void }{
        .{ .name = "Small integer (42)", .json_size = 2, .encode_fn = encodeSmallInt },
        .{ .name = "Large integer (1000000)", .json_size = 7, .encode_fn = encodeLargeInt },
        .{ .name = "Boolean (true)", .json_size = 4, .encode_fn = encodeBool },
        .{ .name = "Null", .json_size = 4, .encode_fn = encodeNull },
        .{ .name = "Short string (\"hi\")", .json_size = 4, .encode_fn = encodeShortStr },
        .{ .name = "Float (3.14159)", .json_size = 7, .encode_fn = encodeFloat },
    };

    try stdout.print("Type                          JSON    MsgPack  Savings\n", .{});
    try stdout.print("----                          ----    -------  -------\n", .{});

    for (test_cases) |tc| {
        var enc = msgpack.Encoder.init(&buffer);
        try tc.encode_fn(&enc);
        const mp_size = enc.getWritten().len;
        const savings = if (mp_size < tc.json_size)
            @as(f64, @floatFromInt(tc.json_size - mp_size)) / @as(f64, @floatFromInt(tc.json_size)) * 100
        else
            0;
        try stdout.print("{s:<30}{d:>4}    {d:>7}  {d:>5.1}%\n", .{ tc.name, tc.json_size, mp_size, savings });
    }

    try stdout.print("\n", .{});
}

fn encodeSmallInt(enc: *msgpack.Encoder) !void {
    try enc.writeInt(42);
}

fn encodeLargeInt(enc: *msgpack.Encoder) !void {
    try enc.writeInt(1000000);
}

fn encodeBool(enc: *msgpack.Encoder) !void {
    try enc.writeBool(true);
}

fn encodeNull(enc: *msgpack.Encoder) !void {
    try enc.writeNil();
}

fn encodeShortStr(enc: *msgpack.Encoder) !void {
    try enc.writeString("hi");
}

fn encodeFloat(enc: *msgpack.Encoder) !void {
    try enc.writeFloat64(3.14159);
}

fn printHex(stdout: anytype, data: []const u8) !void {
    try stdout.print("  ", .{});
    for (data, 0..) |byte, i| {
        try stdout.print("{x:0>2} ", .{byte});
        if ((i + 1) % 16 == 0 and i + 1 < data.len) {
            try stdout.print("\n  ", .{});
        }
    }
    try stdout.print("\n", .{});
}
