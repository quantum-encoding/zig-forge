// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Common types and utilities for AI provider clients
//! Provides unified interfaces across Claude, DeepSeek, Gemini, Grok, and Vertex

const std = @import("std");

/// Unified error set for all AI providers
pub const AIError = error{
    // Authentication errors
    AuthenticationFailed,
    InvalidApiKey,

    // API errors
    ApiRequestFailed,
    InvalidResponse,
    JsonParseError,

    // Rate limiting
    RateLimitExceeded,
    QuotaExceeded,

    // Request errors
    InvalidRequest,
    InvalidModel,
    MaxTokensExceeded,

    // Timeout errors
    RequestTimeout,
    ConnectionTimeout,

    // Provider-specific
    ProviderUnavailable,
    ServiceUnavailable,

    // Tool calling
    ToolExecutionFailed,
    MaxTurnsReached,

    // Memory
    OutOfMemory,
};

/// Message role in a conversation
pub const MessageRole = enum {
    user,
    assistant,
    system,
    tool,

    pub fn toString(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool => "tool",
        };
    }
};

/// Content type in a message
pub const ContentType = enum {
    text,
    image,
    tool_use,
    tool_result,
};

/// Image data for vision requests
/// Supports two modes:
///   1. Base64 data URI: set `data` (base64 string) and `media_type`
///   2. Direct URL: set `url` to an HTTPS image URL
pub const ImageInput = struct {
    /// Base64-encoded image data (for data URI mode)
    data: []const u8 = "",
    /// MIME type (e.g., "image/png") — used with data URI mode
    media_type: []const u8 = "image/png",
    /// Direct HTTPS image URL (alternative to base64 data)
    /// When set, `data` and `media_type` are ignored
    url: ?[]const u8 = null,
    /// Optional: allocator if data was allocated
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *ImageInput) void {
        if (self.allocator) |alloc| {
            if (self.url) |u| {
                alloc.free(u);
            } else {
                alloc.free(self.data);
            }
        }
    }

    /// Check if this is a URL-based image (vs base64 data URI)
    pub fn isUrl(self: ImageInput) bool {
        return self.url != null;
    }

    /// Get the URL string for the image_url JSON field
    /// Returns either the direct URL or a data URI
    pub fn toImageUrl(self: ImageInput, allocator: std.mem.Allocator) ![]u8 {
        if (self.url) |u| {
            return allocator.dupe(u8, u);
        }
        return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ self.media_type, self.data });
    }

    /// Create an ImageInput from a direct URL
    pub fn fromUrl(url: []const u8, allocator: ?std.mem.Allocator) ImageInput {
        return .{ .url = url, .allocator = allocator };
    }

    /// Detect MIME type from file extension
    pub fn mimeTypeFromPath(path: []const u8) []const u8 {
        // Images
        if (std.mem.endsWith(u8, path, ".png")) return "image/png";
        if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
        if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
        if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
        if (std.mem.endsWith(u8, path, ".bmp")) return "image/bmp";
        // Documents (Gemini document understanding)
        if (std.mem.endsWith(u8, path, ".pdf")) return "application/pdf";
        if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) return "text/html";
        if (std.mem.endsWith(u8, path, ".csv")) return "text/csv";
        if (std.mem.endsWith(u8, path, ".xml")) return "text/xml";
        if (std.mem.endsWith(u8, path, ".json")) return "application/json";
        if (std.mem.endsWith(u8, path, ".txt")) return "text/plain";
        if (std.mem.endsWith(u8, path, ".md")) return "text/plain";
        if (std.mem.endsWith(u8, path, ".rtf")) return "text/rtf";
        // Video (Gemini video understanding)
        if (std.mem.endsWith(u8, path, ".mp4")) return "video/mp4";
        if (std.mem.endsWith(u8, path, ".mpeg") or std.mem.endsWith(u8, path, ".mpg")) return "video/mpeg";
        if (std.mem.endsWith(u8, path, ".mov")) return "video/mov";
        if (std.mem.endsWith(u8, path, ".avi")) return "video/avi";
        if (std.mem.endsWith(u8, path, ".flv")) return "video/x-flv";
        if (std.mem.endsWith(u8, path, ".mkv")) return "video/x-matroska";
        if (std.mem.endsWith(u8, path, ".webm")) return "video/webm";
        if (std.mem.endsWith(u8, path, ".wmv")) return "video/x-ms-wmv";
        if (std.mem.endsWith(u8, path, ".3gp")) return "video/3gpp";
        // Audio
        if (std.mem.endsWith(u8, path, ".mp3")) return "audio/mp3";
        if (std.mem.endsWith(u8, path, ".wav")) return "audio/wav";
        if (std.mem.endsWith(u8, path, ".aac")) return "audio/aac";
        if (std.mem.endsWith(u8, path, ".ogg")) return "audio/ogg";
        if (std.mem.endsWith(u8, path, ".flac")) return "audio/flac";
        return "image/png"; // default
    }

    /// Check if a path looks like an HTTPS URL
    pub fn isHttpUrl(path: []const u8) bool {
        return std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "http://");
    }

    /// Check if a path looks like a YouTube URL
    pub fn isYouTubeUrl(path: []const u8) bool {
        return std.mem.startsWith(u8, path, "https://www.youtube.com/") or
            std.mem.startsWith(u8, path, "https://youtube.com/") or
            std.mem.startsWith(u8, path, "https://youtu.be/");
    }

    /// Check if the MIME type is a video type
    pub fn isVideoMime(mime: []const u8) bool {
        return std.mem.startsWith(u8, mime, "video/");
    }

    /// Check if the MIME type is an audio type
    pub fn isAudioMime(mime: []const u8) bool {
        return std.mem.startsWith(u8, mime, "audio/");
    }
};

