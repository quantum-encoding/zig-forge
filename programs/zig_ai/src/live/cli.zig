// Gemini Live CLI — Command-line interface for Gemini Live API
// One-shot and interactive REPL modes via WebSocket

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const gemini_live = @import("gemini_live.zig");

const Modality = types.Modality;
const GeminiVoice = types.GeminiVoice;
const LiveConfig = types.LiveConfig;
const Models = types.Models;

/// Run live CLI from command-line arguments
/// Returns true if a live command was handled
pub fn run(allocator: Allocator, args: []const []const u8) !bool {
    if (args.len < 2) return false;
    if (!std.mem.eql(u8, args[1], "live")) return false;

    // Parse arguments
    var modality: Modality = .text;
    var voice: ?GeminiVoice = null;
    var system_instruction: ?[]const u8 = null;
    var model: []const u8 = Models.FLASH_LIVE;
    var temperature: f32 = 1.0;
    var output_path: []const u8 = "live_response.wav";
    var no_audio = false;
    var interactive = false;
    var prompt: ?[]const u8 = null;
    var context_compression = false;
    var output_transcription = false;
    var google_search = false;
    var thinking_budget: ?u32 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--modality") or std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i < args.len) {
                modality = Modality.fromString(args[i]) orelse {
                    std.debug.print("Error: Unknown modality '{s}'\n", .{args[i]});
                    std.debug.print("Available: text, audio\n", .{});
                    return true;
                };
            }
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--voice")) {
            i += 1;
            if (i < args.len) {
                voice = GeminiVoice.fromString(args[i]) orelse {
                    std.debug.print("Error: Unknown voice '{s}'\n", .{args[i]});
                    std.debug.print("Available: kore, charon, fenrir, aoede, puck, leda, orus, zephyr\n", .{});
                    return true;
                };
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i < args.len) {
                system_instruction = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                model = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--temperature")) {
            i += 1;
            if (i < args.len) {
                temperature = std.fmt.parseFloat(f32, args[i]) catch {
                    std.debug.print("Error: Invalid temperature '{s}'\n", .{args[i]});
                    return true;
                };
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
        } else if (std.mem.eql(u8, arg, "--context-compression")) {
            context_compression = true;
        } else if (std.mem.eql(u8, arg, "--transcription")) {
            output_transcription = true;
        } else if (std.mem.eql(u8, arg, "--google-search")) {
            google_search = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i < args.len) {
                thinking_budget = std.fmt.parseInt(u32, args[i], 10) catch {
                    std.debug.print("Error: Invalid thinking budget '{s}'\n", .{args[i]});
                    return true;
                };
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            prompt = arg;
        }
    }

    // Check API key
    const api_key_c = std.c.getenv("GEMINI_API_KEY") orelse std.c.getenv("GOOGLE_GENAI_API_KEY") orelse {
        std.debug.print("Error: GEMINI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export GEMINI_API_KEY=your-api-key\n", .{});
        return true;
    };
    const api_key = std.mem.span(api_key_c);

    // Build config
    const config = LiveConfig{
        .model = model,
        .modality = modality,
        .system_instruction = system_instruction,
        .voice = voice,
        .temperature = temperature,
        .context_compression = context_compression,
        .output_transcription = output_transcription,
        .google_search = google_search,
        .thinking_budget = thinking_budget,
    };

    if (interactive) {
        try runInteractive(allocator, api_key, config, output_path, no_audio);
    } else {
        if (prompt == null) {
            std.debug.print("Error: No prompt provided\n\nUsage: zig-ai live \"your message\" [options]\n", .{});
            std.debug.print("Run 'zig-ai live --help' for full options.\n", .{});
            return true;
        }
        try runOneShot(allocator, api_key, config, prompt.?, output_path, no_audio);
    }

    return true;
}

/// One-shot mode: connect, send, print, save, disconnect
fn runOneShot(
    allocator: Allocator,
    api_key: []const u8,
    config: LiveConfig,
    prompt: []const u8,
    output_path: []const u8,
    no_audio: bool,
) !void {
    const model_display = if (std.mem.indexOf(u8, config.model, "native-audio") != null) "native audio" else "flash";
    std.debug.print("\x1b[36mConnecting to Gemini Live ({s}, {s})...\x1b[0m\n", .{ model_display, config.modality.toApiString() });

    var session = try gemini_live.GeminiLiveSession.init(allocator);
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

    // Print text response
    if (response.text.len > 0) {
        std.debug.print("\x1b[32mGemini:\x1b[0m {s}\n", .{response.text});
    }

    // Print transcription
    if (response.output_transcript.len > 0) {
        std.debug.print("\x1b[90mTranscript: {s}\x1b[0m\n", .{response.output_transcript});
    }

    // Print function calls
    if (response.function_calls.len > 0) {
        for (response.function_calls) |fc| {
            std.debug.print("\x1b[33mTool call:\x1b[0m {s}({s})\n", .{ fc.name, fc.args });
        }
    }

    // Save audio
    if (!no_audio and response.audio_data.len > 0) {
        const wav = gemini_live.writeWav(allocator, response.audio_data) catch |err| {
            std.debug.print("\x1b[31mFailed to create WAV: {any}\x1b[0m\n", .{err});
            return;
        };
        defer allocator.free(wav);

        writeFile(output_path, wav);
        std.debug.print("\n\x1b[32mSaved:\x1b[0m {s} ({d} bytes)\n", .{ output_path, wav.len });
    }

    // Stats
    var stats_buf: [128]u8 = undefined;
    var stats_len: usize = 0;
    if (response.total_tokens > 0) {
        const s = std.fmt.bufPrint(&stats_buf, "{d}ms, {d} tokens", .{ response.processing_time_ms, response.total_tokens }) catch "";
        stats_len = s.len;
    } else {
        const s = std.fmt.bufPrint(&stats_buf, "{d}ms", .{response.processing_time_ms}) catch "";
        stats_len = s.len;
    }
    std.debug.print("\x1b[90m[{s}]\x1b[0m\n", .{stats_buf[0..stats_len]});
}

