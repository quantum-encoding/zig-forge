// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! CLI for the Batch API (Anthropic + Gemini + OpenAI + xAI)
//!
//! Usage:
//!   zig-ai batch-api create  <csv-file> [options]   Submit batch
//!   zig-ai batch-api status  <batch-id>             Check status
//!   zig-ai batch-api results <batch-id> [-o file]   Download results
//!   zig-ai batch-api cancel  <batch-id>             Cancel batch
//!   zig-ai batch-api list                           List batches
//!   zig-ai batch-api submit  <csv-file> [options]   Create + poll + download

const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const gemini_client = @import("gemini_client.zig");
const openai_client = @import("openai_client.zig");
const xai_client = @import("xai_client.zig");
const model_costs = @import("../model_costs.zig");

extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

// C stdout access - platform-aware (macOS: __stdoutp, Linux: stdout)
const builtin = @import("builtin");
const c_stdout_ptr = if (builtin.os.tag == .macos)
    &struct {
        extern "c" var __stdoutp: *std.c.FILE;
    }.__stdoutp
else
    &struct {
        extern "c" var stdout: *std.c.FILE;
    }.stdout;

fn getStdout() *std.c.FILE {
    return c_stdout_ptr.*;
}

const POLL_INTERVAL_S: u32 = 30;
const MAX_POLL_ATTEMPTS: u32 = 120; // 1 hour

