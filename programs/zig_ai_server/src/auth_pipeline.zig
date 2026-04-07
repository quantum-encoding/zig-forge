// Auth Pipeline — full multi-step authentication
// Token → SHA-256 hash → key lookup → account lookup → permission checks
// FAIL-CLOSED at every step. No cache needed (in-memory maps are the cache).

const std = @import("std");
const http = std.http;
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const security = @import("security.zig");
const ratelimit = @import("ratelimit.zig");

pub const AuthResult = union(enum) {
    ok: types.AuthContext,
    err: AuthError,
};

pub const AuthError = struct {
    status: http.Status,
    body: []const u8,
};

/// Authenticate a request against the store. Returns AuthContext or error response.
/// FAIL-CLOSED: every check that fails returns an error, never proceeds.
/// Rate limiter instance (set from main.zig)
var rate_limiter: ?*ratelimit.RateLimiter = null;

pub fn setRateLimiter(rl: *ratelimit.RateLimiter) void {
    rate_limiter = rl;
}

pub fn authenticate(
    request: *const http.Server.Request,
    store: *store_mod.Store,
) AuthResult {
    // Step 1: Extract Authorization header
    const raw_token = extractBearerToken(request) orelse {
        return .{ .err = .{
            .status = .unauthorized,
            .body =
            \\{"error":"unauthorized","message":"Missing or malformed Authorization header"}
            ,
        } };
    };

    // Step 2: Validate token format
    if (raw_token.len == 0 or raw_token.len > 256) {
        return .{ .err = .{
            .status = .unauthorized,
            .body =
            \\{"error":"unauthorized","message":"Invalid token format"}
            ,
        } };
    }

    // Step 3: SHA-256 hash the raw token
    var key_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_token, &key_hash, .{});

    // Steps 4-12: Lookup and validate (under spinlock)
    store.mutex.lock();
    defer store.mutex.unlock();

    // Step 4: Lookup key by hash
    const key = store.keys.getPtr(key_hash) orelse {
        return .{ .err = .{
            .status = .forbidden,
            .body =
            \\{"error":"forbidden","message":"Invalid API key"}
            ,
        } };
    };

    // Step 5: Check revoked
    if (key.revoked) {
        return .{ .err = .{
            .status = .forbidden,
            .body =
            \\{"error":"forbidden","message":"API key has been revoked"}
            ,
        } };
    }

    // Step 6: Check expiration
    if (key.expires_at > 0) {
        const now = @import("store/types.zig").nowMs();
        if (now > key.expires_at) {
            return .{ .err = .{
                .status = .forbidden,
                .body =
                \\{"error":"forbidden","message":"API key has expired"}
                ,
            } };
        }
    }

    // Step 7: Lookup account
    const account = store.accounts.getPtr(key.account_id.slice()) orelse {
        return .{ .err = .{
            .status = .internal_server_error,
            .body =
            \\{"error":"internal","message":"Account not found for key"}
            ,
        } };
    };

    // Step 8: Check balance (non-admin accounts must have positive balance)
    if (account.role != .admin and account.balance_ticks <= 0) {
        return .{ .err = .{
            .status = .payment_required,
            .body =
            \\{"error":"insufficient_balance","message":"Account balance is zero. Add credits to continue."}
            ,
        } };
    }

    // Step 9: Check spend cap
    if (key.scope.spend_cap_ticks > 0 and key.spent_ticks >= key.scope.spend_cap_ticks) {
        return .{ .err = .{
            .status = .too_many_requests,
            .body =
            \\{"error":"spend_cap_exceeded","message":"API key spend cap reached"}
            ,
        } };
    }

    // Step 10: Endpoint scope (bitmask check deferred to handler level)

    // Step 11: Per-key rate limiting
    if (key.scope.rate_limit_rpm > 0) {
        if (rate_limiter) |rl| {
            if (!rl.check(key_hash, key.scope.rate_limit_rpm)) {
                return .{ .err = .{
                    .status = .too_many_requests,
                    .body =
                    \\{"error":"rate_limited","message":"API key rate limit exceeded. Try again shortly."}
                    ,
                } };
            }
        }
    }

    // Step 12: Success
    return .{ .ok = .{
        .account = account,
        .key = key,
        .key_hash = key_hash,
    } };
}

/// Extract Bearer token from Authorization header.
/// Returns null if header is missing or malformed.
fn extractBearerToken(request: *const http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            const value = std.mem.trim(u8, header.value, " ");
            if (std.mem.startsWith(u8, value, "Bearer ")) {
                const token = std.mem.trim(u8, value[7..], " ");
                if (token.len > 0) return token;
            }
            return null;
        }
    }
    return null;
}
