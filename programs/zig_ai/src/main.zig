// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! AI Providers CLI - Main Entry Point

const std = @import("std");
const cli = @import("cli.zig");
const batch = @import("batch.zig");
const media = @import("media/mod.zig");
const audio = @import("audio/mod.zig");
const structured = @import("structured/mod.zig");
const agent = @import("agent/mod.zig");
const research = @import("research/mod.zig");
const batch_api = @import("batch_api/mod.zig");
const voice = @import("voice/mod.zig");
const live = @import("live/mod.zig");
const text_templates = @import("text/templates.zig");

// C file I/O for file upload (not in std.c on Zig 0.16)
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Check for image-batch command
    if (args.len >= 2 and std.mem.eql(u8, args[1], "image-batch")) {
        const batch_cli = @import("media/batch_cli.zig");
        try batch_cli.run(allocator, args);
        return;
    }

    // Check for media commands first (dalle3, grok-image, imagen, etc.)
    // Media commands are handled by the media module
    if (try media.cli.run(allocator, args)) {
        return; // Media command was handled
    }

    // Check for audio/TTS commands (tts-openai, tts-google)
    if (try audio.cli.run(allocator, args)) {
        return; // Audio command was handled
    }

    // Check for structured output commands (structured, schemas, struct-templates)
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "structured")) {
            try structured.runStructured(allocator, args);
            return;
        }
        if (std.mem.eql(u8, args[1], "schemas")) {
            try structured.runSchemas(allocator, args);
            return;
        }
        if (std.mem.eql(u8, args[1], "struct-templates")) {
            structured.templates.listTemplates();
            return;
        }
    }

    // Check for agent commands
    if (args.len >= 2 and std.mem.eql(u8, args[1], "agent")) {
        try agent.runCli(allocator, args);
        return;
    }

    // Check for research commands
    if (args.len >= 2 and std.mem.eql(u8, args[1], "research")) {
        try research.runCli(allocator, args);
        return;
    }

    // Check for search commands (xAI Grok Web Search / X Search)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "search")) {
        const search_mod = @import("search/mod.zig");
        try search_mod.runCli(allocator, args);
        return;
    }

    // Check for batch API commands (Anthropic Message Batches API)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "batch-api")) {
        try batch_api.runCli(allocator, args);
        return;
    }

    // Check for voice agent commands (xAI Grok Realtime)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "voice")) {
        _ = try voice.cli.run(allocator, args);
        return;
    }

    // Check for models listing command
    if (args.len >= 2 and std.mem.eql(u8, args[1], "models")) {
        const models_mod = @import("models.zig");
        models_mod.run(args);
        return;
    }

    // Check for Gemini Live commands (real-time WebSocket streaming)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "live")) {
        _ = try live.cli.run(allocator, args);
        return;
    }

    // Check for file management commands (xAI Files API)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "file")) {
        try runFileCommand(allocator, args);
        return;
    }

    // Check for Gemini file management commands (Google Files API)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "gemini-file")) {
        try runGeminiFileCommand(allocator, args);
        return;
    }

    // Check for embeddings command (Gemini Embeddings API)
    if (args.len >= 2 and std.mem.eql(u8, args[1], "embed")) {
        try runEmbedCommand(allocator, args);
        return;
    }

    // Check for special media help commands
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "image") and args.len >= 3 and std.mem.eql(u8, args[2], "--help")) {
            media.cli.printHelp();
            return;
        }
        if (std.mem.eql(u8, args[1], "--list-image-providers")) {
            media.cli.listProviders();
            return;
        }
    }

    // Parse arguments
    var config = cli.CLIConfig{};
    var provider_set = false;
    var prompt: ?[]const u8 = null;
    var show_list = false;
    var show_help = false;

    // Batch mode options
    var batch_mode = false;
    var batch_input: ?[]const u8 = null;
    var batch_output: ?[]const u8 = null;
    var batch_concurrency: u32 = 50;
    var batch_full_responses = false;
    var batch_retry: u32 = 2;

    // Vision/image options
    var image_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer image_paths.deinit(allocator);

    // xAI server-side tools & include options
    var server_tools_list: std.ArrayListUnmanaged(cli.ai.common.ServerSideTool) = .empty;
    defer server_tools_list.deinit(allocator);
    var mcp_tools_list: std.ArrayListUnmanaged(cli.ai.common.McpToolConfig) = .empty;
    defer mcp_tools_list.deinit(allocator);
    var include_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer include_list.deinit(allocator);
    var collection_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer collection_list.deinit(allocator);
    var collection_max_results: u32 = 10;
    var file_id_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_id_list.deinit(allocator);
    var file_path_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_path_list.deinit(allocator);

    // Tool choice options
    var tool_choice: ?cli.ai.common.ToolChoice = null;
    var tool_choice_function: ?[]const u8 = null;
    var parallel_tool_calls: ?bool = null;

    // Allowed function names for Gemini toolConfig
    var allowed_fn_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer allowed_fn_list.deinit(allocator);

    // Gemini video/file options
    var video_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer video_paths.deinit(allocator);
    var youtube_urls: std.ArrayListUnmanaged([]const u8) = .empty;
    defer youtube_urls.deinit(allocator);

    // Text template options
    var text_template_name: ?[]const u8 = null;
    var template_params = std.StringHashMapUnmanaged([]const u8){};
    defer template_params.deinit(allocator);

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            show_list = true;
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            config.interactive = true;
        } else if (std.mem.eql(u8, arg, "--temperature") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --temperature requires a value\n", .{});
                return error.MissingArgument;
            }
            config.temperature = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-tokens requires a value\n", .{});
                return error.MissingArgument;
            }
            config.max_tokens = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --system requires a value\n", .{});
                return error.MissingArgument;
            }
            config.system_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--no-usage")) {
            config.show_usage = false;
        } else if (std.mem.eql(u8, arg, "--no-cost")) {
            config.show_cost = false;
        } else if (std.mem.eql(u8, arg, "--save")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --save requires a base filename\n", .{});
                return error.MissingArgument;
            }
            config.save_code = args[i];
        } else if (std.mem.eql(u8, arg, "--batch") or std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --batch requires a file path\n", .{});
                return error.MissingArgument;
            }
            batch_mode = true;
            batch_input = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                return error.MissingArgument;
            }
            batch_output = args[i];
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --concurrency requires a value\n", .{});
                return error.MissingArgument;
            }
            batch_concurrency = try std.fmt.parseInt(u32, args[i], 10);
            if (batch_concurrency == 0 or batch_concurrency > 200) {
                std.debug.print("Error: --concurrency must be between 1 and 200\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--full-responses")) {
            batch_full_responses = true;
        } else if (std.mem.eql(u8, arg, "--retry")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --retry requires a value\n", .{});
                return error.MissingArgument;
            }
            batch_retry = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--image") or std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--doc") or std.mem.eql(u8, arg, "--pdf")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: {s} requires a file path or URL\n", .{arg});
                return error.MissingArgument;
            }
            try image_paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--web-search")) {
            try server_tools_list.append(allocator, .web_search);
        } else if (std.mem.eql(u8, arg, "--x-search")) {
            try server_tools_list.append(allocator, .x_search);
        } else if (std.mem.eql(u8, arg, "--code-interpreter")) {
            try server_tools_list.append(allocator, .code_interpreter);
        } else if (std.mem.eql(u8, arg, "--google-search")) {
            try server_tools_list.append(allocator, .google_search);
        } else if (std.mem.eql(u8, arg, "--url-context")) {
            try server_tools_list.append(allocator, .url_context);
        } else if (std.mem.eql(u8, arg, "--google-maps")) {
            try server_tools_list.append(allocator, .google_maps);
        } else if (std.mem.eql(u8, arg, "--maps-location")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --maps-location requires lat,lng\n", .{});
                return error.MissingArgument;
            }
            // Parse "lat,lng" format
            if (std.mem.indexOf(u8, args[i], ",")) |comma| {
                config.maps_latitude = std.fmt.parseFloat(f64, args[i][0..comma]) catch {
                    std.debug.print("Error: Invalid latitude in --maps-location\n", .{});
                    return error.InvalidArgument;
                };
                config.maps_longitude = std.fmt.parseFloat(f64, args[i][comma + 1 ..]) catch {
                    std.debug.print("Error: Invalid longitude in --maps-location\n", .{});
                    return error.InvalidArgument;
                };
            } else {
                std.debug.print("Error: --maps-location format is lat,lng (e.g. 37.78,-122.40)\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mcp requires a server URL\n", .{});
                return error.MissingArgument;
            }
            try mcp_tools_list.append(allocator, .{ .server_url = args[i] });
        } else if (std.mem.eql(u8, arg, "--mcp-label")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mcp-label requires a value\n", .{});
                return error.MissingArgument;
            }
            if (mcp_tools_list.items.len == 0) {
                std.debug.print("Error: --mcp-label must follow --mcp\n", .{});
                return error.InvalidArgument;
            }
            mcp_tools_list.items[mcp_tools_list.items.len - 1].server_label = args[i];
        } else if (std.mem.eql(u8, arg, "--mcp-auth")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --mcp-auth requires a token\n", .{});
                return error.MissingArgument;
            }
            if (mcp_tools_list.items.len == 0) {
                std.debug.print("Error: --mcp-auth must follow --mcp\n", .{});
                return error.InvalidArgument;
            }
            mcp_tools_list.items[mcp_tools_list.items.len - 1].authorization = args[i];
        } else if (std.mem.eql(u8, arg, "--include")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --include requires a value\n", .{});
                return error.MissingArgument;
            }
            try include_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--collection")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --collection requires a collection ID\n", .{});
                return error.MissingArgument;
            }
            try collection_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--collection-max-results")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --collection-max-results requires a value\n", .{});
                return error.MissingArgument;
            }
            collection_max_results = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--file-id")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file-id requires a file ID\n", .{});
                return error.MissingArgument;
            }
            try file_id_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-F")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --file requires a file path\n", .{});
                return error.MissingArgument;
            }
            try file_path_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--tool-choice")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --tool-choice requires a value (auto/required/none/<function_name>)\n", .{});
                return error.MissingArgument;
            }
            const val = args[i];
            if (std.mem.eql(u8, val, "auto")) {
                tool_choice = .auto;
            } else if (std.mem.eql(u8, val, "required") or std.mem.eql(u8, val, "any")) {
                tool_choice = .required;
            } else if (std.mem.eql(u8, val, "none")) {
                tool_choice = .none;
            } else if (std.mem.eql(u8, val, "validated")) {
                tool_choice = .validated;
            } else {
                tool_choice = .function;
                tool_choice_function = val;
            }
        } else if (std.mem.eql(u8, arg, "--allowed-fn")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --allowed-fn requires a function name\n", .{});
                return error.MissingArgument;
            }
            try allowed_fn_list.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--no-parallel-tools")) {
            parallel_tool_calls = false;
        } else if (std.mem.eql(u8, arg, "--video") or std.mem.eql(u8, arg, "-V")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --video requires a file path\n", .{});
                return error.MissingArgument;
            }
            try video_paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--youtube")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --youtube requires a YouTube URL\n", .{});
                return error.MissingArgument;
            }
            try youtube_urls.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--media-resolution")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --media-resolution requires a value (low/medium/high/ultra_high)\n", .{});
                return error.MissingArgument;
            }
            config.media_resolution = cli.ai.common.MediaResolution.fromString(args[i]);
            if (config.media_resolution == null) {
                std.debug.print("Error: Unknown media resolution '{s}'\n", .{args[i]});
                std.debug.print("Valid: low, medium, high, ultra_high\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--text-template") or std.mem.eql(u8, arg, "-T")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --text-template requires a template name\n", .{});
                return error.MissingArgument;
            }
            text_template_name = args[i];
        } else if (std.mem.eql(u8, arg, "--param") or std.mem.eql(u8, arg, "-P")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --param requires key=value\n", .{});
                return error.MissingArgument;
            }
            // Parse key=value
            if (std.mem.indexOf(u8, args[i], "=")) |eq_pos| {
                const key = args[i][0..eq_pos];
                const value = args[i][eq_pos + 1 ..];
                try template_params.put(allocator, key, value);
            } else {
                std.debug.print("Error: --param format is key=value, got '{s}'\n", .{args[i]});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--text-templates")) {
            text_templates.listTemplates();
            return;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            cli.printUsage();
            return error.UnknownOption;
        } else {
            // Check if it's a provider name
            if (!provider_set) {
                if (cli.Provider.fromString(arg)) |provider| {
                    config.provider = provider;
                    provider_set = true;
                    continue;
                } else if (prompt == null and arg.len < 20 and std.mem.indexOf(u8, arg, " ") == null) {
                    // Looks like a typo'd provider name (short, no spaces, first positional arg)
                    std.debug.print("Error: Unknown provider '{s}'\n", .{arg});
                    std.debug.print("Valid providers: claude, deepseek, gemini, grok, vertex\n\n", .{});
                    cli.printUsage();
                    return error.UnknownProvider;
                }
            }

            // Otherwise it's the prompt
            if (prompt == null) {
                prompt = arg;
            } else {
                std.debug.print("Error: Multiple prompts provided. Use quotes for multi-word prompts.\n", .{});
                return error.MultiplePrompts;
            }
        }
    }

    // Handle special commands
    if (show_help) {
        cli.printUsage();
        return;
    }

    if (show_list) {
        cli.listProviders();
        return;
    }

    // Handle batch mode
    if (batch_mode) {
        const input_file = batch_input orelse {
            std.debug.print("Error: --batch requires an input CSV file\n", .{});
            return error.MissingBatchInput;
        };

        // Parse CSV file
        std.debug.print("📄 Parsing CSV file: {s}\n", .{input_file});
        const requests = batch.parseFile(allocator, input_file) catch |err| {
            std.debug.print("Error parsing CSV: {}\n", .{err});
            return err;
        };
        defer {
            for (requests) |*req| req.deinit();
            allocator.free(requests);
        }

        // Generate output filename if not specified
        const output_file = batch_output orelse blk: {
            const generated = try batch.generateOutputFilename(allocator);
            break :blk generated;
        };
        defer if (batch_output == null) allocator.free(output_file);

        // Create batch config
        const batch_config = batch.BatchConfig{
            .input_file = input_file,
            .output_file = output_file,
            .concurrency = batch_concurrency,
            .full_responses = batch_full_responses,
            .retry_count = batch_retry,
        };

        // Execute batch
        var executor = try batch.BatchExecutor.init(allocator, requests, batch_config);
        defer executor.deinit();

        try executor.execute();

        // Write results
        const results = try executor.getResults();
        try batch.writeResults(allocator, results, output_file, batch_full_responses);

        return;
    }

    // Check if API key is set
    const env_var = config.provider.getEnvVar();
    const has_key = std.c.getenv(env_var) != null;
    if (!has_key) {
        std.debug.print("Error: {s} environment variable not set\n", .{env_var});
        std.debug.print("\n   Set it with:\n", .{});
        std.debug.print("   export {s}=your_api_key_here\n\n", .{env_var});
        return error.MissingApiKey;
    }

    // Set image paths if provided
    if (image_paths.items.len > 0) {
        config.image_paths = image_paths.items;
    }

    // Set server-side tools if provided (Grok only)
    if (server_tools_list.items.len > 0) {
        config.server_tools = server_tools_list.items;
    }

    // Set MCP tools if provided (Grok only)
    if (mcp_tools_list.items.len > 0) {
        config.mcp_tools = mcp_tools_list.items;
    }

    // Set include parameter if provided
    if (include_list.items.len > 0) {
        config.include = include_list.items;
    }

    // Set collection IDs if provided (Grok only)
    if (collection_list.items.len > 0) {
        config.collection_ids = collection_list.items;
        config.collection_max_results = collection_max_results;
    }

    // Set tool choice options
    config.tool_choice = tool_choice;
    config.tool_choice_function = tool_choice_function;
    config.parallel_tool_calls = parallel_tool_calls;

    // Set allowed function names if provided (Gemini)
    if (allowed_fn_list.items.len > 0) {
        config.allowed_function_names = allowed_fn_list.items;
    }

    // Auto-upload file paths and collect file IDs (Grok only)
    if (file_path_list.items.len > 0) {
        if (config.provider != .grok) {
            std.debug.print("Error: --file is only supported with Grok provider\n", .{});
            return error.InvalidArgument;
        }
        const api_key_ptr = std.c.getenv("XAI_API_KEY");
        if (api_key_ptr == null) {
            std.debug.print("Error: XAI_API_KEY not set (required for file upload)\n", .{});
            return error.MissingArgument;
        }
        const api_key = std.mem.span(api_key_ptr.?);
        var grok_client = try cli.ai.GrokClient.init(allocator, api_key);
        defer grok_client.deinit();

        for (file_path_list.items) |path| {
            // Read file from disk using C API
            const path_z = try allocator.allocSentinel(u8, path.len, 0);
            defer allocator.free(path_z);
            @memcpy(path_z, path);

            const fp = std.c.fopen(path_z.ptr, "rb") orelse {
                std.debug.print("Error: Cannot open file: {s}\n", .{path});
                return error.FileNotFound;
            };
            defer _ = std.c.fclose(fp);

            // Get file size
            _ = fseek(fp, 0, SEEK_END);
            const size_long = ftell(fp);
            if (size_long < 0) {
                std.debug.print("Error: Cannot determine file size: {s}\n", .{path});
                return error.FileNotFound;
            }
            _ = fseek(fp, 0, SEEK_SET);
            const size: usize = @intCast(size_long);

            if (size > 48 * 1024 * 1024) {
                std.debug.print("Error: File exceeds 48MB limit: {s}\n", .{path});
                return error.InvalidArgument;
            }

            const file_data = try allocator.alloc(u8, size);
            defer allocator.free(file_data);
            const read = std.c.fread(file_data.ptr, 1, size, fp);
            if (read != size) {
                std.debug.print("Error: Failed to read file: {s}\n", .{path});
                return error.FileNotFound;
            }

            // Extract filename from path
            const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
                path[idx + 1 ..]
            else
                path;

            std.debug.print("Uploading {s}...", .{filename});
            const file_id = grok_client.uploadFile(file_data, filename) catch |err| {
                std.debug.print(" failed: {}\n", .{err});
                return err;
            };
            std.debug.print(" {s}\n", .{file_id});
            try file_id_list.append(allocator, file_id);
        }
    }

    // Set file IDs if provided (Grok only)
    if (file_id_list.items.len > 0) {
        config.file_ids = file_id_list.items;
    }

    // Upload videos via Gemini Files API and add as image URLs (file_data)
    if (video_paths.items.len > 0 or youtube_urls.items.len > 0) {
        if (config.provider != .gemini) {
            std.debug.print("Error: --video/--youtube are only supported with Gemini provider\n", .{});
            return error.InvalidArgument;
        }
        const gemini_key_ptr = std.c.getenv("GEMINI_API_KEY") orelse std.c.getenv("GOOGLE_GENAI_API_KEY");
        if (gemini_key_ptr == null) {
            std.debug.print("Error: GEMINI_API_KEY not set (required for video upload)\n", .{});
            return error.MissingArgument;
        }
        const gemini_key = std.mem.span(gemini_key_ptr.?);
        var gemini_client = try cli.ai.GeminiClient.init(allocator, gemini_key);
        defer gemini_client.deinit();

        // Upload each video file
        for (video_paths.items) |path| {
            const path_z = try allocator.allocSentinel(u8, path.len, 0);
            defer allocator.free(path_z);
            @memcpy(path_z, path);

            const fp = std.c.fopen(path_z.ptr, "rb") orelse {
                std.debug.print("Error: Cannot open video: {s}\n", .{path});
                return error.FileNotFound;
            };
            defer _ = std.c.fclose(fp);

            _ = fseek(fp, 0, SEEK_END);
            const size_long = ftell(fp);
            if (size_long < 0) {
                std.debug.print("Error: Cannot determine file size: {s}\n", .{path});
                return error.FileNotFound;
            }
            _ = fseek(fp, 0, SEEK_SET);
            const size: usize = @intCast(size_long);

            const file_data = try allocator.alloc(u8, size);
            defer allocator.free(file_data);
            const read = std.c.fread(file_data.ptr, 1, size, fp);
            if (read != size) {
                std.debug.print("Error: Failed to read video: {s}\n", .{path});
                return error.FileNotFound;
            }

            const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
                path[idx + 1 ..]
            else
                path;
            const mime = cli.ai.common.ImageInput.mimeTypeFromPath(path);

            std.debug.print("Uploading {s} ({d} bytes)...\n", .{ filename, size });
            const result = gemini_client.uploadFile(file_data, filename, mime) catch |err| {
                std.debug.print("Error uploading video: {}\n", .{err});
                return err;
            };

            // If result starts with "files/" it's a file name that needs polling
            var file_uri: []const u8 = result;
            if (std.mem.startsWith(u8, result, "files/")) {
                std.debug.print("Processing video (this may take a moment)...\n", .{});
                const uri = gemini_client.waitForFile(result, 60) catch |err| {
                    std.debug.print("Error: Video processing failed: {}\n", .{err});
                    allocator.free(result);
                    return err;
                };
                allocator.free(result);
                file_uri = uri;
            }

            std.debug.print("Ready: {s}\n", .{file_uri});
            // Add as image URL (Gemini uses same file_data format for video)
            try image_paths.append(allocator, file_uri);
        }

        // Add YouTube URLs directly as image paths (Gemini accepts them as file_uri)
        for (youtube_urls.items) |url| {
            try image_paths.append(allocator, url);
        }
    }

    // Apply text template if specified
    var template_system_prompt: ?[]u8 = null;
    defer if (template_system_prompt) |sp| allocator.free(sp);
    var template_user_prompt: ?[]u8 = null;
    defer if (template_user_prompt) |up| allocator.free(up);

    if (text_template_name) |tname| {
        const template = text_templates.findTemplate(tname) orelse {
            std.debug.print("Error: Unknown text template '{s}'\n", .{tname});
            std.debug.print("Use --text-templates to see available templates.\n", .{});
            return error.UnknownTemplate;
        };

        // Build system prompt from template (interpolate params)
        const sys_prompt = try text_templates.buildSystemPrompt(allocator, template, &template_params);

        // Stack with existing --system prompt if both are set
        if (config.system_prompt) |existing| {
            template_system_prompt = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sys_prompt, existing });
            allocator.free(sys_prompt);
        } else {
            template_system_prompt = sys_prompt;
        }
        config.system_prompt = template_system_prompt.?;

        // Wrap user prompt with template prefix/suffix
        if (prompt) |p| {
            template_user_prompt = try text_templates.buildUserPrompt(allocator, template, p, &template_params);
            prompt = template_user_prompt.?;
        }
    }

    var tool = cli.CLI.init(allocator, config);
    defer tool.deinit();

    // Run interactive or one-shot mode
    if (config.interactive) {
        try tool.interactive();
    } else {
        if (prompt) |p| {
            try tool.query(p);
        } else {
            std.debug.print("Error: No prompt provided\n\n", .{});
            cli.printUsage();
            return error.MissingPrompt;
        }
    }
}

