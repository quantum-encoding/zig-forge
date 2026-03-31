const std = @import("std");
const linux = std.os.linux;
const libc = std.c;
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sys/inotify.h");
    @cInclude("dbus/dbus.h");
});

// Zig 0.16 compatible Mutex using pthreads (std.Thread.Mutex no longer exists)
const Mutex = struct {
    inner: libc.pthread_mutex_t = libc.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = libc.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = libc.pthread_mutex_unlock(&self.inner);
    }
};

const CognitiveState = struct {
    timestamp: []const u8,
    state_type: []const u8,
    tool_name: ?[]const u8,
    status: ?[]const u8,
    pid: u32,

    pub fn deinit(self: *CognitiveState, allocator: std.mem.Allocator) void {
        allocator.free(self.timestamp);
        allocator.free(self.state_type);
        if (self.tool_name) |name| allocator.free(name);
        if (self.status) |s| allocator.free(s);
    }

    pub fn clone(self: *const CognitiveState, allocator: std.mem.Allocator) !CognitiveState {
        return CognitiveState{
            .timestamp = try allocator.dupe(u8, self.timestamp),
            .state_type = try allocator.dupe(u8, self.state_type),
            .tool_name = if (self.tool_name) |name| try allocator.dupe(u8, name) else null,
            .status = if (self.status) |s| try allocator.dupe(u8, s) else null,
            .pid = self.pid,
        };
    }
};

pub const StateCache = struct {
    allocator: std.mem.Allocator,
    // Map from PID to latest cognitive state
    states_by_pid: std.AutoHashMap(u32, CognitiveState),
    // Ring buffer of recent states (for history)
    recent_states: std.ArrayList(CognitiveState),
    max_recent: usize,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) StateCache {
        return .{
            .allocator = allocator,
            .states_by_pid = std.AutoHashMap(u32, CognitiveState).init(allocator),
            .recent_states = std.ArrayList(CognitiveState).empty,
            .max_recent = 100,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *StateCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.states_by_pid.valueIterator();
        while (it.next()) |state| {
            var mutable_state = state.*;
            mutable_state.deinit(self.allocator);
        }
        self.states_by_pid.deinit();

        for (self.recent_states.items) |*state| {
            state.deinit(self.allocator);
        }
        self.recent_states.deinit(self.allocator);
    }

    pub fn updateState(self: *StateCache, state: CognitiveState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update PID-specific state
        if (self.states_by_pid.get(state.pid)) |old_state| {
            var mutable_old = old_state;
            mutable_old.deinit(self.allocator);
        }
        try self.states_by_pid.put(state.pid, state);

        // Clone the state for the ring buffer (separate ownership)
        const cloned_state = try state.clone(self.allocator);
        try self.recent_states.append(self.allocator, cloned_state);
        if (self.recent_states.items.len > self.max_recent) {
            var removed = self.recent_states.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    pub fn getStateForPid(self: *StateCache, pid: u32) ?CognitiveState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.states_by_pid.get(pid);
    }

    pub fn getRecentStates(self: *StateCache, limit: usize) []const CognitiveState {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = @min(limit, self.recent_states.items.len);
        const start = self.recent_states.items.len - count;
        return self.recent_states.items[start..];
    }
};

const DB_PATH = "/var/lib/cognitive-watcher/cognitive-states.db";

// Extract cognitive state from raw_content (text between * and ()
fn extractCognitiveState(allocator: std.mem.Allocator, raw_content: []const u8) ![]const u8 {
    // Find the * character
    const star_pos = std.mem.indexOf(u8, raw_content, "*") orelse return allocator.dupe(u8, "Unknown");

    const start = star_pos + 1; // Skip the *

    // Find the ( character after the * (if it exists)
    const paren_pos = std.mem.indexOf(u8, raw_content[star_pos..], "(");

    // Determine end position:
    // - If there's a (, use it
    // - Otherwise, use the end of the string or newline
    const end = if (paren_pos) |pos|
        star_pos + pos
    else blk: {
        // No parenthesis found - extract until newline or end of string
        const newline_pos = std.mem.indexOf(u8, raw_content[star_pos..], "\n");
        break :blk if (newline_pos) |npos| star_pos + npos else raw_content.len;
    };

    if (start >= end) return allocator.dupe(u8, "Unknown");

    const state_raw = raw_content[start..end];

    // Trim whitespace
    const state_trimmed = std.mem.trim(u8, state_raw, " \t\n\r");

    if (state_trimmed.len == 0) return allocator.dupe(u8, "Unknown");

    return allocator.dupe(u8, state_trimmed);
}

fn queryCognitiveStates(allocator: std.mem.Allocator, cache: *StateCache) !void {
    var db: ?*c.sqlite3 = null;

    // Open database in read-only mode with shared cache
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

    // Set busy timeout to 1 second
    _ = c.sqlite3_busy_timeout(db, 1000);

    // Query recent cognitive states - get raw_content to extract actual state
    const query =
        \\SELECT timestamp_human, raw_content, tool_name, status, pid
        \\FROM cognitive_states
        \\WHERE raw_content LIKE '%*%'
        \\  AND raw_content LIKE '%esc to interrupt%'
        \\  AND raw_content NOT LIKE '%Bash(%'
        \\  AND raw_content NOT LIKE '%Read(%'
        \\  AND raw_content NOT LIKE '%Write(%'
        \\  AND raw_content NOT LIKE '%Edit(%'
        \\ORDER BY id DESC
        \\LIMIT 50
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, query, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare statement: {d}\n", .{prep_rc});
        return error.StatementPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Fetch results
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const timestamp = c.sqlite3_column_text(stmt, 0);
        const raw_content = c.sqlite3_column_text(stmt, 1);
        const tool_name = c.sqlite3_column_text(stmt, 2);
        const status = c.sqlite3_column_text(stmt, 3);
        const pid = c.sqlite3_column_int(stmt, 4);

        // Extract actual cognitive state from raw_content (text between * and ()
        const raw_content_str = std.mem.span(raw_content);
        const extracted_state = try extractCognitiveState(allocator, raw_content_str);

        const state = CognitiveState{
            .timestamp = try allocator.dupe(u8, std.mem.span(timestamp)),
            .state_type = extracted_state,
            .tool_name = if (c.sqlite3_column_type(stmt, 2) != c.SQLITE_NULL)
                try allocator.dupe(u8, std.mem.span(tool_name))
            else
                null,
            .status = if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL)
                try allocator.dupe(u8, std.mem.span(status))
            else
                null,
            .pid = @intCast(pid),
        };

        try cache.updateState(state);
    }
}

