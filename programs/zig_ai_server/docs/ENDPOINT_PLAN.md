# Endpoint Implementation Plan

**Complete inventory from Go backend analysis: 222+ endpoints**
- 22 implemented in Zig
- 200+ remaining (67 stubbed, 133+ missing)

---

## Tier 0 — Simple Provider Passthroughs (parallel-safe, no new infra)

Each is: parse request → billing → HTTP POST to provider → format response. Can all run in parallel.

| # | Endpoint | Provider | Billing | Complexity |
|---|----------|----------|---------|------------|
| 1 | `POST /search/web` | Brave Search API | per-query | Low |
| 2 | `POST /search/context` | Brave Search API | per-query | Low |
| 3 | `POST /search/answer` | Brave Search API | per-query | Medium (AI grounding) |
| 4 | `POST /embeddings` | OpenAI / Vertex | per-token | Medium |
| 5 | `GET /voices` | ElevenLabs | none | Trivial |
| 6 | `GET /voices/library` | ElevenLabs | none | Trivial |
| 7 | `POST /voices/clone` | ElevenLabs | per-unit | Medium (multipart) |
| 8 | `DELETE /voices/{id}` | ElevenLabs | none | Trivial |
| 9 | `POST /voices/library/add` | ElevenLabs | none | Trivial |

**Prerequisites:** `BRAVE_SEARCH_API_KEY`, `ELEVENLABS_API_KEY` in Secret Manager.

---

## Tier 1 — Media Generation (parallel-safe, binary responses)

| # | Endpoint | Provider | Notes |
|---|----------|----------|-------|
| 10 | `POST /images/generate` | xAI Imagine / OpenAI DALL-E / Gemini Imagen | Route by model prefix, returns base64/URL |
| 11 | `POST /images/edit` | OpenAI / Gemini | Multipart: image + mask + prompt |
| 12 | `POST /audio/tts` | ElevenLabs / OpenAI TTS | Returns audio bytes (mp3/pcm) |
| 13 | `POST /audio/stt` | Google Cloud STT / OpenAI Whisper | Multipart audio upload |
| 14 | `POST /audio/music` | Suno / Udio | Async job, returns job ID |
| 15 | `POST /audio/sound-effects` | ElevenLabs | Returns audio bytes |
| 16 | `POST /audio/speech-to-speech` | ElevenLabs | Audio in → audio out |
| 17 | `POST /audio/isolate` | ElevenLabs | Audio in → isolated voice |
| 18 | `POST /audio/dialogue` | ElevenLabs | Multi-speaker, complex |
| 19 | `POST /video/generate` | xAI Imagine Video / Replicate | Async, returns job ID |
| 20 | `POST /vision/analyze` | Claude / Vertex Vision | Image + prompt → text |
| 21 | `POST /vision/ocr` | Vertex Vision / DeepSeek OCR | Image → text |
| 22 | `POST /vision/describe` | Claude / Vertex | Image → description |

**Prerequisites:** Multipart form-data parsing in Zig (for audio/image upload endpoints).

---

## Tier 2 — Stateful / Firestore-backed (sequential, touch store)

| # | Endpoint | Notes |
|---|----------|-------|
| 23 | `POST /chat/session` | Server-managed conversation history in Firestore |
| 24 | `GET /chat/sessions` | List sessions |
| 25 | `GET /chat/sessions/{id}` | Get session |
| 26 | `PUT /chat/sessions/{id}` | Update session metadata |
| 27 | `DELETE /chat/sessions/{id}` | Delete session |
| 28 | `POST /keys/ephemeral` | Short-lived tokens |
| 29 | `POST /keys/partner` | Partner keys |
| 30-35 | `POST/GET /batch/*` | Batch job submission, status, results |
| 36-40 | `POST/GET /jobs/*` | Async job queue |

---

## Tier 3 — RAG / Knowledge (mix of providers)

| # | Endpoint | Provider | Notes |
|---|----------|----------|-------|
| 41 | `GET /rag/corpora` | Vertex RAG Engine | List corpora |
| 42 | `POST /rag/search` | Vertex RAG Engine | Search knowledge base |
| 43 | `POST /rag/surreal/search` | SurrealDB | Local RAG |
| 44 | `GET /rag/surreal/providers` | SurrealDB | List providers |
| 45-50 | `/rag/collections/*` | xAI Collections API | CRUD + search |

---

## Tier 4 — Video / HeyGen (async, complex)

