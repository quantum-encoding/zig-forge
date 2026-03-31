# Audio Forge - Real-Time Audio DSP Engine

## Overview

Audio Forge is a production-grade real-time audio processing engine written in Zig, designed for sub-millisecond latency audio applications. It provides a complete audio processing pipeline from file decoding through DSP effects to hardware output.

## Design Goals

1. **Ultra-Low Latency**: <1ms round-trip latency for live audio processing
2. **Zero Allocation in Audio Path**: All memory pre-allocated, no allocations during processing
3. **Lock-Free Audio Thread**: No mutexes, semaphores, or blocking calls in the hot path
4. **SIMD-Optimized DSP**: AVX2/AVX-512 vectorized processing for maximum throughput
5. **No External Dependencies**: Pure Zig implementation for codec decode
6. **Multi-Backend Support**: ALSA, PipeWire, JACK for maximum compatibility

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           AUDIO FORGE ENGINE                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────────┐ │
│  │   DECODER   │───▶│   RING      │───▶│    DSP      │───▶│  BACKEND │ │
│  │   THREAD    │    │   BUFFER    │    │   GRAPH     │    │  OUTPUT  │ │
│  └─────────────┘    └─────────────┘    └─────────────┘    └──────────┘ │
│        │                  │                  │                  │       │
│        ▼                  ▼                  ▼                  ▼       │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────────┐ │
│  │ WAV/FLAC/   │    │  Lock-Free  │    │ SIMD Filter │    │  ALSA    │ │
│  │ MP3 Codec   │    │  SPSC Queue │    │   Chain     │    │ PipeWire │ │
│  └─────────────┘    └─────────────┘    └─────────────┘    │  JACK    │ │
│                                                            └──────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Specifications

### 1. Lock-Free Ring Buffer (`src/ring_buffer.zig`)

The core data structure for inter-thread communication without blocking.

```zig
pub const AudioRingBuffer = struct {
    /// Audio sample buffer (pre-allocated)
    buffer: []f32,

    /// Buffer capacity in frames (power of 2 for efficient modulo)
    capacity: usize,

    /// Number of channels (interleaved)
    channels: u8,

    /// Write position (atomic, updated by producer)
    write_pos: std.atomic.Value(usize),

    /// Read position (atomic, updated by consumer)
    read_pos: std.atomic.Value(usize),

    /// Cache line padding to prevent false sharing
    _padding: [64]u8,
};
```

**Design Decisions:**
- **Power-of-2 capacity**: Enables bitwise AND instead of modulo for wrap-around
- **Cache-line padding**: 64-byte padding between read/write positions prevents false sharing
- **Interleaved format**: Samples stored as [L0, R0, L1, R1, ...] for SIMD efficiency
- **SPSC pattern**: Single producer (decoder), single consumer (audio thread)

**API:**
```zig
pub fn init(allocator: Allocator, capacity_frames: usize, channels: u8) !AudioRingBuffer;
pub fn deinit(self: *AudioRingBuffer, allocator: Allocator) void;

/// Non-blocking write. Returns number of frames actually written.
pub fn write(self: *AudioRingBuffer, frames: []const f32) usize;

/// Non-blocking read. Returns number of frames actually read.
pub fn read(self: *AudioRingBuffer, out: []f32) usize;

/// Available frames for reading
pub fn availableRead(self: *const AudioRingBuffer) usize;

/// Available space for writing (in frames)
pub fn availableWrite(self: *const AudioRingBuffer) usize;
```

**Memory Ordering:**
- Write: `release` ordering after updating write_pos
- Read: `acquire` ordering before reading from buffer
- This ensures written data is visible to reader before position update

### 2. Audio Codecs (`src/codec/`)

Pure Zig implementations for audio file decoding.

#### 2.1 WAV Decoder (`src/codec/wav.zig`)

