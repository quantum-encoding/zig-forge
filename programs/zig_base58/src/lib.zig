//! Base58 Library Root
//!
//! Re-exports all Base58 encoding functionality

pub const base58 = @import("base58.zig");

pub const encode = base58.encode;
pub const decode = base58.decode;
pub const encodeCheck = base58.encodeCheck;
pub const decodeCheck = base58.decodeCheck;
pub const StreamEncoder = base58.StreamEncoder;
pub const StreamDecoder = base58.StreamDecoder;
pub const encodeBatch = base58.encodeBatch;
pub const Error = base58.Error;
