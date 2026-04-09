// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Universal HTTP Engine Core
//! Processes HTTP request manifests with full concurrency, retry, and circuit breaking

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const RetryEngine = @import("../retry/retry.zig").RetryEngine;
const manifest = @import("manifest.zig");

/// Pure Zig mutex using atomics (no libc)
const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const MAX_SPIN: u32 = 1000;

    pub fn lock(self: *Mutex) void {
        var spin: u32 = 0;
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            spin += 1;
            if (spin >= MAX_SPIN) {
                std.Thread.yield() catch {};
                spin = 0;
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

/// Pure Zig timer using Io.Timestamp (no libc)
const Timer = struct {
    start_ts: std.Io.Timestamp,
    io: std.Io,

    pub fn start(io: std.Io) Timer {
        return .{ .start_ts = std.Io.Timestamp.now(io, .awake), .io = io };
    }

    pub fn read(self: *const Timer) u64 {
        const elapsed = self.start_ts.untilNow(self.io, .awake);
        const ns = elapsed.toNanoseconds();
        return if (ns > 0) @intCast(ns) else 0;
    }
};

pub const EngineConfig = struct {
    /// Maximum concurrent requests
    max_concurrency: u32 = 50,

    /// Default timeout for requests (can be overridden per-request)
    default_timeout_ms: u64 = 30_000,

    /// Default retry attempts (can be overridden per-request)
    default_max_retries: u32 = 3,
};

pub fn Engine(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: EngineConfig,
        retry_engine: RetryEngine,

        /// Output writer for streaming results
        output_writer: WriterType,

        /// Mutex for synchronized output
        output_mutex: Mutex,

        /// Io for timing and sleep — MUST be heap-allocated because
        /// Io.Threaded.io() stores a pointer back to the Threaded instance,
        /// and std.Io.Threaded itself has self-referential internal state
        /// (worker_threads atomic, mutex, etc.) that cannot be safely moved.
        io_threaded: *std.Io.Threaded,

        pub fn init(allocator: std.mem.Allocator, config: EngineConfig, output_writer: WriterType) !Self {
            const io_threaded = try allocator.create(std.Io.Threaded);
            errdefer allocator.destroy(io_threaded);
            io_threaded.* = .init(allocator, .{});

            return Self{
                .allocator = allocator,
                .config = config,
                .retry_engine = RetryEngine.init(allocator, .{}, io_threaded.io()),
                .output_writer = output_writer,
                .output_mutex = .{},
                .io_threaded = io_threaded,
            };
        }

        pub fn deinit(self: *Self) void {
            self.io_threaded.deinit();
            self.allocator.destroy(self.io_threaded);
        }

        /// Process a batch of request manifests
        pub fn processBatch(self: *Self, requests: []manifest.RequestManifest) !void {
            const max_concurrent = @min(self.config.max_concurrency, requests.len);

            // Simple approach: spawn a thread for each request up to max_concurrency
            var threads = try self.allocator.alloc(std.Thread, max_concurrent);
            defer self.allocator.free(threads);

            var request_index: usize = 0;
            while (request_index < requests.len) {
                // Spawn threads up to max_concurrency
                const batch_size = @min(max_concurrent, requests.len - request_index);

                for (0..batch_size) |i| {
                    const req_idx = request_index + i;
                    threads[i] = try std.Thread.spawn(.{}, processRequestThread, .{ self, &requests[req_idx] });
                }

                // Wait for this batch to complete
                for (threads[0..batch_size]) |thread| {
                    thread.join();
                }

                request_index += batch_size;
            }
        }

        /// Thread entry point
        fn processRequestThread(self: *Self, request: *manifest.RequestManifest) void {
            self.processRequest(request);
        }

        /// Process a single request with per-attempt client isolation
        fn processRequest(self: *Self, request: *manifest.RequestManifest) void {
            const io = self.io_threaded.io();
            var timer = Timer.start(io);

            var response = manifest.ResponseManifest{
                .id = undefined,
                .status = 0,
                .latency_ms = 0,
                .allocator = self.allocator,
            };

            // Duplicate ID for response
            response.id = self.allocator.dupe(u8, request.id) catch {
                self.writeError(request.id, "Memory allocation failed");
                return;
            };
            defer response.deinit();

            // Execute request with retry — fresh HttpClient per attempt
            // so a bad TLS/connection state doesn't contaminate retries
            const max_retries = request.max_retries orelse self.config.default_max_retries;
            var retry_count: u32 = 0;
            var last_err: ?anyerror = null;

            while (retry_count <= max_retries) : (retry_count += 1) {
                // Fresh HTTP client per attempt — isolates connection state
                var http_client = HttpClient.init(self.allocator) catch |err| {
                    last_err = err;
                    // Short backoff before trying to init again
                    if (retry_count < max_retries) {
                        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                        continue;
                    }
                    break;
                };
                defer http_client.deinit();

                var result = self.executeHttpRequest(&http_client, request);

                if (result) |*http_response| {
                    defer http_response.deinit();

                    response.status = @intFromEnum(http_response.status);
                    response.body = self.allocator.dupe(u8, http_response.body) catch null;
                    response.retry_count = retry_count;
                    last_err = null;
                    break;
                } else |err| {
                    last_err = err;
                    if (retry_count < max_retries) {
                        const backoff_ms = @as(u64, 100) * (@as(u64, 1) << @intCast(retry_count));
                        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
                        continue;
                    }
                    break;
                }
            }

            // If we never succeeded, write a categorized error message
            if (last_err) |err| {
                const category = categorizeError(err);
                response.error_message = std.fmt.allocPrint(
                    self.allocator,
                    "{s}: {s}",
                    .{ category, @errorName(err) },
                ) catch null;
                response.retry_count = retry_count;
            }

            const elapsed_ns = timer.read();
            response.latency_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

            self.writeResponse(&response);
        }

        /// Categorize an error for clearer debugging
        fn categorizeError(err: anyerror) []const u8 {
            return switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.ConnectionTimedOut,
                error.NetworkUnreachable,
                error.HostUnreachable,
                error.ConnectionLost,
                => "connection_failed",

                error.TlsInitializationFailed,
                error.CertificateBundleLoadFailure,
                => "tls_failed",

                error.UnknownHostName,
                error.TemporaryNameServerFailure,
                error.NameServerFailure,
                error.UnexpectedHostNameError,
                => "dns_failed",

                error.OutOfMemory,
                => "out_of_memory",

                error.HttpHeadersInvalid,
                error.HttpHeaderContinuationsUnsupported,
                error.HttpTransferEncodingUnsupported,
                => "http_protocol_error",

                error.UnsupportedUriScheme,
                error.InvalidCharacter,
                error.InvalidFormat,
                => "invalid_url",

                error.InvalidHeader,
                => "invalid_header",

                else => "request_failed",
            };
        }

        /// Execute HTTP request
        fn executeHttpRequest(self: *Self, http_client: *HttpClient, request: *manifest.RequestManifest) !HttpClient.Response {
            // Build headers
            var headers: std.ArrayList(std.http.Header) = .empty;
            defer headers.deinit(self.allocator);

            if (request.headers) |*req_headers| {
                var it = req_headers.map.iterator();
                while (it.next()) |entry| {
                    try headers.append(self.allocator, .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                    });
                }
            }

            // Execute based on method
            return switch (request.method) {
                .GET => try http_client.get(request.url, headers.items),
                .POST, .PUT, .PATCH => blk: {
                    const body = request.body orelse "";
                    if (request.method == .POST) {
                        break :blk try http_client.post(request.url, headers.items, body);
                    } else if (request.method == .PUT) {
                        break :blk try http_client.put(request.url, headers.items, body);
                    } else {
                        break :blk try http_client.patch(request.url, headers.items, body);
                    }
                },
                .DELETE => try http_client.delete(request.url, headers.items),
                .HEAD, .OPTIONS => error.MethodNotSupported,
            };
        }

        /// Write response to output (thread-safe)
        fn writeResponse(self: *Self, response: *manifest.ResponseManifest) void {
            self.output_mutex.lock();
            defer self.output_mutex.unlock();

            // Format response as JSON and write to output
            const json = response.toJsonString(self.allocator) catch |err| {
                std.debug.print("Error formatting response: {}\n", .{err});
                return;
            };
            defer self.allocator.free(json);

            _ = self.output_writer.write(json) catch |err| {
                std.debug.print("Error writing response: {}\n", .{err});
            };
        }

        /// Write error to output (thread-safe)
        fn writeError(self: *Self, id: []const u8, error_message: []const u8) void {
            self.output_mutex.lock();
            defer self.output_mutex.unlock();

            const json = std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{s}\",\"status\":0,\"error\":\"{s}\"}}\n",
                .{ id, error_message },
            ) catch return;
            defer self.allocator.free(json);

            _ = self.output_writer.write(json) catch {};
        }
    };
}
