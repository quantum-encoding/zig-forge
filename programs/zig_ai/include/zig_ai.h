/**
 * zig_ai - Unified AI Library for Text, Image, Video, and Music Generation
 *
 * C Header for FFI bindings
 *
 * Build:
 *   zig build -Dlib          # Build shared library
 *   zig build -Dlib -Dstatic # Build static library
 *
 * Link:
 *   -lzig_ai -L/path/to/zig-out/lib
 */

#ifndef ZIG_AI_H
#define ZIG_AI_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Basic Types
 * ============================================================================ */

/** C-compatible string (null-terminated with length) */
typedef struct {
    const char* ptr;
    size_t len;
} ZigAiString;

/** Binary buffer */
typedef struct {
    uint8_t* ptr;
    size_t len;
} ZigAiBuffer;

/* ============================================================================
 * Error Codes
 * ============================================================================ */

#define ZIG_AI_SUCCESS              0
#define ZIG_AI_INVALID_ARGUMENT     1
#define ZIG_AI_OUT_OF_MEMORY        2
#define ZIG_AI_NETWORK_ERROR        3
#define ZIG_AI_API_ERROR            4
#define ZIG_AI_AUTH_ERROR           5
#define ZIG_AI_TIMEOUT              6
#define ZIG_AI_NOT_CONNECTED        7
#define ZIG_AI_ALREADY_CONNECTED    8
#define ZIG_AI_INVALID_STATE        9
#define ZIG_AI_IO_ERROR             10
#define ZIG_AI_PARSE_ERROR          11
#define ZIG_AI_PROVIDER_NOT_AVAILABLE 12
#define ZIG_AI_UNKNOWN_ERROR        -1

/* ============================================================================
 * Provider Enums
 * ============================================================================ */

typedef enum {
    ZIG_AI_TEXT_CLAUDE = 0,
    ZIG_AI_TEXT_DEEPSEEK = 1,
    ZIG_AI_TEXT_GEMINI = 2,
    ZIG_AI_TEXT_GROK = 3,
    ZIG_AI_TEXT_VERTEX = 4,
    ZIG_AI_TEXT_UNKNOWN = -1
} ZigAiTextProvider;

typedef enum {
    ZIG_AI_IMAGE_DALLE3 = 0,
    ZIG_AI_IMAGE_DALLE2 = 1,
    ZIG_AI_IMAGE_GPT_IMAGE = 2,
    ZIG_AI_IMAGE_GPT_IMAGE_15 = 3,
    ZIG_AI_IMAGE_GROK = 4,
    ZIG_AI_IMAGE_IMAGEN_GENAI = 5,
    ZIG_AI_IMAGE_IMAGEN_VERTEX = 6,
    ZIG_AI_IMAGE_GEMINI_FLASH = 7,
    ZIG_AI_IMAGE_GEMINI_PRO = 8,
    ZIG_AI_IMAGE_UNKNOWN = -1
} ZigAiImageProvider;

typedef enum {
    ZIG_AI_VIDEO_SORA = 0,
    ZIG_AI_VIDEO_VEO = 1,
    ZIG_AI_VIDEO_UNKNOWN = -1
} ZigAiVideoProvider;

typedef enum {
    ZIG_AI_MUSIC_LYRIA = 0,
    ZIG_AI_MUSIC_LYRIA_REALTIME = 1,
    ZIG_AI_MUSIC_UNKNOWN = -1
} ZigAiMusicProvider;

typedef enum {
    ZIG_AI_QUALITY_AUTO = 0,
    ZIG_AI_QUALITY_STANDARD = 1,
    ZIG_AI_QUALITY_HD = 2,
    ZIG_AI_QUALITY_HIGH = 3,
    ZIG_AI_QUALITY_MEDIUM = 4,
    ZIG_AI_QUALITY_LOW = 5,
    ZIG_AI_QUALITY_PREMIUM = 6
} ZigAiQuality;

typedef enum {
    ZIG_AI_STYLE_VIVID = 0,
    ZIG_AI_STYLE_NATURAL = 1
} ZigAiStyle;

