const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("sqlite3.h");
});

// SQLITE_TRANSIENT ((sqlite3_destructor_type)-1) can't be expressed in
// Zig 0.16 due to function-pointer alignment safety. Use SQLITE_STATIC
// (null) — safe because every bound value (start/end/state_filter) is an
// argv slice that outlives the prepared statement (the statement is
// finalized before exportToCSV returns, well before the args go away).
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

const DB_PATH = "/var/lib/cognitive-watcher/cognitive-states.db";

const ExportOptions = struct {
    output_file: []const u8 = "cognitive-states.csv",
    start_date: ?[]const u8 = null,
    end_date: ?[]const u8 = null,
    pid: ?u32 = null,
    state_filter: ?[]const u8 = null,
    limit: ?usize = null,
    include_raw: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var options = ExportOptions{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return 0;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a filename\n", .{});
                return 1;
            }
            options.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--start")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --start requires a date\n", .{});
                return 1;
            }
            options.start_date = args[i];
        } else if (std.mem.eql(u8, arg, "--end")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --end requires a date\n", .{});
                return 1;
            }
            options.end_date = args[i];
        } else if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --pid requires a number\n", .{});
                return 1;
            }
            options.pid = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--state")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --state requires a pattern\n", .{});
                return 1;
            }
            options.state_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --limit requires a number\n", .{});
                return 1;
            }
            options.limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--include-raw")) {
            options.include_raw = true;
        }
    }

    try exportToCSV(allocator, options);

    return 0;
}

fn printHelp() void {
    std.debug.print(
        \\cognitive-export - Export cognitive states to CSV
        \\
        \\Usage: cognitive-export [OPTIONS]
        \\
        \\Options:
        \\  -o, --output <file>      Output CSV file (default: cognitive-states.csv)
        \\  --start <date>          Start date filter (YYYY-MM-DD HH:MM:SS)
        \\  --end <date>            End date filter (YYYY-MM-DD HH:MM:SS)
        \\  --pid <number>          Filter by specific PID
        \\  --state <pattern>       Filter by state pattern (SQL LIKE)
        \\  --limit <number>        Limit number of records
        \\  --include-raw           Include raw_content column
        \\  -h, --help              Show this help
        \\
        \\Examples:
        \\  # Export all states
        \\  cognitive-export
        \\
        \\  # Export states for specific PID
        \\  cognitive-export --pid 12345 -o states-12345.csv
        \\
        \\  # Export states from today
        \\  cognitive-export --start "2025-11-03 00:00:00"
        \\
        \\  # Export only "Thinking" states
        \\  cognitive-export --state "%Thinking%"
        \\
        \\  # Export last 1000 states with raw content
        \\  cognitive-export --limit 1000 --include-raw
        \\
    , .{});
}

