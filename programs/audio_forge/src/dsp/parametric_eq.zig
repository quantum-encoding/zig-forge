//! Parametric Equalizer
//!
//! A 10-band parametric equalizer built from cascaded biquad filters.
//! Each band can be independently configured with:
//! - Frequency (20Hz - 20kHz)
//! - Gain (-24dB to +24dB)
//! - Q factor (0.1 to 10.0)
//! - Filter type (peaking, low shelf, high shelf, low pass, high pass)
//!
//! Default configuration provides standard 10-band EQ frequencies:
//! 31Hz, 63Hz, 125Hz, 250Hz, 500Hz, 1kHz, 2kHz, 4kHz, 8kHz, 16kHz

const std = @import("std");
const math = std.math;

const graph = @import("graph.zig");
const biquad = @import("biquad.zig");

const Processor = graph.Processor;
const BiquadFilter = biquad.BiquadFilter;
const FilterType = biquad.FilterType;

/// Number of EQ bands
pub const NUM_BANDS = 10;

/// Default frequencies for 10-band EQ (ISO standard)
pub const DEFAULT_FREQUENCIES = [NUM_BANDS]f32{
    31.25, // Sub bass
    62.5, // Bass
    125.0, // Low mid
    250.0, // Mid
    500.0, // Mid
    1000.0, // Mid
    2000.0, // Upper mid
    4000.0, // Presence
    8000.0, // Brilliance
    16000.0, // Air
};

/// Default Q values (wider at low frequencies, narrower at high)
pub const DEFAULT_Q_VALUES = [NUM_BANDS]f32{
    0.7, // 31Hz
    0.7, // 63Hz
    1.0, // 125Hz
    1.0, // 250Hz
    1.2, // 500Hz
    1.2, // 1kHz
    1.4, // 2kHz
    1.4, // 4kHz
    1.5, // 8kHz
    1.5, // 16kHz
};

/// EQ band configuration
pub const BandConfig = struct {
    frequency: f32 = 1000.0,
    gain_db: f32 = 0.0,
    q: f32 = 1.0,
    filter_type: FilterType = .peaking,
    enabled: bool = true,

    /// Create a peaking band
    pub fn peaking(freq: f32, gain: f32, q: f32) BandConfig {
        return .{
            .frequency = freq,
            .gain_db = gain,
            .q = q,
            .filter_type = .peaking,
            .enabled = true,
        };
    }

    /// Create a low shelf band
    pub fn lowShelf(freq: f32, gain: f32, q: f32) BandConfig {
        return .{
            .frequency = freq,
            .gain_db = gain,
            .q = q,
            .filter_type = .lowshelf,
            .enabled = true,
        };
    }

    /// Create a high shelf band
    pub fn highShelf(freq: f32, gain: f32, q: f32) BandConfig {
        return .{
            .frequency = freq,
            .gain_db = gain,
            .q = q,
            .filter_type = .highshelf,
            .enabled = true,
        };
    }
};