fn getEnvVarOwned(allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
    const value = std.c.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

/// Auto-detect provider from batch ID format.
/// OpenAI: "batch_...", Gemini: "batches/...", Anthropic: "msgbatch_..." or other
fn detectProvider(batch_id: []const u8) types.BatchProvider {
    if (std.mem.startsWith(u8, batch_id, "batch_")) return .openai;
    if (std.mem.startsWith(u8, batch_id, "batches/")) return .gemini;
    return .anthropic;
}

/// Parse --provider/-p flag from args. Returns provider and whether model was explicitly specified.
const ProviderParseResult = struct {
    provider: types.BatchProvider,
    model_specified: bool,
};

/// Main CLI entry point. args[0] = binary, args[1] = "batch-api", args[2] = subcommand
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printHelp();
        return;
    }

    const subcmd = args[2];
    const sub_args = if (args.len > 3) args[3..] else args[0..0];

    if (std.mem.eql(u8, subcmd, "create")) {
        try runCreate(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try runStatus(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "results")) {
        try runResults(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "cancel")) {
        try runCancel(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try runList(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "submit")) {
        try runSubmit(allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printHelp();
    } else {
        std.debug.print("Error: Unknown subcommand '{s}'\n\n", .{subcmd});
        printHelp();
        return error.UnknownSubcommand;
    }
}

// ---------------------------------------------------------------------------
// Subcommand: create
// ---------------------------------------------------------------------------

fn runCreate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var csv_file: ?[]const u8 = null;
    var config = types.BatchCreateConfig{};
    var provider: types.BatchProvider = .anthropic;
    var model_specified = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return missingValue("--model");
            config.model = args[i];
            model_specified = true;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return missingValue("--max-tokens");
            config.max_tokens = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--temperature") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return missingValue("--temperature");
            config.temperature = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return missingValue("--system");
            config.system_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            csv_file = arg;
        } else {
            std.debug.print("Error: Unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        }
    }

    const file = csv_file orelse {
        std.debug.print("Error: CSV file required\n\n", .{});
        std.debug.print("Usage: zig-ai batch-api create <csv-file> [--provider P] [--model M] [--max-tokens N] [--system S]\n", .{});
        return error.MissingArgument;
    };

    // Use provider default model if not explicitly specified
    if (!model_specified) config.model = provider.getDefaultModel();

    const api_key = getEnvVarOwned(allocator, provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    // Parse CSV
    const rows = try parseBatchCsv(allocator, file);
    defer {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    std.debug.print("Parsed {d} requests from {s}\n", .{ rows.len, file });
    std.debug.print("Provider: {s}, Model: {s}\n", .{ @tagName(provider), config.model });

    // Create batch — dispatch by provider
    std.debug.print("Creating batch...\n", .{});
    switch (provider) {
        .anthropic => {
            const payload = try client.buildBatchPayload(allocator, rows, config);
            defer allocator.free(payload);
            var info = try client.create(allocator, api_key, payload);
            defer info.deinit();
            printBatchInfo(&info);
        },
        .gemini => {
            var info = try gemini_client.create(allocator, api_key, config.model, rows, config);
            defer info.deinit();
            printBatchInfo(&info);
        },
        .openai => {
            std.debug.print("Uploading JSONL file...\n", .{});
            var info = try openai_client.create(allocator, api_key, config.model, rows, config);
            defer info.deinit();
            printBatchInfo(&info);
        },
        .xai => {
            std.debug.print("Creating batch and adding requests...\n", .{});
            var info = try xai_client.create(allocator, api_key, config.model, rows, config);
            defer info.deinit();
            printBatchInfo(&info);
        },
    }
}

// ---------------------------------------------------------------------------
// Subcommand: status
// ---------------------------------------------------------------------------

fn runStatus(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var batch_id: ?[]const u8 = null;
    var provider: ?types.BatchProvider = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            batch_id = arg;
        }
    }

    const bid = batch_id orelse {
        std.debug.print("Error: Batch ID required\n\n", .{});
        std.debug.print("Usage: zig-ai batch-api status <batch-id> [--provider P]\n", .{});
        return error.MissingArgument;
    };

    // Auto-detect provider from batch ID format if not explicit
    const effective_provider = provider orelse detectProvider(bid);

    const api_key = getEnvVarOwned(allocator, effective_provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{effective_provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    var info = switch (effective_provider) {
        .anthropic => try client.getStatus(allocator, api_key, bid),
        .gemini => try gemini_client.getStatus(allocator, api_key, bid),
        .openai => try openai_client.getStatus(allocator, api_key, bid),
        .xai => try xai_client.getStatus(allocator, api_key, bid),
    };
    defer info.deinit();

    printBatchInfo(&info);
}

// ---------------------------------------------------------------------------
// Subcommand: results
// ---------------------------------------------------------------------------

fn runResults(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var batch_id: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var csv_mode = false;
    var provider: ?types.BatchProvider = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return missingValue("--output");
            output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv_mode = true;
        } else if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            batch_id = arg;
        } else {
            std.debug.print("Error: Unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        }
    }

    const bid = batch_id orelse {
        std.debug.print("Error: Batch ID required\n\n", .{});
        std.debug.print("Usage: zig-ai batch-api results <batch-id> [-o file] [--csv] [--provider P]\n", .{});
        return error.MissingArgument;
    };

    const effective_provider = provider orelse detectProvider(bid);

    const api_key = getEnvVarOwned(allocator, effective_provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{effective_provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    std.debug.print("Downloading results for {s}...\n", .{bid});
    const results = switch (effective_provider) {
        .anthropic => try client.getResults(allocator, api_key, bid),
        .gemini => try gemini_client.getResults(allocator, api_key, bid),
        .openai => try openai_client.getResults(allocator, api_key, bid),
        .xai => try xai_client.getResults(allocator, api_key, bid),
    };
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    // Format output
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    if (csv_mode) {
        try output.appendSlice(allocator, "custom_id,status,content,model,input_tokens,output_tokens,error\n");
        for (results) |*r| {
            try formatResultCsv(allocator, &output, r);
        }
    } else {
        for (results) |*r| {
            try formatResultJsonl(allocator, &output, r);
        }
    }

    if (output_file) |path| {
        try writeToFile(allocator, path, output.items);
        std.debug.print("Results written to: {s} ({d} items)\n", .{ path, results.len });
    } else {
        const c_stdout = getStdout();
        _ = std.c.fwrite(output.items.ptr, 1, output.items.len, c_stdout);
        _ = fflush(c_stdout);
    }

    // Summary
    var succeeded: u32 = 0;
    var errored: u32 = 0;
    var total_input: u32 = 0;
    var total_output: u32 = 0;
    for (results) |r| {
        switch (r.result_type) {
            .succeeded => succeeded += 1,
            .errored => errored += 1,
            else => {},
        }
        total_input += r.input_tokens;
        total_output += r.output_tokens;
    }

    const default_model = effective_provider.getDefaultModel();
    const model_name = if (results.len > 0 and results[0].model != null) results[0].model.? else default_model;
    const cost_provider = effective_provider.getCostProvider();
    const cost = model_costs.calculateCost(cost_provider, model_name, total_input, total_output) * 0.5;

    std.debug.print("\nResults summary:\n", .{});
    std.debug.print("  Succeeded: {d}\n", .{succeeded});
    std.debug.print("  Errored:   {d}\n", .{errored});
    std.debug.print("  Tokens:    {d} input / {d} output\n", .{ total_input, total_output });
    std.debug.print("  Est. cost: ${d:.4} (50%% batch discount applied)\n", .{cost});
}

// ---------------------------------------------------------------------------
// Subcommand: cancel
// ---------------------------------------------------------------------------

fn runCancel(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var batch_id: ?[]const u8 = null;
    var provider: ?types.BatchProvider = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            batch_id = arg;
        }
    }

    const bid = batch_id orelse {
        std.debug.print("Error: Batch ID required\n\n", .{});
        std.debug.print("Usage: zig-ai batch-api cancel <batch-id> [--provider P]\n", .{});
        return error.MissingArgument;
    };

    const effective_provider = provider orelse detectProvider(bid);

    const api_key = getEnvVarOwned(allocator, effective_provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{effective_provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    std.debug.print("Canceling batch {s}...\n", .{bid});
    var info = switch (effective_provider) {
        .anthropic => try client.cancel(allocator, api_key, bid),
        .gemini => try gemini_client.cancel(allocator, api_key, bid),
        .openai => try openai_client.cancel(allocator, api_key, bid),
        .xai => try xai_client.cancel(allocator, api_key, bid),
    };
    defer info.deinit();

    printBatchInfo(&info);
}

// ---------------------------------------------------------------------------
// Subcommand: list
// ---------------------------------------------------------------------------

fn runList(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var limit: u32 = 20;
    var provider: types.BatchProvider = .anthropic;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) return missingValue("--limit");
            limit = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--provider") or std.mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        }
    }

    const api_key = getEnvVarOwned(allocator, provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    const batches = switch (provider) {
        .anthropic => try client.listBatches(allocator, api_key, limit),
        .gemini => try gemini_client.listBatches(allocator, api_key, limit),
        .openai => try openai_client.listBatches(allocator, api_key, limit),
        .xai => try xai_client.listBatches(allocator, api_key, limit),
    };
    defer {
        for (batches) |*b| b.deinit();
        allocator.free(batches);
    }

    if (batches.len == 0) {
        std.debug.print("No batches found.\n", .{});
        return;
    }

    // Print table header
    std.debug.print("{s:<40} {s:<14} {s:<8} {s:<8} {s:<8} {s:<8} {s}\n", .{
        "BATCH ID", "STATUS", "OK", "ERR", "CANCEL", "EXPIRE", "CREATED",
    });
    std.debug.print("{s}\n", .{"-" ** 100});

    for (batches) |b| {
        const status = if (b.raw_status) |rs| rs else b.processing_status.toString();
        const date = if (b.created_at.len >= 10) b.created_at[0..10] else b.created_at;
        std.debug.print("{s:<40} {s:<14} {d:<8} {d:<8} {d:<8} {d:<8} {s}\n", .{
            b.id,
            status,
            b.request_counts.succeeded,
            b.request_counts.errored,
            b.request_counts.canceled,
            b.request_counts.expired,
            date,
        });
    }
}

// ---------------------------------------------------------------------------
// Subcommand: submit (all-in-one)
// ---------------------------------------------------------------------------

fn runSubmit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var csv_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var csv_mode = false;
    var config = types.BatchCreateConfig{};
    var provider: types.BatchProvider = .anthropic;
    var model_specified = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return missingValue("--model");
            config.model = args[i];
            model_specified = true;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) return missingValue("--max-tokens");
            config.max_tokens = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--temperature") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return missingValue("--temperature");
            config.temperature = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return missingValue("--system");
            config.system_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return missingValue("--provider");
            provider = types.BatchProvider.fromString(args[i]) orelse {
                std.debug.print("Error: Unknown provider '{s}'. Use 'anthropic', 'gemini', 'openai', or 'xai'\n", .{args[i]});
                return error.UnknownProvider;
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return missingValue("--output");
            output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv_mode = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            csv_file = arg;
        } else {
            std.debug.print("Error: Unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        }
    }

    const file = csv_file orelse {
        std.debug.print("Error: CSV file required\n\n", .{});
        std.debug.print("Usage: zig-ai batch-api submit <csv-file> [--provider P] [options]\n", .{});
        return error.MissingArgument;
    };

    // Use provider default model if not explicitly specified
    if (!model_specified) config.model = provider.getDefaultModel();

    const api_key = getEnvVarOwned(allocator, provider.getEnvVar()) catch {
        std.debug.print("Error: {s} environment variable not set\n", .{provider.getEnvVar()});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    // Step 1: Parse CSV
    const rows = try parseBatchCsv(allocator, file);
    defer {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    std.debug.print("Parsed {d} requests from {s}\n", .{ rows.len, file });
    std.debug.print("Provider: {s}, Model: {s}\n", .{ @tagName(provider), config.model });

    // Step 2: Create batch — dispatch by provider
    std.debug.print("Creating batch...\n", .{});
    const batch_id = switch (provider) {
        .anthropic => blk: {
            const payload = try client.buildBatchPayload(allocator, rows, config);
            defer allocator.free(payload);
            var info = try client.create(allocator, api_key, payload);
            const bid = try allocator.dupe(u8, info.id);
            info.deinit();
            break :blk bid;
        },
        .gemini => blk: {
            var info = try gemini_client.create(allocator, api_key, config.model, rows, config);
            const bid = try allocator.dupe(u8, info.id);
            info.deinit();
            break :blk bid;
        },
        .openai => blk: {
            std.debug.print("Uploading JSONL file...\n", .{});
            var info = try openai_client.create(allocator, api_key, config.model, rows, config);
            const bid = try allocator.dupe(u8, info.id);
            info.deinit();
            break :blk bid;
        },
        .xai => blk: {
            std.debug.print("Creating batch and adding requests...\n", .{});
            var info = try xai_client.create(allocator, api_key, config.model, rows, config);
            const bid = try allocator.dupe(u8, info.id);
            info.deinit();
            break :blk bid;
        },
    };
    defer allocator.free(batch_id);

    std.debug.print("Batch created: {s}\n", .{batch_id});
    std.debug.print("Polling for completion (interval: {d}s, timeout: {d}min)...\n\n", .{
        POLL_INTERVAL_S, POLL_INTERVAL_S * MAX_POLL_ATTEMPTS / 60,
    });

    // Step 3: Poll for completion
    var attempt: u32 = 0;
    while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
        if (attempt > 0) {
            _ = usleep(POLL_INTERVAL_S * 1_000_000);
        }

        var status = switch (provider) {
            .anthropic => try client.getStatus(allocator, api_key, batch_id),
            .gemini => try gemini_client.getStatus(allocator, api_key, batch_id),
            .openai => try openai_client.getStatus(allocator, api_key, batch_id),
            .xai => try xai_client.getStatus(allocator, api_key, batch_id),
        };
        defer status.deinit();

        const elapsed_s = attempt * POLL_INTERVAL_S;
        const mins = elapsed_s / 60;
        const secs = elapsed_s % 60;

        const status_display = if (status.raw_status) |rs| rs else status.processing_status.toString();
        std.debug.print("\rBatch {s}: {s} [{d}/{d} done",
            .{
                batch_id, status_display,
                status.request_counts.succeeded + status.request_counts.errored +
                    status.request_counts.canceled + status.request_counts.expired,
                status.request_counts.total(),
            });
        if (mins > 0) {
            std.debug.print(", {d}m{d}s]  ", .{ mins, secs });
        } else {
            std.debug.print(", {d}s]  ", .{secs});
        }

        if (status.processing_status == .ended) {
            std.debug.print("\n\nBatch complete!\n", .{});
            printBatchInfo(&status);

            // Step 4: Download results
            std.debug.print("\nDownloading results...\n", .{});
            const results = switch (provider) {
                .anthropic => try client.getResults(allocator, api_key, batch_id),
                .gemini => try gemini_client.getResults(allocator, api_key, batch_id),
                .openai => try openai_client.getResults(allocator, api_key, batch_id),
                .xai => try xai_client.getResults(allocator, api_key, batch_id),
            };
            defer {
                for (results) |*r| r.deinit();
                allocator.free(results);
            }

            // Format
            var output: std.ArrayListUnmanaged(u8) = .empty;
            defer output.deinit(allocator);

            if (csv_mode) {
                try output.appendSlice(allocator, "custom_id,status,content,model,input_tokens,output_tokens,error\n");
                for (results) |*r| {
                    try formatResultCsv(allocator, &output, r);
                }
            } else {
                for (results) |*r| {
                    try formatResultJsonl(allocator, &output, r);
                }
            }

            // Write
            const out_path = output_file orelse blk: {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(.REALTIME, &ts);
                break :blk try std.fmt.allocPrint(allocator, "batch_results_{d}.jsonl", .{ts.sec});
            };
            const free_path = output_file == null;
            defer if (free_path) allocator.free(out_path);

            try writeToFile(allocator, out_path, output.items);
            std.debug.print("Results written to: {s} ({d} items)\n", .{ out_path, results.len });

            // Summary
            var total_input: u32 = 0;
            var total_output: u32 = 0;
            for (results) |r| {
                total_input += r.input_tokens;
                total_output += r.output_tokens;
            }
            const cost_provider = provider.getCostProvider();
            const cost = model_costs.calculateCost(cost_provider, config.model, total_input, total_output) * 0.5;
            std.debug.print("  Tokens: {d} input / {d} output\n", .{ total_input, total_output });
            std.debug.print("  Est. cost: ${d:.4} (50%% batch discount)\n", .{cost});

            return;
        }
    }

    std.debug.print("\n\nTimeout: batch did not complete within {d} minutes.\n", .{POLL_INTERVAL_S * MAX_POLL_ATTEMPTS / 60});
    std.debug.print("Check status later: zig-ai batch-api status {s}\n", .{batch_id});
}

// ---------------------------------------------------------------------------
// CSV parser (batch-api format: prompt is required, others optional)
// ---------------------------------------------------------------------------

fn parseBatchCsv(allocator: std.mem.Allocator, file_path: []const u8) ![]types.BatchInputRow {
    const io = std.Io.Threaded.global_single_threaded.io();
    const max_size = 256 * 1024 * 1024; // 256MB max (batch can be large)
    const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(max_size));
    defer allocator.free(content);

    var rows: std.ArrayListUnmanaged(types.BatchInputRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');

    // Parse header
    const header_line = line_iter.next() orelse {
        std.debug.print("Error: Empty CSV file\n", .{});
        return error.InvalidHeader;
    };
    const headers = try parseCsvFields(allocator, header_line);
    defer {
        for (headers) |h| allocator.free(h);
        allocator.free(headers);
    }

    // Find column indices
    var prompt_col: ?usize = null;
    var model_col: ?usize = null;
    var max_tokens_col: ?usize = null;
    var temp_col: ?usize = null;
    var system_col: ?usize = null;
    var custom_id_col: ?usize = null;
    var size_col: ?usize = null;
    var quality_col: ?usize = null;
    var n_col: ?usize = null;

    for (headers, 0..) |header, col| {
        const h = std.mem.trim(u8, header, &std.ascii.whitespace);
        if (std.mem.eql(u8, h, "prompt")) prompt_col = col;
        if (std.mem.eql(u8, h, "model")) model_col = col;
        if (std.mem.eql(u8, h, "max_tokens")) max_tokens_col = col;
        if (std.mem.eql(u8, h, "temperature")) temp_col = col;
        if (std.mem.eql(u8, h, "system_prompt") or std.mem.eql(u8, h, "system")) system_col = col;
        if (std.mem.eql(u8, h, "custom_id")) custom_id_col = col;
        if (std.mem.eql(u8, h, "size")) size_col = col;
        if (std.mem.eql(u8, h, "quality")) quality_col = col;
        if (std.mem.eql(u8, h, "n")) n_col = col;
    }

    if (prompt_col == null) {
        std.debug.print("Error: CSV must have a 'prompt' column\n", .{});
        return error.InvalidHeader;
    }

    // Parse rows
    var row_num: u32 = 1;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const fields = parseCsvFields(allocator, trimmed) catch |err| {
            std.debug.print("Warning: Skipping row {d}: {}\n", .{ row_num, err });
            row_num += 1;
            continue;
        };
        defer {
            for (fields) |f| allocator.free(f);
            allocator.free(fields);
        }

        if (fields.len <= prompt_col.?) {
            std.debug.print("Warning: Skipping row {d}: not enough fields\n", .{row_num});
            row_num += 1;
            continue;
        }

        const prompt_val = std.mem.trim(u8, fields[prompt_col.?], &std.ascii.whitespace);
        if (prompt_val.len == 0) {
            row_num += 1;
            continue;
        }

        var row = types.BatchInputRow{
            .prompt = try allocator.dupe(u8, prompt_val),
            .allocator = allocator,
        };
        errdefer row.deinit();

        if (model_col) |mc| {
            if (mc < fields.len) {
                const v = std.mem.trim(u8, fields[mc], &std.ascii.whitespace);
                if (v.len > 0) row.model = try allocator.dupe(u8, v);
            }
        }
        if (max_tokens_col) |mc| {
            if (mc < fields.len) {
                const v = std.mem.trim(u8, fields[mc], &std.ascii.whitespace);
                if (v.len > 0) row.max_tokens = std.fmt.parseInt(u32, v, 10) catch null;
            }
        }
        if (temp_col) |tc| {
            if (tc < fields.len) {
                const v = std.mem.trim(u8, fields[tc], &std.ascii.whitespace);
                if (v.len > 0) row.temperature = std.fmt.parseFloat(f32, v) catch null;
            }
        }
        if (system_col) |sc| {
            if (sc < fields.len) {
                const v = std.mem.trim(u8, fields[sc], &std.ascii.whitespace);
                if (v.len > 0) row.system_prompt = try allocator.dupe(u8, v);
            }
        }
        if (custom_id_col) |cc| {
            if (cc < fields.len) {
                const v = std.mem.trim(u8, fields[cc], &std.ascii.whitespace);
                if (v.len > 0) row.custom_id = try allocator.dupe(u8, v);
            }
        }
        if (size_col) |sc| {
            if (sc < fields.len) {
                const v = std.mem.trim(u8, fields[sc], &std.ascii.whitespace);
                if (v.len > 0) row.size = try allocator.dupe(u8, v);
            }
        }
        if (quality_col) |qc| {
            if (qc < fields.len) {
                const v = std.mem.trim(u8, fields[qc], &std.ascii.whitespace);
                if (v.len > 0) row.quality = try allocator.dupe(u8, v);
            }
        }
        if (n_col) |nc| {
            if (nc < fields.len) {
                const v = std.mem.trim(u8, fields[nc], &std.ascii.whitespace);
                if (v.len > 0) row.n = std.fmt.parseInt(u8, v, 10) catch null;
            }
        }

        try rows.append(allocator, row);
        row_num += 1;
    }

    if (rows.items.len == 0) {
        std.debug.print("Error: No valid requests found in CSV\n", .{});
        return error.NoValidRequests;
    }

    return rows.toOwnedSlice(allocator);
}

/// Parse CSV fields handling quoted strings
fn parseCsvFields(allocator: std.mem.Allocator, line: []const u8) ![][]u8 {
    var fields: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (fields.items) |f| allocator.free(f);
        fields.deinit(allocator);
    }

    var field: std.ArrayListUnmanaged(u8) = .empty;
    defer field.deinit(allocator);

    var in_quotes = false;
    var idx: usize = 0;

    while (idx < line.len) : (idx += 1) {
        const c = line[idx];
        if (c == '"') {
            if (in_quotes and idx + 1 < line.len and line[idx + 1] == '"') {
                try field.append(allocator, '"');
                idx += 1;
            } else {
                in_quotes = !in_quotes;
            }
        } else if (c == ',' and !in_quotes) {
            try fields.append(allocator, try field.toOwnedSlice(allocator));
            field = .empty;
        } else {
            try field.append(allocator, c);
        }
    }
    try fields.append(allocator, try field.toOwnedSlice(allocator));

    return fields.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Output formatters
// ---------------------------------------------------------------------------

fn formatResultJsonl(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), r: *const types.BatchResultItem) !void {
    try out.appendSlice(allocator, "{\"custom_id\":\"");
    var esc: std.ArrayListUnmanaged(u8) = .empty;
    defer esc.deinit(allocator);
    try client.escapeJsonString(allocator, &esc, r.custom_id);
    try out.appendSlice(allocator, esc.items);
    try out.appendSlice(allocator, "\",\"status\":\"");
    try out.appendSlice(allocator, @tagName(r.result_type));
    try out.append(allocator, '"');

    if (r.content) |c| {
        try out.appendSlice(allocator, ",\"content\":\"");
        esc.items.len = 0;
        try client.escapeJsonString(allocator, &esc, c);
        try out.appendSlice(allocator, esc.items);
        try out.append(allocator, '"');
    }
    if (r.model) |m| {
        try out.appendSlice(allocator, ",\"model\":\"");
        try out.appendSlice(allocator, m);
        try out.append(allocator, '"');
    }
    if (r.input_tokens > 0 or r.output_tokens > 0) {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, ",\"input_tokens\":{d},\"output_tokens\":{d}", .{ r.input_tokens, r.output_tokens }) catch unreachable;
        try out.appendSlice(allocator, s);
    }
    if (r.error_type) |et| {
        try out.appendSlice(allocator, ",\"error_type\":\"");
        try out.appendSlice(allocator, et);
        try out.append(allocator, '"');
    }
    if (r.error_message) |em| {
        try out.appendSlice(allocator, ",\"error_message\":\"");
        esc.items.len = 0;
        try client.escapeJsonString(allocator, &esc, em);
        try out.appendSlice(allocator, esc.items);
        try out.append(allocator, '"');
    }

    try out.appendSlice(allocator, "}\n");
}

