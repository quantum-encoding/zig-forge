# stratum_engine_claude — Security Audit

**Scope:** Zig red-team review of `stratum_engine_claude` (Bitcoin stratum mining proxy + HFT exchange execution engine; the name "claude" refers to authorship, not Claude API integration).
**Authorization:** Owner-requested CTF-mode audit. Findings only; no patches applied.
**Date:** 2026-04-27.

Severity scale:
- **Critical** — exploitable now, real money / credentials at stake.
- **High** — exploitable with one extra step, or memory-safety with bounded blast radius.
- **Medium** — abuse, DoS, or info-leak under realistic conditions.
- **Low / Info** — hygiene, defensive depth.

---

## CRITICAL

### C1 — TLS certificate verification disabled on exchange & pool TLS
**Files:** `src/crypto/tls_mbedtls.zig:110`, `src/execution/exchange_client.zig:92`
**Description:** Both mbedTLS clients call `mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE)` and the comments at `tls_mbedtls.zig:48` justify it as an HFT latency optimisation. SNI is set, but no chain verification, no pinning, no hostname binding. The Coinbase-pinned BearSSL trust anchor in `src/crypto/tls.zig` is dead code — exchange traffic flows through `exchange_client.zig`'s own inline mbedTLS client which has VERIFY_NONE.
**Exploit sketch:** Any on-path attacker (rogue Wi-Fi, ARP-spoof on LAN, compromised upstream router, malicious DNS) presents a self-signed cert for `advanced-trade-ws.coinbase.com` / `stream.binance.com`. The handshake completes silently. The attacker now holds plaintext of every WebSocket frame, including the auth frame at `exchange_client.zig:557,570,582` which contains `apiKey` + HMAC signature + (Coinbase) `passphrase`. With the API key + a captured signature, the attacker can either (a) replay/forge order frames inside the same socket, or (b) reuse the credentials on the real exchange.
**Fix:** Use `MBEDTLS_SSL_VERIFY_REQUIRED`, load the system CA bundle (`mbedtls_x509_crt_parse_path` + `mbedtls_ssl_conf_ca_chain`) or the BearSSL-style pinned anchor that already exists. The "5-10 ms" claimed cost in the comment is a one-time handshake cost, not per-message.

### C2 — API key, secret-derived signature, and full order JSON written to stdout
**Files:** `src/execution/exchange_client.zig:517,526,653,682,558` (and the auth path at `:557,570,582`)
**Description:** `executeBuy`/`executeSell` print the full signed JSON payload via `std.debug.print("Payload: {s}\n", .{json})`. `connect()` prints both the WebSocket upgrade request and the raw response (`:517,526`). The `authenticate()` path constructs an auth payload that embeds `apiKey` (and Coinbase `passphrase`) and is fed directly into `sendWebSocketFrame` — but the surrounding hot-path also relies on `std.debug.print` for tracing. Combined with `tls.zig:362-384` which hex-dumps every decrypted byte received, any successful exchange session leaks credentials and order flow to anyone who can read stderr (systemd journal, container logs, log aggregator, captured terminal).
**Exploit sketch:** Operator runs `stratum-engine 2>engine.log`, ships logs to Loki/CloudWatch/Datadog. Anyone with log read access (helpdesk role, breached SaaS account, leaked S3 bucket) extracts `apiKey` and the HMAC of `"timestamp=…"`. For Binance / Bybit / Kraken the secret-keyed HMAC of a known message is cryptographically equivalent to having the secret for the next request — combined with the leaked apiKey, the attacker submits trades.
**Fix:** Drop credentials from log statements unconditionally. Gate hex dumps behind a build-time `-Dtrace_tls=true` flag, and even then redact bytes 0..N when content matches an `apiKey` prefix. Never log auth payloads.