| # | Endpoint | Notes |
|---|----------|-------|
| 51 | `POST /video/studio` | HeyGen async via Cloud Tasks |
| 52 | `GET /video/avatars` | HeyGen API list |
| 53 | `POST /video/translate` | HeyGen dubbing |
| 54 | `POST /video/photo-avatar` | HeyGen avatar creation |
| 55 | `POST /video/digital-twin` | HeyGen digital twin |
| 56 | `GET /video/templates` | HeyGen templates |
| 57 | `GET /video/heygen-voices` | HeyGen voices |

---

## Tier 5 — Analytics / Admin (BigQuery reads)

| # | Endpoint | Notes |
|---|----------|-------|
| 58 | `GET /account/usage` | BigQuery query |
| 59 | `GET /account/usage/summary` | BigQuery aggregation |
| 60 | `GET /stats/overview` | BigQuery dashboard data |
| 61 | `GET /stats/timeline` | BigQuery time series |
| 62 | `GET /stats/models` | BigQuery model breakdown |
| 63-75 | `/admin/stats/*` | Admin analytics (13 endpoints) |
| 76-85 | `/admin/users/*` | Admin user management (10 endpoints) |
| 86-90 | `/admin/batch/*` | Admin batch management |

---

## Tier 6 — Infrastructure / Internal (complex, low priority)

| # | Endpoint | Notes |
|---|----------|-------|
| 91-95 | `/compute/*` | GPU provisioning, instance management |
| 96-100 | `/compute/deploy*` | Model deployment to Vertex |
| 101-105 | `/scanner/*` | Code analysis with SurrealDB |
| 106-108 | `/scraper/*` | Web scraping via Cloud Run service |
| 109-112 | `/documents/*` | Document processing |
| 113-118 | `/security/*` | Code/URL scanning |
| 119-122 | `/notifications/*` | Push notifications via FCM |
| 123-128 | `/observations/*` | Telemetry/observability |
| 129-132 | `/conductor/*` | Conductor logging |

---

## Tier 7 — Realtime / WebSocket (hardest, last)

| # | Endpoint | Notes |
|---|----------|-------|
| 133 | `POST /realtime/session` | Create xAI realtime session |
| 134 | `WS /realtime` | WebSocket: xAI voice/text |
| 135 | `WS /realtime/elevenlabs` | WebSocket: ElevenLabs voice |
| 136-138 | `/twilio/*` | Voice agent webhooks + WebSocket |

---

## Tier 8 — Payments (Stripe integration)

| # | Endpoint | Notes |
|---|----------|-------|
| 139 | `GET /credits/packs` | List credit packs |
| 140 | `POST /credits/purchase` | Stripe checkout |
| 141 | `POST /credits/lifetime` | Lifetime plan purchase |
| 142 | `POST /webhooks/stripe` | Stripe webhook handler |
| 143 | `GET /credits/tiers` | Tier information |

---

## Missions (20+ endpoints, complex orchestration)

| # | Endpoint | Notes |
|---|----------|-------|
| 144 | `POST /missions` | Execute mission (SSE) |
| 145 | `POST /missions/create` | Create mission spec |
| 146-155 | `/missions/{id}/*` | Lifecycle: cancel, pause, resume, approve, retry, chat, checkpoints |

---

## Recommended Sequencing

```
Sprint 1 (Tier 0): 9 endpoints — Brave Search + ElevenLabs voices
  → All parallel, 2-3 hours each
  → Unblocks search-augmented chat + voice selection in app

Sprint 2 (Tier 1): 13 endpoints — Images + Audio + Vision
  → Parallel, needs multipart parser
  → Unblocks media generation in app

Sprint 3 (Tier 2): 18 endpoints — Sessions + Batch + Jobs
  → Sequential, touches Firestore
  → Unblocks conversation persistence + async workloads

Sprint 4 (Tier 3+4): 17 endpoints — RAG + HeyGen
  → Mix of parallel + sequential
  → Unblocks knowledge base + video features

Sprint 5 (Tier 5): 28 endpoints — Analytics + Admin
  → All BigQuery reads, straightforward
  → Unblocks dashboard + admin panel

Sprint 6-8 (Tier 6-8): 50+ endpoints — Infra, Realtime, Payments
  → Complex, needs careful planning
  → WebSocket support in Zig needed for realtime
```

## File Manifest per Sprint

Each parallel agent receives:
1. `docs/SHARED_CONTEXT.md` — handler patterns
2. `docs/HARDENING_RULES.md` — security rules
3. Go handler source file — exact request/response schemas
4. Per-endpoint spec (generated from this plan)
5. `models.csv` row to add (if new provider)
