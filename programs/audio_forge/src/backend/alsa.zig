//! ALSA Audio Backend
//!
//! Direct interface to ALSA (Advanced Linux Sound Architecture) via libasound.
//! Provides low-latency audio output with configurable buffer sizes.

const std = @import("std");
const posix = std.posix;

/// ALSA C API bindings
const c = @cImport({
    @cInclude("alsa/asoundlib.h");
});

/// ALSA error to Zig error
fn checkAlsa(result: c_int) !void {
    if (result < 0) {
        return error.AlsaError;
    }
}

/// Get ALSA error string
pub fn strerror(err: c_int) [*:0]const u8 {
    return c.snd_strerror(err);
}

/// Audio sample format
pub const SampleFormat = enum {
    s16_le, // 16-bit signed little-endian
    s24_le, // 24-bit signed little-endian (in 32-bit container)
    s32_le, // 32-bit signed little-endian
    f32_le, // 32-bit float little-endian

    fn toAlsa(self: SampleFormat) c.snd_pcm_format_t {
        return switch (self) {
            .s16_le => c.SND_PCM_FORMAT_S16_LE,
            .s24_le => c.SND_PCM_FORMAT_S24_LE,
            .s32_le => c.SND_PCM_FORMAT_S32_LE,
            .f32_le => c.SND_PCM_FORMAT_FLOAT_LE,
        };
    }

    pub fn bytesPerSample(self: SampleFormat) usize {
        return switch (self) {
            .s16_le => 2,
            .s24_le => 4, // 24-bit in 32-bit container
            .s32_le => 4,
            .f32_le => 4,
        };
    }
};

/// ALSA backend configuration
pub const Config = struct {
    device: []const u8 = "default",
    sample_rate: u32 = 48000,
    channels: u32 = 2,
    period_frames: u32 = 256, // ~5.3ms at 48kHz
    periods: u32 = 2, // Double buffering
    format: SampleFormat = .f32_le,
};

/// Audio callback function type
pub const AudioCallback = *const fn (
    buffer: []f32,
    channels: u32,
    user_data: ?*anyopaque,
) void;

