// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Universal HTTP Engine Core
//!
//! The Execution Engine - processes HTTP request manifests with full concurrency,
//! retry logic, and circuit breaking. This is the apex predator DNA of http_sentinel,
//! weaponized into a routing engine for microsecond-level warfare.
//!
//! ## Architecture
//!
//! - **Thread-per-Request**: Each request spawns a dedicated thread with its own
//!   HttpClient instance (client-per-worker pattern for zero contention)
//! - **Batch Processing**: Requests are processed in waves up to max_concurrency
//! - **Exponential Backoff**: Failed requests retry with configurable delays
//! - **Mutex-Protected Output**: Thread-safe streaming of JSONL results

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;
const manifest = @import("manifest.zig");
const fail_log = @import("fail_log.zig");
const auth_refresher_mod = @import("auth_refresher.zig");
const AuthRefresher = auth_refresher_mod.AuthRefresher;

/// Zig 0.16 compatible Mutex using pthread
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// Get monotonic time in nanoseconds using clock_gettime (Zig 0.16 compatible)
fn getMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const EngineConfig = struct {
    /// Maximum concurrent requests (thread pool size per batch)
    max_concurrency: u32 = 50,

    /// Default timeout for requests in milliseconds (0 = no timeout, per-request override via timeout_ms)
    default_timeout_ms: u64 = 300_000, // 5 minutes — suitable for LLM inference

    /// Default retry attempts (can be overridden per-request via max_retries field)
    default_max_retries: u32 = 1,

    /// Save each response body to {output_dir}/{id}.{ext} (null = disabled)
    output_dir: ?[]const u8 = null,

    /// File extension for saved output files (default: "md")
    output_ext: []const u8 = "md",

    /// Dot-path to base64 field in JSON response body (e.g., "predictions.0.bytesBase64Encoded")
    /// When set, extracts the field, decodes base64, and saves raw binary instead of body text.
    base64_field: ?[]const u8 = null,

    /// Name of the header whose value is overridden by the AuthRefresher when
    /// one is attached. Case-insensitive match on the request's baked-in
    /// headers — the refresher's value replaces any existing entry. Default
    /// "Authorization" covers Bearer / OAuth2 / GCP / AWS Signature v4 etc.
    auth_header_name: []const u8 = "Authorization",
};