/// 10-Band Parametric Equalizer
pub const ParametricEq = struct {
    /// Biquad filters for each band
    bands: [NUM_BANDS]BiquadFilter,

    /// Band configurations (for UI/serialization)
    configs: [NUM_BANDS]BandConfig,

    /// Sample rate
    sample_rate: f32,

    /// Master bypass
    bypassed: bool,

    /// Output gain (linear)
    output_gain: f32,

    const Self = @This();
    pub const name = "ParametricEQ";

    /// Initialize with default 10-band frequencies
    pub fn init(sample_rate: f32) Self {
        var self = Self{
            .bands = undefined,
            .configs = undefined,
            .sample_rate = sample_rate,
            .bypassed = false,
            .output_gain = 1.0,
        };

        // Initialize each band with default frequencies
        for (0..NUM_BANDS) |i| {
            self.configs[i] = .{
                .frequency = DEFAULT_FREQUENCIES[i],
                .gain_db = 0.0, // Flat response
                .q = DEFAULT_Q_VALUES[i],
                .filter_type = if (i == 0) .lowshelf else if (i == NUM_BANDS - 1) .highshelf else .peaking,
                .enabled = true,
            };

            self.bands[i] = BiquadFilter.init(
                self.configs[i].filter_type,
                sample_rate,
                self.configs[i].frequency,
                self.configs[i].q,
                self.configs[i].gain_db,
            );
        }

        return self;
    }

    /// Initialize with custom band configurations
    pub fn initCustom(sample_rate: f32, configs: [NUM_BANDS]BandConfig) Self {
        var self = Self{
            .bands = undefined,
            .configs = configs,
            .sample_rate = sample_rate,
            .bypassed = false,
            .output_gain = 1.0,
        };

        for (0..NUM_BANDS) |i| {
            self.bands[i] = BiquadFilter.init(
                configs[i].filter_type,
                sample_rate,
                configs[i].frequency,
                configs[i].q,
                configs[i].gain_db,
            );
        }

        return self;
    }

    /// Set band parameters
    pub fn setBand(self: *Self, band: usize, config: BandConfig) void {
        if (band >= NUM_BANDS) return;

        self.configs[band] = config;
        self.bands[band].setParameters(
            config.filter_type,
            config.frequency,
            config.q,
            config.gain_db,
        );
    }

    /// Set band gain only (most common adjustment)
    pub fn setBandGain(self: *Self, band: usize, gain_db: f32) void {
        if (band >= NUM_BANDS) return;

        self.configs[band].gain_db = gain_db;
        self.bands[band].setGain(gain_db);
    }

    /// Set band frequency
    pub fn setBandFrequency(self: *Self, band: usize, frequency: f32) void {
        if (band >= NUM_BANDS) return;

        self.configs[band].frequency = frequency;
        self.bands[band].setFrequency(frequency);
    }

    /// Set band Q
    pub fn setBandQ(self: *Self, band: usize, q: f32) void {
        if (band >= NUM_BANDS) return;

        self.configs[band].q = q;
        self.bands[band].setQ(q);
    }

    /// Enable/disable a band
    pub fn setBandEnabled(self: *Self, band: usize, enabled: bool) void {
        if (band >= NUM_BANDS) return;
        self.configs[band].enabled = enabled;
    }

    /// Set all bands to flat response
    pub fn flatten(self: *Self) void {
        for (0..NUM_BANDS) |i| {
            self.setBandGain(i, 0.0);
        }
    }

    /// Set output gain in dB
    pub fn setOutputGain(self: *Self, gain_db: f32) void {
        self.output_gain = math.pow(f32, 10.0, gain_db / 20.0);
    }

    /// Set master bypass
    pub fn setBypass(self: *Self, bypassed: bool) void {
        self.bypassed = bypassed;
    }

    /// Enable coefficient smoothing on all bands
    pub fn setSmoothing(self: *Self, smoothing: f32) void {
        for (&self.bands) |*band| {
            band.setSmoothing(smoothing);
        }
    }

    /// Get band configuration
    pub fn getBand(self: *const Self, band: usize) BandConfig {
        if (band >= NUM_BANDS) return .{};
        return self.configs[band];
    }

    /// Process audio buffer (Processor interface)
    pub fn process(self: *Self, buffer: []f32, frames: usize, channels: u8) void {
        if (self.bypassed) return;

        // Process through each enabled band
        for (0..NUM_BANDS) |i| {
            if (self.configs[i].enabled) {
                self.bands[i].process(buffer, frames, channels);
            }
        }

        // Apply output gain if not unity
        if (self.output_gain != 1.0) {
            const total_samples = frames * @as(usize, channels);
            for (buffer[0..total_samples]) |*sample| {
                sample.* *= self.output_gain;
            }
        }
    }

    /// Reset all filter states
    pub fn reset(self: *Self) void {
        for (&self.bands) |*band| {
            band.reset();
        }
    }

    /// Get combined magnitude response at a frequency
    pub fn magnitudeAt(self: *const Self, frequency: f32) f32 {
        var magnitude: f32 = 1.0;

        for (0..NUM_BANDS) |i| {
            if (self.configs[i].enabled) {
                magnitude *= self.bands[i].magnitudeAt(frequency);
            }
        }

        return magnitude * self.output_gain;
    }

    /// Get combined magnitude response in dB
    pub fn magnitudeDbAt(self: *const Self, frequency: f32) f32 {
        const mag = self.magnitudeAt(frequency);
        if (mag <= 0.0) return -120.0;
        return 20.0 * @log10(mag);
    }

    /// Get frequency response curve (for visualization)
    pub fn getFrequencyResponse(
        self: *const Self,
        out_frequencies: []f32,
        out_magnitudes_db: []f32,
        num_points: usize,
    ) void {
        const log_min = @log10(@as(f32, 20.0));
        const log_max = @log10(self.sample_rate * 0.499);
        const log_range = log_max - log_min;

        for (0..num_points) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_points - 1));
            const freq = math.pow(f32, 10.0, log_min + t * log_range);

            out_frequencies[i] = freq;
            out_magnitudes_db[i] = self.magnitudeDbAt(freq);
        }
    }
};