fn formatResultCsv(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), r: *const types.BatchResultItem) !void {
    // custom_id
    try appendCsvField(allocator, out, r.custom_id);
    try out.append(allocator, ',');
    // status
    try out.appendSlice(allocator, @tagName(r.result_type));
    try out.append(allocator, ',');
    // content
    if (r.content) |c| {
        try appendCsvField(allocator, out, c);
    }
    try out.append(allocator, ',');
    // model
    if (r.model) |m| {
        try out.appendSlice(allocator, m);
    }
    try out.append(allocator, ',');
    // input_tokens
    var buf: [16]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, "{d}", .{r.input_tokens}) catch unreachable;
    try out.appendSlice(allocator, s);
    try out.append(allocator, ',');
    // output_tokens
    s = std.fmt.bufPrint(&buf, "{d}", .{r.output_tokens}) catch unreachable;
    try out.appendSlice(allocator, s);
    try out.append(allocator, ',');
    // error
    if (r.error_message) |em| {
        try appendCsvField(allocator, out, em);
    }
    try out.append(allocator, '\n');
}

fn appendCsvField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    var needs_quotes = false;
    for (field) |c| {
        if (c == '"' or c == ',' or c == '\n' or c == '\r') {
            needs_quotes = true;
            break;
        }
    }
    if (needs_quotes) {
        try out.append(allocator, '"');
        for (field) |c| {
            if (c == '"') try out.append(allocator, '"');
            try out.append(allocator, c);
        }
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, field);
    }
}

