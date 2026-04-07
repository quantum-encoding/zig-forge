// GCP Auth — Pure Zig Google Cloud authentication library.
//
// Provides OAuth2 token acquisition for GCP services via multiple strategies:
//   - Service Account (JWT assertion with RS256 signing)
//   - Application Default Credentials (refresh token exchange)
//   - Metadata Server (GCE/Cloud Run instance identity)
//   - Static Token (testing / manual injection)
//
// Every Google Cloud API is just REST with `Authorization: Bearer {token}`.
// This library handles getting and refreshing that token.

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;

pub const rsa = @import("rsa.zig");
pub const jwt = @import("jwt.zig");

const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const METADATA_TOKEN_URL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
const METADATA_PROJECT_URL = "http://metadata.google.internal/computeMetadata/v1/project/project-id";

/// Allowed token endpoint host suffixes. Prevents SSRF via attacker-controlled
/// token_uri in service account JSON redirecting signed JWTs to arbitrary URLs.
const allowed_token_hosts = [_][]const u8{
    "://oauth2.googleapis.com/",
    "://accounts.google.com/",
};

/// Default scope covering most GCP services.
pub const SCOPE_CLOUD_PLATFORM = "https://www.googleapis.com/auth/cloud-platform";

/// Get current epoch seconds from an Io handle (real/wall-clock time).
pub fn epochSeconds(io: std.Io) i64 {
    const ts = io.vtable.now(io.userdata, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

pub const Token = struct {
    access_token: []u8,
    expires_at: i64, // epoch seconds
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Token) void {
        std.crypto.secureZero(u8, self.access_token);
        self.allocator.free(self.access_token);
    }

    pub fn isExpired(self: *const Token, now_epoch: i64) bool {
        // Refresh 60 seconds before actual expiry.
        // Use saturating subtraction to prevent underflow when expires_at is
        // near i64 min (which would wrap to a huge positive, making an expired
        // token appear valid).
        const threshold = @max(self.expires_at -| 60, std.math.minInt(i64));
        return now_epoch >= threshold;
    }
};

pub const TokenError = error{
    TokenExchangeFailed,
    MetadataUnavailable,
    InvalidTokenResponse,
    InvalidCredentials,
    NoCredentialsFound,
    HttpError,
    OutOfMemory,
};

/// A cached, auto-refreshing token source.
pub const TokenProvider = union(enum) {
    service_account: ServiceAccountProvider,
    adc: ADCProvider,
    metadata: MetadataProvider,
    static_token: StaticProvider,

    /// Get a valid access token, refreshing if expired.
    /// The returned token string is borrowed — valid until the next getToken() call or deinit().
    pub fn getToken(self: *TokenProvider, client: *HttpClient) ![]const u8 {
        const io = client.io();
        return switch (self.*) {
            .service_account => |*p| p.getToken(client, io),
            .adc => |*p| p.getToken(client, io),
            .metadata => |*p| p.getToken(client, io),
            .static_token => |*p| p.getToken(),
        };
    }

    /// Get the authorization header value ("Bearer {token}").
    /// Caller owns the returned string.
    pub fn getAuthHeader(self: *TokenProvider, allocator: std.mem.Allocator, client: *HttpClient) ![]u8 {
        const token = try self.getToken(client);
        return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    }

    pub fn deinit(self: *TokenProvider) void {
        switch (self.*) {
            .service_account => |*p| p.deinit(),
            .adc => |*p| p.deinit(),
            .metadata => |*p| p.deinit(),
            .static_token => {},
        }
    }
};

// ============================================================================
// Service Account Provider — JWT assertion flow
// ============================================================================

pub const ServiceAccountProvider = struct {
    allocator: std.mem.Allocator,
    client_email: []u8,
    private_key: rsa.RsaPrivateKey,
    token_uri: []u8,
    scope: []u8,
    cached_token: ?Token,

    pub fn fromJson(allocator: std.mem.Allocator, json_bytes: []const u8, scope: []const u8) !ServiceAccountProvider {
        const parsed = std.json.parseFromSlice(ServiceAccountJson, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidCredentials;
        defer parsed.deinit();

        const sa = parsed.value;

        const private_key = rsa.parsePrivateKeyPem(allocator, sa.private_key) catch return error.InvalidCredentials;
        errdefer {
            var pk = private_key;
            pk.deinit();
        }

        const client_email = try allocator.dupe(u8, sa.client_email);
        errdefer allocator.free(client_email);

        // Validate token_uri against allowlist to prevent SSRF.
        // An attacker-controlled SA JSON could redirect the signed JWT assertion
        // to an arbitrary URL, leaking credentials or hitting internal services.
        const raw_uri = sa.token_uri orelse TOKEN_ENDPOINT;
        if (!isAllowedTokenUri(raw_uri)) return error.InvalidCredentials;

        const token_uri = try allocator.dupe(u8, raw_uri);
        errdefer allocator.free(token_uri);

        const scope_owned = try allocator.dupe(u8, scope);

        return .{
            .allocator = allocator,
            .client_email = client_email,
            .private_key = private_key,
            .token_uri = token_uri,
            .scope = scope_owned,
            .cached_token = null,
        };
    }

    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8, scope: []const u8) !ServiceAccountProvider {
        // Pure Zig file read via std.Io.Dir (no std.fs, no libc)
        var io_threaded: std.Io.Threaded = .init(allocator, .{});
        const io = io_threaded.io();
        const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch
            return error.NoCredentialsFound;
        defer allocator.free(json_bytes);

        return fromJson(allocator, json_bytes, scope);
    }

    pub fn getToken(self: *ServiceAccountProvider, client: *HttpClient, io: std.Io) ![]const u8 {
        const now = epochSeconds(io);
        if (self.cached_token) |*t| {
            if (!t.isExpired(now)) return t.access_token;
            t.deinit();
            self.cached_token = null;
        }

        // Create JWT assertion
        const assertion = try jwt.createSignedJwt(self.allocator, &self.private_key, .{
            .issuer = self.client_email,
            .scope = self.scope,
            .audience = self.token_uri,
        }, now);
        defer self.allocator.free(assertion);

        // Build form body
        const body = try std.fmt.allocPrint(self.allocator,
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
            .{assertion},
        );
        defer self.allocator.free(body);

        // Exchange for access token
        self.cached_token = try exchangeToken(self.allocator, client, self.token_uri, body, now);
        return self.cached_token.?.access_token;
    }

    pub fn deinit(self: *ServiceAccountProvider) void {
        if (self.cached_token) |*t| t.deinit();
        self.private_key.deinit();
        self.allocator.free(self.client_email);
        self.allocator.free(self.token_uri);
        self.allocator.free(self.scope);
    }
};

const ServiceAccountJson = struct {
    client_email: []const u8,
    private_key: []const u8,
    token_uri: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
};

// ============================================================================
// ADC Provider — Application Default Credentials (refresh token)
// ============================================================================

pub const ADCProvider = struct {
    allocator: std.mem.Allocator,
    client_id: []u8,
    client_secret: []u8,
    refresh_token: []u8,
    cached_token: ?Token,

    /// Load ADC from the standard well-known location.
    /// Uses environ_map for HOME lookup (pure Zig, no std.process.getEnvVarOwned).
    pub fn init(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) !ADCProvider {
        const home = if (environ_map) |em| em.get("HOME") orelse return error.NoCredentialsFound else return error.NoCredentialsFound;

        const path = try std.fmt.allocPrint(allocator, "{s}/.config/gcloud/application_default_credentials.json", .{home});
        defer allocator.free(path);

        return initFromFile(allocator, path);
    }

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !ADCProvider {
        // Pure Zig file read via std.Io.Dir
        var io_threaded: std.Io.Threaded = .init(allocator, .{});
        const io = io_threaded.io();
        const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch
            return error.NoCredentialsFound;
        defer allocator.free(json_bytes);

        return initFromJson(allocator, json_bytes);
    }

    pub fn initFromJson(allocator: std.mem.Allocator, json_bytes: []const u8) !ADCProvider {
        const parsed = std.json.parseFromSlice(ADCJson, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidCredentials;
        defer parsed.deinit();

        const adc = parsed.value;

        return .{
            .allocator = allocator,
            .client_id = try allocator.dupe(u8, adc.client_id),
            .client_secret = try allocator.dupe(u8, adc.client_secret),
            .refresh_token = try allocator.dupe(u8, adc.refresh_token),
            .cached_token = null,
        };
    }

    pub fn getToken(self: *ADCProvider, client: *HttpClient, io: std.Io) ![]const u8 {
        const now = epochSeconds(io);
        if (self.cached_token) |*t| {
            if (!t.isExpired(now)) return t.access_token;
            t.deinit();
            self.cached_token = null;
        }

        const body = try std.fmt.allocPrint(self.allocator,
            "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
            .{ self.client_id, self.client_secret, self.refresh_token },
        );
        defer self.allocator.free(body);

        self.cached_token = try exchangeToken(self.allocator, client, TOKEN_ENDPOINT, body, now);
        return self.cached_token.?.access_token;
    }

    pub fn deinit(self: *ADCProvider) void {
        if (self.cached_token) |*t| t.deinit();
        self.allocator.free(self.client_id);
        // Zero secrets before freeing — prevents recovery from heap forensics
        std.crypto.secureZero(u8, self.client_secret);
        self.allocator.free(self.client_secret);
        std.crypto.secureZero(u8, self.refresh_token);
        self.allocator.free(self.refresh_token);
    }
};

const ADCJson = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
};

// ============================================================================
// Metadata Provider — GCE/Cloud Run metadata server
// ============================================================================

pub const MetadataProvider = struct {
    allocator: std.mem.Allocator,
    cached_token: ?Token,

    pub fn init(allocator: std.mem.Allocator) MetadataProvider {
        return .{
            .allocator = allocator,
            .cached_token = null,
        };
    }

    pub fn getToken(self: *MetadataProvider, client: *HttpClient, io: std.Io) ![]const u8 {
        const now = epochSeconds(io);
        if (self.cached_token) |*t| {
            if (!t.isExpired(now)) return t.access_token;
            t.deinit();
            self.cached_token = null;
        }

        // SECURITY: Use getNoRedirect to prevent the Metadata-Flavor: Google
        // header from being forwarded to a redirect target. The metadata server
        // uses plaintext HTTP — an attacker with DNS poisoning or MITM could
        // inject a 302 to exfiltrate the token. Refusing redirects blocks this.
        var response = client.getNoRedirect(METADATA_TOKEN_URL, &.{
            .{ .name = "Metadata-Flavor", .value = "Google" },
        }) catch return error.MetadataUnavailable;
        defer response.deinit();

        if (response.status != .ok) return error.MetadataUnavailable;

        self.cached_token = try parseTokenResponse(self.allocator, response.body, now);
        return self.cached_token.?.access_token;
    }

    pub fn deinit(self: *MetadataProvider) void {
        if (self.cached_token) |*t| t.deinit();
    }
};

// ============================================================================
// Static Provider — for testing or manual token injection
// ============================================================================

pub const StaticProvider = struct {
    token: []const u8,

    pub fn init(token: []const u8) StaticProvider {
        return .{ .token = token };
    }

    pub fn getToken(self: *StaticProvider) ![]const u8 {
        return self.token;
    }
};

// ============================================================================
// Auto-detection
// ============================================================================

/// Detect credentials in priority order:
/// 1. GOOGLE_APPLICATION_CREDENTIALS env var (service account file)
/// 2. GCP metadata server (Cloud Run / GCE)
/// 3. Application Default Credentials (~/.config/gcloud/...)
pub fn autoDetect(allocator: std.mem.Allocator, client: *HttpClient, scope: []const u8, environ_map: ?*const std.process.Environ.Map) !TokenProvider {
    // 1. Explicit service account file via env var
    if (environ_map) |em| {
        if (em.get("GOOGLE_APPLICATION_CREDENTIALS")) |path| {
            const sa = ServiceAccountProvider.fromFile(allocator, path, scope) catch |err| switch (err) {
                error.NoCredentialsFound, error.InvalidCredentials => null,
                else => return err,
            };
            if (sa) |provider| return .{ .service_account = provider };
        }
    }

    // 2. Metadata server (fast fail if not on GCP)
    // SECURITY: No redirects — same reason as MetadataProvider.getToken
    {
        var response = client.getNoRedirect(METADATA_PROJECT_URL, &.{
            .{ .name = "Metadata-Flavor", .value = "Google" },
        }) catch null;
        if (response) |*r| {
            defer r.deinit();
            if (r.status == .ok) {
                return .{ .metadata = MetadataProvider.init(allocator) };
            }
        }
    }

    // 3. Application Default Credentials
    {
        const adc = ADCProvider.init(allocator, environ_map) catch |err| switch (err) {
            error.NoCredentialsFound, error.InvalidCredentials => null,
            else => return err,
        };
        if (adc) |provider| return .{ .adc = provider };
    }

    return error.NoCredentialsFound;
}

// ============================================================================
// Shared helpers
// ============================================================================

/// Validate that a token URI points to a known Google endpoint.
pub fn isAllowedTokenUri(uri: []const u8) bool {
    // Must be HTTPS
    if (!std.mem.startsWith(u8, uri, "https://")) return false;
    for (allowed_token_hosts) |host| {
        if (std.mem.indexOf(u8, uri, host) != null) return true;
    }
    return false;
}

/// POST to a token endpoint and parse the response.
fn exchangeToken(allocator: std.mem.Allocator, client: *HttpClient, url: []const u8, body: []const u8, now: i64) !Token {
    var response = client.post(url, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    }, body) catch return error.HttpError;
    defer response.deinit();

    if (response.status != .ok) return error.TokenExchangeFailed;

    return parseTokenResponse(allocator, response.body, now);
}

