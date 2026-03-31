// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Audio CLI commands
//!
//! Commands:
//!   tts-openai "text" [options]   - Generate speech using OpenAI TTS
//!   stt-openai <file> [options]   - Transcribe audio using OpenAI STT
//!   tts-google "text" [options]   - Generate speech using Google TTS (coming soon)
//!   stt-google <file> [options]   - Transcribe audio using Google STT (coming soon)

const std = @import("std");
const http_sentinel = @import("http-sentinel");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

pub const TTSConfig = struct {
    text: ?[]const u8 = null,
    voice: http_sentinel.audio.Voice = .coral,
    model: http_sentinel.audio.TTSModel = .gpt_4o_mini_tts,
    format: http_sentinel.audio.AudioFormat = .mp3,
    output: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    speed: f32 = 1.0,
};

pub const STTConfig = struct {
    input_file: ?[]const u8 = null,
    model: http_sentinel.audio.STTModel = .gpt_4o_mini_transcribe,
    response_format: http_sentinel.audio.STTResponseFormat = .text,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    output: ?[]const u8 = null, // Output file for transcript
    translate: bool = false, // Use translation endpoint (whisper-1 only)
};

pub const GoogleTTSConfig = struct {
    text: ?[]const u8 = null,
    voice: http_sentinel.audio.GoogleVoice = .kore,
    model: http_sentinel.audio.GoogleTTSModel = .gemini_2_5_flash_tts,
    output: ?[]const u8 = null,
    // Multi-speaker mode
    speaker2_name: ?[]const u8 = null,
    speaker2_voice: ?http_sentinel.audio.GoogleVoice = null,
};

/// Check if args contain an audio command and handle it
/// Returns true if command was handled
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !bool {
    if (args.len < 2) return false;

    const command = args[1];

    // TTS commands
    if (std.mem.eql(u8, command, "tts-openai")) {
        try runTTSOpenAI(allocator, args);
        return true;
    }

    if (std.mem.eql(u8, command, "tts-openai-help") or
        (std.mem.eql(u8, command, "tts-openai") and args.len >= 3 and std.mem.eql(u8, args[2], "--help")))
    {
        printTTSOpenAIHelp();
        return true;
    }

    // Google TTS commands
    if (std.mem.eql(u8, command, "tts-google")) {
        try runTTSGoogle(allocator, args);
        return true;
    }

    if (std.mem.eql(u8, command, "tts-google-help") or
        (std.mem.eql(u8, command, "tts-google") and args.len >= 3 and std.mem.eql(u8, args[2], "--help")))
    {
        printTTSGoogleHelp();
        return true;
    }

    // STT commands
    if (std.mem.eql(u8, command, "stt-openai")) {
        try runSTTOpenAI(allocator, args);
        return true;
    }

    if (std.mem.eql(u8, command, "stt-openai-help") or
        (std.mem.eql(u8, command, "stt-openai") and args.len >= 3 and std.mem.eql(u8, args[2], "--help")))
    {
        printSTTOpenAIHelp();
        return true;
    }

    return false;
}

