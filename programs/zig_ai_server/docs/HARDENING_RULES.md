# Hardening Rules — zig-ai-server

**Required reading before writing any new endpoint or handler.**

This document encodes every security, correctness, and architectural decision we've made. Each rule has a reason — usually a bug we've already paid for. Maintain the standard.

---

## 1. Architecture Rules

### 1.1 Module boundaries

- **One handler per endpoint** in `src/<endpoint>.zig` (e.g. `chat.zig`, `vertex.zig`, `genai.zig`, `agent.zig`). Do NOT cram multiple endpoints into one file.
- **Provider isolation**: different auth mechanisms go in different files. `vertex.zig` = GCP token auth (aiplatform.googleapis.com). `genai.zig` = API key auth (generativelanguage.googleapis.com). Never mix. ([commit `9758475`](../../../commits/9758475))
- **Shared logic in `security.zig`, `billing.zig`, `auth_pipeline.zig`** — do not duplicate constants, validation, or error shapes.
- **Router is a dispatcher only**. It reads the body once, peeks the model name, and dispatches to the right handler. No business logic.

### 1.2 Provider registry

- **Routing is driven by `models.csv`**, not hardcoded prefixes. Every model has a `provider` column (Anthropic, DeepSeek, etc.) and a `route` column (direct, vertex_maas, vertex_native, vertex_dedicated, google_genai).
- `models.getRoute(model_id)` returns the route; the router dispatches to the matching handler.
- Adding a new model = adding a CSV row, not changing code. ([commit `9758475`](../../../commits/9758475))
- **DON'T** add `if model.startsWith(...)` prefix matching in router or handlers. That's the anti-pattern we fixed.

### 1.3 File layout for a new endpoint

```
src/
  <endpoint>.zig         ← handler (handleWithBody + handleCore)
  models.csv             ← add a row with provider, route, pricing
  router.zig             ← add route registration (1-2 lines)
  tests.zig              ← import the endpoint's test module
```

---

## 2. Security Rules

### 2.1 Authentication

- **Fail-closed at every step**. The auth pipeline returns early on any missing/invalid field. See `auth_pipeline.zig` for the canonical 12-step sequence: header → token format → SHA-256 hash → key lookup → revoked check → expiration → account lookup → frozen check → balance check → spend cap → endpoint scope → rate limit.
- **Constant-time token comparison** via `security.constantTimeEql`. Never use `std.mem.eql` on secrets.
- **Tokens are SHA-256 hashed before storage**. The raw key is only seen once (at mint time). Storage lookups use the hash. ([commit `d3400fa`](../../../commits/d3400fa))
- **X-API-Key takes priority over Authorization: Bearer** — this is to work around Cloud Run IAM header clashes. ([commit `e2df5ce`](../../../commits/e2df5ce))

### 2.2 OIDC / Apple / Google Sign In

- **Full RS256 signature verification** against the provider's JWKS. Never trust JWT claims without verifying the signature. ([commit `d16cec5`](../../../commits/d16cec5))
- **JWKS cache with 24h TTL + kid-miss refresh**: on an unknown kid, force-refresh JWKS once before rejecting. Handles provider key rotation.
- **Strict PKCS#1 v1.5 padding check**: byte-exact `std.mem.eql` against the full EM structure (block type, PS, DigestInfo, hash). Never substring match the hash — Bleichenbacher attacks.
- **Nonce verification**: if `raw_nonce` is provided, SHA-256(rawNonce) must match the JWT `nonce` claim exactly.
- **Allowed audiences are hardcoded**. Don't accept any audience the provider signed.

### 2.3 Rate limiting

- **IP-keyed rate limit on `/qai/v1/auth/*`** (10/min default). Prevents sign-in brute force. Extract IP from `X-Forwarded-For` (Cloud Run sets it). See `auth_ratelimit.zig`. ([commit `630fb19`](../../../commits/630fb19))
- **Per-key rate limit on all other authenticated endpoints**. Configured in `key.scope.rate_limit_rpm`. Token bucket with monotonic counter. See `ratelimit.zig`.
- **Bucket count is capped** (4096 for IP buckets) to prevent memory exhaustion from spam.

### 2.4 Input validation