```zig
pub const WavDecoder = struct {
    file: std.fs.File,

    // Format info from header
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    data_offset: u64,
    data_size: u64,

    // Current position
    frames_read: u64,
    total_frames: u64,

    pub fn open(path: []const u8) !WavDecoder;
    pub fn decode(self: *WavDecoder, out: []f32) !usize;
    pub fn seek(self: *WavDecoder, frame: u64) !void;
    pub fn close(self: *WavDecoder) void;
};
```

**Supported formats:**
- PCM 8-bit unsigned
- PCM 16-bit signed little-endian
- PCM 24-bit signed little-endian
- PCM 32-bit signed little-endian
- IEEE float 32-bit
- IEEE float 64-bit

#### 2.2 FLAC Decoder (`src/codec/flac.zig`)

```zig
pub const FlacDecoder = struct {
    file: std.fs.File,

    // Stream info
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total_samples: u64,

    // Decoding state
    frame_buffer: []i32,           // Decoded samples (per channel)
    residual_buffer: []i32,        // LPC residuals

    // Seek table (optional)
    seek_points: ?[]SeekPoint,

    pub fn open(path: []const u8, allocator: Allocator) !FlacDecoder;
    pub fn decode(self: *FlacDecoder, out: []f32) !usize;
    pub fn seek(self: *FlacDecoder, sample: u64) !void;
    pub fn close(self: *FlacDecoder) void;
};
```

**FLAC Frame Structure:**
```
┌──────────────────────────────────────────────────────────────┐
│ Frame Header │ Subframe 0 │ Subframe 1 │ ... │ Frame Footer │
└──────────────────────────────────────────────────────────────┘
                     │
                     ▼
         ┌─────────────────────────┐
         │ Subframe Header         │
         │ ├─ Type (constant/      │
         │ │   verbatim/fixed/lpc) │
         │ ├─ Wasted bits          │
         │ └─ LPC order (if LPC)   │
         │ Warmup samples          │
         │ Residual (Rice coded)   │
         └─────────────────────────┘
```

**LPC Decoding (SIMD-optimized):**
```zig
fn decodeLpcSubframe(
    residuals: []const i32,
    coefficients: []const i32,
    shift: u5,
    warmup: []const i32,
    out: []i32,
) void {
    // Copy warmup samples
    @memcpy(out[0..warmup.len], warmup);

    // LPC prediction with SIMD
    const order = coefficients.len;
    var i: usize = order;
    while (i < out.len) : (i += 1) {
        var prediction: i64 = 0;

        // SIMD dot product for LPC coefficients
        // (vectorized in release builds)
        for (coefficients, 0..) |coef, j| {
            prediction += @as(i64, coef) * @as(i64, out[i - order + j]);
        }

        out[i] = @truncate((prediction >> shift) + residuals[i - order]);
    }
}
```

#### 2.3 MP3 Decoder (`src/codec/mp3.zig`)

Implements ISO/IEC 11172-3 (MPEG-1 Audio Layer III).

```zig
pub const Mp3Decoder = struct {
    file: std.fs.File,

    // Stream info (from first frame header)
    sample_rate: u32,
    channels: u8,
    bitrate: u32,

    // Decoding state
    bit_reservoir: BitReader,
    synthesis_buffer: [2][1024]f32,  // Per-channel synthesis
    overlap: [2][576]f32,            // IMDCT overlap-add

    // Huffman tables (compile-time generated)
    huffman_tables: *const HuffmanTables,

    pub fn open(path: []const u8) !Mp3Decoder;
    pub fn decode(self: *Mp3Decoder, out: []f32) !usize;
    pub fn close(self: *Mp3Decoder) void;
};
```