/// File management subcommand: zig-ai file upload/list/delete
fn runFileCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printFileHelp();
        return;
    }

    const api_key_ptr = std.c.getenv("XAI_API_KEY");
    if (api_key_ptr == null) {
        std.debug.print("Error: XAI_API_KEY not set\n", .{});
        return;
    }
    const api_key = std.mem.span(api_key_ptr.?);

    var client = try cli.ai.GrokClient.init(allocator, api_key);
    defer client.deinit();

    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "upload")) {
        if (args.len < 4) {
            std.debug.print("Error: 'file upload' requires a file path\n", .{});
            return;
        }
        const path = args[3];

        // Read file
        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const fp = std.c.fopen(path_z.ptr, "rb") orelse {
            std.debug.print("Error: Cannot open file: {s}\n", .{path});
            return;
        };
        defer _ = std.c.fclose(fp);

        _ = fseek(fp, 0, SEEK_END);
        const size_long = ftell(fp);
        if (size_long < 0) {
            std.debug.print("Error: Cannot determine file size\n", .{});
            return;
        }
        _ = fseek(fp, 0, SEEK_SET);
        const size: usize = @intCast(size_long);

        if (size > 48 * 1024 * 1024) {
            std.debug.print("Error: File exceeds 48MB limit\n", .{});
            return;
        }

        const file_data = try allocator.alloc(u8, size);
        defer allocator.free(file_data);
        const read = std.c.fread(file_data.ptr, 1, size, fp);
        if (read != size) {
            std.debug.print("Error: Failed to read file\n", .{});
            return;
        }

        const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;

        const file_id = client.uploadFile(file_data, filename) catch |err| {
            std.debug.print("Error uploading file: {}\n", .{err});
            return;
        };
        defer allocator.free(file_id);

        std.debug.print("{s}\n", .{file_id});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        const response = client.listFiles() catch |err| {
            std.debug.print("Error listing files: {}\n", .{err});
            return;
        };
        defer allocator.free(response);

        // Parse and display
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            response,
            .{ .allocate = .alloc_always },
        ) catch {
            std.debug.print("{s}\n", .{response});
            return;
        };
        defer parsed.deinit();

        if (parsed.value.object.get("data")) |data| {
            if (data == .array) {
                if (data.array.items.len == 0) {
                    std.debug.print("No files uploaded.\n", .{});
                    return;
                }
                std.debug.print("{s:<30} {s:<30} {s:>10}\n", .{ "ID", "Filename", "Size" });
                std.debug.print("{s}\n", .{"-" ** 72});
                for (data.array.items) |item| {
                    const id = if (item.object.get("id")) |v| (if (v == .string) v.string else "?") else "?";
                    const fname = if (item.object.get("filename")) |v| (if (v == .string) v.string else "?") else "?";
                    const bytes: i64 = if (item.object.get("bytes")) |v| (if (v == .integer) v.integer else 0) else 0;
                    std.debug.print("{s:<30} {s:<30} {d:>10}\n", .{ id, fname, bytes });
                }
            }
        } else {
            std.debug.print("{s}\n", .{response});
        }
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        if (args.len < 4) {
            std.debug.print("Error: 'file delete' requires a file ID\n", .{});
            return;
        }
        client.deleteFile(args[3]) catch |err| {
            std.debug.print("Error deleting file: {}\n", .{err});
            return;
        };
        std.debug.print("Deleted: {s}\n", .{args[3]});
    } else {
        std.debug.print("Unknown file command: {s}\n", .{subcmd});
        printFileHelp();
    }
}

