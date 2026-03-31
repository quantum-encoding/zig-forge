//! Directory Walking + Database Insertion
//!
//! Walks directories of Zig source files, parses them via parser.zig,
//! and inserts the resulting function/call records into SurrealDB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const parser = @import("parser.zig");
const surreal = @import("surreal.zig");
const FunctionInfo = types.FunctionInfo;
const CallEdge = types.CallEdge;
const Config = types.Config;
const SurrealClient = surreal.SurrealClient;

const FunctionList = std.ArrayList(FunctionInfo);
const CallList = std.ArrayList(CallEdge);

pub const WalkResult = struct {
    functions: FunctionList,
    calls: CallList,
    stats: types.IngestStats,

    pub fn deinit(self: *WalkResult, allocator: Allocator) void {
        for (self.functions.items) |func| {
            allocator.free(func.name);
            allocator.free(func.file);
            allocator.free(func.qualified_id);
            allocator.free(func.code);
        }
        self.functions.deinit(allocator);

        for (self.calls.items) |call| {
            allocator.free(call.caller_id);
            allocator.free(call.caller_name);
            allocator.free(call.callee);
        }
        self.calls.deinit(allocator);
    }
};

/// Walk a directory tree, parsing all .zig files and collecting functions + calls.
pub fn walkDirectory(
    allocator: Allocator,
    io: std.Io,
    dir_path: []const u8,
    relative_base: []const u8,
    verbose: bool,
) !WalkResult {
    var all_functions: FunctionList = .empty;
    var all_calls: CallList = .empty;
    var walk_stats: types.IngestStats = .{};

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open directory {s}: {s}\n", .{ dir_path, @errorName(err) });
        return error.DirOpenFailed;
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return error.WalkFailed;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        // Build full path and relative path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(full_path);

        const relative_path = if (relative_base.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_base, entry.path })
        else
            try allocator.dupe(u8, entry.path);
        defer allocator.free(relative_path);

        if (verbose) {
            std.debug.print("  Parsing: {s}\n", .{relative_path});
        }

        var result = parser.parseFile(allocator, io, full_path, relative_path, verbose) catch |err| {
            if (err == error.ParseFailed) {
                walk_stats.parse_errors += 1;
            }
            if (verbose) {
                std.debug.print("    Error: {s}\n", .{@errorName(err)});
            }
            continue;
        };

        walk_stats.files_processed += 1;
        walk_stats.functions_found += result.functions.items.len;
        walk_stats.calls_found += result.calls.items.len;

        // Transfer ownership
        for (result.functions.items) |func| {
            try all_functions.append(allocator, func);
        }
        result.functions.deinit(allocator);

        for (result.calls.items) |call| {
            try all_calls.append(allocator, call);
        }
        result.calls.deinit(allocator);
    }

    return .{ .functions = all_functions, .calls = all_calls, .stats = walk_stats };
}

/// Insert functions into SurrealDB in batches.
pub fn insertFunctions(
    allocator: Allocator,
    client: *SurrealClient,
    functions: []const FunctionInfo,
    dry_run: bool,
    verbose: bool,
) !usize {
    var inserted: usize = 0;
    var insert_errors: usize = 0;
    const batch_size: usize = 100;

    var i: usize = 0;
    while (i < functions.len) {
        const end = @min(i + batch_size, functions.len);
        const batch = functions[i..end];

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);

        for (batch) |func| {
            const escaped_code = try types.escapeString(allocator, func.code);
            defer allocator.free(escaped_code);

            const stmt = try std.fmt.allocPrint(allocator,
                \\CREATE code_function:`{s}` SET
                \\  name = '{s}',
                \\  file = '{s}',
                \\  qualified_id = '{s}',
                \\  line_start = {d},
                \\  line_end = {d},
                \\  code = '{s}',
                \\  language = 'zig';
                \\
            , .{ func.qualified_id, func.name, func.file, func.qualified_id, func.line_start, func.line_end, escaped_code });
            defer allocator.free(stmt);

            try sql.appendSlice(allocator, stmt);
        }

        if (!dry_run) {
            const response = client.executeQuery(sql.items) catch |err| {
                if (verbose) {
                    std.debug.print("Insert error: {s}\n", .{@errorName(err)});
                }
                insert_errors += 1;
                i = end;
                continue;
            };
            allocator.free(response);
        }

        inserted += batch.len;
        i = end;

        if (verbose and inserted % 500 == 0) {
            std.debug.print("  Inserted {d} functions...\n", .{inserted});
        }
    }

    return inserted;
}

/// Insert call edges into SurrealDB in batches.
pub fn insertCalls(
    allocator: Allocator,
    client: *SurrealClient,
    calls: []const CallEdge,
    dry_run: bool,
    verbose: bool,
) !usize {
    var inserted: usize = 0;
    var insert_errors: usize = 0;
    const batch_size: usize = 200;

    var i: usize = 0;
    while (i < calls.len) {
        const end = @min(i + batch_size, calls.len);
        const batch = calls[i..end];

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);

        for (batch) |call| {
            const stmt = try std.fmt.allocPrint(allocator,
                \\RELATE code_function:`{s}`->code_calls->code_function:`{s}`;
                \\
            , .{ call.caller_id, call.callee });
            defer allocator.free(stmt);

            try sql.appendSlice(allocator, stmt);
        }

        if (!dry_run) {
            const response = client.executeQuery(sql.items) catch |err| {
                if (verbose) {
                    std.debug.print("Insert call error: {s}\n", .{@errorName(err)});
                }
                insert_errors += 1;
                i = end;
                continue;
            };
            allocator.free(response);
        }

        inserted += batch.len;
        i = end;

        if (verbose and inserted % 1000 == 0) {
            std.debug.print("  Inserted {d} call edges...\n", .{inserted});
        }
    }

    return inserted;
}

/// Top-level orchestrator: walk directory, parse files, insert into DB.
pub fn ingestDirectory(
    allocator: Allocator,
    io: std.Io,
    client: *SurrealClient,
    cfg: Config,
) !types.IngestResult {
    var walk_result = try walkDirectory(allocator, io, cfg.source_dir, "", cfg.verbose);
    defer walk_result.deinit(allocator);

    var result: types.IngestResult = .{
        .stats = walk_result.stats,
    };

    if (!cfg.dry_run) {
        result.functions_inserted = try insertFunctions(
            allocator,
            client,
            walk_result.functions.items,
            cfg.dry_run,
            cfg.verbose,
        );
        result.calls_inserted = try insertCalls(
            allocator,
            client,
            walk_result.calls.items,
            cfg.dry_run,
            cfg.verbose,
        );
    }

    return result;
}
