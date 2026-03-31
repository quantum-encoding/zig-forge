//! Audio Forge Library
//!
//! Real-time audio DSP engine with sub-millisecond latency.
//!
//! Features:
//! - Lock-free audio ring buffer
//! - WAV/FLAC/MP3 decoding (pure Zig)
//! - SIMD-optimized DSP processing
//! - ALSA/PipeWire/JACK backends

pub const ring_buffer = @import("ring_buffer.zig");
pub const engine = @import("engine.zig");
pub const codec = @import("codec/mod.zig");
pub const backend = @import("backend/mod.zig");
pub const dsp = @import("dsp/mod.zig");

// Re-export main types
pub const AudioRingBuffer = ring_buffer.AudioRingBuffer;
pub const AudioEngine = engine.AudioEngine;
pub const EngineConfig = engine.Config;
pub const EngineState = engine.State;

pub const WavDecoder = codec.WavDecoder;

pub const AlsaBackend = backend.AlsaBackend;
pub const AlsaConfig = backend.AlsaConfig;
pub const SampleFormat = backend.SampleFormat;

// DSP types
pub const DspGraph = dsp.DspGraph;
pub const Processor = dsp.Processor;
pub const ProcessorNode = dsp.ProcessorNode;
pub const BiquadFilter = dsp.BiquadFilter;
pub const FilterType = dsp.FilterType;
pub const ParametricEq = dsp.ParametricEq;
pub const EqPreset = dsp.EqPreset;

// =============================================================================
// Tests
// =============================================================================

test {
    // Import all tests
    _ = ring_buffer;
    _ = codec.wav;
    // Skip backend tests - ALSA not available in test environment
    // _ = backend.alsa;
    _ = engine;
    _ = dsp;
}
