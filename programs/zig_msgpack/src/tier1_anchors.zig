//! Tier-1 externally-anchored test vectors for MessagePack.
//!
//! Each test pins encode AND decode to a published byte sequence whose
//! authority lives **outside this codebase** — the MessagePack spec
//! (https://github.com/msgpack/msgpack/blob/master/spec.md) and the
//! cross-implementation `msgpack-test` corpus. The hex on each line is the
//! verbatim wire format expected by every conforming msgpack library.
//!
//! Rule (from `/CLAUDE.md`): if you delete every roundtrip test in this
//! repo, the tier-1 file alone must still cover encode + decode for every
//! public function. Removing or weakening any anchor in this file requires
//! a re-audit, not a refactor.
//!
//! If an anchor here ever fails, the failure is either:
//!   (a) a real divergence from the msgpack spec — fix the library, or
//!   (b) an error in transcribing the spec — fix the anchor with a
//!       cross-reference to the upstream byte sequence in the commit msg.
//! In no case should an anchor be "fixed" by changing it to match the
//! library's current output without a citation.

const std = @import("std");
const msgpack = @import("msgpack");

const testing = std.testing;

// ============================================================================
// Helper: assert that encoding produces exactly the spec bytes.
// ============================================================================

fn expectEncoded(comptime expected: []const u8, writer: anytype) !void {
    var buf: [256]u8 = undefined;
    var enc = msgpack.Encoder.init(&buf);
    try writer(&enc);
    try testing.expectEqualSlices(u8, expected, enc.getWritten());
}

// ============================================================================
// Nil, booleans
// ============================================================================

test "anchor: nil -> 0xc0" {
    try expectEncoded(&[_]u8{0xc0}, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeNil();
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{0xc0});
    try testing.expect((try dec.read()) == .nil);
}

test "anchor: false -> 0xc2, true -> 0xc3" {
    try expectEncoded(&[_]u8{ 0xc2, 0xc3 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeBool(false);
            try enc.writeBool(true);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xc2, 0xc3 });
    try testing.expectEqual(false, (try dec.read()).bool);
    try testing.expectEqual(true, (try dec.read()).bool);
}

// ============================================================================
// Positive fixint (0x00..0x7f) and negative fixint (0xe0..0xff)
// ============================================================================

test "anchor: positive fixint boundaries (0, 1, 42, 127)" {
    try expectEncoded(&[_]u8{ 0x00, 0x01, 0x2a, 0x7f }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeUint(0);
            try enc.writeUint(1);
            try enc.writeUint(42); // the spec's canonical "answer" anchor
            try enc.writeUint(127);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0x00, 0x01, 0x2a, 0x7f });
    try testing.expectEqual(@as(u64, 0), (try dec.read()).uint);
    try testing.expectEqual(@as(u64, 1), (try dec.read()).uint);
    try testing.expectEqual(@as(u64, 42), (try dec.read()).uint);
    try testing.expectEqual(@as(u64, 127), (try dec.read()).uint);
}

test "anchor: negative fixint boundaries (-1, -32)" {
    try expectEncoded(&[_]u8{ 0xff, 0xe0 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeInt(-1);
            try enc.writeInt(-32);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xff, 0xe0 });
    try testing.expectEqual(@as(i64, -1), (try dec.read()).int);
    try testing.expectEqual(@as(i64, -32), (try dec.read()).int);
}

// ============================================================================
// Sized integers
// ============================================================================

test "anchor: uint8 boundary - 128 -> 0xcc 0x80, 255 -> 0xcc 0xff" {
    try expectEncoded(&[_]u8{ 0xcc, 0x80, 0xcc, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeUint(128);
            try enc.writeUint(255);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xcc, 0x80, 0xcc, 0xff });
    try testing.expectEqual(@as(u64, 128), (try dec.read()).uint);
    try testing.expectEqual(@as(u64, 255), (try dec.read()).uint);
}

test "anchor: uint16 boundary - 256 -> 0xcd 0x01 0x00, 65535 -> 0xcd 0xff 0xff" {
    try expectEncoded(&[_]u8{ 0xcd, 0x01, 0x00, 0xcd, 0xff, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeUint(256);
            try enc.writeUint(65535);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xcd, 0x01, 0x00, 0xcd, 0xff, 0xff });
    try testing.expectEqual(@as(u64, 256), (try dec.read()).uint);
    try testing.expectEqual(@as(u64, 65535), (try dec.read()).uint);
}