**MP3 Decoding Pipeline:**
```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Bit Stream  │───▶│  Huffman    │───▶│ Requantize  │───▶│  Reorder    │
│   Parse     │    │  Decode     │    │             │    │  (short)    │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                                                                │
                                                                ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Output    │◀───│ Polyphase   │◀───│   IMDCT     │◀───│   Stereo    │
│   Buffer    │    │  Synthesis  │    │  36-point   │    │  Decode     │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

**SIMD-Optimized Components:**
- **IMDCT**: 36-point IMDCT using pre-computed twiddle factors
- **Polyphase Synthesis**: 32-point DCT-IV using vectorized multiply-accumulate
- **Huffman Decoding**: Table-driven with 16-bit lookups

### 3. DSP Processing Graph (`src/dsp/`)

A node-based processing graph where audio flows through connected processors.

```zig
pub const ProcessorNode = struct {
    /// Process a block of audio in-place
    process_fn: *const fn (self: *ProcessorNode, buffer: []f32, channels: u8) void,

    /// Reset internal state (e.g., filter delays)
    reset_fn: *const fn (self: *ProcessorNode) void,

    /// User data pointer for the specific processor
    context: *anyopaque,

    /// Next node in the chain (null = end)
    next: ?*ProcessorNode,
};

pub const DspGraph = struct {
    head: ?*ProcessorNode,
    tail: ?*ProcessorNode,
    allocator: Allocator,

    pub fn addProcessor(self: *DspGraph, node: *ProcessorNode) void;
    pub fn process(self: *DspGraph, buffer: []f32, channels: u8) void;
    pub fn reset(self: *DspGraph) void;
};
```

#### 3.1 Biquad Filter (`src/dsp/biquad.zig`)

Standard IIR biquad filter with SIMD processing.

```zig
pub const BiquadFilter = struct {
    /// Filter coefficients [b0, b1, b2, a1, a2] (a0 normalized to 1)
    coeffs: [5]f32,

    /// Delay line per channel [z1, z2]
    state: [MAX_CHANNELS][2]f32,

    /// Filter type
    filter_type: FilterType,

    /// Current parameters
    frequency: f32,
    q: f32,
    gain_db: f32,
    sample_rate: f32,

    pub const FilterType = enum {
        lowpass,
        highpass,
        bandpass,
        notch,
        allpass,
        peaking,
        low_shelf,
        high_shelf,
    };

    pub fn init(filter_type: FilterType, freq: f32, q: f32, gain_db: f32, sample_rate: f32) BiquadFilter;
    pub fn setParams(self: *BiquadFilter, freq: f32, q: f32, gain_db: f32) void;
    pub fn process(self: *BiquadFilter, buffer: []f32, channels: u8) void;
    pub fn reset(self: *BiquadFilter) void;
};
```

**SIMD Processing (Transposed Direct Form II):**
```zig
fn processBlock(self: *BiquadFilter, buffer: []f32, channels: u8) void {
    const b0 = self.coeffs[0];
    const b1 = self.coeffs[1];
    const b2 = self.coeffs[2];
    const a1 = self.coeffs[3];
    const a2 = self.coeffs[4];

    for (0..channels) |ch| {
        var z1 = self.state[ch][0];
        var z2 = self.state[ch][1];

        var i: usize = ch;
        while (i < buffer.len) : (i += channels) {
            const x = buffer[i];
            const y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            buffer[i] = y;
        }

        self.state[ch][0] = z1;
        self.state[ch][1] = z2;
    }
}
```

#### 3.2 Parametric EQ (`src/dsp/eq.zig`)

Multi-band parametric equalizer using cascaded biquads.

```zig
pub const ParametricEq = struct {
    bands: [MAX_BANDS]EqBand,
    num_bands: u8,

    pub const MAX_BANDS = 10;

    pub const EqBand = struct {
        filter: BiquadFilter,
        enabled: bool,
        frequency: f32,
        gain_db: f32,
        q: f32,
        band_type: BandType,

        pub const BandType = enum {
            low_shelf,
            peaking,
            high_shelf,
            lowpass,
            highpass,
        };
    };

    pub fn init(sample_rate: f32) ParametricEq;
    pub fn setBand(self: *ParametricEq, index: u8, band: EqBand) void;
    pub fn process(self: *ParametricEq, buffer: []f32, channels: u8) void;
};
```

#### 3.3 Dynamics Compressor (`src/dsp/compressor.zig`)

```zig
pub const Compressor = struct {
    // Parameters
    threshold_db: f32,      // Compression threshold (-60 to 0 dB)
    ratio: f32,             // Compression ratio (1:1 to inf:1)
    attack_ms: f32,         // Attack time (0.1 to 100 ms)
    release_ms: f32,        // Release time (10 to 1000 ms)
    knee_db: f32,           // Soft knee width (0 to 12 dB)
    makeup_gain_db: f32,    // Output gain compensation

    // Internal state
    envelope: f32,          // Current envelope level
    attack_coeff: f32,      // Attack smoothing coefficient
    release_coeff: f32,     // Release smoothing coefficient
    sample_rate: f32,

    pub fn init(sample_rate: f32) Compressor;
    pub fn setParams(self: *Compressor, threshold: f32, ratio: f32, attack: f32, release: f32) void;
    pub fn process(self: *Compressor, buffer: []f32, channels: u8) void;
};
```

**Gain Reduction Calculation:**
```zig
fn computeGain(self: *Compressor, input_db: f32) f32 {
    const threshold = self.threshold_db;
    const ratio = self.ratio;
    const knee = self.knee_db;

    if (input_db < threshold - knee / 2) {
        // Below knee - no compression
        return 0;
    } else if (input_db > threshold + knee / 2) {
        // Above knee - full compression
        return (threshold - input_db) * (1 - 1 / ratio);
    } else {
        // In knee region - soft knee
        const x = input_db - threshold + knee / 2;
        return x * x / (2 * knee) * (1 / ratio - 1);
    }
}
```

#### 3.4 Reverb (`src/dsp/reverb.zig`)

Algorithmic reverb using Schroeder/Moorer architecture.

```zig
pub const Reverb = struct {
    // Parameters
    room_size: f32,         // 0.0 - 1.0
    damping: f32,           // High frequency damping
    wet_dry: f32,           // Wet/dry mix
    width: f32,             // Stereo width

    // Comb filters (8 parallel)
    comb_filters: [8]CombFilter,

    // All-pass filters (4 series)
    allpass_filters: [4]AllpassFilter,

    // Pre-delay line
    predelay: DelayLine,
    predelay_ms: f32,

    sample_rate: f32,

    pub fn init(allocator: Allocator, sample_rate: f32) !Reverb;
    pub fn setParams(self: *Reverb, room_size: f32, damping: f32, wet_dry: f32) void;
    pub fn process(self: *Reverb, buffer: []f32, channels: u8) void;
    pub fn deinit(self: *Reverb, allocator: Allocator) void;
};

