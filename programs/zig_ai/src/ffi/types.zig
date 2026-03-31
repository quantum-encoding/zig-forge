// FFI Types - C-compatible structures for cross-language interop
// All pointers are heap-allocated and must be freed with corresponding free functions

const std = @import("std");

// ============================================================================
// String and Buffer Types
// ============================================================================

/// C-compatible string (null-terminated, with length for convenience)
pub const CString = extern struct {
    ptr: ?[*:0]const u8,
    len: usize,

    pub fn fromSlice(s: []const u8) CString {
        if (s.len == 0) return .{ .ptr = null, .len = 0 };
        // Assume s is already null-terminated if passed from Zig
        return .{ .ptr = @ptrCast(s.ptr), .len = s.len };
    }

    pub fn toSlice(self: CString) []const u8 {
        if (self.ptr) |p| {
            return p[0..self.len];
        }
        return "";
    }
};

/// Mutable C string
pub const CMutString = extern struct {
    ptr: ?[*]u8,
    len: usize,
    capacity: usize,
};

/// Binary buffer (for images, audio, etc.)
pub const CBuffer = extern struct {
    ptr: ?[*]u8,
    len: usize,

    pub fn toSlice(self: CBuffer) []u8 {
        if (self.ptr) |p| {
            return p[0..self.len];
        }
        return &[_]u8{};
    }
};

// ============================================================================
// Result Types
// ============================================================================

/// Generic result with error code
pub const CResult = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
};

/// Result containing a string
pub const CStringResult = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    value: CString,
};

/// Result containing a buffer
pub const CBufferResult = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    value: CBuffer,
};

// ============================================================================
// Provider Enums
// ============================================================================

/// Text AI providers
pub const CTextProvider = enum(i32) {
    claude = 0,
    deepseek = 1,
    gemini = 2,
    grok = 3,
    vertex = 4,
    openai = 5,
    unknown = -1,
};

/// Image generation providers
pub const CImageProvider = enum(i32) {
    dalle3 = 0,
    dalle2 = 1,
    gpt_image = 2,
    gpt_image_15 = 3,
    grok = 4,
    imagen_genai = 5,
    imagen_vertex = 6,
    gemini_flash = 7,
    gemini_pro = 8,
    unknown = -1,
};

/// Video generation providers
pub const CVideoProvider = enum(i32) {
    sora = 0,
    veo = 1,
    grok_video = 2,
    unknown = -1,
};

/// Music generation providers
pub const CMusicProvider = enum(i32) {
    lyria = 0,
    lyria_realtime = 1,
    unknown = -1,
};

/// Image quality settings
pub const CQuality = enum(i32) {
    auto = 0,
    standard = 1,
    hd = 2,
    high = 3,
    medium = 4,
    low = 5,
    premium = 6,
};

/// Image style settings
pub const CStyle = enum(i32) {
    vivid = 0,
    natural = 1,
};

/// Image background mode
pub const CBackground = enum(i32) {
    @"opaque" = 0,
    transparent = 1,
};

/// Input fidelity for image editing
pub const CInputFidelity = enum(i32) {
    low = 0,
    high = 1,
};

/// Media format
pub const CMediaFormat = enum(i32) {
    png = 0,
    jpeg = 1,
    webp = 2,
    gif = 3,
    mp4 = 4,
    wav = 5,
    unknown = -1,
};

/// Lyria session state
pub const CLyriaState = enum(i32) {
    disconnected = 0,
    connecting = 1,
    setup = 2,
    ready = 3,
    playing = 4,
    paused = 5,
    failed = 6,
};

// ============================================================================
// Template Types
// ============================================================================

/// Template parameter key-value pair
pub const CTemplateParam = extern struct {
    key: CString,
    value: CString,
};

// ============================================================================
// Configuration Structures
// ============================================================================