test "anchor: uint32 boundary - 65536 -> 0xce 0x00 0x01 0x00 0x00" {
    try expectEncoded(&[_]u8{ 0xce, 0x00, 0x01, 0x00, 0x00 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeUint(65536);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xce, 0x00, 0x01, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 65536), (try dec.read()).uint);
}

test "anchor: uint64 - 4294967296 -> 0xcf 00 00 00 01 00 00 00 00" {
    try expectEncoded(&[_]u8{ 0xcf, 0, 0, 0, 1, 0, 0, 0, 0 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeUint(4294967296);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xcf, 0, 0, 0, 1, 0, 0, 0, 0 });
    try testing.expectEqual(@as(u64, 4294967296), (try dec.read()).uint);
}

test "anchor: int8 - -33 -> 0xd0 0xdf, -128 -> 0xd0 0x80" {
    try expectEncoded(&[_]u8{ 0xd0, 0xdf, 0xd0, 0x80 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeInt(-33);
            try enc.writeInt(-128);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd0, 0xdf, 0xd0, 0x80 });
    try testing.expectEqual(@as(i64, -33), (try dec.read()).int);
    try testing.expectEqual(@as(i64, -128), (try dec.read()).int);
}

test "anchor: int16 - -129 -> 0xd1 0xff 0x7f, -32768 -> 0xd1 0x80 0x00" {
    try expectEncoded(&[_]u8{ 0xd1, 0xff, 0x7f, 0xd1, 0x80, 0x00 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeInt(-129);
            try enc.writeInt(-32768);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd1, 0xff, 0x7f, 0xd1, 0x80, 0x00 });
    try testing.expectEqual(@as(i64, -129), (try dec.read()).int);
    try testing.expectEqual(@as(i64, -32768), (try dec.read()).int);
}

test "anchor: int32 - -32769 -> 0xd2 0xff 0xff 0x7f 0xff" {
    try expectEncoded(&[_]u8{ 0xd2, 0xff, 0xff, 0x7f, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeInt(-32769);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd2, 0xff, 0xff, 0x7f, 0xff });
    try testing.expectEqual(@as(i64, -32769), (try dec.read()).int);
}

test "anchor: int64 - -2147483649 -> 0xd3 ff ff ff ff 7f ff ff ff" {
    try expectEncoded(&[_]u8{ 0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeInt(-2147483649);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff });
    try testing.expectEqual(@as(i64, -2147483649), (try dec.read()).int);
}

// ============================================================================
// Floats
// ============================================================================

test "anchor: float32 - 1.5 -> 0xca 0x3f 0xc0 0x00 0x00" {
    // 1.5 in IEEE-754 single precision: 0x3FC00000
    try expectEncoded(&[_]u8{ 0xca, 0x3f, 0xc0, 0x00, 0x00 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeFloat32(1.5);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xca, 0x3f, 0xc0, 0x00, 0x00 });
    try testing.expectEqual(@as(f32, 1.5), (try dec.read()).float32);
}

test "anchor: float64 - 1.5 -> 0xcb 0x3f 0xf8 00 00 00 00 00 00" {
    // 1.5 in IEEE-754 double precision: 0x3FF8000000000000
    try expectEncoded(&[_]u8{ 0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeFloat64(1.5);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(f64, 1.5), (try dec.read()).float64);
}

// ============================================================================
// Strings
// ============================================================================

test "anchor: fixstr empty -> 0xa0" {
    try expectEncoded(&[_]u8{0xa0}, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeString("");
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{0xa0});
    try testing.expectEqualSlices(u8, "", (try dec.read()).string);
}

test "anchor: fixstr 'abc' -> 0xa3 0x61 0x62 0x63" {
    // The canonical msgpack spec anchor for strings.
    try expectEncoded(&[_]u8{ 0xa3, 0x61, 0x62, 0x63 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeString("abc");
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xa3, 0x61, 0x62, 0x63 });
    try testing.expectEqualSlices(u8, "abc", (try dec.read()).string);
}

test "anchor: fixstr 31 chars (max) starts with 0xbf" {
    // 31 'a's is the largest fixstr; header byte is 0xa0 | 0x1f = 0xbf.
    var input: [31]u8 = undefined;
    @memset(&input, 'a');

    var enc_buf: [64]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeString(&input);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, 32), out.len);
    try testing.expectEqual(@as(u8, 0xbf), out[0]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqualSlices(u8, &input, (try dec.read()).string);
}

