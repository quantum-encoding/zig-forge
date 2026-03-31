//! Audio Codec Module
//!
//! Re-exports all supported audio decoders.

pub const wav = @import("wav.zig");

pub const WavDecoder = wav.WavDecoder;

// Future codecs:
// pub const flac = @import("flac.zig");
// pub const mp3 = @import("mp3.zig");
// pub const FlacDecoder = flac.FlacDecoder;
// pub const Mp3Decoder = mp3.Mp3Decoder;
