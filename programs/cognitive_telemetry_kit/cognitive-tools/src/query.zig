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

    if (args.len < 2) {
        printHelp();
        return 1;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printHelp();
        return 0;
    } else if (std.mem.eql(u8, command, "search")) {
        if (args.len < 3) {
            std.debug.print("Error: search requires a pattern\n", .{});
            return 1;
        }
        try searchStates(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "session")) {
        if (args.len < 3) {
            std.debug.print("Error: session requires a PID\n", .{});
            return 1;
        }
        const pid = try std.fmt.parseInt(u32, args[2], 10);
        try showSession(allocator, pid);
    } else if (std.mem.eql(u8, command, "timeline")) {
        if (args.len < 3) {
            std.debug.print("Error: timeline requires a PID\n", .{});
            return 1;
        }
        const pid = try std.fmt.parseInt(u32, args[2], 10);
        try showTimeline(allocator, pid);
    } else if (std.mem.eql(u8, command, "recent")) {
        const limit = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 20;
        try showRecent(allocator, limit);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printHelp();
        return 1;
    }

    return 0;
}

fn printHelp() void {
    std.debug.print(
        \\cognitive-query - Advanced cognitive state search
        \\
        \\Usage: cognitive-query <command> [args]
        \\
        \\Commands:
        \\  search <pattern>    Search for states matching pattern
        \\  session <pid>       Show all states for a specific session
        \\  timeline <pid>      Show timeline visualization for session
        \\  recent [limit]      Show recent states (default: 20)
        \\
        \\Examples:
        \\  cognitive-query search "Thinking"
        \\  cognitive-query session 12345
        \\  cognitive-query timeline 12345
        \\  cognitive-query recent 50
        \\
    , .{});
}

fn searchStates(allocator: std.mem.Allocator, pattern: []const u8) !void {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(
        DB_PATH,
        &db,
        c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_SHAREDCACHE,
        null,
    );
    if (rc != c.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_busy_timeout(db, 5000);

    const query_fmt =
        \\SELECT
        \\  timestamp_human,
        \\  TRIM(substr(raw_content,
        \\    instr(raw_content, '*') + 1,
        \\    CASE
        \\      WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0
        \\      THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1
        \\      ELSE length(raw_content)
        \\    END
        \\  )) as cognitive_state,
        \\  pid
        \\FROM cognitive_states
        \\WHERE raw_content LIKE '%*%'
        \\  AND raw_content LIKE ?
        \\ORDER BY id DESC
        \\LIMIT 50
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query_fmt, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind pattern
    const search_pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{pattern});
    defer allocator.free(search_pattern);
    _ = c.sqlite3_bind_text(stmt, 1, search_pattern.ptr, @intCast(search_pattern.len), c.SQLITE_TRANSIENT);

    std.debug.print("\n🔍 Search Results for \"{s}\":\n\n", .{pattern});

    var count: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const timestamp = if (c.sqlite3_column_text(stmt, 0)) |t| std.mem.span(t) else "N/A";
        const state = if (c.sqlite3_column_text(stmt, 1)) |s| std.mem.span(s) else "Unknown";
        const pid = c.sqlite3_column_int(stmt, 2);

        std.debug.print("[{s}] PID {d}: {s}\n", .{ timestamp, pid, state });
        count += 1;
    }

    std.debug.print("\nFound {d} matches\n\n", .{count});
}

fn showSession(allocator: std.mem.Allocator, pid: u32) !void {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(
        DB_PATH,
        &db,
        c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_SHAREDCACHE,
        null,
    );
    if (rc != c.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_busy_timeout(db, 5000);

    const query_fmt =
        \\SELECT
        \\  timestamp_human,
        \\  TRIM(substr(raw_content,
        \\    instr(raw_content, '*') + 1,
        \\    CASE
        \\      WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0
        \\      THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1
        \\      ELSE length(raw_content)
        \\    END
        \\  )) as cognitive_state,
        \\  COUNT(*) OVER () as total_count
        \\FROM cognitive_states
        \\WHERE pid = ?
        \\  AND raw_content LIKE '%*%'
        \\ORDER BY id
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query_fmt, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, @intCast(pid));

    std.debug.print("\n📋 Session History for PID {d}:\n\n", .{pid});

    var prev_state: ?[]const u8 = null;
    var state_count: usize = 1;
    var total: usize = 0;

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const timestamp = if (c.sqlite3_column_text(stmt, 0)) |t| std.mem.span(t) else "N/A";
        const state = if (c.sqlite3_column_text(stmt, 1)) |s| std.mem.span(s) else "Unknown";

        if (total == 0) {
            total = @intCast(c.sqlite3_column_int(stmt, 2));
        }

        if (prev_state) |prev| {
            if (std.mem.eql(u8, prev, state)) {
                state_count += 1;
                continue;
            } else {
                // State changed, print previous
                if (state_count > 1) {
                    std.debug.print("    (× {d} times)\n", .{state_count});
                }
                state_count = 1;
            }
        }

        std.debug.print("[{s}] {s}\n", .{ timestamp, state });
        prev_state = try allocator.dupe(u8, state);
    }

    if (prev_state) |prev| {
        if (state_count > 1) {
            std.debug.print("    (× {d} times)\n", .{state_count});
        }
        allocator.free(prev);
    }

    std.debug.print("\nTotal: {d} state changes\n\n", .{total});
}

fn showTimeline(allocator: std.mem.Allocator, pid: u32) !void {
    _ = allocator;
    _ = pid;
    std.debug.print("Timeline visualization coming soon!\n", .{});
}

fn showRecent(allocator: std.mem.Allocator, limit: usize) !void {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(
        DB_PATH,
        &db,
        c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_SHAREDCACHE,
        null,
    );
    if (rc != c.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    _ = c.sqlite3_busy_timeout(db, 5000);

    const query_fmt =
        \\SELECT
        \\  timestamp_human,
        \\  TRIM(substr(raw_content,
        \\    instr(raw_content, '*') + 1,
        \\    CASE
        \\      WHEN instr(substr(raw_content, instr(raw_content, '*')), '(') > 0
        \\      THEN instr(substr(raw_content, instr(raw_content, '*')), '(') - 1
        \\      ELSE length(raw_content)
        \\    END
        \\  )) as cognitive_state,
        \\  pid
        \\FROM cognitive_states
        \\WHERE raw_content LIKE '%*%'
        \\ORDER BY id DESC
        \\LIMIT ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query_fmt, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));

    std.debug.print("\n⏱️  Recent {d} Cognitive States:\n\n", .{limit});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const timestamp = if (c.sqlite3_column_text(stmt, 0)) |t| std.mem.span(t) else "N/A";
        const state = if (c.sqlite3_column_text(stmt, 1)) |s| std.mem.span(s) else "Unknown";
        const pid_val = c.sqlite3_column_int(stmt, 2);

        std.debug.print("[{s}] PID {d: <6} → {s}\n", .{ timestamp, pid_val, state });
    }

    std.debug.print("\n", .{});

    _ = allocator;
}
