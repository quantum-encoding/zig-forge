// Auth middleware — Bearer token validation

const std = @import("std");
const http = std.http;

/// Validate the Authorization header against the server's API key.
/// Returns null if auth is valid, or an error response body if not.
pub fn validateRequest(request: *const http.Server.Request, api_key: []const u8) ?AuthError {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            const value = std.mem.trim(u8, header.value, " ");
            if (std.mem.startsWith(u8, value, "Bearer ")) {
                const token = std.mem.trim(u8, value[7..], " ");
                if (token.len > 0 and std.mem.eql(u8, token, api_key)) {
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
