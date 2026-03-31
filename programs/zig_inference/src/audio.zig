const std = @import("std");
const Allocator = std.mem.Allocator;

// Whisper audio constants
pub const SAMPLE_RATE: u32 = 16000;
pub const N_FFT: u32 = 400;
pub const HOP_LENGTH: u32 = 160;
pub const N_MELS: u32 = 80;
pub const CHUNK_LENGTH: u32 = 30; // seconds
pub const N_SAMPLES: u32 = SAMPLE_RATE * CHUNK_LENGTH; // 480000
pub const N_FRAMES: u32 = N_SAMPLES / HOP_LENGTH; // 3000
pub const FFT_SIZE: u32 = 512; // next power of 2 >= N_FFT
pub const N_FREQ: u32 = FFT_SIZE / 2 + 1; // 257

pub const MelSpectrogram = struct {
    data: []f32, // [N_MELS × N_FRAMES] = [80 × 3000]
    n_mels: u32,
    n_frames: u32,

    pub fn deinit(self: *MelSpectrogram, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

// ── WAV Reader ──

pub fn readWav(allocator: Allocator, path: []const u8) ![]f32 {
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);

    const fp = std.c.fopen(c_path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(fp);

    // Read RIFF header (12 bytes)
    var riff_header: [12]u8 = undefined;
    if (std.c.fread(&riff_header, 1, 12, fp) != 12) return error.InvalidHeader;
    if (!std.mem.eql(u8, riff_header[0..4], "RIFF")) return error.NotRiff;
    if (!std.mem.eql(u8, riff_header[8..12], "WAVE")) return error.NotWave;

    // Scan chunks looking for fmt and data
    var audio_format: u16 = 0;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data_size: u32 = 0;
    var found_fmt = false;
    var found_data = false;

    var chunk_header: [8]u8 = undefined;
    while (std.c.fread(&chunk_header, 1, 8, fp) == 8) {
        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            var fmt_data: [16]u8 = undefined;
            if (std.c.fread(&fmt_data, 1, 16, fp) != 16) return error.InvalidHeader;
            audio_format = std.mem.readInt(u16, fmt_data[0..2], .little);
            num_channels = std.mem.readInt(u16, fmt_data[2..4], .little);
            sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, fmt_data[14..16], .little);
            found_fmt = true;
            // Skip any extra fmt bytes
            if (chunk_size > 16) skipBytes(fp, chunk_size - 16);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_size = chunk_size;
            found_data = true;
            break; // fread position is now at start of audio data
        } else {
            // Skip unknown chunk (pad to even boundary)
            skipBytes(fp, (chunk_size + 1) & ~@as(u32, 1));
        }
    }

    if (!found_fmt or !found_data) return error.InvalidHeader;
    if (audio_format != 1) return error.NotPCM;
    if (sample_rate != SAMPLE_RATE) return error.WrongSampleRate;
    if (bits_per_sample != 16) return error.WrongBitDepth;

    const n_samples_in_file = data_size / (@as(u32, num_channels) * 2);

    // Read raw samples
    const raw = try allocator.alloc(i16, n_samples_in_file);
    defer allocator.free(raw);
    const read_count = std.c.fread(@ptrCast(raw.ptr), 2, n_samples_in_file, fp);

    // Convert to f32, take first channel if stereo
    const actual_samples: usize = @intCast(read_count);
    const samples = try allocator.alloc(f32, N_SAMPLES);
    @memset(samples, 0.0);

    const copy_len = @min(actual_samples, N_SAMPLES);
    if (num_channels == 1) {
        for (0..copy_len) |i| {
            samples[i] = @as(f32, @floatFromInt(raw[i])) / 32768.0;
        }
    } else {
        // Stereo: take left channel
        const mono_samples = @min(copy_len, actual_samples / num_channels);
        for (0..mono_samples) |i| {
            samples[i] = @as(f32, @floatFromInt(raw[i * num_channels])) / 32768.0;
        }
    }

    return samples;
}

fn skipBytes(fp: *std.c.FILE, n: u32) void {
    var skip_buf: [256]u8 = undefined;
    var remaining: usize = n;
    while (remaining > 0) {
        const chunk = @min(remaining, 256);
        const read = std.c.fread(&skip_buf, 1, chunk, fp);
        if (read == 0) break;
        remaining -= read;
    }
}