/// A single message in a conversation
pub const AIMessage = struct {
    id: []const u8,
    role: MessageRole,
    content: []const u8,
    timestamp: i64,

    // Optional tool calling data
    tool_calls: ?[]ToolCall = null,
    tool_results: ?[]ToolResult = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *AIMessage) void {
        self.allocator.free(self.id);
        self.allocator.free(self.content);

        if (self.tool_calls) |calls| {
            for (calls) |*call| {
                call.deinit();
            }
            self.allocator.free(calls);
        }

        if (self.tool_results) |results| {
            for (results) |*result| {
                result.deinit();
            }
            self.allocator.free(results);
        }
    }
};

/// Tool call request from the AI
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolCall) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.arguments);
    }
};

/// Tool execution result
pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool = false,
    /// Tool name (needed by Gemini which uses name instead of ID in responses)
    tool_name: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolResult) void {
        self.allocator.free(self.tool_call_id);
        self.allocator.free(self.content);
        if (self.tool_name) |name| {
            self.allocator.free(name);
        }
    }
};

/// Tool definition for AI providers
/// JSON schema format compatible with Claude, OpenAI, Gemini, Grok
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for input parameters (as JSON string)
    input_schema: []const u8,
};

/// Tool choice control for function calling
/// Grok/OpenAI: top-level "tool_choice" field
/// Gemini: "toolConfig.functionCallingConfig.mode" field
pub const ToolChoice = enum {
    auto, // Model decides whether to call a tool (default)
    required, // Model must call at least one tool (Gemini: ANY mode)
    none, // Disable tool calling
    function, // Force a specific tool (use tool_choice_function for name)
    validated, // Gemini-only: predict function calls or text, ensure schema adherence

    /// Grok/OpenAI Responses API serialization
    pub fn toJsonValue(self: ToolChoice) []const u8 {
        return switch (self) {
            .auto => "\"auto\"",
            .required => "\"required\"",
            .none => "\"none\"",
            .function => unreachable, // Handled separately as object
            .validated => "\"required\"", // Map to required for non-Gemini
        };
    }

    /// Gemini functionCallingConfig mode string
    pub fn toGeminiMode(self: ToolChoice) []const u8 {
        return switch (self) {
            .auto => "AUTO",
            .required => "ANY",
            .none => "NONE",
            .function => "ANY", // ANY + allowedFunctionNames
            .validated => "VALIDATED",
        };
    }
};

