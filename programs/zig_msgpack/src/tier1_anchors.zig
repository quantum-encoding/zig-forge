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
// Reserved opcode and grammar boundaries
// ============================================================================

test "anchor: opcode 0xc1 (never-used) is rejected" {
    // RFC: 0xc1 is reserved and MUST NOT be encoded; decoders MUST treat it
    // as an error.
    var dec = msgpack.Decoder.init(&[_]u8{0xc1});
    try testing.expectError(error.InvalidFormat, dec.read());
}
