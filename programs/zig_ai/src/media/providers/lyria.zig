// Google Lyria Music Generation Provider
// Supports: Lyria 2 via Vertex AI (requires gcloud auth)
// Supports: Lyria RealTime via GenAI WebSocket (requires GEMINI_API_KEY)

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const storage = @import("../storage.zig");
const Timer = @import("../../timer.zig").Timer;
const MusicRequest = types.MusicRequest;
const MusicResponse = types.MusicResponse;
const MusicProvider = types.MusicProvider;
const MediaConfig = types.MediaConfig;

const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;

const lyria_ws = @import("lyria_ws.zig");
const LyriaSession = lyria_ws.LyriaSession;
const WeightedPrompt = lyria_ws.WeightedPrompt;
const MusicConfig = lyria_ws.MusicConfig;

// Extern C functions
extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *std.c.FILE) ?[*]u8;

// ============================================================================
// API Constants
// ============================================================================

const LYRIA_MODEL = "lyria-002";
const LYRIA_REALTIME_MODEL = "models/lyria-realtime-exp";
const VERTEX_LOCATION = "us-central1";

// ============================================================================
// Lyria Music Generation (Vertex AI)
// ============================================================================

pub fn generateLyria(
    allocator: Allocator,
    request: MusicRequest,
    config: MediaConfig,
) !MusicResponse {
    // Try to get project ID from config or gcloud
    const project_id = config.vertex_project_id orelse blk: {
        // Try gcloud config
        const gcloud_project = getGcloudProjectId(allocator) catch {
            std.debug.print("Error: VERTEX_PROJECT_ID not set and gcloud project not configured\n", .{});
            std.debug.print("Lyria requires Google Cloud Vertex AI authentication.\n", .{});
            std.debug.print("Set it with: export VERTEX_PROJECT_ID=your-project-id\n", .{});
            std.debug.print("Or configure gcloud: gcloud config set project YOUR_PROJECT\n", .{});
            return error.MissingProjectId;
        };
        break :blk gcloud_project;
    };
    defer if (config.vertex_project_id == null) allocator.free(project_id);

    var timer = Timer.start() catch unreachable;

    // Get access token from gcloud
    std.debug.print("  Getting gcloud access token...\n", .{});
    const access_token = getGcloudAccessToken(allocator) catch |err| {
        std.debug.print("Error: Failed to get gcloud access token: {any}\n", .{err});
        std.debug.print("Make sure gcloud CLI is installed and authenticated:\n", .{});
        std.debug.print("  gcloud auth login\n", .{});
        return error.AuthenticationFailed;
    };
    defer allocator.free(access_token);

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    // Build instance object
    var instance_parts: std.ArrayListUnmanaged(u8) = .empty;
    defer instance_parts.deinit(allocator);

    try instance_parts.appendSlice(allocator, "{\"prompt\":\"");
    try instance_parts.appendSlice(allocator, escaped_prompt);
    try instance_parts.appendSlice(allocator, "\"");

    // Add negative prompt if present
    if (request.negative_prompt) |neg| {
        const escaped_neg = try escapeJson(allocator, neg);
        defer allocator.free(escaped_neg);
        try instance_parts.appendSlice(allocator, ",\"negative_prompt\":\"");
        try instance_parts.appendSlice(allocator, escaped_neg);
        try instance_parts.appendSlice(allocator, "\"");
    }

    // Add seed if present
    if (request.seed) |seed| {
        var seed_buf: [32]u8 = undefined;
        const seed_str = std.fmt.bufPrint(&seed_buf, ",\"seed\":{d}", .{seed}) catch unreachable;
        try instance_parts.appendSlice(allocator, seed_str);
    }

    try instance_parts.appendSlice(allocator, "}");

    // Build parameters if no seed (sample_count only works without seed)
    var params_json: []const u8 = "";
    var params_owned = false;
    if (request.seed == null and request.count > 1) {
        params_json = try std.fmt.allocPrint(allocator, ",\"parameters\":{{\"sample_count\":{d}}}", .{request.count});
        params_owned = true;
    }
    defer if (params_owned) allocator.free(params_json);

    const payload = try std.fmt.allocPrint(allocator,
        "{{\"instances\":[{s}]{s}}}",
        .{ instance_parts.items, params_json },
    );
    defer allocator.free(payload);

    // Build Vertex AI URL
    const url = try std.fmt.allocPrint(allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:predict",
        .{ VERTEX_LOCATION, project_id, VERTEX_LOCATION, LYRIA_MODEL },
    );
    defer allocator.free(url);

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    std.debug.print("  Starting music generation...\n", .{});
    std.debug.print("  Model: {s}\n", .{LYRIA_MODEL});

    var http_response = try client.post(url, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("Lyria API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const predictions = root.get("predictions") orelse return error.InvalidResponse;

    if (predictions.array.items.len == 0) {
        std.debug.print("  No audio clips generated\n", .{});
        return error.NoAudioGenerated;
    }

    // Extract audio data from first prediction
    const first_pred = predictions.array.items[0].object;

    var audio_data: []u8 = undefined;

    // Try bytesBase64Encoded first
    if (first_pred.get("bytesBase64Encoded")) |b64_val| {
        std.debug.print("  Decoding audio data...\n", .{});
        audio_data = try decodeBase64(allocator, b64_val.string);
    } else if (first_pred.get("audioContent")) |b64_val| {
        std.debug.print("  Decoding audio content...\n", .{});
        audio_data = try decodeBase64(allocator, b64_val.string);
    } else {
        std.debug.print("  No audio data in response\n", .{});
        return error.NoAudioGenerated;
    }
    defer allocator.free(audio_data);

    const size_kb = @as(f64, @floatFromInt(audio_data.len)) / 1024.0;
    std.debug.print("  Audio decoded: {d:.1} KB\n", .{size_kb});

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = MusicResponse{
        .job_id = job_id,
        .provider = request.provider,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .tracks = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, LYRIA_MODEL),
        .bpm = request.bpm,
        .allocator = allocator,
    };

    // Save audio
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveMusic(allocator, &result, audio_data, .wav, resolved.config);

    return result;
}

/// Get access token from gcloud CLI
fn getGcloudAccessToken(allocator: Allocator) ![]u8 {
    const cmd = "gcloud auth print-access-token 2>/dev/null";

    const pipe = popen(cmd, "r") orelse return error.PopenFailed;
    defer _ = pclose(pipe);

    var buffer: [2048]u8 = undefined;
    const result = fgets(&buffer, buffer.len, pipe);

    if (result == null) {
        return error.ReadFailed;
    }

    // Find end of token (newline or null)
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0 and buffer[len] != '\n' and buffer[len] != '\r') {
        len += 1;
    }

    if (len == 0) {
        return error.EmptyToken;
    }

    return allocator.dupe(u8, buffer[0..len]);
}