/// Server-side tools auto-executed by xAI (Grok Responses API)
/// These are added to the `tools` array alongside function tools but
/// are handled server-side — the model orchestrates them automatically.
pub const ServerSideTool = enum {
    // xAI (Grok) server-side tools
    web_search,
    x_search,
    code_interpreter,
    // Gemini server-side tools
    google_search, // Grounding with Google Search
    url_context, // URL context retrieval (up to 20 URLs)
    google_maps, // Grounding with Google Maps

    /// xAI Responses API tool type string
    pub fn toJsonType(self: ServerSideTool) []const u8 {
        return switch (self) {
            .web_search => "web_search",
            .x_search => "x_search",
            .code_interpreter => "code_interpreter",
            .google_search => "google_search",
            .url_context => "url_context",
            .google_maps => "googleMaps",
        };
    }

    /// Gemini tools array object (separate from functionDeclarations)
    pub fn toGeminiToolJson(self: ServerSideTool) ?[]const u8 {
        return switch (self) {
            .google_search => "{\"google_search\":{}}",
            .url_context => "{\"url_context\":{}}",
            .google_maps => "{\"googleMaps\":{}}",
            .web_search => "{\"google_search\":{}}", // map xAI web_search to Gemini google_search
            else => null, // x_search, code_interpreter are xAI-only
        };
    }

    /// Whether this tool is supported on Gemini
    pub fn isGeminiTool(self: ServerSideTool) bool {
        return switch (self) {
            .google_search, .url_context, .google_maps, .web_search => true,
            .x_search, .code_interpreter => false,
        };
    }
};

/// Remote MCP tool configuration for xAI Responses API
/// Connects Grok to external MCP servers — xAI manages the connection
pub const McpToolConfig = struct {
    /// MCP server URL (Streaming HTTP or SSE transport)
    server_url: []const u8,
    /// Label to identify the server (used for tool call prefixing)
    server_label: ?[]const u8 = null,
    /// Description of what the server provides
    server_description: ?[]const u8 = null,
    /// Restrict to specific tool names (empty = allow all)
    allowed_tool_names: ?[]const []const u8 = null,
    /// Authorization token for the MCP server
    authorization: ?[]const u8 = null,
};

/// Output item types returned by xAI Responses API
/// Server-side tool calls are auto-executed — only function_call needs client handling
pub const OutputItemType = enum {
    message, // text response
    function_call, // client-side tool (requires local execution)
    web_search_call, // server-side: web search
    x_search_call, // server-side: X/Twitter search
    code_interpreter_call, // server-side: code execution
    file_search_call, // server-side: collections search
    mcp_call, // server-side: MCP tool
    unknown,

    pub fn fromString(s: []const u8) OutputItemType {
        if (std.mem.eql(u8, s, "message")) return .message;
        if (std.mem.eql(u8, s, "function_call")) return .function_call;
        if (std.mem.eql(u8, s, "web_search_call")) return .web_search_call;
        if (std.mem.eql(u8, s, "x_search_call")) return .x_search_call;
        if (std.mem.eql(u8, s, "code_interpreter_call")) return .code_interpreter_call;
        if (std.mem.eql(u8, s, "file_search_call")) return .file_search_call;
        if (std.mem.eql(u8, s, "mcp_call")) return .mcp_call;
        return .unknown;
    }

    pub fn isServerSide(self: OutputItemType) bool {
        return switch (self) {
            .web_search_call, .x_search_call, .code_interpreter_call, .file_search_call, .mcp_call => true,
            else => false,
        };
    }
};

/// Inline citation annotation from xAI Responses API
/// Provides precise positional information about each citation in response text
pub const InlineCitation = struct {
    /// Source URL
    url: []const u8,
    /// Citation display number (e.g., "1", "2")
    title: []const u8,
    /// Character position where the citation starts in the response text
    start_index: u32,
    /// Character position where the citation ends (exclusive)
    end_index: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *InlineCitation) void {
        self.allocator.free(self.url);
        self.allocator.free(self.title);
    }
};

