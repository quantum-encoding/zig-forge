// Gemini Live Module — Real-time WebSocket streaming for Gemini Live API
// Re-exports types, session, WebSocket client, and CLI

pub const types = @import("types.zig");
pub const ws_client = @import("ws_client.zig");
pub const gemini_live = @import("gemini_live.zig");
pub const cli = @import("cli.zig");

// Re-export key types
pub const Modality = types.Modality;
pub const GeminiVoice = types.GeminiVoice;
pub const VadConfig = types.VadConfig;
pub const LiveConfig = types.LiveConfig;
pub const LiveResponse = types.LiveResponse;
pub const FunctionCall = types.FunctionCall;
pub const SessionState = types.SessionState;
pub const Models = types.Models;
pub const GeminiLiveSession = gemini_live.GeminiLiveSession;
pub const ToolResponse = gemini_live.ToolResponse;
pub const writeWav = gemini_live.writeWav;
