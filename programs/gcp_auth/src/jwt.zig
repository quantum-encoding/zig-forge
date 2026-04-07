// JWT creation with RS256 signing for Google OAuth2 service account flow.
// Produces a signed JWT assertion for token exchange with Google's token endpoint.

const std = @import("std");
const rsa = @import("rsa.zig");

const base64url = std.base64.url_safe_no_pad;

// Pre-encoded JWT header for RS256: {"alg":"RS256","typ":"JWT"}
const header_b64 = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9";

pub const Claims = struct {
    /// Service account email (iss and sub)
    issuer: []const u8,
    /// Space-delimited OAuth2 scopes
    scope: []const u8,
    /// Token endpoint (aud), typically "https://oauth2.googleapis.com/token"
    audience: []const u8,
    /// Token lifetime in seconds (max 3600 for Google)
    lifetime_secs: i64 = 3600,
};

/// Create a signed JWT assertion string. Caller owns the returned memory.
/// `now_epoch_secs` is the current unix timestamp in seconds.
pub fn createSignedJwt(
    allocator: std.mem.Allocator,
    key: *const rsa.RsaPrivateKey,
    claims: Claims,
    now_epoch_secs: i64,
) ![]u8 {
    const now = now_epoch_secs;

    // Build claims JSON
    const claims_json = try std.fmt.allocPrint(allocator,
        \\{{"iss":"{s}","scope":"{s}","aud":"{s}","iat":{d},"exp":{d}}}
    , .{
        claims.issuer,
        claims.scope,
        claims.audience,
        now,
        now + claims.lifetime_secs,
    });
    defer allocator.free(claims_json);

    // Base64url encode the claims
    const claims_b64_len = base64url.Encoder.calcSize(claims_json.len);
    const claims_b64 = try allocator.alloc(u8, claims_b64_len);
    defer allocator.free(claims_b64);
    _ = base64url.Encoder.encode(claims_b64, claims_json);

    // Build signing input: header.claims
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, claims_b64 });
    defer allocator.free(signing_input);

    // RS256 sign
    const signature = try key.sign(signing_input);
    defer allocator.free(signature);

    // Base64url encode the signature
    const sig_b64_len = base64url.Encoder.calcSize(signature.len);
    const sig_b64 = try allocator.alloc(u8, sig_b64_len);
    defer allocator.free(sig_b64);
    _ = base64url.Encoder.encode(sig_b64, signature);

    // Final JWT: header.claims.signature
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, claims_b64, sig_b64 });
}

/// URL-encode a string for use in application/x-www-form-urlencoded bodies.
/// Only encodes characters that need escaping in form data.
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try list.append(allocator, c);
        } else {
            // %XX hex encoding
            const hex = "0123456789ABCDEF";
            try list.append(allocator, '%');
            try list.append(allocator, hex[c >> 4]);
            try list.append(allocator, hex[c & 0x0f]);
        }
    }

    return list.toOwnedSlice(allocator);
}