/// Text AI configuration
pub const CTextConfig = extern struct {
    provider: CTextProvider,
    model: CString,
    temperature: f32,
    max_tokens: u32,
    system_prompt: CString,
    api_key: CString,
    template_name: CString,
    template_params: ?[*]const CTemplateParam,
    template_param_count: u32,
};

/// Media configuration (API keys + storage)
pub const CMediaConfig = extern struct {
    openai_api_key: CString,
    xai_api_key: CString,
    genai_api_key: CString,
    vertex_project_id: CString,
    vertex_location: CString,
    media_store_path: CString,
    output_dir: CString,
    disable_central_store: bool,

    /// Map CMediaConfig to internal MediaConfig (shared by all FFI modules)
    pub fn toMediaConfig(self: *const CMediaConfig) @import("../media/types.zig").MediaConfig {
        return .{
            .openai_api_key = if (self.openai_api_key.len > 0) self.openai_api_key.toSlice() else null,
            .xai_api_key = if (self.xai_api_key.len > 0) self.xai_api_key.toSlice() else null,
            .genai_api_key = if (self.genai_api_key.len > 0) self.genai_api_key.toSlice() else null,
            .vertex_project_id = if (self.vertex_project_id.len > 0) self.vertex_project_id.toSlice() else null,
            .vertex_location = if (self.vertex_location.len > 0) self.vertex_location.toSlice() else "us-central1",
            .media_store_path = if (self.media_store_path.len > 0) self.media_store_path.toSlice() else null,
            .output_dir = if (self.output_dir.len > 0) self.output_dir.toSlice() else null,
            .disable_central_store = self.disable_central_store,
        };
    }
};

/// Image request
pub const CImageRequest = extern struct {
    prompt: CString,
    provider: CImageProvider,
    count: u8,
    size: CString,
    aspect_ratio: CString,
    quality: CQuality,
    style: CStyle,
    output_path: CString,
    background: CBackground,
};

/// Image edit request (multipart upload with input images)
pub const CEditRequest = extern struct {
    prompt: CString,
    image_paths: [*]const CString,
    image_count: u8,
    model: CString,
    quality: CQuality,
    size: CString,
    count: u8,
    input_fidelity: CInputFidelity,
    background: CBackground,
    output_path: CString,
};

/// Video request
pub const CVideoRequest = extern struct {
    prompt: CString,
    provider: CVideoProvider,
    model: CString,
    duration_seconds: u8,
    size: CString,
    aspect_ratio: CString,
    resolution: CString,
    audio: bool,
    output_path: CString,
};

/// Music request
pub const CMusicRequest = extern struct {
    prompt: CString,
    provider: CMusicProvider,
    count: u8,
    duration_seconds: u32,
    negative_prompt: CString,
    seed: u64,
    bpm: u16,
    output_path: CString,
};

/// Lyria streaming configuration
pub const CLyriaConfig = extern struct {
    bpm: u16,
    temperature: f32,
    guidance: f32,
    density: f32,
    brightness: f32,
    mute_bass: bool,
    mute_drums: bool,
    only_bass_and_drums: bool,
};

/// Weighted prompt for Lyria streaming
pub const CWeightedPrompt = extern struct {
    text: CString,
    weight: f32,
};

// ============================================================================
// Response Structures
// ============================================================================

/// Token usage information
pub const CTokenUsage = extern struct {
    input_tokens: u32,
    output_tokens: u32,
    total_tokens: u32,
    cost_usd: f64,
};

/// Text AI response
pub const CTextResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    content: CString,
    usage: CTokenUsage,
    model_used: CString,
    provider: CTextProvider,
};

/// Single generated media item
pub const CGeneratedMedia = extern struct {
    data: CBuffer,
    format: CMediaFormat,
    local_path: CString,
    store_path: CString,
    revised_prompt: CString,
};

/// Array of generated media
pub const CMediaArray = extern struct {
    items: ?[*]CGeneratedMedia,
    count: usize,
};

