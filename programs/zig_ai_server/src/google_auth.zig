// Google Sign In — POST /qai/v1/auth/google
// Full RS256 signature verification against Google's JWKS.
//
// Flow:
//   1. Client sends { "id_token": "<google_jwt>", "client_id": "<optional>" }
//   2. Fetch Google's JWKS from https://www.googleapis.com/oauth2/v3/certs (cached 24h)
//   3. Verify RS256 signature using Google's RSA public key
//   4. Validate claims: issuer, audience, expiration
//   5. Find or create account in Firestore (by google_sub)
//   6. Mint a qai_k_ API key for the account
//   7. Return { "api_key": "...", "session_token": "...", "email": "...", ... }

const std = @import("std");
const http = std.http;
const oidc = @import("oidc.zig");
const json_util = @import("json.zig");
const router = @import("router.zig");
const store_mod = @import("store/store.zig");
const types = @import("store/types.zig");
const firestore = @import("firestore.zig");
const gcp = @import("gcp.zig");
const Response = router.Response;

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const WELCOME_BONUS: i64 = 10_000_000_000; // $1 welcome credit

/// Valid Google token issuers
const GOOGLE_ISSUERS = [_][]const u8{
    "accounts.google.com",
    "https://accounts.google.com",
};

/// Allowed Google OAuth client IDs (web + iOS + Android)
const ALLOWED_CLIENT_IDS = [_][]const u8{
    "967904281608-e0u8a4odho83k8ctgs6ju98tcg5p6h30.apps.googleusercontent.com", // VWG web
};

/// JWKS cache — refreshed every 24h or on kid miss
var google_cache: ?oidc.JwksCache = null;

// ── Request ────────────────────────────────────────────────────

const AuthRequest = struct {
    id_token: []const u8,
    client_id: ?[]const u8 = null,
};

// ── Handler ────────────────────────────────────────────────────

pub fn handle(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*store_mod.Store,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    const s = store orelse return .{ .status = .internal_server_error, .body =
        \\{"error":"internal","message":"Store not available"}
    };
    const ctx = gcp_ctx orelse return .{ .status = .service_unavailable, .body =
        \\{"error":"service_unavailable","message":"Auth service not ready"}
    };

    // Parse request
    const body = json_util.readBody(request, allocator, 16 * 1024) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_request","message":"Failed to read request body"}
        };
    };
    defer allocator.free(body);

    if (body.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_request","message":"id_token is required"}
    };

    const parsed = std.json.parseFromSlice(AuthRequest, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_json","message":"Invalid JSON. Required: id_token"}
        };
    };
    defer parsed.deinit();

    if (parsed.value.id_token.len == 0) return .{ .status = .bad_request, .body =
        \\{"error":"invalid_request","message":"id_token is required"}
    };

    // Verify client_id is in our allow list (if provided)
    if (parsed.value.client_id) |cid| {
        if (cid.len > 0) {
            var allowed = false;
            for (ALLOWED_CLIENT_IDS) |id| {
                if (std.mem.eql(u8, cid, id)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) return .{ .status = .bad_request, .body =
                \\{"error":"invalid_request","message":"Unrecognized client_id"}
            };
        }
    }

    const now = oidc.epochSeconds(io);

    // Ensure JWKS cache is fresh
    if (google_cache == null or google_cache.?.isStale(now)) {
        google_cache = oidc.fetchJwks(allocator, &ctx.http_client, GOOGLE_JWKS_URL, now) catch {
            std.debug.print("  Google JWKS fetch failed\n", .{});
            return .{ .status = .service_unavailable, .body =
                \\{"error":"service_unavailable","message":"Failed to fetch Google signing keys"}
            };
        };
        std.debug.print("  Google JWKS: cached {d} keys\n", .{google_cache.?.count});
    }

    // Verify JWT signature + extract claims
    var claims = oidc.verifyJwt(allocator, parsed.value.id_token, &google_cache.?) catch |err| {
        // On KeyNotFound, try refreshing JWKS (key rotation)
        if (err == error.KeyNotFound) {
            google_cache = oidc.fetchJwks(allocator, &ctx.http_client, GOOGLE_JWKS_URL, now) catch {
                return .{ .status = .unauthorized, .body =
                    \\{"error":"authentication_error","message":"Failed to verify Google ID token (key refresh failed)"}
                };
            };
            var retry_claims = oidc.verifyJwt(allocator, parsed.value.id_token, &google_cache.?) catch {
                return .{ .status = .unauthorized, .body =
                    \\{"error":"authentication_error","message":"Invalid or expired Google ID token"}
                };
            };
            return processVerifiedClaims(allocator, io, s, &retry_claims, now);
        }
        std.debug.print("  Google JWT verify failed: {}\n", .{err});
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Invalid or expired Google ID token"}
        };
    };

    return processVerifiedClaims(allocator, io, s, &claims, now);
}

