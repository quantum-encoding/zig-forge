// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Search CLI — Web Search and X Search via xAI Grok
//!
//! Commands:
//!   zig-ai search "query"               - Web search (default)
//!   zig-ai search "query" -X             - X/Twitter search
//!   zig-ai search "query" -o report.md  - Save to file
//!   zig-ai search "query" --json        - Output as JSON

const std = @import("std");
const types = @import("types.zig");
const grok_search = @import("grok_search.zig");
const pricing = @import("../agent/pricing.zig");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;

pub const SearchConfig = struct {
    mode: types.SearchMode = .web_search,
    model: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    max_tokens: u32 = 64000,
    max_turns: ?u32 = null,
    show_sources: bool = true,
    json_output: bool = false,
    enable_image_understanding: bool = false,
    enable_video_understanding: bool = false,
    // Repeatable filter lists (accumulated during arg parsing)
    allowed_domains: std.ArrayListUnmanaged([]const u8) = .empty,
    excluded_domains: std.ArrayListUnmanaged([]const u8) = .empty,
    allowed_x_handles: std.ArrayListUnmanaged([]const u8) = .empty,
    excluded_x_handles: std.ArrayListUnmanaged([]const u8) = .empty,
    from_date: ?[]const u8 = null,
    to_date: ?[]const u8 = null,

    pub fn deinit(self: *SearchConfig, allocator: std.mem.Allocator) void {
        self.allowed_domains.deinit(allocator);
        self.excluded_domains.deinit(allocator);
        self.allowed_x_handles.deinit(allocator);
        self.excluded_x_handles.deinit(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = SearchConfig{};
    defer config.deinit(allocator);
    var query: ?[]const u8 = null;
    var show_help = false;

    var i: usize = 2; // Skip program name and "search"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--x") or std.mem.eql(u8, arg, "-X")) {
            config.mode = .x_search;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                return error.MissingArgument;
            }
            config.model = args[i];
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --system requires a value\n", .{});
                return error.MissingArgument;
            }
            config.instructions = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-tokens requires a value\n", .{});
                return error.MissingArgument;
            }
            config.max_tokens = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid --max-tokens value\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-turns requires a value\n", .{});
                return error.MissingArgument;
            }
            config.max_turns = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: invalid --max-turns value\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--no-sources")) {
            config.show_sources = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json_output = true;
        } else if (std.mem.eql(u8, arg, "--allow-domain")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --allow-domain requires a value\n", .{});
                return error.MissingArgument;
            }
            try config.allowed_domains.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--exclude-domain")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --exclude-domain requires a value\n", .{});
                return error.MissingArgument;
            }
            try config.excluded_domains.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--allow-handle")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --allow-handle requires a value\n", .{});
                return error.MissingArgument;
            }
            try config.allowed_x_handles.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--exclude-handle")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --exclude-handle requires a value\n", .{});
                return error.MissingArgument;
            }
            try config.excluded_x_handles.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --from requires a date (YYYY-MM-DD)\n", .{});
                return error.MissingArgument;
            }
            config.from_date = args[i];
        } else if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --to requires a date (YYYY-MM-DD)\n", .{});
                return error.MissingArgument;
            }
            config.to_date = args[i];
        } else if (std.mem.eql(u8, arg, "--image-understanding")) {
            config.enable_image_understanding = true;
        } else if (std.mem.eql(u8, arg, "--video-understanding")) {
            config.enable_video_understanding = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            printHelp();
            return error.UnknownOption;
        } else {
            if (query == null) {
                query = arg;
            } else {
                std.debug.print("Error: Multiple queries provided. Use quotes for multi-word queries.\n", .{});
                return error.MultiplePrompts;
            }
        }
    }

    if (show_help) {
        printHelp();
        return;
    }

    const q = query orelse {
        std.debug.print("Error: No search query provided\n\n", .{});
        printHelp();
        return error.MissingPrompt;
    };

    // Get API key
    const api_key_ptr = std.c.getenv("XAI_API_KEY") orelse {
        std.debug.print("Error: XAI_API_KEY environment variable not set\n", .{});
        std.debug.print("Set it with: export XAI_API_KEY=your-api-key\n", .{});
        return error.MissingApiKey;
    };
    const api_key = std.mem.span(api_key_ptr);

    // Build request
    const request = types.SearchRequest{
        .query = q,
        .mode = config.mode,
        .model = config.model,
        .instructions = config.instructions,
        .max_output_tokens = config.max_tokens,
        .max_turns = config.max_turns,
        .allowed_domains = if (config.allowed_domains.items.len > 0) config.allowed_domains.items else null,
        .excluded_domains = if (config.excluded_domains.items.len > 0) config.excluded_domains.items else null,
        .allowed_x_handles = if (config.allowed_x_handles.items.len > 0) config.allowed_x_handles.items else null,
        .excluded_x_handles = if (config.excluded_x_handles.items.len > 0) config.excluded_x_handles.items else null,
        .from_date = config.from_date,
        .to_date = config.to_date,
        .enable_image_understanding = config.enable_image_understanding,
        .enable_video_understanding = config.enable_video_understanding,
    };

    std.debug.print("[{s}] Searching: {s}\n\n", .{ config.mode.displayName(), q });

    // Execute search
    var result = grok_search.search(allocator, api_key, request) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();

    if (config.json_output) {
        try outputJson(allocator, &result, config.mode);
    } else {
        // Print content
        std.debug.print("{s}\n", .{result.content});

        // Print sources
        if (config.show_sources and result.sources.len > 0) {
            std.debug.print("\n--- Sources ({d}) ---\n", .{result.sources.len});
            for (result.sources, 1..) |src, idx| {
                if (src.title.len > 0) {
                    std.debug.print("{d}. {s}\n   {s}\n", .{ idx, src.title, src.uri });
                } else {
                    std.debug.print("{d}. {s}\n", .{ idx, src.uri });
                }
            }
        }

        // Print usage stats
        if (result.input_tokens > 0 or result.output_tokens > 0) {
            std.debug.print("\n--- Usage ---\n", .{});
            std.debug.print("Input: {d} tokens, Output: {d} tokens\n", .{
                result.input_tokens,
                result.output_tokens,
            });
            if (result.reasoning_tokens > 0) {
                std.debug.print("Reasoning: {d} tokens\n", .{result.reasoning_tokens});
            }
            if (result.cached_tokens > 0) {
                std.debug.print("Cached: {d} tokens\n", .{result.cached_tokens});
            }

            const model_name = config.model orelse "grok-4-1-fast-reasoning";
            if (pricing.calculateCost(model_name, result.input_tokens, result.output_tokens)) |cost| {
                var cost_buf: [64]u8 = undefined;
                const cost_str = pricing.formatCost(&cost_buf, cost);
                std.debug.print("Estimated cost: {s}\n", .{cost_str});
            }
        }

        // Print server-side tool usage
        if (result.tool_usage.total() > 0) {
            std.debug.print("\n--- Tool Usage ---\n", .{});
            if (result.tool_usage.web_search_calls > 0)
                std.debug.print("Web search: {d} calls\n", .{result.tool_usage.web_search_calls});
            if (result.tool_usage.x_search_calls > 0)
                std.debug.print("X search: {d} calls\n", .{result.tool_usage.x_search_calls});
            if (result.tool_usage.code_execution_calls > 0)
                std.debug.print("Code execution: {d} calls\n", .{result.tool_usage.code_execution_calls});
            if (result.tool_usage.view_image_calls > 0)
                std.debug.print("Image analysis: {d} calls\n", .{result.tool_usage.view_image_calls});
            if (result.tool_usage.view_x_video_calls > 0)
                std.debug.print("Video analysis: {d} calls\n", .{result.tool_usage.view_x_video_calls});
            if (result.tool_usage.collections_search_calls > 0)
                std.debug.print("Collections search: {d} calls\n", .{result.tool_usage.collections_search_calls});
            if (result.tool_usage.mcp_calls > 0)
                std.debug.print("MCP: {d} calls\n", .{result.tool_usage.mcp_calls});
        }
    }

    // Save to file if requested
    if (config.output_file) |path| {
        try saveToFile(path, result.content);
        std.debug.print("\nSaved to: {s}\n", .{path});
    }
}

