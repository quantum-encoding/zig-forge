//! Zig Code Query - CLI for Zig Standard Library Exploration + Knowledge Ingestion
//!
//! Thin CLI wrapper over the zig-code-query library.

const std = @import("std");
const lib = @import("lib.zig");
const types = lib.types;
const CodeQuery = lib.CodeQuery;

// =============================================================================
// Terminal Colors
// =============================================================================

const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const magenta = "\x1b[35m";
    const blue = "\x1b[34m";
};

// =============================================================================
// Display Helpers
// =============================================================================

fn printFunctionRecords(items: []const types.FunctionRecord) void {
    for (items) |item| {
        std.debug.print("  {s}{s}{s} @ {s}{s}:{d}{s}\n", .{
            Color.cyan,
            item.name,
            Color.reset,
            Color.dim,
            item.file,
            item.line_start,
            Color.reset,
        });
    }
}

fn printCallRecords(items: []const types.CallRecord, prefix: []const u8, color: []const u8) void {
    var count: usize = 0;
    for (items) |item| {
        if (count >= 20) {
            std.debug.print("  {s}... and {d} more{s}\n", .{ Color.dim, items.len - 20, Color.reset });
            break;
        }
        std.debug.print("  {s}{s}{s} {s}{s}{s} @ {s}{s}:{d}{s}\n", .{
            Color.dim,
            prefix,
            Color.reset,
            color,
            item.name,
            Color.reset,
            Color.dim,
            item.file,
            item.line_start,
            Color.reset,
        });
        count += 1;
    }
}

// =============================================================================
// Commands
// =============================================================================

fn cmdFind(cq: *CodeQuery, term: []const u8) void {
    var result = cq.find(term) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}No functions found matching '{s}'{s}\n", .{ Color.dim, term, Color.reset });
        return;
    }

    std.debug.print("\n{s}Found {d} functions matching '{s}':{s}\n\n", .{
        Color.green, result.total_count, term, Color.reset,
    });
    printFunctionRecords(result.items);
    std.debug.print("\n", .{});
}

fn cmdContext(cq: *CodeQuery, name: []const u8) void {
    var result = cq.context(name) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (!result.found) {
        std.debug.print("{s}Function '{s}' not found{s}\n", .{ Color.red, name, Color.reset });
        return;
    }

    std.debug.print("\n{s}{s}=== {s} ==={s}\n", .{ Color.bold, Color.cyan, result.func.name, Color.reset });
    std.debug.print("{s}Location:{s} {s}:{d}\n\n", .{ Color.dim, Color.reset, result.func.file, result.func.line_start });

    if (result.callees.len > 0) {
        std.debug.print("{s}Calls ({d}):{s}\n", .{ Color.yellow, result.callees.len, Color.reset });
        printCallRecords(result.callees, "->", Color.green);
        std.debug.print("\n", .{});
    }

    if (result.callers.len > 0) {
        std.debug.print("{s}Called by ({d}):{s}\n", .{ Color.magenta, result.callers.len, Color.reset });
        printCallRecords(result.callers, "<-", Color.magenta);
    }

    std.debug.print("\n", .{});
}

fn cmdFile(cq: *CodeQuery, path: []const u8) void {
    var result = cq.fileQuery(path) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}No functions found in '{s}'{s}\n", .{ Color.dim, path, Color.reset });
        return;
    }

    std.debug.print("\n{s}Found {d} functions in modules matching '{s}':{s}\n\n", .{
        Color.green, result.total_count, path, Color.reset,
    });

    var current_file: []const u8 = "";
    for (result.items) |item| {
        if (!std.mem.eql(u8, item.file, current_file)) {
            if (current_file.len > 0) std.debug.print("\n", .{});
            std.debug.print("{s}{s}{s}\n", .{ Color.blue, item.file, Color.reset });
            current_file = item.file;
        }
        std.debug.print("  {s}:{d}{s} {s}{s}{s}\n", .{
            Color.dim, item.line_start, Color.reset,
            Color.cyan, item.name, Color.reset,
        });
    }
    std.debug.print("\n", .{});
}