test "anchor: str8 - 32 chars uses 0xd9 0x20" {
    // 32 chars is one over the fixstr cap → str8.
    var input: [32]u8 = undefined;
    @memset(&input, 'b');

    var enc_buf: [64]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeString(&input);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, 34), out.len);
    try testing.expectEqual(@as(u8, 0xd9), out[0]);
    try testing.expectEqual(@as(u8, 0x20), out[1]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqualSlices(u8, &input, (try dec.read()).string);
}

// ============================================================================
// Binary
// ============================================================================

test "anchor: bin8 - [0x01 0x02 0x03] -> 0xc4 0x03 0x01 0x02 0x03" {
    try expectEncoded(&[_]u8{ 0xc4, 0x03, 0x01, 0x02, 0x03 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeBinary(&[_]u8{ 0x01, 0x02, 0x03 });
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xc4, 0x03, 0x01, 0x02, 0x03 });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, (try dec.read()).binary);
}

// ============================================================================
// Arrays
// ============================================================================

test "anchor: empty fixarray -> 0x90" {
    try expectEncoded(&[_]u8{0x90}, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeArrayHeader(0);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{0x90});
    const v = try dec.read();
    var arr = v.array;
    try testing.expectEqual(@as(usize, 0), arr.len());
    try testing.expect((try arr.next()) == null);
}

test "anchor: fixarray [1, 2, 3] -> 0x93 0x01 0x02 0x03" {
    try expectEncoded(&[_]u8{ 0x93, 0x01, 0x02, 0x03 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeArrayHeader(3);
            try enc.writeUint(1);
            try enc.writeUint(2);
            try enc.writeUint(3);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0x93, 0x01, 0x02, 0x03 });
    const v = try dec.read();
    var arr = v.array;
    try testing.expectEqual(@as(u64, 1), (try arr.next()).?.uint);
    try testing.expectEqual(@as(u64, 2), (try arr.next()).?.uint);
    try testing.expectEqual(@as(u64, 3), (try arr.next()).?.uint);
    try testing.expect((try arr.next()) == null);
}

test "anchor: array16 - 16-element array uses 0xdc 0x00 0x10" {
    var enc_buf: [64]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeArrayHeader(16);
    for (0..16) |_| try enc.writeNil();
    const out = enc.getWritten();

    try testing.expectEqual(@as(u8, 0xdc), out[0]);
    try testing.expectEqual(@as(u8, 0x00), out[1]);
    try testing.expectEqual(@as(u8, 0x10), out[2]);
}

// ============================================================================
// Maps
// ============================================================================

test "anchor: empty fixmap -> 0x80" {
    try expectEncoded(&[_]u8{0x80}, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeMapHeader(0);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{0x80});
    const v = try dec.read();
    var m = v.map;
    try testing.expect((try m.next()) == null);
}

test "anchor: fixmap {'key': 'val'} -> 0x81 0xa3 'k' 'e' 'y' 0xa3 'v' 'a' 'l'" {
    try expectEncoded(&[_]u8{ 0x81, 0xa3, 'k', 'e', 'y', 0xa3, 'v', 'a', 'l' }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeMapHeader(1);
            try enc.writeString("key");
            try enc.writeString("val");
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0x81, 0xa3, 'k', 'e', 'y', 0xa3, 'v', 'a', 'l' });
    const v = try dec.read();
    var m = v.map;
    const entry = (try m.next()).?;
    try testing.expectEqualSlices(u8, "key", entry.key.string);
    try testing.expectEqualSlices(u8, "val", entry.value.string);
}

// ============================================================================
// Extensions
// ============================================================================

