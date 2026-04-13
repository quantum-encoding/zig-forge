# Shared Context for Endpoint Development

**Read this ENTIRE document before writing any code.**

You are implementing a new endpoint for the zig-ai-server. This document describes every pattern, convention, and constraint you must follow. Deviating from these patterns will break the server or fail code review.

## Architecture

The server is a concurrent HTTP API server in Zig 0.16, deployed on Cloud Run. It proxies requests to AI provider APIs (Anthropic, DeepSeek, OpenAI, xAI, Google, ElevenLabs, etc.) and handles authentication, billing, and response formatting.

Key files:
- `src/router.zig` — request dispatch (register your route here)
- `src/chat.zig` — reference handler implementation
- `src/billing.zig` — billing reserve/commit/rollback
- `src/security.zig` — input validation limits
- `src/models.csv` — provider registry (add your model here if needed)
- `src/tests.zig` — test root (import your test module here)
- `docs/HARDENING_RULES.md` — full security/correctness rules

## Handler Function Signature

Every handler follows one of two patterns:

### Non-streaming (returns JSON):
```zig
pub fn handle(
    request: *http.Server.Request,  // not used if body is pre-read
    allocator: std.mem.Allocator,
    // ... provider-specific params
) Response {
    // Return: router.Response { .status, .body, .headers }
}
```

### With pre-read body (called from router):
```zig
pub fn handleWithBody(
    _: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: ?std.Io,
    store: ?*store_mod.Store,
    auth: ?*const types.AuthContext,
    ledger: ?*ledger_mod.Ledger,
    body: []const u8,
) Response {
```

### Response type:
```zig
pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: []const http.Header = &json_headers,
    handled: bool = false,  // true for SSE (handler wrote directly to stream)
};
```

## Request Processing Pattern

Every endpoint follows this exact sequence:

```zig
pub fn handle(...) Response {
    // 1. Parse request body
    const body = json_util.readBody(request, allocator, security.Limits.max_chat_body) catch |err| {
        return errorResp(err);
    };
    defer allocator.free(body);
    if (body.len == 0) return errorResp(error.EmptyBody);

    const parsed = std.json.parseFromSlice(MyRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return errorResp(error.OutOfMemory);
    defer parsed.deinit();
    const req = parsed.value;

    // 2. Validate input
    if (req.model.len == 0) return .{ .status = .bad_request, .body = ... };

    // 3. Billing reserve (BEFORE calling the provider)
    var reservation_id: ?u64 = null;
    if (store) |s| if (auth) |a| if (io) |io_handle| {
        const input_estimate = billing.estimateInputTokens(body.len);
        const result = billing.reserveWithCap(
            s, io_handle, a, req.model,
            max_tokens, input_estimate, "/qai/v1/your/endpoint",
        ) catch {
            return .{ .status = .payment_required, .body =
                \\{"error":"insufficient_balance","message":"Not enough balance"}
            };
        };
        reservation_id = result.reservation_id;
        // For token-based billing, cap max_tokens:
        // max_tokens = result.capped_max_tokens;
    };

    // 4. Call provider API
    const provider_result = callProvider(allocator, req, environ_map) catch |err| {
        // ROLLBACK on failure
        if (reservation_id) |rid| if (store) |s| if (io) |io_handle|
            billing.rollback(s, io_handle, rid);
        return providerErrorResponse(err);
    };

    // 5. Commit billing with actual usage
    if (reservation_id) |rid| if (store) |s| if (io) |io_handle| {
        const tier = if (auth) |a| a.account.tier else types.DevTier.free;
        billing.commit(s, io_handle, rid, req.model,
            provider_result.input_tokens, provider_result.output_tokens, tier);
    };

    // 6. Return response
    return .{ .body = provider_result.json };
}
```

## Calling Provider APIs

Use the GcpContext for GCP-authed providers (Vertex), or create a fresh HttpClient for API-key-authed providers:

### API key auth (most providers):
```zig
const api_key = environ_map.get("PROVIDER_API_KEY") orelse {
    return .{ .status = .internal_server_error, .body =
        \\{"error":"config_error","message":"Server missing PROVIDER_API_KEY"}
    };
};

var http_client = hs.HttpClient.init(allocator) catch
    return .{ .status = .internal_server_error, .body = ... };
defer http_client.deinit();

var resp = http_client.post(url, &.{
    .{ .name = "Authorization", .value = auth_header },
    .{ .name = "Content-Type", .value = "application/json" },
}, payload) catch return providerErrorResponse(error.ApiRequestFailed);
defer resp.deinit();
```