const CombFilter = struct {
    buffer: []f32,
    index: usize,
    feedback: f32,
    damping: f32,
    damp_state: f32,

    fn process(self: *CombFilter, input: f32) f32 {
        const output = self.buffer[self.index];

        // Low-pass filtered feedback
        self.damp_state = output * (1 - self.damping) + self.damp_state * self.damping;

        self.buffer[self.index] = input + self.damp_state * self.feedback;
        self.index = (self.index + 1) % self.buffer.len;

        return output;
    }
};

const AllpassFilter = struct {
    buffer: []f32,
    index: usize,
    feedback: f32,

    fn process(self: *AllpassFilter, input: f32) f32 {
        const delayed = self.buffer[self.index];
        const output = delayed - input;

        self.buffer[self.index] = input + delayed * self.feedback;
        self.index = (self.index + 1) % self.buffer.len;

        return output;
    }
};
```

**Comb Filter Delay Times (in samples at 44.1kHz):**
| Filter | Left Delay | Right Delay |
|--------|------------|-------------|
| 0      | 1116       | 1139        |
| 1      | 1188       | 1211        |
| 2      | 1277       | 1300        |
| 3      | 1356       | 1379        |
| 4      | 1422       | 1445        |
| 5      | 1491       | 1514        |
| 6      | 1557       | 1580        |
| 7      | 1617       | 1640        |

**All-pass Delay Times:**
| Filter | Delay |
|--------|-------|
| 0      | 556   |
| 1      | 441   |
| 2      | 341   |
| 3      | 225   |

### 4. Audio Backends (`src/backend/`)

#### 4.1 ALSA Backend (`src/backend/alsa.zig`)

Direct ALSA interface using `libasound` through Zig's C interop.

```zig
pub const AlsaBackend = struct {
    handle: *c.snd_pcm_t,
    hw_params: *c.snd_pcm_hw_params_t,

    sample_rate: u32,
    channels: u32,
    period_size: u32,       // Frames per period
    buffer_size: u32,       // Total buffer frames

    // Callback for audio processing
    callback: *const fn (buffer: []f32, channels: u32, user_data: ?*anyopaque) void,
    user_data: ?*anyopaque,

    // Thread handle for callback mode
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn open(device: []const u8, config: Config) !AlsaBackend;
    pub fn start(self: *AlsaBackend) !void;
    pub fn stop(self: *AlsaBackend) void;
    pub fn close(self: *AlsaBackend) void;

    pub const Config = struct {
        sample_rate: u32 = 48000,
        channels: u32 = 2,
        period_size: u32 = 256,     // ~5.3ms at 48kHz
        periods: u32 = 2,           // Double buffering
        format: Format = .f32_le,

        pub const Format = enum {
            s16_le,
            s24_le,
            s32_le,
            f32_le,
        };
    };
};
```

**ALSA Initialization Sequence:**
```zig
fn initHardware(self: *AlsaBackend, config: Config) !void {
    // Open PCM device
    try checkAlsa(c.snd_pcm_open(&self.handle, "default", c.SND_PCM_STREAM_PLAYBACK, 0));

    // Allocate hw_params
    try checkAlsa(c.snd_pcm_hw_params_malloc(&self.hw_params));
    try checkAlsa(c.snd_pcm_hw_params_any(self.handle, self.hw_params));

    // Set parameters
    try checkAlsa(c.snd_pcm_hw_params_set_access(self.handle, self.hw_params,
        c.SND_PCM_ACCESS_RW_INTERLEAVED));
    try checkAlsa(c.snd_pcm_hw_params_set_format(self.handle, self.hw_params,
        c.SND_PCM_FORMAT_FLOAT_LE));
    try checkAlsa(c.snd_pcm_hw_params_set_channels(self.handle, self.hw_params,
        config.channels));
    try checkAlsa(c.snd_pcm_hw_params_set_rate(self.handle, self.hw_params,
        config.sample_rate, 0));
    try checkAlsa(c.snd_pcm_hw_params_set_period_size(self.handle, self.hw_params,
        config.period_size, 0));
    try checkAlsa(c.snd_pcm_hw_params_set_periods(self.handle, self.hw_params,
        config.periods, 0));

    // Apply hw_params
    try checkAlsa(c.snd_pcm_hw_params(self.handle, self.hw_params));

    // Prepare device
    try checkAlsa(c.snd_pcm_prepare(self.handle));
}
```

#### 4.2 PipeWire Backend (`src/backend/pipewire.zig`)

Modern Linux audio via PipeWire's SPA API.

```zig
pub const PipeWireBackend = struct {
    main_loop: *c.pw_main_loop,
    context: *c.pw_context,
    core: *c.pw_core,
    stream: *c.pw_stream,

    sample_rate: u32,
    channels: u32,

    callback: *const fn (buffer: []f32, channels: u32, user_data: ?*anyopaque) void,
    user_data: ?*anyopaque,

    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn open(config: Config) !PipeWireBackend;
    pub fn start(self: *PipeWireBackend) !void;
    pub fn stop(self: *PipeWireBackend) void;
    pub fn close(self: *PipeWireBackend) void;

    pub const Config = struct {
        sample_rate: u32 = 48000,
        channels: u32 = 2,
        buffer_frames: u32 = 256,
        app_name: []const u8 = "AudioForge",
    };
};
```

#### 4.3 JACK Backend (`src/backend/jack.zig`)

Professional audio via JACK Audio Connection Kit.

```zig
pub const JackBackend = struct {
    client: *c.jack_client_t,
    output_ports: [MAX_CHANNELS]*c.jack_port_t,
    input_ports: [MAX_CHANNELS]*c.jack_port_t,

    sample_rate: u32,
    buffer_size: u32,

    callback: *const fn (buffer: []f32, channels: u32, user_data: ?*anyopaque) void,
    user_data: ?*anyopaque,

    pub const MAX_CHANNELS = 8;

    pub fn open(client_name: []const u8) !JackBackend;
    pub fn start(self: *JackBackend) !void;
    pub fn stop(self: *JackBackend) void;
    pub fn close(self: *JackBackend) void;
    pub fn connect(self: *JackBackend, source: []const u8, dest: []const u8) !void;

    // JACK callback (called from JACK thread)
    fn processCallback(nframes: u32, arg: ?*anyopaque) callconv(.C) c_int;
};
```

### 5. Sample Rate Conversion (`src/resampler.zig`)

High-quality resampling using polyphase FIR filters.

```zig
pub const Resampler = struct {
    // Filter bank (compile-time generated)
    filter_bank: []const f32,
    filter_len: usize,
    num_phases: usize,

    // Conversion ratio
    ratio: f64,              // output_rate / input_rate

    // State
    phase_accumulator: f64,
    history: []f32,          // Input history buffer

    pub fn init(allocator: Allocator, input_rate: u32, output_rate: u32, quality: Quality) !Resampler;
    pub fn process(self: *Resampler, input: []const f32, output: []f32) usize;
    pub fn reset(self: *Resampler) void;
    pub fn deinit(self: *Resampler, allocator: Allocator) void;

    pub const Quality = enum {
        fast,       // 8-tap filter
        medium,     // 32-tap filter
        high,       // 64-tap filter
        highest,    // 128-tap filter
    };
};
```

**Polyphase Interpolation:**
```zig
fn interpolate(self: *Resampler, phase: f64) f32 {
    const phase_idx = @as(usize, @intFromFloat(phase * @as(f64, @floatFromInt(self.num_phases))));
    const frac = phase * @as(f64, @floatFromInt(self.num_phases)) - @as(f64, @floatFromInt(phase_idx));

    const filter = self.filter_bank[phase_idx * self.filter_len ..][0..self.filter_len];

    var sum: f32 = 0;
    for (filter, 0..) |coeff, i| {
        sum += coeff * self.history[i];
    }

    return sum;
}
```

## File Layout

```
audio_forge/
├── build.zig
├── ARCHITECTURE.md
├── README.md
└── src/
    ├── main.zig              # CLI entry point
    ├── lib.zig               # Library exports
    ├── engine.zig            # Main audio engine
    ├── ring_buffer.zig       # Lock-free SPSC ring buffer
    ├── resampler.zig         # Sample rate conversion
    ├── codec/
    │   ├── mod.zig           # Codec module
    │   ├── wav.zig           # WAV decoder
    │   ├── flac.zig          # FLAC decoder
    │   ├── mp3.zig           # MP3 decoder
    │   ├── huffman.zig       # MP3 Huffman tables
    │   └── bit_reader.zig    # Bit-level reading
    ├── dsp/
    │   ├── mod.zig           # DSP module
    │   ├── biquad.zig        # Biquad filter
    │   ├── eq.zig            # Parametric EQ
    │   ├── compressor.zig    # Dynamics compressor
    │   ├── limiter.zig       # Brickwall limiter
    │   ├── reverb.zig        # Algorithmic reverb
    │   ├── delay.zig         # Delay line
    │   └── graph.zig         # Processing graph
    └── backend/
        ├── mod.zig           # Backend module
        ├── alsa.zig          # ALSA backend
        ├── pipewire.zig      # PipeWire backend
        └── jack.zig          # JACK backend