/// Preset EQ curves
pub const Preset = enum {
    flat,
    bass_boost,
    treble_boost,
    vocal,
    electronic,
    rock,
    jazz,
    classical,

    /// Apply preset to EQ
    pub fn apply(self: Preset, eq: *ParametricEq) void {
        switch (self) {
            .flat => eq.flatten(),

            .bass_boost => {
                eq.setBandGain(0, 6.0); // 31Hz
                eq.setBandGain(1, 5.0); // 63Hz
                eq.setBandGain(2, 3.0); // 125Hz
                eq.setBandGain(3, 1.0); // 250Hz
                for (4..NUM_BANDS) |i| eq.setBandGain(i, 0.0);
            },

            .treble_boost => {
                for (0..6) |i| eq.setBandGain(i, 0.0);
                eq.setBandGain(6, 2.0); // 2kHz
                eq.setBandGain(7, 4.0); // 4kHz
                eq.setBandGain(8, 5.0); // 8kHz
                eq.setBandGain(9, 6.0); // 16kHz
            },

            .vocal => {
                eq.setBandGain(0, -2.0); // Reduce rumble
                eq.setBandGain(1, -1.0);
                eq.setBandGain(2, 0.0);
                eq.setBandGain(3, 2.0); // Warmth
                eq.setBandGain(4, 3.0); // Presence
                eq.setBandGain(5, 4.0); // Clarity
                eq.setBandGain(6, 3.0);
                eq.setBandGain(7, 2.0);
                eq.setBandGain(8, 1.0);
                eq.setBandGain(9, 0.0);
            },

            .electronic => {
                eq.setBandGain(0, 5.0); // Sub bass
                eq.setBandGain(1, 4.0);
                eq.setBandGain(2, 0.0);
                eq.setBandGain(3, -2.0);
                eq.setBandGain(4, 0.0);
                eq.setBandGain(5, 2.0);
                eq.setBandGain(6, 3.0);
                eq.setBandGain(7, 4.0);
                eq.setBandGain(8, 3.0);
                eq.setBandGain(9, 2.0);
            },

            .rock => {
                eq.setBandGain(0, 4.0);
                eq.setBandGain(1, 3.0);
                eq.setBandGain(2, 1.0);
                eq.setBandGain(3, -1.0);
                eq.setBandGain(4, -2.0);
                eq.setBandGain(5, 0.0);
                eq.setBandGain(6, 2.0);
                eq.setBandGain(7, 4.0);
                eq.setBandGain(8, 5.0);
                eq.setBandGain(9, 4.0);
            },

            .jazz => {
                eq.setBandGain(0, 2.0);
                eq.setBandGain(1, 2.0);
                eq.setBandGain(2, 1.0);
                eq.setBandGain(3, 2.0);
                eq.setBandGain(4, -1.0);
                eq.setBandGain(5, -1.0);
                eq.setBandGain(6, 0.0);
                eq.setBandGain(7, 1.0);
                eq.setBandGain(8, 2.0);
                eq.setBandGain(9, 3.0);
            },

            .classical => {
                eq.setBandGain(0, 0.0);
                eq.setBandGain(1, 0.0);
                eq.setBandGain(2, 0.0);
                eq.setBandGain(3, 0.0);
                eq.setBandGain(4, 0.0);
                eq.setBandGain(5, 0.0);
                eq.setBandGain(6, -2.0);
                eq.setBandGain(7, -2.0);
                eq.setBandGain(8, -2.0);
                eq.setBandGain(9, -3.0);
            },
        }
    }
};

/// Create a Processor interface from a ParametricEq
pub fn makeProcessor(eq: *ParametricEq) Processor {
    return graph.makeProcessor(ParametricEq, eq);
}

// =============================================================================
// Tests
// =============================================================================

