//! Biquad IIR Filter
//!
//! A second-order IIR filter implemented using Transposed Direct Form II.
//! This form minimizes numerical precision issues and provides optimal
//! performance for real-time audio processing.
//!
//! Supports standard filter types:
//! - Low-pass, high-pass, band-pass, notch
//! - Peaking EQ (for parametric equalizer bands)
//! - Low-shelf, high-shelf
//!
//! Coefficient calculation follows the Audio EQ Cookbook by Robert Bristow-Johnson.
//! Reference: https://www.w3.org/2011/audio/audio-eq-cookbook.html

const std = @import("std");
const math = std.math;

const graph = @import("graph.zig");
const Processor = graph.Processor;
const MAX_CHANNELS = graph.MAX_CHANNELS;

/// Filter types supported by the biquad
pub const FilterType = enum {
    lowpass,
    highpass,
    bandpass, // Constant skirt gain, peak gain = Q
    bandpass_peak, // Constant 0dB peak gain
    notch,
    allpass,
    peaking, // Parametric EQ band
    lowshelf,
    highshelf,
};

/// Biquad filter coefficients
/// Transfer function: H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
pub const Coefficients = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    /// Create coefficients for a specific filter type
    pub fn calculate(
        filter_type: FilterType,
        sample_rate: f32,
        frequency: f32,
        q: f32,
        gain_db: f32,
    ) Coefficients {
        // Limit frequency to valid range (avoid instability at Nyquist)
        const freq = @min(frequency, sample_rate * 0.499);
        const omega = 2.0 * math.pi * freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const alpha = sin_omega / (2.0 * q);

        // For shelving and peaking filters
        const a = math.pow(f32, 10.0, gain_db / 40.0); // sqrt(10^(dB/20))
        const two_sqrt_a_alpha = 2.0 * @sqrt(a) * alpha;

        var b0: f32 = undefined;
        var b1: f32 = undefined;
        var b2: f32 = undefined;
        var a0: f32 = undefined;
        var a1: f32 = undefined;
        var a2: f32 = undefined;

        switch (filter_type) {
            .lowpass => {
                b0 = (1.0 - cos_omega) / 2.0;
                b1 = 1.0 - cos_omega;
                b2 = (1.0 - cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .highpass => {
                b0 = (1.0 + cos_omega) / 2.0;
                b1 = -(1.0 + cos_omega);
                b2 = (1.0 + cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .bandpass => {
                b0 = sin_omega / 2.0;
                b1 = 0.0;
                b2 = -sin_omega / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .bandpass_peak => {
                b0 = alpha;
                b1 = 0.0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .notch => {
                b0 = 1.0;
                b1 = -2.0 * cos_omega;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .allpass => {
                b0 = 1.0 - alpha;
                b1 = -2.0 * cos_omega;
                b2 = 1.0 + alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .peaking => {
                b0 = 1.0 + alpha * a;
                b1 = -2.0 * cos_omega;
                b2 = 1.0 - alpha * a;
                a0 = 1.0 + alpha / a;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha / a;
            },
            .lowshelf => {
                const ap1 = a + 1.0;
                const am1 = a - 1.0;
                b0 = a * (ap1 - am1 * cos_omega + two_sqrt_a_alpha);
                b1 = 2.0 * a * (am1 - ap1 * cos_omega);
                b2 = a * (ap1 - am1 * cos_omega - two_sqrt_a_alpha);
                a0 = ap1 + am1 * cos_omega + two_sqrt_a_alpha;
                a1 = -2.0 * (am1 + ap1 * cos_omega);
                a2 = ap1 + am1 * cos_omega - two_sqrt_a_alpha;
            },
            .highshelf => {
                const ap1 = a + 1.0;
                const am1 = a - 1.0;
                b0 = a * (ap1 + am1 * cos_omega + two_sqrt_a_alpha);
                b1 = -2.0 * a * (am1 + ap1 * cos_omega);
                b2 = a * (ap1 + am1 * cos_omega - two_sqrt_a_alpha);
                a0 = ap1 - am1 * cos_omega + two_sqrt_a_alpha;
                a1 = 2.0 * (am1 - ap1 * cos_omega);
                a2 = ap1 - am1 * cos_omega - two_sqrt_a_alpha;
            },
        }

        // Normalize coefficients (divide by a0)
        const inv_a0 = 1.0 / a0;
        return .{
            .b0 = b0 * inv_a0,
            .b1 = b1 * inv_a0,
            .b2 = b2 * inv_a0,
            .a1 = a1 * inv_a0,
            .a2 = a2 * inv_a0,
        };
    }

    /// Create a bypass (unity gain) filter
    pub fn bypass() Coefficients {
        return .{
            .b0 = 1.0,
            .b1 = 0.0,
            .b2 = 0.0,
            .a1 = 0.0,
            .a2 = 0.0,
        };
    }
};

/// Per-channel filter state (delay line)
const ChannelState = struct {
    z1: f32 = 0.0, // z^-1 delay
    z2: f32 = 0.0, // z^-2 delay
};

/// Biquad filter processor
pub const BiquadFilter = struct {
    /// Current coefficients
    coeffs: Coefficients,

    /// Target coefficients (for smoothing)
    target_coeffs: Coefficients,

    /// Coefficient smoothing factor (0 = instant, 0.999 = very slow)
    smoothing: f32,

    /// Per-channel state
    state: [MAX_CHANNELS]ChannelState,

    /// Filter parameters (for display/editing)
    filter_type: FilterType,
    frequency: f32,
    q: f32,
    gain_db: f32,
    sample_rate: f32,

    const Self = @This();
    pub const name = "BiquadFilter";

    /// Initialize a biquad filter
    pub fn init(
        filter_type: FilterType,
        sample_rate: f32,
        frequency: f32,
        q: f32,
        gain_db: f32,
    ) Self {
        const coeffs = Coefficients.calculate(filter_type, sample_rate, frequency, q, gain_db);

        return .{
            .coeffs = coeffs,
            .target_coeffs = coeffs,
            .smoothing = 0.0, // No smoothing by default
            .state = [_]ChannelState{.{}} ** MAX_CHANNELS,
            .filter_type = filter_type,
            .frequency = frequency,
            .q = q,
            .gain_db = gain_db,
            .sample_rate = sample_rate,
        };
    }

    /// Create a lowpass filter
    pub fn lowpass(sample_rate: f32, frequency: f32, q: f32) Self {
        return init(.lowpass, sample_rate, frequency, q, 0.0);
    }

    /// Create a highpass filter
    pub fn highpass(sample_rate: f32, frequency: f32, q: f32) Self {
        return init(.highpass, sample_rate, frequency, q, 0.0);
    }

    /// Create a peaking EQ filter
    pub fn peaking(sample_rate: f32, frequency: f32, q: f32, gain_db: f32) Self {
        return init(.peaking, sample_rate, frequency, q, gain_db);
    }

    /// Create a low shelf filter
    pub fn lowShelf(sample_rate: f32, frequency: f32, q: f32, gain_db: f32) Self {
        return init(.lowshelf, sample_rate, frequency, q, gain_db);
    }

    /// Create a high shelf filter
    pub fn highShelf(sample_rate: f32, frequency: f32, q: f32, gain_db: f32) Self {
        return init(.highshelf, sample_rate, frequency, q, gain_db);
    }

    /// Set filter parameters (recalculates coefficients)
    pub fn setParameters(
        self: *Self,
        filter_type: FilterType,
        frequency: f32,
        q: f32,
        gain_db: f32,
    ) void {
        self.filter_type = filter_type;
        self.frequency = frequency;
        self.q = q;
        self.gain_db = gain_db;

        self.target_coeffs = Coefficients.calculate(
            filter_type,
            self.sample_rate,
            frequency,
            q,
            gain_db,
        );

        // If no smoothing, apply immediately
        if (self.smoothing == 0.0) {
            self.coeffs = self.target_coeffs;
        }
    }

    /// Set frequency only
    pub fn setFrequency(self: *Self, frequency: f32) void {
        self.setParameters(self.filter_type, frequency, self.q, self.gain_db);
    }

    /// Set Q only
    pub fn setQ(self: *Self, q: f32) void {
        self.setParameters(self.filter_type, self.frequency, q, self.gain_db);
    }

    /// Set gain only (for peaking/shelf filters)
    pub fn setGain(self: *Self, gain_db: f32) void {
        self.setParameters(self.filter_type, self.frequency, self.q, gain_db);
    }

    /// Enable coefficient smoothing to avoid clicks during parameter changes
    pub fn setSmoothing(self: *Self, smoothing: f32) void {
        self.smoothing = math.clamp(smoothing, 0.0, 0.9999);
    }

    /// Process audio buffer in-place (Processor interface)
    pub fn process(self: *Self, buffer: []f32, frames: usize, channels: u8) void {
        // Smooth coefficients if needed
        if (self.smoothing > 0.0) {
            self.smoothCoefficients();
        }

        const ch: usize = channels;
        const c = &self.coeffs;

        // Process each frame
        for (0..frames) |frame| {
            // Process each channel
            for (0..ch) |channel| {
                const idx = frame * ch + channel;
                const input = buffer[idx];
                const state = &self.state[channel];

                // Transposed Direct Form II
                // y[n] = b0*x[n] + z1
                // z1 = b1*x[n] - a1*y[n] + z2
                // z2 = b2*x[n] - a2*y[n]
                const output = c.b0 * input + state.z1;
                state.z1 = c.b1 * input - c.a1 * output + state.z2;
                state.z2 = c.b2 * input - c.a2 * output;

                buffer[idx] = output;
            }
        }
    }

    /// Smooth coefficients towards target
    fn smoothCoefficients(self: *Self) void {
        const s = self.smoothing;
        const inv_s = 1.0 - s;

        self.coeffs.b0 = s * self.coeffs.b0 + inv_s * self.target_coeffs.b0;
        self.coeffs.b1 = s * self.coeffs.b1 + inv_s * self.target_coeffs.b1;
        self.coeffs.b2 = s * self.coeffs.b2 + inv_s * self.target_coeffs.b2;
        self.coeffs.a1 = s * self.coeffs.a1 + inv_s * self.target_coeffs.a1;
        self.coeffs.a2 = s * self.coeffs.a2 + inv_s * self.target_coeffs.a2;
    }

    /// Reset filter state (clear delay lines)
    pub fn reset(self: *Self) void {
        for (&self.state) |*s| {
            s.z1 = 0.0;
            s.z2 = 0.0;
        }
    }

    /// Process a single sample (for testing/debugging)
    pub fn processSample(self: *Self, input: f32, channel: usize) f32 {
        const c = &self.coeffs;
        const state = &self.state[channel];

        const output = c.b0 * input + state.z1;
        state.z1 = c.b1 * input - c.a1 * output + state.z2;
        state.z2 = c.b2 * input - c.a2 * output;

        return output;
    }

    /// Get magnitude response at a given frequency (for visualization)
    pub fn magnitudeAt(self: *const Self, frequency: f32) f32 {
        const omega = 2.0 * math.pi * frequency / self.sample_rate;
        const cos_w = @cos(omega);
        const sin_w = @sin(omega);
        const cos_2w = @cos(2.0 * omega);
        const sin_2w = @sin(2.0 * omega);

        const c = &self.coeffs;

        // Numerator: b0 + b1*e^(-jw) + b2*e^(-2jw)
        const num_real = c.b0 + c.b1 * cos_w + c.b2 * cos_2w;
        const num_imag = -c.b1 * sin_w - c.b2 * sin_2w;

        // Denominator: 1 + a1*e^(-jw) + a2*e^(-2jw)
        const den_real = 1.0 + c.a1 * cos_w + c.a2 * cos_2w;
        const den_imag = -c.a1 * sin_w - c.a2 * sin_2w;

        const num_mag_sq = num_real * num_real + num_imag * num_imag;
        const den_mag_sq = den_real * den_real + den_imag * den_imag;

        return @sqrt(num_mag_sq / den_mag_sq);
    }

    /// Get magnitude response in dB
    pub fn magnitudeDbAt(self: *const Self, frequency: f32) f32 {
        const mag = self.magnitudeAt(frequency);
        if (mag <= 0.0) return -120.0;
        return 20.0 * @log10(mag);
    }
};

/// Create a Processor interface from a BiquadFilter
pub fn makeProcessor(filter: *BiquadFilter) Processor {
    return graph.makeProcessor(BiquadFilter, filter);
}

// =============================================================================
// Tests
// =============================================================================

test "biquad bypass" {
    const coeffs = Coefficients.bypass();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), coeffs.b0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), coeffs.b1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), coeffs.a1, 0.0001);
}

test "biquad lowpass unity at DC" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // DC signal should pass through unchanged
    const dc_mag = filter.magnitudeAt(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dc_mag, 0.01);
}

test "biquad lowpass attenuation at high freq" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // Signal well above cutoff should be attenuated
    const high_mag = filter.magnitudeAt(10000);
    try std.testing.expect(high_mag < 0.1); // At least -20dB
}

test "biquad highpass unity at Nyquist" {
    var filter = BiquadFilter.highpass(48000, 1000, 0.707);

    // High frequency should pass through
    const high_mag = filter.magnitudeAt(20000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), high_mag, 0.1);
}

