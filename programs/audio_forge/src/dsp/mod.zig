//! DSP Module
//!
//! Real-time audio processing components.
//!
//! Includes:
//! - Processing graph for chaining effects
//! - Biquad IIR filters (lowpass, highpass, peaking, shelf)
//! - 10-band Parametric EQ with presets
//! - Compressor (Phase 3)
//! - Reverb (Phase 3)

pub const graph = @import("graph.zig");
pub const biquad = @import("biquad.zig");
pub const parametric_eq = @import("parametric_eq.zig");

// Re-export commonly used types
pub const DspGraph = graph.DspGraph;
pub const Processor = graph.Processor;
pub const ProcessorNode = graph.ProcessorNode;
pub const makeProcessor = graph.makeProcessor;

pub const BiquadFilter = biquad.BiquadFilter;
pub const FilterType = biquad.FilterType;
pub const Coefficients = biquad.Coefficients;

pub const ParametricEq = parametric_eq.ParametricEq;
pub const EqBandConfig = parametric_eq.BandConfig;
pub const EqPreset = parametric_eq.Preset;
pub const NUM_EQ_BANDS = parametric_eq.NUM_BANDS;

test {
    _ = graph;
    _ = biquad;
    _ = parametric_eq;
}
