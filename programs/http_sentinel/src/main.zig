// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! AI Providers CLI - Main Entry Point

const std = @import("std");
const cli = @import("cli.zig");
const batch = @import("batch.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

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
        var executor = try batch.BatchExecutor.init(allocator, requests, batch_config, init.environ_map);
        defer executor.deinit();

        try executor.execute();

        // Write results
        const results = try executor.getResults();
        try batch.writeResults(allocator, results, output_file, batch_full_responses);

        return;
    }

    // Check if API key is set
    const env_var = config.provider.getEnvVar();
    const has_key = init.environ_map.get(env_var) != null;
    if (!has_key) {
        std.debug.print("Error: {s} environment variable not set\n", .{env_var});
        std.debug.print("\n   Set it with:\n", .{});
        std.debug.print("   export {s}=your_api_key_here\n\n", .{env_var});
        return error.MissingApiKey;
    }

    var tool = cli.CLI.init(allocator, config, init.environ_map);

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
