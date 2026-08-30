# Fixes Log — zigix_tsdb

## Wave 1 — 2026-04-27 — CRIT only

| ID | Status | Commit | Files | Description |
| — | NO_CRITS | — | — | No CRIT findings in audit; HIGH-tier (stored XSS in dashboard, slow-read DoS, ring-buffer freeze) deferred to Wave 2 |

## Wave 2 — 2026-08-30 — HIGH tier + the reachability preconditions

Verified against a running `zig-out/bin/zigix-tsdb` on 127.0.0.1:8081, not only by
inspection. `zig build test` → 6/6.

| ID | Status | Files | Description |
| H-3 | FIXED | src/main.zig | Ring buffer indexed by a new `write_idx` cursor instead of the capped `entry_count`, and `/api/recent` windowed off it via `recentWindow()`. Live: 10 100 ingests, the window returns m10050..m10099 — the old build froze on entries 9950..9999 with every later write landing in slot 0. |
| H-2 | FIXED | src/main.zig | `SO_RCVTIMEO` + `SO_SNDTIMEO` (5 s) on every accepted socket. Live: a connection that sends nothing now stalls the sequential accept loop for 5 s instead of until the kernel gives up on the socket. |
| H-1 | FIXED | src/main.zig | Dashboard rows built with `createElement` + `textContent` and `replaceChildren` instead of interpolated into `innerHTML`. Live: `<img src=x onerror=alert(1)>` ingested as a model name is carried as data. Pairs with the Wave-1 `std.json.Stringify` emit (server side). |
| M-2 | FIXED | src/main.zig | Binds `127.0.0.1` rather than `INADDR_ANY`. Live: `lsof` shows `127.0.0.1:8081`, and the LAN address refuses. Removes the precondition that made H-1/H-3 remotely reachable. Networked ingest needs a credential first, not a wider bind. |
| M-3 | FIXED | src/main.zig | `readHeaders` + `readBody` loop until the CRLFCRLF and the whole declared `Content-Length` are in hand; a request with no parseable Content-Length is refused rather than guessed at. Live: a body deliberately split across TCP segments records latency 4321 — the single-read path recorded 0 and still acked. |
| M-4 | FIXED | src/main.zig | `Access-Control-Allow-Origin: *` dropped from every response. The dashboard is same-origin off this listener. |
| — | FIXED | src/main.zig | Non-UTF-8 `model` bytes rejected at ingest (`ERR invalid model encoding`, nothing stored). Validated BEFORE the 64-byte truncation, and the truncation itself now cuts on a codepoint boundary (`utf8TruncLen`). |

Still open from findings.md: M-1 (closed in Wave 1 by Stringify), M-5 (hand-rolled
parser → `std.json.parseFromSlice`), M-6 (silent i64→u32 truncation), L-1..L-4.