### C3 — `signCoinbase()` writes attacker-controlled body into a fixed 512-byte stack buffer with no bounds check
**File:** `src/crypto/hmac.zig:141-156`
**Description:** Builds the message-to-sign as raw `@memcpy` calls into `var message_buf: [512]u8` for `timestamp + method + path + body`. There is no `if (timestamp.len + method.len + path.len + body.len > 512)` guard. `body` is the order JSON, which Coinbase customers extend with notes / client_order_id / metadata. The single caller from `exchange_client.zig:565` passes `""` today, but the function is `pub`, so any future caller (or a Zig 0.16 inliner that keeps the symbol exported) can trigger this.
**Exploit sketch:** Caller passes a `body` longer than `512 - len(other)`. `@memcpy(message_buf[pos..][0..body.len], body)` indexes past the array → in `ReleaseFast` builds, silent stack corruption past `message_buf` (return address, neighbouring locals, including `secret`/`output` pointers) → arbitrary write primitive in a function that handles HMAC keys.
**Fix:** Either compute the required length and `return error.MessageTooLong`, or use a heap allocation, or stream the four pieces directly through `Sha256.update` (avoiding the buffer entirely — same approach `HmacContext.sign` already uses).

### C4 — Use-after-free / use-after-stack-return on every io_uring send in the proxy
**Files:** `src/proxy/server.zig:599-603` (`sendToMiner`) and every caller (`:469,488,565,589,605-615,632-650`); `src/proxy/websocket.zig:573-608` (`sendWebSocketFrame`)
**Description:** `sendToMiner` only does `sqe.prep_send(miner.sockfd, msg, 0)` and returns. The send is processed asynchronously by the kernel later. Every caller in this file owns `msg` either via `try std.fmt.allocPrint(self.allocator, …)` followed by `defer self.allocator.free(response)`, or as the `merkle_str.items` slice of a stack-allocated ArrayList. By the time `io_uring_enter` actually copies bytes, the buffer has been freed (allocator) or the stack frame has unwound (websocket frame_buf). In `websocket.zig:579` the `frame_buf` is a 2058-byte stack array of the function — io_uring reads from popped stack memory.
**Exploit sketch:** A malicious miner connects, sends `mining.subscribe`. Server runs `handleSubscribe` → allocPrint → `sendToMiner` → `defer free(response)` runs at `:469`. Next allocation by any thread (very common in this io_uring loop — every share, every job, every ws event) reuses the same heap chunk. Kernel later DMA-copies the new contents into the miner's TCP stream → either garbage / leaked secrets from other miners, or, by spraying allocations, the attacker controls what the next ASIC sees as a stratum response (job spoofing, difficulty manipulation). On stack-buffer cases the same trick leaks process stack contents (return addresses → ASLR bypass; HMAC keys if hot path coincides).
**Fix:** Either (a) keep a per-connection in-flight send buffer that persists until the send CQE completes (use `user_data` to track and free on completion), or (b) call `submit_and_wait` in `sendToMiner` so the kernel copies before return, or (c) use `IORING_OP_SEND_ZC` with proper completion tracking (and only free the buffer after the second "more" CQE arrives), or (d) revert to blocking `posix.send` for these small synchronous writes.

### C5 — Send-completion `user_data = 0xFFFFFFFF` is dereferenced as a `*MinerConnection`
**Files:** `src/proxy/server.zig:347-356,602`
**Description:** `handleCompletion` checks `if (cqe.user_data == 0)` for accept; the `else` branch does `const miner: *MinerConnection = @ptrFromInt(cqe.user_data)` and calls `handleRecv(miner, …)`. `sendToMiner` sets `sqe.user_data = 0xFFFFFFFF`. Every successful send produces a completion that the loop interprets as a recv on the miner pointed at address `0x00000000FFFFFFFF` → out-of-bounds read of `cqe.res`, then `miner.recv_len += bytes_read` to wild memory, then `processMessages(miner)` parses arbitrary memory as JSON.
**Exploit sketch:** Triggered by every server-initiated send. With C4 above, the combined effect is corruption of the address-`0xFFFFFFFF` page (likely SIGSEGV today; on systems where that address is mapped — e.g. JIT regions, sandbox shims — silent heap corruption). Even in the benign case, the loop crashes on first miner subscribe.
**Fix:** Either add a sentinel branch for `0xFFFFFFFF`/`SEND_USER_DATA` in `handleCompletion` and skip, or encode the operation type in the high bits of `user_data` (e.g. bit 63 = recv vs send), or use `IOSQE_CQE_SKIP_SUCCESS` so successful sends don't produce CQEs at all.

