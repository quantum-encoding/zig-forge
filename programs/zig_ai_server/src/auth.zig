// Auth middleware — Bearer token validation (legacy single-key mode).
//
// Timing notes (audit M11):
//   - The "Bearer " scheme tag is a *public* literal. Comparing it
//     with std.mem.startsWith leaks nothing — both operands are
//     attacker-visible, and the early exit on mismatch only reveals
//     that the request was not a Bearer-shaped auth header.
//   - Header-name matching uses std.ascii.eqlIgnoreCase, which short-
//     circuits on length. Header names are public.
//   - The *secret comparison* (token vs. api_key) is the only part
//     that operates on attacker-controlled-vs-secret input, and that
//     path MUST stay constant-time. We enforce it with
//     security.constantTimeEql; the `token.len > 0` guard above the
//     compare is fine because the empty-string case has no secret
//     information to leak.
//
// This file is the bootstrap / legacy path used only when the keyed
// store is empty (see main.zig). The store-backed pipeline in
// auth_pipeline.zig is the production path.

const std = @import("std");
const http = std.http;
const security = @import("security.zig");

/// Validate the Authorization header against the server's API key.
/// Returns null if auth is valid, or an error type if not.
pub fn validateRequest(request: *const http.Server.Request, api_key: []const u8) ?AuthError {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            const value = std.mem.trim(u8, header.value, " ");
            // Public scheme tag — see file header for the timing rationale.
            if (std.mem.startsWith(u8, value, "Bearer ")) {
                const token = std.mem.trim(u8, value[7..], " ");
                // Secret comparison — constant time, mandatory.
                if (token.len > 0 and security.constantTimeEql(token, api_key)) {
                    return null; // Auth OK
                }
                return .invalid_token;
            }
            return .malformed_header;
        }
    }
    return .missing_header;
}

pub const AuthError = enum {
    missing_header,
    malformed_header,
    invalid_token,

    pub fn statusCode(self: AuthError) http.Status {
        return switch (self) {
            .missing_header => .unauthorized,
            .malformed_header => .unauthorized,
            .invalid_token => .forbidden,
        };
    }

    pub fn body(self: AuthError) []const u8 {
        return switch (self) {
            .missing_header =>
            \\{"error":"unauthorized","message":"Missing Authorization header. Use: Authorization: Bearer <api_key>"}
            ,
            .malformed_header =>
            \\{"error":"unauthorized","message":"Malformed Authorization header. Expected: Bearer <token>"}
            ,
            .invalid_token =>
            \\{"error":"forbidden","message":"Invalid API key"}
            ,
        };
    }
};