pub fn Engine(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: EngineConfig,

        /// Output writer for streaming results
        output_writer: WriterType,

        /// Mutex for synchronized output
        output_mutex: Mutex,

        /// Optional failure logger — writes failed requests to a replay file
        fail_logger: ?*fail_log.FailLogger = null,

        /// Optional auth refresher — when set, overrides every request's
        /// Authorization header with a periodically-refreshed Bearer token.
        /// Essential for multi-hour batches where tokens outlive their TTL.
        auth_refresher: ?*AuthRefresher = null,

        pub fn init(allocator: std.mem.Allocator, config: EngineConfig, output_writer: WriterType) !Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .output_writer = output_writer,
                .output_mutex = .{},
                .fail_logger = null,
                .auth_refresher = null,
            };
        }

        /// Attach a failure logger. Call this after init() and before processBatch().
        pub fn setFailLogger(self: *Self, logger: *fail_log.FailLogger) void {
            self.fail_logger = logger;
        }

        /// Attach an auth refresher. Call after init() and before processBatch().
        pub fn setAuthRefresher(self: *Self, refresher: *AuthRefresher) void {
            self.auth_refresher = refresher;
        }

        /// Header list with optional owned auth value for cleanup. Returned by
        /// buildHeaders — the caller must `deinit()` when done so the freshly
        /// fetched bearer string is freed with the worker that requested it.
        const BuiltHeaders = struct {
            list: std.ArrayList(std.http.Header),
            owned_auth_value: ?[]u8,
            allocator: std.mem.Allocator,

            fn deinit(self: *BuiltHeaders) void {
                self.list.deinit(self.allocator);
                if (self.owned_auth_value) |v| {
                    std.crypto.secureZero(u8, v);
                    self.allocator.free(v);
                }
            }
        };

        /// Build the outgoing header list for a request. When an auth refresher
        /// is attached, any baked-in header matching config.auth_header_name
        /// (case-insensitive) is stripped and replaced with the refresher's
        /// current value — so stale Authorization tokens in a plan JSONL
        /// never leak through to the wire.
        fn buildHeaders(self: *Self, request: *manifest.RequestManifest) !BuiltHeaders {
            var list: std.ArrayList(std.http.Header) = .empty;
            errdefer list.deinit(self.allocator);

            var owned_auth: ?[]u8 = null;
            errdefer if (owned_auth) |v| self.allocator.free(v);

            const refresher = self.auth_refresher;
            const auth_name = self.config.auth_header_name;

            if (request.headers) |*req_headers| {
                var it = req_headers.map.iterator();
                while (it.next()) |entry| {
                    if (refresher != null and std.ascii.eqlIgnoreCase(entry.key_ptr.*, auth_name)) {
                        continue; // refresher value takes precedence
                    }
                    try list.append(self.allocator, .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                    });
                }
            }

            if (refresher) |r| {
                const fresh = try r.getAuthHeader(self.allocator);
                owned_auth = fresh;
                try list.append(self.allocator, .{
                    .name = auth_name,
                    .value = fresh,
                });
            }

            return BuiltHeaders{
                .list = list,
                .owned_auth_value = owned_auth,
                .allocator = self.allocator,
            };
        }

        pub fn deinit(_: *Self) void {
            // Nothing to deinit - resources are per-thread
        }

        /// Process a batch of request manifests with high-concurrency execution
        pub fn processBatch(self: *Self, requests: []manifest.RequestManifest) !void {
            const max_concurrent = @min(self.config.max_concurrency, requests.len);

            // Thread pool - spawn threads up to max_concurrency
            var threads = try self.allocator.alloc(?std.Thread, max_concurrent);
            defer self.allocator.free(threads);

            // Initialize all thread slots to null
            for (threads) |*t| {
                t.* = null;
            }

            var request_index: usize = 0;
            var wave: usize = 0;
            while (request_index < requests.len) {
                // Spawn threads up to max_concurrency
                const batch_size = @min(max_concurrent, requests.len - request_index);
                var spawned_count: usize = 0;
                wave += 1;

                std.debug.print("[quantum-curl] Wave {}: dispatching {} requests ({}-{} of {})\n", .{
                    wave, batch_size, request_index + 1, request_index + batch_size, requests.len,
                });

                for (0..batch_size) |i| {
                    const req_idx = request_index + i;
                    threads[i] = std.Thread.spawn(.{}, processRequestThread, .{ self, &requests[req_idx] }) catch |err| {
                        // Log spawn failure and process request synchronously
                        std.debug.print("[quantum-curl] Thread spawn failed: {}, processing synchronously\n", .{err});
                        self.processRequest(&requests[req_idx]);
                        continue;
                    };
                    spawned_count += 1;
                }

                std.debug.print("[quantum-curl] Wave {}: {} threads spawned, waiting for completion...\n", .{ wave, spawned_count });

                // Wait for all spawned threads in this batch to complete
                for (threads[0..batch_size]) |maybe_thread| {
                    if (maybe_thread) |thread| {
                        thread.join();
                    }
                }

                std.debug.print("[quantum-curl] Wave {}: complete\n", .{wave});

                // Reset thread slots for next batch
                for (threads[0..batch_size]) |*t| {
                    t.* = null;
                }

                request_index += batch_size;
            }

            std.debug.print("[quantum-curl] All {} waves complete ({} requests)\n", .{ wave, requests.len });
        }

        /// Thread entry point — wraps processRequest to prevent thread panics from killing the process
        fn processRequestThread(self: *Self, request: *manifest.RequestManifest) void {
            self.processRequest(request);
        }


        /// Decide whether this worker should stream the response body straight
        /// to disk instead of buffering it in RAM. Streaming path is only taken
        /// when an output_dir is configured AND base64_field is unset (base64
        /// extraction requires a fully-buffered JSON body to walk the dot-path).
        fn shouldStream(self: *const Self) bool {
            return self.config.output_dir != null and self.config.base64_field == null;
        }

        /// Process a single request with retry logic
        fn processRequest(self: *Self, request: *manifest.RequestManifest) void {
            const start_time_ns = getMonotonicNs();

            // Create thread-local HTTP client (client-per-worker pattern)
            var http_client = HttpClient.init(self.allocator) catch {
                self.writeError(request.id, "Failed to initialize HTTP client");
                return;
            };
            defer http_client.deinit();

            var response = manifest.ResponseManifest{
                .id = undefined,
                .status = 0,
                .latency_ms = 0,
                .allocator = self.allocator,
            };

            // Duplicate ID for response ownership
            response.id = self.allocator.dupe(u8, request.id) catch {
                self.writeError(request.id, "Memory allocation failed");
                return;
            };

            const stream_mode = self.shouldStream();

            // Execute request with exponential backoff retry
            const max_retries = request.max_retries orelse self.config.default_max_retries;
            var retry_count: u32 = 0;

            while (retry_count <= max_retries) : (retry_count += 1) {
                if (stream_mode) {
                    // Streaming path — body pipes directly to {output_dir}/{id}.{ext}.
                    // No buffered slice ever exists. Safe for 50 MB+ responses × 100 workers.
                    const streamed = self.executeStreamingRequest(&http_client, request);
                    if (streamed) |sr| {
                        response.status = @intFromEnum(sr.response.status);
                        response.body_path = sr.file_path; // transfers ownership
                        response.body_bytes = sr.response.bytes_written;
                        response.retry_count = retry_count;
                        break;
                    } else |err| {
                        if (retry_count < max_retries) {
                            const backoff_ms = @as(u64, 100) * (@as(u64, 1) << @intCast(retry_count));
                            var ts: std.c.timespec = .{
                                .sec = @intCast(backoff_ms / 1000),
                                .nsec = @intCast((backoff_ms % 1000) * 1_000_000),
                            };
                            _ = std.c.nanosleep(&ts, null);
                            continue;
                        } else {
                            response.error_message = std.fmt.allocPrint(
                                self.allocator,
                                "{}",
                                .{err},
                            ) catch null;
                            response.retry_count = retry_count;
                            break;
                        }
                    }
                }

                var result = self.executeHttpRequest(&http_client, request);

                if (result) |*http_response| {
                    defer http_response.deinit();

                    response.status = @intFromEnum(http_response.status);
                    response.body = self.allocator.dupe(u8, http_response.body) catch null;
                    response.retry_count = retry_count;
                    break;
                } else |err| {
                    if (retry_count < max_retries) {
                        // Calculate exponential backoff: 100ms * 2^attempt
                        // Use std.c.nanosleep — cross-platform via libc (works on Linux + macOS).
                        // Previously used linux.nanosleep which SIGSYS'd on macOS because
                        // Linux syscall numbers don't map to Darwin/Mach kernel.
                        const backoff_ms = @as(u64, 100) * (@as(u64, 1) << @intCast(retry_count));
                        var ts: std.c.timespec = .{
                            .sec = @intCast(backoff_ms / 1000),
                            .nsec = @intCast((backoff_ms % 1000) * 1_000_000),
                        };
                        _ = std.c.nanosleep(&ts, null);
                        continue;
                    } else {
                        // Final failure - record error
                        response.error_message = std.fmt.allocPrint(
                            self.allocator,
                            "{}",
                            .{err},
                        ) catch null;
                        response.retry_count = retry_count;
                        break;
                    }
                }
            }

            const end_time_ns = getMonotonicNs();
            const elapsed_ns: u64 = @intCast(end_time_ns - start_time_ns);
            response.latency_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

            self.writeResponse(&response);

            // Log to failure replay file if this request failed.
            // Failure criteria:
            //   - status == 0 (transport error: DNS, TCP, TLS, timeout)
            //   - status >= 400 (HTTP error response)
            if (self.fail_logger) |fl| {
                const failed = response.status == 0 or response.status >= 400;
                if (failed) {
                    const err_msg = response.error_message orelse "http_error";
                    fl.logFailure(
                        request.raw_line,
                        request.id,
                        request.source_line,
                        response.status,
                        response.retry_count,
                        err_msg,
                    );
                }
            }

            response.deinit();
        }

        /// Result of a streaming request — the caller owns `file_path` and
        /// must free it via the engine allocator. `response` carries the
        /// status code and on-disk byte count.
        const StreamResult = struct {
            response: HttpClient.StreamedResponse,
            file_path: []u8,
        };

        /// Execute HTTP request in streaming mode — body pipes directly from
        /// the TLS socket into {output_dir}/{id}.{ext} via File.Writer. Zero
        /// intermediate buffering: a Cloud Run container with 100 concurrent
        /// workers can handle 50 MB+ responses without blowing RAM.
        fn executeStreamingRequest(
            self: *Self,
            http_client: *HttpClient,
            request: *manifest.RequestManifest,
        ) !StreamResult {
            const dir = self.config.output_dir.?; // caller checks shouldStream() first

            // Ensure directory exists (best-effort; mkdir failures are ignored
            // because concurrent workers may race on the same dir and
            // createFile below will surface any real error).
            var dir_z: [4096:0]u8 = undefined;
            if (dir.len >= 4096) return error.PathTooLong;
            @memcpy(dir_z[0..dir.len], dir);
            dir_z[dir.len] = 0;
            _ = std.c.mkdir(&dir_z, 0o755);

            // Build the output path — caller receives ownership of this slice.
            const file_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}.{s}",
                .{ dir, request.id, self.config.output_ext },
            );
            errdefer self.allocator.free(file_path);

            // Each worker has its own HttpClient which owns its own Io handle.
            // Use that same Io for file ops so we stay on a single event loop.
            const io_handle = http_client.io();

            const file = try std.Io.Dir.cwd().createFile(io_handle, file_path, .{});
            defer file.close(io_handle);

            // 64 KB buffer is the sweet spot for the TLS record size × typical
            // filesystem page alignment. Larger wastes stack; smaller thrashes.
            var write_buf: [65536]u8 = undefined;
            var file_writer = file.writer(io_handle, &write_buf);

            // Build headers (honors the auth refresher if one is attached)
            var built = try self.buildHeaders(request);
            defer built.deinit();
            const headers = built.list.items;

            const timeout_ms = request.timeout_ms orelse self.config.default_timeout_ms;
            const opts = HttpClient.RequestOptions{
                .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
            };

            const streamed = switch (request.method) {
                .GET => try http_client.getStreamToWriter(
                    request.url,
                    headers,
                    &file_writer.interface,
                    opts,
                ),
                .POST => try http_client.postStreamToWriter(
                    request.url,
                    headers,
                    request.body orelse "",
                    &file_writer.interface,
                    opts,
                ),
                .PUT => try http_client.putStreamToWriter(
                    request.url,
                    headers,
                    request.body orelse "",
                    &file_writer.interface,
                    opts,
                ),
                .PATCH => try http_client.patchStreamToWriter(
                    request.url,
                    headers,
                    request.body orelse "",
                    &file_writer.interface,
                    opts,
                ),
                .DELETE => try http_client.deleteStreamToWriter(
                    request.url,
                    headers,
                    &file_writer.interface,
                    opts,
                ),
                .HEAD, .OPTIONS => return error.MethodNotSupported,
            };

            // Flush any buffered bytes to disk before the file closes.
            // Without this, the tail of large bodies can be lost in the 64 KB
            // write_buf when the worker returns.
            try file_writer.interface.flush();

            return StreamResult{
                .response = streamed,
                .file_path = file_path,
            };
        }

        /// Execute HTTP request based on method
        fn executeHttpRequest(self: *Self, http_client: *HttpClient, request: *manifest.RequestManifest) !HttpClient.Response {
            // Build headers (honors the auth refresher if one is attached)
            var built = try self.buildHeaders(request);
            defer built.deinit();
            const headers = built.list.items;

            // Resolve timeout: per-request override > engine default
            const timeout_ms = request.timeout_ms orelse self.config.default_timeout_ms;
            const opts = HttpClient.RequestOptions{
                .timeout_ns = if (timeout_ms > 0) timeout_ms * 1_000_000 else 0,
            };

            // Execute based on method — use WithOptions variants for timeout support
            return switch (request.method) {
                .GET => try http_client.getWithOptions(request.url, headers, opts),
                .POST, .PUT, .PATCH => blk: {
                    const body = request.body orelse "";
                    if (request.method == .POST) {
                        break :blk try http_client.postWithOptions(request.url, headers, body, opts);
                    } else if (request.method == .PUT) {
                        break :blk try http_client.putWithOptions(request.url, headers, body, opts);
                    } else {
                        break :blk try http_client.patchWithOptions(request.url, headers, body, opts);
                    }
                },
                .DELETE => try http_client.deleteWithOptions(request.url, headers, opts),
                .HEAD, .OPTIONS => error.MethodNotSupported,
            };
        }

        /// Write response to output (thread-safe via mutex)
        fn writeResponse(self: *Self, response: *manifest.ResponseManifest) void {
            self.output_mutex.lock();
            defer self.output_mutex.unlock();

            response.toJson(&self.output_writer.interface) catch |err| {
                std.debug.print("Error writing response: {}\n", .{err});
            };

            // Flush immediately for real-time streaming
            std.Io.Writer.flush(&self.output_writer.interface) catch {};

            // Save response body to file — only on the buffered path. In
            // streaming mode the body was already piped straight to disk by
            // executeStreamingRequest, and response.body is null here.
            if (!self.shouldStream()) {
                if (self.config.output_dir) |dir| {
                    if (response.body) |body| {
                        self.saveBodyToFile(dir, response.id, body);
                    }
                }
            }
        }

        /// Save response body to {output_dir}/{id}.{ext}
        /// If base64_field is set, extracts the specified JSON path, decodes base64, writes binary.
        /// Otherwise writes the raw body text.
        fn saveBodyToFile(self: *Self, dir: []const u8, id: []const u8, body: []const u8) void {
            // Ensure directory exists
            var dir_z: [4096:0]u8 = undefined;
            if (dir.len >= 4096) return;
            @memcpy(dir_z[0..dir.len], dir);
            dir_z[dir.len] = 0;
            _ = std.c.mkdir(&dir_z, 0o755);

            // Build path: {dir}/{id}.{ext}
            var path_buf: [4096:0]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.{s}", .{ dir, id, self.config.output_ext }) catch return;

            if (self.config.base64_field) |field_path| {
                // Extract + decode base64 from JSON response
                self.saveBase64Field(path, body, field_path);
            } else {
                // Write raw body text
                const file = std.c.fopen(path.ptr, "w") orelse {
                    std.debug.print("Error: cannot write {s}\n", .{path});
                    return;
                };
                defer _ = std.c.fclose(file);
                _ = std.c.fwrite(body.ptr, 1, body.len, file);
            }
        }

        /// Extract a base64 field from JSON body using dot-path, decode, and write binary.
        /// Path format: "predictions.0.bytesBase64Encoded" (dots separate keys/indices)
        fn saveBase64Field(self: *Self, path: [:0]const u8, body: []const u8, field_path: []const u8) void {
            // Parse the JSON response
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
                std.debug.print("[save] Error: cannot parse JSON for base64 extraction\n", .{});
                return;
            };
            defer parsed.deinit();

            // Walk the dot-path to find the target field
            const b64_value = walkJsonPath(parsed.value, field_path) orelse {
                std.debug.print("[save] Error: field '{s}' not found in response\n", .{field_path});
                return;
            };

            if (b64_value != .string) {
                std.debug.print("[save] Error: field '{s}' is not a string\n", .{field_path});
                return;
            }

            const b64_str = b64_value.string;

            // Decode base64
            const decoded = decodeBase64(self.allocator, b64_str) orelse {
                std.debug.print("[save] Error: base64 decode failed ({} chars)\n", .{b64_str.len});
                return;
            };
            defer self.allocator.free(decoded);

            // Write binary
            const file = std.c.fopen(path.ptr, "wb") orelse {
                std.debug.print("Error: cannot write {s}\n", .{path});
                return;
            };
            defer _ = std.c.fclose(file);
            _ = std.c.fwrite(decoded.ptr, 1, decoded.len, file);
        }

        /// Write error to output (thread-safe via mutex)
        fn writeError(self: *Self, id: []const u8, error_message: []const u8) void {
            self.output_mutex.lock();
            defer self.output_mutex.unlock();

            std.Io.Writer.print(
                &self.output_writer.interface,
                "{{\"id\":\"{s}\",\"status\":0,\"error\":\"{s}\"}}\n",
                .{ id, error_message },
            ) catch {};
        }
    };
}

