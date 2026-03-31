# Audio Forge

**Real-time audio DSP engine with sub-millisecond latency**

```
┌─────────────────────────────────────────────────────────────────┐
│  DECODER  ──▶  RING BUFFER  ──▶  DSP GRAPH  ──▶  AUDIO OUT    │
│   Thread       (Lock-free)      (SIMD EQ,       (ALSA/PW/     │
│                                  Comp, Reverb)   JACK)         │
└─────────────────────────────────────────────────────────────────┘
```

## Features

- **Lock-free audio buffer ring** for <1ms latency
- **SIMD-optimized DSP**: EQ, compression, reverb, limiting
- **Pure Zig codecs**: WAV, FLAC, MP3 decode without external libs
- **Multi-backend**: ALSA, PipeWire, JACK support
- **Zero allocations** in the audio processing path

## Quick Start

```bash
# Build
zig build -Doptimize=ReleaseFast

# Play audio file
audio-forge play music.flac

# Play with processing
audio-forge play music.mp3 --eq "100:+3,1k:-2,8k:+2" --reverb 0.5

# List audio devices
audio-forge devices
```

## Performance

| Metric | Value |
|--------|-------|
| Audio callback latency | <500μs |
| Ring buffer ops | <100ns |
| 10-band EQ | <1μs/sample |
| Reverb | <2μs/sample |
| MP3 decode | >100x realtime |
| FLAC decode | >200x realtime |

## DSP Processors

### Parametric EQ
- 10-band fully parametric equalizer
- Low/high shelf, peaking, lowpass, highpass filters
- SIMD-vectorized biquad processing

### Dynamics Compressor
- Threshold, ratio, attack, release controls
- Soft-knee compression
- Look-ahead (optional)

### Algorithmic Reverb
- Schroeder/Moorer architecture
- 8 parallel comb filters + 4 series allpass
- Room size, damping, wet/dry controls

## Supported Formats

| Format | Features |
|--------|----------|
| WAV | PCM 8/16/24/32-bit, IEEE Float 32/64-bit |
| FLAC | Lossless, all bit depths, seeking |
| MP3 | MPEG-1 Layer III, VBR/CBR |

## Building

```bash
# All backends
zig build

# Specific backend only
zig build -Dalsa=true -Dpipewire=false -Djack=false

# Tests
zig build test

# Benchmarks
zig build bench
```

## Dependencies

- `libasound2` - ALSA backend
- `libpipewire-0.3` - PipeWire backend
- `libjack` - JACK backend

Codecs are pure Zig - no external dependencies.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed technical specification.

## License

MIT License - QUANTUM ENCODING LTD
