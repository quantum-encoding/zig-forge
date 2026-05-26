//! Base58 Library Root
//!
//! Re-exports all Base58 encoding functionality. For wallet code, prefer the
//! versioned helpers (`encodeCheckVersioned`, `decodeCheckVersioned`) over the
//! bare `encodeCheck` / `decodeCheck` — they make the network version byte
//! explicit and reject cross-network address reuse.

pub const base58 = @import("base58.zig");

// Alphabet selection
pub const Alphabet = base58.Alphabet;

// Core encode / decode (Bitcoin/Tron alphabet)
pub const encode = base58.encode;
pub const decode = base58.decode;

// Alphabet-parameterized variants (Ripple/Flickr/custom)
pub const encodeWith = base58.encodeWith;
pub const decodeWith = base58.decodeWith;

// Base58Check (double SHA-256, Bitcoin/Tron/DOGE/LTC compatible)
pub const encodeCheck = base58.encodeCheck;
pub const decodeCheck = base58.decodeCheck;

// Versioned helpers — preferred for wallet code
pub const encodeCheckVersioned = base58.encodeCheckVersioned;
pub const decodeCheckVersioned = base58.decodeCheckVersioned;

// Streaming (buffered, not true streams — see base58.zig docs)
pub const StreamEncoder = base58.StreamEncoder;
pub const StreamDecoder = base58.StreamDecoder;
pub const encodeBatch = base58.encodeBatch;

// Limits and errors
pub const MAX_DECODE_INPUT = base58.MAX_DECODE_INPUT;
pub const Error = base58.Error;