/// Image response
pub const CImageResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    job_id: CString,
    provider: CImageProvider,
    original_prompt: CString,
    revised_prompt: CString,
    images: CMediaArray,
    processing_time_ms: u64,
    model_used: CString,
};

/// Video response
pub const CVideoResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    job_id: CString,
    provider: CVideoProvider,
    original_prompt: CString,
    videos: CMediaArray,
    processing_time_ms: u64,
    model_used: CString,
};

/// Music response
pub const CMusicResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    job_id: CString,
    provider: CMusicProvider,
    original_prompt: CString,
    tracks: CMediaArray,
    processing_time_ms: u64,
    model_used: CString,
    bpm: u16,
};

/// Audio format info for streaming
pub const CAudioFormat = extern struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
};

// ============================================================================
// Batch Processing Types
// ============================================================================

/// Batch request item
pub const CBatchRequest = extern struct {
    id: u32,
    provider: CTextProvider,
    prompt: CString,
    temperature: f32,
    max_tokens: u32,
    system_prompt: CString,
};

/// Batch result item
pub const CBatchResult = extern struct {
    id: u32,
    provider: CTextProvider,
    prompt: CString,
    response: CString,
    input_tokens: u32,
    output_tokens: u32,
    cost_usd: f64,
    execution_time_ms: u64,
    error_message: CString,
    success: bool,
};

/// Batch results array
pub const CBatchResults = extern struct {
    items: ?[*]CBatchResult,
    count: usize,
    total_cost_usd: f64,
    total_time_ms: u64,
};

/// Batch configuration
pub const CBatchConfig = extern struct {
    concurrency: u32,
    retry_count: u32,
    timeout_ms: u64,
    continue_on_error: bool,
};

// ============================================================================
// Handle Types (opaque pointers)
// ============================================================================

/// Opaque handle for text session
pub const CTextSession = opaque {};

/// Opaque handle for image generation session
pub const CImageSession = opaque {};

/// Image session configuration (session-based API for cross-language consumers)
pub const CImageSessionConfig = extern struct {
    provider: CImageProvider,
    size: CString, // e.g. "1024x1024", empty = provider default
    quality: CQuality,
    style: CStyle,
    background: CBackground,
    openai_api_key: CString,
    xai_api_key: CString,
    genai_api_key: CString,
    vertex_project_id: CString,
    vertex_location: CString,
};

/// Simplified image response with base64 data (for session API)
pub const CImageSessionResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    image_data: CString, // base64-encoded PNG/JPEG/WebP
    revised_prompt: CString,
    format: CMediaFormat,
};

/// Opaque handle for Lyria streaming session
pub const CLyriaSession = opaque {};

/// Opaque handle for voice agent session
pub const CVoiceSession = opaque {};

/// Voice persona
pub const CVoice = enum(i32) {
    ara = 0,
    rex = 1,
    sal = 2,
    eve = 3,
    leo = 4,
};

/// Voice audio encoding
pub const CVoiceEncoding = enum(i32) {
    pcm16 = 0,
    pcmu = 1,
    pcma = 2,
};

/// Voice session state
pub const CVoiceState = enum(i32) {
    disconnected = 0,
    connecting = 1,
    configuring = 2,
    ready = 3,
    responding = 4,
    tool_calling = 5,
    failed = 6,
};

/// Voice session configuration
pub const CVoiceConfig = extern struct {
    voice: CVoice,
    instructions: CString,
    encoding: CVoiceEncoding,
    sample_rate: u32,
};

/// Voice tool call
pub const CVoiceToolCall = extern struct {
    call_id: CString,
    name: CString,
    arguments: CString,
};

/// Voice response
pub const CVoiceResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    transcript: CString,
    audio_data: CBuffer,
    tool_calls: ?[*]CVoiceToolCall,
    tool_call_count: usize,
    processing_time_ms: u64,
};

/// Opaque handle for batch executor
pub const CBatchExecutor = opaque {};