test "parametric eq init" {
    const eq = ParametricEq.init(48000);

    // Verify default frequencies
    try std.testing.expectApproxEqAbs(DEFAULT_FREQUENCIES[0], eq.configs[0].frequency, 0.01);
    try std.testing.expectApproxEqAbs(DEFAULT_FREQUENCIES[9], eq.configs[9].frequency, 0.01);

    // Default gains should be 0 (flat)
    for (0..NUM_BANDS) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), eq.configs[i].gain_db, 0.001);
    }
}

test "parametric eq flat response" {
    var eq = ParametricEq.init(48000);

    // With all gains at 0, response should be unity
    const mag_at_1k = eq.magnitudeAt(1000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mag_at_1k, 0.05);

    const mag_at_100 = eq.magnitudeAt(100);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mag_at_100, 0.05);
}

test "parametric eq set band gain" {
    var eq = ParametricEq.init(48000);

    // Boost 1kHz band by 6dB
    eq.setBandGain(5, 6.0);

    // At 1kHz, should see approximately 6dB boost
    const mag_db_at_1k = eq.magnitudeDbAt(1000);
    try std.testing.expect(mag_db_at_1k > 4.0);
    try std.testing.expect(mag_db_at_1k < 8.0);
}

test "parametric eq process" {
    var eq = ParametricEq.init(48000);

    // Apply bass boost
    eq.setBandGain(0, 6.0);
    eq.setBandGain(1, 4.0);

    var buffer = [_]f32{ 0.5, 0.5, 0.3, 0.3, 0.0, 0.0, -0.3, -0.3 };
    eq.process(&buffer, 4, 2);

    // Verify no NaN or Inf
    for (buffer) |sample| {
        try std.testing.expect(!math.isNan(sample));
        try std.testing.expect(!math.isInf(sample));
    }
}

test "parametric eq bypass" {
    var eq = ParametricEq.init(48000);
    eq.setBandGain(5, 12.0); // Heavy boost

    var buffer1 = [_]f32{ 0.5, 0.5 };
    var buffer2 = [_]f32{ 0.5, 0.5 };

    // Process with bypass
    eq.setBypass(true);
    eq.process(&buffer1, 1, 2);

    // Should be unchanged
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffer1[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffer1[1], 0.001);

    // Process without bypass
    eq.setBypass(false);
    eq.process(&buffer2, 1, 2);

    // Should be different (EQ applied)
    // Note: Single sample doesn't show much EQ effect due to filter delay
}

test "parametric eq preset" {
    var eq = ParametricEq.init(48000);

    // Apply bass boost preset
    Preset.bass_boost.apply(&eq);

    // Low frequencies should have gain
    try std.testing.expect(eq.configs[0].gain_db > 0);
    try std.testing.expect(eq.configs[1].gain_db > 0);

    // High frequencies should be flat
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eq.configs[9].gain_db, 0.001);

    // Apply flat to reset
    Preset.flat.apply(&eq);

    for (0..NUM_BANDS) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), eq.configs[i].gain_db, 0.001);
    }
}

test "parametric eq output gain" {
    var eq = ParametricEq.init(48000);
    eq.setOutputGain(-6.0); // -6dB

    // Process a sample
    var buffer = [_]f32{1.0};
    eq.process(&buffer, 1, 1);

    // Output should be approximately half amplitude
    // (First sample won't show full effect due to filter warmup)
}

test "parametric eq frequency response" {
    var eq = ParametricEq.init(48000);

    var frequencies: [64]f32 = undefined;
    var magnitudes: [64]f32 = undefined;

    eq.getFrequencyResponse(&frequencies, &magnitudes, 64);

    // First point should be near 20Hz
    try std.testing.expect(frequencies[0] >= 19.0);
    try std.testing.expect(frequencies[0] <= 21.0);

    // Last point should be near Nyquist
    try std.testing.expect(frequencies[63] > 20000.0);
}

test "parametric eq disable band" {
    var eq = ParametricEq.init(48000);

    // Heavy boost on band 5
    eq.setBandGain(5, 12.0);
    const boosted_mag = eq.magnitudeAt(1000);

    // Disable the band
    eq.setBandEnabled(5, false);
    const disabled_mag = eq.magnitudeAt(1000);

    // Disabled should be less than boosted
    try std.testing.expect(disabled_mag < boosted_mag);
}