/// Stop reason from AI response
pub const StopReason = enum {
    end_turn, // Normal completion
    tool_use, // Model wants to use a tool
    max_tokens, // Hit token limit
    stop_sequence, // Hit stop sequence
    unknown,

    pub fn fromString(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
        // OpenAI variants
        if (std.mem.eql(u8, s, "stop")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
        if (std.mem.eql(u8, s, "length")) return .max_tokens;
        // Gemini variants
        if (std.mem.eql(u8, s, "STOP")) return .end_turn;
        if (std.mem.eql(u8, s, "MAX_TOKENS")) return .max_tokens;
        return .unknown;
    }
};

/// Token usage statistics
pub const UsageStats = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,

    pub fn total(self: UsageStats) u32 {
        return self.input_tokens + self.output_tokens;
    }

    /// Estimate cost in USD (varies by provider and model)
    pub fn estimateCost(self: UsageStats, input_price_per_mtok: f64, output_price_per_mtok: f64) f64 {
        const input_cost = (@as(f64, @floatFromInt(self.input_tokens)) / 1_000_000.0) * input_price_per_mtok;
        const output_cost = (@as(f64, @floatFromInt(self.output_tokens)) / 1_000_000.0) * output_price_per_mtok;
        return input_cost + output_cost;
    }
};

/// Metadata about the API response
pub const ResponseMetadata = struct {
    model: []const u8,
    provider: []const u8,
    turns_used: u32 = 1,
    execution_time_ms: u64,
    max_turns_reached: bool = false,
    stop_reason: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseMetadata) void {
        self.allocator.free(self.model);
        self.allocator.free(self.provider);
        if (self.stop_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// Complete AI response with message and metadata
pub const AIResponse = struct {
    message: AIMessage,
    usage: UsageStats,
    metadata: ResponseMetadata,

    /// All source URLs encountered during search (xAI Responses API `citations` field)
    /// Always returned by default when server-side tools are used
    citations: ?[][]const u8 = null,

    /// Structured inline citation annotations with positional data
    /// Available from xAI Responses API `output_text.annotations`
    inline_citations: ?[]InlineCitation = null,

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *AIResponse) void {
        self.message.deinit();
        self.metadata.deinit();
        if (self.citations) |citations| {
            if (self.allocator) |alloc| {
                for (citations) |url| alloc.free(url);
                alloc.free(citations);
            }
        }
        if (self.inline_citations) |ics| {
            if (self.allocator) |alloc| {
                for (ics) |*ic| {
                    @constCast(ic).deinit();
                }
                alloc.free(ics);
            }
        }
    }
};

/// GPT-5.2 Reasoning Effort levels
/// Controls how many reasoning tokens the model generates before producing a response
pub const ReasoningEffort = enum {
    /// No reasoning tokens - lowest latency (GPT-5.2 default)
    none,
    /// Minimal reasoning
    low,
    /// Balanced reasoning (GPT-5/5.1 default)
    medium,
    /// Thorough reasoning
    high,
    /// Maximum reasoning (GPT-5.2 only)
    xhigh,

    pub fn toString(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .none => "none",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }
};

/// GPT-5.2 Verbosity levels
/// Controls output token count - lower verbosity = more concise answers
pub const Verbosity = enum {
    /// Concise answers, minimal commentary
    low,
    /// Balanced (GPT-5.2 default)
    medium,
    /// Thorough explanations
    high,

    pub fn toString(self: Verbosity) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

/// Media resolution for Gemini image/video/document understanding
/// Controls quality vs token cost tradeoff for visual inputs
pub const MediaResolution = enum {
    low, // Lowest token cost, fastest
    medium, // Balanced quality and cost
    high, // Higher quality
    ultra_high, // Maximum quality (Gemini 3 only)

    pub fn toApiString(self: MediaResolution) []const u8 {
        return switch (self) {
            .low => "MEDIA_RESOLUTION_LOW",
            .medium => "MEDIA_RESOLUTION_MEDIUM",
            .high => "MEDIA_RESOLUTION_HIGH",
            .ultra_high => "MEDIA_RESOLUTION_ULTRA_HIGH",
        };
    }

    pub fn fromString(s: []const u8) ?MediaResolution {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "ultra_high") or std.mem.eql(u8, s, "ultra-high") or std.mem.eql(u8, s, "ultrahigh")) return .ultra_high;
        return null;
    }
};

