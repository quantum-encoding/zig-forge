//! Audio Engine
//!
//! Main audio processing orchestrator. Manages the decoder thread,
//! ring buffer, DSP processing, and audio output backend.
//!
//! Thread Model:
//! - Main Thread: File I/O, decoding, control
//! - Audio Thread: Ring buffer read, DSP processing, backend output

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const ring_buffer = @import("ring_buffer.zig");
const codec = @import("codec/mod.zig");
const backend = @import("backend/mod.zig");
const dsp = @import("dsp/mod.zig");

const AudioRingBuffer = ring_buffer.AudioRingBuffer;
const WavDecoder = codec.WavDecoder;
const AlsaBackend = backend.AlsaBackend;
const DspGraph = dsp.DspGraph;
const ParametricEq = dsp.ParametricEq;
const ProcessorNode = dsp.ProcessorNode;

/// Engine state
pub const State = enum(u8) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

/// Engine configuration
pub const Config = struct {
    /// Audio device name
    device: []const u8 = "default",

    /// Sample rate (Hz)
    sample_rate: u32 = 48000,

    /// Number of channels
    channels: u32 = 2,

    /// Period size in frames (~latency control)
    period_frames: u32 = 256,

    /// Number of periods
    periods: u32 = 2,

    /// Ring buffer size in frames
    ring_buffer_frames: usize = 8192,
};

