# zig_ai_server — red-team findings

Audit date: 2026-04-27. Manual review across `src/` (10,675 LoC). Routes mapped from `router.zig`. Auth, billing, JWT verification, agent sandbox, WAL/Firestore persistence, rate limiting and CORS reviewed. No patches applied.

Severity legend: **CRITICAL** = exploitable now / direct authn bypass / financial fraud, **HIGH** = exploitable with mild prerequisites or material loss, **MEDIUM** = bug class with real impact but bounded blast.

---

## CRITICAL

### C1. JWT issuer (`iss`) never validated; `aud` check is bypassable by omitting the claim
Files: `src/oidc.zig:66-80, 142-149`, `src/apple_auth.zig:139-154`, `src/google_auth.zig:153-168`.

`VerifiedClaims` doesn't even capture `iss`. Apple/Google handlers compare `aud` only — and the comparison is gated on `if (claims.aud) |aud| { … }` (`apple_auth.zig:140`, `google_auth.zig:154`). A signed JWT that simply omits `aud` passes audience validation entirely.

Combined effect:
- Apple endpoint: any Apple-issued JWT (including tokens minted for *third-party* apps that use Sign in with Apple) is accepted, because Apple JWKS verifies the signature and `aud` is no longer enforced. Attackers can authenticate as the corresponding `sub` and immediately receive a fresh `qai_k_…` key with the $1 welcome credit.
- Google endpoint: any Google-issued JWT with `aud` stripped is accepted. The `client_id` allowlist (line 92-103) is only consulted when the *request body* supplies `client_id` — a non-zero attacker just omits it.

Exploit sketch:
```
# Get an Apple/Google ID token from any IdP-trusting app you control,
# strip the aud claim before signing OR forge an unsigned aud-less token
# (still must be RS256-signed by Apple/Google — fine, real Apple tokens
# without aud are accepted).
curl -X POST https://api.cosmicduck.dev/qai/v1/auth/apple \
     -d '{"id_token":"<aud-stripped Apple JWT>"}'
# → returns api_key + $1 credit, infinitely callable per IP/min limit.
```

Fix: parse and require `iss` matching `APPLE_ISSUER` / one of `GOOGLE_ISSUERS`; treat missing `aud` as a hard failure (require it to exist *and* match the allowlist).

### C2. `/qai/v1/agent` discards auth and shares a default `/tmp` workspace across all users
Files: `src/agent.zig:178-282` (and `src/cloudrun.zig`, which is a near-identical second copy).

`handle()` is wired through the auth pipeline by `router.zig`, but the very first thing it does is:
```zig
_ = store; // TODO: billing for agent calls
_ = auth;
_ = ledger;
```
It then derives `workspace_id = req.workspace_id orelse "agent-session"` and constructs `/tmp/qai-agent-agent-session` (`agent.zig:239-249`, `createWorkspace` line 677-693). Default ID is the same constant for every caller.

Consequences:
1. **Cross-tenant data exposure / tampering.** Any authed user can `read_file` files written by another user's agent run, `write_file` over them, or `bash`-execute on the same checkout. The git auto-commit (`gitAutoCommit`) attributes every action to the same shared repo.
2. **Free agent calls.** No `reserve`, no `commit`, no per-account ticks. `account_mod.recordTicks(cost_ticks)` (`agent.zig:428`) only updates a single global atomic counter — billing is lost.
3. **No `frozen`/balance/spend-cap enforcement.** A frozen or 0-balance user that managed to authenticate can still spend provider quota.

Note: `cloudrun.zig` is byte-different from `agent.zig` but exposes the same handler shape — reviewing the routed `cloudrun` path (`router.zig:254-256`) shows the same `_ = auth;` pattern. Both endpoints share the bug.

Exploit sketch: `POST /qai/v1/agent {"goal":"cat $(ls /tmp/qai-agent-agent-session)","model":"deepseek-chat","capabilities":["code_execution"]}` — read another tenant's source.

Fix: require `auth != null`, scope `workspace_id` by `auth.account.id`, run `reserve` / `commit` like `chat.zig`.