fn processVerifiedClaims(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    claims: *oidc.VerifiedClaims,
    now: i64,
) Response {
    defer claims.deinit(allocator);

    // Validate audience — must match one of our client IDs
    if (claims.aud) |aud| {
        var aud_ok = false;
        for (ALLOWED_CLIENT_IDS) |id| {
            if (std.mem.eql(u8, aud, id)) {
                aud_ok = true;
                break;
            }
        }
        if (!aud_ok) {
            std.debug.print("  Google auth: bad audience: {s}\n", .{aud});
            return .{ .status = .unauthorized, .body =
                \\{"error":"authentication_error","message":"Token audience not allowed"}
            };
        }
    }

    // Validate expiration
    if (claims.exp > 0 and now > claims.exp) {
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Google ID token has expired"}
        };
    }

    // Find or create account
    const account_id_str = std.fmt.allocPrint(allocator, "google_{s}", .{claims.sub}) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to generate account ID"}
        };
    };
    defer allocator.free(account_id_str);

    const is_new = findOrCreateAccount(io, store, account_id_str, claims);

    // Mint API key
    const raw_key = mintApiKey(allocator, io, store, account_id_str) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to create API key"}
        };
    };
    defer allocator.free(raw_key);

    // Get balance
    const balance = if (store.getAccountLocked(account_id_str)) |acct| acct.balance_ticks else WELCOME_BONUS;
    const credit_usd = @as(f64, @floatFromInt(balance)) / 10_000_000_000.0;

    // Build response (matches Go backend format)
    const email = claims.email orelse "";
    const display_name = if (claims.email) |e| blk: {
        if (std.mem.indexOfScalar(u8, e, '@')) |at| break :blk e[0..at];
        break :blk e;
    } else "";

    const resp = std.fmt.allocPrint(allocator,
        \\{{"token":"{s}","session_token":"{s}","api_key":"{s}","email":"{s}","credit_usd":{d:.4},"is_new":{s},"user":{{"id":"{s}","email":"{s}","display_name":"{s}","photo_url":"","credit_ticks":{d},"role":"user"}}}}
    , .{
        raw_key, raw_key, raw_key, email, credit_usd,
        if (is_new) "true" else "false",
        account_id_str, email, display_name, balance,
    }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build response"}
        };
    };

    return .{ .body = resp };
}

// ── Account Management ─────────────────────────────────────────

fn findOrCreateAccount(
    io: std.Io,
    store: *store_mod.Store,
    account_id: []const u8,
    claims: *oidc.VerifiedClaims,
) bool {
    if (store.getAccountLocked(account_id) != null) return false;

    // Try loading from Firestore (might exist from a previous container)
    store.loadFromFirestore();
    if (store.getAccountLocked(account_id) != null) return false;

    // Create new account
    const now_ms = types.nowMs();
    const email = claims.email orelse "";
    store.createAccount(io, .{
        .id = types.FixedStr32.fromSlice(account_id),
        .email = types.FixedStr256.fromSlice(email),
        .balance_ticks = WELCOME_BONUS,
        .role = .user,
        .tier = .free,
        .created_at = now_ms,
        .updated_at = now_ms,
    }) catch return false;

    std.debug.print("  New Google user: {s} ({s})\n", .{ account_id, email });
    return true;
}

fn mintApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    account_id: []const u8,
) ![]u8 {
    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);

    var hex_buf: [64]u8 = undefined;
    types.hexEncode(&random_bytes, &hex_buf);

    const raw_key = try std.fmt.allocPrint(allocator, "qai_k_{s}", .{&hex_buf});
    errdefer allocator.free(raw_key);

    var key_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_key, &key_hash, .{});

    var prefix_buf: [14]u8 = undefined;
    @memcpy(prefix_buf[0..6], "qai_k_");
    @memcpy(prefix_buf[6..14], hex_buf[0..8]);

    const now_ms = types.nowMs();

    store.createKey(io, .{
        .key_hash = key_hash,
        .account_id = types.FixedStr32.fromSlice(account_id),
        .name = types.FixedStr128.fromSlice("app-auth"),
        .prefix = types.FixedStr16.fromSlice(&prefix_buf),
        .scope = .{},
        .created_at = now_ms,
    }) catch return error.KeyCreationFailed;

    return raw_key;
}
