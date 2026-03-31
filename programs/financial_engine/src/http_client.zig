const std = @import("std");
const http = std.http;

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        var threaded: std.Io.Threaded = .init_single_threaded;
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator, .io = threaded.io() },
            .threaded = threaded,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub const Response = struct {
        status: http.Status,
        body: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    pub fn post(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
        body: []const u8,
    ) !Response {
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

        // Read response body
        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        
        // Read all the response data using allocRemaining
        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    pub fn get(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        // Read response body
        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);

        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);
        
        // Read all the response data using allocRemaining
        const body_data = try response_reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
        defer self.allocator.free(body_data);

        const body_slice = try self.allocator.dupe(u8, body_data);

        return Response{
            .status = response.head.status,
            .body = body_slice,
            .allocator = self.allocator,
        };
    }

    pub fn delete(
        self: *HttpClient,
        url: []const u8,
        headers: []const http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.DELETE, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});

        // Read response body with proper Reader API
        var transfer_buffer: [8192]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        // Read up to 10MB
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
        };
    }
};