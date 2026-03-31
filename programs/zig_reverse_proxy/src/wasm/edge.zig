//! WASM Edge Function Runtime
//!
//! Executes WebAssembly functions for edge computing.
//! Provides HTTP request/response bindings for WASM modules.
//!
//! The WASM module interface:
//! - `handle(request_ptr, request_len) -> response_ptr`
//! - Memory is shared between host and WASM module
//!
//! Imports provided to WASM (via env module):
//! - `env.log(ptr, len)` - Log a message
//! - `env.get_request_method() -> i32` - Get HTTP method
//! - `env.get_request_path(buf_ptr, buf_len) -> i32` - Get request path
//! - `env.get_request_header(name_ptr, name_len, buf_ptr, buf_len) -> i32`
//! - `env.set_response_status(code)` - Set response status
//! - `env.set_response_header(name_ptr, name_len, val_ptr, val_len)`
//! - `env.set_response_body(ptr, len)` - Set response body

const std = @import("std");
const http = @import("../http/parser.zig");

// Zig 0.16 compatible Mutex using pthread
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// =============================================================================
// Edge Function Configuration
// =============================================================================

pub const EdgeConfig = struct {
    /// Maximum memory for WASM module (bytes)
    max_memory: u32 = 64 * 1024 * 1024,
    /// Maximum execution time (ms)
    timeout_ms: u32 = 30000,
    /// Enable debug logging
    debug: bool = false,
    /// Maximum request body size
    max_request_body: u32 = 10 * 1024 * 1024,
    /// Maximum response body size
    max_response_body: u32 = 10 * 1024 * 1024,
};

// =============================================================================
// Edge Request (serialized for WASM)
// =============================================================================

/// Serialized request format for WASM modules
pub const EdgeRequest = struct {
    method: http.Method,
    path: []const u8,
    query: ?[]const u8,
    host: []const u8,
    headers: []const http.Header,
    body: []const u8,

    /// Serialize request to bytes for WASM
    pub fn serialize(self: *const EdgeRequest, buf: []u8) !usize {
        var pos: usize = 0;

        // Method (1 byte)
        buf[pos] = @intFromEnum(self.method);
        pos += 1;

        // Path length + data
        pos += try writeString(buf[pos..], self.path);

        // Query length + data (0 if null)
        if (self.query) |q| {
            pos += try writeString(buf[pos..], q);
        } else {
            pos += try writeU32(buf[pos..], 0);
        }

        // Host
        pos += try writeString(buf[pos..], self.host);

        // Headers count (u16)
        if (pos + 2 > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(self.headers.len), .little);
        pos += 2;

        // Headers
        for (self.headers) |h| {
            pos += try writeString(buf[pos..], h.name);
            pos += try writeString(buf[pos..], h.value);
        }

        // Body
        pos += try writeString(buf[pos..], self.body);

        return pos;
    }

    /// Deserialize request from bytes
    pub fn deserialize(data: []const u8) !EdgeRequest {
        var pos: usize = 0;

        // Method
        const method: http.Method = @enumFromInt(data[pos]);
        pos += 1;

        // Path
        const path_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const path = data[pos..][0..path_len];
        pos += path_len;

        // Query
        const query_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const query = if (query_len > 0) data[pos..][0..query_len] else null;
        pos += query_len;

        // Host
        const host_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const host = data[pos..][0..host_len];
        pos += host_len;

        // Headers (skip for now - would need allocator)
        const header_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        var i: usize = 0;
        while (i < header_count) : (i += 1) {
            const name_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4 + name_len;
            const value_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4 + value_len;
        }

        // Body
        const body_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const body = data[pos..][0..body_len];

        return EdgeRequest{
            .method = method,
            .path = path,
            .query = query,
            .host = host,
            .headers = &.{},
            .body = body,
        };
    }
};

// =============================================================================
// Edge Response (serialized from WASM)
// =============================================================================

pub const EdgeResponse = struct {
    status: u16 = 200,
    headers: [http.MAX_HEADERS]http.Header = undefined,
    header_count: usize = 0,
    body: []const u8 = "",

    /// Deserialize response from WASM output
    pub fn deserialize(data: []const u8) !EdgeResponse {
        var response = EdgeResponse{};
        var pos: usize = 0;

        // Status code (u16)
        response.status = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        // Header count
        const header_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        // Headers
        var i: usize = 0;
        while (i < header_count and i < http.MAX_HEADERS) : (i += 1) {
            const name_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            const name = data[pos..][0..name_len];
            pos += name_len;

            const value_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            const value = data[pos..][0..value_len];
            pos += value_len;

            response.headers[i] = .{ .name = name, .value = value };
        }
        response.header_count = i;

        // Body
        const body_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        response.body = data[pos..][0..body_len];

        return response;
    }

    /// Convert to HTTP response
    pub fn toHttpResponse(self: *const EdgeResponse) http.Response {
        var response = http.Response{
            .status_code = self.status,
            .reason = statusReason(self.status),
            .header_count = self.header_count,
            .body = self.body,
            .content_length = self.body.len,
        };

        for (self.headers[0..self.header_count], 0..) |h, i| {
            response.headers[i] = h;
        }

        return response;
    }
};