// ============================================================================
// Agent Types
// ============================================================================

/// Opaque handle for agent session
pub const CAgentSession = opaque {};

/// Agent configuration (flat struct for C consumers)
pub const CAgentConfig = extern struct {
    provider: CString, // "claude", "gemini", "openai", "grok"
    model: CString, // null = provider default
    sandbox_root: CString, // required
    system_prompt: CString, // null = default
    api_key: CString, // null = use env var
    max_tokens: u32, // 0 = default (32768)
    max_turns: u32, // 0 = default (50)
    temperature: f32, // <0 = default (0.7)
};

/// Agent event types (flattened from Zig union)
pub const CAgentEventType = enum(i32) {
    turn_start = 0,
    tool_start = 1,
    tool_complete = 2,
    turn_complete = 3,
};

/// Agent event data (flat struct)
pub const CAgentEvent = extern struct {
    type: CAgentEventType,
    turn: u32, // turn_start, turn_complete
    tool_name: CString, // tool_start, tool_complete
    tool_reason: CString, // tool_start (may be null)
    tool_success: bool, // tool_complete
    duration_ms: u64, // tool_complete
    has_tool_calls: bool, // turn_complete
};

/// Agent execution result
pub const CAgentResult = extern struct {
    success: bool,
    final_response: CString,
    error_message: CString, // null on success
    turns_used: u32,
    tool_calls_made: u32,
    input_tokens: u32,
    output_tokens: u32,
};

/// Event callback type
pub const CAgentEventCallback = ?*const fn (*const CAgentEvent, ?*anyopaque) callconv(.c) void;

// ============================================================================
// Structured Output Types (runtime schema)
// ============================================================================

/// Structured output request with arbitrary JSON schema
pub const CStructuredRequest = extern struct {
    prompt: CString,
    schema_json: CString, // Raw JSON Schema string (the "schema" object)
    schema_name: CString, // Identifier for the schema (e.g. "product-listing")
    provider: CTextProvider, // Which AI provider to use
    model: CString, // Model override (empty = provider default)
    system_prompt: CString, // System instruction (empty = none)
    api_key: CString, // API key (empty = read from env var)
    max_tokens: u32, // 0 = default (4096)
};

/// Structured output response
pub const CStructuredResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    json_output: CString, // The structured JSON matching the schema
    input_tokens: u32,
    output_tokens: u32,
};

// ============================================================================
// Research Types
// ============================================================================

/// Research mode
pub const CResearchMode = enum(i32) {
    web_search = 0,
    deep_research = 1,
};

/// Research response
pub const CResearchResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    content: CString,
    sources_json: CString, // JSON array of {title, uri} objects
    input_tokens: u32,
    output_tokens: u32,
};

// ============================================================================
// Search Types (xAI Grok Web Search / X Search)
// ============================================================================

/// Search mode
pub const CSearchMode = enum(i32) {
    web_search = 0,
    x_search = 1,
};

/// Search response
pub const CSearchResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    content: CString,
    sources_json: CString, // JSON array of {title, uri} objects
    input_tokens: u32,
    output_tokens: u32,
    response_id: CString,
};

// ============================================================================
// Batch API Types (Anthropic Message Batches)
// ============================================================================

/// Batch processing status
pub const CBatchApiStatus = enum(i32) {
    in_progress = 0,
    canceling = 1,
    ended = 2,
};

/// Batch info response
pub const CBatchApiInfo = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    batch_id: CString,
    processing_status: CBatchApiStatus,
    processing: u32,
    succeeded: u32,
    errored: u32,
    canceled: u32,
    expired: u32,
    created_at: CString,
    results_url: CString,
};

// ============================================================================
// Extended Text Send Options (multimodal, server tools, files, collections)
// ============================================================================