test "biquad highpass attenuation at DC" {
    var filter = BiquadFilter.highpass(48000, 1000, 0.707);

    // DC should be completely blocked
    const dc_mag = filter.magnitudeAt(1.0); // Near DC
    try std.testing.expect(dc_mag < 0.01);
}

test "biquad peaking gain at center" {
    const gain_db: f32 = 6.0;
    var filter = BiquadFilter.peaking(48000, 1000, 2.0, gain_db);

    // At center frequency, gain should match requested
    const center_mag_db = filter.magnitudeDbAt(1000);
    try std.testing.expectApproxEqAbs(gain_db, center_mag_db, 0.5);
}

test "biquad peaking unity away from center" {
    var filter = BiquadFilter.peaking(48000, 1000, 2.0, 6.0);

    // Far from center, magnitude should approach unity
    const low_mag = filter.magnitudeAt(100);
    const high_mag = filter.magnitudeAt(10000);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), low_mag, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), high_mag, 0.1);
}

test "biquad process stereo" {
    var filter = BiquadFilter.lowpass(48000, 5000, 0.707);

    // Process stereo buffer
    var buffer = [_]f32{ 1.0, 1.0, 0.5, 0.5, 0.0, 0.0, -0.5, -0.5 };
    filter.process(&buffer, 4, 2);

    // Just verify processing doesn't crash and outputs reasonable values
    for (buffer) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
    }
}

