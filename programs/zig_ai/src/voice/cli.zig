// Voice Agent CLI — Command-line interface for xAI Grok Voice Agent
// One-shot and interactive REPL modes with WAV audio output

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const grok_voice = @import("grok_voice.zig");

const Voice = types.Voice;
const AudioEncoding = types.AudioEncoding;
const SessionConfig = types.SessionConfig;

/// Run voice agent CLI from command-line arguments
/// Returns true if a voice command was handled
pub fn run(allocator: Allocator, args: []const []const u8) !bool {
    if (args.len < 2) return false;
    if (!std.mem.eql(u8, args[1], "voice")) return false;

    // Parse arguments
    var voice: Voice = .ara;
    var instructions: ?[]const u8 = null;
    var encoding: AudioEncoding = .pcm16;
    var sample_rate: u32 = 24000;
    var output_path: []const u8 = "voice_response.wav";
    var no_audio = false;
    var interactive = false;
    var prompt: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--voice")) {
            i += 1;
            if (i < args.len) {
                voice = Voice.fromString(args[i]) orelse {
                    std.debug.print("Error: Unknown voice '{s}'\n", .{args[i]});
                    std.debug.print("Available voices: ara, rex, sal, eve, leo\n", .{});
                    return true;
                };
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--instructions")) {
            i += 1;
            if (i < args.len) {
                instructions = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i < args.len) {
                encoding = AudioEncoding.fromString(args[i]) orelse {
                    std.debug.print("Error: Unknown audio format '{s}'\n", .{args[i]});
                    std.debug.print("Available formats: pcm16, pcmu, pcma\n", .{});
                    return true;
                };
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--sample-rate")) {
            i += 1;
            if (i < args.len) {
                sample_rate = std.fmt.parseInt(u32, args[i], 10) catch {
                    std.debug.print("Error: Invalid sample rate '{s}'\n", .{args[i]});
                    return true;
                };
                if (sample_rate < 8000 or sample_rate > 48000) {
                    std.debug.print("Error: Sample rate must be between 8000 and 48000\n", .{});
                    return true;
                }
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--no-audio")) {
            no_audio = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            prompt = arg;
        }
    }

    // Check API key
    const api_key_c = std.c.getenv("XAI_API_KEY") orelse {
        std.debug.print("Error: XAI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export XAI_API_KEY=your-api-key\n", .{});
        return true;
    };
    const api_key = std.mem.span(api_key_c);

    // Build config
    const config = SessionConfig{
        .voice = voice,
        .instructions = instructions,
        .output_format = .{
            .encoding = encoding,
            .sample_rate = sample_rate,
            .channels = 1,
        },
    };

    if (interactive) {
        try runInteractive(allocator, api_key, config, encoding, sample_rate, no_audio);
    } else {
        if (prompt == null) {
            std.debug.print("Error: No prompt provided\n\nUsage: zig-ai voice \"your message\" [options]\n", .{});
            std.debug.print("Run 'zig-ai voice --help' for full options.\n", .{});
            return true;
        }
        try runOneShot(allocator, api_key, config, prompt.?, output_path, encoding, sample_rate, no_audio);
    }

    return true;
}

/// One-shot mode: connect, send, print, save, disconnect
fn runOneShot(
    allocator: Allocator,
    api_key: []const u8,
    config: SessionConfig,
    prompt: []const u8,
    output_path: []const u8,
    encoding: AudioEncoding,
    sample_rate: u32,
    no_audio: bool,
) !void {
    std.debug.print("\x1b[36mConnecting to Grok Voice ({s})...\x1b[0m\n", .{config.voice.toString()});

    var session = try grok_voice.GrokVoiceSession.init(allocator);
    defer session.deinit();

    session.connect(api_key, config) catch |err| {
        std.debug.print("\x1b[31mConnection failed: {any}\x1b[0m\n", .{err});
        return;
    };

    std.debug.print("\x1b[36mSending: \x1b[0m{s}\n\n", .{prompt});

    var response = session.sendTextAndWait(prompt) catch |err| {
        std.debug.print("\x1b[31mRequest failed: {any}\x1b[0m\n", .{err});
        return;
    };
    defer response.deinit();

    // Print transcript
    if (response.transcript.len > 0) {
        std.debug.print("\x1b[32mGrok:\x1b[0m {s}\n", .{response.transcript});
    }

    // Save audio
    if (!no_audio and response.audio_data.len > 0) {
        const wav = grok_voice.writeWav(
            allocator,
            response.audio_data,
            sample_rate,
            encoding.bitsPerSample(),
            1,
        ) catch |err| {
            std.debug.print("\x1b[31mFailed to create WAV: {any}\x1b[0m\n", .{err});
            return;
        };
        defer allocator.free(wav);

        writeFile(output_path, wav);
        std.debug.print("\n\x1b[32mSaved:\x1b[0m {s} ({d} bytes)\n", .{ output_path, wav.len });
    }

    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});
}

