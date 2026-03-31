# Zig AI Library - Current Capabilities Report

**Date:** 2026-02-12
**Binary:** `libzig_ai.dylib` (6.6 MB shared) / `libzig_ai.a` (11 MB static)
**CLI:** `zig-ai` (7.9 MB)
**Language:** Zig 0.16, zero external C dependencies
**Repo:** `quantum-zig-forge/programs/zig_ai/`
**Header:** `include/zig_ai.h` (687 lines, compiles clean as C and C++)

---

## 1. What It Is

zig_ai is a universal AI provider library that ships as both a standalone CLI tool and a shared library with a C FFI interface. Every AI API call in the monorepo goes through this single binary. Provider routing, API key management, model selection, retry logic, structured output parsing, cost tracking, and response formatting are all handled inside the Zig library. Consumer apps never touch an AI API directly.

The library exports 42 C-callable functions via `export fn` with stable ABI. Any language that can call C can use it: Rust (via `extern "C"`), Python (via ctypes/cffi), Swift, Go, etc.

---

## 2. Text Generation - 5 Providers

| Provider | Default Model | Env Var | Wire Format |
|----------|--------------|---------|-------------|
| Claude (Anthropic) | `claude-sonnet-4-5-20250929` | `ANTHROPIC_API_KEY` | Messages API, `tools[]` with `input_schema` |
| DeepSeek | `deepseek-chat` | `DEEPSEEK_API_KEY` | OpenAI-compatible Chat Completions |
| Gemini (Google) | `gemini-2.5-flash` | `GOOGLE_GENAI_API_KEY` | `functionDeclarations[]`, `functionCall` parts |
| Grok (xAI) | `grok-4-1-fast-non-reasoning` | `XAI_API_KEY` | Chat Completions with `tools[].function` |
| Vertex AI | `gemini-2.5-pro` | `VERTEX_PROJECT_ID` | Same as Gemini, routed through Vertex endpoint |

OpenAI GPT-5.2 is also supported but uses the Responses API (NOT Chat Completions). Tool format is flat, uses `function_call` output items.

### FFI Interface

```c
// Session-based (multi-turn conversation)
ZigAiTextSession* zig_ai_text_session_create(const ZigAiTextConfig* config);
void zig_ai_text_send(ZigAiTextSession* session, ZigAiString prompt, ZigAiTextResponse* response_out);
void zig_ai_text_clear_history(ZigAiTextSession* session);
void zig_ai_text_session_destroy(ZigAiTextSession* session);

// One-shot (stateless)
void zig_ai_text_query(ZigAiTextProvider provider, ZigAiString prompt, ZigAiString api_key, ZigAiTextResponse* response_out);

// Utilities
double zig_ai_text_calculate_cost(ZigAiTextProvider provider, ZigAiString model, uint32_t input_tokens, uint32_t output_tokens);
ZigAiString zig_ai_text_default_model(ZigAiTextProvider provider);
bool zig_ai_text_provider_available(ZigAiTextProvider provider);
```

### Response Struct
```c
typedef struct {
    bool success;
    int32_t error_code;
    ZigAiString error_message;
    ZigAiString content;          // The AI response text
    ZigAiTokenUsage usage;        // { input_tokens, output_tokens, total_tokens, cost_usd }
    ZigAiString model_used;
    ZigAiTextProvider provider;
} ZigAiTextResponse;
```

### Cost Tracking (Built-in)
Every response includes `cost_usd` computed from actual token counts. Pricing is hardcoded per model:
- DeepSeek: $0.14/$0.28 per 1M tokens (cheapest)
- Gemini Flash: $0.30/$2.50
- Grok: $0.20/$0.50
- Claude Sonnet: $3.00/$15.00
- GPT-5.2: $1.75/$14.00

---

## 3. Image Generation - 9 Provider Variants