test "biquad reset state" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // Process some samples to build up state
    _ = filter.processSample(1.0, 0);
    _ = filter.processSample(1.0, 0);

    // State should be non-zero
    try std.testing.expect(filter.state[0].z1 != 0.0 or filter.state[0].z2 != 0.0);

    // Reset
    filter.reset();

    // State should be zero
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), filter.state[0].z1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), filter.state[0].z2, 0.0001);
}

test "biquad parameter change" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // Change frequency
    filter.setFrequency(2000);
    try std.testing.expectApproxEqAbs(@as(f32, 2000), filter.frequency, 0.1);

    // The -3dB point should now be near 2000 Hz
    const mag_at_cutoff = filter.magnitudeDbAt(2000);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), mag_at_cutoff, 1.0);
}

test "coefficient smoothing" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);
    filter.setSmoothing(0.9);

    const original_b0 = filter.coeffs.b0;

    // Change frequency (coefficients should smooth towards target)
    filter.setFrequency(5000);

    // Process to trigger smoothing
    var buffer = [_]f32{0.0} ** 8;
    filter.process(&buffer, 4, 2);

    // Coefficients should have moved but not reached target yet
    try std.testing.expect(filter.coeffs.b0 != original_b0);
    try std.testing.expect(filter.coeffs.b0 != filter.target_coeffs.b0);
}

