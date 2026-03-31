//! Audio Forge CLI
//!
//! Command-line interface for audio playback and processing.
//!
//! Usage:
//!   audio-forge play <file.wav>
//!   audio-forge devices
//!   audio-forge info <file.wav>

const std = @import("std");
const lib = @import("lib.zig");
const linux = std.os.linux;

const AudioEngine = lib.AudioEngine;
const WavDecoder = lib.WavDecoder;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "play")) {
        if (args.len < 3) {
            std.debug.print("Error: No file specified\n", .{});
            printUsage();
            return;
        }
        try playCommand(allocator, args[2], args[3..]);
    } else if (std.mem.eql(u8, command, "devices")) {
        try devicesCommand(allocator);
    } else if (std.mem.eql(u8, command, "info")) {
        if (args.len < 3) {
            std.debug.print("Error: No file specified\n", .{});
            printUsage();
            return;
        }
        try infoCommand(args[2]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Audio Forge - Real-time audio DSP engine
        \\
        \\Usage:
        \\  audio-forge <command> [options]
        \\
        \\Commands:
        \\  play <file>      Play an audio file
        \\  devices          List available audio devices
        \\  info <file>      Show audio file information
        \\  help             Show this help message
        \\
        \\Play Options:
        \\  --device <name>  Audio device (default: "default")
        \\  --buffer <ms>    Buffer size in milliseconds
        \\  --eq <preset>    Apply EQ preset (flat, bass, treble, vocal,
        \\                   electronic, rock, jazz, classical)
        \\
        \\Examples:
        \\  audio-forge play music.wav
        \\  audio-forge play music.wav --device hw:0
        \\  audio-forge play music.wav --eq bass
        \\  audio-forge info track.wav
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn playCommand(allocator: std.mem.Allocator, file_path: []const u8, extra_args: []const []const u8) !void {
    // Parse extra arguments
    var device: []const u8 = "default";
    var eq_preset: ?lib.EqPreset = null;

    var i: usize = 0;
    while (i < extra_args.len) : (i += 1) {
        if (std.mem.eql(u8, extra_args[i], "--device") and i + 1 < extra_args.len) {
            device = extra_args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, extra_args[i], "--eq") and i + 1 < extra_args.len) {
            const preset_name = extra_args[i + 1];
            eq_preset = parseEqPreset(preset_name);
            if (eq_preset == null) {
                std.debug.print("Unknown EQ preset: {s}\n", .{preset_name});
                std.debug.print("Valid presets: flat, bass, treble, vocal, electronic, rock, jazz, classical\n", .{});
                return;
            }
            i += 1;
        }
    }

    std.debug.print("Audio Forge - Real-time Audio Player\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // Initialize engine
    var engine = AudioEngine.init(allocator, .{
        .device = device,
        .sample_rate = 48000,
        .channels = 2,
        .period_frames = 256,
        .periods = 2,
        .ring_buffer_frames = 8192,
    }) catch |err| {
        std.debug.print("Error initializing audio engine: {}\n", .{err});
        std.debug.print("Make sure ALSA is installed and audio device is available.\n", .{});
        return;
    };
    defer engine.deinit();

    // Apply EQ preset if specified
    if (eq_preset) |preset| {
        engine.applyEqPreset(preset);
        engine.setDspEnabled(true);
        std.debug.print("EQ: {s}\n", .{@tagName(preset)});
    }

    // Load file
    engine.loadFile(file_path) catch |err| {
        std.debug.print("Error loading file '{s}': {}\n", .{ file_path, err });
        return;
    };

    std.debug.print("File: {s}\n", .{file_path});
    std.debug.print("Duration: {d:.1}s\n", .{engine.getDuration()});
    std.debug.print("Latency: {d:.1}ms\n", .{engine.getLatencyMs()});
    std.debug.print("\nPlaying... (Press Ctrl+C to stop)\n\n", .{});

    // Start playback
    engine.play() catch |err| {
        std.debug.print("Error starting playback: {}\n", .{err});
        return;
    };

    // Progress display loop
    const duration = engine.getDuration();
    var last_pos: f64 = -1;

    while (!engine.isFinished()) {
        const pos = engine.getPosition();

        // Update display every 100ms
        if (pos - last_pos >= 0.1 or last_pos < 0) {
            const progress = pos / duration * 100.0;
            const bar_width: usize = 40;
            const filled = @as(usize, @intFromFloat(progress / 100.0 * @as(f64, @floatFromInt(bar_width))));

            // Build progress bar
            var bar: [40]u8 = undefined;
            for (0..bar_width) |j| {
                bar[j] = if (j < filled) '=' else '-';
            }

            std.debug.print("\r[{s}] {d:5.1}s / {d:.1}s ({d:5.1}%)", .{
                bar[0..bar_width],
                pos,
                duration,
                progress,
            });

            last_pos = pos;
        }

        var ts: linux.timespec = .{ .sec = 0, .nsec = 50_000_000 }; // 50ms
        _ = linux.nanosleep(&ts, null);
    }

    std.debug.print("\n\nPlayback complete.\n", .{});
}

fn devicesCommand(allocator: std.mem.Allocator) !void {
    std.debug.print("Available Audio Devices:\n", .{});
    std.debug.print("========================\n\n", .{});

    const devices = lib.backend.listAlsaDevices(allocator) catch |err| {
        std.debug.print("Error listing devices: {}\n", .{err});
        std.debug.print("Make sure ALSA is installed.\n", .{});
        return;
    };
    defer {
        for (devices) |d| allocator.free(d);
        allocator.free(devices);
    }

    if (devices.len == 0) {
        std.debug.print("No audio devices found.\n", .{});
        return;
    }

    for (devices, 0..) |device, idx| {
        std.debug.print("  [{d}] {s}\n", .{ idx, device });
    }
}

fn infoCommand(file_path: []const u8) !void {
    var decoder = WavDecoder.open(file_path) catch |err| {
        std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer decoder.close();

    const duration = decoder.durationSeconds();
    const minutes = @as(u32, @intFromFloat(duration / 60.0));
    const seconds = duration - @as(f64, @floatFromInt(minutes * 60));

    std.debug.print("Audio File Information\n", .{});
    std.debug.print("======================\n\n", .{});
    std.debug.print("File:        {s}\n", .{file_path});
    std.debug.print("Format:      WAV\n", .{});
    std.debug.print("Channels:    {d}\n", .{decoder.getChannels()});
    std.debug.print("Sample Rate: {d} Hz\n", .{decoder.getSampleRate()});
    std.debug.print("Frames:      {d}\n", .{decoder.getTotalFrames()});
    std.debug.print("Duration:    {d}:{d:0>5.2}\n", .{ minutes, seconds });
}

/// Parse EQ preset name to enum
fn parseEqPreset(name: []const u8) ?lib.EqPreset {
    const presets = .{
        .{ "flat", lib.EqPreset.flat },
        .{ "bass", lib.EqPreset.bass_boost },
        .{ "treble", lib.EqPreset.treble_boost },
        .{ "vocal", lib.EqPreset.vocal },
        .{ "electronic", lib.EqPreset.electronic },
        .{ "rock", lib.EqPreset.rock },
        .{ "jazz", lib.EqPreset.jazz },
        .{ "classical", lib.EqPreset.classical },
    };

    inline for (presets) |p| {
        if (std.mem.eql(u8, name, p[0])) {
            return p[1];
        }
    }

    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "main compiles" {
    // Just verify it compiles
    _ = lib;
}

test "parse eq preset" {
    try std.testing.expectEqual(lib.EqPreset.bass_boost, parseEqPreset("bass").?);
    try std.testing.expectEqual(lib.EqPreset.flat, parseEqPreset("flat").?);
    try std.testing.expect(parseEqPreset("invalid") == null);
}