/// ALSA audio backend
pub const AlsaBackend = struct {
    // ALSA handles
    handle: ?*c.snd_pcm_t,

    // Configuration
    config: Config,

    // Callback
    callback: ?AudioCallback,
    user_data: ?*anyopaque,

    // Playback thread
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // Intermediate buffer for format conversion
    convert_buffer: []u8,
    float_buffer: []f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize ALSA backend
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        var self = Self{
            .handle = null,
            .config = config,
            .callback = null,
            .user_data = null,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .convert_buffer = &.{},
            .float_buffer = &.{},
            .allocator = allocator,
        };

        try self.openDevice();

        // Allocate buffers
        const buffer_samples = config.period_frames * config.channels;
        self.float_buffer = try allocator.alloc(f32, buffer_samples);
        @memset(self.float_buffer, 0);

        const bytes_per_sample = config.format.bytesPerSample();
        self.convert_buffer = try allocator.alloc(u8, buffer_samples * bytes_per_sample);

        return self;
    }

    /// Open and configure ALSA device
    fn openDevice(self: *Self) !void {
        var handle: ?*c.snd_pcm_t = null;

        // Create null-terminated device name
        var device_buf: [256]u8 = undefined;
        const device_z = std.fmt.bufPrintZ(&device_buf, "{s}", .{self.config.device}) catch {
            return error.DeviceNameTooLong;
        };

        // Open PCM device for playback
        const open_result = c.snd_pcm_open(
            &handle,
            device_z.ptr,
            c.SND_PCM_STREAM_PLAYBACK,
            0, // Blocking mode
        );
        if (open_result < 0) {
            std.log.err("ALSA: Failed to open device '{s}': {s}", .{
                self.config.device,
                strerror(open_result),
            });
            return error.DeviceOpenFailed;
        }
        errdefer _ = c.snd_pcm_close(handle);

        self.handle = handle;

        // Configure hardware parameters
        try self.configureHardware();
    }

    /// Configure ALSA hardware parameters
    fn configureHardware(self: *Self) !void {
        const handle = self.handle orelse return error.NotInitialized;

        var hw_params: ?*c.snd_pcm_hw_params_t = null;

        // Allocate hw_params
        try checkAlsa(c.snd_pcm_hw_params_malloc(&hw_params));
        defer c.snd_pcm_hw_params_free(hw_params);

        // Fill with default values
        try checkAlsa(c.snd_pcm_hw_params_any(handle, hw_params));

        // Set access type (interleaved)
        try checkAlsa(c.snd_pcm_hw_params_set_access(
            handle,
            hw_params,
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
        ));

        // Set sample format
        try checkAlsa(c.snd_pcm_hw_params_set_format(
            handle,
            hw_params,
            self.config.format.toAlsa(),
        ));

        // Set channel count
        try checkAlsa(c.snd_pcm_hw_params_set_channels(
            handle,
            hw_params,
            self.config.channels,
        ));

        // Set sample rate
        var actual_rate: c_uint = self.config.sample_rate;
        try checkAlsa(c.snd_pcm_hw_params_set_rate_near(
            handle,
            hw_params,
            &actual_rate,
            null,
        ));

        if (actual_rate != self.config.sample_rate) {
            std.log.warn("ALSA: Requested rate {d}, got {d}", .{
                self.config.sample_rate,
                actual_rate,
            });
        }

        // Set period size
        var actual_period: c.snd_pcm_uframes_t = self.config.period_frames;
        try checkAlsa(c.snd_pcm_hw_params_set_period_size_near(
            handle,
            hw_params,
            &actual_period,
            null,
        ));

        // Set number of periods (buffer size = period_size * periods)
        try checkAlsa(c.snd_pcm_hw_params_set_periods(
            handle,
            hw_params,
            self.config.periods,
            0,
        ));

        // Apply hardware parameters
        try checkAlsa(c.snd_pcm_hw_params(handle, hw_params));

        // Log actual configuration
        std.log.info("ALSA: Configured - rate={d}, period={d}, periods={d}", .{
            actual_rate,
            actual_period,
            self.config.periods,
        });
    }

    /// Set the audio callback
    pub fn setCallback(self: *Self, callback: AudioCallback, user_data: ?*anyopaque) void {
        self.callback = callback;
        self.user_data = user_data;
    }

    /// Start audio playback
    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        if (self.callback == null) {
            return error.NoCallback;
        }

        // Prepare the PCM device
        const handle = self.handle orelse return error.NotInitialized;
        try checkAlsa(c.snd_pcm_prepare(handle));

        self.running.store(true, .release);

        // Start playback thread
        self.thread = try std.Thread.spawn(.{}, playbackThread, .{self});
    }

    /// Stop audio playback
    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        // Drain remaining audio
        if (self.handle) |handle| {
            _ = c.snd_pcm_drain(handle);
        }
    }

    /// Playback thread function
    fn playbackThread(self: *Self) void {
        const handle = self.handle orelse return;
        const callback = self.callback orelse return;

        // Try to set real-time priority (may fail without privileges)
        setRealtimePriority() catch {};

        while (self.running.load(.acquire)) {
            // Fill buffer via callback
            @memset(self.float_buffer, 0);
            callback(self.float_buffer, self.config.channels, self.user_data);

            // Convert float to output format
            self.convertToOutput();

            // Write to ALSA
            var frames_written: c.snd_pcm_sframes_t = 0;
            var frames_remaining: c.snd_pcm_uframes_t = self.config.period_frames;
            var buffer_offset: usize = 0;

            while (frames_remaining > 0 and self.running.load(.acquire)) {
                frames_written = c.snd_pcm_writei(
                    handle,
                    self.convert_buffer.ptr + buffer_offset,
                    frames_remaining,
                );

                if (frames_written < 0) {
                    // Handle xrun (buffer underrun)
                    if (frames_written == -@as(c_long, @intFromEnum(std.posix.E.PIPE))) {
                        std.log.warn("ALSA: Buffer underrun, recovering...", .{});
                        _ = c.snd_pcm_prepare(handle);
                        continue;
                    } else if (frames_written == -@as(c_long, @intFromEnum(std.posix.E.AGAIN))) {
                        // Would block, try again
                        continue;
                    } else {
                        std.log.err("ALSA: Write error: {s}", .{strerror(@intCast(frames_written))});
                        break;
                    }
                }

                const written: usize = @intCast(frames_written);
                frames_remaining -= written;
                buffer_offset += written * self.config.channels * self.config.format.bytesPerSample();
            }
        }
    }

    /// Convert float buffer to output format
    fn convertToOutput(self: *Self) void {
        const samples = self.float_buffer.len;

        switch (self.config.format) {
            .f32_le => {
                // Direct copy for float format
                const src_bytes = std.mem.sliceAsBytes(self.float_buffer);
                @memcpy(self.convert_buffer[0..src_bytes.len], src_bytes);
            },
            .s16_le => {
                for (0..samples) |i| {
                    const clamped = std.math.clamp(self.float_buffer[i], -1.0, 1.0);
                    const sample_i16: i16 = @intFromFloat(clamped * 32767.0);
                    const offset = i * 2;
                    std.mem.writeInt(i16, self.convert_buffer[offset..][0..2], sample_i16, .little);
                }
            },
            .s24_le => {
                for (0..samples) |i| {
                    const clamped = std.math.clamp(self.float_buffer[i], -1.0, 1.0);
                    const sample_i32: i32 = @intFromFloat(clamped * 8388607.0);
                    const offset = i * 4;
                    std.mem.writeInt(i32, self.convert_buffer[offset..][0..4], sample_i32, .little);
                }
            },
            .s32_le => {
                for (0..samples) |i| {
                    const clamped = std.math.clamp(self.float_buffer[i], -1.0, 1.0);
                    const sample_i32: i32 = @intFromFloat(clamped * 2147483647.0);
                    const offset = i * 4;
                    std.mem.writeInt(i32, self.convert_buffer[offset..][0..4], sample_i32, .little);
                }
            },
        }
    }

    /// Deinitialize backend
    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.handle) |handle| {
            _ = c.snd_pcm_close(handle);
            self.handle = null;
        }

        if (self.float_buffer.len > 0) {
            self.allocator.free(self.float_buffer);
            self.float_buffer = &.{};
        }

        if (self.convert_buffer.len > 0) {
            self.allocator.free(self.convert_buffer);
            self.convert_buffer = &.{};
        }
    }

    /// Get the actual sample rate (may differ from requested)
    pub fn getSampleRate(self: *const Self) u32 {
        return self.config.sample_rate;
    }

    /// Get the number of channels
    pub fn getChannels(self: *const Self) u32 {
        return self.config.channels;
    }

    /// Get the buffer size in frames
    pub fn getBufferSize(self: *const Self) u32 {
        return self.config.period_frames * self.config.periods;
    }

    /// Get latency in milliseconds
    pub fn getLatencyMs(self: *const Self) f32 {
        const buffer_frames = self.config.period_frames * self.config.periods;
        return @as(f32, @floatFromInt(buffer_frames)) / @as(f32, @floatFromInt(self.config.sample_rate)) * 1000.0;
    }
};