// =============================================================================
// Edge Function Handler
// =============================================================================

pub const EdgeHandler = struct {
    allocator: std.mem.Allocator,
    config: EdgeConfig,

    // WASM module data
    module_data: ?[]const u8 = null,

    // Execution context - stores current request for host function access
    current_request: ?*const http.Request = null,
    response_status: u16 = 200,
    response_headers: [http.MAX_HEADERS]http.Header = undefined,
    response_header_count: usize = 0,
    response_body: []const u8 = "",

    // Execution buffers
    request_buf: [1024 * 1024]u8 = undefined,
    response_buf: [1024 * 1024]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, config: EdgeConfig) EdgeHandler {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *EdgeHandler) void {
        if (self.module_data) |data| {
            self.allocator.free(data);
        }
    }

    /// Load WASM module from file
    pub fn loadModule(self: *EdgeHandler, path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Use readFileAlloc for simpler file reading (Zig 0.16.1859)
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024));

        if (self.module_data) |old| {
            self.allocator.free(old);
        }
        self.module_data = data;
    }

    /// Execute edge function with HTTP request
    pub fn execute(self: *EdgeHandler, request: *const http.Request) !EdgeResponse {
        // Store current request for host function access
        self.current_request = request;
        defer self.current_request = null;

        // Reset response state
        self.response_status = 200;
        self.response_header_count = 0;
        self.response_body = "";

        // Convert HTTP request to edge request
        const edge_request = EdgeRequest{
            .method = request.method,
            .path = request.path,
            .query = request.query,
            .host = request.host,
            .headers = request.headers[0..request.header_count],
            .body = request.body,
        };

        // Serialize request
        const request_len = try edge_request.serialize(&self.request_buf);

        // Execute WASM module
        const response_len = try self.executeWasm(
            self.request_buf[0..request_len],
            &self.response_buf,
        );

        // If WASM wrote to response buffer, deserialize it
        if (response_len > 0) {
            return EdgeResponse.deserialize(self.response_buf[0..response_len]);
        }

        // Otherwise, build response from host function calls
        var response = EdgeResponse{
            .status = self.response_status,
            .header_count = self.response_header_count,
            .body = self.response_body,
        };

        for (self.response_headers[0..self.response_header_count], 0..) |h, i| {
            response.headers[i] = h;
        }

        return response;
    }

    /// Execute WASM module
    /// This integrates with the wasm_runtime module
    fn executeWasm(self: *EdgeHandler, request_data: []const u8, response_buf: []u8) !usize {
        _ = request_data;

        // Check if we have a loaded module
        if (self.module_data == null) {
            // No WASM module loaded, return a default response
            return buildDefaultResponse(response_buf);
        }

        // Parse WASM module
        // Note: In production, this would use @import("wasm_runtime") directly
        // For now, we return a placeholder response since we can't directly
        // import from the other program

        // TODO: Integration with wasm_runtime:
        //
        // const wasm = @import("wasm_runtime");
        //
        // var module = try wasm.parse(self.allocator, self.module_data.?);
        // defer module.deinit();
        //
        // var instance = try wasm.instantiate(self.allocator, &module);
        // defer instance.deinit();
        //
        // // Set up import resolver for host functions
        // instance.import_resolver = handleImport;
        // instance.import_resolver_ctx = @ptrCast(self);
        //
        // // Call the "handle" function with request pointer
        // const request_ptr: i32 = @intCast(self.writeToMemory(&instance, request_data));
        // const result = try instance.call("handle", &.{
        //     .{ .i32 = request_ptr },
        //     .{ .i32 = @intCast(request_data.len) },
        // });
        //
        // if (result) |val| {
        //     const response_ptr: usize = @intCast(val.asI32());
        //     return self.readFromMemory(&instance, response_ptr, response_buf);
        // }

        return buildDefaultResponse(response_buf);
    }

    /// Build a default JSON response
    fn buildDefaultResponse(response_buf: []u8) usize {
        const response_body =
            \\{"status":"ok","message":"Edge function executed","runtime":"quantum-edge"}
        ;

        // Status code (200)
        std.mem.writeInt(u16, response_buf[0..2], 200, .little);

        // Header count (1)
        std.mem.writeInt(u16, response_buf[2..4], 1, .little);

        // Content-Type header
        var pos: usize = 4;
        const ct_name = "Content-Type";
        const ct_value = "application/json";

        std.mem.writeInt(u32, response_buf[pos..][0..4], ct_name.len, .little);
        pos += 4;
        @memcpy(response_buf[pos..][0..ct_name.len], ct_name);
        pos += ct_name.len;

        std.mem.writeInt(u32, response_buf[pos..][0..4], ct_value.len, .little);
        pos += 4;
        @memcpy(response_buf[pos..][0..ct_value.len], ct_value);
        pos += ct_value.len;

        // Body
        std.mem.writeInt(u32, response_buf[pos..][0..4], response_body.len, .little);
        pos += 4;
        @memcpy(response_buf[pos..][0..response_body.len], response_body);
        pos += response_body.len;

        return pos;
    }
};