test "anchor: fixext1 - ext type 5 with [0x42] -> 0xd4 0x05 0x42" {
    try expectEncoded(&[_]u8{ 0xd4, 0x05, 0x42 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeExt(5, &[_]u8{0x42});
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd4, 0x05, 0x42 });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, 5), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{0x42}, v.ext.data);
}

test "anchor: ext8 - ext type 7 with 3 bytes -> 0xc7 0x03 0x07 0x01 0x02 0x03" {
    try expectEncoded(&[_]u8{ 0xc7, 0x03, 0x07, 0x01, 0x02, 0x03 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeExt(7, &[_]u8{ 0x01, 0x02, 0x03 });
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xc7, 0x03, 0x07, 0x01, 0x02, 0x03 });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, 7), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, v.ext.data);
}

// ============================================================================
// Timestamp extension (ext type -1), per the MessagePack timestamp spec:
// https://github.com/msgpack/msgpack/blob/master/spec.md#timestamp-extension-type
//
//   timestamp 32: fixext4  (0xd6 0xff) + u32 BE seconds
//   timestamp 64: fixext8  (0xd7 0xff) + u64 BE ((nanoseconds << 34) | seconds)
//                 nanoseconds in the high 30 bits, seconds in the low 34 bits
//   timestamp 96: ext8     (0xc7 0x0c 0xff) + u32 BE nanoseconds + i64 BE seconds
//
// The encoder hand-packs these three layouts (encoder.zig:344-367); these
// anchors pin the emitted bytes to the spec's bit layout so a transposed
// opcode or a wrong shift width fails the test. Decode is verified both as
// the generic ext value AND through the `readTimestamp` helper, so the
// decode-side bit-unpacking is pinned to the same external bytes.
// ============================================================================

test "anchor: timestamp32 (seconds=1, nanos=0) -> 0xd6 0xff 00 00 00 01" {
    try expectEncoded(&[_]u8{ 0xd6, 0xff, 0x00, 0x00, 0x00, 0x01 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeTimestamp(1, 0);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd6, 0xff, 0x00, 0x00, 0x00, 0x01 });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, -1), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, v.ext.data);

    var dec2 = msgpack.Decoder.init(&[_]u8{ 0xd6, 0xff, 0x00, 0x00, 0x00, 0x01 });
    const ts = try dec2.readTimestamp();
    try testing.expectEqual(@as(i64, 1), ts.seconds);
    try testing.expectEqual(@as(u32, 0), ts.nanoseconds);
}

test "anchor: timestamp64 (seconds=1, nanos=1) -> 0xd7 0xff 00 00 00 04 00 00 00 01" {
    // val = (1 << 34) | 1 = 0x0000000400000001; verifies the 30/34-bit split:
    // bit 34 set comes from nanoseconds, bit 0 set comes from seconds.
    try expectEncoded(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01 }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeTimestamp(1, 1);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01 });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, -1), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01 }, v.ext.data);

    var dec2 = msgpack.Decoder.init(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01 });
    const ts = try dec2.readTimestamp();
    try testing.expectEqual(@as(i64, 1), ts.seconds);
    try testing.expectEqual(@as(u32, 1), ts.nanoseconds);
}

test "anchor: timestamp64 boundary (seconds=0x3ffffffff max-34bit, nanos=0) -> 0xd7 0xff 00 00 00 03 ff ff ff ff" {
    // Seconds > 0xffffffff forces ts64 even with nanos==0; 0x3ffffffff is the
    // widest value that fits the 34-bit seconds field.
    try expectEncoded(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x03, 0xff, 0xff, 0xff, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeTimestamp(0x3ffffffff, 0);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x03, 0xff, 0xff, 0xff, 0xff });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, -1), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x03, 0xff, 0xff, 0xff, 0xff }, v.ext.data);

    var dec2 = msgpack.Decoder.init(&[_]u8{ 0xd7, 0xff, 0x00, 0x00, 0x00, 0x03, 0xff, 0xff, 0xff, 0xff });
    const ts = try dec2.readTimestamp();
    try testing.expectEqual(@as(i64, 0x3ffffffff), ts.seconds);
    try testing.expectEqual(@as(u32, 0), ts.nanoseconds);
}