fn cmdCallers(cq: *CodeQuery, name: []const u8) void {
    var result = cq.callers(name) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}No callers found for '{s}'{s}\n", .{ Color.dim, name, Color.reset });
        return;
    }

    std.debug.print("\n{s}Functions that call '{s}' ({d}):{s}\n\n", .{
        Color.magenta, name, result.total_count, Color.reset,
    });
    printCallRecords(result.items, "<-", Color.magenta);
    std.debug.print("\n", .{});
}

fn cmdCallees(cq: *CodeQuery, name: []const u8) void {
    var result = cq.callees(name) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}'{s}' doesn't call any other functions{s}\n", .{ Color.dim, name, Color.reset });
        return;
    }

    std.debug.print("\n{s}Functions called by '{s}' ({d}):{s}\n\n", .{
        Color.green, name, result.total_count, Color.reset,
    });
    printCallRecords(result.items, "->", Color.green);
    std.debug.print("\n", .{});
}

fn cmdStats(cq: *CodeQuery) void {
    const s = cq.stats() catch |err| {
        printError(err);
        return;
    };

    std.debug.print("\n{s}{s}Zig Standard Library Database{s}\n", .{ Color.bold, Color.cyan, Color.reset });
    std.debug.print("{s}================================{s}\n\n", .{ Color.dim, Color.reset });
    std.debug.print("  {s}Functions:{s}  {s}{d}{s}\n", .{ Color.dim, Color.reset, Color.green, s.function_count, Color.reset });
    std.debug.print("  {s}Call Edges:{s} {s}{d}{s}\n", .{ Color.dim, Color.reset, Color.yellow, s.edge_count, Color.reset });
    std.debug.print("  {s}Documents:{s}  {s}{d}{s}\n", .{ Color.dim, Color.reset, Color.blue, s.document_count, Color.reset });
    std.debug.print("  {s}Chunks:{s}     {s}{d}{s}\n", .{ Color.dim, Color.reset, Color.blue, s.chunk_count, Color.reset });
    std.debug.print("  {s}Namespace:{s}  {s}{s}{s}\n", .{ Color.dim, Color.reset, Color.blue, s.ns, Color.reset });
    std.debug.print("  {s}Database:{s}   {s}{s}{s}\n", .{ Color.dim, Color.reset, Color.blue, s.db, Color.reset });
    std.debug.print("\n", .{});
}

fn cmdIngest(cq: *CodeQuery, path: []const u8) void {
    // Ensure schema exists
    cq.ensureSchema() catch |err| {
        std.debug.print("{s}Error:{s} Failed to ensure schema: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
        return;
    };

    const result = cq.ingestFile(path, .{}) catch |err| {
        printError(err);
        return;
    };

    std.debug.print("\n{s}Ingestion complete:{s}\n", .{ Color.green, Color.reset });
    std.debug.print("  Documents created: {s}{d}{s}\n", .{ Color.cyan, result.documents_created, Color.reset });
    std.debug.print("  Chunks created:    {s}{d}{s}\n", .{ Color.cyan, result.chunks_created, Color.reset });
    if (result.documents_skipped > 0) {
        std.debug.print("  Skipped (same):    {s}{d}{s}\n", .{ Color.dim, result.documents_skipped, Color.reset });
    }
    if (result.errors > 0) {
        std.debug.print("  Errors:            {s}{d}{s}\n", .{ Color.red, result.errors, Color.reset });
    }
    std.debug.print("\n", .{});
}

fn cmdIngestFolder(cq: *CodeQuery, path: []const u8) void {
    cq.ensureSchema() catch |err| {
        std.debug.print("{s}Error:{s} Failed to ensure schema: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
        return;
    };

    const result = cq.ingestFolder(path, .{}) catch |err| {
        printError(err);
        return;
    };

    std.debug.print("\n{s}Folder ingestion complete:{s}\n", .{ Color.green, Color.reset });
    std.debug.print("  Documents created: {s}{d}{s}\n", .{ Color.cyan, result.documents_created, Color.reset });
    std.debug.print("  Chunks created:    {s}{d}{s}\n", .{ Color.cyan, result.chunks_created, Color.reset });
    if (result.documents_skipped > 0) {
        std.debug.print("  Skipped (same):    {s}{d}{s}\n", .{ Color.dim, result.documents_skipped, Color.reset });
    }
    if (result.errors > 0) {
        std.debug.print("  Errors:            {s}{d}{s}\n", .{ Color.red, result.errors, Color.reset });
    }
    std.debug.print("\n", .{});
}

fn cmdDocuments(cq: *CodeQuery) void {
    var result = cq.listDocuments() catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}No documents ingested yet{s}\n", .{ Color.dim, Color.reset });
        return;
    }

    std.debug.print("\n{s}Ingested documents ({d}):{s}\n\n", .{ Color.green, result.total_count, Color.reset });
    for (result.items) |doc| {
        std.debug.print("  {s}{s}{s} ({s}{d} bytes{s}) {s}[{s}]{s}\n", .{
            Color.cyan,  doc.path, Color.reset,
            Color.dim,   doc.size, Color.reset,
            Color.yellow, doc.content_hash, Color.reset,
        });
    }
    std.debug.print("\n", .{});
}