fn runTTSOpenAI(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = TTSConfig{};

    // Parse arguments
    var i: usize = 2; // Skip program name and "tts-openai"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printTTSOpenAIHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--voice") or std.mem.eql(u8, arg, "-v")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --voice requires a value\n", .{});
                return error.MissingArgument;
            }
            config.voice = http_sentinel.audio.Voice.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown voice '{s}'\n", .{args[i]});
                std.debug.print("Valid voices: alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse, marin, cedar\n", .{});
                return error.InvalidVoice;
            };
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                return error.MissingArgument;
            }
            config.model = http_sentinel.audio.TTSModel.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown model '{s}'\n", .{args[i]});
                std.debug.print("Valid models: gpt-4o-mini-tts, tts-1, tts-1-hd\n", .{});
                return error.InvalidModel;
            };
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --format requires a value\n", .{});
                return error.MissingArgument;
            }
            config.format = http_sentinel.audio.AudioFormat.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown format '{s}'\n", .{args[i]});
                std.debug.print("Valid formats: mp3, opus, aac, flac, wav, pcm\n", .{});
                return error.InvalidFormat;
            };
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            config.output = args[i];
        } else if (std.mem.eql(u8, arg, "--instructions") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --instructions requires a value\n", .{});
                return error.MissingArgument;
            }
            config.instructions = args[i];
        } else if (std.mem.eql(u8, arg, "--speed") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --speed requires a value\n", .{});
                return error.MissingArgument;
            }
            config.speed = try std.fmt.parseFloat(f32, args[i]);
            if (config.speed < 0.25 or config.speed > 4.0) {
                std.debug.print("Error: --speed must be between 0.25 and 4.0\n", .{});
                return error.InvalidSpeed;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = text
            if (config.text == null) {
                config.text = arg;
            } else {
                std.debug.print("Error: Multiple text arguments. Use quotes for multi-word text.\n", .{});
                return error.MultipleTexts;
            }
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            printTTSOpenAIHelp();
            return error.UnknownOption;
        }
    }

    // Validate
    const text = config.text orelse {
        std.debug.print("Error: No text provided\n\n", .{});
        printTTSOpenAIHelp();
        return error.MissingText;
    };

    // Check API key
    const api_key_ptr = std.c.getenv("OPENAI_API_KEY") orelse {
        std.debug.print("Error: OPENAI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export OPENAI_API_KEY=your-api-key\n", .{});
        return error.MissingApiKey;
    };
    const api_key = std.mem.span(api_key_ptr);

    // Generate output filename if not specified
    const output_path = config.output orelse blk: {
        const ext = config.format.fileExtension();
        break :blk try std.fmt.allocPrint(allocator, "speech{s}", .{ext});
    };
    defer if (config.output == null) allocator.free(output_path);

    std.debug.print("\x1b[36m🔊\x1b[0m Generating speech with OpenAI {s}...\n", .{config.model.toString()});
    std.debug.print("   Voice: {s}, Format: {s}\n", .{ config.voice.toString(), config.format.toString() });

    // Create client and generate speech
    var client = try http_sentinel.audio.OpenAITTSClient.init(allocator, api_key);
    defer client.deinit();

    var response = client.speak(.{
        .text = text,
        .voice = config.voice,
        .model = config.model,
        .format = config.format,
        .instructions = config.instructions,
        .speed = config.speed,
    }) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Generation failed: {any}\n", .{err});
        return err;
    };
    defer response.deinit();

    // Write to file using C API
    var path_buf: [512]u8 = undefined;
    if (output_path.len >= path_buf.len - 1) {
        std.debug.print("Error: Output path too long\n", .{});
        return error.PathTooLong;
    }
    @memcpy(path_buf[0..output_path.len], output_path);
    path_buf[output_path.len] = 0;

    const file = fopen(path_buf[0..output_path.len :0], "wb") orelse {
        std.debug.print("Error: Could not open output file: {s}\n", .{output_path});
        return error.FileOpenFailed;
    };
    defer _ = fclose(file);

    const written = fwrite(response.audio_data.ptr, 1, response.audio_data.len, file);
    if (written != response.audio_data.len) {
        std.debug.print("Error: Failed to write audio data\n", .{});
        return error.WriteError;
    }

    const size_kb = @as(f64, @floatFromInt(response.audio_data.len)) / 1024.0;
    std.debug.print("\x1b[32m✓\x1b[0m Saved: {s} ({d:.1} KB)\n", .{ output_path, size_kb });
}