/// Interactive REPL mode
fn runInteractive(
    allocator: Allocator,
    api_key: []const u8,
    config: SessionConfig,
    encoding: AudioEncoding,
    sample_rate: u32,
    no_audio: bool,
) !void {
    std.debug.print("\x1b[36mConnecting to Grok Voice ({s})...\x1b[0m\n", .{config.voice.toString()});

    var session = try grok_voice.GrokVoiceSession.init(allocator);
    defer session.deinit();

    session.connect(api_key, config) catch |err| {
        std.debug.print("\x1b[31mConnection failed: {any}\x1b[0m\n", .{err});
        return;
    };

    std.debug.print("\x1b[32mConnected!\x1b[0m Type your message or Ctrl+D to exit.\n\n", .{});

    var turn: u32 = 0;
    var line_buf: [4096]u8 = undefined;

    while (true) {
        std.debug.print("\x1b[36mYou>\x1b[0m ", .{});

        // Read line from stdin (fd 0) using C read, byte-by-byte
        var line_len: usize = 0;
        var got_eof = false;
        while (line_len < line_buf.len - 1) {
            const read_count = std.c.read(0, line_buf[line_len..].ptr, 1);
            if (read_count <= 0) {
                got_eof = true;
                break;
            }
            if (line_buf[line_len] == '\n') break;
            line_len += 1;
        }
        if (got_eof and line_len == 0) break; // Ctrl+D
        const trimmed = std.mem.trim(u8, line_buf[0..line_len], &[_]u8{ '\n', '\r', ' ' });
        if (trimmed.len == 0) continue;

        turn += 1;

        var response = session.sendTextAndWait(trimmed) catch |err| {
            std.debug.print("\x1b[31mError: {any}\x1b[0m\n\n", .{err});
            continue;
        };
        defer response.deinit();

        // Print transcript
        if (response.transcript.len > 0) {
            std.debug.print("\x1b[32mGrok>\x1b[0m {s}\n", .{response.transcript});
        }

        // Save audio per turn
        if (!no_audio and response.audio_data.len > 0) {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "voice_turn_{d}.wav", .{turn}) catch "voice_turn.wav";

            const wav = grok_voice.writeWav(
                allocator,
                response.audio_data,
                sample_rate,
                encoding.bitsPerSample(),
                1,
            ) catch continue;
            defer allocator.free(wav);

            writeFile(path, wav);
            std.debug.print("\x1b[90m  [{s}, {d}ms]\x1b[0m\n", .{ path, response.processing_time_ms });
        } else {
            std.debug.print("\x1b[90m  [{d}ms]\x1b[0m\n", .{response.processing_time_ms});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("\n\x1b[90mDisconnected after {d} turn(s).\x1b[0m\n", .{turn});
}

/// Write bytes to a file using C API (cross-platform, no std.fs)
fn writeFile(path: []const u8, data: []const u8) void {
    var path_buf: [1024]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_buf), "wb") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
}

fn printHelp() void {
    std.debug.print(
        \\
        \\Usage: zig-ai voice "message" [options]
        \\       zig-ai voice --interactive [options]
        \\
        \\Talk to Grok via the xAI Realtime Voice API. Send text, receive
        \\audio + text responses. Requires XAI_API_KEY.
        \\
        \\Modes:
        \\  One-shot (default)      Send a message, get response, exit
        \\  Interactive (-i)        REPL conversation loop (Ctrl+D to exit)
        \\
        \\Options:
        \\  -v, --voice <VOICE>     Voice: ara (default), rex, sal, eve, leo
        \\  -s, --instructions <S>  System prompt / persona instructions
        \\  -f, --format <FMT>      Audio format: pcm16 (default), pcmu, pcma
        \\  -r, --sample-rate <N>   Sample rate: 8000-48000 (default: 24000)
        \\  -o, --output <PATH>     Output WAV path (default: voice_response.wav)
        \\      --no-audio          Transcript only, skip audio output
        \\  -i, --interactive       Interactive REPL conversation mode
        \\  -h, --help              Show this help
        \\
        \\Voices:
        \\  ara     Warm and conversational (default)
        \\  rex     Energetic and bold
        \\  sal     Calm and measured
        \\  eve     Friendly and expressive
        \\  leo     Deep and authoritative
        \\
        \\Examples:
        \\  zig-ai voice "Hello, how are you?"
        \\  zig-ai voice "Count to five" --no-audio
        \\  zig-ai voice "Tell me a joke" -v rex -o joke.wav
        \\  zig-ai voice --interactive -v eve
        \\  zig-ai voice "Explain quantum computing" -s "Be concise"
        \\
        \\
    , .{});
}
