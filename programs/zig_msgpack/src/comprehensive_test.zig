const std = @import("std");
const msgpack = @import("lib.zig");

test "comprehensive encoding tests" {
    var buffer: [2048]u8 = undefined;

    // Test 1: Nil
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeNil();
        var dec = msgpack.Decoder.init(enc.getWritten());
        const val = try dec.read();
        try std.testing.expect(val == .nil);
    }

    // Test 2: Boolean
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeBool(true);
        try enc.writeBool(false);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const t = try dec.read();
        const f = try dec.read();
        try std.testing.expectEqual(true, t.bool);
        try std.testing.expectEqual(false, f.bool);
    }

    // Test 3: Positive fixint
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeUint(0);
        try enc.writeUint(127);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v0 = try dec.read();
        const v127 = try dec.read();
        try std.testing.expectEqual(@as(u64, 0), v0.uint);
        try std.testing.expectEqual(@as(u64, 127), v127.uint);
    }

    // Test 4: Negative fixint
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeInt(-1);
        try enc.writeInt(-32);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v1 = try dec.read();
        const v32 = try dec.read();
        try std.testing.expectEqual(@as(i64, -1), v1.int);
        try std.testing.expectEqual(@as(i64, -32), v32.int);
    }

    // Test 5: Uint8
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeUint(128);
        try enc.writeUint(255);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v128 = try dec.read();
        const v255 = try dec.read();
        try std.testing.expectEqual(@as(u64, 128), v128.uint);
        try std.testing.expectEqual(@as(u64, 255), v255.uint);
    }

    // Test 6: Uint16
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeUint(256);
        try enc.writeUint(65535);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v256 = try dec.read();
        const v65535 = try dec.read();
        try std.testing.expectEqual(@as(u64, 256), v256.uint);
        try std.testing.expectEqual(@as(u64, 65535), v65535.uint);
    }

    // Test 7: Uint32
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeUint(65536);
        try enc.writeUint(4294967295);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v65536 = try dec.read();
        const vmax = try dec.read();
        try std.testing.expectEqual(@as(u64, 65536), v65536.uint);
        try std.testing.expectEqual(@as(u64, 4294967295), vmax.uint);
    }

    // Test 8: Uint64
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeUint(4294967296);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const vbig = try dec.read();
        try std.testing.expectEqual(@as(u64, 4294967296), vbig.uint);
    }

    // Test 9: Int8
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeInt(-33);
        try enc.writeInt(-128);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v33 = try dec.read();
        const v128 = try dec.read();
        try std.testing.expectEqual(@as(i64, -33), v33.int);
        try std.testing.expectEqual(@as(i64, -128), v128.int);
    }

    // Test 10: Int16
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeInt(-129);
        try enc.writeInt(-32768);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v129 = try dec.read();
        const vmin = try dec.read();
        try std.testing.expectEqual(@as(i64, -129), v129.int);
        try std.testing.expectEqual(@as(i64, -32768), vmin.int);
    }

    // Test 11: Int32
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeInt(-32769);
        try enc.writeInt(-2147483648);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v32769 = try dec.read();
        const vmin = try dec.read();
        try std.testing.expectEqual(@as(i64, -32769), v32769.int);
        try std.testing.expectEqual(@as(i64, -2147483648), vmin.int);
    }

    // Test 12: Int64
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeInt(-2147483649);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const vsmall = try dec.read();
        try std.testing.expectEqual(@as(i64, -2147483649), vsmall.int);
    }

    // Test 13: Float32
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeFloat32(3.14);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const val = try dec.read();
        try std.testing.expect(val == .float32);
    }

    // Test 14: Float64
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeFloat64(3.141592653589793);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const val = try dec.read();
        try std.testing.expect(val == .float64);
    }

    // Test 15: Fixstr
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeString("hi");
        try enc.writeString("Hello, World! This is a test.");
        var dec = msgpack.Decoder.init(enc.getWritten());
        const v1 = try dec.read();
        const v2 = try dec.read();
        try std.testing.expectEqualSlices(u8, "hi", v1.string);
        try std.testing.expectEqualSlices(u8, "Hello, World! This is a test.", v2.string);
    }

    // Test 16: Str8
    {
        var enc = msgpack.Encoder.init(&buffer);
        var longstr: [100]u8 = undefined;
        @memset(&longstr, 'a');
        try enc.writeString(longstr[0..32]);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const val = try dec.read();
        try std.testing.expectEqual(@as(usize, 32), val.string.len);
    }

    // Test 17: Binary
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeBinary(&[_]u8{1, 2, 3, 4, 5});
        var dec = msgpack.Decoder.init(enc.getWritten());
        const val = try dec.read();
        try std.testing.expectEqual(@as(usize, 5), val.binary.len);
    }

    // Test 18: Fixarray
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeArrayHeader(3);
        try enc.writeInt(1);
        try enc.writeInt(2);
        try enc.writeInt(3);
        var dec = msgpack.Decoder.init(enc.getWritten());
        const arr_val = try dec.read();
        var arr = arr_val.array;
        var count: usize = 0;
        while (try arr.next()) |_| {
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
    }

    // Test 19: Array16
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeArrayHeader(100);
        for (0..100) |i| {
            try enc.writeInt(@intCast(i));
        }
        var dec = msgpack.Decoder.init(enc.getWritten());
        const arr_val = try dec.read();
        var arr = arr_val.array;
        var count: usize = 0;
        while (try arr.next()) |_| {
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 100), count);
    }

    // Test 20: Fixmap
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeMapHeader(2);
        try enc.writeString("key1");
        try enc.writeInt(42);
        try enc.writeString("key2");
        try enc.writeString("value");
        var dec = msgpack.Decoder.init(enc.getWritten());
        const map_val = try dec.read();
        var map = map_val.map;
        var count: usize = 0;
        while (try map.next()) |_| {
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }

    // Test 21: Map16
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeMapHeader(50);
        for (0..50) |i| {
            try enc.writeInt(@intCast(i));
            try enc.writeInt(@intCast(i * 2));
        }
        var dec = msgpack.Decoder.init(enc.getWritten());
        const map_val = try dec.read();
        var map = map_val.map;
        var count: usize = 0;
        while (try map.next()) |_| {
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 50), count);
    }

    // Test 22: Extension
    {
        var enc = msgpack.Encoder.init(&buffer);
        try enc.writeExt(5, &[_]u8{1, 2, 3, 4});
        var dec = msgpack.Decoder.init(enc.getWritten());
        const ext_val = try dec.read();
        try std.testing.expectEqual(@as(i8, 5), ext_val.ext.type_id);
        try std.testing.expectEqual(@as(usize, 4), ext_val.ext.data.len);
    }
}