/// Configuration for AI requests
pub const RequestConfig = struct {
    /// Model to use (provider-specific)
    model: []const u8,

    /// Maximum tokens to generate
    max_tokens: u32 = 64000,

    /// Sampling temperature (0.0 - 2.0)
    /// Note: Only supported with reasoning_effort = none for GPT-5.2
    temperature: f32 = 1.0,

    /// Top-p sampling
    /// Note: Only supported with reasoning_effort = none for GPT-5.2
    top_p: f32 = 1.0,

    /// Stop sequences
    stop_sequences: ?[]const []const u8 = null,

    /// Maximum number of turns for agentic loops
    max_turns: u32 = 100,

    /// Request timeout in milliseconds
    timeout_ms: u64 = 300_000, // 5 minutes default

    /// Enable SSE streaming response (provider sends events incrementally)
    stream: bool = false,

    /// System prompt (if supported)
    system_prompt: ?[]const u8 = null,

    /// Images for vision requests (multimodal)
    /// Supported by: OpenAI, Claude, Gemini, Grok
    images: ?[]const ImageInput = null,

    /// Tool definitions for function calling (client-side tools)
    /// Supported by: Claude, OpenAI, Gemini, Grok
    tools: ?[]const ToolDefinition = null,

    /// Tool choice control (Grok/OpenAI Responses API)
    /// auto = model decides, required = must call a tool, none = no tools
    tool_choice: ?ToolChoice = null,

    /// Force a specific function tool by name (used when tool_choice = .function)
    tool_choice_function: ?[]const u8 = null,

    /// Enable/disable parallel function calling (default: true on server)
    /// Set to false to force sequential tool calls
    parallel_tool_calls: ?bool = null,

    /// Restrict to specific function names (Gemini: allowedFunctionNames)
    /// Used with tool_choice = .required or .validated to limit which functions the model can call
    allowed_function_names: ?[]const []const u8 = null,

    /// Server-side tools (xAI: web_search, x_search, code_interpreter;
    /// Gemini: google_search, url_context, google_maps)
    server_tools: ?[]const ServerSideTool = null,

    /// Remote MCP tools — connect Grok to external MCP servers (xAI only)
    /// xAI manages the MCP server connection and tool execution
    mcp_tools: ?[]const McpToolConfig = null,

    /// Collection IDs for file_search tool (xAI Grok only)
    /// Adds {"type":"file_search","vector_store_ids":[...]} to tools array
    collection_ids: ?[]const []const u8 = null,

    /// Uploaded file IDs to attach to the message (xAI Grok only)
    /// Adds {"type":"input_file","file_id":"..."} to content array
    /// Triggers automatic attachment_search server-side tool
    file_ids: ?[]const []const u8 = null,

    /// Max results from collection search (default: 10)
    collection_max_results: u32 = 10,

    /// Google Maps grounding location (Gemini only)
    /// Latitude/longitude for location-aware queries
    maps_latitude: ?f64 = null,
    maps_longitude: ?f64 = null,

    /// Store conversation server-side for multi-turn via previous_response_id (xAI/OpenAI)
    store: ?bool = null,

    /// Limit server-side agentic loop turns (xAI Responses API max_turns parameter)
    /// Controls how many assistant/tool-call rounds xAI performs before returning
    server_max_turns: ?u32 = null,

    /// Include additional response data (xAI/OpenAI Responses API)
    /// e.g., "inline_citations", "web_search_call.action.sources",
    /// "code_interpreter_call.outputs", "file_search_call.results"
    include: ?[]const []const u8 = null,

    // ===========================================
    // GPT-5.2 specific options (OpenAI only)
    // ===========================================

    /// Reasoning effort level (GPT-5.2: none, low, medium, high, xhigh)
    /// Controls reasoning token generation. Default: none (lowest latency)
    reasoning_effort: ReasoningEffort = .none,

    /// Verbosity level (GPT-5.2: low, medium, high)
    /// Controls output conciseness. Default: medium
    verbosity: Verbosity = .medium,

    /// Previous response ID for multi-turn conversations
    /// Enables passing chain-of-thought between turns for improved intelligence
    previous_response_id: ?[]const u8 = null,

    /// Media resolution for Gemini image/video/document understanding
    /// Controls token cost vs quality for visual inputs (generationConfig.mediaResolution)
    media_resolution: ?MediaResolution = null,
};

