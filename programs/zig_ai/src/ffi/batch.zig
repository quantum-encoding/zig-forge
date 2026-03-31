// FFI Batch Processing - C bindings for batch text AI processing

const std = @import("std");
const types = @import("types.zig");
const batch_types = @import("../batch/types.zig");
const batch_executor = @import("../batch/executor.zig");
const batch_parser = @import("../batch/csv_parser.zig");
const batch_writer = @import("../batch/writer.zig");
const cli = @import("../cli.zig");

const CString = types.CString;
const CTextProvider = types.CTextProvider;
const CBatchRequest = types.CBatchRequest;
const CBatchResult = types.CBatchResult;
const CBatchResults = types.CBatchResults;
const CBatchConfig = types.CBatchConfig;
const CBatchExecutor = types.CBatchExecutor;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Batch Executor
// ============================================================================

/// Create a batch executor from an array of requests
export fn zig_ai_batch_create(
    requests: [*]const CBatchRequest,
    count: usize,
    config: *const CBatchConfig,
) ?*CBatchExecutor {
    if (count == 0) return null;

    // Convert C requests to Zig requests
    var zig_requests = allocator.alloc(batch_types.BatchRequest, count) catch return null;
    errdefer allocator.free(zig_requests);

    for (requests[0..count], 0..) |req, i| {
        zig_requests[i] = .{
            .id = req.id,
            .provider = mapProvider(req.provider),
            .prompt = allocator.dupe(u8, req.prompt.toSlice()) catch return null,
            .temperature = req.temperature,
            .max_tokens = req.max_tokens,
            .system_prompt = if (req.system_prompt.len > 0)
                allocator.dupe(u8, req.system_prompt.toSlice()) catch null
            else
                null,
        };
    }

    const zig_config = batch_types.BatchConfig{
        .input_file = "",
        .output_file = "",
        .concurrency = config.concurrency,
        .full_responses = true,
        .continue_on_error = config.continue_on_error,
        .retry_count = config.retry_count,
        .timeout_ms = config.timeout_ms,
        .show_progress = false,
    };

    const executor = batch_executor.BatchExecutor.init(allocator, zig_requests, zig_config) catch return null;

    const wrapper = allocator.create(ExecutorWrapper) catch return null;
    wrapper.* = .{
        .executor = executor,
        .requests = zig_requests,
    };

    return @ptrCast(wrapper);
}

/// Create a batch executor from a CSV file
export fn zig_ai_batch_create_from_csv(
    csv_path: CString,
    config: *const CBatchConfig,
) ?*CBatchExecutor {
    const path = csv_path.toSlice();
    if (path.len == 0) return null;

    const requests = batch_parser.parseFile(allocator, path) catch return null;

    const zig_config = batch_types.BatchConfig{
        .input_file = path,
        .output_file = "",
        .concurrency = config.concurrency,
        .full_responses = true,
        .continue_on_error = config.continue_on_error,
        .retry_count = config.retry_count,
        .timeout_ms = config.timeout_ms,
        .show_progress = false,
    };

    const executor = batch_executor.BatchExecutor.init(allocator, requests, zig_config) catch return null;

    const wrapper = allocator.create(ExecutorWrapper) catch return null;
    wrapper.* = .{
        .executor = executor,
        .requests = requests,
    };

    return @ptrCast(wrapper);
}

/// Destroy a batch executor
export fn zig_ai_batch_destroy(executor: ?*CBatchExecutor) void {
    if (executor == null) return;
    const wrapper: *ExecutorWrapper = @ptrCast(@alignCast(executor));

    wrapper.executor.deinit();

    // Free request data
    for (wrapper.requests) |*req| {
        allocator.free(req.prompt);
        if (req.system_prompt) |sp| allocator.free(sp);
    }
    allocator.free(wrapper.requests);

    // Free results if any
    if (wrapper.results) |results| {
        for (results) |*r| {
            if (r.response) |resp| allocator.free(resp);
            if (r.error_message) |err| allocator.free(err);
        }
        allocator.free(results);
    }

    allocator.destroy(wrapper);
}

