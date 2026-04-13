# Endpoint Implementation Plan

Status: **DRAFT** — pending full Go backend mapping from analysis agent.

## Current State

### Implemented (22 endpoints)
| Method | Path | Handler |
|---|---|---|
| POST | `/qai/v1/auth/apple` | apple_auth.zig |
| POST | `/qai/v1/auth/google` | google_auth.zig |
| POST | `/qai/v1/chat` | chat.zig (+ stream.zig for stream:true) |
| POST | `/qai/v1/chat/stream` | stream.zig |
| POST | `/qai/v1/vertex/chat` | vertex.zig |
| POST | `/qai/v1/vertex/chat/stream` | vertex.zig |
| POST | `/qai/v1/agent` | agent.zig |
| GET | `/qai/v1/models` | models.zig |
| GET | `/qai/v1/models/pricing` | models.zig |
| GET | `/qai/v1/account/balance` | router.zig (inline) |
| POST | `/qai/v1/keys` | keys.zig |
| GET | `/qai/v1/keys` | keys.zig |
| DELETE | `/qai/v1/keys/{prefix}` | keys.zig |
| POST | `/qai/v1/admin/accounts` | keys.zig |
| GET | `/qai/v1/admin/accounts` | keys.zig |
| GET | `/qai/v1/admin/accounts/{id}` | keys.zig |
| POST | `/qai/v1/admin/accounts/{id}/credit` | keys.zig |
| POST | `/qai/v1/admin/accounts/{id}/freeze` | keys.zig |
| POST | `/qai/v1/admin/accounts/{id}/tier` | keys.zig |
| POST | `/qai/v1/admin/endpoints` | vertex.zig |
| GET | `/qai/v1/admin/endpoints` | vertex.zig |
| DELETE | `/qai/v1/admin/endpoints/{model}` | vertex.zig |

### Stubbed (16 endpoint groups — need implementation)

## Implementation Tiers

### Tier 0 — Simple Provider Passthroughs (parallel-safe)
Each is: parse request → billing reserve → HTTP call to provider → format response → billing commit.

| Endpoint | Provider API | Auth | Billing | Notes |
|---|---|---|---|---|
| `POST /search/web` | Brave Search API | API key (BRAVE_SEARCH_API_KEY) | Per-query flat rate | Returns JSON results |
| `POST /search/context` | Brave Context API | API key | Per-query | Returns LLM-optimized text |
| `POST /search/answer` | Brave Answer API | API key | Per-query | Returns AI-grounded answer |
| `POST /embeddings` | OpenAI / Vertex | API key / GCP token | Per-token | Returns float arrays |
| `GET /voices` | ElevenLabs | API key | None (read-only) | Returns voice list |
| `GET /voices/library` | ElevenLabs | API key | None | Returns community voices |

### Tier 1 — Media Generation (parallel-safe, binary responses)

| Endpoint | Provider API | Notes |
|---|---|---|
| `POST /images/generate` | xAI Imagine, OpenAI DALL-E, Gemini Imagen | Route by model prefix. Returns base64 or URL. |
| `POST /images/edit` | OpenAI, Gemini | Multipart upload (image + prompt) |
| `POST /audio/tts` | ElevenLabs, OpenAI TTS | Returns audio bytes (mp3/wav) |
| `POST /audio/transcribe` | OpenAI Whisper | Multipart upload (audio file) |
| `POST /video/generate` | xAI Imagine Video | Async — returns job ID, poll for result |

### Tier 2 — Stateful / Orchestrated (sequential, touch store)

| Endpoint | Notes |
|---|---|
| `POST /chat/session` | Session-based chat with server-managed history in Firestore |
| `POST /rag/ingest` | Upload docs → Vertex RAG Engine corpus |
| `POST /rag/query` | Query against RAG corpus |
| `POST /batch` | Submit batch job (CSV of prompts) |
| `GET /jobs/{id}` | Poll job status |
| `POST /missions` | Multi-step agent orchestration |

### Tier 3 — Specialized

| Endpoint | Notes |
|---|---|
| `POST /3d/generate` | Meshy 3D model generation (async) |
| `POST /compute/*` | Internal compute dispatch |

## Parallel Agent Spec Template

Each Tier 0/1 endpoint task for an agent includes:

1. **SHARED_CONTEXT.md** — handler patterns, billing flow, error format, test requirements
2. **Per-endpoint spec** with:
   - Exact request/response JSON schemas (from Go handler)
   - Provider API URL, auth header, request format
   - Billing model (per-token, per-query, per-unit)
   - `models.csv` row to add (if new provider)
   - Test contract (3-5 specific test cases)
   - Files to create/modify

## Sequencing

```
Week 1: Tier 0 (6 endpoints, all parallel)
  → search/web, search/context, search/answer
  → embeddings
  → voices, voices/library

Week 2: Tier 1 (5 endpoints, all parallel)
  → images/generate, images/edit
  → audio/tts, audio/transcribe
  → video/generate

Week 3: Tier 2 (6 endpoints, sequential)
  → chat/session (needs Firestore session store)
  → rag/ingest, rag/query
  → batch, jobs
  → missions

Week 4: Tier 3 + polish
  → 3d/generate
  → compute/*
  → API docs, SDK update, deploy
```

## Prerequisites per tier

**Tier 0**: No new infrastructure. Just env vars for BRAVE_SEARCH_API_KEY, ELEVENLABS_API_KEY.

**Tier 1**: Need to handle multipart/form-data (for audio/image upload). May need a multipart parser in Zig or convert to base64.

**Tier 2**: Firestore session collection, Vertex RAG Engine setup, Cloud Tasks queue for batch.

**Tier 3**: Meshy API access.
