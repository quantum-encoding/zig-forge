// FFI Text AI - C bindings for text generation with AI providers
// Thread-safe, uses global allocator for FFI boundary

const std = @import("std");
const types = @import("types.zig");
const cli = @import("../cli.zig");
const model_costs = @import("../model_costs.zig");

const CString = types.CString;
const CTextProvider = types.CTextProvider;
const CTextConfig = types.CTextConfig;
const CTextResponse = types.CTextResponse;
const CTextSession = types.CTextSession;
const CTokenUsage = types.CTokenUsage;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Session Management
// ============================================================================

/// Create a new text AI session
export fn zig_ai_text_session_create(config: *const CTextConfig) ?*CTextSession {
    const session = allocator.create(TextSessionInternal) catch return null;

    session.* = .{
        .provider = mapProvider(config.provider),
        .model = dupeString(config.model.toSlice()) catch null,
        .temperature = config.temperature,
        .max_tokens = config.max_tokens,
        .system_prompt = dupeString(config.system_prompt.toSlice()) catch null,
        .api_key = dupeString(config.api_key.toSlice()) catch null,
        .conversation = std.ArrayList(Message).init(allocator),
    };

    return @ptrCast(session);
}

/// Destroy a text AI session
export fn zig_ai_text_session_destroy(session: ?*CTextSession) void {
    if (session == null) return;
    const s: *TextSessionInternal = @ptrCast(@alignCast(session));

    if (s.model) |m| allocator.free(m);
    if (s.system_prompt) |sp| allocator.free(sp);
    if (s.api_key) |ak| allocator.free(ak);

    for (s.conversation.items) |msg| {
        allocator.free(msg.content);
    }
    s.conversation.deinit();

    allocator.destroy(s);
}

/// Send a message and get a response
export fn zig_ai_text_send(
    session: ?*CTextSession,
    prompt: CString,
    response_out: *CTextResponse,
) void {
    response_out.* = std.mem.zeroes(CTextResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *TextSessionInternal = @ptrCast(@alignCast(session));
    const prompt_slice = prompt.toSlice();

    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    // Build context from conversation history
    var context: ?[]const cli.AIMessage = null;
    if (s.conversation.items.len > 0) {
        var ai_messages = allocator.alloc(cli.AIMessage, s.conversation.items.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };
        defer allocator.free(ai_messages);

        for (s.conversation.items, 0..) |msg, i| {
            ai_messages[i] = .{
                .role = if (msg.is_user) .user else .assistant,
                .content = msg.content,
            };
        }
        context = ai_messages;
    }

    // Create CLI config
    const cli_config = cli.CLIConfig{
        .provider = s.provider,
        .model = s.model,
        .temperature = s.temperature,
        .max_tokens = s.max_tokens,
        .system_prompt = s.system_prompt,
    };

    // Make API call
    var cli_instance = cli.CLI.init(allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, context) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Store in conversation
    s.conversation.append(.{
        .content = allocator.dupe(u8, prompt_slice) catch "",
        .is_user = true,
    }) catch {};

    s.conversation.append(.{
        .content = allocator.dupe(u8, result.message.content) catch "",
        .is_user = false,
    }) catch {};

    // Build response
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = blk: {
            // Get actual costs based on provider
            const costs = switch (s.provider) {
                .deepseek => .{ @as(f64, 0.14), @as(f64, 0.28) },
                .claude => .{ @as(f64, 3.0), @as(f64, 15.0) },
                .gemini => .{ @as(f64, 0.075), @as(f64, 0.30) },
                .grok => .{ @as(f64, 2.0), @as(f64, 10.0) },
                .openai => .{ @as(f64, 2.50), @as(f64, 10.0) },
                .vertex => .{ @as(f64, 1.25), @as(f64, 5.0) },
            };
            break :blk result.usage.estimateCost(costs[0], costs[1]);
        },
    };
    response_out.provider = s.config_provider;
}