| Provider | Enum Value | API | Key Env Var |
|----------|-----------|-----|-------------|
| DALL-E 3 | 0 | OpenAI Images | `OPENAI_API_KEY` |
| DALL-E 2 | 1 | OpenAI Images | `OPENAI_API_KEY` |
| GPT-Image 1 | 2 | OpenAI Images | `OPENAI_API_KEY` |
| GPT-Image 1.5 | 3 | OpenAI Images | `OPENAI_API_KEY` |
| Grok Image | 4 | xAI Aurora | `XAI_API_KEY` |
| Imagen (GenAI) | 5 | Google GenAI | `GOOGLE_GENAI_API_KEY` |
| Imagen (Vertex) | 6 | Vertex AI | `VERTEX_PROJECT_ID` |
| Gemini Flash Image | 7 | Google GenAI | `GOOGLE_GENAI_API_KEY` |
| Gemini Pro Image | 8 | Google GenAI | `GOOGLE_GENAI_API_KEY` |

### FFI Interface - Two APIs

**Full API** (raw bytes, multiple images, full metadata):
```c
void zig_ai_image_generate(const ZigAiImageRequest* request, const ZigAiMediaConfig* config, ZigAiImageResponse* response_out);
void zig_ai_image_edit(const ZigAiEditRequest* request, const ZigAiMediaConfig* config, ZigAiImageResponse* response_out);
void zig_ai_image_response_free(ZigAiImageResponse* response);
```

**Session API** (simplified, base64 output, for cross-language consumers):
```c
ZigAiImageSession* zig_ai_image_session_create(const ZigAiImageSessionConfig* config);
void zig_ai_image_session_generate(
    ZigAiImageSession* session,
    ZigAiString prompt,
    ZigAiString size_override,        // empty = session default
    ZigAiQuality quality_override,    // AUTO = session default
    ZigAiImageSessionResponse* response_out
);
void zig_ai_image_session_response_free(ZigAiImageSessionResponse* response);
void zig_ai_image_session_destroy(ZigAiImageSession* session);
```

The session API returns base64-encoded image data in `ZigAiString image_data`, ready for display or storage without binary buffer handling.

### Image Editing
GPT-Image supports multipart edit mode: pass 1+ source images + prompt, get back modified images. Supports style transfer, background removal, object removal, try-on, sketch rendering.

### Image Templates (39 CLI presets)
Photography (8): photo, portrait, landscape, macro, product, food, architecture, fashion
Art Styles (13): anime, comic, watercolor, digital-art, cinematic, noir, cyberpunk, steampunk, fantasy, surreal, retro80s, solarpunk, sci-fi
Design (11): painting, kitchen, bathroom, flooring, roofing, terrace, abstract, minimalist, infographic, ui-mockup, collectible
Editing (6): style-transfer, try-on, sketch-render, bg-remove, weather-change, object-remove

---

## 4. Video Generation - 2 Providers

| Provider | Model | Duration | Resolutions |
|----------|-------|----------|-------------|
| Sora (OpenAI) | sora-2-pro | 5-60s | 720p, 1080p |
| Veo (Google) | veo-2.0-generate-001 | 2-5min | 720p, 1080p, 2K |

CLI: `zig-ai sora "prompt" -d 10 -r 1920x1080` / `zig-ai veo "prompt" --aspect-ratio 16:9`

---

## 5. Music Generation - 2 Modes

| Provider | Model | Mode | Duration |
|----------|-------|------|----------|
| Lyria | lyria-002 | Batch generation | 30-120s |
| Lyria RealTime | lyria-realtime-exp | WebSocket streaming | Continuous |

### FFI - Batch Music
```c
void zig_ai_music_generate(const ZigAiMusicRequest* request, const ZigAiMediaConfig* config, ZigAiMusicResponse* response_out);
void zig_ai_music_response_free(ZigAiMusicResponse* response);
```