fn outputJson(allocator: std.mem.Allocator, result: *types.SearchResponse, mode: types.SearchMode) !void {
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"mode\":\"");
    try json_buf.appendSlice(allocator, mode.toString());
    try json_buf.appendSlice(allocator, "\",\"content\":\"");
    try escapeJsonString(allocator, &json_buf, result.content);

    try json_buf.appendSlice(allocator, "\",\"sources\":[");
    for (result.sources, 0..) |src, idx| {
        if (idx > 0) try json_buf.append(allocator, ',');
        try json_buf.appendSlice(allocator, "{\"title\":\"");
        try escapeJsonString(allocator, &json_buf, src.title);
        try json_buf.appendSlice(allocator, "\",\"uri\":\"");
        try escapeJsonString(allocator, &json_buf, src.uri);
        try json_buf.appendSlice(allocator, "\"}");
    }

    const tokens_part = try std.fmt.allocPrint(allocator,
        \\],"input_tokens":{d},"output_tokens":{d},"reasoning_tokens":{d},"cached_tokens":{d}
    , .{ result.input_tokens, result.output_tokens, result.reasoning_tokens, result.cached_tokens });
    defer allocator.free(tokens_part);
    try json_buf.appendSlice(allocator, tokens_part);

    // Server-side tool usage
    if (result.tool_usage.total() > 0) {
        const tu = try std.fmt.allocPrint(allocator,
            \\,"tool_usage":{{"web_search":{d},"x_search":{d},"code_execution":{d},"view_image":{d},"view_x_video":{d},"collections_search":{d},"mcp":{d}}}
        , .{
            result.tool_usage.web_search_calls,
            result.tool_usage.x_search_calls,
            result.tool_usage.code_execution_calls,
            result.tool_usage.view_image_calls,
            result.tool_usage.view_x_video_calls,
            result.tool_usage.collections_search_calls,
            result.tool_usage.mcp_calls,
        });
        defer allocator.free(tu);
        try json_buf.appendSlice(allocator, tu);
    }

    try json_buf.append(allocator, '}');

    std.debug.print("{s}\n", .{json_buf.items});
}