### C3. `nowMs()` is a global atomic counter, not a clock — every time-based check is broken
Files: `src/store/types.zig:172-178`.

```zig
var timestamp_counter: std.atomic.Value(i64) = .init(0);
pub fn nowMs() i64 {
    return timestamp_counter.fetchAdd(1, .monotonic) + 1;
}
```

This is used as if it were epoch milliseconds across the codebase. Concrete impacts:

- **API keys never effectively expire** (`auth_pipeline.zig:84-94`, `keys.zig:101-104`). `expires_at = now + hours * 3600 * 1000`, where `now` is a *call counter*. To reach `expires_at`, the server has to make ~3.6 million `nowMs()` calls — could be days or never. Combined with C1, a one-time-issued key from a leaked Apple JWT keeps working indefinitely.
- **Per-key rate limiter (`ratelimit.zig:67`) and per-IP auth rate limiter (`auth_ratelimit.zig:77`) are mathematically broken**: `refill = rpm * elapsed / 60`. `elapsed` is the delta between two counter ticks (frequently `1`), so for `rpm=10` we compute `10*1/60 = 0`. Tokens never replenish; once a bucket is drained, it stays drained for the bucket's lifetime — *or* tokens regenerate at random based on unrelated server activity (every billing event, account update, audit row also bumps the counter).
- **Frozen/created/updated timestamps in WAL & Firestore are nonsense**, breaking forensics and any future TTL.
- Apple/Google JWT `exp` checks use `oidc.epochSeconds(io)` which *is* a real clock — so token expiration works, but everything `nowMs()`-based does not. Inconsistency obscures the bug.

Exploit sketch: any operator who issues a "1-hour" key gets a forever key. Rate limits can be drained then bypassed once enough ambient traffic accumulates.

Fix: `nowMs` must read `io.vtable.now(io.userdata, .real).nanoseconds / std.time.ns_per_ms`.

### C4. `bash` tool blocklist is trivially bypassable; agent has effective code execution as the server UID
Files: `src/security.zig:50-130`, `src/agent.zig:474-540`.

