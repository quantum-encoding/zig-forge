// Thread-Safe HTTP Client Architecture
// Each thread/tenant gets its own complete HTTP client instance
// This prevents the segfault issue identified in CRITICAL_THREAD_SAFETY_ANALYSIS.md

const std = @import("std");
const http = std.http;

/// Thread-local HTTP client - safe for concurrent use when each thread has its own instance
pub const ThreadSafeHttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    tenant_id: []const u8,  // For debugging/logging
    request_count: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tenant_id: []const u8) !Self {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .tenant_id = try allocator.dupe(u8, tenant_id),
            .request_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.allocator.free(self.tenant_id);
    }

    pub const Response = struct {
        status: http.Status,
        body: []u8,
        allocator: std.mem.Allocator,
        request_id: u64,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    pub fn post(
        self: *Self,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
        const request_id = self.request_count.fetchAdd(1, .monotonic);

        std.log.debug("[{s}] HTTP POST #{d} to {s}", .{
            self.tenant_id,
            request_id,
            url
        });

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
            .request_id = request_id,
        };
    }

    pub fn get(
        self: *Self,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const request_id = self.request_count.fetchAdd(1, .monotonic);

        std.log.debug("[{s}] HTTP GET #{d} to {s}", .{
            self.tenant_id,
            request_id,
            url
        });

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
            .request_id = request_id,
        };
    }

    pub fn delete(
        self: *Self,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const request_id = self.request_count.fetchAdd(1, .monotonic);

        std.log.debug("[{s}] HTTP DELETE #{d} to {s}", .{
            self.tenant_id,
            request_id,
            url
        });

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.DELETE, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        const body_data = try response_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024)
        );
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
            .request_id = request_id,
        };
    }
};

// Test to verify thread safety
test "concurrent HTTP clients are safe" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ThreadContext = struct {
        client: ThreadSafeHttpClient,
        success_count: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            // Each thread makes multiple requests
            for (0..10) |_| {
                const headers = [_]http.Header{
                    .{ .name = "User-Agent", .value = "Test" },
                };

                // This would segfault with shared client
                const response = ctx.client.get(
                    "https://httpbin.org/get",
                    &headers
                ) catch {
                    continue;
                };
                defer response.deinit();

                if (response.status == .ok) {
                    _ = ctx.success_count.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var success_count = std.atomic.Value(u32).init(0);
    var threads: [5]std.Thread = undefined;
    var contexts: [5]ThreadContext = undefined;

    // Create thread-local clients
    for (&contexts, 0..) |*ctx, i| {
        const tenant_id = try std.fmt.allocPrint(allocator, "tenant_{d}", .{i});
        defer allocator.free(tenant_id);

        ctx.* = .{
            .client = try ThreadSafeHttpClient.init(allocator, tenant_id),
            .success_count = &success_count,
        };
    }
    defer for (&contexts) |*ctx| ctx.client.deinit();

    // Spawn threads
    for (&threads, &contexts) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    // Verify no crashes and some successes
    try testing.expect(success_count.load(.acquire) > 0);
}