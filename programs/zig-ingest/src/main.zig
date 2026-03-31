//! Zig Ingest CLI - Thin wrapper over the zig-ingest library
//!
//! Parses Zig source files, extracts functions and call graphs,
//! and inserts them into SurrealDB for querying.
//!
//! Usage:
//!   zig-ingest <source-dir> [options]

const std = @import("std");
const lib = @import("lib.zig");
const ZigIngest = lib.ZigIngest;
const Config = lib.types.Config;

fn printUsage() void {
    std.debug.print(
        \\zig-ingest - Zig Code Graph Ingestion Engine
        \\
        \\USAGE:
        \\  zig-ingest <source-dir> [options]
        \\
        \\OPTIONS:
        \\  --db <name>       Database name (default: stdlib_016)
        \\  --ns <name>       Namespace (default: zig)
        \\  --url <url>       SurrealDB URL (default: http://127.0.0.1:8000/sql)
        \\  --dry-run         Parse only, don't insert to DB
        \\  --verbose, -v     Show detailed progress
        \\  --help, -h        Show this help
        \\
        \\EXAMPLES:
        \\  zig-ingest /usr/local/zig/lib/std --verbose
        \\  zig-ingest ./src --db my_project --dry-run
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse arguments
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var cfg: Config = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            i += 1;
            cfg.db = args[i];
        } else if (std.mem.eql(u8, arg, "--ns") and i + 1 < args.len) {
            i += 1;
            cfg.ns = args[i];
        } else if (std.mem.eql(u8, arg, "--url") and i + 1 < args.len) {
            i += 1;
            cfg.url = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            cfg.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            cfg.verbose = true;
        } else if (arg[0] != '-') {
            cfg.source_dir = arg;
        }
    }

    if (cfg.source_dir.len == 0) {
        printUsage();
        return;
    }

    std.debug.print("\n=== Zig Ingest ===\n", .{});
    std.debug.print("Source: {s}\n", .{cfg.source_dir});
    std.debug.print("Target: {s} -> {s}.{s}\n", .{ cfg.url, cfg.ns, cfg.db });
    if (cfg.dry_run) {
        std.debug.print("Mode: DRY RUN (no database writes)\n", .{});
    }
    std.debug.print("\n", .{});

    // Initialize library
    var zi = ZigIngest.init(allocator, cfg, init.minimal.environ) catch |err| {
        std.debug.print("Error: Failed to initialize: {s}\n", .{@errorName(err)});
        return;
    };
    defer zi.deinit();

    // Run ingestion
    std.debug.print("Phase 1: Parsing source files...\n", .{});
    const result = zi.ingestDirectory(cfg.source_dir) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("\nParsing complete:\n", .{});
    std.debug.print("  Files processed: {d}\n", .{result.stats.files_processed});
    std.debug.print("  Functions found: {d}\n", .{result.stats.functions_found});
    std.debug.print("  Call edges found: {d}\n", .{result.stats.calls_found});
    std.debug.print("  Parse errors: {d}\n", .{result.stats.parse_errors});

    if (cfg.dry_run) {
        std.debug.print("\nDry run complete. No data inserted.\n", .{});
        return;
    }

    std.debug.print("\n=== Ingestion Complete ===\n", .{});
    std.debug.print("  Total functions: {d}\n", .{result.functions_inserted});
    std.debug.print("  Total call edges: {d}\n", .{result.calls_inserted});
    std.debug.print("  Insert errors: {d}\n", .{result.stats.insert_errors});
}