fn exportToCSV(allocator: std.mem.Allocator, options: ExportOptions) !void {
    // Open database
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(
        DB_PATH,
        &db,
        c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_SHAREDCACHE,
        null,
    );
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open database: {d}\n", .{rc});
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_busy_timeout(db, 5000);

    // Build the query with `?` placeholders (no caller-controlled value is
    // ever concatenated into the SQL text — argv-derived filters are bound
    // as parameters below, matching the pattern in query.zig:132-134).
    const query = try buildExportQuery(allocator, options);
    defer allocator.free(query);

    // Execute query
    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare statement: {d}\n", .{prep_rc});
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters in the exact order their placeholders were appended.
    var bind_pos: c_int = 1;
    if (options.start_date) |start| {
        _ = c.sqlite3_bind_text(stmt, bind_pos, start.ptr, @intCast(start.len), SQLITE_STATIC);
        bind_pos += 1;
    }
    if (options.end_date) |end| {
        _ = c.sqlite3_bind_text(stmt, bind_pos, end.ptr, @intCast(end.len), SQLITE_STATIC);
        bind_pos += 1;
    }
    if (options.pid) |pid| {
        _ = c.sqlite3_bind_int(stmt, bind_pos, @intCast(pid));
        bind_pos += 1;
    }
    if (options.state_filter) |filter| {
        _ = c.sqlite3_bind_text(stmt, bind_pos, filter.ptr, @intCast(filter.len), SQLITE_STATIC);
        bind_pos += 1;
    }
    if (options.limit) |limit| {
        _ = c.sqlite3_bind_int64(stmt, bind_pos, @intCast(limit));
        bind_pos += 1;
    }

    // Open output file
    const io = Io.Threaded.global_single_threaded.io();
    const file = try Io.Dir.cwd().createFile(io, options.output_file, .{});
    defer file.close(io);

    // Create buffered writer
    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    // Write CSV header
    writer.interface.writeAll("id,timestamp,cognitive_state,tool_name,status,pid") catch return error.WriteError;
    if (options.include_raw) {
        writer.interface.writeAll(",raw_content") catch return error.WriteError;
    }
    writer.interface.writeAll("\n") catch return error.WriteError;

    // Write rows
    var count: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // id
        const id = c.sqlite3_column_int64(stmt, 0);
        writer.interface.print("{d},", .{id}) catch return error.WriteError;

        // timestamp
        if (c.sqlite3_column_text(stmt, 1)) |timestamp| {
            const timestamp_str = std.mem.span(timestamp);
            writer.interface.print("\"{s}\",", .{timestamp_str}) catch return error.WriteError;
        } else {
            writer.interface.writeAll(",") catch return error.WriteError;
        }

        // cognitive_state
        if (c.sqlite3_column_text(stmt, 2)) |state| {
            const state_str = std.mem.span(state);
            const escaped = try escapeCSV(allocator, state_str);
            defer allocator.free(escaped);
            writer.interface.print("{s},", .{escaped}) catch return error.WriteError;
        } else {
            writer.interface.writeAll(",") catch return error.WriteError;
        }

        // tool_name
        if (c.sqlite3_column_text(stmt, 3)) |tool| {
            const tool_str = std.mem.span(tool);
            const escaped = try escapeCSV(allocator, tool_str);
            defer allocator.free(escaped);
            writer.interface.print("{s},", .{escaped}) catch return error.WriteError;
        } else {
            writer.interface.writeAll(",") catch return error.WriteError;
        }

        // status
        if (c.sqlite3_column_text(stmt, 4)) |status| {
            const status_str = std.mem.span(status);
            const escaped = try escapeCSV(allocator, status_str);
            defer allocator.free(escaped);
            writer.interface.print("{s},", .{escaped}) catch return error.WriteError;
        } else {
            writer.interface.writeAll(",") catch return error.WriteError;
        }

        // pid
        const pid = c.sqlite3_column_int(stmt, 5);
        writer.interface.print("{d}", .{pid}) catch return error.WriteError;

        // raw_content (optional)
        if (options.include_raw) {
            if (c.sqlite3_column_text(stmt, 6)) |raw| {
                const raw_str = std.mem.span(raw);
                const escaped = try escapeCSV(allocator, raw_str);
                defer allocator.free(escaped);
                writer.interface.print(",{s}", .{escaped}) catch return error.WriteError;
            } else {
                writer.interface.writeAll(",") catch return error.WriteError;
            }
        }

        writer.interface.writeAll("\n") catch return error.WriteError;
        count += 1;
    }

    // Flush the writer
    writer.interface.flush() catch return error.WriteError;

    std.debug.print("✅ Exported {d} cognitive states to {s}\n", .{ count, options.output_file });
}

