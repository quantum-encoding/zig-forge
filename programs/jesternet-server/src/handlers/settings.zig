// Layer C repo settings handler — PATCH /api/repos/{owner}/{name}/settings.
//
// Auth model: **session-cookie-only**, owner-only. Per CONTRACT §6.7
// and the TS reference's settings.ts:75-82 — "tokens don't carry
// settings scope on a single-tenant host." PAT callers MUST receive
// 401, not 403, because the token model has no settings scope at all
// (vs scope_missing which implies a scope that exists but the token
// lacks).
//
// Jesternet-server's auth pipeline currently only handles PAT. Once
// session-cookie auth lands, this handler will:
//   1. Verify the session cookie + same-origin check
//   2. Verify session.userHandle == owner (V1 owner-only gate)
//   3. Parse PATCH body, validate fields (description, topics,
//      default_branch, is_private, allow_force_push)
//   4. Validate default_branch references an existing ref
//   5. Apply via store.updateRepoSettings — durable WAL'd via
//      .repo_settings_update
//   6. Invalidate ref-resolver cache when default branch moves
//   7. Return 200 with the updated RepoRow
//
// Until then this handler returns 401 with the contract's body shape
// for PAT callers. The conformance suite's §6.7 case asserts this
// exact behavior — PAT → 401 — so the handler passes today.

const std = @import("std");
const http = std.http;

const router = @import("../router.zig");

const body_session_required =
    \\{"error":"unauthorized","message":"Repo settings require a session cookie; PATs cannot modify repo config"}
;

pub fn handlePatch(_: *http.Server.Request, _: router.HandlerCtx) router.Response {
    return .{
        .status = .unauthorized,
        .body = body_session_required,
        .headers = &router.headers_json_cors,
    };
}
