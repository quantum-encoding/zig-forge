// GCP Context — TokenProvider + HttpClient for Firestore/BigQuery
// On Cloud Run: MetadataProvider (auto-tokens from metadata server)
// Locally: ServiceAccountProvider via GOOGLE_APPLICATION_CREDENTIALS env var
// Fallback: ADC from gcloud auth application-default login

const std = @import("std");
const gcp_auth = @import("gcp-auth");
const hs = @import("http-sentinel");

pub const GcpContext = struct {
    allocator: std.mem.Allocator,
    http_client: hs.HttpClient,
    provider: gcp_auth.TokenProvider,
    project_id: []const u8,

    /// Initialize GCP context via autoDetect (SA key → Metadata → ADC).
    pub fn init(
        allocator: std.mem.Allocator,
        project_id: []const u8,
        environ_map: *const std.process.Environ.Map,
    ) !GcpContext {
        var http_client = try hs.HttpClient.init(allocator);
        errdefer http_client.deinit();

        const provider = try gcp_auth.autoDetect(
            allocator,
            &http_client,
            gcp_auth.SCOPE_CLOUD_PLATFORM,
            environ_map,
        );

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .provider = provider,
            .project_id = project_id,
        };
    }

    pub fn deinit(self: *GcpContext) void {
        self.provider.deinit();
        self.http_client.deinit();
    }

    /// Authenticated GET
    pub fn get(self: *GcpContext, url: []const u8) !hs.HttpClient.Response {
        return gcp_auth.apiGet(&self.provider, &self.http_client, self.allocator, url);
    }

    /// Authenticated POST
    pub fn post(self: *GcpContext, url: []const u8, body: []const u8) !hs.HttpClient.Response {
        return gcp_auth.apiPost(&self.provider, &self.http_client, self.allocator, url, body);
    }

    /// Authenticated PATCH (Firestore upsert, etc.)
    pub fn patch(self: *GcpContext, url: []const u8, body: []const u8) !hs.HttpClient.Response {
        return gcp_auth.apiPatch(&self.provider, &self.http_client, self.allocator, url, body);
    }

    /// Authenticated PATCH with a fresh HTTP connection.
    /// Avoids stale connection pool issues after GET requests.
    pub fn patchFresh(self: *GcpContext, url: []const u8, body: []const u8) !hs.HttpClient.Response {
        var fresh = hs.HttpClient.init(self.allocator) catch return error.HttpError;
        defer fresh.deinit();
        return gcp_auth.apiPatch(&self.provider, &fresh, self.allocator, url, body);
    }

    /// Authenticated DELETE
    pub fn delete(self: *GcpContext, url: []const u8) !hs.HttpClient.Response {
        return gcp_auth.apiDelete(&self.provider, &self.http_client, self.allocator, url);
    }

    /// Authenticated streaming POST — returns SSE event reader
    pub fn postStreaming(self: *GcpContext, url: []const u8, body: []const u8) !*hs.HttpClient.StreamingResponse {
        return gcp_auth.apiPostStreaming(&self.provider, &self.http_client, self.allocator, url, body);
    }
};