/// Gemini file management subcommand: zig-ai gemini-file upload/list/delete/status
fn runGeminiFileCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printGeminiFileHelp();
        return;
    }

    const api_key_ptr = std.c.getenv("GEMINI_API_KEY") orelse std.c.getenv("GOOGLE_GENAI_API_KEY");
    if (api_key_ptr == null) {
        std.debug.print("Error: GEMINI_API_KEY not set\n", .{});
        return;
    }
    const api_key = std.mem.span(api_key_ptr.?);

    var client = try cli.ai.GeminiClient.init(allocator, api_key);
    defer client.deinit();

    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "upload")) {
        if (args.len < 4) {
            std.debug.print("Error: 'gemini-file upload' requires a file path\n", .{});
            return;
        }
        const path = args[3];

        // Read file
        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const fp = std.c.fopen(path_z.ptr, "rb") orelse {
            std.debug.print("Error: Cannot open file: {s}\n", .{path});
            return;
        };
        defer _ = std.c.fclose(fp);

        _ = fseek(fp, 0, SEEK_END);
        const size_long = ftell(fp);
        if (size_long < 0) {
            std.debug.print("Error: Cannot determine file size\n", .{});
            return;
        }
        _ = fseek(fp, 0, SEEK_SET);
        const size: usize = @intCast(size_long);

        const file_data = try allocator.alloc(u8, size);
        defer allocator.free(file_data);
        const read = std.c.fread(file_data.ptr, 1, size, fp);
        if (read != size) {
            std.debug.print("Error: Failed to read file\n", .{});
            return;
        }

        const filename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;
        const mime = cli.ai.common.ImageInput.mimeTypeFromPath(path);

        std.debug.print("Uploading {s} ({d} bytes, {s})...\n", .{ filename, size, mime });
        const result = client.uploadFile(file_data, filename, mime) catch |err| {
            std.debug.print("Error uploading file: {}\n", .{err});
            return;
        };
        defer allocator.free(result);

        std.debug.print("{s}\n", .{result});

        // If still processing, offer to wait
        if (std.mem.startsWith(u8, result, "files/")) {
            std.debug.print("File is still processing. Use 'gemini-file status {s}' to check.\n", .{result});
        }
    } else if (std.mem.eql(u8, subcmd, "status")) {
        if (args.len < 4) {
            std.debug.print("Error: 'gemini-file status' requires a file name (e.g., files/abc123)\n", .{});
            return;
        }
        const json = client.getFileStatus(args[3]) catch |err| {
            std.debug.print("Error getting file status: {}\n", .{err});
            return;
        };
        defer allocator.free(json);

        // Parse and show key fields
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json,
            .{ .allocate = .alloc_always },
        ) catch {
            std.debug.print("{s}\n", .{json});
            return;
        };
        defer parsed.deinit();

        const name = if (parsed.value.object.get("name")) |v| (if (v == .string) v.string else "?") else "?";
        const state = if (parsed.value.object.get("state")) |v| (if (v == .string) v.string else "?") else "?";
        const uri = if (parsed.value.object.get("uri")) |v| (if (v == .string) v.string else "-") else "-";
        const display = if (parsed.value.object.get("displayName")) |v| (if (v == .string) v.string else "-") else "-";
        const mime_type = if (parsed.value.object.get("mimeType")) |v| (if (v == .string) v.string else "-") else "-";

        std.debug.print("Name:     {s}\n", .{name});
        std.debug.print("Display:  {s}\n", .{display});
        std.debug.print("State:    {s}\n", .{state});
        std.debug.print("MIME:     {s}\n", .{mime_type});
        std.debug.print("URI:      {s}\n", .{uri});
    } else if (std.mem.eql(u8, subcmd, "wait")) {
        if (args.len < 4) {
            std.debug.print("Error: 'gemini-file wait' requires a file name (e.g., files/abc123)\n", .{});
            return;
        }
        std.debug.print("Waiting for {s} to become ACTIVE...\n", .{args[3]});
        const uri = client.waitForFile(args[3], 60) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return;
        };
        defer allocator.free(uri);
        std.debug.print("Ready: {s}\n", .{uri});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        const response = client.listFiles() catch |err| {
            std.debug.print("Error listing files: {}\n", .{err});
            return;
        };
        defer allocator.free(response);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            response,
            .{ .allocate = .alloc_always },
        ) catch {
            std.debug.print("{s}\n", .{response});
            return;
        };
        defer parsed.deinit();

        if (parsed.value.object.get("files")) |files| {
            if (files == .array) {
                if (files.array.items.len == 0) {
                    std.debug.print("No files uploaded.\n", .{});
                    return;
                }
                std.debug.print("{s:<30} {s:<20} {s:<12} {s}\n", .{ "Name", "Display Name", "State", "MIME" });
                std.debug.print("{s}\n", .{"-" ** 80});
                for (files.array.items) |item| {
                    const name = if (item.object.get("name")) |v| (if (v == .string) v.string else "?") else "?";
                    const display = if (item.object.get("displayName")) |v| (if (v == .string) v.string else "?") else "?";
                    const state = if (item.object.get("state")) |v| (if (v == .string) v.string else "?") else "?";
                    const mime_type = if (item.object.get("mimeType")) |v| (if (v == .string) v.string else "?") else "?";
                    std.debug.print("{s:<30} {s:<20} {s:<12} {s}\n", .{ name, display, state, mime_type });
                }
            }
        } else {
            std.debug.print("{s}\n", .{response});
        }
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        if (args.len < 4) {
            std.debug.print("Error: 'gemini-file delete' requires a file name (e.g., files/abc123)\n", .{});
            return;
        }
        client.deleteFile(args[3]) catch |err| {
            std.debug.print("Error deleting file: {}\n", .{err});
            return;
        };
        std.debug.print("Deleted: {s}\n", .{args[3]});
    } else {
        std.debug.print("Unknown gemini-file command: {s}\n", .{subcmd});
        printGeminiFileHelp();
    }
}