/// Interactive REPL mode
fn runInteractive(
    allocator: Allocator,
    api_key: []const u8,
    config: LiveConfig,
    output_path: []const u8,
    no_audio: bool,
) !void {
    const model_display = if (std.mem.indexOf(u8, config.model, "native-audio") != null) "native audio" else "flash";
    std.debug.print("\x1b[36mConnecting to Gemini Live ({s}, {s})...\x1b[0m\n", .{ model_display, config.modality.toApiString() });

    var session = try gemini_live.GeminiLiveSession.init(allocator);
    defer session.deinit();

    session.connect(api_key, config) catch |err| {
        std.debug.print("\x1b[31mConnection failed: {any}\x1b[0m\n", .{err});
        return;
    };

    std.debug.print("\x1b[32mConnected!\x1b[0m Type your message or Ctrl+D to exit.\n", .{});
    if (config.context_compression) {
        std.debug.print("\x1b[90mContext compression enabled (unlimited session)\x1b[0m\n", .{});
    }
    std.debug.print("\n", .{});

    var turn: u32 = 0;
    var line_buf: [4096]u8 = undefined;

    while (true) {
        std.debug.print("\x1b[36mYou>\x1b[0m ", .{});

        // Read line from stdin using C read
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
        if (got_eof and line_len == 0) break;
        const trimmed = std.mem.trim(u8, line_buf[0..line_len], &[_]u8{ '\n', '\r', ' ' });
        if (trimmed.len == 0) continue;

        turn += 1;

        var response = session.sendTextAndWait(trimmed) catch |err| {
            std.debug.print("\x1b[31mError: {any}\x1b[0m\n\n", .{err});
            continue;
        };
        defer response.deinit();

        // Print text
        if (response.text.len > 0) {
            std.debug.print("\x1b[32mGemini>\x1b[0m {s}\n", .{response.text});
        }

        // Print transcription
        if (response.output_transcript.len > 0) {
            std.debug.print("\x1b[90mTranscript: {s}\x1b[0m\n", .{response.output_transcript});
        }

        // Function calls
        if (response.function_calls.len > 0) {
            for (response.function_calls) |fc| {
                std.debug.print("\x1b[33mTool call:\x1b[0m {s}({s})\n", .{ fc.name, fc.args });
            }
        }

        // Save audio per turn
        if (!no_audio and response.audio_data.len > 0) {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "live_turn_{d}.wav", .{turn}) catch output_path;

            const wav = gemini_live.writeWav(allocator, response.audio_data) catch continue;
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

/// Write bytes to a file using C API
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
        \\Usage: zig-ai live "message" [options]
        \\       zig-ai live --interactive [options]
        \\
        \\Real-time streaming conversation with Gemini via WebSocket.
        \\Supports text and audio modalities. Requires GEMINI_API_KEY.
        \\
        \\Modes:
        \\  One-shot (default)      Send a message, get response, exit
        \\  Interactive (-i)        REPL conversation loop (Ctrl+D to exit)
        \\
        \\Options:
        \\  --modality <MODE>       Response modality: text (default), audio
        \\  -v, --voice <VOICE>     Voice for audio: kore (default), charon, fenrir,
        \\                          aoede, puck, leda, orus, zephyr
        \\  -s, --system <TEXT>     System instruction
        \\  --model <MODEL>         Model name (default: gemini-live-2.5-flash-preview)
        \\  -t, --temperature <F>   Temperature (0.0-2.0, default: 1.0)
        \\  -o, --output <PATH>     Output WAV path (default: live_response.wav)
        \\      --no-audio          Text only, skip audio output
        \\  -i, --interactive       Interactive REPL conversation mode
        \\      --context-compression  Enable sliding window for unlimited sessions
        \\      --transcription     Enable output audio transcription
        \\      --google-search     Enable Google Search grounding
        \\      --thinking <N>      Enable thinking with token budget
        \\  -h, --help              Show this help
        \\
        \\Models:
        \\  gemini-live-2.5-flash-preview               Text + VAD (default)
        \\  gemini-2.5-flash-native-audio-preview-12-2025  Native audio output
        \\
        \\Voices:
        \\  kore     Firm and authoritative (default)
        \\  charon   Warm and calm
        \\  fenrir   Excitable and energetic
        \\  aoede    Bright and upbeat
        \\  puck     Lively and playful
        \\  leda     Youthful and clear
        \\  orus     Firm and informative
        \\  zephyr   Breezy and conversational
        \\
        \\Examples:
        \\  zig-ai live "Hello, how are you?"
        \\  zig-ai live "Explain quantum computing" --no-audio
        \\  zig-ai live "Tell me a story" --modality audio -v puck -o story.wav
        \\  zig-ai live --interactive --context-compression
        \\  zig-ai live "What's the latest on Zig?" --google-search
        \\  zig-ai live "Think step by step" --thinking 1024
        \\
        \\
    , .{});
}