fn cmdSearch(cq: *CodeQuery, term: []const u8) void {
    var result = cq.searchChunks(term) catch |err| {
        printError(err);
        return;
    };
    defer result.deinit();

    if (result.total_count == 0) {
        std.debug.print("{s}No chunks found matching '{s}'{s}\n", .{ Color.dim, term, Color.reset });
        return;
    }

    std.debug.print("\n{s}Found {d} chunks matching '{s}':{s}\n\n", .{
        Color.green, result.total_count, term, Color.reset,
    });

    for (result.items) |chunk| {
        std.debug.print("{s}--- {s} (chunk {d}, offset {d}) ---{s}\n", .{
            Color.blue, chunk.document_id, chunk.chunk_index, chunk.byte_offset, Color.reset,
        });
        // Print first 200 chars of content
        const preview_len = @min(chunk.content.len, 200);
        std.debug.print("{s}{s}{s}", .{ Color.dim, chunk.content[0..preview_len], Color.reset });
        if (chunk.content.len > 200) {
            std.debug.print("...", .{});
        }
        std.debug.print("\n\n", .{});
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Read an environment variable via libc, returning null for unset/empty.
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    if (std.c.getenv(name)) |ptr| {
        const s = std.mem.span(ptr);
        if (s.len > 0) return s;
    }
    return null;
}

/// True if the URL points at the loopback interface (dev-only default creds
/// are tolerated there but warned about anywhere else).
fn isLoopbackUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "127.0.0.1") != null or
        std.mem.indexOf(u8, url, "localhost") != null or
        std.mem.indexOf(u8, url, "[::1]") != null or
        std.mem.indexOf(u8, url, "//::1") != null;
}

/// Build the SurrealDB connection config, letting ZCQ_* environment variables
/// override the baked-in localhost/root:root defaults so the CLI is not
/// hardwired to a single credential. `ZCQ_AUTH` supplies a full Authorization
/// header value; alternatively `ZCQ_USER`/`ZCQ_PASS` are base64-encoded into a
/// Basic header. Strings live for the process lifetime (env memory or a
/// deliberate one-shot leak of the encoded header), which is fine for a CLI.
fn resolveConfig(allocator: std.mem.Allocator) types.Config {
    var cfg = types.Config{};

    if (getEnv("ZCQ_URL")) |v| cfg.url = v;
    if (getEnv("ZCQ_NS")) |v| cfg.ns = v;
    if (getEnv("ZCQ_DB")) |v| cfg.db = v;

    var auth_overridden = false;
    if (getEnv("ZCQ_AUTH")) |v| {
        cfg.auth = v;
        auth_overridden = true;
    } else if (getEnv("ZCQ_USER")) |user| {
        const pass = getEnv("ZCQ_PASS") orelse "";
        const raw = std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, pass }) catch null;
        if (raw) |r| {
            defer allocator.free(r);
            const enc = std.base64.standard.Encoder;
            const b64 = allocator.alloc(u8, enc.calcSize(r.len)) catch null;
            if (b64) |bb| {
                defer allocator.free(bb);
                const encoded = enc.encode(bb, r);
                if (std.fmt.allocPrint(allocator, "Basic {s}", .{encoded})) |header| {
                    cfg.auth = header; // intentionally kept for process lifetime
                    auth_overridden = true;
                } else |_| {}
            }
        }
    }

    if (!auth_overridden and !isLoopbackUrl(cfg.url)) {
        std.debug.print(
            "{s}Warning:{s} using default root:root credentials against non-loopback URL '{s}'. Set ZCQ_AUTH (or ZCQ_USER/ZCQ_PASS) to override.\n",
            .{ Color.yellow, Color.reset, cfg.url },
        );
    }

    return cfg;
}