/// Try to set real-time priority for the audio thread
fn setRealtimePriority() !void {
    const param = std.os.linux.sched_param{ .priority = 50 };
    const result = std.os.linux.sched_setscheduler(0, .{ .mode = .FIFO }, &param);

    if (result != 0) {
        return error.SetSchedulerFailed;
    }
}

/// List available ALSA devices
/// Note: This is a simplified stub for Phase 1. Full device enumeration
/// requires complex ALSA C interop that we'll implement in Phase 4.
pub fn listDevices(allocator: std.mem.Allocator) ![][]const u8 {
    var devices = std.ArrayListUnmanaged([]const u8).empty;

    // Return common default device names
    const defaults = [_][]const u8{
        "default",
        "hw:0,0",
        "plughw:0,0",
    };

    for (defaults) |name| {
        const duped = try allocator.dupe(u8, name);
        try devices.append(allocator, duped);
    }

    return devices.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "sample format bytes per sample" {
    try std.testing.expectEqual(@as(usize, 2), SampleFormat.s16_le.bytesPerSample());
    try std.testing.expectEqual(@as(usize, 4), SampleFormat.s24_le.bytesPerSample());
    try std.testing.expectEqual(@as(usize, 4), SampleFormat.s32_le.bytesPerSample());
    try std.testing.expectEqual(@as(usize, 4), SampleFormat.f32_le.bytesPerSample());
}

test "config defaults" {
    const config = Config{};
    try std.testing.expectEqual(@as(u32, 48000), config.sample_rate);
    try std.testing.expectEqual(@as(u32, 2), config.channels);
    try std.testing.expectEqual(@as(u32, 256), config.period_frames);
}