/// Get project ID from gcloud config
fn getGcloudProjectId(allocator: Allocator) ![]u8 {
    const cmd = "gcloud config get-value project 2>/dev/null";

    const pipe = popen(cmd, "r") orelse return error.PopenFailed;
    defer _ = pclose(pipe);

    var buffer: [256]u8 = undefined;
    const result = fgets(&buffer, buffer.len, pipe);

    if (result == null) {
        return error.ReadFailed;
    }

    // Find end of project ID (newline or null)
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0 and buffer[len] != '\n' and buffer[len] != '\r') {
        len += 1;
    }

    if (len == 0) {
        return error.EmptyProjectId;
    }

    return allocator.dupe(u8, buffer[0..len]);
}

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buffer = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buffer);

    decoder.Decoder.decode(buffer, encoded) catch return error.InvalidBase64;
    return buffer;
}

// ============================================================================
// Lyria RealTime (WebSocket streaming for instant clips)
// ============================================================================

pub fn generateLyriaRealtime(
    allocator: Allocator,
    request: MusicRequest,
    config: MediaConfig,
) !MusicResponse {
    // Check for GEMINI_API_KEY (RealTime uses GenAI, not Vertex)
    const api_key = config.genai_api_key orelse {
        std.debug.print("Error: GEMINI_API_KEY not set for Lyria RealTime\n", .{});
        std.debug.print("Set it with: export GEMINI_API_KEY=your-api-key\n", .{});
        std.debug.print("Falling back to standard Lyria (Vertex AI)...\n", .{});
        return generateLyria(allocator, request, config);
    };

    var timer = Timer.start() catch unreachable;

    std.debug.print("  Connecting to Lyria RealTime WebSocket...\n", .{});

    // Initialize Lyria session
    var session = LyriaSession.init(allocator) catch |err| {
        std.debug.print("  WebSocket init failed: {any}, falling back to standard Lyria\n", .{err});
        return generateLyria(allocator, request, config);
    };
    defer session.deinit();

    // Connect (includes TLS handshake and WS upgrade)
    session.connect(api_key) catch |err| {
        std.debug.print("  WebSocket connect failed: {any}, falling back to standard Lyria\n", .{err});
        return generateLyria(allocator, request, config);
    };

    if (!session.setup_complete) {
        std.debug.print("  Session setup incomplete, falling back to standard Lyria\n", .{});
        return generateLyria(allocator, request, config);
    }

    std.debug.print("  Session established, sending prompts...\n", .{});

    // Send weighted prompts
    const prompts = [_]WeightedPrompt{
        .{ .text = request.prompt, .weight = 1.0 },
    };
    session.setPrompts(&prompts) catch |err| {
        std.debug.print("  Failed to set prompts: {any}\n", .{err});
        return error.WebSocketError;
    };

    // Send music config
    session.setConfig(.{
        .bpm = request.bpm,
        .temperature = 1.1,
        .guidance = 4.0,
    }) catch |err| {
        std.debug.print("  Failed to set config: {any}\n", .{err});
        return error.WebSocketError;
    };

    // Start playback
    session.play() catch |err| {
        std.debug.print("  Failed to start playback: {any}\n", .{err});
        return error.WebSocketError;
    };

    std.debug.print("  Streaming audio...\n", .{});

    // Collect audio data
    var audio_data: std.ArrayListUnmanaged(u8) = .empty;
    defer audio_data.deinit(allocator);

    const duration_secs: u64 = if (request.duration_seconds > 0) request.duration_seconds else 10;
    var stream_timer = Timer.start() catch unreachable;
    const max_time_ns: u64 = (duration_secs + 5) * std.time.ns_per_s; // duration + 5s buffer

    // Receive audio chunks
    while (!session.ws.closed) {
        const elapsed_ns = stream_timer.read();
        if (elapsed_ns > max_time_ns) break;
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

        if (session.receiveAudio()) |maybe_chunk| {
            if (maybe_chunk) |audio_chunk| {
                defer allocator.free(audio_chunk);
                try audio_data.appendSlice(allocator, audio_chunk);
            }
        } else |_| {
            // Error receiving audio
        }

        // Progress indicator
        const elapsed_secs = elapsed_ms / 1000;
        std.debug.print("\r  Recording: {d}s / {d}s ({d:.1} KB)  ", .{
            elapsed_secs,
            duration_secs,
            @as(f64, @floatFromInt(audio_data.items.len)) / 1024.0,
        });
    }
    std.debug.print("\n", .{});

    session.close();

    if (audio_data.items.len == 0) {
        std.debug.print("  No audio received, falling back to standard Lyria\n", .{});
        return generateLyria(allocator, request, config);
    }

    const size_kb = @as(f64, @floatFromInt(audio_data.items.len)) / 1024.0;
    std.debug.print("  PCM audio received: {d:.1} KB\n", .{size_kb});

    // Wrap raw PCM data in WAV container (24kHz 16-bit mono)
    const wav_data = try createWavFile(allocator, audio_data.items);
    defer allocator.free(wav_data);

    const wav_size_kb = @as(f64, @floatFromInt(wav_data.len)) / 1024.0;
    std.debug.print("  WAV file created: {d:.1} KB\n", .{wav_size_kb});

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = MusicResponse{
        .job_id = job_id,
        .provider = .lyria_realtime,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .tracks = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, LYRIA_REALTIME_MODEL),
        .bpm = request.bpm,
        .allocator = allocator,
    };

    // Save audio with proper WAV headers
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveMusic(allocator, &result, wav_data, .wav, resolved.config);

    return result;
}