/// Assemble the export SELECT with `?` placeholders for every caller-controlled
/// filter. No argv-derived value is concatenated into the returned SQL text; the
/// values are bound with sqlite3_bind_* at the call site. Only fixed literals
/// (including the constant `LIKE '%*%'` marker) are embedded directly.
fn buildExportQuery(allocator: std.mem.Allocator, options: ExportOptions) ![]u8 {
    var query = std.ArrayList(u8).empty;
    errdefer query.deinit(allocator);

    try query.appendSlice(allocator, "SELECT id, timestamp_human, ");

    // Extract cognitive state from raw_content
    try query.appendSlice(allocator,
        \\TRIM(substr(raw_content,
        \\  instr(raw_content, '*') + 1,
        \\  CASE
        \\    WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0
        \\    THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1
        \\    ELSE length(raw_content)
        \\  END
        \\)) as cognitive_state,
    );

    try query.appendSlice(allocator, "tool_name, status, pid");

    if (options.include_raw) {
        try query.appendSlice(allocator, ", raw_content");
    }

    try query.appendSlice(allocator, " FROM cognitive_states WHERE raw_content LIKE '%*%'");

    // Filters — placeholders only; bound in the same order at the call site.
    if (options.start_date != null) {
        try query.appendSlice(allocator, " AND timestamp_human >= ?");
    }
    if (options.end_date != null) {
        try query.appendSlice(allocator, " AND timestamp_human <= ?");
    }
    if (options.pid != null) {
        try query.appendSlice(allocator, " AND pid = ?");
    }
    if (options.state_filter != null) {
        try query.appendSlice(allocator, " AND raw_content LIKE ?");
    }

    try query.appendSlice(allocator, " ORDER BY id DESC");

    if (options.limit != null) {
        try query.appendSlice(allocator, " LIMIT ?");
    }

    return query.toOwnedSlice(allocator);
}

fn escapeCSV(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    // Check if escaping is needed
    const needs_escape = std.mem.indexOf(u8, value, "\"") != null or
        std.mem.indexOf(u8, value, ",") != null or
        std.mem.indexOf(u8, value, "\n") != null;

    if (!needs_escape) {
        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
    }

    // Escape quotes by doubling them
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    try result.append(allocator, '"');
    for (value) |char| {
        if (char == '"') {
            try result.append(allocator, '"');
            try result.append(allocator, '"');
        } else {
            try result.append(allocator, char);
        }
    }
    try result.append(allocator, '"');

    return try result.toOwnedSlice(allocator);
}

test "buildExportQuery binds filters instead of interpolating them" {
    const allocator = std.testing.allocator;

    const evil_state = "%'; DROP TABLE cognitive_states; --";
    const evil_start = "2025-01-01' OR '1'='1";
    const options = ExportOptions{
        .state_filter = evil_state,
        .start_date = evil_start,
        .end_date = "2025-12-31",
        .pid = 4242,
        .limit = 10,
        .include_raw = true,
    };

    const q = try buildExportQuery(allocator, options);
    defer allocator.free(q);

    // The adversarial argv values must never appear in the SQL text —
    // they are bound as parameters, not concatenated.
    try std.testing.expect(std.mem.indexOf(u8, q, evil_state) == null);
    try std.testing.expect(std.mem.indexOf(u8, q, evil_start) == null);
    try std.testing.expect(std.mem.indexOf(u8, q, "DROP TABLE") == null);
    try std.testing.expect(std.mem.indexOf(u8, q, "OR '1'='1") == null);

    // Placeholders are present for each supplied filter.
    try std.testing.expect(std.mem.indexOf(u8, q, "timestamp_human >= ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "timestamp_human <= ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "pid = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "raw_content LIKE ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "LIMIT ?") != null);
}

test "buildExportQuery omits placeholders for unset filters" {
    const allocator = std.testing.allocator;

    const q = try buildExportQuery(allocator, .{});
    defer allocator.free(q);

    // No filters set → no bound placeholders at all.
    try std.testing.expect(std.mem.indexOf(u8, q, "?") == null);
    try std.testing.expect(std.mem.indexOf(u8, q, "WHERE raw_content LIKE '%*%'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "ORDER BY id DESC") != null);
}