// ---------------------------------------------------------------------------
// File I/O
// ---------------------------------------------------------------------------

fn writeToFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var io_impl = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    defer io_impl.deinit();
    const io = io_impl.io();

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

fn printBatchInfo(info: *const types.BatchInfo) void {
    std.debug.print("\n  Batch ID:    {s}\n", .{info.id});
    const status_display = if (info.raw_status) |rs| rs else info.processing_status.toString();
    std.debug.print("  Status:      {s}\n", .{status_display});
    std.debug.print("  Provider:    {s}\n", .{@tagName(info.provider)});
    std.debug.print("  Created:     {s}\n", .{info.created_at});
    if (info.ended_at) |ea| {
        std.debug.print("  Ended:       {s}\n", .{ea});
    }
    std.debug.print("  Expires:     {s}\n", .{info.expires_at});
    std.debug.print("  Requests:    processing={d} succeeded={d} errored={d} canceled={d} expired={d}\n", .{
        info.request_counts.processing,
        info.request_counts.succeeded,
        info.request_counts.errored,
        info.request_counts.canceled,
        info.request_counts.expired,
    });
    if (info.results_url) |ru| {
        std.debug.print("  Results URL: {s}\n", .{ru});
    }
    std.debug.print("\n", .{});
}

fn missingValue(opt: []const u8) error{MissingArgument} {
    std.debug.print("Error: {s} requires a value\n", .{opt});
    return error.MissingArgument;
}