// ============================================================================
// Helpers
// ============================================================================

/// Create WAV file from raw PCM data
/// Lyria RealTime sends 48kHz 16-bit stereo PCM
fn createWavFile(allocator: Allocator, pcm_data: []const u8) ![]u8 {
    const sample_rate: u32 = 48000;
    const bits_per_sample: u16 = 16;
    const num_channels: u16 = 2;
    const byte_rate: u32 = sample_rate * num_channels * (bits_per_sample / 8);
    const block_align: u16 = num_channels * (bits_per_sample / 8);
    const data_size: u32 = @intCast(pcm_data.len);
    const file_size: u32 = 36 + data_size;

    // WAV header is 44 bytes
    const wav_data = try allocator.alloc(u8, 44 + pcm_data.len);
    errdefer allocator.free(wav_data);

    var pos: usize = 0;

    // RIFF header
    @memcpy(wav_data[pos..][0..4], "RIFF");
    pos += 4;
    std.mem.writeInt(u32, wav_data[pos..][0..4], file_size, .little);
    pos += 4;
    @memcpy(wav_data[pos..][0..4], "WAVE");
    pos += 4;

    // fmt subchunk
    @memcpy(wav_data[pos..][0..4], "fmt ");
    pos += 4;
    std.mem.writeInt(u32, wav_data[pos..][0..4], 16, .little); // Subchunk1Size (16 for PCM)
    pos += 4;
    std.mem.writeInt(u16, wav_data[pos..][0..2], 1, .little); // AudioFormat (1 = PCM)
    pos += 2;
    std.mem.writeInt(u16, wav_data[pos..][0..2], num_channels, .little);
    pos += 2;
    std.mem.writeInt(u32, wav_data[pos..][0..4], sample_rate, .little);
    pos += 4;
    std.mem.writeInt(u32, wav_data[pos..][0..4], byte_rate, .little);
    pos += 4;
    std.mem.writeInt(u16, wav_data[pos..][0..2], block_align, .little);
    pos += 2;
    std.mem.writeInt(u16, wav_data[pos..][0..2], bits_per_sample, .little);
    pos += 2;

    // data subchunk
    @memcpy(wav_data[pos..][0..4], "data");
    pos += 4;
    std.mem.writeInt(u32, wav_data[pos..][0..4], data_size, .little);
    pos += 4;

    // PCM data
    @memcpy(wav_data[pos..][0..pcm_data.len], pcm_data);

    return wav_data;
}

fn escapeJson(allocator: Allocator, s: []const u8) ![]u8 {
    var extra: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => extra += 1,
            else => if (c < 0x20) {
                extra += 5;
            },
        }
    }

    const result = try allocator.alloc(u8, s.len + extra);
    var i: usize = 0;

    for (s) |c| {
        switch (c) {
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(result[i .. i + 6], "\\u{x:0>4}", .{c}) catch unreachable;
                    i += 6;
                } else {
                    result[i] = c;
                    i += 1;
                }
            },
        }
    }

    return result[0..i];
}