- **Body size limits**: `security.Limits.max_chat_body` = 1MB, `max_agent_body` = 256KB, `max_generic_body` = 10MB. Enforced at `json_util.readBody`.
- **Message count cap**: `max_messages` = 1000. Prevents unbounded array allocation.
- **Model name length**: `max_model_name` = 128. Prevents CSV-matching DoS.
- **Max tokens cap**: `max_tokens_cap` = 1,000,000. Hard ceiling regardless of what the user requests.
- **Path validation** (for agent file operations): blocks `..`, absolute paths, null bytes, `\`, `~/`. See `security.validatePath`.
- **Command validation** (for agent shell exec): blocklist includes `rm -rf /`, `sudo`, `curl`, `wget`, `reboot`, `shutdown`, and chaining via `;`, `|`, backticks. See `security.validateCommand`.
- **Workspace ID sanitization**: alphanumeric + `-_` only, max 128 chars.

### 2.5 Secrets

- **All provider API keys live in GCP Secret Manager**, not env vars. Rotated without redeploy via `gcloud secrets versions add`. See `deploy/migrate_secrets.sh`.
- **`QAI_BOOTSTRAP_KEY`** is also in Secret Manager. Never commit to git, never put in env files.
- **Cloud Run runtime SA needs `roles/secretmanager.secretAccessor`** — granted once at setup.

### 2.6 Side channels

- **Timing-safe crypto** — we use `std.crypto.ff.Modulus.powWithEncodedExponent` for RSA verification, which uses `cmov` for constant-time table lookups. `std.options.side_channels_mitigations` must NOT be `.none` (enforced at comptime in `gcp_auth/rsa.zig`).
- **Do not enable `link_libc = false` on macOS**: the http-sentinel crypto fallback is not yet clean. See build.zig note.

---

## 3. Correctness Rules

### 3.1 Memory management

- **Every `try` allocation has a corresponding `defer free`** OR is stored in a struct with a `deinit` method.
- **Fixed-size strings (`FixedStrN`) for hot-path storage** — no heap allocation per request. Use `FixedStr64` for account IDs (handles Apple 48-char subs), `FixedStr128` for key names, `FixedStr256` for emails. ([commit `b4c15f0`](../../../commits/b4c15f0))
- **`FixedStr32` truncates silently at 32 chars**. If your ID is longer, use a bigger size. This is the Apple-sub-truncation bug — don't repeat it.
- **`allocator.create()` returns uninitialized memory**. Fields with `= default` values in the struct definition are NOT initialized by `create`. You must set every field explicitly. The `done = false` bug on `StreamingResponse` caused silent empty streams for weeks. ([commit `47e7cd1`](../../../commits/47e7cd1))
- **`Store.deinit()` must free duped strings** — the keys of `accounts` HashMap are `allocator.dupe`'d and need explicit free. Detected by `testing.allocator` leak check. ([commit `715487e`](../../../commits/715487e))

### 3.2 Concurrency

- **Hold the mutex for the minimum possible time**. Any HTTP I/O, Firestore write, or provider call MUST happen outside the mutex scope. ([commit `630fb19`](../../../commits/630fb19))
- **The hot-path billing flow never holds the mutex across network I/O**: `createAccount`/`createKey`/`creditAccount` all release the mutex after WAL + in-memory write, then do the Firestore PATCH.
- **Atomic counters for shared state that survives function returns**: `active_connections` is module-level `std.atomic.Value(u32)`. Do NOT use stack-local atomics with detached threads — detached threads outlive the stack frame and will use-after-free. ([commit `44f5e15`](../../../commits/44f5e15))
- **Background threads check `shutdown_requested.load(.acquire)` every iteration** so SIGTERM actually stops them.

### 3.3 Error handling

- **Catch-all `catch {}` is only for fire-and-forget operations** (logging, background flushes). Never swallow errors on the request path.
- **Errors must be surfaced to the client** with a specific error code + JSON body. Never return `.ok` on failure.
- **Log the error name**, not just a generic message. The `Firestore saveAccount FAILED: HttpConnectionClosing` log was what let us find the stale-connection bug.
- **Error response format**: `{"error": "short_code", "message": "human description"}`. Every handler must conform.

### 3.4 Exit cleanup

- **Call `std.process.exit(0)` after shutdown flush**. Do NOT rely on defer cleanup in `main` — Zig 0.16's I/O subsystem teardown has an integer overflow bug that panics. All state must be flushed before `exit(0)`. ([commit `42b32df`](../../../commits/42b32df))
- **Graceful shutdown order**: drain active connections (5s max) → `flushDirtyAccounts` → `bq_audit.waitPending` → `store.snapshot` → `process.exit(0)`.

---

## 4. HTTP / SSE Rules

### 4.1 Request body

- **Read the body once, in the router**. Pass it as a parameter to `handleWithBody(...)` variants. Both streaming and non-streaming handlers must accept pre-read bodies.
- **`json_util.readBody` with explicit size limit**. Never unlimited. Pick the right limit from `security.Limits`.
- **Do NOT call `readBody` twice on the same request** — the body is a stream, it's consumed. ([commit `42b32df`](../../../commits/42b32df))

### 4.2 Streaming (SSE)

- **Use `postSseStream` for real incremental streaming**. It keeps the HTTP Request on the stack so TLS pointers stay valid. ([commit `58b89a8`](../../../commits/58b89a8))
- **The Anthropic API pads data lines with trailing whitespace**. The SSE reader must `trimEnd` both `\r\n` and ` \t` from lines AND from the extracted payload. ([commit `e9ac095`](../../../commits/e9ac095))
- **Disable keep-alive on SSE connections** (`response.head.keep_alive = false`): SSE streams don't fully consume the body, so returning the connection to the pool causes stale data on the next request. ([commit `e3a4d30`](../../../commits/e3a4d30))
- **Drain the socket after the SSE loop** (`reader.discardRemaining()`) so the connection can be closed cleanly.
- **SSE event format must match the SDK**:
  ```
  data: {"type":"content_delta","delta":{"text":"..."}}\n\n
  data: {"type":"usage","input_tokens":N,"output_tokens":N}\n\n
  data: {"type":"done"}\n\n
  ```
- **The `done` event is required**. Do not rely on `[DONE]` sentinels — the QuantumSDK parses `{"type":"done"}`.
- **Error events flow through `accumulated` text**, not just `onError` callbacks. Otherwise the race condition in SwiftUI's fire-and-forget `Task(@MainActor)` drops them. ([commit `37f9dd4`](../../../commits/37f9dd4))

### 4.3 Conversation history

- **Streaming handlers MUST pass the full message array** to the provider via `sendMessageStreamingWithContext`. Extracting only the last user message gives the provider amnesia. The first commit that shipped streaming had this bug. ([commit `37f9dd4`](../../../commits/37f9dd4))
- **Alternate user/assistant messages** in the context array (except for the leading system prompt).

### 4.4 Non-streaming

- **OpenAI convention**: `"stream": true` in the body routes to the streaming handler; absence or `false` routes to the blocking JSON handler. Both live at `/qai/v1/chat`. ([commit `bfe1f78`](../../../commits/bfe1f78))
- **Response shape for non-streaming**:
  ```json
  {
    "id": "...",
    "model": "...",
    "content": [{"type": "text", "text": "..."}],
    "usage": {"input_tokens": N, "output_tokens": N, "cost_ticks": N},
    "stop_reason": "end_turn",
    "cost_ticks": N
  }
  ```

### 4.5 CORS

- **Every response includes CORS headers** (Access-Control-Allow-Origin: *), not just OPTIONS preflight. Applied uniformly in `handleConnection`.

---

## 5. Billing Rules

### 5.1 Two-phase commit

- **Every provider call goes through `billing.reserveWithCap` → provider → `billing.commit` or `billing.rollback`**. Never skip the reserve step.
- **Reserve deducts the upper bound; commit refunds the difference**. Rollback returns the full amount.
- **Reserve happens BEFORE the provider call**. If reserve fails, return 402 Payment Required; never call the provider on a broke account.
- **Commit/rollback always happens** — use `errdefer billing.rollback(...)` pattern so an error mid-handler cleans up.

### 5.2 Dynamic output capping

- **Never send worst-case max_tokens to the provider**. Calculate `affordable_output_tokens` from the user's balance, cap the requested `max_tokens` to that amount. ([commit `64540fa`](../../../commits/64540fa))
- **Input cost is deducted first**, then the remainder determines affordable output tokens. See `billing.calculateCap`.
- **Minimum reservation is 1000 ticks** to prevent zero-cost bypass.
- **If a user has $1 balance, they should get a tiny response, not a 402**. That's the whole point of capping — don't kneecap users with budget limits.

### 5.3 Pricing

- **All pricing in `models.csv`**, driven by `models.getPricing(model_id)`.
- **Margin applied by tier**: free = 30%, hobby = 20%, pro = 10%, enterprise = 5%. Applied in `billing.actualCost`.
- **Ticks are integers**, 10 billion ticks = $1. Never use floats for balance math.

### 5.4 Balance updates

- **In-memory update first, background flush to Firestore every 5s**. See `main.backgroundFlushLoop`.
- **Dirty set tracks which accounts need flushing**. Flushed under snapshot-and-release pattern (release lock before Firestore PATCH).
- **On crash, up to 5s of balance updates can be lost**. WAL replay recovers the rest.

---

## 6. Storage / Persistence Rules

### 6.1 WAL (Write-Ahead Log)

- **Every mutation writes to WAL before updating in-memory state**. WAL is append-only, CRC32-checked per entry.
- **WAL replay on startup** restores state from last snapshot + unwritten entries. Implemented in `store.recover()` with a real callback (was a stub for weeks). ([commit `630fb19`](../../../commits/630fb19))
- **WAL rotation when size > 10MB**: the background flush thread forces a snapshot and truncates.
- **Corrupted entries stop replay** — the store loads everything valid, then halts at the bad entry. Better than crashing.

### 6.2 Snapshot

- **Snapshot is a JSON file** with all accounts + keys. Written on SIGTERM and on WAL rotation.
- **Snapshot + WAL replay together** reconstruct the full state. Loading snapshot alone is incomplete.

### 6.3 Firestore

- **Writes use HTTP PATCH, not PUT**. Firestore REST API rejects PUT for document create/update with 404. ([commit `2cff7be`](../../../commits/2cff7be))
- **Fresh HTTP connection per Firestore write** via `GcpContext.patchFresh()`. The pooled connection from prior GETs goes stale (HttpConnectionClosing errors). Retry on the same stale connection fails the same way. ([commit `203df12`](../../../commits/203df12))
- **Cloud Run runtime SA needs `roles/datastore.user`** to write. Reads work with just the default role — don't be fooled by successful reads into thinking writes work.
- **Write-through is optional** — the server runs fine with `gcp_ctx = null` (local-only WAL mode). Don't hard-require Firestore in handlers.

---

## 7. Testing Rules

### 7.1 Every new endpoint must have

1. **Unit tests for request parsing** (invalid JSON, missing fields, oversized bodies)
2. **Integration tests for auth** — valid key, revoked, expired, frozen account, insufficient balance
3. **Billing round-trip test** — reserve → commit → verify balance delta
4. **Smoke test entry** in `scripts/smoke_test.sh` — at minimum: 401 without auth, 400 on bad JSON, 200 with valid request
5. **Response format assertion** — the SDK must be able to decode it

### 7.2 Test patterns

- **Use `TestFixture`** from `integration_test.zig` for anything touching the store. Builds an in-memory account + key in a temp data dir.
- **`testing.allocator` catches leaks** — run tests regularly to catch regressions in cleanup logic.
- **WAL tests use unique temp dirs** via `uniqueDataDir(io, name)`. Never write to `./data` in tests.
- **Run both** `zig build test` AND `./scripts/smoke_test.sh` before pushing.

### 7.3 Do NOT

- **Don't skip tests to "make the build pass"**. If a test is broken, fix it or delete it with a commit message explaining why.
- **Don't mock the store** in integration tests. Use the real store with a temp data dir.
- **Don't test against the real deployed server** in unit tests. Use smoke_test.sh for that.

---

## 8. Bug Database — "DON'T" List

Every past bug is a rule. Each one was a surprise; none should happen twice.

| Commit | Lesson |
|---|---|
| `2cff7be` | **DON'T** use HTTP PUT for Firestore upsert — it returns 404. Use PATCH. |
| `203df12` | **DON'T** reuse HTTP connections for Firestore writes after GETs — they go stale (`HttpConnectionClosing`). Use `patchFresh`. |
| `b4c15f0` | **DON'T** use `FixedStr32` for IDs that can be >32 chars. Apple subs are 48 chars. Silent truncation → HashMap miss → infinite account recreation. |
| `47e7cd1` | **DON'T** rely on struct field defaults (`done: bool = false`) after `allocator.create()`. It returns uninitialized memory. Set every field. |
| `e9ac095` | **DON'T** skip `trimEnd` on SSE data lines — Anthropic pads with trailing spaces, JSON parser rejects. |
| `e3a4d30` | **DON'T** pool HTTP connections used for SSE streaming — leftover data poisons the next request. Set `keep_alive = false`. |
| `58b89a8` | **DON'T** copy `std.http.Client.Request` to the heap — internal TLS pointers become invalid. Keep it on the stack. |
| `37f9dd4` | **DON'T** extract only the last user message in streaming handlers — provider needs the full conversation history. Use `sendMessageStreamingWithContext`. |
| `5db5684` | **DON'T** do raw string matching on JSON-encoded model names — Swift escapes `/` as `\/`. Unescape before CSV lookup. |
| `44f5e15` | **DON'T** store shared counters as stack-local atomics when detached threads outlive the stack. Module-level atomics only. |
| `42b32df` | **DON'T** rely on defer cleanup in Zig 0.16's `main` — I/O subsystem teardown panics with integer overflow. Call `std.process.exit(0)` after flush. |
| `bfe1f78` | **DON'T** route streaming by URL path alone — the SDK sends `/qai/v1/chat` with `"stream":true` in the body. Check the body. |
| `9758475` | **DON'T** hardcode provider routing via prefix matching in `if` chains. Use `models.csv` + registry lookup. |
| `64540fa` | **DON'T** fail requests with 402 just because max_tokens*price > balance. Calculate affordable tokens and cap max_tokens. |
| `d16cec5` | **DON'T** ship JWT auth that only checks claims. You MUST verify the RS256 signature against JWKS. Previous commit shipped claims-only. |
| `630fb19` | **DON'T** hold the store mutex across Firestore network I/O — blocks all other requests for 50-100ms. Phase 1: mutex. Phase 2: network. |
| `715487e` | **DON'T** forget to free duped strings in `deinit()` — `testing.allocator` catches it but production leaks silently. |
| `d352c66` | **DON'T** swallow errors with `catch {}` on the request path. The silent `Firestore saveAccount FAILED` bug cost hours. Log errors by name. |

---

## 9. Deployment Rules

### 9.1 Deploy checklist

1. Run `zig build test` — all tests must pass.
2. Run `./scripts/smoke_test.sh` — all smoke tests must pass.
3. Review git diff for new `catch {}` swallowed errors.
4. Run `./deploy/deploy.sh` (includes local build check + cloud build + deploy + health check).

### 9.2 Cloud Run config

- **min-instances=0** (scales to zero when idle — cheap).
- **max-instances=10** (ceiling for runaway scaling).
- **concurrency=80** (per-instance concurrent connections).
- **1 vCPU, 512Mi memory** — sufficient per benchmarks; Zig uses ~10% of this at steady state.
- **timeout=300s** (5 minutes) — long enough for slow provider streams.

### 9.3 Rotating secrets

```bash
# Rotate one secret
echo 'new-value' | gcloud secrets versions add <name> --project=metatron-cloud-prod-v1 --data-file=-