/// Extended options for text send (passed to zig_ai_text_send_ex)
/// All pointer fields are optional — null/0 = not used
pub const CTextSendOptions = extern struct {
    // Image paths for vision input
    image_paths: ?[*]const CString = null,
    image_path_count: u32 = 0,

    // xAI uploaded file IDs for attachment_search
    file_ids: ?[*]const CString = null,
    file_id_count: u32 = 0,

    // xAI collection IDs for file_search
    collection_ids: ?[*]const CString = null,
    collection_id_count: u32 = 0,
    collection_max_results: u32 = 10,

    // xAI server-side tools (boolean flags)
    enable_web_search: bool = false,
    enable_x_search: bool = false,
    enable_code_interpreter: bool = false,

    // Model override (empty = use session default)
    model: CString = .{ .ptr = null, .len = 0 },
};

// ============================================================================
// TTS Types (Text-to-Speech)
// ============================================================================

/// TTS provider
pub const CTTSProvider = enum(i32) {
    openai = 0,
    google = 1,
};

/// TTS request (string-based voice/model for maximum flexibility)
pub const CTTSRequest = extern struct {
    text: CString,
    voice: CString, // "coral", "alloy", etc. (OpenAI) or "kore", "puck" etc. (Google)
    model: CString, // "gpt-4o-mini-tts", "tts-1", "tts-1-hd" (OpenAI) or "flash", "pro" (Google)
    format: CString, // "mp3", "opus", "aac", "flac", "wav", "pcm" (OpenAI only; Google = WAV)
    instructions: CString, // Speaking style instructions (gpt-4o-mini-tts only)
    speed: f32, // 0.25-4.0 (OpenAI only, 0 = default 1.0)
    api_key: CString, // Empty = read from env var
};

/// TTS response
pub const CTTSResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    audio_data: CBuffer, // Raw audio bytes
    format: CString, // Actual output format ("mp3", "wav", etc.)
    sample_rate: u32, // Sample rate (24000 for Google, 0 = unknown for OpenAI)
};

// ============================================================================
// STT Types (Speech-to-Text)
// ============================================================================

/// STT request
pub const CSTTRequest = extern struct {
    audio_data: CBuffer, // Raw audio file bytes
    filename: CString, // Original filename (for MIME type detection)
    model: CString, // "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"
    response_format: CString, // "json", "text", "srt", "verbose_json", "vtt"
    language: CString, // ISO 639-1 code (e.g. "en", "es")
    prompt: CString, // Context hint
    translate: bool, // Translate to English (whisper-1 only)
    api_key: CString, // Empty = read from env var
};

/// STT response
pub const CSTTResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    text: CString, // Transcribed/translated text
    language: CString, // Detected language (null if unavailable)
    duration: f64, // Audio duration in seconds (0 if unavailable)
};

// ============================================================================
// File Types (xAI Files API)
// ============================================================================

/// File upload/info response
pub const CFileResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    file_id: CString,
    filename: CString,
    bytes: u64,
    purpose: CString,
};

// ============================================================================
// Gemini Live Types (real-time WebSocket streaming)
// ============================================================================

/// Opaque handle for Gemini Live session
pub const CLiveSession = opaque {};

/// Live response modality
pub const CLiveModality = enum(i32) {
    text = 0,
    audio = 1,
};

/// Gemini Live voice presets
pub const CLiveVoice = enum(i32) {
    none = -1,
    kore = 0,
    charon = 1,
    fenrir = 2,
    aoede = 3,
    puck = 4,
    leda = 5,
    orus = 6,
    zephyr = 7,
};

/// Gemini Live session state
pub const CLiveSessionState = enum(i32) {
    disconnected = 0,
    connecting = 1,
    setup_sent = 2,
    ready = 3,
    responding = 4,
    tool_calling = 5,
    failed = 6,
};

/// Gemini Live session configuration
pub const CLiveConfig = extern struct {
    model: CString,
    modality: CLiveModality,
    system_instruction: CString,
    voice: CLiveVoice,
    temperature: f32,
    context_compression: bool,
    output_transcription: bool,
    google_search: bool,
    thinking_budget: u32, // 0 = disabled
};

