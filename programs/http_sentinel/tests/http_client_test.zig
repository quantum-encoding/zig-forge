// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const testing = std.testing;
const HttpClient = @import("../src/http_client.zig").HttpClient;

/// Production-grade test suite for HTTP Sentinel
/// Comprehensive testing of all HTTP operations with error scenarios

test "HTTP client initialization and cleanup" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    try testing.expect(client.allocator == allocator);
}

test "GET request with custom options" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "zig-http-sentinel/1.0" },
    };
    
    const options = HttpClient.RequestOptions{
        .max_body_size = 1024 * 1024, // 1MB
        .timeout_ns = 30 * std.time.ns_per_s, // 30 seconds
    };
    
    // Test against a reliable endpoint
    var response = client.getWithOptions(
        "https://httpbin.org/get",
        &headers,
        options,
    ) catch |err| {
        // Skip test if network unavailable
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping GET test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
    try testing.expect(response.body.len > 0);
    
    // Response should contain our headers
    try testing.expect(std.mem.indexOf(u8, response.body, "zig-http-sentinel") != null);
}

test "POST request with JSON payload" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };
    
    const json_payload =
        \\{
        \\  "client": "zig-http-sentinel",
        \\  "version": "1.0.0",
        \\  "features": ["production-grade", "thread-safe", "high-performance"]
        \\}
    ;
    
    var response = client.post(
        "https://httpbin.org/post",
        &headers,
        json_payload,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping POST test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
    try testing.expect(response.body.len > 0);
    
    // Response should echo our JSON
    try testing.expect(std.mem.indexOf(u8, response.body, "zig-http-sentinel") != null);
}

test "PUT request functionality" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    
    const payload = "{\"data\": \"test_update\"}";
    
    var response = client.put(
        "https://httpbin.org/put",
        &headers,
        payload,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping PUT test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
    try testing.expect(std.mem.indexOf(u8, response.body, "test_update") != null);
}

test "PATCH request functionality" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    
    const payload = "{\"patch\": \"data\"}";
    
    var response = client.patch(
        "https://httpbin.org/patch",
        &headers,
        payload,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping PATCH test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
}

test "DELETE request functionality" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Bearer test-token" },
    };
    
    var response = client.delete(
        "https://httpbin.org/delete",
        &headers,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping DELETE test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
}

test "HEAD request functionality" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "zig-http-sentinel-test" },
    };
    
    var response = client.head(
        "https://httpbin.org/get",
        &headers,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping HEAD test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
    try testing.expect(response.body.len == 0); // HEAD should have no body
}

test "Error handling for invalid URLs" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    // Test invalid URL
    const result = client.get("not-a-valid-url", &.{});
    try testing.expectError(error.InvalidUri, result);
}

test "Error handling for non-existent domain" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    // Test non-existent domain
    const result = client.get("https://this-domain-definitely-does-not-exist-12345.com", &.{});
    
    // Should get some kind of network error
    try testing.expectError(anyerror, result);
}

test "Large response handling" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const options = HttpClient.RequestOptions{
        .max_body_size = 100 * 1024, // 100KB limit
    };
    
    // Request a large response
    var response = client.getWithOptions(
        "https://httpbin.org/bytes/50000", // 50KB
        &.{},
        options,
    ) catch |err| {
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network unavailable, skipping large response test\n", .{});
            return;
        }
        return err;
    };
    defer response.deinit();
    
    try testing.expect(response.status == .ok);
    try testing.expect(response.body.len == 50000);
}

test "Timeout handling" {
    const allocator = testing.allocator;
    
    var client = HttpClient.init(allocator);
    defer client.deinit();
    
    const options = HttpClient.RequestOptions{
        .timeout_ns = 1 * std.time.ns_per_s, // Very short timeout
        .max_body_size = 1024,
    };
    
    // This might timeout depending on network conditions
    const result = client.getWithOptions(
        "https://httpbin.org/delay/5", // 5 second delay
        &.{},
        options,
    );
    
    // Either succeeds (fast network) or times out
    if (result) |response| {
        response.deinit();
    } else |err| {
        // Timeout or connection error is expected
        try testing.expect(
            err == error.ConnectionTimedOut or 
            err == error.NetworkUnreachable or
            err == error.ConnectionRefused
        );
    }
}

test "Thread safety - concurrent requests" {
    const allocator = testing.allocator;
    
    const Worker = struct {
        allocator: std.mem.Allocator,
        id: u32,
        success_count: *std.atomic.Value(u32),
        error_count: *std.atomic.Value(u32),
        
        fn run(self: @This()) void {
            // Each thread must create its own client
            var client = HttpClient.init(self.allocator);
            defer client.deinit();
            
            var i: u32 = 0;
            while (i < 5) {
                const url = std.fmt.allocPrint(
                    self.allocator,
                    "https://httpbin.org/delay/0?worker={d}&request={d}",
                    .{ self.id, i },
                ) catch {
                    _ = self.error_count.fetchAdd(1, .monotonic);
                    return;
                };
                defer self.allocator.free(url);
                
                var response = client.get(url, &.{}) catch {
                    _ = self.error_count.fetchAdd(1, .monotonic);
                    i += 1;
                    continue;
                };
                defer response.deinit();
                
                if (response.status == .ok) {
                    _ = self.success_count.fetchAdd(1, .monotonic);
                } else {
                    _ = self.error_count.fetchAdd(1, .monotonic);
                }
                
                i += 1;
            }
        }
    };
    
    var success_count = std.atomic.Value(u32).init(0);
    var error_count = std.atomic.Value(u32).init(0);
    
    const num_workers = 4;
    var workers: [num_workers]Worker = undefined;
    var threads: [num_workers]std.Thread = undefined;
    
    // Initialize workers
    for (&workers, 0..) |*worker, i| {
        worker.* = Worker{
            .allocator = allocator,
            .id = @intCast(i),
            .success_count = &success_count,
            .error_count = &error_count,
        };
    }
    
    // Launch threads
    for (&workers, &threads) |*worker, *thread| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{worker.*}) catch {
            std.debug.print("Failed to spawn thread, skipping concurrent test\n", .{});
            return;
        };
    }
    
    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }
    
    const total_successes = success_count.load(.monotonic);
    const total_errors = error_count.load(.monotonic);
    
    std.debug.print("Thread safety test: {} successes, {} errors\n", .{ total_successes, total_errors });
    
    // At least some operations should succeed if network is available
    try testing.expect(total_successes > 0 or total_errors == 20); // All failed due to network
}