typedef enum {
    ZIG_AI_BG_OPAQUE = 0,
    ZIG_AI_BG_TRANSPARENT = 1
} ZigAiBackground;

typedef enum {
    ZIG_AI_FIDELITY_LOW = 0,
    ZIG_AI_FIDELITY_HIGH = 1
} ZigAiInputFidelity;

typedef enum {
    ZIG_AI_FORMAT_PNG = 0,
    ZIG_AI_FORMAT_JPEG = 1,
    ZIG_AI_FORMAT_WEBP = 2,
    ZIG_AI_FORMAT_GIF = 3,
    ZIG_AI_FORMAT_MP4 = 4,
    ZIG_AI_FORMAT_WAV = 5,
    ZIG_AI_FORMAT_UNKNOWN = -1
} ZigAiMediaFormat;

typedef enum {
    ZIG_AI_LYRIA_DISCONNECTED = 0,
    ZIG_AI_LYRIA_CONNECTING = 1,
    ZIG_AI_LYRIA_SETUP = 2,
    ZIG_AI_LYRIA_READY = 3,
    ZIG_AI_LYRIA_PLAYING = 4,
    ZIG_AI_LYRIA_PAUSED = 5,
    ZIG_AI_LYRIA_FAILED = 6
} ZigAiLyriaState;

/* ============================================================================
 * Configuration Structures
 * ============================================================================ */

/** Template parameter key-value pair */
typedef struct {
    ZigAiString key;
    ZigAiString value;
} ZigAiTemplateParam;

typedef struct {
    ZigAiTextProvider provider;
    ZigAiString model;
    float temperature;
    uint32_t max_tokens;
    ZigAiString system_prompt;
    ZigAiString api_key;
    ZigAiString template_name;
    const ZigAiTemplateParam* template_params;
    uint32_t template_param_count;
} ZigAiTextConfig;

typedef struct {
    ZigAiString openai_api_key;
    ZigAiString xai_api_key;
    ZigAiString genai_api_key;
    ZigAiString vertex_project_id;
    ZigAiString vertex_location;
    ZigAiString media_store_path;
    ZigAiString output_dir;
    bool disable_central_store;
} ZigAiMediaConfig;

typedef struct {
    ZigAiString prompt;
    ZigAiImageProvider provider;
    uint8_t count;
    ZigAiString size;
    ZigAiString aspect_ratio;
    ZigAiQuality quality;
    ZigAiStyle style;
    ZigAiString output_path;
    ZigAiBackground background;
} ZigAiImageRequest;

typedef struct {
    ZigAiString prompt;
    const ZigAiString* image_paths;
    uint8_t image_count;
    ZigAiString model;
    ZigAiQuality quality;
    ZigAiString size;
    uint8_t count;
    ZigAiInputFidelity input_fidelity;
    ZigAiBackground background;
    ZigAiString output_path;
} ZigAiEditRequest;

typedef struct {
    ZigAiString prompt;
    ZigAiVideoProvider provider;
    ZigAiString model;
    uint8_t duration_seconds;
    ZigAiString size;
    ZigAiString aspect_ratio;
    ZigAiString resolution;
    bool audio;
    ZigAiString output_path;
} ZigAiVideoRequest;

typedef struct {
    ZigAiString prompt;
    ZigAiMusicProvider provider;
    uint8_t count;
    uint32_t duration_seconds;
    ZigAiString negative_prompt;
    uint64_t seed;
    uint16_t bpm;
    ZigAiString output_path;
} ZigAiMusicRequest;

typedef struct {
    uint16_t bpm;
    float temperature;
    float guidance;
    float density;
    float brightness;
    bool mute_bass;
    bool mute_drums;
    bool only_bass_and_drums;
} ZigAiLyriaConfig;

typedef struct {
    ZigAiString text;
    float weight;
} ZigAiWeightedPrompt;

/* ============================================================================
 * Response Structures
 * ============================================================================ */

typedef struct {
    uint32_t input_tokens;
    uint32_t output_tokens;
    uint32_t total_tokens;
    double cost_usd;
} ZigAiTokenUsage;

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString content;
    ZigAiTokenUsage usage;
    ZigAiString model_used;
    ZigAiTextProvider provider;
} ZigAiTextResponse;