fn watchDatabaseChanges(allocator: std.mem.Allocator, cache: *StateCache) !void {
    // Initialize inotify
    const inotify_fd = c.inotify_init1(c.IN_NONBLOCK);
    if (inotify_fd < 0) {
        return error.InotifyInitFailed;
    }
    defer _ = std.c.close(inotify_fd);

    // Watch the database directory for modifications
    const watch_path = "/var/lib/cognitive-watcher";
    const wd = c.inotify_add_watch(inotify_fd, watch_path, c.IN_MODIFY | c.IN_CLOSE_WRITE);
    if (wd < 0) {
        return error.InotifyWatchFailed;
    }

    std.debug.print("[Cognitive State Server] Watching database for changes...\n", .{});

    var buffer: [4096]u8 = undefined;
    // Zig 0.16: Use std.posix.clock_gettime for timestamps
    var last_query_time = getMilliTimestamp();

    while (true) {
        // Check for inotify events
        const bytes_read = std.posix.read(inotify_fd, &buffer) catch 0;

        const current_time = getMilliTimestamp();
        const time_since_last_query = current_time - last_query_time;

        // If database modified or 500ms has passed, requery
        if (bytes_read > 0 or time_since_last_query > 500) {
            queryCognitiveStates(allocator, cache) catch |err| {
                std.debug.print("Failed to query database: {}\n", .{err});
            };
            last_query_time = current_time;
        }

        // Sleep briefly to avoid busy-waiting
        var ts1: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts1, null);
    }
}

// Zig 0.16 compatibility: Get milliseconds since epoch using libc
fn getMilliTimestamp() i64 {
    var ts: libc.timespec = undefined;
    if (libc.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return ts.sec * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

const DBusServer = @import("dbus_server.zig").DBusServer;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("🧠 Cognitive State Server - The In-Memory Oracle\n", .{});
    std.debug.print("═══════════════════════════════════════════════\n", .{});

    var cache = StateCache.init(allocator);
    defer cache.deinit();

    // Initial database query
    std.debug.print("[Oracle] Loading cognitive states from database...\n", .{});
    try queryCognitiveStates(allocator, &cache);
    std.debug.print("[Oracle] Loaded {d} unique PIDs\n", .{cache.states_by_pid.count()});

    // Initialize D-Bus server
    std.debug.print("[Oracle] Starting D-Bus server...\n", .{});
    var dbus_server = try DBusServer.init(allocator, &cache);
    defer dbus_server.deinit();

    // Start database watcher in separate thread
    std.debug.print("[Oracle] Starting inotify watcher...\n", .{});
    const WatcherContext = struct {
        allocator: std.mem.Allocator,
        cache: *StateCache,
    };
    const ctx = WatcherContext{
        .allocator = allocator,
        .cache = &cache,
    };

    const watcher_thread = try std.Thread.spawn(.{}, struct {
        fn run(context: WatcherContext) !void {
            try watchDatabaseChanges(context.allocator, context.cache);
        }
    }.run, .{ctx});
    defer watcher_thread.join();

    // Main event loop - process D-Bus messages
    std.debug.print("[Oracle] Oracle is online. Listening for queries...\n", .{});
    while (true) {
        try dbus_server.processMessages();
        var ts2: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts2, null); // 10ms sleep to avoid busy-waiting
    }
}
