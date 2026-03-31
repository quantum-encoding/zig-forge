// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Research CLI
//!
//! Commands:
//!   zig-ai research "query"               - Web search (default, fast)
//!   zig-ai research "query" --deep        - Deep research (comprehensive, minutes)
//!   zig-ai research "query" -o report.md  - Save to file
//!   zig-ai research "query" --json        - Output as JSON

const std = @import("std");
const types = @import("types.zig");
const web_search = @import("web_search.zig");
const deep_research = @import("deep_research.zig");
const pricing = @import("../agent/pricing.zig");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;

pub const ResearchConfig = struct {
    mode: types.ResearchMode = .web_search,
    model: ?[]const u8 = null,
    agent: []const u8 = deep_research.DEEP_RESEARCH_AGENT,
    output_file: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 64000,
    thinking: types.ThinkingLevel = .low,
    show_sources: bool = true,
    json_output: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = ResearchConfig{};
    var query: ?[]const u8 = null;
    var show_help = false;

    var i: usize = 2; // Skip program name and "research"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--deep") or std.mem.eql(u8, arg, "-D")) {
            config.mode = .deep_research;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --model requires a value\n", .{});
                return error.MissingArgument;
            }
            config.model = args[i];
        } else if (std.mem.eql(u8, arg, "--agent") or std.mem.eql(u8, arg, "-A")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --agent requires a value\n", .{});
                return error.MissingArgument;
            }
            config.agent = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --system requires a value\n", .{});
                return error.MissingArgument;
            }
            config.system_prompt = args[i];
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
        } else if (std.mem.eql(u8, arg, "--thinking") or std.mem.eql(u8, arg, "-T")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --thinking requires a value (off, low, medium, high)\n", .{});
                return error.MissingArgument;
            }
            if (std.mem.eql(u8, args[i], "off")) {
                config.thinking = .off;
            } else if (std.mem.eql(u8, args[i], "low")) {
                config.thinking = .low;
            } else if (std.mem.eql(u8, args[i], "medium")) {
                config.thinking = .medium;
            } else if (std.mem.eql(u8, args[i], "high")) {
                config.thinking = .high;
            } else {
                std.debug.print("Error: invalid --thinking value '{s}' (use: off, low, medium, high)\n", .{args[i]});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--no-sources")) {
            config.show_sources = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json_output = true;
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
        std.debug.print("Error: No research query provided\n\n", .{});
        printHelp();
        return error.MissingPrompt;
    };

    // Get API key: try GEMINI_API_KEY first, fallback to GOOGLE_GENAI_API_KEY
    const api_key_ptr = std.c.getenv("GEMINI_API_KEY") orelse
        std.c.getenv("GOOGLE_GENAI_API_KEY") orelse {
        std.debug.print("Error: GEMINI_API_KEY (or GOOGLE_GENAI_API_KEY) environment variable not set\n", .{});
        std.debug.print("Set it with: export GEMINI_API_KEY=your-api-key\n", .{});
        return error.MissingApiKey;
    };
    const api_key = std.mem.span(api_key_ptr);

    // Build request
    const request = types.ResearchRequest{
        .query = q,
        .mode = config.mode,
        .model = config.model,
        .agent = config.agent,
        .system_prompt = config.system_prompt,
        .max_tokens = config.max_tokens,
        .thinking = config.thinking,
    };

    std.debug.print("[{s}] Researching: {s}\n\n", .{ config.mode.displayName(), q });

    // Execute research
    var result = switch (config.mode) {
        .web_search => web_search.search(allocator, api_key, request),
        .deep_research => deep_research.research(allocator, api_key, request),
    } catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();

    if (config.json_output) {
        try outputJson(allocator, &result, config.mode);
    } else {
        // Print report content
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

            // Estimate cost using the model name
            const model_name = config.model orelse "gemini-2.5-flash";
            if (pricing.calculateCost(model_name, result.input_tokens, result.output_tokens)) |cost| {
                var cost_buf: [64]u8 = undefined;
                const cost_str = pricing.formatCost(&cost_buf, cost);
                std.debug.print("Estimated cost: {s}\n", .{cost_str});
            }
        }
    }

    // Save to file if requested
    if (config.output_file) |path| {
        try saveToFile(path, result.content);
        std.debug.print("\nReport saved to: {s}\n", .{path});
    }
}

fn outputJson(allocator: std.mem.Allocator, result: *types.ResearchResponse, mode: types.ResearchMode) !void {
    // Build JSON output manually
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"mode\":\"");
    try json_buf.appendSlice(allocator, mode.toString());
    try json_buf.appendSlice(allocator, "\",\"content\":\"");

    // Escape content for JSON
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
        \\],"input_tokens":{d},"output_tokens":{d}}}
    , .{ result.input_tokens, result.output_tokens });
    defer allocator.free(tokens_part);

    try json_buf.appendSlice(allocator, tokens_part);

    std.debug.print("{s}\n", .{json_buf.items});
}

fn saveToFile(path: []const u8, content: []u8) !void {
    // Need null-terminated path for fopen
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
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
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
        \\zig-ai research — Web Search and Deep Research via Gemini
        \\
        \\USAGE:
        \\  zig-ai research "query" [options]
        \\
        \\MODES:
        \\  (default)   Web Search — fast grounded search (seconds)
        \\  --deep, -D  Deep Research — comprehensive autonomous report (5-20 minutes)
        \\
        \\OPTIONS:
        \\  --model, -m <model>    Model override (default: gemini-2.5-flash for search)
        \\  --agent, -A <agent>    Deep research agent name override
        \\  --output, -o <path>    Save report to file
        \\  --system, -s <prompt>  System instruction
        \\  --max-tokens <n>       Maximum output tokens (default: 64000)
        \\  --thinking, -T <level> Thinking level: off, low, medium, high (default: low)
        \\                         Gemini 3: maps to thinkingLevel
        \\                         Gemini 2.5: maps to thinkingBudget (0/1K/8K/dynamic)
        \\  --no-sources           Hide source URLs
        \\  --json                 Output as JSON (content + sources + usage)
        \\  --help, -h             Show this help
        \\
        \\ENVIRONMENT:
        \\  GEMINI_API_KEY         Gemini API key (preferred)
        \\  GOOGLE_GENAI_API_KEY   Fallback API key
        \\
        \\EXAMPLES:
        \\  zig-ai research "What is quantum computing?"
        \\  zig-ai research "Zig vs Rust for systems programming" --deep
        \\  zig-ai research "Latest AI news" -o report.md
        \\  zig-ai research "DPDK performance tuning" --json
        \\  zig-ai research "topic" --deep --agent deep-research-2.0
        \\  zig-ai research "complex topic" -T high -m gemini-3-pro-preview
        \\
    , .{});
}