### C6 — Pool credentials passed via `argv`, visible to every local user
**Files:** `src/main.zig:88-90,137-145`, `src/main_dashboard.zig:53,150-155`
**Description:** Worker `username` (often `wallet.workername` — a Bitcoin payout address) and `password` are positional CLI arguments. On Linux they are world-readable in `/proc/<pid>/cmdline` and in any `ps -ef` output. They also appear in the engine's startup banner at `main.zig:92-93`, which is logged to stdout.
**Exploit sketch:** Any unprivileged local user reads `/proc/<engine-pid>/cmdline` and obtains the payout wallet (which doubles as the auth identity for solo-mining pools like ckpool — letting them redirect future shares / inspect that miner's reward stream).
**Fix:** Read pool URL/username/password from environment variables, a 0600 config file, or stdin. Strip them from the banner. Optionally `prctl(PR_SET_DUMPABLE, 0)` to deny `/proc` access from other UIDs.

### C7 — Pool passwords stored in plaintext in SQLite
**Files:** `src/storage/sqlite.zig:194-203,399-425,438-449`, schema columns `pools.username`/`pools.password`
**Description:** `sentient_trader.db` (default path, in current working directory — `src/main_proxy.zig:14`) stores pool credentials as plaintext TEXT columns. The DB is opened with default permissions (umask). No file-level encryption. Backup processes / cron rsync / Docker volume snapshots will export the credentials.
**Exploit sketch:** Operator backs up `sentient_trader.db` to S3 nightly. Read access to that bucket = full take-over of every pool account.
**Fix:** Encrypt credential columns with a key derived from a passphrase (Argon2id → ChaCha20-Poly1305). At minimum, `chmod 0600` the DB on creation and document the file-system trust boundary.

### C8 — Integer overflow in mempool transaction parser → bounds-check bypass / OOB read
**Files:** `src/mempool/sniffer.zig:425-431,448-450,477-500`; the test driver at `src/test_mempool.zig:289` shares the same shape
**Description:** `readVarint` happily returns a `usize` derived from a 64-bit attacker-controlled field. The caller does:
```zig
const script_len = readVarint(payload, &offset) catch return;
offset += script_len;
if (offset > payload.len) return;
```
On a 64-bit host, `script_len` can be ≈2⁶⁴-1. `offset += script_len` wraps, leaving `offset` *less than* `payload.len`. The next iteration reads from `payload[offset..]` — out of bounds of the on-stack 4096-byte `buffer` from `bitcoin/mempool.zig:258`. `total_value += value` at `:443` is also a signed 64-bit accumulation of attacker-controlled `i64`s with no `+%` / saturation — overflow is undefined behaviour in `ReleaseFast`, and a single `INT64_MIN` output silently flips the running sum.
**Exploit sketch:** A malicious peer (the seed-node list at `bitcoin/mempool.zig:19-25` is hard-coded but the connect-by-IP path in `test_mempool.zig` is wide open, and any peer that the operator manually points at counts) sends a `tx` message whose first script-length varint is `0xff ff ff ff ff ff ff ff`. The bounds check is bypassed; subsequent `std.mem.readInt` calls dereference past the stack buffer → information disclosure (read process memory and report it to the peer through the whale-alert ANSI print) and DoS via SIGSEGV.
**Fix:** Use checked arithmetic: `const new_offset = std.math.add(usize, offset, script_len) catch return error.Overflow;` then bound-check; reject any `script_len > payload.len`; treat the eight-byte form of varint as `error.Oversized` for tx-script context.

---

## HIGH

### H1 — JSON-RPC parser panics on type confusion (DoS by any miner)
**Files:** `src/proxy/server.zig:440-441,480,525,536-538`
**Description:** Code uses `root.object.get("id").?.integer`, `params.array.items[0].string`, etc. without validating the union tag. `std.json.Value.integer` on a string-typed value triggers an unreachable / panic.
**Exploit sketch:** Any miner connects to port 3333 and sends `{"id":"x","method":"mining.subscribe","params":[]}`. Process aborts. Repeats trivially → permanent denial of service of the entire proxy fleet.
**Fix:** Guard each access: `const id = if (root.object.get("id")) |v| switch (v) { .integer => |i| i, else => 0 } else 0;`. Same pattern for every `.string`/`.array` access.

### H2 — WebSocket dashboard has no authentication, no CORS, no origin check, bound to `INADDR_ANY`
**Files:** `src/proxy/websocket.zig:266-280`, `src/proxy/server.zig:209-213`
**Description:** Both the stratum proxy (port 3333) and the dashboard WebSocket (port 9999) bind to `0.0.0.0` with no auth. Anyone on the network (or anyone the host is exposed to) can: (a) subscribe to the dashboard stream — leaks miner names, IPs, hashrates, earnings; (b) connect a fake ASIC to the stratum port and submit shares as any worker.
**Exploit sketch:** Two attacks. Reconnaissance: `wscat -c ws://victim:9999` and read fleet inventory. Reward theft: connect to port 3333, run `mining.authorize` with the victim's known payout wallet (often discoverable via on-chain analysis), the proxy forwards your shares as theirs — at solo-mining pools like ckpool, finding a block credits the stored wallet, not the submitter, so theft requires also controlling the upstream pool config; but at fee/PPS pools the attacker can divert hashrate accounting and degrade the operator's reputation/payout.
**Fix:** Bind to `127.0.0.1` by default; require a token (`Sec-WebSocket-Protocol`-style or query param compared with constant-time eq); for the stratum side, require a TLS-pinned certificate or shared-secret password matched against a per-worker policy.

### H3 — Dashboard JSON injection via attacker-controlled `worker_name`
**File:** `src/proxy/websocket.zig:512-523` (the `.share` payload format string)
**Description:** Miner-supplied `worker_name` from `mining.authorize` is interpolated as `"miner_name":"{s}"` without JSON escaping. Same for `job_id` (`s.job_id_len` bytes echoed raw) and the `alert.message` field at `:548-555`.
**Exploit sketch:** Miner authorizes with name `evil","status":"compromised","_pwn":"x` — broadcast frame becomes `… "miner_name":"evil","status":"compromised","_pwn":"x", …` which the dashboard parser accepts as a forged share with arbitrary fields. If the dashboard renders `miner_name` into HTML (highly likely, given the Svelte dashboard from CLAUDE.md), a `</script><script>…` payload is XSS.
**Fix:** Sanitise on ingress (reject names containing `"`/`\`/control bytes at `mining.authorize` time, `src/proxy/server.zig:480-482`), or properly JSON-encode on egress (`std.json.Stringify` rather than `bufPrint("{s}")`).

### H4 — Dashboard handshake never completes → events silently dropped, but the hot-path runs
**File:** `src/proxy/websocket.zig:459-466` (`handshake_complete = false` at init), `:490` gating
**Description:** `WsClient.handshake_complete` is initialised to `false` and never set to `true` anywhere — there is no recv handler that processes the WebSocket upgrade request. `broadcastEvent` therefore drops all events (`:490` guards on `client.handshake_complete`). Functionally the dashboard is broken; defensively this is a fail-closed safety net for H3 — if the bug is "fixed" without first fixing H3, the XSS becomes live.
**Fix:** Pair the H3 fix with the handshake completion. Document the dependency in the commit that addresses H3.

### H5 — Decrypted TLS traffic hex-dumped + ASCII-rendered to stdout on every recv
**File:** `src/crypto/tls.zig:362-384`
**Description:** The BearSSL `recvTimeout` path prints up to 128 bytes of every decrypted message in both hex and ASCII. Even though `tls.zig` is dead code (see C1), the function is `pub` and exported — the next refactor that wires the BearSSL path back in will start streaming decrypted exchange responses (account balances, order acknowledgements with API metadata) to logs.
**Fix:** Delete the dump or gate behind a compile-time flag. Mark the function `@internal` or remove `pub` so it can't be re-enabled silently.

### H6 — `getrandom()` syscall return value ignored — masking key may be uninitialised stack memory
**File:** `src/execution/websocket.zig:11-13`
**Description:** `_ = linux.getrandom(buf.ptr, buf.len, 0);` swallows the return code. On `EINTR` (signal during boot), `ENOSYS` (old kernel), or pool-exhaustion before-`urandom-warmup`, the function returns without writing. The "random" buffer is `var random_bytes: [16]u8 = undefined;` from the caller — uninitialised stack. This bytes is used as (a) the WebSocket masking key and (b) the `Sec-WebSocket-Key` echoed by the server.
**Exploit sketch:** A predictable mask key in the client→server direction lets a network observer recover the cleartext payload from a captured masked WebSocket frame even without breaking TLS (irrelevant if C1 is fixed, severe if C1 is also exploited — the attacker now has *plaintext* of the WSS-then-WS payload). Predictable `Sec-WebSocket-Key` doesn't break the handshake (it's a sanity echo, not crypto), but it weakens any defence-in-depth that assumed real entropy.
**Fix:** `if (linux.getrandom(buf.ptr, buf.len, 0) != buf.len) @panic("entropy");` or use `std.crypto.random.bytes(buf)`.

### H7 — Use-after-free in worker `pending_shares` references freed `job_id`
**Files:** `src/miner/worker.zig:291-301,315-323`
**Description:** `queueShare` stores `job.job_id` as a slice owned by `self.job`. On the next `updateJob`, `self.job = job` overwrites the reference without `deinit`'ing the old job's heap allocations. The dispatcher's eventual share submission reads `pending_shares.items[i].job_id`, which may now point at freed memory once the old `Job` is GC'd. Even without explicit free, the pool's `parseJobNotify` builds these slices via `allocator.dupe`, and `Job.deinit` will free them at process exit at minimum.
**Exploit sketch:** Pool sends rapid `mining.notify` frames (clean_jobs flag toggling). Worker queues shares against the old job_id. At submission time the slice points at stale data → corrupted `mining.submit` payload sent to the pool. Cumulative: attacker pool can grief the miner into submitting malformed shares, accruing rejected-share penalties, eventually banning the worker.
**Fix:** `dupe` the `job_id` into the `ShareSubmission` with the same allocator, free in `drainShares`. Also fix `worker.updateJob` to call `self.job.?.deinit()` on the prior value (or document explicit ownership transfer).

### H8 — Unverified Bitcoin P2P checksums in the mempool sniffer
**Files:** `src/mempool/sniffer.zig:315`, `src/test_mempool.zig:225`
**Description:** Both code paths read the 4-byte checksum field with `_ = std.mem.readInt(...); // checksum (unused)` and never compare it against `dsha256(payload)[0..4]`. The protocol-defined integrity check is skipped entirely.
**Exploit sketch:** A malicious peer crafts a malformed `tx` whose checksum doesn't match — the parser still feeds it into `processInv`/`handleTransaction`. Combined with C8, this is the realistic attack path: the attacker doesn't need to keep their malformed message valid, only to make it *parse far enough* to trigger the integer overflow.
**Fix:** Compute and verify the checksum before dispatching the message. Reject mismatches without further parsing.

---

## MEDIUM

### M1 — Sequential, predictable extranonce1 per miner
**File:** `src/proxy/server.zig:84-86` (`std.mem.writeInt(u64, &extranonce1, id, .little)`)
**Description:** `extranonce1` is the upstream miner ID, which starts at 1 and increments. Stratum extranonce1 is intended to be unpredictable per session.
**Impact:** Two miners on the same proxy can predict each other's nonce ranges. If a malicious miner connects and reads the dashboard, it can pre-compute and submit a competitor's expected shares as its own (limited utility because the proxy assigns extranonces, but matters for any future direct-pool path).
**Fix:** `std.crypto.random.bytes(&extranonce1)`.

### M2 — Stratum server `recv_buffer` shift on partial messages permits resource exhaustion
**File:** `src/proxy/server.zig:415-429`
**Description:** Per-miner `recv_buffer` is 8 KB. If a miner sends 8 KB without a newline, the next recv into `miner.recv_buffer[8192..]` is a zero-length slice → `cqe.res == 0` → treated as disconnect. So the attack is bounded to "miner gets disconnected", but combined with the lack of connection rate-limiting or per-IP cap (only a global `MAX_MINERS = 256`), an attacker exhausts the slot pool with rapid reconnects.
**Fix:** Add per-IP connection cap and a token-bucket on accept; or grow the buffer up to a hard ceiling and only disconnect on overflow rather than on first wraparound.

### M3 — `recv` in stratum client treats partial-line messages as protocol error after 8 KB
**File:** `src/stratum/client.zig:540-542`
**Description:** Same 8 KB single-line cap — a hostile pool sending a single huge `mining.notify` (legal under stratum: large coinbase + many merkle branches) crashes the engine with `ProtocolError`.
**Fix:** Either dynamically grow the buffer or assert against a documented protocol cap (16-32 KB is more typical for stratum implementations).

### M4 — `parseJobNotify` accepts hex of any length for prevhash, then fixed-decodes 32 bytes
**File:** `src/stratum/client.zig:425-427`
**Description:** Length check `if (prevhash_hex.len != 64) return null;` is fine, but other elements (coinb1, coinb2) are dup'd unbounded — a malicious pool sends a 100 MB coinbase and the proxy `allocator.dupe` allocates 100 MB.
**Fix:** Cap all element sizes (1 MB is generous for stratum).

### M5 — `submit_and_wait` errors continue silently in proxy event loop
**File:** `src/proxy/server.zig:268-273`
**Description:** `submit_and_wait` errors print and `continue`, no backoff. A persistent EBADF / ENOMEM spins the loop hot.
**Fix:** Exponential backoff on consecutive errors, fail-fast after N.

### M6 — Pool hostname trusted blindly to be IPv4-resolvable
**File:** `src/stratum/client.zig:117-156`
**Description:** Only AF_INET resolution; any pool with IPv6-only DNS yields `NoAddressFound`. Pool failover then can't recover. Not a security issue per se, but availability under adversarial DNS conditions (attacker poisons cache to A-only with a sinkhole address).
**Fix:** Try `AF_UNSPEC`; iterate the addrinfo list rather than taking the first result.

### M7 — `parseDifficulty` accepts only ASCII digits + dot, silently mis-parses scientific or signed notation
**File:** `src/stratum/protocol.zig:30-40`
**Description:** A pool sending `set_difficulty -1e10` causes the loop to terminate at the `-`, parse empty string → error. Today this just disables difficulty updates; a pool could deliberately keep the proxy at difficulty 1.0 to inflate accepted-share counts (relevant for FPPS payouts).
**Fix:** Use a real JSON value parser, accept the IEEE 754 surface area, validate sign and range.

### M8 — `parseDifficulty`/`extractMethod` are substring-based; arrays containing the literal `"params":[` in a string prefix mis-parse
**File:** `src/stratum/protocol.zig:32,80-92`
**Description:** Hand-rolled JSON. A pool that prefaces its real notification with a string like `{"id":1,"result":["params:[fake]"]}` confuses the parser. Mostly cosmetic given that the production path uses `std.json.parseFromSlice` in `proxy/server.zig` — but `client.zig` and `protocol.zig` use the brittle parser.
**Fix:** Replace ad-hoc JSON code with `std.json.parseFromSlice`. Single source of truth.

### M9 — Mempool ping nonce is a truncated timestamp, not random
**File:** `src/bitcoin/mempool.zig:112`
**Description:** `const nonce: u64 = @intCast(@as(u128, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF);` — predictable to anyone who knows the connect time within a millisecond. Bitcoin nodes use the version-message nonce to detect self-connections; predictable nonces let an attacker on the network block your connection by claiming "I'm you".
**Fix:** `std.crypto.random.int(u64)`.

### M10 — `compat.timestamp()` ignores `clock_gettime` return code
**File:** `src/utils/compat.zig:53-57`
**Description:** Discarded return; on syscall failure (signal, sandbox restriction) `ts` is uninitialised, returned as time. Many call sites compare against this for share latency, alert deduplication, session tracking. Misbehaviour, not exploit.
**Fix:** Return `error.ClockFailed` or fall back to `std.time.timestamp()`.

### M11 — `engine.run` 100 ms blocking sleep between pool poll iterations
**File:** `src/engine.zig:144-147`
**Description:** Stratum jobs arrive sub-second; this sleep adds up to 100 ms to job dispatch latency, eroding effective hashrate on jobs that change quickly (clean_jobs broadcasts during a stale window). Not a vulnerability, but degrades the system to attacker-favourable conditions on pool-induced churn.
**Fix:** Use `submit_and_wait(1)` with a real timeout via `IORING_OP_TIMEOUT`, not a sleep.

---

## LOW / INFO

### L1 — `catch unreachable` on `clock_gettime` in test driver
**File:** `src/mempool/sniffer.zig:21`
**Description:** `posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable` aborts the binary on failure. Only in the standalone sniffer demo, not production engine.

### L2 — Earnings UPSERT accumulates without bound
**File:** `src/storage/sqlite.zig:253-260`
**Description:** `btc_earned + excluded.btc_earned` grows monotonically. Combined with H2 (no auth on stratum port) an attacker spamming submits can balloon the row indefinitely.
**Fix:** Cap or rate-limit earnings recording.

### L3 — `mbedtls_ssl_set_hostname` called with `&hostname_z` — passes `*[N]u8` instead of `[*c]const u8`
**Files:** `src/crypto/tls_mbedtls.zig:121`, `src/execution/exchange_client.zig:99`
**Description:** Implicit Zig-to-C coercion produces a pointer to the array's first byte (functionally OK), but if `toPosixPath` ever changes layout it's a footgun. Use `hostname_z[0..].ptr`.

### L4 — `compat.recvSocket`/`sendSocket` lose errno
**File:** `src/utils/compat.zig:24-34`
**Description:** All errors collapse to a single `error.RecvFailed` / `SendFailed`. Diagnosing intermittent network issues in production becomes guesswork.

### L5 — Test-only credentials in source files
**Files:** `src/test_exchange_client.zig:22-23`, `src/test_execution_engine.zig:31-32`
**Description:** `"test_key"` / `"test_secret"`. Not real, but flagged for defence-in-depth — make sure no developer ever reuses these strings to test against a live exchange.

### L6 — `mbedtls_ssl_handshake` busy-loop without polling
**Files:** `src/crypto/tls_mbedtls.zig:141-149`, `src/execution/exchange_client.zig:113-119`
**Description:** Spins on `WANT_READ`/`WANT_WRITE` continuously. Today the underlying socket is blocking so it waits inside `mbedtls_net_recv` — fine. If anyone makes the socket non-blocking (the BearSSL client does), this turns into a CPU melt. Not exploitable; flagged so the risk isn't introduced later.

### L7 — `bindText` allocates+frees a copy for every SQLite bind
**File:** `src/storage/sqlite.zig:570-578`
**Description:** Could use `SQLITE_STATIC` with a Zig-side null-terminator. Performance, not security.

### L8 — Hard-coded Bitcoin seed-node IPs
**File:** `src/bitcoin/mempool.zig:19-25`, `src/test_mempool.zig:118-124`
**Description:** Stale IPs become unreachable; worse, if those IPs change ownership the engine connects to the new (potentially adversarial) operator on every restart. Combined with H8 + C8 this is the dependency chain to a remote OOB read.
**Fix:** Resolve via `seed.bitcoin.sipa.be` etc. at runtime through DNSSEC-validating resolvers.

### L9 — `WebSocketBroadcaster.serializeEvent` truncates to 2048 bytes silently
**File:** `src/proxy/websocket.zig:483-484`
**Description:** `bufPrint` returns `error.NoSpaceLeft` for oversized events; `broadcastEvent` `catch return`s without logging. Alerts with long messages are silently dropped.

### L10 — `extranonce1` exposed in `mining.subscribe` response is the same value used as the per-miner identity bitcast (`server.zig:461-466`)
**Description:** Triple-encoding of the same little-endian u64 means any logging of one component leaks the others.

---

## Quick wins (highest value-to-effort)
1. **C1**: change `MBEDTLS_SSL_VERIFY_NONE` → `REQUIRED` and load CAs (4 lines).
2. **C2 + H5**: delete or gate the `std.debug.print` of payloads/responses (5 sites).
3. **C5**: add `if (cqe.user_data == SEND_TAG) continue;` in `handleCompletion`.
4. **H1**: wrap each `std.json.Value` access in a tag-checked switch.
5. **C6**: read pool credentials from environment instead of `argv`.

These five fixes remove one MITM, one credential-leak, one DoS, one panic-on-input, and one local-info-disclosure — in well under a day of work.

## Scope notes
- Did not exercise the SIMD SHA-256 implementations (`crypto/sha256_avx*`); their correctness affects mining yield, not security boundaries.
- The `dispatcher.zig` and `metrics/stats.zig` modules were out of read scope for this pass — recommend a follow-up audit covering shared-state lifecycle between dispatcher, worker pool, and engine, particularly around H7's job-lifetime concern.
- Did not test `qai security .` (qai scanner) — manual review only.