/// Embedding task type for Gemini embeddings API
/// Optimizes embeddings for specific use cases
pub const EmbeddingTaskType = enum {
    semantic_similarity,
    classification,
    clustering,
    retrieval_document,
    retrieval_query,
    code_retrieval_query,
    question_answering,
    fact_verification,

    pub fn toApiString(self: EmbeddingTaskType) []const u8 {
        return switch (self) {
            .semantic_similarity => "SEMANTIC_SIMILARITY",
            .classification => "CLASSIFICATION",
            .clustering => "CLUSTERING",
            .retrieval_document => "RETRIEVAL_DOCUMENT",
            .retrieval_query => "RETRIEVAL_QUERY",
            .code_retrieval_query => "CODE_RETRIEVAL_QUERY",
            .question_answering => "QUESTION_ANSWERING",
            .fact_verification => "FACT_VERIFICATION",
        };
    }

    pub fn fromString(s: []const u8) ?EmbeddingTaskType {
        if (std.mem.eql(u8, s, "semantic_similarity") or std.mem.eql(u8, s, "SEMANTIC_SIMILARITY")) return .semantic_similarity;
        if (std.mem.eql(u8, s, "classification") or std.mem.eql(u8, s, "CLASSIFICATION")) return .classification;
        if (std.mem.eql(u8, s, "clustering") or std.mem.eql(u8, s, "CLUSTERING")) return .clustering;
        if (std.mem.eql(u8, s, "retrieval_document") or std.mem.eql(u8, s, "RETRIEVAL_DOCUMENT")) return .retrieval_document;
        if (std.mem.eql(u8, s, "retrieval_query") or std.mem.eql(u8, s, "RETRIEVAL_QUERY")) return .retrieval_query;
        if (std.mem.eql(u8, s, "code_retrieval_query") or std.mem.eql(u8, s, "CODE_RETRIEVAL_QUERY")) return .code_retrieval_query;
        if (std.mem.eql(u8, s, "question_answering") or std.mem.eql(u8, s, "QUESTION_ANSWERING")) return .question_answering;
        if (std.mem.eql(u8, s, "fact_verification") or std.mem.eql(u8, s, "FACT_VERIFICATION")) return .fact_verification;
        // Short aliases
        if (std.mem.eql(u8, s, "similarity")) return .semantic_similarity;
        if (std.mem.eql(u8, s, "search")) return .retrieval_query;
        if (std.mem.eql(u8, s, "document")) return .retrieval_document;
        if (std.mem.eql(u8, s, "code")) return .code_retrieval_query;
        if (std.mem.eql(u8, s, "qa")) return .question_answering;
        if (std.mem.eql(u8, s, "fact")) return .fact_verification;
        return null;
    }
};

/// Single embedding result (array of f64 values)
pub const EmbeddingResult = struct {
    values: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EmbeddingResult) void {
        self.allocator.free(self.values);
    }
};