pub fn printHelp() void {
    std.debug.print(
        \\Batch API — 50%% cost reduction for async processing (Anthropic + Gemini + OpenAI + xAI)
        \\
        \\Usage: zig-ai batch-api <command> [options]
        \\
        \\Commands:
        \\  create  <csv-file>  Create a new batch from CSV file
        \\  status  <batch-id>  Check batch processing status
        \\  results <batch-id>  Download batch results
        \\  cancel  <batch-id>  Cancel an in-progress batch
        \\  list                List recent batches
        \\  submit  <csv-file>  Create, poll, and download results (all-in-one)
        \\
        \\Provider selection:
        \\  --provider, -p <name>   Provider: anthropic (default), gemini, openai, xai
        \\                          Auto-detected from batch ID for status/results/cancel:
        \\                            batch_...    → openai (use --provider xai for xAI)
        \\                            batches/...  → gemini
        \\                            msgbatch_... → anthropic
        \\
        \\Options for create/submit:
        \\  --model, -m <model>     Model (default: provider-specific)
        \\  --max-tokens <n>        Max output tokens per request (default: 4096)
        \\  --temperature, -t <f>   Temperature
        \\  --system, -s <prompt>   Shared system prompt for all requests
        \\
        \\Options for results/submit:
        \\  -o, --output <file>     Output file path
        \\  --csv                   Output as CSV instead of JSONL
        \\
        \\Options for list:
        \\  --limit <n>             Number of batches to show (default: 20)
        \\
        \\CSV Format (text):
        \\  Required column: prompt
        \\  Optional columns: model, max_tokens, temperature, system_prompt, custom_id
        \\
        \\  Example (minimal):
        \\    prompt
        \\    "What is quantum computing?"
        \\    "Explain the Zig programming language"
        \\
        \\CSV Format (OpenAI images — use --model gpt-image-1):
        \\  Required column: prompt
        \\  Optional columns: size, quality, n, custom_id
        \\
        \\  Example:
        \\    prompt,size,quality
        \\    "A sunset over mountains",1024x1024,hd
        \\    "Abstract geometric patterns",1024x1536,standard
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY    Required for --provider anthropic (default)
        \\  GEMINI_API_KEY       Required for --provider gemini
        \\  OPENAI_API_KEY       Required for --provider openai
        \\  XAI_API_KEY          Required for --provider xai
        \\
        \\Pricing (50%% batch discount applied):
        \\  Anthropic:
        \\    Haiku 4.5:  $0.50/$2.50 per MTok
        \\    Sonnet 4.5: $1.50/$7.50 per MTok
        \\    Opus 4.6:   $2.50/$12.50 per MTok
        \\  Gemini:
        \\    Flash 2.5:  $0.15/$1.25 per MTok
        \\    Pro 2.5:    $1.25/$7.50 per MTok
        \\    Flash 3:    $0.15/$1.25 per MTok
        \\    Pro 3:      $1.25/$7.50 per MTok
        \\  OpenAI:
        \\    GPT-4.1 Mini: $0.20/$0.40 per MTok
        \\    GPT-4.1:      $1.00/$2.00 per MTok
        \\    GPT-5.2:      (uses Responses API)
        \\    GPT-Image-*:  (image batches, 24h window)
        \\  xAI:
        \\    Grok 4.1 Fast: $2.50/$5.00 per MTok
        \\    Grok 4:        (check xAI pricing page)
        \\
    , .{});
}