/// Gemini Live function call
pub const CLiveFunctionCall = extern struct {
    id: CString,
    name: CString,
    args: CString,
};

/// Gemini Live response
pub const CLiveResponse = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    text: CString,
    audio_data: CBuffer,
    output_transcript: CString,
    function_calls: ?[*]CLiveFunctionCall,
    function_call_count: usize,
    processing_time_ms: u64,
    total_tokens: u32,
};

// ============================================================================
// Orchestrator Types
// ============================================================================

/// Orchestrator task status
pub const CTaskStatus = enum(i32) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    skipped = 4,
};

/// Orchestrator event types
pub const COrchestratorEventType = enum(i32) {
    phase_start = 0,
    architect_turn = 1,
    plan_accepted = 2,
    worker_start = 3,
    worker_complete = 4,
    worker_skipped = 5,
    cost_update = 6,
    orchestration_complete = 7,
};

/// Orchestrator event data (flat struct for C consumers)
pub const COrchestratorEvent = extern struct {
    type: COrchestratorEventType,
    phase: CString, // phase_start
    turn: u32, // architect_turn
    task_count: u32, // plan_accepted
    execution_order: CString, // plan_accepted
    task_id: CString, // worker_start, worker_complete, worker_skipped
    provider: CString, // worker_start
    success: bool, // worker_complete, orchestration_complete
    duration_ms: u64, // worker_complete
    reason: CString, // worker_skipped
    total_cost_usd: f64, // cost_update
};

/// Orchestrator configuration (flat struct for C consumers)
pub const COrchestratorConfig = extern struct {
    sandbox_root: CString, // required
    architect_provider: CString, // "claude", "gemini", etc. (default: "claude")
    architect_model: CString, // null = provider default
    architect_max_turns: u32, // 0 = default (30)
    worker_provider: CString, // default worker provider (default: "claude")
    worker_model: CString, // default worker model
    worker_max_turns: u32, // 0 = default (25)
    save_plan: bool, // persist plan to disk
    plan_path: CString, // null = sandbox_root/plan.json
    audit_log: bool, // enable JSONL audit log
    audit_path: CString, // null = sandbox_root/audit.jsonl
    max_tasks: u32, // 0 = default (20)
    max_cost_usd: f64, // 0 = unlimited
    api_key: CString, // null = use env var
};

/// Orchestrator execution result
pub const COrchestratorResult = extern struct {
    success: bool,
    error_code: i32,
    error_message: CString,
    tasks_completed: u32,
    tasks_failed: u32,
    tasks_skipped: u32,
    total_input_tokens: u32,
    total_output_tokens: u32,
    total_cost_usd: f64,
    plan_path: CString,
    summary: CString,
};

/// Orchestrator event callback type
pub const COrchestratorEventCallback = ?*const fn (*const COrchestratorEvent, ?*anyopaque) callconv(.c) void;

// ============================================================================
// Error Codes
// ============================================================================

pub const ErrorCode = struct {
    pub const SUCCESS: i32 = 0;
    pub const INVALID_ARGUMENT: i32 = 1;
    pub const OUT_OF_MEMORY: i32 = 2;
    pub const NETWORK_ERROR: i32 = 3;
    pub const API_ERROR: i32 = 4;
    pub const AUTH_ERROR: i32 = 5;
    pub const TIMEOUT: i32 = 6;
    pub const NOT_CONNECTED: i32 = 7;
    pub const ALREADY_CONNECTED: i32 = 8;
    pub const INVALID_STATE: i32 = 9;
    pub const IO_ERROR: i32 = 10;
    pub const PARSE_ERROR: i32 = 11;
    pub const PROVIDER_NOT_AVAILABLE: i32 = 12;
    pub const UNKNOWN_ERROR: i32 = -1;
};