pub fn printTTSOpenAIHelp() void {
    std.debug.print(
        \\OpenAI Text-to-Speech
        \\
        \\USAGE:
        \\  zig-ai tts-openai "your text here" [options]
        \\
        \\OPTIONS:
        \\  -v, --voice <voice>         Voice to use (default: coral)
        \\                              Voices: alloy, ash, ballad, coral, echo, fable,
        \\                                      nova, onyx, sage, shimmer, verse, marin, cedar
        \\  -m, --model <model>         TTS model (default: gpt-4o-mini-tts)
        \\                              Models: gpt-4o-mini-tts, tts-1, tts-1-hd
        \\  -f, --format <format>       Audio format (default: mp3)
        \\                              Formats: mp3, opus, aac, flac, wav, pcm
        \\  -o, --output <path>         Output file path (default: speech.<format>)
        \\  -i, --instructions <text>   Speaking style instructions (gpt-4o-mini-tts only)
        \\  -s, --speed <0.25-4.0>      Speech speed (default: 1.0)
        \\  -h, --help                  Show this help
        \\
        \\EXAMPLES:
        \\  zig-ai tts-openai "Hello world"
        \\  zig-ai tts-openai "Welcome to our app" -v marin -o welcome.mp3
        \\  zig-ai tts-openai "Breaking news!" -i "Speak urgently like a news anchor"
        \\  zig-ai tts-openai "Calm meditation" -v sage -i "Speak slowly and calmly" -s 0.8
        \\
        \\PRICING (per 1M characters):
        \\  gpt-4o-mini-tts: $12.00
        \\  tts-1:          $15.00
        \\  tts-1-hd:       $30.00
        \\
    , .{});
}

pub fn listVoices() void {
    std.debug.print(
        \\Available OpenAI TTS Voices:
        \\
        \\  alloy    - Neutral, balanced
        \\  ash      - Warm, friendly
        \\  ballad   - Expressive, dramatic
        \\  coral    - Clear, professional (default)
        \\  echo     - Deep, resonant
        \\  fable    - Storytelling, narrative
        \\  nova     - Bright, energetic
        \\  onyx     - Deep, authoritative
        \\  sage     - Calm, wise
        \\  shimmer  - Light, airy
        \\  verse    - Poetic, rhythmic
        \\  marin    - High quality, recommended
        \\  cedar    - High quality, recommended
        \\
    , .{});
}

// ============================================================
// Google Gemini TTS Functions
// ============================================================

fn runTTSGoogle(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = GoogleTTSConfig{};

    // Parse arguments
    var i: usize = 2; // Skip program name and "tts-google"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printTTSGoogleHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--voice") or std.mem.eql(u8, arg, "-v")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --voice requires a value\n", .{});
                return error.MissingArgument;
            }
            config.voice = http_sentinel.audio.GoogleVoice.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown voice '{s}'\n", .{args[i]});
                std.debug.print("Use 'zig-ai tts-google --help' to see available voices\n", .{});
                return error.InvalidVoice;
            };
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                return error.MissingArgument;
            }
            config.model = http_sentinel.audio.GoogleTTSModel.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown model '{s}'\n", .{args[i]});
                std.debug.print("Valid models: flash, pro (or gemini-2.5-flash-preview-tts, gemini-2.5-pro-preview-tts)\n", .{});
                return error.InvalidModel;
            };
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            config.output = args[i];
        } else if (std.mem.eql(u8, arg, "--voices")) {
            listGoogleVoices();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = text
            if (config.text == null) {
                config.text = arg;
            } else {
                std.debug.print("Error: Multiple text arguments. Use quotes for multi-word text.\n", .{});
                return error.MultipleTexts;
            }
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            printTTSGoogleHelp();
            return error.UnknownOption;
        }
    }

    // Validate
    const text = config.text orelse {
        std.debug.print("Error: No text provided\n\n", .{});
        printTTSGoogleHelp();
        return error.MissingText;
    };

    // Check API key (try GEMINI_API_KEY first, then GOOGLE_GENAI_API_KEY as fallback)
    const api_key_ptr = std.c.getenv("GEMINI_API_KEY") orelse
        std.c.getenv("GOOGLE_GENAI_API_KEY") orelse {
        std.debug.print("Error: GEMINI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export GEMINI_API_KEY=your-api-key\n", .{});
        return error.MissingApiKey;
    };
    const api_key = std.mem.span(api_key_ptr);

    // Generate output filename if not specified (always .wav for Google TTS)
    const output_path = config.output orelse "speech.wav";

    std.debug.print("\x1b[36m🔊\x1b[0m Generating speech with Google Gemini TTS ({s})...\n", .{
        if (config.model == .gemini_2_5_pro_tts) "Pro" else "Flash",
    });
    std.debug.print("   Voice: {s} ({s})\n", .{
        config.voice.toString(),
        config.voice.description(),
    });

    // Create client and generate speech
    var client = try http_sentinel.audio.GoogleTTSClient.init(allocator, api_key);
    defer client.deinit();

    var response = client.speak(.{
        .text = text,
        .voice = config.voice,
        .model = config.model,
    }) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Generation failed: {any}\n", .{err});
        return err;
    };
    defer response.deinit();

    // Convert PCM to WAV format
    const wav_data = try response.toWav(allocator);
    defer allocator.free(wav_data);

    // Write to file using C API
    var path_buf: [512]u8 = undefined;
    if (output_path.len >= path_buf.len - 1) {
        std.debug.print("Error: Output path too long\n", .{});
        return error.PathTooLong;
    }
    @memcpy(path_buf[0..output_path.len], output_path);
    path_buf[output_path.len] = 0;

    const file = fopen(path_buf[0..output_path.len :0], "wb") orelse {
        std.debug.print("Error: Could not open output file: {s}\n", .{output_path});
        return error.FileOpenFailed;
    };
    defer _ = fclose(file);

    const written = fwrite(wav_data.ptr, 1, wav_data.len, file);
    if (written != wav_data.len) {
        std.debug.print("Error: Failed to write audio data\n", .{});
        return error.WriteError;
    }

    const size_kb = @as(f64, @floatFromInt(wav_data.len)) / 1024.0;
    std.debug.print("\x1b[32m✓\x1b[0m Saved: {s} ({d:.1} KB)\n", .{ output_path, size_kb });
}

