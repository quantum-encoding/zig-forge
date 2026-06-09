# zig_ai_server — feature parity with the Go gateway

Target: `quantum-ai-polyrepo/quantum-ai-backend` (`internal/server`, **270 routes**).

This file maps every Go route group to its status in the Zig gateway. The goal
is the **LLM/AI inference feature set** — the provider-backed inference surface
plus the account/billing plumbing that supports it. Each deferral names a
concrete technical blocker, not a vague "TODO".

## ✅ Implemented (provider-backed AI inference + core gateway)

| Route(s) | Backend | File |
|---|---|---|
| `POST /qai/v1/chat`, `/chat/stream` | OpenAI/Anthropic/Gemini/Grok/DeepSeek (http_sentinel) | `chat.zig`, `stream.zig` |
| `POST /qai/v1/vertex/chat`, `/vertex/chat/stream` | Vertex MaaS | `vertex.zig` |
| `POST /qai/v1/agent` | provider passthrough, client-executed tools | `agent.zig` |
| `POST /qai/v1/chat/estimate` | pure compute (registry pricing) | `estimate.zig` ⬅ new |
| `POST /qai/v1/embeddings` | OpenAI `text-embedding-3-*`, `ada-002` | `embeddings.zig` ⬅ new |
| `POST /qai/v1/images/generate` | OpenAI gpt-image-*, dall-e-3 | `images.zig` |
| `POST /qai/v1/vision/{analyze,describe,detect,ocr,quality}` | OpenAI vision (multimodal) | `vision.zig` ⬅ new |
| `POST /qai/v1/audio/tts` | OpenAI `/v1/audio/speech` | `audio.zig` ⬅ new |
| `POST /qai/v1/audio/stt` | OpenAI `/v1/audio/transcriptions` (multipart) | `audio.zig` ⬅ new |
| `POST /qai/v1/audio/sound-effects`, `/audio/music` | ElevenLabs sound-generation / music | `audio.zig` ⬅ new |
| `POST /qai/v1/credits/purchase` | Stripe Checkout Session (inline price_data) | `stripe.zig` ⬅ new |
| `POST /qai/v1/webhooks/stripe` | Stripe webhook — HMAC-verified, credits account | `stripe.zig` ⬅ new |
| `POST /qai/v1/credits/{reserve,commit,rollback}` | spend-hold API over store reservations (ownership-checked) | `reservations.zig` ⬅ new |
| `GET /qai/v1/voices`, `/voices/library` | ElevenLabs voice catalog (pass-through) | `audio.zig` ⬅ new |
| `POST /qai/v1/audio/{isolate,speech-to-speech}` | ElevenLabs (multipart audio→audio) | `audio.zig` ⬅ new |
| `POST /qai/v1/audio/voice-design` | ElevenLabs create-previews | `audio.zig` ⬅ new |
| `POST /qai/v1/audio/{dialogue,align,remix}` | ElevenLabs (dialogue script / forced-alignment / voice remix) | `audio.zig` ⬅ new |
| `POST /qai/v1/voices/clone` | ElevenLabs voice add (multipart samples) | `audio.zig` ⬅ new |
| `GET /qai/v1/video/{avatars,templates,heygen-voices}` | HeyGen catalog (pass-through) | `heygen.zig` ⬅ new |
| `POST /qai/v1/audio/starfish-tts` | HeyGen Starfish TTS | `heygen.zig` ⬅ new |
| job type `audio/dub` | ElevenLabs dubbing (submit + poll + download) | `audio.zig` ⬅ new |
| `POST /qai/v1/video/translate` + job type | HeyGen video translation (sync enqueue → async worker) | `heygen.zig` ⬅ new |
| `/qai/v1/chat/session(s)`, `/observations`, `/media-sessions`, `/notifications/devices`, `/workflows`, `/missions` | owner-scoped Firestore CRUD (list/create/get/delete) | `crud.zig` + `fs_value.zig` ⬅ new |
| `POST /qai/v1/documents/{chunk,extract,process}` | reverse-proxy → Axiom service (`QAI_AXIOM_URL`) | `proxy.zig` ⬅ new |
| `POST /qai/v1/scraper/{scrape,screenshot}` | reverse-proxy → scraper service (`QAI_SCRAPER_URL`) | `proxy.zig` ⬅ new |
| `/qai/v1/rag/surreal/{search,providers}` | reverse-proxy → SurrealDB RAG (`QAI_SURREAL_RAG_URL`) | `proxy.zig` ⬅ new |
| `POST /qai/v1/jobs`, `GET /qai/v1/jobs`, `GET /qai/v1/jobs/{id}` | in-process queue + background worker | `jobs.zig` ⬅ new |
| job type `3d/{generate,remesh,retexture,rig,animate}` | Meshy (submit + poll LRO) | `meshy.zig` ⬅ new |
| job type `video/generate` | Veo predictLongRunning (submit + poll + download) | `video.zig` ⬅ new |
| `POST /qai/v1/images/edit` | OpenAI `/v1/images/edits` (multipart) | `images.zig` ⬅ new |
| `POST /qai/v1/moderate` | Firestore `moderation_reports` (user-report) | `moderate.zig` ⬅ new |
| `POST /qai/v1/search/{web,context,answer}` | Brave Search API | `search.zig` ⬅ new |
| `POST /qai/v1/search/google` | Gemini grounded search | `grounded.zig` ⬅ new |
| `GET /qai/v1/rag/corpora`, `POST /qai/v1/rag/search` | Vertex AI RAG (server GCP creds) | `rag.zig` ⬅ new |
| `GET /qai/v1/models`, `/models/pricing`, `/pricing` | embedded models.csv | `models.zig` |
| `GET /qai/v1/account/balance` | store | `router.zig` |
| `GET /qai/v1/credits/balance` | store (live balance) | `account_stats.zig` ⬅ new |
| `GET /qai/v1/credits/packs`, `/credits/tiers` | static catalogs | `account_stats.zig` ⬅ new |
| `GET /qai/v1/admin/users`, `/admin/system/health` | store iteration / counts | `account_stats.zig`, `keys.zig` ⬅ new |
| `GET /qai/v1/account/usage`, `/account/usage/summary` | local ledger.jsonl aggregation | `ledger_query.zig` ⬅ new |
| `GET /qai/v1/stats/{overview,models,timeline}` | local ledger.jsonl aggregation | `ledger_query.zig` ⬅ new |
| `GET /admin/stats/overview`, `/admin/stats/usage/{models,endpoints,providers,top-users,daily}` | local ledger.jsonl (global) | `ledger_query.zig` ⬅ new |
| `POST/GET/DELETE /qai/v1/keys`, `/admin/accounts*`, `/admin/endpoints*` | store + Firestore | `keys.zig`, `vertex.zig` |
| `POST /qai/v1/auth/{apple,google}` | Apple/Google sign-in | `apple_auth.zig`, `google_auth.zig` |
| `GET /health`, `/healthz`, `/` | — | `router.zig` |