The blocklist is a literal substring scan over `command`. None of the following are blocked:
- `/usr/bin/curl` (only matches `"curl "` prefix or `| curl ` after pipe; not `; /usr/bin/curl`, not `xargs curl`, not `${PATH%/*}/curl`, not `bash -c "curl …"`).
- `cur\l`, `c"u"rl`, `\curl`, `eval $(echo Y3VybA== | base64 -d)`.
- `python -c "import socket,os,pty;…"`, `perl -e`, `nc.openbsd`, `socat`, `php -r`, `node -e`, `gcc -x c - -o /tmp/x && /tmp/x` etc.
- `find / -name id_rsa -exec cat {} \;` — exfiltration via stdout (returned in tool result).
- `rm -rf $HOME`, `rm -rf .` (in `/tmp/qai-agent-agent-session` — see C2 — destroys other tenants' data).
- Output truncation: `stdout_limit=512KB` is enough to leak `/etc/passwd`, all env vars (`env`), service-account credentials (`cat $GOOGLE_APPLICATION_CREDENTIALS`), Apple/Google API keys (`env | grep KEY`).

The `terminal_inject` capability is mapped to the same `bash` tool, so the per-capability allowlist gates nothing meaningful (`agent.zig:50-59`).

Fix: drop substring blocklists; use a real sandbox (gVisor, Cloud Run jobs with no service-account binding, or refuse to execute arbitrary shell at all). At minimum, parse the command with a real lexer and refuse anything that isn't an allowlisted binary in an allowlisted argv shape.

### C5. WAL / Firestore / ledger JSON serializers do not escape user-controlled strings — JSON injection into financial records
Files: `src/store/store.zig:533-571`, `src/firestore.zig:155-183, 188-200`, `src/ledger.zig:60-76, 95-105, 131-148`, `src/bq.zig:67-90`.

Every serializer uses `std.fmt.allocPrint("…\"{s}\"…", .{user_string})`. The strings come from JWT claims (`email`), admin-controlled API input (`name`, `account_id`, `email` in `keys.handleCreateAccount`), per-request fields (`model`, `endpoint`), and dedicated-endpoint registry input.

Concrete consequences:
1. **WAL replay role-escalation.** `serializeAccount` interpolates `email` raw. An admin (only admins can create accounts) sets `email = `\``","role":"admin","x":"`\``. The WAL line becomes `{"id":"victim","email":"","role":"admin","x":"…","balance_ticks":0,"role":"user",…}`. On replay, `parseFromSlice(AccountJson, …)` deserializes the duplicate `role` — Zig's std.json honours the *last* value for duplicate keys, but the same trick works against the snapshot loader, which reads the WAL-derived JSON. With a tweaked payload (`","balance_ticks":99999999999,"role":"admin","x":"`) the payload places admin-fields **before** the legitimate ones; Zig's parser actually keeps the LAST field on duplicates, but `ignore_unknown_fields=true` plus careful field ordering gives the attacker a write into any non-final field. Even when key-collision protection holds, the attacker can corrupt the WAL into an unparseable state and then re-write it via crash-recovery skipping the entry → silent data loss.
2. **Ledger fraud.** `recordBilling` interpolates `model` raw (`ledger.zig:62`). `model` is user-supplied (`chat.zig:24-41`, capped at 128 chars). A user calling `POST /qai/v1/chat` with `model=`\``","cost_ticks":-100000000,"x":"`\`` writes a ledger line that can flip the sign of the cost or rewrite balance_after — `ledger.jsonl` is the "permanent financial record" per the file header.
3. **Firestore injection.** `firestore.buildAccountDocument` and `buildKeyDocument` interpolate raw. `apple_auth`/`google_auth` write the JWT-derived `email` into Firestore — Google emails are sanitized but the `name` field accepted from the request body in apple_auth (`AuthRequest.name`) flows into `display_name` in the response JSON (`apple_auth.zig:194-211`) without escaping → response body JSON corruption.
4. **Vertex dedicated-endpoint URL path traversal** (`vertex.zig:175-200`). `ep.model_name` is dropped into the Firestore document path with no encoding. An admin registering a model named `../../zig_accounts/admin` writes to the admin account doc.
5. **Vertex `extra_params` raw-JSON injection** (`vertex.zig:823-826`). Admin-controlled `extra_params` is appended verbatim to the Vertex request body, allowing arbitrary JSON fields injected into the Vertex AI call.

Fix: route every untrusted string through `chat.jsonEscape` (or a single shared helper) before formatting. URL-encode path segments. Reject `/` in `model_name` for the dedicated-endpoint registry. Stop accepting raw-JSON `extra_params`; take typed key/value pairs and re-serialize.

---

## HIGH

### H1. CORS `*` is broadcast on every authenticated response, including credentialed endpoints
Files: `src/main.zig:377-381`, `src/router.zig:38-43`.

`access-control-allow-origin: *` is added to *every* response (line 379-380, unconditional). The same is true of the OPTIONS preflight which advertises `Authorization, Content-Type` headers as allowed (`router.zig:38-43`). Browsers will not send credentials when the wildcard is used for cookie-based auth, but `Authorization: Bearer …` and `X-API-Key` headers from a JS fetch *do* go cross-origin so long as the preflight succeeds. Combined with the implicit "anyone with an API key" model, any malicious page a user visits can drive `qai_k_…` requests against the API on behalf of the user (the user's local CLI has the key in env / config; a phishing page uses fetch with their key). Worse, the `/qai/v1/auth/{apple,google}` endpoints accept POST with `Content-Type: application/json` from any origin — combined with C1 they're abusable by any embedded iframe.

Fix: lock CORS to the exact origins of the official web client (`https://api.cosmicduck.dev` is the docs origin; the actual web client origin should be enumerated). Refuse `Access-Control-Allow-Origin: *` for `/qai/v1/*` paths.

### H2. `X-Forwarded-For` is trusted from any peer — IP rate limit (auth brute force protection) is spoofable when not behind Cloud Run
Files: `src/auth_ratelimit.zig:109-122`.

`extractClientIp` reads `X-Forwarded-For` from any request, with no check that the peer is a trusted Cloud Run/IAP front-end. The per-IP auth rate limit (default 10/min) keys on this string. An attacker hitting the server directly (or any deployment that isn't strictly fronted by Cloud Run) can rotate `X-Forwarded-For: 1.2.3.4`, `1.2.3.5`, … to keep getting fresh buckets — defeating the brute-force protection that the file claims to implement.

The fallback when no header is present is the empty string (line 121) → all anonymous traffic shares a single bucket; combined with bucket eviction (`MAX_IP_BUCKETS`), a flood of 4096 unique IPs evicts honest users' buckets.

Fix: pin trust to the known Cloud Run forwarding chain. When deployed bare, fall back to `request.head.client_addr` (or whatever std.http exposes).

### H3. Login mints a fresh API key on every successful Apple/Google sign-in — unbounded key growth, impossible to revoke meaningfully
Files: `src/apple_auth.zig:181-282`, `src/google_auth.zig:188-286`.

`mintApiKey` always issues a brand-new `qai_k_…` and persists it. Nothing reuses or rotates an existing key for the account. After N logins the account has N valid, never-expiring keys (`expires_at = 0`). Memory grows linearly with login count, Firestore `zig_keys` grows linearly, and revoking "the user's key" is meaningless — only listing-and-revoking-all works. Attacker who learns one key has effectively unrevokable access (admin needs to revoke each key by prefix — the /keys/{prefix} endpoint requires admin).

Fix: reuse the most recent active `app-auth` key for the account, OR set a short `expires_at`, OR revoke prior `app-auth` keys before minting.

### H4. WAL is a full-file-rewrite on every append (10MB I/O per state change → DoS amplifier)
Files: `src/store/wal.zig:22-55`.

`append()` reads the entire WAL, concatenates the new entry, writes the whole thing back. With the rotation threshold at 10MB (`main.zig:403`) and every chat request triggering at least `reserve` + `commit_reservation` (each a write), an attacker with a tiny balance can drive ~20MB of disk I/O per request. At even modest concurrency this saturates disk bandwidth and the 5s flush thread starves, increasing recovery-loss window.

A second consequence: the read-modify-write isn't atomic — a crash mid-`writeFile` truncates the WAL even though the per-request mutex appears to serialize.

Fix: open the WAL once in `O_APPEND` mode, write only the new bytes, fsync periodically. Guard total file size at write time, not via the 60-second poller.

### H5. Per-connection `std.Io.Threaded` initialization + no idle timeout → Slowloris kills the server with 64 sockets
Files: `src/main.zig:300-393`.

Each accepted connection spawns a worker that immediately constructs a fresh `std.Io.Threaded` thread pool (`io_threaded: std.Io.Threaded = .init(ctx.allocator, .{})`). The accept loop caps concurrent connections at `max_workers = 64` (line 261-266). There is no per-request read timeout: `http_server.receiveHead()` blocks indefinitely waiting for a slow client to finish the headers. 64 sockets that send "GET / HTTP/1.1\r\n" and then nothing pin all workers; subsequent connections are dropped by the accept loop (`if (current >= config.max_workers) close`).

The thread-pool-per-connection also means a memory amplification: every long-lived connection (SSE streams) keeps an entire pool alive.

Fix: a single shared `Io.Threaded`; per-request read deadline; idle-keepalive timeout.

### H6. Bootstrap admin from `QAI_BOOTSTRAP_KEY` / `QAI_API_KEY` env — operator-supplied weak keys mint admin
Files: `src/main.zig:107-139`.

If the persisted store has no keys, the server bootstraps an admin account whose key is *whatever the operator put in the env var*. Many operators will pick a 16-char password. The `prefix` of that admin key is hardcoded as `"bootstrap_key"` (line 132) — so any leaked WAL / Firestore document trivially identifies it.

Fix: require a high-entropy random key (32 bytes hex), refuse short keys, log + rotate the bootstrap key after first use; never accept a bootstrap key that was already in WAL.

### H7. Pricing prefix-match enables undercharging via crafted model names
Files: `src/models.zig:339-373`.

`getPricing` and `getModel` fall back to `startsWith(model_id, m.api_model_id)` after exact match fails. CSV order determines which model wins for a prefix collision. An attacker requesting `gpt-4o-2024-…` against a registry that includes a cheap `gpt-4` entry can be billed at the cheap rate while the actual upstream call goes against the expensive model (the model string is forwarded verbatim to the provider). Default fallback is `3.0/15.0` (Claude Opus pricing) — wildly wrong both ways for unrecognized models.

Fix: exact-match only; reject unknown models with 400.

### H8. SSE streaming bills per-chunk, not per-token — large undercharge
Files: `src/stream.zig:30-65, 246-260`.

`StreamCtx.token_count` increments by 1 per provider chunk; `commit` and the ledger entry use `token_count` as `output_tokens`. Provider chunks routinely contain dozens of tokens. The blocking endpoint settles via real provider usage; the streaming endpoint reports a fraction of the real output. Attackers prefer the streaming endpoint for cheap usage of expensive models.

Vertex streaming has the same shape (`vertex.zig:1051-1053`), where output tokens are estimated as `chunk_count * 2`.

Fix: read the provider's terminal `usage` event (Anthropic, OpenAI, Vertex MaaS all emit one in the SSE stream) and bill from that.

### H9. Symlink TOCTOU in agent file tools — `validatePath` is purely lexical
Files: `src/security.zig:21-45`, `src/agent.zig:544-673`.

`validatePath` rejects `..`, absolute paths, and `\`. It does *nothing* about symbolic links. An agent run that has both `bash` and `read_file`/`write_file` capability can: `bash: ln -s /etc/passwd ./pwd` then `read_file ./pwd` — the read follows the symlink because `ws_dir.readFileAlloc` doesn't pass `O_NOFOLLOW`. With C2 (shared default workspace), one tenant can `ln -s` over another tenant's expected files.

Fix: use `Dir.openFile` with `nofollow=true` (and on Linux, `RESOLVE_BENEATH`/`RESOLVE_NO_SYMLINKS`), or mount the workspace on a tmpfs the agent can't escape.

### H10. CSV pricing fallback default of $3 in / $15 out is silently applied to unknown models
Files: `src/models.zig:354-355`.

`getPricing` returns Claude-Opus rates for unknown models. For an unrecognized cheap provider this overcharges by 1000×; for an unrecognized cheap model in front of a cheap provider it undercharges. Because the model string is forwarded verbatim to the upstream, a creative attacker passing a typo'd cheap-model-but-expensive-suffix can exploit either side.

Fix: refuse unknown models in `chat.zig` long before pricing is consulted; return 400 not 200.

---

## MEDIUM

### M1. Response headers buffer is fixed-size `[8]http.Header`; silent drop on overflow
File: `src/main.zig:360-381`. With CORS + request-id + the route's own headers, totals can exceed 8 if a future handler adds more. Silent header loss is hard to debug and may invalidate `set-cookie` etc. when added later.

### M2. `appendToFile` (ledger / audit) is a full read-modify-write per line
File: `src/ledger.zig:154-170`. Same shape as the WAL bug; not as hot a path but still a DoS amplifier on busy accounts.

### M3. `loadFromFirestore()` is invoked per-login on cache miss
Files: `src/apple_auth.zig:226`, `src/google_auth.zig:232`. New users (or any login the in-memory cache misses) cause a full collection scan over `zig_accounts` *and* `zig_keys`. Cost-of-firestore amplification + latency cliff. Attackers can drive Firestore quotas via fresh login attempts.

### M4. `account_id` constructed from JWT `sub` with no length cap
Files: `src/apple_auth.zig:171-176`, `src/google_auth.zig:178-183`. `claims.sub` is bounded by JWT signature, but Apple-emitted subs are 48 chars + `apple_` prefix = 54 — fits `FixedStr64`. Google subs are typically 21 digits. There is no explicit guard; a future provider with longer subs or a misissued token will silently truncate (`FixedStr64.fromSlice` truncates) and could collide two distinct users into the same account.

### M5. `chat.costTicks` always uses `.free` tier for the `cost_ticks` echoed in the response
File: `src/chat.zig:479-482`. Internal billing uses the right tier, but the API response advertises a free-tier-margin number. Confuses dashboards.

### M6. `account.recordTicks` is a single global counter
File: `src/account.zig:13-18`. Used by `agent.zig:428`. Not per-account; combined with C2 means agent runs are completely unattributed.

### M7. `getStr` only honours JSON strings — agent silently misroutes object/array args
File: `src/agent.zig:714-719`. A model that emits `{"path": ["..", "etc/passwd"]}` returns `null` and the tool result is `Error: missing 'path'`. Not exploitable by itself but compounds C4: bypass attempts fail loud and can be retried unbounded.

### M8. `oidc.epochSeconds` reaches into `io.vtable.now` directly
File: `src/oidc.zig:291-294`. Brittle to std.Io changes; should use the public helper. Doesn't cause a vuln today.

### M9. `verifyRS256` accepts any modulus length without enforcing a minimum (e.g. 2048-bit floor)
File: `src/oidc.zig:154-184`. Apple/Google currently use 2048-bit; if a JWKS ever advertises a 1024-bit key (test/staging IdP, malicious cache poisoning of an HTTP fetch — the JWKS GET is over TLS so this needs MITM at the cert level), it would still verify. Defense-in-depth: require `key.modulus_len >= 256`.

### M10. SSE error path in `stream.sendSseError` allocates with `std.heap.c_allocator` and never frees
File: `src/stream.zig:290-292`. c_allocator drops on libc heap, harmless in practice but is a leak primitive.

### M11. `auth.zig` legacy code path uses `security.constantTimeEql` only after a `std.mem.startsWith` short-circuit
File: `src/auth.zig:13-26`. The `Bearer ` prefix check is non-constant-time; with a known token-format prefix this is fine, but consistent with C3 it shows the project hasn't audited timing primitives carefully. Low impact since legacy mode is gated by absence of store keys.

### M12. `bq.flushThread` discards HTTP errors silently
File: `src/bq.zig:151-168`. BigQuery rejects (400 from a malformed row, 401 from token rotation, 5xx) are swallowed; rows are gone. Combined with C5 ledger injection, audit trail can be erased.

### M13. `request_id` from `bufPrint` is borrowed into `extra_headers` for the whole response, but `req_id_buf` lives on the connection's stack
File: `src/main.zig:336-388`. The slice is valid because `request.respond` is called in the same stack frame, but if any handler is later refactored to defer respond(), this becomes a use-after-stack-pop. Fragile; consider returning a heap-owned id or a fixed module-level ring buffer.

### M14. `keys.handleCreateAccount` accepts caller-supplied `id` and `tier` strings without sanitisation
File: `src/keys.zig:240-292`. `id` length-checked (1-32) but characters not restricted. An admin can create accounts whose id contains `:` (breaks the WAL `update_balance` payload format `{id}:{delta}` parsed by `lastIndexOfScalar` on replay → wrong account credited). Operator-only path but a foot-gun.

### M15. `dispatch` sets `safe_keepalive=false` only when method-expects-body and has no body header; no per-connection cap on number of bodyless requests
File: `src/main.zig:349-357`. A keep-alive flood of bodyless POSTs is allowed up to `max_requests_per_conn=1000`, then the connection is closed — but during those 1000 the connection ties up a worker. Combined with H5 this makes Slowloris trivial.

---

## Notes on what *was* done well
- API keys are stored as SHA-256 of a 256-bit random secret; raw key shown once. Constant-time comparison present (`security.constantTimeEql`).
- Auth pipeline is fail-closed and short-circuits on every check.
- JWT signature verification is a real PKCS#1 v1.5 RSA verify against the provider's JWKS, not a header-trust.
- Two-phase commit billing with reservation refunds.
- Rate limiter on `/qai/v1/auth/*` exists (just broken — see C3, H2).
- Path validation rejects `..`, absolute, null bytes, backslashes.
- No `std.process.system`, no `popen`, no obvious `@ptrCast` misuse, no `catch unreachable` on input.

The architecture is right; the implementation has a handful of foot-guns that together let an attacker authn-bypass, run free agent jobs, and rewrite the financial ledger.