// ── JSON path walker ─────────────────────────────────────────────────────────

/// Walk a dot-separated path through a JSON value.
/// "predictions.0.bytesBase64Encoded" → value["predictions"][0]["bytesBase64Encoded"]
fn walkJsonPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var current = root;
    var iter = std.mem.splitScalar(u8, path, '.');

    while (iter.next()) |segment| {
        if (segment.len == 0) continue;

        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse return null;
            },
            .array => |arr| {
                const idx = std.fmt.parseInt(usize, segment, 10) catch return null;
                if (idx >= arr.items.len) return null;
                current = arr.items[idx];
            },
            else => return null,
        }
    }

    return current;
}

// ── Base64 decoder ───────────────────────────────────────────────────────────

/// Decode a base64 string (standard or URL-safe) into raw bytes.
/// Returns allocated slice or null on error.
fn decodeBase64(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    if (input.len == 0) return null;

    // Strip whitespace and padding for length calculation
    var clean_len: usize = 0;
    for (input) |c| {
        if (c != '=' and c != '\n' and c != '\r' and c != ' ') clean_len += 1;
    }

    // Output size: 3 bytes per 4 base64 chars
    const out_size = (clean_len * 3) / 4 + 4;
    const output = allocator.alloc(u8, out_size) catch return null;

    var out_pos: usize = 0;
    var buf: [4]u8 = undefined;
    var buf_len: usize = 0;

    for (input) |c| {
        const val = b64Decode(c);
        if (val == 0xFF) continue; // Skip whitespace, padding, invalid

        buf[buf_len] = val;
        buf_len += 1;

        if (buf_len == 4) {
            if (out_pos + 3 > output.len) break;
            output[out_pos] = (buf[0] << 2) | (buf[1] >> 4);
            output[out_pos + 1] = (buf[1] << 4) | (buf[2] >> 2);
            output[out_pos + 2] = (buf[2] << 6) | buf[3];
            out_pos += 3;
            buf_len = 0;
        }
    }

    // Handle remaining bytes
    if (buf_len >= 2) {
        if (out_pos < output.len) {
            output[out_pos] = (buf[0] << 2) | (buf[1] >> 4);
            out_pos += 1;
        }
    }
    if (buf_len >= 3) {
        if (out_pos < output.len) {
            output[out_pos] = (buf[1] << 4) | (buf[2] >> 2);
            out_pos += 1;
        }
    }

    // Resize to actual length
    if (out_pos == 0) {
        allocator.free(output);
        return null;
    }

    return output[0..out_pos];
}

fn b64Decode(c: u8) u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+', '-' => 62, // '+' standard, '-' URL-safe
        '/', '_' => 63, // '/' standard, '_' URL-safe
        else => 0xFF, // Invalid / skip
    };
}