typedef struct {
    ZigAiBuffer data;
    ZigAiMediaFormat format;
    ZigAiString local_path;
    ZigAiString store_path;
    ZigAiString revised_prompt;
} ZigAiGeneratedMedia;

typedef struct {
    ZigAiGeneratedMedia* items;
    size_t count;
} ZigAiMediaArray;

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString job_id;
    ZigAiImageProvider provider;
    ZigAiString original_prompt;
    ZigAiString revised_prompt;
    ZigAiMediaArray images;
    uint64_t processing_time_ms;
    ZigAiString model_used;
} ZigAiImageResponse;

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString job_id;
    ZigAiVideoProvider provider;
    ZigAiString original_prompt;
    ZigAiMediaArray videos;
    uint64_t processing_time_ms;
    ZigAiString model_used;
} ZigAiVideoResponse;

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString job_id;
    ZigAiMusicProvider provider;
    ZigAiString original_prompt;
    ZigAiMediaArray tracks;
    uint64_t processing_time_ms;
    ZigAiString model_used;
    uint16_t bpm;
} ZigAiMusicResponse;

typedef struct {
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t bits_per_sample;
} ZigAiAudioFormat;

/* ============================================================================
 * Agent Types
 * ============================================================================ */

typedef struct ZigAiAgentSession ZigAiAgentSession;

typedef struct {
    ZigAiString provider;       /* "claude", "gemini", "openai", "grok" */
    ZigAiString model;          /* NULL = provider default */
    ZigAiString sandbox_root;   /* required */
    ZigAiString system_prompt;  /* NULL = default */
    ZigAiString api_key;        /* NULL = use env var */
    uint32_t max_tokens;        /* 0 = default (32768) */
    uint32_t max_turns;         /* 0 = default (50) */
    float temperature;          /* <0 = default (0.7) */
} ZigAiAgentConfig;

typedef enum {
    ZIG_AI_EVENT_TURN_START = 0,
    ZIG_AI_EVENT_TOOL_START = 1,
    ZIG_AI_EVENT_TOOL_COMPLETE = 2,
    ZIG_AI_EVENT_TURN_COMPLETE = 3
} ZigAiAgentEventType;

typedef struct {
    ZigAiAgentEventType type;
    uint32_t turn;              /* turn_start, turn_complete */
    ZigAiString tool_name;      /* tool_start, tool_complete */
    ZigAiString tool_reason;    /* tool_start (may be NULL) */
    bool tool_success;          /* tool_complete */
    uint64_t duration_ms;       /* tool_complete */
    bool has_tool_calls;        /* turn_complete */
} ZigAiAgentEvent;

typedef struct {
    bool success;
    ZigAiString final_response;
    ZigAiString error_message;  /* NULL on success */
    uint32_t turns_used;
    uint32_t tool_calls_made;
    uint32_t input_tokens;
    uint32_t output_tokens;
} ZigAiAgentResult;

typedef void (*ZigAiAgentEventCallback)(const ZigAiAgentEvent* event, void* userdata);

/* ============================================================================
 * Batch Processing Types
 * ============================================================================ */

typedef struct {
    uint32_t id;
    ZigAiTextProvider provider;
    ZigAiString prompt;
    float temperature;
    uint32_t max_tokens;
    ZigAiString system_prompt;
} ZigAiBatchRequest;

typedef struct {
    uint32_t id;
    ZigAiTextProvider provider;
    ZigAiString prompt;
    ZigAiString response;
    uint32_t input_tokens;
    uint32_t output_tokens;
    double cost_usd;
    uint64_t execution_time_ms;
    ZigAiString error_message;
    bool success;
} ZigAiBatchResult;

typedef struct {
    ZigAiBatchResult* items;
    size_t count;
    double total_cost_usd;
    uint64_t total_time_ms;
} ZigAiBatchResults;

typedef struct {
    uint32_t concurrency;
    uint32_t retry_count;
    uint64_t timeout_ms;
    bool continue_on_error;
} ZigAiBatchConfig;