/// Embeddings subcommand: zig-ai embed [options] "text" ["text2" ...]
fn runEmbedCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printEmbedHelp();
        return;
    }

    const api_key_ptr = std.c.getenv("GEMINI_API_KEY") orelse std.c.getenv("GOOGLE_GENAI_API_KEY");
    if (api_key_ptr == null) {
        std.debug.print("Error: GEMINI_API_KEY not set\n", .{});
        return;
    }
    const api_key = std.mem.span(api_key_ptr.?);

    var client = try cli.ai.GeminiClient.init(allocator, api_key);
    defer client.deinit();

    // Parse options
    var task_type: ?cli.ai.common.EmbeddingTaskType = null;
    var dimensionality: ?u32 = null;
    var json_output = false;
    var texts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer texts.deinit(allocator);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--task") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --task requires a value\n", .{});
                return;
            }
            task_type = cli.ai.common.EmbeddingTaskType.fromString(args[i]);
            if (task_type == null) {
                std.debug.print("Error: Unknown task type '{s}'\n", .{args[i]});
                std.debug.print("Valid: semantic_similarity, classification, clustering,\n", .{});
                std.debug.print("       retrieval_document, retrieval_query, code_retrieval_query,\n", .{});
                std.debug.print("       question_answering, fact_verification\n", .{});
                std.debug.print("Short: similarity, search, document, code, qa, fact\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--dim") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --dim requires a value (128-3072)\n", .{});
                return;
            }
            dimensionality = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid dimension '{s}'\n", .{args[i]});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printEmbedHelp();
            return;
        } else {
            try texts.append(allocator, arg);
        }
    }

    if (texts.items.len == 0) {
        std.debug.print("Error: No text provided\n", .{});
        printEmbedHelp();
        return;
    }

    const results = client.embedContent(texts.items, task_type, dimensionality) catch |err| {
        std.debug.print("Error generating embeddings: {}\n", .{err});
        return;
    };
    defer {
        for (results) |*r| @constCast(r).deinit();
        allocator.free(results);
    }

    if (json_output) {
        // JSON output for programmatic use
        std.debug.print("[", .{});
        for (results, 0..) |result, ri| {
            if (ri > 0) std.debug.print(",", .{});
            std.debug.print("\n  {{\"text\":", .{});
            // Print escaped text
            const escaped = cli.ai.common.escapeJsonString(allocator, texts.items[ri]) catch {
                std.debug.print("\"?\"", .{});
                continue;
            };
            defer allocator.free(escaped);
            std.debug.print("\"{s}\",\"dimensions\":{d},\"values\":[", .{ escaped, result.values.len });
            for (result.values, 0..) |v, vi| {
                if (vi > 0) std.debug.print(",", .{});
                std.debug.print("{d:.8}", .{v});
            }
            std.debug.print("]}}", .{});
        }
        std.debug.print("\n]\n", .{});
    } else {
        // Human-readable output
        for (results, 0..) |result, ri| {
            std.debug.print("Text {d}: \"{s}\"\n", .{ ri + 1, texts.items[ri] });
            std.debug.print("  Dimensions: {d}\n", .{result.values.len});
            std.debug.print("  Values: [", .{});
            const preview = @min(result.values.len, 8);
            for (result.values[0..preview], 0..) |v, vi| {
                if (vi > 0) std.debug.print(", ", .{});
                std.debug.print("{d:.6}", .{v});
            }
            if (result.values.len > preview) {
                std.debug.print(", ... ({d} more)", .{result.values.len - preview});
            }
            std.debug.print("]\n\n", .{});
        }
    }
}