pub fn printTTSGoogleHelp() void {
    std.debug.print(
        \\Google Gemini Text-to-Speech
        \\
        \\USAGE:
        \\  zig-ai tts-google "your text here" [options]
        \\
        \\OPTIONS:
        \\  -v, --voice <voice>         Voice to use (default: kore)
        \\                              Use --voices to see all 30 available voices
        \\  -m, --model <model>         TTS model (default: flash)
        \\                              Models: flash (faster), pro (higher quality)
        \\  -o, --output <path>         Output file path (default: speech.wav)
        \\  --voices                    List all available voices with descriptions
        \\  -h, --help                  Show this help
        \\
        \\FEATURES:
        \\  - 30 unique voices with different styles
        \\  - Style controllable via natural language in text
        \\  - Output format: WAV (24kHz, 16-bit, mono)
        \\
        \\STYLE CONTROL:
        \\  Control style, tone, accent, and pace using natural language:
        \\  "Say cheerfully: Have a wonderful day!"
        \\  "In a whisper: The secret is safe with me."
        \\  "Speak slowly and calmly: Take a deep breath."
        \\
        \\EXAMPLES:
        \\  zig-ai tts-google "Hello world"
        \\  zig-ai tts-google "Welcome to our app" -v puck -o welcome.wav
        \\  zig-ai tts-google "Say excitedly: This is amazing!" -v fenrir
        \\  zig-ai tts-google "Speak with a British accent: Good morning" -v charon
        \\
        \\PRICING (estimate):
        \\  Flash: ~$0.002/1K characters
        \\  Pro:   ~$0.010/1K characters
        \\
    , .{});
}

pub fn listGoogleVoices() void {
    std.debug.print(
        \\Available Google Gemini TTS Voices (30 voices):
        \\
        \\  VOICE           STYLE           VOICE           STYLE
        \\  ─────────────────────────────────────────────────────────
        \\  zephyr          Bright          puck            Upbeat
        \\  charon          Informative     kore            Firm (default)
        \\  fenrir          Excitable       leda            Youthful
        \\  orus            Firm            aoede           Breezy
        \\  callirrhoe      Easy-going      autonoe         Bright
        \\  enceladus       Breathy         iapetus         Clear
        \\  umbriel         Easy-going      algieba         Smooth
        \\  despina         Smooth          erinome         Clear
        \\  algenib         Gravelly        rasalgethi      Informative
        \\  laomedeia       Upbeat          achernar        Soft
        \\  alnilam         Firm            schedar         Even
        \\  gacrux          Mature          pulcherrima     Forward
        \\  achird          Friendly        zubenelgenubi   Casual
        \\  vindemiatrix    Gentle          sadachbia       Lively
        \\  sadaltager      Knowledgeable   sulafat         Warm
        \\
        \\TIP: Voice style can be enhanced with natural language prompts.
        \\     Example: "Say with enthusiasm:" prepended to your text.
        \\
    , .{});
}