// ── FFT ──

fn fft512(re: *[FFT_SIZE]f32, im: *[FFT_SIZE]f32) void {
    // Bit-reversal permutation
    var j: u32 = 0;
    for (1..FFT_SIZE) |ii| {
        const i: u32 = @intCast(ii);
        var bit: u32 = FFT_SIZE >> 1;
        while (j & bit != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            const tmp_re = re[i];
            re[i] = re[j];
            re[j] = tmp_re;
            const tmp_im = im[i];
            im[i] = im[j];
            im[j] = tmp_im;
        }
    }

    // Butterfly stages
    var len: u32 = 2;
    while (len <= FFT_SIZE) : (len *= 2) {
        const half = len / 2;
        const angle_step = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        var i: u32 = 0;
        while (i < FFT_SIZE) : (i += len) {
            for (0..half) |k| {
                const angle = angle_step * @as(f32, @floatFromInt(k));
                const wr = @cos(angle);
                const wi = @sin(angle);
                const a = i + @as(u32, @intCast(k));
                const b = a + half;
                const tr = re[b] * wr - im[b] * wi;
                const ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] = re[a] + tr;
                im[a] = im[a] + ti;
            }
        }
    }
}

// ── Mel Filterbank ──

fn hzToMel(hz: f32) f32 {
    return 2595.0 * std.math.log10(1.0 + hz / 700.0);
}

fn melToHz(mel: f32) f32 {
    return 700.0 * (std.math.pow(f32, 10.0, mel / 2595.0) - 1.0);
}