/// Parse a Google OAuth2 token response JSON.
fn parseTokenResponse(allocator: std.mem.Allocator, body: []const u8, now: i64) !Token {
    const parsed = std.json.parseFromSlice(TokenResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();

    const tr = parsed.value;
    const access_token = allocator.dupe(u8, tr.access_token) catch return error.OutOfMemory;

    // Clamp expires_in to a sane range. A malicious token endpoint could
    // return a huge value (caching a stale/revoked token forever) or a
    // negative value (causing arithmetic overflow). Google tokens max at 3600s
    // but we allow up to 7200s for safety margin.
    const raw_expires: i64 = tr.expires_in orelse 3600;
    const expires_in: i64 = @max(0, @min(raw_expires, 7200));

    return Token{
        .access_token = access_token,
        .expires_at = now + expires_in,
        .allocator = allocator,
    };
}

const TokenResponse = struct {
    access_token: []const u8,
    expires_in: ?i64 = null,
    token_type: ?[]const u8 = null,
};

// ============================================================================
// Convenience: GCP API client helper
// ============================================================================

/// Helper for making authenticated GCP API calls.
/// Usage:
///   var auth = try gcp.autoDetect(allocator, &client, gcp.SCOPE_CLOUD_PLATFORM);
///   defer auth.deinit();
///
///   // Firebase REST API
///   var resp = try gcp.apiGet(&auth, &client, allocator,
///       "https://firestore.googleapis.com/v1/projects/my-proj/databases/(default)/documents/users/abc");
///
///   // BigQuery insert
///   var resp = try gcp.apiPost(&auth, &client, allocator,
///       "https://bigquery.googleapis.com/bigquery/v2/projects/my-proj/datasets/ds/tables/t/insertAll",
///       body_json);
pub fn apiGet(
    auth: *TokenProvider,
    client: *HttpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !HttpClient.Response {
    const token = try auth.getToken(client);
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    return client.get(url, &.{
        .{ .name = "Authorization", .value = auth_header },
    });
}

pub fn apiPost(
    auth: *TokenProvider,
    client: *HttpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !HttpClient.Response {
    const token = try auth.getToken(client);
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    return client.post(url, &.{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
}

/// Authenticated streaming POST — returns SSE event reader for real-time token streaming.
/// Caller MUST call response.deinit() when done.
pub fn apiPostStreaming(
    auth: *TokenProvider,
    client: *HttpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !*HttpClient.StreamingResponse {
    const token = try auth.getToken(client);
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    return client.postStreaming(url, &.{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "text/event-stream" },
    }, body);
}

pub fn apiPut(
    auth: *TokenProvider,
    client: *HttpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !HttpClient.Response {
    const token = try auth.getToken(client);
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    return client.put(url, &.{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
}

pub fn apiDelete(
    auth: *TokenProvider,
    client: *HttpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !HttpClient.Response {
    const token = try auth.getToken(client);
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    return client.delete(url, &.{
        .{ .name = "Authorization", .value = auth_header },
    });
}

test {
    std.testing.refAllDecls(@This());
}