/* ============================================================================
 * Image Session Types (simplified session-based API)
 * ============================================================================ */

typedef struct {
    ZigAiImageProvider provider;
    ZigAiString size;           /* e.g. "1024x1024", empty = provider default */
    ZigAiQuality quality;
    ZigAiStyle style;
    ZigAiBackground background;
    ZigAiString openai_api_key;
    ZigAiString xai_api_key;
    ZigAiString genai_api_key;
    ZigAiString vertex_project_id;
    ZigAiString vertex_location;
} ZigAiImageSessionConfig;

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString image_data;     /* base64-encoded PNG/JPEG/WebP */
    ZigAiString revised_prompt;
    ZigAiMediaFormat format;
} ZigAiImageSessionResponse;

/* ============================================================================
 * Structured Output Types (runtime schema + template results)
 * ============================================================================ */

typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString value;
} ZigAiStringResult;

/** Structured output request with arbitrary JSON schema */
typedef struct {
    ZigAiString prompt;
    ZigAiString schema_json;    /* Raw JSON Schema string */
    ZigAiString schema_name;    /* Identifier (e.g. "product-listing") */
    ZigAiTextProvider provider;
    ZigAiString model;          /* empty = provider default */
    ZigAiString system_prompt;  /* empty = none */
    ZigAiString api_key;        /* empty = read from env var */
    uint32_t max_tokens;        /* 0 = default (65536) */
} ZigAiStructuredRequest;

/** Structured output response */
typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString json_output;    /* JSON conforming to the schema */
    uint32_t input_tokens;
    uint32_t output_tokens;
} ZigAiStructuredResponse;

/* ============================================================================
 * Opaque Handle Types
 * ============================================================================ */

typedef struct ZigAiTextSession ZigAiTextSession;
typedef struct ZigAiImageSession ZigAiImageSession;
typedef struct ZigAiLyriaSession ZigAiLyriaSession;
typedef struct ZigAiBatchExecutor ZigAiBatchExecutor;

/* ============================================================================
 * Library Initialization
 * ============================================================================ */

void zig_ai_init(void);
void zig_ai_shutdown(void);
ZigAiString zig_ai_version(void);

/* ============================================================================
 * Text AI Functions
 * ============================================================================ */

/** Create a text AI session for multi-turn conversation */
ZigAiTextSession* zig_ai_text_session_create(const ZigAiTextConfig* config);

/** Destroy a text AI session */
void zig_ai_text_session_destroy(ZigAiTextSession* session);

/** Send a message and get a response */
void zig_ai_text_send(ZigAiTextSession* session, ZigAiString prompt, ZigAiTextResponse* response_out);

/** Clear conversation history */
void zig_ai_text_clear_history(ZigAiTextSession* session);

/** One-shot query (no session needed) */
void zig_ai_text_query(ZigAiTextProvider provider, ZigAiString prompt, ZigAiString api_key, ZigAiTextResponse* response_out);

/** Calculate cost for a model */
double zig_ai_text_calculate_cost(ZigAiTextProvider provider, ZigAiString model, uint32_t input_tokens, uint32_t output_tokens);

/** Get default model for a provider */
ZigAiString zig_ai_text_default_model(ZigAiTextProvider provider);

/** Check if a provider is available */
bool zig_ai_text_provider_available(ZigAiTextProvider provider);

/** Free a text response */
void zig_ai_text_response_free(ZigAiTextResponse* response);

/** Free a string allocated by this library */
void zig_ai_string_free(ZigAiString s);

/* ============================================================================
 * Image Generation Functions
 * ============================================================================ */

/** Generate images using the specified provider */
void zig_ai_image_generate(const ZigAiImageRequest* request, const ZigAiMediaConfig* config, ZigAiImageResponse* response_out);

/** Convenience: Generate with DALL-E 3 */
void zig_ai_image_dalle3(ZigAiString prompt, ZigAiString size, ZigAiQuality quality, ZigAiString api_key, ZigAiImageResponse* response_out);

/** Convenience: Generate with Grok */
void zig_ai_image_grok(ZigAiString prompt, uint8_t count, ZigAiString api_key, ZigAiImageResponse* response_out);