const MelFilterbank = struct {
    filters: []f32, // [N_MELS × N_FREQ]
    n_mels: u32,
    n_freq: u32,

    fn init(allocator: Allocator) !MelFilterbank {
        const n_mels = N_MELS;
        const n_freq = N_FREQ;
        const filters = try allocator.alloc(f32, n_mels * n_freq);
        @memset(filters, 0.0);

        const mel_low = hzToMel(0.0);
        const mel_high = hzToMel(@as(f32, @floatFromInt(SAMPLE_RATE)) / 2.0);

        // n_mels + 2 boundary points
        var mel_points: [N_MELS + 2]f32 = undefined;
        for (0..N_MELS + 2) |i| {
            mel_points[i] = mel_low + @as(f32, @floatFromInt(i)) * (mel_high - mel_low) / @as(f32, @floatFromInt(N_MELS + 1));
        }

        var hz_points: [N_MELS + 2]f32 = undefined;
        for (0..N_MELS + 2) |i| {
            hz_points[i] = melToHz(mel_points[i]);
        }

        // Convert Hz to FFT bin indices
        var bin_points: [N_MELS + 2]f32 = undefined;
        for (0..N_MELS + 2) |i| {
            bin_points[i] = hz_points[i] * @as(f32, @floatFromInt(FFT_SIZE)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        }

        // Build triangular filters
        for (0..n_mels) |m| {
            for (0..n_freq) |k| {
                const k_f: f32 = @floatFromInt(k);
                const left = bin_points[m];
                const center = bin_points[m + 1];
                const right = bin_points[m + 2];

                if (k_f > left and k_f <= center and center > left) {
                    filters[m * n_freq + k] = (k_f - left) / (center - left);
                } else if (k_f > center and k_f < right and right > center) {
                    filters[m * n_freq + k] = (right - k_f) / (right - center);
                }
            }

            // Normalize filter (slaney normalization)
            const left_hz = hz_points[m];
            const right_hz = hz_points[m + 2];
            const norm = 2.0 / (right_hz - left_hz);
            for (0..n_freq) |k| {
                filters[m * n_freq + k] *= norm;
            }
        }

        return MelFilterbank{
            .filters = filters,
            .n_mels = n_mels,
            .n_freq = n_freq,
        };
    }

    fn deinit(self: *MelFilterbank, allocator: Allocator) void {
        allocator.free(self.filters);
    }
};

// ── Mel Spectrogram Pipeline ──

/// Compute mel spectrogram using provided mel filters from model file.
/// filters: [n_mels × n_freq] mel filterbank from ggml file
/// n_freq: number of frequency bins (typically 201 = N_FFT/2+1)
pub fn melSpectrogramWithFilters(allocator: Allocator, samples: []const f32, filters: []const f32, n_mels: u32, n_freq: u32) !MelSpectrogram {
    // Build Hann window (periodic, matching whisper.cpp)
    var hann: [N_FFT]f32 = undefined;
    for (0..N_FFT) |i| {
        const n_f: f32 = @floatFromInt(i);
        const N_f: f32 = @floatFromInt(N_FFT);
        hann[i] = 0.5 * (1.0 - @cos(2.0 * std.math.pi * n_f / N_f));
    }

    // Allocate output: [n_mels × N_FRAMES]
    const mel_data = try allocator.alloc(f32, @as(usize, n_mels) * N_FRAMES);
    @memset(mel_data, 0.0);

    // STFT: for each frame, window → zero-pad to 512 → FFT → power spectrum → mel filter
    var fft_re: [FFT_SIZE]f32 = undefined;
    var fft_im: [FFT_SIZE]f32 = undefined;

    for (0..N_FRAMES) |frame| {
        @memset(&fft_re, 0.0);
        @memset(&fft_im, 0.0);

        // Fill windowed samples (centered around hop position)
        const center = frame * HOP_LENGTH;
        for (0..N_FFT) |i| {
            // Sample index: center - N_FFT/2 + i
            const sample_idx_signed: i64 = @as(i64, @intCast(center)) - @as(i64, N_FFT / 2) + @as(i64, @intCast(i));
            if (sample_idx_signed >= 0 and sample_idx_signed < @as(i64, @intCast(samples.len))) {
                const sample_idx: usize = @intCast(sample_idx_signed);
                fft_re[i] = samples[sample_idx] * hann[i];
            }
        }

        fft512(&fft_re, &fft_im);

        // Apply mel filterbank: mel[m][frame] = sum_k(filter[m][k] * power[k])
        // Only use first n_freq bins (201 = N_FFT/2+1, not 257 = FFT_SIZE/2+1)
        for (0..n_mels) |m| {
            var sum: f32 = 0.0;
            for (0..n_freq) |k| {
                const power = fft_re[k] * fft_re[k] + fft_im[k] * fft_im[k];
                sum += filters[m * n_freq + k] * power;
            }
            mel_data[m * N_FRAMES + frame] = sum;
        }
    }

    // Log-mel: log10(max(x, 1e-10))
    var max_val: f32 = -std.math.inf(f32);
    for (mel_data) |*v| {
        v.* = std.math.log10(@max(v.*, 1e-10));
        if (v.* > max_val) max_val = v.*;
    }

    // Clamp to max - 8, then normalize to [-1, 1] as (x + 4) / 4
    for (mel_data) |*v| {
        v.* = @max(v.*, max_val - 8.0);
        v.* = (v.* + 4.0) / 4.0;
    }

    return MelSpectrogram{
        .data = mel_data,
        .n_mels = n_mels,
        .n_frames = N_FRAMES,
    };
}

pub fn melSpectrogram(allocator: Allocator, samples: []const f32) !MelSpectrogram {
    // Build our own mel filterbank
    var fb = try MelFilterbank.init(allocator);
    defer fb.deinit(allocator);
    return melSpectrogramWithFilters(allocator, samples, fb.filters, N_MELS, N_FREQ);
}

// ── Tests ──

test "hzToMel roundtrip" {
    const hz: f32 = 1000.0;
    const mel = hzToMel(hz);
    const back = melToHz(mel);
    try std.testing.expectApproxEqAbs(hz, back, 0.1);
}

test "FFT basic" {
    // DC signal: all ones
    var re: [FFT_SIZE]f32 = undefined;
    var im: [FFT_SIZE]f32 = undefined;
    @memset(&re, 1.0);
    @memset(&im, 0.0);

    fft512(&re, &im);

    // DC bin should be FFT_SIZE, all others ~0
    try std.testing.expectApproxEqAbs(@as(f32, FFT_SIZE), re[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), re[1], 0.01);
}