/// Audio Engine
pub const AudioEngine = struct {
    allocator: Allocator,
    config: Config,

    // Core components
    ring_buffer: AudioRingBuffer,
    backend: AlsaBackend,

    // DSP processing
    dsp_graph: DspGraph,
    eq: ParametricEq,
    eq_node: ProcessorNode,
    dsp_enabled: bool,

    // Decoder state
    decoder: ?WavDecoder,
    decoder_thread: ?std.Thread,

    // Control
    state: std.atomic.Value(State),
    stop_decoder: std.atomic.Value(bool),

    // Playback info
    file_sample_rate: u32,
    file_channels: u16,
    total_frames: u64,
    frames_played: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize the audio engine
    pub fn init(allocator: Allocator, config: Config) !Self {
        // Create ring buffer
        var rb = try AudioRingBuffer.init(
            allocator,
            config.ring_buffer_frames,
            @intCast(config.channels),
        );
        errdefer rb.deinit(allocator);

        // Create ALSA backend
        var alsa = try AlsaBackend.init(allocator, .{
            .device = config.device,
            .sample_rate = config.sample_rate,
            .channels = config.channels,
            .period_frames = config.period_frames,
            .periods = config.periods,
            .format = .f32_le,
        });
        errdefer alsa.deinit();

        // Create DSP graph and EQ
        const sample_rate_f: f32 = @floatFromInt(config.sample_rate);
        const dsp_graph = DspGraph.init(sample_rate_f, @intCast(config.channels));
        const eq = ParametricEq.init(sample_rate_f);

        var self = Self{
            .allocator = allocator,
            .config = config,
            .ring_buffer = rb,
            .backend = alsa,
            .dsp_graph = dsp_graph,
            .eq = eq,
            .eq_node = undefined, // Will be initialized below
            .dsp_enabled = false, // Disabled by default
            .decoder = null,
            .decoder_thread = null,
            .state = std.atomic.Value(State).init(.stopped),
            .stop_decoder = std.atomic.Value(bool).init(false),
            .file_sample_rate = 0,
            .file_channels = 0,
            .total_frames = 0,
            .frames_played = std.atomic.Value(u64).init(0),
        };

        // Initialize EQ processor node (must be done after self is created)
        self.eq_node = ProcessorNode.init(dsp.parametric_eq.makeProcessor(&self.eq));
        self.dsp_graph.addProcessor(&self.eq_node);

        // Set audio callback
        self.backend.setCallback(audioCallback, &self);

        return self;
    }

    /// Load an audio file
    pub fn loadFile(self: *Self, path: []const u8) !void {
        // Stop any current playback
        self.stop();

        // Open decoder
        self.decoder = try WavDecoder.open(path);

        self.file_sample_rate = self.decoder.?.getSampleRate();
        self.file_channels = self.decoder.?.getChannels();
        self.total_frames = self.decoder.?.getTotalFrames();

        // Validate compatibility
        if (self.file_channels != self.config.channels) {
            std.log.warn("Channel mismatch: file={d}, engine={d}", .{
                self.file_channels,
                self.config.channels,
            });
        }

        if (self.file_sample_rate != self.config.sample_rate) {
            std.log.warn("Sample rate mismatch: file={d}, engine={d} (resampling not implemented)", .{
                self.file_sample_rate,
                self.config.sample_rate,
            });
        }

        // Reset ring buffer
        self.ring_buffer.reset();
        self.frames_played.store(0, .release);

        std.log.info("Loaded: {s} - {d}Hz, {d}ch, {d} frames ({d:.1}s)", .{
            path,
            self.file_sample_rate,
            self.file_channels,
            self.total_frames,
            self.decoder.?.durationSeconds(),
        });
    }

    /// Start playback
    pub fn play(self: *Self) !void {
        if (self.decoder == null) {
            return error.NoFileLoaded;
        }

        const current_state = self.state.load(.acquire);
        if (current_state == .playing) {
            return; // Already playing
        }

        // Start decoder thread
        self.stop_decoder.store(false, .release);
        self.decoder_thread = try std.Thread.spawn(.{}, decoderThread, .{self});

        // Start audio backend
        try self.backend.start();

        self.state.store(.playing, .release);
        std.log.info("Playback started", .{});
    }

    /// Pause playback
    pub fn pause(self: *Self) void {
        if (self.state.load(.acquire) != .playing) {
            return;
        }

        self.backend.stop();
        self.state.store(.paused, .release);
        std.log.info("Playback paused", .{});
    }

    /// Resume playback
    pub fn unpause(self: *Self) !void {
        if (self.state.load(.acquire) != .paused) {
            return;
        }

        try self.backend.start();
        self.state.store(.playing, .release);
        std.log.info("Playback resumed", .{});
    }

    /// Stop playback
    pub fn stop(self: *Self) void {
        // Signal decoder to stop
        self.stop_decoder.store(true, .release);

        // Stop backend
        self.backend.stop();

        // Wait for decoder thread
        if (self.decoder_thread) |thread| {
            thread.join();
            self.decoder_thread = null;
        }

        // Close decoder
        if (self.decoder) |*dec| {
            dec.close();
            self.decoder = null;
        }

        self.state.store(.stopped, .release);
        std.log.info("Playback stopped", .{});
    }

    /// Seek to position (in seconds)
    pub fn seek(self: *Self, seconds: f64) !void {
        if (self.decoder == null) {
            return error.NoFileLoaded;
        }

        const frame = @as(u64, @intFromFloat(seconds * @as(f64, @floatFromInt(self.file_sample_rate))));
        try self.decoder.?.seek(frame);

        // Clear ring buffer
        self.ring_buffer.reset();
        self.frames_played.store(frame, .release);
    }

    /// Get current playback position in seconds
    pub fn getPosition(self: *Self) f64 {
        const frames = self.frames_played.load(.acquire);
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.file_sample_rate));
    }

    /// Get total duration in seconds
    pub fn getDuration(self: *Self) f64 {
        if (self.decoder) |*dec| {
            return dec.durationSeconds();
        }
        return 0;
    }

    /// Get current state
    pub fn getState(self: *Self) State {
        return self.state.load(.acquire);
    }

    /// Check if playback has finished
    pub fn isFinished(self: *Self) bool {
        if (self.decoder) |dec| {
            return dec.isEof() and self.ring_buffer.isEmpty();
        }
        return true;
    }

    /// Audio callback - called from audio thread
    fn audioCallback(buffer: []f32, channels: u32, user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        _ = channels;

        // Read from ring buffer
        const frames_read = self.ring_buffer.read(buffer);

        // Zero any remaining buffer if we didn't get enough data
        if (frames_read < buffer.len / self.config.channels) {
            const samples_read = frames_read * self.config.channels;
            @memset(buffer[samples_read..], 0);
        }

        // Apply DSP processing if enabled
        if (self.dsp_enabled) {
            self.dsp_graph.process(buffer);
        }

        // Update position
        _ = self.frames_played.fetchAdd(frames_read, .acq_rel);
    }

    /// Decoder thread - reads from file and writes to ring buffer
    fn decoderThread(self: *Self) void {
        var dec = &(self.decoder orelse return);

        // Decode buffer (larger than ring buffer period for efficiency)
        var decode_buf: [4096]f32 = undefined;
        const channels: usize = self.config.channels;

        while (!self.stop_decoder.load(.acquire)) {
            // Check if decoder has reached EOF
            if (dec.isEof()) {
                // Wait until ring buffer empties or stop requested
                while (!self.ring_buffer.isEmpty() and !self.stop_decoder.load(.acquire)) {
                    var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 }; // 1ms
                    _ = linux.nanosleep(&ts, null);
                }
                break;
            }

            // Check ring buffer space
            const available = self.ring_buffer.availableWrite();
            if (available < decode_buf.len / channels) {
                // Buffer full, wait a bit
                var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 }; // 1ms
                _ = linux.nanosleep(&ts, null);
                continue;
            }

            // Decode frames
            const frames_decoded = dec.decode(&decode_buf) catch |err| {
                std.log.err("Decode error: {}", .{err});
                break;
            };

            if (frames_decoded == 0) {
                continue;
            }

            // Write to ring buffer
            const samples_decoded = frames_decoded * channels;
            const frames_written = self.ring_buffer.write(decode_buf[0..samples_decoded]);

            if (frames_written < frames_decoded) {
                std.log.warn("Ring buffer overflow: wrote {d}/{d} frames", .{
                    frames_written,
                    frames_decoded,
                });
            }
        }

        std.log.info("Decoder thread exiting", .{});
    }

    /// Deinitialize the engine
    pub fn deinit(self: *Self) void {
        self.stop();
        self.backend.deinit();
        self.ring_buffer.deinit(self.allocator);
    }

    /// Get latency in milliseconds
    pub fn getLatencyMs(self: *Self) f32 {
        return self.backend.getLatencyMs();
    }

    // =========================================================================
    // DSP Control Methods
    // =========================================================================

    /// Enable/disable DSP processing
    pub fn setDspEnabled(self: *Self, enabled: bool) void {
        self.dsp_enabled = enabled;
        std.log.info("DSP processing {s}", .{if (enabled) "enabled" else "disabled"});
    }

    /// Check if DSP is enabled
    pub fn isDspEnabled(self: *const Self) bool {
        return self.dsp_enabled;
    }

    /// Get the equalizer for configuration
    pub fn getEq(self: *Self) *ParametricEq {
        return &self.eq;
    }

    /// Get the DSP graph for adding custom processors
    pub fn getDspGraph(self: *Self) *DspGraph {
        return &self.dsp_graph;
    }

    /// Apply an EQ preset
    pub fn applyEqPreset(self: *Self, preset: dsp.EqPreset) void {
        preset.apply(&self.eq);
        std.log.info("Applied EQ preset", .{});
    }

    /// Reset all DSP processors
    pub fn resetDsp(self: *Self) void {
        self.dsp_graph.reset();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "engine config defaults" {
    const config = Config{};
    try std.testing.expectEqual(@as(u32, 48000), config.sample_rate);
    try std.testing.expectEqual(@as(u32, 2), config.channels);
    try std.testing.expectEqual(@as(usize, 8192), config.ring_buffer_frames);
}

test "state enum" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(State).@"enum".fields.len);
}
