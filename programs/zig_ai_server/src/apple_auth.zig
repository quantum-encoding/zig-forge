// Apple Sign In — POST /qai/v1/auth/apple
// Full RS256 signature verification against Apple's JWKS.
//
// Flow:
//   1. Client sends { "id_token": "<apple_jwt>", "name": "...", "nonce": "..." }
//   2. Fetch Apple's JWKS from https://appleid.apple.com/auth/keys (cached 24h)
//   3. Verify RS256 signature using Apple's RSA public key
//   4. Validate claims: issuer, audience, expiration, nonce
//   5. Find or create account in Firestore (by apple_sub)
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
const security = @import("security.zig");
const Response = router.Response;

const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const APPLE_ISSUER = "https://appleid.apple.com";
const WELCOME_BONUS: i64 = 10_000_000_000; // $1 welcome credit

/// Allowed audiences — Apple app bundle IDs + Services IDs
const ALLOWED_AUDIENCES = [_][]const u8{
    "com.quantumencoding.cosmicduck",
    "com.quantumencoding.CosmicDuckOS",
    "com.quantumencoding.vibing-with-grok.web",
};

/// JWKS cache — refreshed every 24h or on kid miss
var apple_cache: ?oidc.JwksCache = null;

// ── Request ────────────────────────────────────────────────────

const AuthRequest = struct {
    id_token: []const u8,
    name: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
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

    const now = oidc.epochSeconds(io);

    // Ensure JWKS cache is fresh
    if (apple_cache == null or apple_cache.?.isStale(now)) {
        apple_cache = oidc.fetchJwks(allocator, &ctx.http_client, APPLE_JWKS_URL, now) catch {
            std.debug.print("  Apple JWKS fetch failed\n", .{});
            return .{ .status = .service_unavailable, .body =
                \\{"error":"service_unavailable","message":"Failed to fetch Apple signing keys"}
            };
        };
        std.debug.print("  Apple JWKS: cached {d} keys\n", .{apple_cache.?.count});
    }

    // Verify JWT signature + extract claims
    var claims = oidc.verifyJwt(allocator, parsed.value.id_token, &apple_cache.?) catch |err| {
        // On KeyNotFound, try refreshing JWKS (key rotation)
        if (err == error.KeyNotFound) {
            apple_cache = oidc.fetchJwks(allocator, &ctx.http_client, APPLE_JWKS_URL, now) catch {
                return .{ .status = .unauthorized, .body =
                    \\{"error":"authentication_error","message":"Failed to verify Apple ID token (key refresh failed)"}
                };
            };
            // Retry with refreshed cache
            var retry_claims = oidc.verifyJwt(allocator, parsed.value.id_token, &apple_cache.?) catch {
                return .{ .status = .unauthorized, .body =
                    \\{"error":"authentication_error","message":"Invalid or expired Apple ID token"}
                };
            };
            return handleVerifiedClaims(allocator, io, s, ctx, &retry_claims, parsed.value.nonce, parsed.value.name, now);
        }
        std.debug.print("  Apple JWT verify failed: {}\n", .{err});
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Invalid or expired Apple ID token"}
        };
    };

    return handleVerifiedClaims(allocator, io, s, ctx, &claims, parsed.value.nonce, parsed.value.name, now);
}

