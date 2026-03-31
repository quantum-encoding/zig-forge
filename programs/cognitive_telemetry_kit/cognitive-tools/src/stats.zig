const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const DB_PATH = "/var/lib/cognitive-watcher/cognitive-states.db";

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

    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printHelp();
        return 0;
    }

    try printStatistics(allocator);

    return 0;
}

fn printHelp() void {
    std.debug.print(
        \\cognitive-stats - Analyze cognitive state statistics
        \\
        \\Usage: cognitive-stats
        \\
        \\Displays:
        \\  - Total states captured
        \\  - Number of unique PIDs/sessions
        \\  - Most common cognitive states
        \\  - Time range of data
        \\  - State distribution
        \\
    , .{});
}

fn printStatistics(allocator: std.mem.Allocator) !void {
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

    std.debug.print("\n", .{});
    std.debug.print("🧠 COGNITIVE TELEMETRY STATISTICS\n", .{});
    std.debug.print("═══════════════════════════════════════════════\n\n", .{});

    // Overall stats
    try printOverallStats(db);
    std.debug.print("\n", .{});

    // Top states
    try printTopStates(allocator, db);
    std.debug.print("\n", .{});

    // PIDs
    try printPIDStats(allocator, db);
    std.debug.print("\n", .{});
}

fn printOverallStats(db: ?*c.sqlite3) !void {
    const query =
        \\SELECT
        \\  COUNT(*) as total,
        \\  COUNT(DISTINCT pid) as unique_pids,
        \\  MIN(timestamp_human) as first,
        \\  MAX(timestamp_human) as last
        \\FROM cognitive_states
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const total = c.sqlite3_column_int64(stmt, 0);
        const unique_pids = c.sqlite3_column_int(stmt, 1);

        std.debug.print("📊 Overall Statistics:\n", .{});
        std.debug.print("   Total States:    {d:>10}\n", .{total});
        std.debug.print("   Unique Sessions: {d:>10}\n\n", .{unique_pids});

        if (c.sqlite3_column_text(stmt, 2)) |first| {
            const first_str = std.mem.span(first);
            std.debug.print("   First Capture:   {s}\n", .{first_str});
        }

        if (c.sqlite3_column_text(stmt, 3)) |last| {
            const last_str = std.mem.span(last);
            std.debug.print("   Latest Capture:  {s}\n", .{last_str});
        }
    }
}

fn printTopStates(allocator: std.mem.Allocator, db: ?*c.sqlite3) !void {
    const query =
        \\SELECT
        \\  TRIM(substr(raw_content,
        \\    instr(raw_content, '*') + 1,
        \\    CASE
        \\      WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0
        \\      THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1
        \\      ELSE length(raw_content)
        \\    END
        \\  )) as cognitive_state,
        \\  COUNT(*) as count
        \\FROM cognitive_states
        \\WHERE raw_content LIKE '%*%'
        \\  AND raw_content LIKE '%esc to interrupt%'
        \\GROUP BY cognitive_state
        \\ORDER BY count DESC
        \\LIMIT 20
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("🔥 Top 20 Cognitive States:\n", .{});
    std.debug.print("   ┌────────────────────────────────────────┬─────────┐\n", .{});
    std.debug.print("   │ State                                  │ Count   │\n", .{});
    std.debug.print("   ├────────────────────────────────────────┼─────────┤\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (c.sqlite3_column_text(stmt, 0)) |state| {
            const state_str = std.mem.span(state);
            const count = c.sqlite3_column_int64(stmt, 1);

            // Truncate long states
            const display_state = if (state_str.len > 38)
                try std.fmt.allocPrint(allocator, "{s}...", .{state_str[0..35]})
            else
                try allocator.dupe(u8, state_str);
            defer allocator.free(display_state);

            std.debug.print("   │ {s: <38} │ {d: >7} │\n", .{ display_state, count });
        }
    }

    std.debug.print("   └────────────────────────────────────────┴─────────┘\n", .{});
}

fn printPIDStats(allocator: std.mem.Allocator, db: ?*c.sqlite3) !void {
    const query =
        \\SELECT
        \\  pid,
        \\  COUNT(*) as count,
        \\  MIN(timestamp_human) as first,
        \\  MAX(timestamp_human) as last
        \\FROM cognitive_states
        \\GROUP BY pid
        \\ORDER BY count DESC
        \\LIMIT 10
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("🎯 Top 10 Most Active Sessions (by PID):\n", .{});
    std.debug.print("   ┌────────┬─────────┬──────────────────────┬──────────────────────┐\n", .{});
    std.debug.print("   │ PID    │ States  │ First Seen           │ Last Seen            │\n", .{});
    std.debug.print("   ├────────┼─────────┼──────────────────────┼──────────────────────┤\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const pid = c.sqlite3_column_int(stmt, 0);
        const count = c.sqlite3_column_int64(stmt, 1);

        const first = if (c.sqlite3_column_text(stmt, 2)) |f|
            std.mem.span(f)
        else
            "N/A";

        const last = if (c.sqlite3_column_text(stmt, 3)) |l|
            std.mem.span(l)
        else
            "N/A";

        // Truncate timestamps to fit
        const first_short = if (first.len > 19) first[0..19] else first;
        const last_short = if (last.len > 19) last[0..19] else last;

        std.debug.print("   │ {d: <6} │ {d: >7} │ {s: <20} │ {s: <20} │\n", .{
            pid,
            count,
            first_short,
            last_short,
        });
    }

    std.debug.print("   └────────┴─────────┴──────────────────────┴──────────────────────┘\n", .{});

    _ = allocator;
}