test "biquad lowpass filter unity gain at DC" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // DC (0 Hz) should pass through with unity gain
    const dc_mag = filter.magnitudeAt(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dc_mag, 0.05);
}

test "biquad lowpass filter attenuation above cutoff" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    // Frequency well above cutoff should be attenuated significantly
    const high_freq_mag = filter.magnitudeAt(10000);
    try std.testing.expect(high_freq_mag < 0.2);
}

test "biquad highpass filter unity at high frequencies" {
    var filter = BiquadFilter.highpass(48000, 1000, 0.707);

    // Frequency well above cutoff should have near unity gain
    const high_mag = filter.magnitudeAt(20000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), high_mag, 0.1);
}

test "biquad highpass filter attenuation at DC" {
    var filter = BiquadFilter.highpass(48000, 1000, 0.707);

    // DC should be strongly attenuated
    const dc_mag = filter.magnitudeAt(1.0);
    try std.testing.expect(dc_mag < 0.05);
}

test "biquad notch filter null at center frequency" {
    var filter = BiquadFilter.init(.notch, 48000, 1000, 2.0, 0.0);

    // At the notch frequency, gain should be near zero
    const center_mag = filter.magnitudeAt(1000);
    try std.testing.expect(center_mag < 0.1);
}

test "biquad allpass filter unity magnitude at all frequencies" {
    var filter = BiquadFilter.init(.allpass, 48000, 1000, 1.0, 0.0);

    const dc_mag = filter.magnitudeAt(0.0);
    const center_mag = filter.magnitudeAt(1000);
    const nyquist_mag = filter.magnitudeAt(24000);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dc_mag, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), center_mag, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), nyquist_mag, 0.05);
}