### GCP token auth (Vertex):
```zig
const ctx = gcp_ctx orelse return .{ .status = .service_unavailable, ... };
var resp = try ctx.post(url, payload);
defer resp.deinit();
```

## Error Response Format

Always use this shape:
```json
{"error": "short_code", "message": "Human-readable description"}
```

Error codes: `invalid_request`, `invalid_json`, `invalid_model`, `insufficient_balance`,
`provider_error`, `config_error`, `rate_limited`, `not_found`, `internal`.

**Never leak internal error names** (`@errorName(err)`) to the client. Map to generic codes.

## Billing Models

Different endpoints use different billing:

- **Per-token** (chat, embeddings): `billing.reserveWithCap` → dynamic output capping
- **Per-query** (search): flat rate, use `store.reserve(io, account_id, key_hash, FLAT_COST, ...)`
- **Per-unit** (images, video, audio): fixed cost per image/second/etc.
- **Free** (voices list, models): no billing needed

For flat-rate billing:
```zig
const COST_PER_QUERY: i64 = 100_000_000; // $0.01
if (store) |s| if (auth) |a| if (io) |io_handle| {
    reservation_id = s.reserve(io_handle, a.account.id.slice(), a.key_hash,
        COST_PER_QUERY, "/qai/v1/search/web", "brave-search") catch {
        return .{ .status = .payment_required, ... };
    };
};
```

## Registering Your Route

In `src/router.zig`, inside `routeApiV1Authed`:

```zig
// ── Your Endpoint ──────────────────────────────────
if (std.mem.eql(u8, path, "your/endpoint")) {
    if (method != .POST) return handlers.methodNotAllowed(request, allocator);
    return your_handler.handle(request, allocator, environ_map, io, store, auth, server_ledger);
}
```

And add the import at the top:
```zig
const your_handler = @import("your_handler.zig");
```

## Adding to models.csv (if new provider/model)

Format: `Provider,Category,Internal ID,API Model ID,Display Name,Context Window,Input $/M,Output $/M,Cached $/M,Per Unit Price,Price Unit,RPM,Margin,Route,Notes`

Example:
```
ElevenLabs,Audio,—,eleven-turbo-v2.5,ElevenLabs Turbo v2.5,—,—,—,—,$0.15,per 1K chars,500,1.25,direct,Text-to-speech
```

## Testing Requirements

Every new endpoint MUST have:

### 1. Unit tests (in your handler file or a `_test.zig` file):
- Request parsing with missing fields
- Request parsing with invalid values
- Response format validation

### 2. Integration test (in `integration_test.zig` or similar):
- Billing reserve/commit round-trip
- Auth required (returns 401/403 without key)

### 3. Smoke test entry (in `scripts/smoke_test.sh`):
```bash
# Test N: Your endpoint
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:$PORT/qai/v1/your/endpoint" \
  -H "Authorization: Bearer $BOOTSTRAP_KEY" \
  -H "Content-Type: application/json" \
  -d '{"minimal":"request"}')
assert_eq "POST /qai/v1/your/endpoint returns 200" "200" "$status"
```

### 4. Import in tests.zig:
```zig
const your_test = @import("your_handler_test.zig");
test "module tests imported" { _ = your_test; }
```

## Build & Verify

Before submitting:
```bash
zig build              # must compile
zig build test         # all tests pass
./scripts/smoke_test.sh  # all smoke tests pass
```

## What NOT to do

- **Don't** use `catch {}` on the request path (log + propagate)
- **Don't** hold the store mutex during HTTP I/O
- **Don't** leak `@errorName(err)` to clients
- **Don't** hardcode provider routing — use models.csv
- **Don't** skip billing reserve before calling a provider
- **Don't** forget `defer allocator.free(...)` on every allocation
- **Don't** use `FixedStr32` for IDs that could be long — use FixedStr64
- **Don't** create files without reading `docs/HARDENING_RULES.md` first