```

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Audio callback latency | <500μs | Time to process one buffer |
| Ring buffer operations | <100ns | Lock-free read/write |
| Biquad processing | 4 cycles/sample | SIMD vectorized |
| Full EQ (10 bands) | <1μs/sample | Cascaded biquads |
| Reverb processing | <2μs/sample | 8 combs + 4 allpass |
| MP3 decode throughput | >100x realtime | Huffman + IMDCT |
| FLAC decode throughput | >200x realtime | LPC + Rice decode |
| Memory footprint | <10MB | Including all buffers |

## Latency Analysis

```
┌─────────────────────────────────────────────────────────────────┐
│                    LATENCY BREAKDOWN                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Audio Backend Buffer (ALSA/PipeWire/JACK):                    │
│  ├─ Period size: 256 samples @ 48kHz = 5.33ms                  │
│  └─ Double buffering: +5.33ms worst case                       │
│                                                                 │
│  Ring Buffer (decoder → DSP):                                   │
│  └─ Configurable, typically 1024 samples = 21.3ms              │
│                                                                 │
│  DSP Processing:                                                │
│  └─ <0.5ms for full chain                                      │
│                                                                 │
│  TOTAL END-TO-END:                                              │
│  ├─ Best case:  ~5.5ms (single period + DSP)                   │
│  ├─ Typical:    ~11ms (double buffer + DSP)                    │
│  └─ Worst case: ~32ms (with large ring buffer)                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Thread Model

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌─────────────┐                         ┌─────────────┐       │
│  │   MAIN      │                         │   AUDIO     │       │
│  │   THREAD    │                         │   THREAD    │       │
│  │             │                         │ (Real-time) │       │
│  │ • File I/O  │      Ring Buffer       │             │       │
│  │ • Decoding  │ ─────────────────────▶ │ • DSP proc  │       │
│  │ • UI/CLI    │     (Lock-free)        │ • Backend   │       │
│  │             │                         │             │       │
│  └─────────────┘                         └─────────────┘       │
│                                                                 │
│  Priority: Normal                        Priority: SCHED_FIFO  │
│  Can block on I/O                        Never blocks          │
│  Uses allocator                          Zero allocations      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Usage Examples