Each new provider-backed handler follows the `images.zig` pattern: reserve
credits → call provider → settle exact cost → ledger entry → JSON response.
Integer-tick billing only. All JSON built via `std.json.Stringify`
(no JSON-IN-FMT). `zig build`, `zig build test`, and `zig-lens --strict` all
pass (0 gating findings).

## ⛔ Deferred — concrete technical blockers

These cannot be faithfully reproduced in the Zig gateway today without adding
infrastructure that does not exist here. Grouped by the blocker.

### 1. Multipart/form-data uploads — UNBLOCKED (`multipart.zig`)
A multipart builder now exists (`multipart.zig`), built on the existing
raw-body `post()` — no `http_sentinel` change was needed. `audio/stt` and
`images/edit` are **implemented** (see table above). Still to port (all now
mechanically straightforward — same multipart pattern, just per-provider
plumbing):
- `POST /qai/v1/voices/clone`, `/audio/{dub,isolate,remix,speech-to-speech,align}` (ElevenLabs)
- `POST /qai/v1/files` (Gemini Files API upload + Firestore duration stash)

### 2. Async job orchestration — core DONE (`jobs.zig`)
`POST/GET /qai/v1/jobs` + `GET /qai/v1/jobs/{id}` now run on an in-process
queue with a single background worker (spawned in main.zig). A job's `type` is
the endpoint path it defers and its `params` is that endpoint's body; the
worker dispatches to the same body-core handlers the sync routes use, so
billing happens once at processing time. Supported types: images/generate,
images/edit, embeddings, audio/{tts,stt,music,sound-effects}.

