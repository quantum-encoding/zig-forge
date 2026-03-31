// Sequential image batch executor
// Processes CSV rows one at a time with configurable delay and retry
// Designed for rate-limited API usage (50+ images without hitting limits)

const std = @import("std");
const types = @import("types.zig");
const media_types = @import("../types.zig");
const providers = @import("../providers/mod.zig");
const templates = @import("../templates.zig");
const storage = @import("../storage.zig");
const Timer = @import("../../timer.zig").Timer;

const ImageProvider = media_types.ImageProvider;
const ImageRequest = media_types.ImageRequest;
const ImageResponse = media_types.ImageResponse;
const MediaConfig = media_types.MediaConfig;

pub const ImageBatchExecutor = struct {
    allocator: std.mem.Allocator,
    config: types.ImageBatchConfig,
    media_config: MediaConfig,
    results: std.ArrayList(types.ImageBatchResult),
    completed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    total_bytes: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        config: types.ImageBatchConfig,
        media_config: MediaConfig,
    ) ImageBatchExecutor {
        return .{
            .allocator = allocator,
            .config = config,
            .media_config = media_config,
            .results = std.ArrayList(types.ImageBatchResult).empty,
        };
    }

    pub fn deinit(self: *ImageBatchExecutor) void {
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(self.allocator);
    }

    /// Execute all requests sequentially with delay between each
    pub fn execute(self: *ImageBatchExecutor, requests: []types.ImageBatchRequest) !void {
        var batch_timer = try Timer.start();

        for (requests, 0..) |*request, idx| {
            const row_num = idx + 1;

            // Skip rows before start_from
            if (row_num < self.config.start_from) {
                var result = types.ImageBatchResult{
                    .id = request.id,
                    .prompt = try self.allocator.dupe(u8, request.prompt),
                    .status = .skipped,
                    .image_paths = try self.allocator.alloc([]const u8, 0),
                    .allocator = self.allocator,
                };
                try self.results.append(self.allocator, result);
                self.skipped += 1;
                _ = &result;
                continue;
            }

            // Delay between requests (not before the first one)
            if (row_num > self.config.start_from and self.config.delay_ms > 0) {
                sleepMs(self.config.delay_ms);
            }

            // Print progress
            const prompt_preview = truncatePrompt(request.prompt, 60);
            std.debug.print("[{}/{}] Generating \"{s}\"...\n", .{ row_num, requests.len, prompt_preview });

            // Execute with retry
            const result = self.executeWithRetry(request);
            if (result.status == .success) {
                self.completed += 1;
                self.total_bytes += result.file_size_bytes;
                const size = storage.formatSize(result.file_size_bytes);
                if (result.image_paths.len > 0) {
                    std.debug.print("[{}/{}] Saved: {s} ({d:.1} {s}, {d}ms)\n", .{
                        row_num, requests.len,
                        result.image_paths[0],
                        size.value, size.unit,
                        result.execution_time_ms,
                    });
                }
            } else {
                self.failed += 1;
                const err_msg = result.error_message orelse "unknown error";
                std.debug.print("[{}/{}] FAILED: {s}\n", .{ row_num, requests.len, err_msg });
            }

            try self.results.append(self.allocator, result);
        }

        // Print summary
        const elapsed_ns = batch_timer.read();
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
        const total_size = storage.formatSize(self.total_bytes);

        std.debug.print("\nBatch complete!\n", .{});
        if (elapsed_s >= 60.0) {
            const minutes = @as(u32, @intFromFloat(elapsed_s / 60.0));
            const seconds = @as(u32, @intFromFloat(@mod(elapsed_s, 60.0)));
            std.debug.print("  Total time: {}m {}s\n", .{ minutes, seconds });
        } else {
            std.debug.print("  Total time: {d:.1}s\n", .{elapsed_s});
        }
        std.debug.print("  Success: {}/{}\n", .{ self.completed, requests.len });
        if (self.failed > 0) {
            std.debug.print("  Failed: {}/{}\n", .{ self.failed, requests.len });
        }
        if (self.skipped > 0) {
            std.debug.print("  Skipped: {}\n", .{self.skipped});
        }
        std.debug.print("  Total size: {d:.1} {s}\n", .{ total_size.value, total_size.unit });
    }

    /// Execute a single request with retry logic
    fn executeWithRetry(self: *ImageBatchExecutor, request: *const types.ImageBatchRequest) types.ImageBatchResult {
        var last_error: ?[]const u8 = null;
        const max_attempts = self.config.retry_count + 1;

        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            if (attempt > 0) {
                // Exponential backoff: 1s, 2s, 4s...
                const backoff_ms = @as(u64, 1000) * (@as(u64, 1) << @intCast(attempt - 1));
                std.debug.print("  Retrying in {}ms (attempt {}/{})...\n", .{
                    backoff_ms, attempt + 1, max_attempts,
                });
                sleepMs(backoff_ms);
                if (last_error) |e| self.allocator.free(e);
                last_error = null;
            }

            var result = self.executeOne(request);
            if (result.status == .success) {
                if (last_error) |e| self.allocator.free(e);
                return result;
            }

            // Save error message for potential next retry
            if (result.error_message) |e| {
                last_error = self.allocator.dupe(u8, e) catch null;
            }
            result.deinit();
        }

        // All retries exhausted
        return .{
            .id = request.id,
            .prompt = self.allocator.dupe(u8, request.prompt) catch "",
            .provider = request.provider orelse self.config.default_provider,
            .status = .failed,
            .image_paths = self.allocator.alloc([]const u8, 0) catch &.{},
            .error_message = last_error,
            .allocator = self.allocator,
        };
    }

    /// Execute a single request (no retry)
    fn executeOne(self: *ImageBatchExecutor, request: *const types.ImageBatchRequest) types.ImageBatchResult {
        var timer = Timer.start() catch {
            return makeError(self, request, "Timer init failed");
        };

        // Resolve provider: row value -> CLI default -> error
        const provider = request.provider orelse self.config.default_provider orelse {
            return makeError(self, request, "No provider specified (use --provider flag or add 'provider' column)");
        };

        // Check API key
        if (!self.media_config.hasProvider(provider)) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "{s} not set",
                .{provider.getEnvVar()},
            ) catch return makeError(self, request, "API key missing");
            return .{
                .id = request.id,
                .prompt = self.allocator.dupe(u8, request.prompt) catch "",
                .provider = provider,
                .status = .failed,
                .image_paths = self.allocator.alloc([]const u8, 0) catch &.{},
                .error_message = msg,
                .allocator = self.allocator,
            };
        }

        // Apply template if specified
        const template_name = request.template orelse self.config.default_template;
        var final_prompt: []const u8 = request.prompt;
        var templated_alloc: ?[]u8 = null;

        if (template_name) |tname| {
            if (templates.findTemplate(tname)) |tmpl| {
                templated_alloc = templates.buildTemplatedPrompt(self.allocator, tmpl, request.prompt) catch null;
                if (templated_alloc) |tp| final_prompt = tp;
            }
        }
        defer if (templated_alloc) |tp| self.allocator.free(tp);

        // Build the output path if filename is specified
        var output_path_alloc: ?[]u8 = null;
        if (request.filename) |fname| {
            output_path_alloc = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                self.config.output_dir, fname,
            }) catch null;
        }
        defer if (output_path_alloc) |p| self.allocator.free(p);

        // Build ImageRequest
        const image_request = ImageRequest{
            .prompt = final_prompt,
            .provider = provider,
            .count = if (request.count > 0) request.count else self.config.default_count,
            .size = request.size orelse self.config.default_size,
            .quality = request.quality orelse self.config.default_quality,
            .style = request.style orelse self.config.default_style,
            .aspect_ratio = request.aspect_ratio orelse self.config.default_aspect_ratio,
            .output_path = output_path_alloc,
            .background = request.background orelse self.config.default_background,
        };

        // Generate image
        var response = providers.generateImage(self.allocator, image_request, self.media_config) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "{any}", .{err}) catch null;
            return .{
                .id = request.id,
                .prompt = self.allocator.dupe(u8, request.prompt) catch "",
                .provider = provider,
                .status = .failed,
                .image_paths = self.allocator.alloc([]const u8, 0) catch &.{},
                .error_message = msg,
                .allocator = self.allocator,
            };
        };
        defer response.deinit();

        // Collect paths and total size
        var paths = self.allocator.alloc([]const u8, response.images.len) catch {
            return makeError(self, request, "Failed to allocate paths");
        };
        var total_size: usize = 0;
        for (response.images, 0..) |img, i| {
            paths[i] = self.allocator.dupe(u8, img.local_path) catch "";
            total_size += img.data.len;
        }

        const elapsed_ns = timer.read();

        return .{
            .id = request.id,
            .prompt = self.allocator.dupe(u8, request.prompt) catch "",
            .provider = provider,
            .status = .success,
            .image_paths = paths,
            .execution_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
            .file_size_bytes = total_size,
            .allocator = self.allocator,
        };
    }

    /// Helper to create a failed result with an error message
    fn makeError(self: *ImageBatchExecutor, request: *const types.ImageBatchRequest, msg: []const u8) types.ImageBatchResult {
        return .{
            .id = request.id,
            .prompt = self.allocator.dupe(u8, request.prompt) catch "",
            .provider = request.provider orelse self.config.default_provider,
            .status = .failed,
            .image_paths = self.allocator.alloc([]const u8, 0) catch &.{},
            .error_message = self.allocator.dupe(u8, msg) catch null,
            .allocator = self.allocator,
        };
    }

    pub fn getResults(self: *ImageBatchExecutor) []types.ImageBatchResult {
        return self.results.items;
    }
};

/// Sleep for the specified number of milliseconds using C nanosleep
fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Truncate prompt for display (avoid flooding the terminal)
fn truncatePrompt(prompt: []const u8, max_len: usize) []const u8 {
    if (prompt.len <= max_len) return prompt;
    return prompt[0..max_len];
}