// ============================================================
// Speech-to-Text (STT) Functions
// ============================================================

fn runSTTOpenAI(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = STTConfig{};

    // Parse arguments
    var i: usize = 2; // Skip program name and "stt-openai"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printSTTOpenAIHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                return error.MissingArgument;
            }
            config.model = http_sentinel.audio.STTModel.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown model '{s}'\n", .{args[i]});
                std.debug.print("Valid models: whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe\n", .{});
                return error.InvalidModel;
            };
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --format requires a value\n", .{});
                return error.MissingArgument;
            }
            config.response_format = http_sentinel.audio.STTResponseFormat.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown format '{s}'\n", .{args[i]});
                std.debug.print("Valid formats: json, text, srt, verbose_json, vtt\n", .{});
                return error.InvalidFormat;
            };
        } else if (std.mem.eql(u8, arg, "--language") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --language requires a value\n", .{});
                return error.MissingArgument;
            }
            config.language = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --prompt requires a value\n", .{});
                return error.MissingArgument;
            }
            config.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            config.output = args[i];
        } else if (std.mem.eql(u8, arg, "--translate")) {
            config.translate = true;
            config.model = .whisper_1; // Translation only supports whisper-1
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = input file
            if (config.input_file == null) {
                config.input_file = arg;
            } else {
                std.debug.print("Error: Multiple input files. Only one audio file is supported.\n", .{});
                return error.MultipleInputs;
            }
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            printSTTOpenAIHelp();
            return error.UnknownOption;
        }
    }

    // Validate
    const input_file = config.input_file orelse {
        std.debug.print("Error: No input file provided\n\n", .{});
        printSTTOpenAIHelp();
        return error.MissingInput;
    };

    // Check API key
    const api_key_ptr = std.c.getenv("OPENAI_API_KEY") orelse {
        std.debug.print("Error: OPENAI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export OPENAI_API_KEY=your-api-key\n", .{});
        return error.MissingApiKey;
    };
    const api_key = std.mem.span(api_key_ptr);

    // Read audio file
    var path_buf: [512]u8 = undefined;
    if (input_file.len >= path_buf.len - 1) {
        std.debug.print("Error: Input path too long\n", .{});
        return error.PathTooLong;
    }
    @memcpy(path_buf[0..input_file.len], input_file);
    path_buf[input_file.len] = 0;

    const file = fopen(path_buf[0..input_file.len :0], "rb") orelse {
        std.debug.print("Error: Could not open input file: {s}\n", .{input_file});
        return error.FileOpenFailed;
    };
    defer _ = fclose(file);

    // Get file size
    if (fseek(file, 0, SEEK_END) != 0) {
        std.debug.print("Error: Could not read file size\n", .{});
        return error.FileReadFailed;
    }
    const file_size_long = ftell(file);
    if (file_size_long < 0) {
        std.debug.print("Error: Could not read file size\n", .{});
        return error.FileReadFailed;
    }
    const file_size: usize = @intCast(file_size_long);

    // Check size limit (25 MB)
    if (file_size > 25 * 1024 * 1024) {
        std.debug.print("Error: File too large. Maximum size is 25 MB.\n", .{});
        return error.FileTooLarge;
    }

    if (fseek(file, 0, SEEK_SET) != 0) {
        std.debug.print("Error: Could not read file\n", .{});
        return error.FileReadFailed;
    }

    // Allocate and read file content
    const audio_data = try allocator.alloc(u8, file_size);
    defer allocator.free(audio_data);

    const bytes_read = fread(audio_data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        std.debug.print("Error: Could not read file contents\n", .{});
        return error.FileReadFailed;
    }

    // Get filename for API
    const filename = std.fs.path.basename(input_file);

    const size_mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
    if (config.translate) {
        std.debug.print("\x1b[36m🎤\x1b[0m Translating audio with OpenAI whisper-1...\n", .{});
    } else {
        std.debug.print("\x1b[36m🎤\x1b[0m Transcribing audio with OpenAI {s}...\n", .{config.model.toString()});
    }
    std.debug.print("   File: {s} ({d:.2} MB)\n", .{ input_file, size_mb });

    // Create client and transcribe
    var client = try http_sentinel.audio.OpenAISTTClient.init(allocator, api_key);
    defer client.deinit();

    var response = if (config.translate)
        client.translate(audio_data) catch |err| {
            std.debug.print("\x1b[31m✗\x1b[0m Transcription failed: {any}\n", .{err});
            return err;
        }
    else
        client.transcribe(.{
            .audio_data = audio_data,
            .filename = filename,
            .model = config.model,
            .response_format = config.response_format,
            .language = config.language,
            .prompt = config.prompt,
        }) catch |err| {
            std.debug.print("\x1b[31m✗\x1b[0m Transcription failed: {any}\n", .{err});
            return err;
        };
    defer response.deinit();

    // Output result
    if (config.output) |output_path| {
        // Write to file
        var out_path_buf: [512]u8 = undefined;
        if (output_path.len >= out_path_buf.len - 1) {
            std.debug.print("Error: Output path too long\n", .{});
            return error.PathTooLong;
        }
        @memcpy(out_path_buf[0..output_path.len], output_path);
        out_path_buf[output_path.len] = 0;

        const out_file = fopen(out_path_buf[0..output_path.len :0], "wb") orelse {
            std.debug.print("Error: Could not open output file: {s}\n", .{output_path});
            return error.FileOpenFailed;
        };
        defer _ = fclose(out_file);

        const written = fwrite(response.text.ptr, 1, response.text.len, out_file);
        if (written != response.text.len) {
            std.debug.print("Error: Failed to write transcript\n", .{});
            return error.WriteError;
        }

        std.debug.print("\x1b[32m✓\x1b[0m Saved transcript to: {s}\n", .{output_path});
    } else {
        // Print to stdout
        std.debug.print("\n\x1b[32m✓\x1b[0m Transcript:\n", .{});
        std.debug.print("─────────────────────────────────────────\n", .{});
        std.debug.print("{s}\n", .{response.text});
        std.debug.print("─────────────────────────────────────────\n", .{});

        if (response.duration) |dur| {
            std.debug.print("\x1b[90mDuration: {d:.1}s\x1b[0m\n", .{dur});
        }
        if (response.language) |lang| {
            std.debug.print("\x1b[90mLanguage: {s}\x1b[0m\n", .{lang});
        }
    }
}