/// Execute the batch
export fn zig_ai_batch_execute(executor: ?*CBatchExecutor) i32 {
    if (executor == null) return ErrorCode.INVALID_ARGUMENT;
    const wrapper: *ExecutorWrapper = @ptrCast(@alignCast(executor));

    wrapper.executor.execute() catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Get results after execution
export fn zig_ai_batch_get_results(
    executor: ?*CBatchExecutor,
    results_out: *CBatchResults,
) i32 {
    results_out.* = std.mem.zeroes(CBatchResults);

    if (executor == null) return ErrorCode.INVALID_ARGUMENT;
    const wrapper: *ExecutorWrapper = @ptrCast(@alignCast(executor));

    const zig_results = wrapper.executor.getResults() catch |err| {
        return mapError(err);
    };

    // Store internally for cleanup
    wrapper.results = zig_results;

    if (zig_results.len == 0) {
        return ErrorCode.SUCCESS;
    }

    // Convert to C results
    const c_results = allocator.alloc(CBatchResult, zig_results.len) catch {
        return ErrorCode.OUT_OF_MEMORY;
    };

    var total_cost: f64 = 0;
    var total_time: u64 = 0;

    for (zig_results, 0..) |res, i| {
        c_results[i] = .{
            .id = res.id,
            .provider = mapProviderToC(res.provider),
            .prompt = CString.fromSlice(res.prompt),
            .response = if (res.response) |r|
                CString.fromSlice(allocator.dupe(u8, r) catch "")
            else
                .{ .ptr = null, .len = 0 },
            .input_tokens = res.input_tokens,
            .output_tokens = res.output_tokens,
            .cost_usd = res.cost,
            .execution_time_ms = res.execution_time_ms,
            .error_message = if (res.error_message) |e|
                CString.fromSlice(allocator.dupe(u8, e) catch "")
            else
                .{ .ptr = null, .len = 0 },
            .success = res.error_message == null,
        };

        total_cost += res.cost;
        total_time += res.execution_time_ms;
    }

    results_out.* = .{
        .items = c_results.ptr,
        .count = c_results.len,
        .total_cost_usd = total_cost,
        .total_time_ms = total_time,
    };

    return ErrorCode.SUCCESS;
}

/// Write results to a CSV file
export fn zig_ai_batch_write_results(
    results: *const CBatchResults,
    output_path: CString,
    full_responses: bool,
) i32 {
    const path = output_path.toSlice();
    if (path.len == 0 or results.items == null) {
        return ErrorCode.INVALID_ARGUMENT;
    }

    // Convert C results to Zig results
    const items = results.items.?[0..results.count];
    var zig_results = allocator.alloc(batch_types.BatchResult, items.len) catch {
        return ErrorCode.OUT_OF_MEMORY;
    };
    defer allocator.free(zig_results);

    for (items, 0..) |r, i| {
        zig_results[i] = .{
            .id = r.id,
            .provider = mapProvider(r.provider),
            .prompt = r.prompt.toSlice(),
            .response = if (r.response.ptr != null) r.response.toSlice() else null,
            .input_tokens = r.input_tokens,
            .output_tokens = r.output_tokens,
            .cost = r.cost_usd,
            .execution_time_ms = r.execution_time_ms,
            .error_message = if (r.error_message.ptr != null) r.error_message.toSlice() else null,
        };
    }

    batch_writer.writeResults(allocator, zig_results, path, full_responses) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free batch results
export fn zig_ai_batch_results_free(results: *CBatchResults) void {
    if (results.items) |items| {
        for (items[0..results.count]) |*r| {
            if (r.response.ptr) |p| {
                allocator.free(p[0 .. r.response.len + 1]);
            }
            if (r.error_message.ptr) |p| {
                allocator.free(p[0 .. r.error_message.len + 1]);
            }
        }
        allocator.free(items[0..results.count]);
    }
    results.* = std.mem.zeroes(CBatchResults);
}

// ============================================================================
// Internal Types and Helpers
// ============================================================================

const ExecutorWrapper = struct {
    executor: batch_executor.BatchExecutor,
    requests: []batch_types.BatchRequest,
    results: ?[]batch_types.BatchResult = null,
};

fn mapProvider(cp: CTextProvider) cli.Provider {
    return switch (cp) {
        .claude => .claude,
        .deepseek => .deepseek,
        .gemini => .gemini,
        .grok => .grok,
        .vertex => .vertex,
        .unknown => .claude,
    };
}

fn mapProviderToC(p: cli.Provider) CTextProvider {
    return switch (p) {
        .claude => .claude,
        .deepseek => .deepseek,
        .gemini => .gemini,
        .grok => .grok,
        .vertex => .vertex,
    };
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.FileNotFound => ErrorCode.IO_ERROR,
        error.AccessDenied => ErrorCode.AUTH_ERROR,
        error.InvalidData => ErrorCode.PARSE_ERROR,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}