test "biquad peaking filter boost at center" {
    const gain_db: f32 = 12.0;
    var filter = BiquadFilter.peaking(48000, 2000, 1.0, gain_db);

    const center_mag_db = filter.magnitudeDbAt(2000);
    try std.testing.expectApproxEqAbs(gain_db, center_mag_db, 1.0);
}

test "biquad peaking filter cut at center" {
    const gain_db: f32 = -12.0;
    var filter = BiquadFilter.peaking(48000, 2000, 1.0, gain_db);

    const center_mag_db = filter.magnitudeDbAt(2000);
    try std.testing.expectApproxEqAbs(gain_db, center_mag_db, 1.0);
}

test "biquad lowshelf filter boosts low frequencies" {
    var filter = BiquadFilter.lowShelf(48000, 200, 1.0, 12.0);

    const low_mag_db = filter.magnitudeDbAt(50);
    try std.testing.expect(low_mag_db > 10.0); // Should be boosted
}

test "biquad highshelf filter boosts high frequencies" {
    var filter = BiquadFilter.highShelf(48000, 5000, 1.0, 12.0);

    const high_mag_db = filter.magnitudeDbAt(15000);
    try std.testing.expect(high_mag_db > 10.0); // Should be boosted
}

test "biquad process multiple channels independently" {
    var filter = BiquadFilter.lowpass(48000, 5000, 0.707);

    // Stereo buffer with different values
    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5, 0.0, 0.0, -0.5, 0.5 };
    filter.process(&buffer, 4, 2);

    // Just verify no NaN or Inf
    for (buffer) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
    }
}

test "biquad single sample processing" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    const input = 1.0;
    const output = filter.processSample(input, 0);

    try std.testing.expect(!std.math.isNan(output));
    try std.testing.expect(!std.math.isInf(output));
    try std.testing.expect(output >= -1.0 and output <= 1.0);
}

test "biquad frequency limiting prevents instability" {
    var filter = BiquadFilter.lowpass(48000, 30000, 0.707); // Freq near Nyquist

    // Should not crash or produce NaN
    const mag = filter.magnitudeAt(20000);
    try std.testing.expect(!std.math.isNan(mag));
    try std.testing.expect(!std.math.isInf(mag));
}

test "biquad parametric EQ coefficient calculation" {
    const coeffs = Coefficients.calculate(.peaking, 48000, 1000, 2.0, 6.0);

    // Coefficients should be valid numbers
    try std.testing.expect(!std.math.isNan(coeffs.b0));
    try std.testing.expect(!std.math.isNan(coeffs.b1));
    try std.testing.expect(!std.math.isNan(coeffs.b2));
    try std.testing.expect(!std.math.isNan(coeffs.a1));
    try std.testing.expect(!std.math.isNan(coeffs.a2));
}

test "biquad bandwidth vs Q relationship" {
    // Higher Q = narrower bandwidth
    const narrow = BiquadFilter.peaking(48000, 1000, 5.0, 6.0);
    const wide = BiquadFilter.peaking(48000, 1000, 1.0, 6.0);

    // At half octave away, narrow should have less boost
    const narrow_mag = narrow.magnitudeAt(750);
    const wide_mag = wide.magnitudeAt(750);

    try std.testing.expect(narrow_mag < wide_mag);
}

test "biquad magnitude response range" {
    var filter = BiquadFilter.lowpass(48000, 1000, 0.707);

    for ([_]f32{ 0, 100, 500, 1000, 5000, 10000, 20000 }) |freq| {
        const mag = filter.magnitudeAt(freq);
        try std.testing.expect(mag >= 0.0);
        try std.testing.expect(mag <= 2.0); // Should not exceed 2x for lowpass
    }
}