/// Conversation context for multi-turn interactions
pub const ConversationContext = struct {
    id: []const u8,
    messages: std.ArrayList(AIMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ConversationContext {
        const id = try generateId(allocator, io);
        return ConversationContext{
            .id = id,
            .messages = std.ArrayList(AIMessage).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConversationContext) void {
        self.allocator.free(self.id);
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);
    }

    pub fn addMessage(self: *ConversationContext, message: AIMessage) !void {
        try self.messages.append(self.allocator, message);
    }

    pub fn getLastMessage(self: *ConversationContext) ?*AIMessage {
        if (self.messages.items.len == 0) return null;
        return &self.messages.items[self.messages.items.len - 1];
    }

    pub fn totalTokens(self: *ConversationContext) u32 {
        var total: u32 = 0;
        for (self.messages.items) |msg| {
            // Rough estimate: 1 token ≈ 4 characters
            total += @intCast(msg.content.len / 4);
        }
        return total;
    }
};

/// Callback type for streaming AI responses.
/// Called once per token/chunk. Return false to stop the stream.
pub const StreamCallback = *const fn (
    /// The text content delta (partial token/chunk)
    text: []const u8,
    /// User-provided context pointer
    context: ?*anyopaque,
) bool;

/// Utility: Generate a unique ID for messages/conversations (pure Zig — no libc)
/// Uses io.random() for cryptographically secure randomness
pub fn generateId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var uuid_bytes: [16]u8 = undefined;
    io.random(&uuid_bytes);
    return try std.fmt.allocPrint(allocator, "{x:0>32}", .{std.mem.readInt(u128, &uuid_bytes, .big)});
}

/// Utility: Escape JSON string
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\x08' => try result.appendSlice(allocator, "\\b"),
            '\x0C' => try result.appendSlice(allocator, "\\f"),
            else => {
                if (char < 0x20) {
                    // Control character - escape as \uXXXX
                    const hex_str = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{char});
                    defer allocator.free(hex_str);
                    try result.appendSlice(allocator, hex_str);
                } else {
                    try result.append(allocator, char);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Utility: Build Authorization header value
pub fn buildAuthHeader(allocator: std.mem.Allocator, api_key: []const u8, scheme: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ scheme, api_key });
}

/// Utility: Parse error from API response
pub fn parseApiError(response_body: []const u8) AIError {
    // Try to parse JSON error response
    if (std.mem.indexOf(u8, response_body, "rate_limit")) |_| {
        return AIError.RateLimitExceeded;
    }
    if (std.mem.indexOf(u8, response_body, "quota")) |_| {
        return AIError.QuotaExceeded;
    }
    if (std.mem.indexOf(u8, response_body, "authentication") != null or
        std.mem.indexOf(u8, response_body, "unauthorized") != null) {
        return AIError.AuthenticationFailed;
    }
    if (std.mem.indexOf(u8, response_body, "invalid_request")) |_| {
        return AIError.InvalidRequest;
    }

    return AIError.ApiRequestFailed;
}

/// Load an image from a file and return base64-encoded data
pub fn loadImageFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ImageInput {
    // Split path into directory and filename
    const dir_path = std.fs.path.dirname(path) orelse return error.FileOpenFailed;
    const file_name = std.fs.path.basename(path);

    // Open directory and read file contents
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.FileOpenFailed;
    defer dir.close(io);

    const content = dir.readFileAlloc(io, file_name, allocator, .unlimited) catch return error.FileReadFailed;
    defer allocator.free(content);

    // Base64 encode
    const base64_len = std.base64.standard.Encoder.calcSize(content.len);
    const base64_data = try allocator.alloc(u8, base64_len);
    _ = std.base64.standard.Encoder.encode(base64_data, content);

    return ImageInput{
        .data = base64_data,
        .media_type = ImageInput.mimeTypeFromPath(path),
        .allocator = allocator,
    };
}

test "escapeJsonString" {
    const allocator = std.testing.allocator;

    const input = "Hello \"World\"\nNew line\tTab";
    const escaped = try escapeJsonString(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("Hello \\\"World\\\"\\nNew line\\tTab", escaped);
}

test "UsageStats.total" {
    const stats = UsageStats{
        .input_tokens = 100,
        .output_tokens = 50,
    };

    try std.testing.expectEqual(@as(u32, 150), stats.total());
}

test "UsageStats.estimateCost" {
    const stats = UsageStats{
        .input_tokens = 1_000_000,
        .output_tokens = 500_000,
    };

    // Claude Sonnet pricing example: $3/MTok input, $15/MTok output
    const cost = stats.estimateCost(3.0, 15.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), cost, 0.01);
}