// =============================================================================
// Edge Function Cache
// =============================================================================

pub const ModuleCache = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMapUnmanaged(*EdgeHandler),
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ModuleCache {
        return .{
            .allocator = allocator,
            .handlers = .{},
        };
    }

    pub fn deinit(self: *ModuleCache) void {
        var iter = self.handlers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.handlers.deinit(self.allocator);
    }

    /// Get or load a handler for a module path
    pub fn getHandler(self: *ModuleCache, path: []const u8, config: EdgeConfig) !*EdgeHandler {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handlers.getPtr(path)) |handler_ptr| {
            return handler_ptr.*;
        }

        // Load new handler
        const handler = try self.allocator.create(EdgeHandler);
        handler.* = EdgeHandler.init(self.allocator, config);
        errdefer {
            handler.deinit();
            self.allocator.destroy(handler);
        }

        try handler.loadModule(path);
        try self.handlers.put(self.allocator, path, handler);

        return handler;
    }

    /// Remove a handler from cache
    pub fn removeHandler(self: *ModuleCache, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handlers.fetchRemove(path)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    /// Clear all cached handlers
    pub fn clear(self: *ModuleCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.handlers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.handlers.clearRetainingCapacity();
    }
};

// =============================================================================
// Host Function Interface
// =============================================================================

/// Host functions that WASM modules can call
pub const HostFunctions = struct {
    /// Log a message from WASM
    pub fn log(handler: *EdgeHandler, ptr: u32, len: u32) void {
        _ = handler;
        _ = ptr;
        _ = len;
        // Would read from WASM memory and log
        std.log.info("[WASM] log called", .{});
    }

    /// Get request method (returns enum value)
    pub fn getRequestMethod(handler: *EdgeHandler) i32 {
        if (handler.current_request) |req| {
            return @intFromEnum(req.method);
        }
        return 0;
    }

    /// Get request path length
    pub fn getRequestPathLen(handler: *EdgeHandler) i32 {
        if (handler.current_request) |req| {
            return @intCast(req.path.len);
        }
        return 0;
    }

    /// Set response status code
    pub fn setResponseStatus(handler: *EdgeHandler, status: i32) void {
        handler.response_status = @intCast(@as(u32, @bitCast(status)));
    }

    /// Set response body (stores pointer for later)
    pub fn setResponseBody(handler: *EdgeHandler, ptr: u32, len: u32) void {
        _ = handler;
        _ = ptr;
        _ = len;
        // Would read from WASM memory
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn writeU32(buf: []u8, value: u32) !usize {
    if (buf.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], value, .little);
    return 4;
}

fn writeString(buf: []u8, str: []const u8) !usize {
    if (buf.len < 4 + str.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[0..4], @intCast(str.len), .little);
    @memcpy(buf[4..][0..str.len], str);
    return 4 + str.len;
}

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "edge request serialization" {
    var buf: [1024]u8 = undefined;

    const request = EdgeRequest{
        .method = .GET,
        .path = "/api/test",
        .query = "foo=bar",
        .host = "example.com",
        .headers = &.{},
        .body = "hello",
    };

    const len = try request.serialize(&buf);
    try std.testing.expect(len > 0);

    const parsed = try EdgeRequest.deserialize(buf[0..len]);
    try std.testing.expectEqual(http.Method.GET, parsed.method);
    try std.testing.expectEqualStrings("/api/test", parsed.path);
    try std.testing.expectEqualStrings("hello", parsed.body);
}

test "edge handler placeholder" {
    const allocator = std.testing.allocator;

    var handler = EdgeHandler.init(allocator, .{});
    defer handler.deinit();

    const request = http.Request{
        .method = .GET,
        .path = "/test",
        .host = "example.com",
    };

    const response = try handler.execute(&request);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(response.body.len > 0);
}

test "module cache" {
    const allocator = std.testing.allocator;

    var cache = ModuleCache.init(allocator);
    defer cache.deinit();

    // Cache starts empty
    try std.testing.expect(cache.handlers.count() == 0);
}