fn saveToFile(path: []const u8, content: []u8) !void {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.InvalidArgument;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path.len :0];

    const file = fopen(path_z, "w") orelse return error.IoError;
    defer _ = fclose(file);
    _ = fwrite(content.ptr, 1, content.len, file);
}

fn escapeJsonString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try list.appendSlice(allocator, hex);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

fn printHelp() void {
    std.debug.print(
        \\zig-ai search — Web Search and X Search via xAI Grok
        \\
        \\USAGE:
        \\  zig-ai search "query" [options]
        \\
        \\MODES:
        \\  (default)   Web Search — search the internet via Grok
        \\  --x, -X     X Search — search X/Twitter posts
        \\
        \\OPTIONS:
        \\  --model, -m <model>      Model override (default: grok-4-1-fast-reasoning)
        \\  --system, -s <prompt>    System instruction
        \\  --output, -o <path>      Save result to file
        \\  --max-tokens <n>         Maximum output tokens (default: 64000)
        \\  --max-turns <n>          Max agentic loop turns (limits tool call rounds)
        \\  --no-sources             Hide source URLs
        \\  --json                   Output as JSON
        \\  --help, -h               Show this help
        \\
        \\WEB SEARCH FILTERS:
        \\  --allow-domain <domain>    Constrain to domain (repeatable)
        \\  --exclude-domain <domain>  Exclude domain (repeatable)
        \\
        \\X SEARCH FILTERS:
        \\  --allow-handle <handle>    Constrain to X handle (repeatable)
        \\  --exclude-handle <handle>  Exclude X handle (repeatable)
        \\  --from <YYYY-MM-DD>        Start date for X search
        \\  --to <YYYY-MM-DD>          End date for X search
        \\
        \\MEDIA UNDERSTANDING:
        \\  --image-understanding      Enable image analysis in results
        \\  --video-understanding      Enable video analysis (X search only)
        \\
        \\ENVIRONMENT:
        \\  XAI_API_KEY              xAI API key (required)
        \\
        \\EXAMPLES:
        \\  zig-ai search "What is Zig programming language?"
        \\  zig-ai search -X "AI news today"
        \\  zig-ai search "Zig vs Rust" --allow-domain ziglang.org
        \\  zig-ai search -X "Grok updates" --allow-handle xai --from 2026-01-01
        \\  zig-ai search "DPDK performance" -o report.md
        \\  zig-ai search "latest AI models" --json
        \\  zig-ai search "topic" -m grok-4-1-fast-non-reasoning
        \\
    , .{});
}