pub fn printSTTOpenAIHelp() void {
    std.debug.print(
        \\OpenAI Speech-to-Text
        \\
        \\USAGE:
        \\  zig-ai stt-openai <audio-file> [options]
        \\
        \\OPTIONS:
        \\  -m, --model <model>         STT model (default: gpt-4o-mini-transcribe)
        \\                              Models: whisper-1, gpt-4o-transcribe,
        \\                                      gpt-4o-mini-transcribe
        \\  -f, --format <format>       Response format (default: text)
        \\                              Formats: json, text, srt, verbose_json, vtt
        \\  -l, --language <code>       Language code (ISO 639-1, e.g., en, es, fr)
        \\  -p, --prompt <text>         Context hint to improve accuracy
        \\  -o, --output <path>         Save transcript to file
        \\  --translate                 Translate to English (whisper-1 only)
        \\  -h, --help                  Show this help
        \\
        \\SUPPORTED FORMATS:
        \\  mp3, mp4, mpeg, mpga, m4a, wav, webm (max 25 MB)
        \\
        \\EXAMPLES:
        \\  zig-ai stt-openai meeting.mp3
        \\  zig-ai stt-openai lecture.wav -m gpt-4o-transcribe
        \\  zig-ai stt-openai interview.mp3 -o transcript.txt
        \\  zig-ai stt-openai german.mp3 --translate
        \\  zig-ai stt-openai podcast.mp3 -p "Technical discussion about AI and ML"
        \\
        \\PRICING (per minute of audio):
        \\  whisper-1:              $0.006
        \\  gpt-4o-transcribe:      $0.006
        \\  gpt-4o-mini-transcribe: $0.003
        \\
    , .{});
}
