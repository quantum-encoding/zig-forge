//! Fuzz harness for the MessagePack decoder.
//!
//! The decoder's entire reason for existing is to consume **untrusted input**
//! safely, but its correctness coverage is otherwise example-based. This feeds
//! `std.testing`'s structured fuzzer arbitrary byte strings and asserts the
//! two invariants that must hold for ANY input, hostile or not:
//!
//!   1. neither `skip()` nor a bounded `read()`/iterator walk ever crashes or
//!      triggers undefined behavior (index-out-of-bounds, integer overflow,
//!      unreachable), and
//!   2. the decoder position (`pos`) never advances past the end of the input
//!      buffer.
//!
//! This is the cheapest automated catch for the class of bug the wave-2 audit
//! found by hand (`skip()` writing past its fixed stack buffer): a fuzzer that
//! raises `max_depth` and feeds deep nesting would have hit it immediately.
//!
//! Run under the fuzzer:  `zig build fuzz --fuzz`
//! It is also wired into `zig build test`, where `std.testing.fuzz` runs a
//! single deterministic iteration so the harness stays compiling and green in
//! CI even without a fuzzing backend attached.

const std = @import("std");
const msgpack = @import("msgpack");

fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    // (1) skip() over the whole message. It has its own iterative,
    // depth-capped traversal; it must never crash and must leave pos in
    // bounds whether it succeeds or errors.
    {
        var dec = msgpack.Decoder.init(input);
        dec.skip() catch {};
        try std.testing.expect(dec.pos <= input.len);
    }

    // (2) skip() with a raised max_depth — this is the exact configuration
    // that used to overflow the fixed stack buffer. It must still only ever
    // return MaxDepthExceeded (or another decode error), never corrupt memory.
    {
        var dec = msgpack.Decoder.init(input);
        dec.max_depth = 4096; // above DEFAULT_MAX_DEPTH (512)
        dec.skip() catch {};
        try std.testing.expect(dec.pos <= input.len);
    }

    // (3) A flat read() loop that also drains the direct elements of any
    // top-level container, exercising the iterator poisoning / atomicity
    // paths. `guard` bounds the loop regardless of what the bytes claim; each
    // successful read advances pos by >= 1 so it always terminates.
    {
        var dec = msgpack.Decoder.init(input);
        var guard: usize = 0;
        while (dec.hasMore() and guard <= input.len) : (guard += 1) {
            const value = dec.read() catch break;
            switch (value) {
                .array => |a| {
                    var it = a;
                    while (it.next() catch break) |_| {}
                },
                .map => |m| {
                    var it = m;
                    while (it.next() catch break) |_| {}
                },
                else => {},
            }
            try std.testing.expect(dec.pos <= input.len);
        }
    }
}

test "fuzz: decoder never crashes or over-reads on arbitrary bytes" {
    try std.testing.fuzz({}, testOne, .{});
}
