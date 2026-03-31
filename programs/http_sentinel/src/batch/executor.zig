// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Batch executor - Concurrent request processing with thread pool

const std = @import("std");
const types = @import("types.zig");
const cli = @import("../cli.zig");
const ai_common = @import("../ai/common.zig");
const anthropic = @import("../ai/anthropic.zig");
const deepseek = @import("../ai/deepseek.zig");
const gemini = @import("../ai/gemini.zig");
const grok = @import("../ai/grok.zig");
const vertex = @import("../ai/vertex.zig");

/// Simple mutex wrapper using pthread (Mutex removed in Zig 0.16)
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// Timer using clock_gettime (Timer removed in Zig 0.16)
const Timer = struct {
    start_ts: std.c.timespec,

    pub fn start() error{}!Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{ .start_ts = ts };
    }

    pub fn read(self: *const Timer) u64 {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const start_ns: i128 = @as(i128, self.start_ts.sec) * 1_000_000_000 + self.start_ts.nsec;
        const now_ns: i128 = @as(i128, now.sec) * 1_000_000_000 + now.nsec;
        const diff = now_ns - start_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

/// Thread-safe batch executor using worker threads
pub const BatchExecutor = struct {
    allocator: std.mem.Allocator,
    requests: []types.BatchRequest,
    results: std.ArrayListUnmanaged(types.BatchResult),
    results_mutex: Mutex,
    work_queue_mutex: Mutex,
    work_queue_index: usize,
    completed: std.atomic.Value(u32),
    failed: std.atomic.Value(u32),
    config: types.BatchConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        requests: []types.BatchRequest,
        config: types.BatchConfig,
    ) !BatchExecutor {
        return .{
            .allocator = allocator,
            .requests = requests,
            .results = std.ArrayListUnmanaged(types.BatchResult).empty,
            .results_mutex = .{},
            .work_queue_mutex = .{},
            .work_queue_index = 0,
            .completed = std.atomic.Value(u32).init(0),
            .failed = std.atomic.Value(u32).init(0),
            .config = config,
        };
    }

    pub fn deinit(self: *BatchExecutor) void {
        for (self.results.items) |*result| {
            result.deinit();
        }
        self.results.deinit(self.allocator);
    }

    /// Get next work item from queue (thread-safe)
    fn getNextWorkItem(self: *BatchExecutor) ?*types.BatchRequest {
        self.work_queue_mutex.lock();
        defer self.work_queue_mutex.unlock();

        if (self.work_queue_index >= self.requests.len) {
            return null;
        }

        const item = &self.requests[self.work_queue_index];
        self.work_queue_index += 1;
        return item;
    }

    /// Worker thread entry point
    fn workerThread(self: *BatchExecutor) void {
        while (self.getNextWorkItem()) |request| {
            self.executeRequest(request);
        }
    }

    /// Execute all requests using thread pool
    pub fn execute(self: *BatchExecutor) !void {
        var timer = try Timer.start();

        // Determine concurrency level (cap at request count and concurrency limit)
        const thread_count = @min(self.requests.len, self.config.concurrency);

        if (self.config.show_progress) {
            std.debug.print("\n🔄 Starting batch processing...\n", .{});
            std.debug.print("   Requests: {}\n", .{self.requests.len});
            std.debug.print("   Concurrency: {}\n", .{thread_count});
            std.debug.print("   Retry count: {}\n\n", .{self.config.retry_count});
        }

        // Create worker threads
        var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
        defer threads.deinit(self.allocator);

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const thread = std.Thread.spawn(.{}, workerThread, .{self}) catch |err| {
                std.debug.print("Failed to spawn thread {}: {}\n", .{ i, err });
                continue;
            };
            threads.append(self.allocator, thread) catch |err| {
                std.debug.print("Failed to track thread {}: {}\n", .{ i, err });
                continue;
            };
        }

        // Wait for all threads to complete
        for (threads.items) |thread| {
            thread.join();
        }

        const elapsed_ns = timer.read();
        const duration_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

        if (self.config.show_progress) {
            std.debug.print("\n[INFO] Processed {}/{} requests (success: {} failed: {})...Done!\n\n", .{
                self.requests.len,
                self.requests.len,
                self.completed.load(.acquire),
                self.failed.load(.acquire),
            });
            std.debug.print("Batch complete!\n", .{});
            std.debug.print("   Total time: {d:.2}s\n", .{duration_s});
            std.debug.print("   Success: {}\n", .{self.completed.load(.acquire)});
            std.debug.print("   Failed: {}\n\n", .{self.failed.load(.acquire)});
        }
    }

    /// Execute a single request (called by worker thread)
    fn executeRequest(self: *BatchExecutor, request: *const types.BatchRequest) void {
        var timer = Timer.start() catch unreachable;

        var result = types.BatchResult{
            .id = request.id,
            .provider = request.provider,
            .prompt = undefined,
            .response = null,
            .input_tokens = 0,
            .output_tokens = 0,
            .cost = 0.0,
            .execution_time_ms = 0,
            .error_message = null,
            .allocator = self.allocator,
        };

        // Duplicate prompt for result
        result.prompt = self.allocator.dupe(u8, request.prompt) catch |err| {
            result.prompt = self.allocator.dupe(u8, "[error copying prompt]") catch unreachable;
            result.error_message = std.fmt.allocPrint(
                self.allocator,
                "Failed to allocate prompt: {any}",
                .{err},
            ) catch null;
            self.storeResult(result);
            _ = self.failed.fetchAdd(1, .release);
            return;
        };

        // Execute with retries
        var attempts: u32 = 0;
        const max_attempts = self.config.retry_count + 1;

        while (attempts < max_attempts) : (attempts += 1) {
            if (attempts > 0) {
                // Exponential backoff using std.Thread.sleep
                const delay_ms = @as(u64, 1000) * (@as(u64, 1) << @intCast(attempts - 1));
                const delay_ns = delay_ms * std.time.ns_per_ms;
                // Cross-platform nanosleep via libc
                const ts: std.c.timespec = .{
                    .sec = @intCast(delay_ns / std.time.ns_per_s),
                    .nsec = @intCast(delay_ns % std.time.ns_per_s),
                };
                _ = std.c.nanosleep(&ts, null);
            }

            // Execute the request
            const execute_result = self.executeWithProvider(request);

            if (execute_result) |ai_response| {
                var response = ai_response;
                defer response.deinit();

                // Success - populate result
                result.response = self.allocator.dupe(u8, response.message.content) catch |err| {
                    result.error_message = std.fmt.allocPrint(
                        self.allocator,
                        "Failed to copy response: {any}",
                        .{err},
                    ) catch null;
                    break;
                };
                result.input_tokens = response.usage.input_tokens;
                result.output_tokens = response.usage.output_tokens;
                result.cost = request.provider.calculateCost(
                    response.metadata.model,
                    response.usage.input_tokens,
                    response.usage.output_tokens,
                );

                const elapsed_ns = timer.read();
                result.execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

                self.storeResult(result);
                _ = self.completed.fetchAdd(1, .release);
                return;
            } else |err| {
                // Determine if we should retry
                const should_retry = switch (err) {
                    ai_common.AIError.RateLimitExceeded,
                    ai_common.AIError.ApiRequestFailed,
                    => true,
                    else => false,
                };

                if (!should_retry or attempts == max_attempts - 1) {
                    // Final failure - store error
                    result.error_message = std.fmt.allocPrint(
                        self.allocator,
                        "{any}",
                        .{err},
                    ) catch null;

                    const elapsed_ns = timer.read();
                    result.execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms);

                    self.storeResult(result);
                    _ = self.failed.fetchAdd(1, .release);
                    return;
                }

                // Continue to retry
            }
        }
    }

    /// Get environment variable as owned slice (compatible with Zig 0.16)
    fn getEnvVar(allocator: std.mem.Allocator, key: [:0]const u8) ?[]const u8 {
        const ptr = std.c.getenv(key) orelse return null;
        const len = std.mem.len(ptr);
        return allocator.dupe(u8, ptr[0..len]) catch null;
    }

    /// Execute request with appropriate provider
    fn executeWithProvider(
        self: *BatchExecutor,
        request: *const types.BatchRequest,
    ) !ai_common.AIResponse {

        // Build request config
        const req_config = ai_common.RequestConfig{
            .model = request.provider.getDefaultModel(),
            .temperature = request.temperature,
            .max_tokens = request.max_tokens,
            .system_prompt = request.system_prompt,
            .max_turns = 1, // Single turn for batch processing
        };

        // Execute based on provider
        return switch (request.provider) {
            .claude => blk: {
                const api_key = getEnvVar(self.allocator, "ANTHROPIC_API_KEY") orelse
                    return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try anthropic.AnthropicClient.init(
                    self.allocator,
                    .{ .api_key = api_key },
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .deepseek => blk: {
                const api_key = getEnvVar(self.allocator, "DEEPSEEK_API_KEY") orelse
                    return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try deepseek.DeepSeekClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .gemini => blk: {
                const api_key = getEnvVar(self.allocator, "GEMINI_API_KEY") orelse getEnvVar(self.allocator, "GOOGLE_GENAI_API_KEY") orelse
                    return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try gemini.GeminiClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .grok => blk: {
                const api_key = getEnvVar(self.allocator, "XAI_API_KEY") orelse
                    return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(api_key);

                var client = try grok.GrokClient.init(
                    self.allocator,
                    api_key,
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
            .vertex => blk: {
                const project_id = getEnvVar(self.allocator, "VERTEX_PROJECT_ID") orelse
                    return ai_common.AIError.AuthenticationFailed;
                defer self.allocator.free(project_id);

                var client = try vertex.VertexClient.init(
                    self.allocator,
                    .{ .project_id = project_id },
                );
                defer client.deinit();

                break :blk try client.sendMessage(request.prompt, req_config);
            },
        };
    }

    /// Thread-safe result storage
    fn storeResult(self: *BatchExecutor, result: types.BatchResult) void {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();

        self.results.append(self.allocator, result) catch |err| {
            std.debug.print("⚠️  Warning: Failed to store result {}: {}\n", .{ result.id, err });
        };
    }

    /// Get results sorted by ID
    pub fn getResults(self: *BatchExecutor) ![]types.BatchResult {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();

        // Sort by ID
        std.mem.sort(types.BatchResult, self.results.items, {}, struct {
            pub fn lessThan(_: void, a: types.BatchResult, b: types.BatchResult) bool {
                return a.id < b.id;
            }
        }.lessThan);

        return self.results.items;
    }
};