### FFI - Lyria Streaming (Real-time)
Full session lifecycle with DJ-style weighted prompt blending:
```c
ZigAiLyriaSession* zig_ai_lyria_session_create(void);
int32_t zig_ai_lyria_connect(ZigAiLyriaSession* session, ZigAiString api_key);
int32_t zig_ai_lyria_set_prompts(ZigAiLyriaSession* session, const ZigAiWeightedPrompt* prompts, size_t count);
int32_t zig_ai_lyria_set_config(ZigAiLyriaSession* session, const ZigAiLyriaConfig* config);
int32_t zig_ai_lyria_play(ZigAiLyriaSession* session);
int32_t zig_ai_lyria_pause(ZigAiLyriaSession* session);
int32_t zig_ai_lyria_stop(ZigAiLyriaSession* session);
int32_t zig_ai_lyria_get_audio_chunk(ZigAiLyriaSession* session, ZigAiBuffer* buffer_out);
ZigAiLyriaState zig_ai_lyria_get_state(const ZigAiLyriaSession* session);
void zig_ai_lyria_close(ZigAiLyriaSession* session);
void zig_ai_lyria_session_destroy(ZigAiLyriaSession* session);
```

Config controls: BPM, temperature, guidance, density, brightness, mute bass/drums, bass-and-drums-only.

---

## 6. Audio / TTS / STT

**OpenAI TTS:** 13 voices (alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse, marin, cedar), models tts-1/tts-1-hd/gpt-4o-mini-tts, formats mp3/opus/aac/flac/wav/pcm.

**Google TTS:** gemini-2.5-flash-tts, multi-speaker mode.

**OpenAI STT:** gpt-4o-mini-transcribe, Whisper-1 for translation. Formats: text, json, verbose_json, srt, vtt.

CLI: `zig-ai tts-openai "Hello" -v coral -m tts-1-hd -o hello.mp3`
CLI: `zig-ai stt-openai recording.mp3 --language en --format json`

---

## 7. Structured Output (JSON Schema)

Forces AI responses to conform to a JSON Schema. The library handles the per-provider differences:

| Provider | Mechanism |
|----------|-----------|
| OpenAI/GPT-5.2 | `text.format.json_schema` in Responses API |
| Claude | `output_format.json_schema` (beta header) |
| Gemini | `responseMimeType: application/json` + `responseJsonSchema` |
| Grok | `response_format.json_schema` in Chat Completions |
| DeepSeek | JSON mode + schema embedded in system prompt |

### Built-in Templates (12)
Templates bundle JSON Schema + system prompt + configurable parameters:

| Template | Category | Parameters |
|----------|----------|-----------|
| `product-listing` | Business | `detail_level` (brief/standard/comprehensive) |
| `meeting-notes` | Business | `format` (action-items/full-minutes/decisions-only) |
| `invoice` | Business | `currency` (USD/EUR/GBP) |
| `resume-parse` | Business | `format` (standard/tech/academic) |
| `sentiment` | Analysis | `granularity` (simple/detailed/aspect-based) |
| `entity-extraction` | Analysis | `entity_types` (people/orgs/locations/all) |
| `classification` | Analysis | `taxonomy` (topic/intent/priority) |
| `code-review` | Coding | `language`, `focus` (bugs/security/performance/style) |
| `api-spec` | Coding | `style` (openapi/graphql) |
| `recipe` | Creative | `cuisine`, `dietary` |
| `lesson-plan` | Education | `level`, `duration` |
| `quiz` | Education | `difficulty`, `question_types` |

### FFI Interface
```c
ZigAiStringResult zig_ai_structured_list_templates(void);       // JSON array of all templates
ZigAiStringResult zig_ai_structured_get_template(ZigAiString name); // Single template with schema
```

The `ZigAiStringResult` contains `{ success, error_code, error_message, value }` where `value` is JSON.

**This is the key integration point for the cockpit architecture.** The orchestrator can:
1. Call `zig_ai_structured_list_templates()` to populate a dropdown
2. Call `zig_ai_structured_get_template("product-listing")` to get the schema
3. Construct a `ZigAiTextConfig` with the template name and parameters
4. The library handles schema injection, system prompt interpolation, provider-specific formatting
5. Response comes back as validated JSON matching the schema