fn printEmbedHelp() void {
    std.debug.print(
        \\
        \\zig-ai embed - Gemini Text Embeddings
        \\
        \\Usage:
        \\  zig-ai embed [options] "text" ["text2" ...]
        \\
        \\Options:
        \\  --task, -t <type>    Task type to optimize embeddings for
        \\  --dim, -d <n>        Output dimensions (128-3072, default: 3072)
        \\  --json               Output as JSON array
        \\  --help               Show this help
        \\
        \\Task types:
        \\  semantic_similarity  Compare text similarity (alias: similarity)
        \\  classification       Classify text by labels
        \\  clustering           Group similar texts
        \\  retrieval_document   Index documents for search (alias: document)
        \\  retrieval_query      Search queries (alias: search)
        \\  code_retrieval_query Code search queries (alias: code)
        \\  question_answering   Q&A matching (alias: qa)
        \\  fact_verification    Fact-checking (alias: fact)
        \\
        \\Examples:
        \\  zig-ai embed "What is the meaning of life?"
        \\  zig-ai embed -t similarity "cats are great" "dogs are wonderful"
        \\  zig-ai embed -t document -d 768 "index this text" --json
        \\  zig-ai embed -t search "find similar documents"
        \\
        \\Model: gemini-embedding-001 (3072 dimensions, MRL-trained)
        \\
    , .{});
}

