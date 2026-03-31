//! zig_msgpack - MessagePack Serialization Library
//!
//! A high-performance MessagePack encoder/decoder for Zig.
//! MessagePack is an efficient binary serialization format, faster and smaller than JSON.
//!
//! ## Features
//!
//! - Zero allocations in encoding/decoding hot paths
//! - Streaming-friendly lazy decoding of arrays and maps
//! - Full MessagePack spec support including extensions
//! - Timestamp extension support
//! - Type-safe value representation
//!
//! ## Example: Encoding
//!
//! ```zig
//! var buffer: [1024]u8 = undefined;
//! var enc = msgpack.Encoder.init(&buffer);
//!
//! try enc.writeMapHeader(2);
//! try enc.writeString("name");
//! try enc.writeString("Alice");
//! try enc.writeString("age");
//! try enc.writeInt(30);
//!
//! const data = enc.getWritten();
//! // data is now compact binary MessagePack
//! ```
//!
//! ## Example: Decoding
//!
//! ```zig
//! var dec = msgpack.Decoder.init(data);
//!
//! const value = try dec.read();
//! switch (value) {
//!     .map => |m| {
//!         var iter = m;
//!         while (try iter.next()) |entry| {
//!             // Process key-value pairs
//!         }
//!     },
//!     else => {},
//! }
//! ```

pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");

// Re-export main types
pub const Encoder = encoder.Encoder;
pub const Format = encoder.Format;
pub const Decoder = decoder.Decoder;
pub const Value = decoder.Value;
pub const ArrayIterator = decoder.ArrayIterator;
pub const MapIterator = decoder.MapIterator;
pub const Extension = decoder.Extension;

/// Version info
pub const version = "0.1.0";
pub const version_major = 0;
pub const version_minor = 1;
pub const version_patch = 0;

/// Convenience function to encode a value to a buffer
pub fn encode(buffer: []u8, writer_fn: anytype) ![]const u8 {
    var enc = Encoder.init(buffer);
    try writer_fn(&enc);
    return enc.getWritten();
}

/// Convenience function to decode a value
pub fn decode(data: []const u8) Decoder {
    return Decoder.init(data);
}

test {
    // Run all module tests
    @import("std").testing.refAllDecls(@This());
}