Custom schemas are also supported via `--schema <file.json>` on CLI or by constructing a `StructuredRequest` directly.

---

## 8. Text Templates (16 Parametric Presets)

Separate from structured output. These set system prompts + wrap user prompts for specific use cases:

| Template | Category | Parameters |
|----------|----------|-----------|
| `joke-code` | Coding | `language` |
| `code-review` | Coding | `language`, `focus_areas` |
| `rubber-duck` | Coding | `language` |
| `storyteller` | Creative | `genre`, `style` |
| `poet` | Creative | `form`, `theme` |
| `worldbuilder` | Creative | `genre`, `scope` |
| `email-pro` | Professional | `tone`, `context` |
| `executive-summary` | Professional | `audience`, `length` |
| `tweet` | Professional | `tone`, `hashtag_style` |
| `tutor` | Education | `subject`, `level` |
| `eli5` | Education | `domain` |
| `socratic` | Education | `subject` |
| `data-analyst` | Education | `domain`, `tool` |
| `debate` | Entertainment | `position`, `style` |
| `dungeon-master` | Entertainment | `setting`, `difficulty` |
| `roast` | Entertainment | `style`, `intensity` |

CLI: `zig-ai gemini -T eli5 -P domain=physics "quantum entanglement"`

---

## 9. Agent Mode (17 Tools + Permission System)

Agentic execution with tool calling, sandboxing, and human-in-the-loop confirmation.

### FFI Interface
```c
ZigAiAgentSession* zig_ai_agent_create(const ZigAiAgentConfig* config);
void zig_ai_agent_set_callback(ZigAiAgentSession* session, ZigAiAgentEventCallback callback, void* userdata);
void zig_ai_agent_run(ZigAiAgentSession* session, ZigAiString task, ZigAiAgentResult* result_out);
void zig_ai_agent_destroy(ZigAiAgentSession* session);
```

### Event Callback
Real-time events streamed to caller via function pointer:
```c
typedef void (*ZigAiAgentEventCallback)(const ZigAiAgentEvent* event, void* userdata);
// Events: TURN_START, TOOL_START (with tool_name + reason), TOOL_COMPLETE (with duration_ms), TURN_COMPLETE
```

### 17 Built-in Tools
File ops: `read_file`, `write_file`, `list_files`, `search_files`, `trash_file`, `grep`, `cat`, `wc`, `find`
File mgmt: `cp`, `mv`, `rm`, `mkdir`, `touch`
Process: `execute_command`, `kill_process`, `process_table`
Interaction: `confirm_action`

### Permission Tiers (Config-driven)
- `auto` - Execute immediately (read-only ops)
- `confirm` - Show dialog, default deny (write ops)
- `askpass` - Require explicit "yes" (destructive ops)
- `blocked` - Hard no (dd, shred, chroot)

### Agent Result
```c
typedef struct {
    bool success;
    ZigAiString final_response;
    ZigAiString error_message;
    uint32_t turns_used;
    uint32_t tool_calls_made;
    uint32_t input_tokens;
    uint32_t output_tokens;
} ZigAiAgentResult;
```

---

## 10. Batch Processing

### FFI (not yet fully exported, available via CLI)
```bash
zig-ai --batch input.csv -o results.jsonl --concurrency 50 --retry 2
zig-ai image-batch input.csv --concurrency 10
```

Processes N requests in parallel across any mix of providers. CSV input, JSONL output. Concurrency 1-200, automatic retry with backoff.

---

## 11. Complete FFI Export List (42 Functions)