fn printGeminiFileHelp() void {
    std.debug.print(
        \\
        \\zig-ai gemini-file - Google Gemini Files API
        \\
        \\Usage:
        \\  zig-ai gemini-file upload <path>      Upload a file (PDF, video, audio, etc.)
        \\  zig-ai gemini-file status <name>      Check file processing status
        \\  zig-ai gemini-file wait <name>        Wait for file to become ACTIVE
        \\  zig-ai gemini-file list               List all uploaded files
        \\  zig-ai gemini-file delete <name>      Delete a file
        \\
        \\Chat with videos:
        \\  zig-ai gemini "Describe this video" --video video.mp4
        \\  zig-ai gemini "Summarize" --youtube https://youtube.com/watch?v=xxx
        \\
        \\Supported: PDF, video (mp4/mov/avi/mkv/webm), audio (mp3/wav/flac), images
        \\Max size: 2GB (free tier) or 20GB (paid)
        \\
    , .{});
}

fn printFileHelp() void {
    std.debug.print(
        \\
        \\zig-ai file - xAI File Management
        \\
        \\Usage:
        \\  zig-ai file upload <path>    Upload a file, returns file ID
        \\  zig-ai file list             List uploaded files
        \\  zig-ai file delete <id>      Delete a file by ID
        \\
        \\Chat with files:
        \\  zig-ai "question" --file <path> -p grok     Auto-upload and attach
        \\  zig-ai "question" --file-id <id> -p grok    Attach pre-uploaded file
        \\
        \\Max file size: 48 MB
        \\Supported: .txt, .md, .py, .js, .csv, .json, .pdf, and more
        \\
    , .{});
}