test "anchor: timestamp96 (seconds=-1, nanos=1) -> 0xc7 0x0c 0xff 00 00 00 01 ff ff ff ff ff ff ff ff" {
    // Negative seconds (pre-1970) forces ts96: u32 BE nanoseconds, then i64 BE
    // seconds (-1 == 0xFFFFFFFFFFFFFFFF two's complement).
    try expectEncoded(&[_]u8{ 0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, struct {
        fn run(enc: *msgpack.Encoder) !void {
            try enc.writeTimestamp(-1, 1);
        }
    }.run);

    var dec = msgpack.Decoder.init(&[_]u8{ 0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    const v = try dec.read();
    try testing.expectEqual(@as(i8, -1), v.ext.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, v.ext.data);

    var dec2 = msgpack.Decoder.init(&[_]u8{ 0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    const ts = try dec2.readTimestamp();
    try testing.expectEqual(@as(i64, -1), ts.seconds);
    try testing.expectEqual(@as(u32, 1), ts.nanoseconds);
}

// ============================================================================
// Wide-width wire headers (str16/32, bin16/32, array32, map16/32, ext16/32,
// fixext2/4/8/16). Only the 8-bit and smallest-fix forms were pinned before;
// a transposed opcode (e.g. swapping 0xda/0xdb) or a wrong length width would
// slip past every small-value test. These anchor the exact header bytes at
// the size boundary that forces each wider form. Header byte sequences are
// verbatim from the MessagePack spec's "formats" table.
// ============================================================================

test "anchor: str16 - 256-char string uses 0xda 0x01 0x00" {
    // 256 > 0xff → str16; length is big-endian u16 0x0100.
    var input: [256]u8 = undefined;
    @memset(&input, 'x');

    var enc_buf: [260]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeString(&input);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, 259), out.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xda, 0x01, 0x00 }, out[0..3]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqualSlices(u8, &input, (try dec.read()).string);
}

test "anchor: str32 - 65536-char string uses 0xdb 0x00 0x01 0x00 0x00" {
    // 65536 > 0xffff → str32; length is big-endian u32 0x00010000.
    const n: usize = 65536;
    const body = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(body);
    @memset(body, 'z');

    const enc_buf = try testing.allocator.alloc(u8, n + 5);
    defer testing.allocator.free(enc_buf);
    var enc = msgpack.Encoder.init(enc_buf);
    try enc.writeString(body);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, n + 5), out.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xdb, 0x00, 0x01, 0x00, 0x00 }, out[0..5]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqual(@as(usize, n), (try dec.read()).string.len);
}

test "anchor: bin16 - 256-byte binary uses 0xc5 0x01 0x00" {
    var input: [256]u8 = undefined;
    @memset(&input, 0xab);

    var enc_buf: [260]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeBinary(&input);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, 259), out.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc5, 0x01, 0x00 }, out[0..3]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqualSlices(u8, &input, (try dec.read()).binary);
}

test "anchor: bin32 - 65536-byte binary uses 0xc6 0x00 0x01 0x00 0x00" {
    const n: usize = 65536;
    const body = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(body);
    @memset(body, 0xcd);

    const enc_buf = try testing.allocator.alloc(u8, n + 5);
    defer testing.allocator.free(enc_buf);
    var enc = msgpack.Encoder.init(enc_buf);
    try enc.writeBinary(body);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, n + 5), out.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc6, 0x00, 0x01, 0x00, 0x00 }, out[0..5]);

    var dec = msgpack.Decoder.init(out);
    try testing.expectEqual(@as(usize, n), (try dec.read()).binary.len);
}

test "anchor: array32 - 65536-element header uses 0xdd 0x00 0x01 0x00 0x00" {
    // Header-only: writeArrayHeader emits just the header, no elements.
    var enc_buf: [8]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeArrayHeader(65536);
    const out = enc.getWritten();

    try testing.expectEqualSlices(u8, &[_]u8{ 0xdd, 0x00, 0x01, 0x00, 0x00 }, out);

    var dec = msgpack.Decoder.init(out);
    const v = try dec.read();
    try testing.expectEqual(@as(usize, 65536), v.array.len());
}