fn printError(err: anyerror) void {
    std.debug.print("{s}Error:{s} {s}\n", .{ Color.red, Color.reset, @errorName(err) });
    if (err == lib.surreal.SurrealError.ConnectionFailed) {
        std.debug.print("{s}Is SurrealDB running? Try: surreal start --user root --pass root{s}\n", .{ Color.dim, Color.reset });
    }
}

fn printUsage() void {
    std.debug.print(
        \\
        \\{s}zig-code-query{s} - Zig Standard Library Explorer + Knowledge Base
        \\
        \\{s}USAGE:{s}
        \\  zig-code-query <command> [args]
        \\
        \\{s}QUERY COMMANDS:{s}
        \\  {s}find{s} <term>            Search functions by name
        \\  {s}context{s} <name>         Full call graph context (callers + callees)
        \\  {s}file{s} <path>            List functions in a module
        \\  {s}callers{s} <name>         Who calls this function?
        \\  {s}callees{s} <name>         What does this function call?
        \\  {s}stats{s}                  Database statistics
        \\
        \\{s}KNOWLEDGE COMMANDS:{s}
        \\  {s}ingest{s} <path>          Ingest a file into the knowledge base
        \\  {s}ingest-folder{s} <path>   Ingest all files in a folder (recursive)
        \\  {s}documents{s}              List all ingested documents
        \\  {s}search{s} <term>          Search across ingested knowledge chunks
        \\
        \\{s}EXAMPLES:{s}
        \\  zig-code-query find hash
        \\  zig-code-query context Keccak
        \\  zig-code-query file crypto/sha3
        \\  zig-code-query ingest /path/to/api_docs.md
        \\  zig-code-query ingest-folder /path/to/docs
        \\  zig-code-query search "api endpoint"
        \\
        \\
    , .{
        Color.bold ++ Color.cyan, Color.reset,
        Color.yellow,             Color.reset,
        Color.yellow,             Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.yellow,             Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.green,              Color.reset,
        Color.yellow,             Color.reset,
    });
}

// =============================================================================
// Main
// =============================================================================

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

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    // Initialize library (ZCQ_* env vars override the baked defaults).
    var cq = CodeQuery.init(allocator, resolveConfig(allocator), init.minimal.environ) catch |err| {
        std.debug.print("{s}Error:{s} Failed to initialize: {s}\n", .{ Color.red, Color.reset, @errorName(err) });
        return;
    };
    defer cq.deinit();

    if (std.mem.eql(u8, cmd, "find")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing search term\nUsage: zig-code-query find <term>\n", .{ Color.red, Color.reset });
            return;
        }
        cmdFind(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "context")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing function name\n", .{ Color.red, Color.reset });
            return;
        }
        cmdContext(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "file")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing file path\n", .{ Color.red, Color.reset });
            return;
        }
        cmdFile(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "callers")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing function name\n", .{ Color.red, Color.reset });
            return;
        }
        cmdCallers(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "callees")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing function name\n", .{ Color.red, Color.reset });
            return;
        }
        cmdCallees(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "stats")) {
        cmdStats(&cq);
    } else if (std.mem.eql(u8, cmd, "ingest")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing file path\nUsage: zig-code-query ingest <path>\n", .{ Color.red, Color.reset });
            return;
        }
        cmdIngest(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "ingest-folder")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing folder path\nUsage: zig-code-query ingest-folder <path>\n", .{ Color.red, Color.reset });
            return;
        }
        cmdIngestFolder(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "documents")) {
        cmdDocuments(&cq);
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} Missing search term\nUsage: zig-code-query search <term>\n", .{ Color.red, Color.reset });
            return;
        }
        cmdSearch(&cq, args[2]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else {
        std.debug.print("{s}Unknown command:{s} {s}\n", .{ Color.red, Color.reset, cmd });
        printUsage();
    }
}