/// Send a message with extended options (images, files, server tools, collections)
export fn zig_ai_text_send_ex(
    session: ?*CTextSession,
    prompt: CString,
    options: ?*const types.CTextSendOptions,
    response_out: *CTextResponse,
) void {
    response_out.* = std.mem.zeroes(CTextResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *TextSessionInternal = @ptrCast(@alignCast(session));
    const prompt_slice = prompt.toSlice();

    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    // Build CLI config with extended options
    var cli_config = cli.CLIConfig{
        .provider = s.provider,
        .model = s.model,
        .temperature = s.temperature,
        .max_tokens = s.max_tokens,
        .system_prompt = s.system_prompt,
    };

    // Temporary storage for converted arrays
    var image_paths_buf: [16][]const u8 = undefined;
    var file_ids_buf: [32][]const u8 = undefined;
    var collection_ids_buf: [16][]const u8 = undefined;
    var server_tools_buf: [3]cli.ai.common.ServerSideTool = undefined;

    if (options) |opts| {
        // Image paths
        if (opts.image_paths) |paths| {
            const count = @min(opts.image_path_count, 16);
            for (0..count) |i| {
                image_paths_buf[i] = paths[i].toSlice();
            }
            if (count > 0) cli_config.image_paths = image_paths_buf[0..count];
        }

        // File IDs
        if (opts.file_ids) |fids| {
            const count = @min(opts.file_id_count, 32);
            for (0..count) |i| {
                file_ids_buf[i] = fids[i].toSlice();
            }
            if (count > 0) cli_config.file_ids = file_ids_buf[0..count];
        }

        // Collection IDs
        if (opts.collection_ids) |cids| {
            const count = @min(opts.collection_id_count, 16);
            for (0..count) |i| {
                collection_ids_buf[i] = cids[i].toSlice();
            }
            if (count > 0) {
                cli_config.collection_ids = collection_ids_buf[0..count];
                cli_config.collection_max_results = opts.collection_max_results;
            }
        }

        // Server-side tools
        var tool_count: usize = 0;
        if (opts.enable_web_search) {
            server_tools_buf[tool_count] = .web_search;
            tool_count += 1;
        }
        if (opts.enable_x_search) {
            server_tools_buf[tool_count] = .x_search;
            tool_count += 1;
        }
        if (opts.enable_code_interpreter) {
            server_tools_buf[tool_count] = .code_interpreter;
            tool_count += 1;
        }
        if (tool_count > 0) cli_config.server_tools = server_tools_buf[0..tool_count];
    }

    // Make API call
    var cli_instance = cli.CLI.init(allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Store in conversation
    s.conversation.append(.{
        .content = allocator.dupe(u8, prompt_slice) catch "",
        .is_user = true,
    }) catch {};

    s.conversation.append(.{
        .content = allocator.dupe(u8, result.message.content) catch "",
        .is_user = false,
    }) catch {};

    // Build response
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = blk: {
            const costs = switch (s.provider) {
                .deepseek => .{ @as(f64, 0.14), @as(f64, 0.28) },
                .claude => .{ @as(f64, 3.0), @as(f64, 15.0) },
                .gemini => .{ @as(f64, 0.075), @as(f64, 0.30) },
                .grok => .{ @as(f64, 2.0), @as(f64, 10.0) },
                .openai => .{ @as(f64, 2.50), @as(f64, 10.0) },
                .vertex => .{ @as(f64, 1.25), @as(f64, 5.0) },
            };
            break :blk result.usage.estimateCost(costs[0], costs[1]);
        },
    };
    response_out.provider = s.config_provider;
}

/// Clear conversation history
export fn zig_ai_text_clear_history(session: ?*CTextSession) void {
    if (session == null) return;
    const s: *TextSessionInternal = @ptrCast(@alignCast(session));

    for (s.conversation.items) |msg| {
        allocator.free(msg.content);
    }
    s.conversation.clearRetainingCapacity();
}

// ============================================================================
// One-shot Functions (no session needed)
// ============================================================================

/// Send a one-shot message to a provider
export fn zig_ai_text_query(
    provider: CTextProvider,
    prompt: CString,
    api_key: CString,
    response_out: *CTextResponse,
) void {
    response_out.* = std.mem.zeroes(CTextResponse);

    const prompt_slice = prompt.toSlice();
    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    const zig_provider = mapProvider(provider);

    const cli_config = cli.CLIConfig{
        .provider = zig_provider,
        .api_key = if (api_key.len > 0) api_key.toSlice() else null,
    };

    var cli_instance = cli.CLI.init(allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = 0,
    };
    response_out.provider = provider;
}

/// Calculate cost for a model
export fn zig_ai_text_calculate_cost(
    provider: CTextProvider,
    model: CString,
    input_tokens: u32,
    output_tokens: u32,
) f64 {
    const provider_name = switch (provider) {
        .claude => "anthropic",
        .deepseek => "deepseek",
        .gemini => "google",
        .grok => "xai",
        .vertex => "google",
        .unknown => return 0,
    };

    return model_costs.calculateCost(
        provider_name,
        model.toSlice(),
        input_tokens,
        output_tokens,
    );
}

/// Get default model for a provider
export fn zig_ai_text_default_model(provider: CTextProvider) CString {
    const zig_provider = mapProvider(provider);
    return CString.fromSlice(zig_provider.getDefaultModel(null));
}

/// Check if a provider is available (API key set)
export fn zig_ai_text_provider_available(provider: CTextProvider) bool {
    const zig_provider = mapProvider(provider);
    const env_var = zig_provider.getEnvVar();
    return std.c.getenv(env_var) != null;
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free a text response
export fn zig_ai_text_response_free(response: *CTextResponse) void {
    if (response.content.ptr) |p| {
        allocator.free(p[0..response.content.len]);
    }
    if (response.error_message.ptr) |p| {
        allocator.free(p[0..response.error_message.len]);
    }
    if (response.model_used.ptr) |p| {
        allocator.free(p[0..response.model_used.len]);
    }
    response.* = std.mem.zeroes(CTextResponse);
}

/// Free a C string allocated by this library
export fn zig_ai_string_free(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0..s.len]);
    }
}

// ============================================================================
// Internal Types and Helpers
// ============================================================================

const TextSessionInternal = struct {
    provider: cli.Provider,
    config_provider: CTextProvider = .unknown,
    model: ?[]const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: ?[]const u8,
    api_key: ?[]const u8,
    conversation: std.ArrayList(Message),
};

const Message = struct {
    content: []const u8,
    is_user: bool,
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

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.ConnectionRefused, error.NetworkUnreachable => ErrorCode.NETWORK_ERROR,
        error.AuthenticationFailed => ErrorCode.AUTH_ERROR,
        error.Timeout => ErrorCode.TIMEOUT,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn dupeString(s: []const u8) !?[]const u8 {
    if (s.len == 0) return null;
    return try allocator.dupe(u8, s);
}

fn makeErrorString(msg: []const u8) CString {
    const duped = allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}
