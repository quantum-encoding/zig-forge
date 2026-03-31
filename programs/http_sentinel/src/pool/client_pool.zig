// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;

/// Thread-safe HTTP client pool using the "client-per-worker" pattern
/// Each worker/thread gets its own isolated HTTP client instance
/// This avoids all concurrency issues with Zig 0.16.0's http.Client
pub const ClientPool = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ClientPool {
        return .{
            .allocator = allocator,
        };
    }
    
    /// Create a new HTTP client for a worker thread
    /// Each worker should call this once and own the client for its lifetime
    pub fn createClient(self: *ClientPool) !*HttpClient {
        const client = try self.allocator.create(HttpClient);
        client.* = HttpClient.init(self.allocator);
        return client;
    }
    
    /// Destroy a worker's HTTP client
    pub fn destroyClient(self: *ClientPool, client: *HttpClient) void {
        client.deinit();
        self.allocator.destroy(client);
    }
};

/// Worker context for concurrent HTTP operations
pub const HttpWorker = struct {
    id: usize,
    client: *HttpClient,
    pool: *ClientPool,
    
    pub fn init(pool: *ClientPool, id: usize) !HttpWorker {
        return HttpWorker{
            .id = id,
            .client = try pool.createClient(),
            .pool = pool,
        };
    }
    
    pub fn deinit(self: *HttpWorker) void {
        self.pool.destroyClient(self.client);
    }
    
    /// Perform HTTP operations using this worker's dedicated client
    pub fn get(self: *HttpWorker, url: []const u8, headers: []const std.http.Header) !HttpClient.Response {
        return self.client.get(url, headers);
    }
    
    pub fn post(self: *HttpWorker, url: []const u8, headers: []const std.http.Header, body: []const u8) !HttpClient.Response {
        return self.client.post(url, headers, body);
    }
};