fn handleVerifiedClaims(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    _: *gcp.GcpContext,
    claims: *oidc.VerifiedClaims,
    raw_nonce: ?[]const u8,
    name: ?[]const u8,
    now: i64,
) Response {
    defer claims.deinit(allocator);

    // Validate issuer (C1). VerifiedClaims.iss is now mandatory at
    // parse time, so this is a value check, not a presence check.
    // Apple-signed tokens always carry "https://appleid.apple.com".
    // zig-lens-ignore: EQL-FOR-SECRETS JWT issuer is a published public URL ("https://appleid.apple.com"), not secret material
    if (!std.mem.eql(u8, claims.iss, APPLE_ISSUER)) {
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Token issuer is not Apple"}
        };
    }

    // Validate audience (C1). aud is now also mandatory at parse time;
    // the bypass-by-omission ("if (claims.aud) |aud| { ... }") no
    // longer exists — a missing aud is rejected upstream in verifyJwt.
    var aud_ok = false;
    for (ALLOWED_AUDIENCES) |allowed| {
        // zig-lens-ignore: EQL-FOR-SECRETS JWT audience is a public app bundle ID checked against an allowlist; both sides are public identifiers, not secrets
        if (std.mem.eql(u8, claims.aud, allowed)) {
            aud_ok = true;
            break;
        }
    }
    if (!aud_ok) {
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Token audience not allowed"}
        };
    }

    // Validate expiration
    if (claims.exp > 0 and now > claims.exp) {
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Apple ID token has expired"}
        };
    }

    // Validate nonce (replay protection)
    if (!oidc.verifyNonce(raw_nonce, claims.nonce)) {
        return .{ .status = .unauthorized, .body =
            \\{"error":"authentication_error","message":"Nonce mismatch: possible token replay"}
        };
    }

    // Find or create account. Audit M14: validate the *full*
    // account_id (prefix + sub) so a hostile or malformed `sub` claim
    // cannot inject `:` or any other delimiter into WAL payloads or
    // Firestore doc paths. Apple's `sub` is supposed to be a stable
    // numeric user identifier; if a token reaches us with a sub
    // containing odd characters we fail the request rather than
    // serialize it.
    const account_id_str = std.fmt.allocPrint(allocator, "apple_{s}", .{claims.sub}) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to generate account ID"}
        };
    };
    defer allocator.free(account_id_str);

    if (security.validateAccountId(account_id_str) == null) {
        return .{ .status = .bad_request, .body =
            \\{"error":"invalid_token","message":"Apple sub claim contains characters not allowed in an account ID"}
        };
    }

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

    // Build response (matches Go backend format)
    const email = claims.email orelse "";
    const display_name = name orelse if (claims.email) |e| blk: {
        if (std.mem.indexOfScalar(u8, e, '@')) |at| break :blk e[0..at];
        break :blk e;
    } else "";

    // JSON-IN-FMT fix: the client-supplied `name` (→ display_name) and `email`
    // are now escaped by std.json.Stringify instead of raw `{s}` interpolation.
    const resp = json_util.writeSignInResponse(allocator, .{
        .raw_key = raw_key,
        .email = email,
        .is_new = is_new,
        .account_id = account_id_str,
        .display_name = display_name,
        .balance_ticks = balance,
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
    // Check if account exists in memory
    if (store.getAccountLocked(account_id) != null) return false;

    // Audit M3: single-doc fetch instead of a full collection scan.
    // The previous call here was store.loadFromFirestore() which
    // re-listed every `zig_accounts` and `zig_keys` row on every
    // cache miss — an O(N) Firestore amplifier triggerable by any
    // new Apple JWT subject.
    if (store.loadSingleAccountFromFirestore(account_id)) {
        if (store.getAccountLocked(account_id) != null) return false;
    }

    // Create new account
    const now_ms = types.nowMs(io);
    const email = claims.email orelse "";
    store.createAccount(io, .{
        .id = types.FixedStr64.fromSlice(account_id),
        .email = types.FixedStr256.fromSlice(email),
        .balance_ticks = WELCOME_BONUS,
        .role = .user,
        .tier = .free,
        .created_at = now_ms,
        .updated_at = now_ms,
    }) catch return false;

    std.debug.print("  New Apple user: {s} ({s})\n", .{ account_id, email });
    return true;
}

fn mintApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    account_id: []const u8,
) ![]u8 {
    // Audit H3: revoke any prior `app-auth` key for this account
    // before minting a new one. Logging in invalidates the previous
    // session's key — the standard "logged in elsewhere, this device
    // is signed out" semantics — and bounds key growth at one
    // active app-auth key per account, instead of one per login.
    store.revokeKeysByAccountAndName(io, account_id, "app-auth");

    // Generate raw key
    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);

    var hex_buf: [64]u8 = undefined;
    types.hexEncode(&random_bytes, &hex_buf);

    const raw_key = try std.fmt.allocPrint(allocator, "qai_k_{s}", .{&hex_buf});
    errdefer allocator.free(raw_key);

    // Hash for storage
    var key_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_key, &key_hash, .{});

    // Prefix for display
    var prefix_buf: [14]u8 = undefined;
    @memcpy(prefix_buf[0..6], "qai_k_");
    @memcpy(prefix_buf[6..14], hex_buf[0..8]);

    const now_ms = types.nowMs(io);

    store.createKey(io, .{
        .key_hash = key_hash,
        .account_id = types.FixedStr64.fromSlice(account_id),
        .name = types.FixedStr128.fromSlice("app-auth"),
        .prefix = types.FixedStr16.fromSlice(&prefix_buf),
        .scope = .{},
        .created_at = now_ms,
    }) catch return error.KeyCreationFailed;

    return raw_key;
}