Still deferred (each needs provider-side long-running-operation polling or
extra infra the worker doesn't yet do):
- `POST /qai/v1/video/{generate,translate,studio,digital-twin,photo-avatar}` (Veo/Sora/HeyGen LROs — the worker would need to submit + poll the provider operation).
- `POST /qai/v1/batch`, `/batch/jsonl` (batch fan-out over the job queue — tractable next step on top of `jobs.zig`).
- `/qai/v1/missions*`, `/qai/v1/workflows*`, `/qai/v1/workers/*`, `/qai/v1/conductor/*` (multi-step orchestration + external worker protocol).
- `/internal/deployments/*`, `/qai/v1/compute/*` (GPU instance lifecycle — cloud provisioning).
- `GET /qai/v1/jobs/{id}/stream` (SSE job progress — the queue is in place; needs the SSE writer hookup).
- **Note:** the in-process queue is non-durable (jobs are lost on restart). A
  WAL-backed job store would make it crash-safe — natural follow-up.

### 3. External proxy services — DONE (`proxy.zig`)
Generic authenticated reverse-proxy. `documents/{chunk,extract,process}`
(`QAI_AXIOM_URL`), `scraper/{scrape,screenshot}` (`QAI_SCRAPER_URL`), and
`rag/surreal/{search,providers}` (`QAI_SURREAL_RAG_URL`) forward to their
upstreams when the base-URL env is set (503 otherwise). Still proxy-able the
same way once their env names are confirmed:
- `POST /qai/v1/security/scan-*`, `/qai/v1/scanner/*` → zig_lens scanner service.
- `/qai/v1/rag/collections/*` → managed-collection service.

### 4. Third-party SaaS SDK surface (provider-specific, mostly multipart/async)
- ElevenLabs JSON endpoints **done**: `/audio/music`, `/audio/sound-effects` (see table).
- ElevenLabs still to port: `/audio/{dialogue,voice-design}` (JSON — tractable), `/audio/{dub,isolate,remix,speech-to-speech,align}` + `/voices/clone` (multipart), `/voices*` (GET proxy — tractable).
- HeyGen: `/video/{avatars,templates,heygen-voices}`, `/audio/starfish-tts`, `/video/studio` (async/multipart).
- Meshy 3D: `/qai/v1/3d/*` (async job).
- **Unblock:** the JSON-only remainder (dialogue, voice-design, voices list) follows the `audio.zig` ElevenLabs pattern directly; the rest need multipart/async first.

### 5. Payments & entitlements — core Stripe flow DONE (`stripe.zig`)
`credits/purchase` (Checkout Session) + `webhooks/stripe` (HMAC-verified,
credits the account) are implemented against the Stripe REST API directly —
no SDK needed (Stripe is form-encoded + Bearer-auth). Confirmed against the
working dropship/Lutuno Stripe setup. Still to wire:
- `POST /qai/v1/account/billing-portal` (Stripe billing-portal session — same REST pattern, a few lines).
- `/credits/{commit,reserve,rollback}` (per-request spend holds — needs account-level reservation aggregation).
- `/qai/v1/kitchenshare/iap/*`, `/qai/v1/quantify/iap/*` (App Store / Play **receipt verification** — distinct verification APIs).
- `/qai/v1/licenses/*` (signed-license minting — needs the signing key tooling).
- **Note:** the webhook idempotency set is in-memory (non-durable across
  restart). Persisting processed session ids to the store/WAL is the
  follow-up to make double-credit impossible across a restart.

### 6. App-specific SaaS verticals (not LLM-gateway features)
- `/qai/v1/kitchenshare/*`, `/qai/v1/quantify/*`, `/qai/v1/recipebox/*`, `/qai/v1/reservations/*`
- `/qai/v1/contact`, `/qai/v1/twilio/*`, `/qai/v1/notifications/*`, `/qai/v1/onboarding/*`, `/qai/v1/media-sessions/*`, `/qai/v1/observations/*`, `/qai/v1/sessions/*`
- These are tenant application features layered on the gateway, out of scope for the inference gateway itself.

### 7. History/analytics reads — mostly DONE via local ledger aggregation
`ledger_query.zig` now reads the local `ledger.jsonl` and serves
`account/usage`, `account/usage/summary`, `stats/{overview,models,timeline}`,
and `admin/stats/{overview,usage/models}` with no external dependency (see
table). Done locally now also: `/admin/stats/usage/{endpoints,providers,top-users,daily}`
(provider derived from the model registry). Still BigQuery-only — the
two-axis time-series combos and the partner dimension the local ledger
doesn't carry:
- `/admin/stats/usage/{providers/daily,partners}`, `/admin/analytics/*`.
- **Unblock:** add a BigQuery read client, or record `partner_id` on ledger
  lines and add the day×provider cross-tab to `ledger_query.zig`.

## Suggested next step
Multipart is now unblocked (`multipart.zig`) and STT + image-edit are live.
The remaining tractable, no-new-dependency work is **#7** (admin/stats reads —
pure `ledger`/`store` aggregation) and the JSON-only ElevenLabs endpoints
(`audio/music`, `audio/sound-effects`). The big remaining categories (#2 async
jobs, #5 payments) each need genuinely new infrastructure (a durable job
queue; a Stripe client + receipt verification) and are the natural larger
follow-ups.