test "anchor: map16 - 16-entry header uses 0xde 0x00 0x10" {
    // 16 > 15 (fixmap cap) → map16.
    var enc_buf: [8]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeMapHeader(16);
    const out = enc.getWritten();

    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0x00, 0x10 }, out);

    var dec = msgpack.Decoder.init(out);
    const v = try dec.read();
    try testing.expectEqual(@as(usize, 16), v.map.len());
}

test "anchor: map32 - 65536-entry header uses 0xdf 0x00 0x01 0x00 0x00" {
    var enc_buf: [8]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeMapHeader(65536);
    const out = enc.getWritten();

    try testing.expectEqualSlices(u8, &[_]u8{ 0xdf, 0x00, 0x01, 0x00, 0x00 }, out);

    var dec = msgpack.Decoder.init(out);
    const v = try dec.read();
    try testing.expectEqual(@as(usize, 65536), v.map.len());
}

test "anchor: fixext2/4/8/16 header opcodes (0xd5/0xd6/0xd7/0xd8)" {
    // writeExt picks the fixext form for exactly-2/4/8/16-byte payloads.
    // Use type id 0x10 (not -1, to stay clear of the timestamp shape).
    const sizes = [_]usize{ 2, 4, 8, 16 };
    const opcodes = [_]u8{ 0xd5, 0xd6, 0xd7, 0xd8 };
    inline for (sizes, opcodes) |sz, opcode| {
        var data: [16]u8 = undefined;
        @memset(&data, 0x5a);

        var enc_buf: [20]u8 = undefined;
        var enc = msgpack.Encoder.init(&enc_buf);
        try enc.writeExt(0x10, data[0..sz]);
        const out = enc.getWritten();

        try testing.expectEqual(opcode, out[0]);
        try testing.expectEqual(@as(u8, 0x10), out[1]); // type byte
        try testing.expectEqual(@as(usize, sz + 2), out.len);

        var dec = msgpack.Decoder.init(out);
        const v = try dec.read();
        try testing.expectEqual(@as(i8, 0x10), v.ext.type_id);
        try testing.expectEqualSlices(u8, data[0..sz], v.ext.data);
    }
}

test "anchor: ext16 - 256-byte ext uses 0xc8 0x01 0x00 <type>" {
    var input: [256]u8 = undefined;
    @memset(&input, 0x33);

    var enc_buf: [262]u8 = undefined;
    var enc = msgpack.Encoder.init(&enc_buf);
    try enc.writeExt(9, &input);
    const out = enc.getWritten();

    try testing.expectEqualSlices(u8, &[_]u8{ 0xc8, 0x01, 0x00, 0x09 }, out[0..4]);
    try testing.expectEqual(@as(usize, 260), out.len);

    var dec = msgpack.Decoder.init(out);
    const v = try dec.read();
    try testing.expectEqual(@as(i8, 9), v.ext.type_id);
    try testing.expectEqual(@as(usize, 256), v.ext.data.len);
}

test "anchor: ext32 - 65536-byte ext uses 0xc9 0x00 0x01 0x00 0x00 <type>" {
    const n: usize = 65536;
    const body = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(body);
    @memset(body, 0x44);

    const enc_buf = try testing.allocator.alloc(u8, n + 6);
    defer testing.allocator.free(enc_buf);
    var enc = msgpack.Encoder.init(enc_buf);
    try enc.writeExt(11, body);
    const out = enc.getWritten();

    try testing.expectEqual(@as(usize, n + 6), out.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc9, 0x00, 0x01, 0x00, 0x00, 0x0b }, out[0..6]);

    var dec = msgpack.Decoder.init(out);
    const v = try dec.read();
    try testing.expectEqual(@as(i8, 11), v.ext.type_id);
    try testing.expectEqual(@as(usize, n), v.ext.data.len);
}

// ============================================================================
// Reserved opcode and grammar boundaries
// ============================================================================

test "anchor: opcode 0xc1 (never-used) is rejected" {
    // RFC: 0xc1 is reserved and MUST NOT be encoded; decoders MUST treat it
    // as an error.
    var dec = msgpack.Decoder.init(&[_]u8{0xc1});
    try testing.expectError(error.InvalidFormat, dec.read());
}