### Basic Playback
```zig
const engine = try AudioEngine.init(allocator, .{
    .backend = .alsa,
    .sample_rate = 48000,
    .buffer_size = 256,
});
defer engine.deinit();

try engine.loadFile("music.flac");
try engine.play();
```

### With DSP Processing
```zig
// Add parametric EQ
var eq = ParametricEq.init(48000);
eq.setBand(0, .{ .band_type = .low_shelf, .frequency = 100, .gain_db = 3 });
eq.setBand(1, .{ .band_type = .peaking, .frequency = 1000, .gain_db = -2, .q = 1.4 });
eq.setBand(2, .{ .band_type = .high_shelf, .frequency = 8000, .gain_db = 2 });

engine.addProcessor(&eq.node);

// Add compressor
var compressor = Compressor.init(48000);
compressor.setParams(-20, 4, 10, 100);  // threshold, ratio, attack, release
engine.addProcessor(&compressor.node);

// Add reverb
var reverb = try Reverb.init(allocator, 48000);
reverb.setParams(0.8, 0.3, 0.3);  // room_size, damping, wet_dry
engine.addProcessor(&reverb.node);
```

### CLI Interface
```bash
# Simple playback
audio-forge play music.flac

# With EQ and reverb
audio-forge play music.mp3 --eq "100:+3,1k:-2,8k:+2" --reverb 0.5

# List audio devices
audio-forge devices

# Record to file
audio-forge record --output recording.wav --duration 60

# Real-time DSP on microphone
audio-forge monitor --input hw:0 --eq "100:+6" --compressor "-20:4:10:100"
```

## Build Instructions

```bash
# Debug build
zig build

# Release build (SIMD optimized)
zig build -Doptimize=ReleaseFast

# With specific backend
zig build -Dalsa=true -Dpipewire=false -Djack=false

# Run tests
zig build test

# Run benchmarks
zig build bench
```

## Dependencies

- **libasound2** (ALSA backend)
- **libpipewire-0.3** (PipeWire backend)
- **libjack** (JACK backend)

All codec implementations (WAV, FLAC, MP3) are pure Zig with no external dependencies.

## License

MIT License - QUANTUM ENCODING LTD