/** Convenience: Generate with Google Imagen */
void zig_ai_image_imagen(ZigAiString prompt, uint8_t count, ZigAiString aspect_ratio, ZigAiString api_key, ZigAiImageResponse* response_out);

/** Check if an image provider is available */
bool zig_ai_image_provider_available(ZigAiImageProvider provider, const ZigAiMediaConfig* config);

/** Get provider name */
ZigAiString zig_ai_image_provider_name(ZigAiImageProvider provider);

/** Get environment variable name for provider */
ZigAiString zig_ai_image_provider_env_var(ZigAiImageProvider provider);

/** Free an image response */
void zig_ai_image_response_free(ZigAiImageResponse* response);

/** Edit images using GPT-Image model (multipart upload) */
void zig_ai_image_edit(const ZigAiEditRequest* request, const ZigAiMediaConfig* config, ZigAiImageResponse* response_out);

/* ============================================================================
 * Image Session Functions (simplified session-based API for cross-language use)
 * ============================================================================ */

/** Create an image generation session */
ZigAiImageSession* zig_ai_image_session_create(const ZigAiImageSessionConfig* config);

/** Destroy an image generation session */
void zig_ai_image_session_destroy(ZigAiImageSession* session);

/** Generate an image (returns base64-encoded data) */
void zig_ai_image_session_generate(
    ZigAiImageSession* session,
    ZigAiString prompt,
    ZigAiString size_override,      /* empty = use session default */
    ZigAiQuality quality_override,  /* ZIG_AI_QUALITY_AUTO = use session default */
    ZigAiImageSessionResponse* response_out
);

/** Free an image session response */
void zig_ai_image_session_response_free(ZigAiImageSessionResponse* response);

/* ============================================================================
 * Structured Output Template Functions
 * ============================================================================ */

/** List all structured output templates as JSON array */
ZigAiStringResult zig_ai_structured_list_templates(void);

/** Get a single template as JSON (includes schema, system prompt, parameters) */
ZigAiStringResult zig_ai_structured_get_template(ZigAiString name);

/** Generate structured output with an arbitrary JSON schema.
 *  This is the key function for orchestrator/DAG use: pass any schema,
 *  get back conforming JSON. The library handles per-provider differences
 *  (Claude output_config.format, Gemini responseJsonSchema, Grok response_format,
 *  DeepSeek JSON mode with schema in prompt). */
void zig_ai_structured_generate(const ZigAiStructuredRequest* request, ZigAiStructuredResponse* response_out);

/** Free a structured output response */
void zig_ai_structured_response_free(ZigAiStructuredResponse* response);

/* ============================================================================
 * Video Generation Functions
 * ============================================================================ */

/** Generate videos using the specified provider */
void zig_ai_video_generate(const ZigAiVideoRequest* request, const ZigAiMediaConfig* config, ZigAiVideoResponse* response_out);

/** Convenience: Generate with Sora */
void zig_ai_video_sora(ZigAiString prompt, uint8_t duration_seconds, ZigAiString resolution, ZigAiString api_key, ZigAiVideoResponse* response_out);

/** Convenience: Generate with Veo */
void zig_ai_video_veo(ZigAiString prompt, uint8_t duration_seconds, ZigAiString aspect_ratio, ZigAiString api_key, ZigAiVideoResponse* response_out);

/** Check if a video provider is available */
bool zig_ai_video_provider_available(ZigAiVideoProvider provider, const ZigAiMediaConfig* config);

/** Get provider name */
ZigAiString zig_ai_video_provider_name(ZigAiVideoProvider provider);

/** Free a video response */
void zig_ai_video_response_free(ZigAiVideoResponse* response);

/* ============================================================================
 * Music Generation Functions
 * ============================================================================ */

/** Generate music using the specified provider */
void zig_ai_music_generate(const ZigAiMusicRequest* request, const ZigAiMediaConfig* config, ZigAiMusicResponse* response_out);

/** Convenience: Generate with Lyria */
void zig_ai_music_lyria(ZigAiString prompt, uint32_t duration_seconds, uint16_t bpm, ZigAiString api_key, ZigAiMusicResponse* response_out);