# Redeploy to pick up the latest version
./deploy/deploy.sh
```

### 9.4 Monitoring

- **Cloud Run logs**: `gcloud run services logs read zig-ai-server --region=europe-west1`.
- **Firestore persistence**: check `zig_accounts` and `zig_keys` collections directly.
- **Billing**: `ledger.jsonl` is appended per billing event.
- **Audit**: every request logged to `audit.jsonl`.

---

## 10. Code Review Checklist

Before merging ANY new handler or change to an existing one:

- [ ] Request body read with size limit (not unlimited)
- [ ] Auth pipeline invoked if endpoint is not in `/qai/v1/auth/*`
- [ ] Billing reserve → commit/rollback pattern (for any provider call)
- [ ] Dynamic output capping applied (not hardcoded max_tokens)
- [ ] Error responses use the `{"error": "...", "message": "..."}` shape
- [ ] No `catch {}` on the request path (logs + propagate instead)
- [ ] No synchronous HTTP I/O under the store mutex
- [ ] FixedStr sizes are large enough for their data
- [ ] All `allocator.create()` structs have every field explicitly set
- [ ] Streaming handlers use `sendMessageStreamingWithContext` (full history)
- [ ] Response format matches what the SDK parses (`content_delta`, `usage`, `done`)
- [ ] Unit test covers request parsing + response shape
- [ ] Integration test covers auth + billing round-trip
- [ ] Smoke test entry added (at minimum: 401/400/200)
- [ ] `models.csv` updated if new model/provider added
- [ ] Route registered in `router.zig`
- [ ] `zig build test` passes
- [ ] `./scripts/smoke_test.sh` passes

---

*Last updated: 2026-04-09. Maintained alongside the codebase — when you fix a bug, add it to the Bug Database.*
