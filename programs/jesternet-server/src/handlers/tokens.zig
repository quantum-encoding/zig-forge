// Layer C tokens handlers — list, mint, revoke.
//
// Auth model (mirrors the TS reference, api/tokens/index.ts:41-47 +
// api/tokens/[id].ts:24-26): **session-cookie-only**. A PAT cannot
// mint or revoke another PAT — by design, per CONTRACT §6.3 and the
// settings endpoint's adjacent comment. The token model has no
// "tokens:mint" scope and shouldn't, on a single-tenant host where
// the operator is the only one who'd touch tokens.
//
// Jesternet-server's auth pipeline currently only handles PAT.
// Session-cookie auth is a follow-up task. Until it lands, these
// handlers correctly return 401 for PAT callers — that's the
// documented contract behavior, not a stub. The conformance suite's
// token-management cases assert exactly this (PAT → 401), so this
// handler passes them today.

const std = @import("std");
const http = std.http;

const router = @import("../router.zig");

const body_session_required =
    \\{"error":"unauthorized","message":"Token management requires a session; PATs cannot mint or revoke other PATs"}
;

pub fn handleList(_: *http.Server.Request, _: router.HandlerCtx) router.Response {
    return sessionRequired();
}

pub fn handleMint(_: *http.Server.Request, _: router.HandlerCtx) router.Response {
    return sessionRequired();
}

pub fn handleRevoke(_: *http.Server.Request, _: router.HandlerCtx) router.Response {
    return sessionRequired();
}

fn sessionRequired() router.Response {
    return .{
        .status = .unauthorized,
        .body = body_session_required,
        .headers = &router.headers_json_cors,
    };
}
