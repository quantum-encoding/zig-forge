// Voice Agent Types — xAI Grok Realtime Voice API
// Type definitions for voice sessions, audio formats, and tool calling

const std = @import("std");

/// Available voice personas
pub const Voice = enum {
    ara,
    rex,
    sal,
    eve,
    leo,

    pub fn toString(self: Voice) []const u8 {
        return switch (self) {
            .ara => "Ara",
            .rex => "Rex",
            .sal => "Sal",
            .eve => "Eve",
            .leo => "Leo",
        };
    }

    pub fn fromString(s: []const u8) ?Voice {
        if (std.mem.eql(u8, s, "ara") or std.mem.eql(u8, s, "Ara")) return .ara;
        if (std.mem.eql(u8, s, "rex") or std.mem.eql(u8, s, "Rex")) return .rex;
        if (std.mem.eql(u8, s, "sal") or std.mem.eql(u8, s, "Sal")) return .sal;
        if (std.mem.eql(u8, s, "eve") or std.mem.eql(u8, s, "Eve")) return .eve;
        if (std.mem.eql(u8, s, "leo") or std.mem.eql(u8, s, "Leo")) return .leo;
        return null;
    }

    pub fn description(self: Voice) []const u8 {
        return switch (self) {
            .ara => "Warm and conversational (default)",
            .rex => "Energetic and bold",
            .sal => "Calm and measured",
            .eve => "Friendly and expressive",
            .leo => "Deep and authoritative",
        };
    }
};

/// Audio encoding formats
pub const AudioEncoding = enum {
    pcm16,
    pcmu,
    pcma,

    pub fn toApiString(self: AudioEncoding) []const u8 {
        return switch (self) {
            .pcm16 => "audio/pcm",
            .pcmu => "audio/pcmu",
            .pcma => "audio/pcma",
        };
    }

    pub fn fromString(s: []const u8) ?AudioEncoding {
        if (std.mem.eql(u8, s, "pcm16") or std.mem.eql(u8, s, "pcm")) return .pcm16;
        if (std.mem.eql(u8, s, "pcmu") or std.mem.eql(u8, s, "g711u")) return .pcmu;
        if (std.mem.eql(u8, s, "pcma") or std.mem.eql(u8, s, "g711a")) return .pcma;
        return null;
    }

    pub fn bitsPerSample(self: AudioEncoding) u16 {
        return switch (self) {
            .pcm16 => 16,
            .pcmu, .pcma => 8,
        };
    }
};

/// Audio format specification
pub const AudioFormat = struct {
    encoding: AudioEncoding = .pcm16,
    sample_rate: u32 = 24000,
    channels: u16 = 1,
};

/// Session configuration
pub const SessionConfig = struct {
    voice: Voice = .ara,
    instructions: ?[]const u8 = null,
    input_format: AudioFormat = .{},
    output_format: AudioFormat = .{},
    tools: []const ToolDefinition = &.{},
};

/// Tool definition for function calling
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// A tool call received from the API
pub const ToolCall = struct {
    call_id: []u8,
    name: []u8,
    arguments: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolCall) void {
        self.allocator.free(self.call_id);
        self.allocator.free(self.name);
        self.allocator.free(self.arguments);
    }
};

/// Response from a voice interaction
pub const VoiceResponse = struct {
    transcript: []u8,
    audio_data: []u8,
    tool_calls: []ToolCall,
    processing_time_ms: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VoiceResponse) void {
        if (self.transcript.len > 0) self.allocator.free(self.transcript);
        if (self.audio_data.len > 0) self.allocator.free(self.audio_data);
        for (self.tool_calls) |*tc| tc.deinit();
        if (self.tool_calls.len > 0) self.allocator.free(self.tool_calls);
    }
};

/// Session state machine
pub const SessionState = enum {
    disconnected,
    connecting,
    configuring,
    ready,
    responding,
    tool_calling,
    failed,
};