```
zig_ai_init                          zig_ai_shutdown
zig_ai_version

zig_ai_text_session_create           zig_ai_text_session_destroy
zig_ai_text_send                     zig_ai_text_clear_history
zig_ai_text_query                    zig_ai_text_calculate_cost
zig_ai_text_default_model            zig_ai_text_provider_available
zig_ai_text_response_free            zig_ai_string_free

zig_ai_image_generate                zig_ai_image_edit
zig_ai_image_provider_available      zig_ai_image_provider_name
zig_ai_image_response_free

zig_ai_image_session_create          zig_ai_image_session_destroy
zig_ai_image_session_generate        zig_ai_image_session_response_free

zig_ai_structured_list_templates     zig_ai_structured_get_template

zig_ai_music_generate                zig_ai_music_response_free

zig_ai_lyria_session_create          zig_ai_lyria_session_destroy
zig_ai_lyria_connect                 zig_ai_lyria_set_prompts
zig_ai_lyria_set_config              zig_ai_lyria_play
zig_ai_lyria_pause                   zig_ai_lyria_stop
zig_ai_lyria_reset_context           zig_ai_lyria_get_audio_chunk
zig_ai_lyria_is_connected            zig_ai_lyria_get_state
zig_ai_lyria_get_audio_format        zig_ai_lyria_close
zig_ai_buffer_free

zig_ai_agent_create                  zig_ai_agent_destroy
zig_ai_agent_set_callback            zig_ai_agent_run
zig_ai_agent_result_free
```

---

## 12. Memory Model

All strings returned by the library are heap-allocated with a null sentinel. The caller must free them using the corresponding `_free` function. The pattern is:

```c
ZigAiTextResponse response;
zig_ai_text_query(ZIG_AI_TEXT_GEMINI, prompt, api_key, &response);
// Use response.content, response.usage, etc.
zig_ai_text_response_free(&response);  // Frees all internal strings
```

Opaque handles (`ZigAiTextSession*`, `ZigAiImageSession*`, etc.) are created with `_create` and destroyed with `_destroy`. The library owns all internal state.

The base types:
- `ZigAiString { const char* ptr; size_t len; }` - null-terminated, length-prefixed
- `ZigAiBuffer { uint8_t* ptr; size_t len; }` - raw binary data
- `ZigAiStringResult { bool success; int32_t error_code; ZigAiString error_message; ZigAiString value; }` - for JSON returns

---

## 13. What's Ready for the Cockpit Architecture

**Already built and exported:**
- Session-based text generation (create session, send messages, get responses with cost tracking)
- Session-based image generation (create session, generate, get base64 back)
- Structured output with 12 built-in templates (list templates as JSON, get template schema as JSON)
- Agent execution with real-time event callbacks (tool start/complete events with duration)
- Lyria streaming with full playback control

**What the orchestrator would call:**
1. `zig_ai_structured_list_templates()` -> populate UI dropdown
2. `zig_ai_structured_get_template("product-listing")` -> get schema for validation
3. `zig_ai_text_session_create(config_with_template)` -> create session with schema
4. `zig_ai_text_send(session, user_input, &response)` -> get structured JSON back
5. Validate response against schema client-side
6. `zig_ai_text_calculate_cost(...)` -> track spend

**The update story:** When a new model ships, edit the model name constants in `src/cli.zig` and `src/model_costs.zig`, rebuild `libzig_ai.dylib`, every app that links against it gets the new model. One change, universal effect.

**What's NOT yet exported but exists internally:**
- TTS/STT (CLI only, no FFI exports yet)
- Video generation (CLI only, no FFI exports yet)
- Batch processing (CLI only, no FFI exports yet)
- Custom schema file loading (CLI only)

These can be exposed as FFI functions when needed - the internal implementations are complete.

---

## 14. Build Commands

```bash
# Shared library (for FFI consumers)
zig build -Dlib

# Static library
zig build -Dlib -Dstatic

# CLI executable
zig build

# Artifacts
zig-out/lib/libzig_ai.dylib   # 6.6 MB
zig-out/lib/libzig_ai.a       # 11 MB
zig-out/bin/zig-ai             # 7.9 MB
include/zig_ai.h               # C header
```

---

**Summary: 42 FFI exports, 5+ text providers, 9 image providers, 2 video, 2 music, 4 audio services, 17 agent tools, 67 templates (16 text + 39 image + 12 structured), built-in cost tracking, session-based and stateless APIs, real-time event callbacks for agent execution.**