/** Free a music response */
void zig_ai_music_response_free(ZigAiMusicResponse* response);

/* ============================================================================
 * Lyria Streaming Functions (Real-time Music Generation)
 * ============================================================================ */

/** Create a new Lyria streaming session */
ZigAiLyriaSession* zig_ai_lyria_session_create(void);

/** Destroy a Lyria streaming session */
void zig_ai_lyria_session_destroy(ZigAiLyriaSession* session);

/** Connect to Lyria RealTime service */
int32_t zig_ai_lyria_connect(ZigAiLyriaSession* session, ZigAiString api_key);

/** Set weighted prompts for DJ-style blending */
int32_t zig_ai_lyria_set_prompts(ZigAiLyriaSession* session, const ZigAiWeightedPrompt* prompts, size_t count);

/** Update music generation config */
int32_t zig_ai_lyria_set_config(ZigAiLyriaSession* session, const ZigAiLyriaConfig* config);

/** Start playback */
int32_t zig_ai_lyria_play(ZigAiLyriaSession* session);

/** Pause playback */
int32_t zig_ai_lyria_pause(ZigAiLyriaSession* session);

/** Stop playback */
int32_t zig_ai_lyria_stop(ZigAiLyriaSession* session);

/** Reset context (required after BPM changes) */
int32_t zig_ai_lyria_reset_context(ZigAiLyriaSession* session);

/** Get next audio chunk (PCM data) - caller must free with zig_ai_buffer_free */
int32_t zig_ai_lyria_get_audio_chunk(ZigAiLyriaSession* session, ZigAiBuffer* buffer_out);

/** Check if session is connected */
bool zig_ai_lyria_is_connected(const ZigAiLyriaSession* session);

/** Get current session state */
ZigAiLyriaState zig_ai_lyria_get_state(const ZigAiLyriaSession* session);

/** Get audio format info */
void zig_ai_lyria_get_audio_format(const ZigAiLyriaSession* session, ZigAiAudioFormat* format_out);

/** Close the connection */
void zig_ai_lyria_close(ZigAiLyriaSession* session);

/** Free a buffer allocated by this library */
void zig_ai_buffer_free(ZigAiBuffer buffer);

/* ============================================================================
 * Batch Processing Functions
 * ============================================================================ */

/** Create a batch executor from an array of requests */
ZigAiBatchExecutor* zig_ai_batch_create(const ZigAiBatchRequest* requests, size_t count, const ZigAiBatchConfig* config);

/** Create a batch executor from a CSV file */
ZigAiBatchExecutor* zig_ai_batch_create_from_csv(ZigAiString csv_path, const ZigAiBatchConfig* config);

/** Destroy a batch executor */
void zig_ai_batch_destroy(ZigAiBatchExecutor* executor);

/** Execute the batch */
int32_t zig_ai_batch_execute(ZigAiBatchExecutor* executor);

/** Get results after execution */
int32_t zig_ai_batch_get_results(ZigAiBatchExecutor* executor, ZigAiBatchResults* results_out);

/** Write results to a CSV file */
int32_t zig_ai_batch_write_results(const ZigAiBatchResults* results, ZigAiString output_path, bool full_responses);

/** Free batch results */
void zig_ai_batch_results_free(ZigAiBatchResults* results);

/* ============================================================================
 * Agent Functions (AI Agent with Security Sandbox)
 * ============================================================================ */

/** Create an agent session from config */
ZigAiAgentSession* zig_ai_agent_create(const ZigAiAgentConfig* config);

/** Destroy an agent session */
void zig_ai_agent_destroy(ZigAiAgentSession* session);

/** Set event callback for real-time tool execution updates */
void zig_ai_agent_set_callback(ZigAiAgentSession* session, ZigAiAgentEventCallback callback, void* userdata);

/** Run agent with a task (blocking) */
void zig_ai_agent_run(ZigAiAgentSession* session, ZigAiString task, ZigAiAgentResult* result_out);

/** Free agent result strings */
void zig_ai_agent_result_free(ZigAiAgentResult* result);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_AI_H */
