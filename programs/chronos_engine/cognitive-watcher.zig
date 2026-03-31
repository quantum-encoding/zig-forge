// SPDX-License-Identifier: Dual License - MIT (Non-Commercial) / Commercial License
//
// cognitive-watcher.zig - The Cognitive Oracle Consumer
//
// Purpose: Consume cognitive_events from eBPF ring buffer and forward to chronosd-cognitive
// Architecture: Ring buffer consumer → D-Bus publisher
//
// THE SACRED TRINITY:
//   Guardian (conductor-daemon) → Cognitive Watcher → chronosd-cognitive
//
// Philosophy: "The Watcher sits between the kernel and the daemon, translating divine whispers"

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const chronos = @import("chronos.zig");
const dbus_if = @import("dbus_interface.zig");
const dbus = @import("dbus_bindings.zig");
const cognitive_states = @import("cognitive_states.zig");

const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("linux/bpf.h");
    @cInclude("sqlite3.h");
});

const VERSION = "2.1.0"; // Session-based aggregation
const MAX_COMM_LEN = 16;
const MAX_BUF_SIZE = 256;
const MAX_TOOLS_PER_SESSION = 64;
const DB_PATH = "/var/lib/cognitive-watcher/cognitive-states.db";

/// Cognitive Event (must match eBPF side - optimized structure)
const CognitiveEvent = extern struct {
    pid: u32,
    timestamp_ns: u32,  // Reduced to 32-bit
    fd: u32,
    buf_size: u32,      // Reduced to 32-bit
    comm: [MAX_COMM_LEN]u8,
    buffer: [MAX_BUF_SIZE]u8,  // Raw write buffer
};

/// Cognitive Session - tracks state + tools for one PID
const CognitiveSession = struct {
    pid: u32,
    state: [64]u8,           // Current cognitive state ("Waddling", etc)
    state_len: usize,
    tools: [MAX_TOOLS_PER_SESSION][32]u8,  // Tools called in this state
    tool_lens: [MAX_TOOLS_PER_SESSION]usize,
    tool_count: usize,
    start_time: i64,         // Session start (unix seconds)
    last_activity: i64,      // Last activity time

    fn init(pid: u32) CognitiveSession {
        return CognitiveSession{
            .pid = pid,
            .state = [_]u8{0} ** 64,
            .state_len = 0,
            .tools = undefined,
            .tool_lens = [_]usize{0} ** MAX_TOOLS_PER_SESSION,
            .tool_count = 0,
            .start_time = 0,
            .last_activity = 0,
        };
    }

    fn setState(self: *CognitiveSession, new_state: []const u8) void {
        const len = @min(new_state.len, 63);
        @memcpy(self.state[0..len], new_state[0..len]);
        self.state[len] = 0;
        self.state_len = len;
    }

    fn getState(self: *const CognitiveSession) []const u8 {
        return self.state[0..self.state_len];
    }

    fn addTool(self: *CognitiveSession, tool: []const u8) void {
        if (self.tool_count >= MAX_TOOLS_PER_SESSION) return;
        const len = @min(tool.len, 31);
        @memcpy(self.tools[self.tool_count][0..len], tool[0..len]);
        self.tools[self.tool_count][len] = 0;
        self.tool_lens[self.tool_count] = len;
        self.tool_count += 1;
    }

    fn getToolsString(self: *const CognitiveSession, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (0..self.tool_count) |i| {
            if (i > 0 and pos + 2 < buf.len) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            const tool_len = self.tool_lens[i];
            if (pos + tool_len < buf.len) {
                @memcpy(buf[pos..][0..tool_len], self.tools[i][0..tool_len]);
                pos += tool_len;
            }
        }
        return buf[0..pos];
    }

    fn reset(self: *CognitiveSession) void {
        self.state_len = 0;
        self.tool_count = 0;
        self.start_time = 0;
    }
};

/// The Cognitive Watcher - Bridge between eBPF, D-Bus, and SQLite
pub const CognitiveWatcher = struct {
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    dbus_conn: ?dbus.DBusConnection,
    db: ?*c.sqlite3,
    events_processed: u64,
    sessions_saved: u64,
    // Track sessions per PID (simple fixed array for up to 8 concurrent Claude processes)
    sessions: [8]CognitiveSession,
    session_count: usize,

    pub fn init(allocator: std.mem.Allocator) !CognitiveWatcher {
        std.debug.print("🔮 THE COGNITIVE WATCHER v{s} - Awakening\n", .{VERSION});
        std.debug.print("   Purpose: Bridge eBPF cognitive events to D-Bus + SQLite\n", .{});
        std.debug.print("   Target D-Bus: {s}\n", .{dbus_if.DBUS_SERVICE});
        std.debug.print("   Target DB: {s}\n", .{DB_PATH});

        // Try to connect to D-Bus (chronosd-cognitive)
        var dbus_conn: ?dbus.DBusConnection = null;
        if (dbus.DBusConnection.init(dbus.BusType.SYSTEM)) |conn| {
            dbus_conn = conn;
        } else |err| {
            std.debug.print("⚠️  Failed to connect to D-Bus: {any}\n", .{err});
            std.debug.print("   Continuing without D-Bus (chronosd-cognitive not running?)\n", .{});
        }

        // Initialize SQLite database
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(DB_PATH, &db);
        if (rc != c.SQLITE_OK) {
            std.debug.print("⚠️  Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
            std.debug.print("   Continuing without database persistence\n", .{});
            if (db != null) _ = c.sqlite3_close(db);
            db = null;
        } else {
            std.debug.print("✓ Database opened: {s}\n", .{DB_PATH});
            // Initialize schema
            initSchema(db.?) catch |err| {
                std.debug.print("⚠️  Failed to initialize schema: {any}\n", .{err});
            };
        }

        return CognitiveWatcher{
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .dbus_conn = dbus_conn,
            .db = db,
            .events_processed = 0,
            .sessions_saved = 0,
            .sessions = undefined,
            .session_count = 0,
        };
    }

    /// Find or create session for a PID
    fn getOrCreateSession(self: *CognitiveWatcher, pid: u32) *CognitiveSession {
        // Look for existing session
        for (self.sessions[0..self.session_count]) |*session| {
            if (session.pid == pid) return session;
        }
        // Create new session
        if (self.session_count < 8) {
            self.sessions[self.session_count] = CognitiveSession.init(pid);
            self.session_count += 1;
            return &self.sessions[self.session_count - 1];
        }
        // Evict oldest session (first one)
        return &self.sessions[0];
    }

    /// Initialize database schema
    fn initSchema(db: *c.sqlite3) !void {
        // Enable WAL mode for better concurrency (allows reads while writing)
        var err_msg: [*c]u8 = null;
        var rc = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, &err_msg);
        if (rc != c.SQLITE_OK and err_msg != null) {
            std.debug.print("WAL mode warning: {s}\n", .{err_msg});
            c.sqlite3_free(err_msg);
            err_msg = null;
        }

        // New session-based schema
        const schema =
            \\CREATE TABLE IF NOT EXISTS cognitive_sessions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    pid INTEGER NOT NULL,
            \\    cognitive_state TEXT NOT NULL,
            \\    tools_called TEXT,
            \\    tool_count INTEGER DEFAULT 0,
            \\    start_time INTEGER NOT NULL,
            \\    end_time INTEGER NOT NULL,
            \\    duration_seconds INTEGER,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_pid ON cognitive_sessions(pid);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_state ON cognitive_sessions(cognitive_state);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_time ON cognitive_sessions(start_time);
        ;

        rc = c.sqlite3_exec(db, schema, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("SQL error: {s}\n", .{err_msg});
                c.sqlite3_free(err_msg);
            }
            return error.SchemaInitFailed;
        }
        std.debug.print("✓ Database schema initialized (WAL mode, session-based)\n", .{});
    }

    /// Flush a session to the database (called when state changes)
    fn flushSession(self: *CognitiveWatcher, session: *CognitiveSession) void {
        const db = self.db orelse return;
        if (session.state_len == 0) return; // No state to flush

        var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts);
        const now = ts.sec;

        // Get tools string
        var tools_buf: [1024]u8 = undefined;
        const tools_str = session.getToolsString(&tools_buf);

        const sql =
            \\INSERT INTO cognitive_sessions
            \\(pid, cognitive_state, tools_called, tool_count, start_time, end_time, duration_seconds)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("⚠️  Failed to prepare session insert: {s}\n", .{c.sqlite3_errmsg(db)});
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const s = stmt.?;
        _ = c.sqlite3_bind_int(s, 1, @intCast(session.pid));

        const state = session.getState();
        _ = c.sqlite3_bind_text(s, 2, state.ptr, @intCast(state.len), c.SQLITE_TRANSIENT);

        if (tools_str.len > 0) {
            _ = c.sqlite3_bind_text(s, 3, tools_str.ptr, @intCast(tools_str.len), c.SQLITE_TRANSIENT);
        } else {
            _ = c.sqlite3_bind_null(s, 3);
        }

        _ = c.sqlite3_bind_int(s, 4, @intCast(session.tool_count));
        _ = c.sqlite3_bind_int64(s, 5, session.start_time);
        _ = c.sqlite3_bind_int64(s, 6, now);

        const duration = now - session.start_time;
        _ = c.sqlite3_bind_int64(s, 7, duration);

        rc = c.sqlite3_step(s);
        if (rc == c.SQLITE_DONE) {
            self.sessions_saved += 1;
            std.debug.print("💾 SESSION SAVED: PID={d} State=\"{s}\" Tools=[{s}] Duration={d}s\n", .{
                session.pid,
                state,
                tools_str,
                duration,
            });
        } else {
            std.debug.print("⚠️  Failed to insert session: {s}\n", .{c.sqlite3_errmsg(db)});
        }
    }

    pub fn deinit(self: *CognitiveWatcher) void {
        // Flush all active sessions before shutdown
        for (self.sessions[0..self.session_count]) |*session| {
            if (session.state_len > 0) {
                self.flushSession(session);
            }
        }

        if (self.dbus_conn) |*conn| {
            conn.deinit();
        }
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
        std.debug.print("🔮 Cognitive Watcher shutdown complete\n", .{});
        std.debug.print("   Events processed: {d}\n", .{self.events_processed});
        std.debug.print("   Sessions saved: {d}\n", .{self.sessions_saved});
    }

    /// Ring buffer callback (called by libbpf for each event)
    fn handleCognitiveEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: c_ulong) callconv(.c) c_int {
        _ = size;
        if (data == null or ctx == null) return 0;

        const self: *CognitiveWatcher = @ptrCast(@alignCast(ctx));
        const event: *CognitiveEvent = @ptrCast(@alignCast(data));

        self.processCognitiveEvent(event) catch |err| {
            std.debug.print("⚠️  Event processing error: {any}\n", .{err});
        };

        return 0;
    }

    /// Strip ANSI escape sequences and control characters from buffer
    /// This makes cognitive state strings visible when they contain terminal formatting
    fn stripAnsi(allocator: std.mem.Allocator, buffer: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < buffer.len) {
            // Detect ANSI CSI sequence: ESC [ ... letter
            if (i + 1 < buffer.len and buffer[i] == 0x1b and buffer[i + 1] == '[') {
                i += 2;
                // Skip until we hit a letter (a-zA-Z) which terminates the sequence
                while (i < buffer.len) : (i += 1) {
                    const ch = buffer[i];
                    if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            // Detect ANSI OSC sequence: ESC ] ... BEL or ESC ] ... ESC \
            if (i + 1 < buffer.len and buffer[i] == 0x1b and buffer[i + 1] == ']') {
                i += 2;
                // Skip until BEL (0x07) or ST (ESC \)
                while (i < buffer.len) : (i += 1) {
                    if (buffer[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (i + 1 < buffer.len and buffer[i] == 0x1b and buffer[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }

            // Keep printable characters, newlines, and tabs
            const ch = buffer[i];
            if (ch >= 32 or ch == '\n' or ch == '\t') {
                try result.append(allocator, ch);
            }
            // Skip other control characters (0x00-0x1F except \n and \t)

            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Check if PID is Claude Code CLI by reading /proc/PID/cmdline
    fn isClaudeCLI(self: *CognitiveWatcher, pid: u32) bool {
        _ = self;
        var cmdline_buf: [4096]u8 = undefined;
        const cmdline_path_len = (std.fmt.bufPrint(&cmdline_buf, "/proc/{d}/cmdline", .{pid}) catch return false).len;
        cmdline_buf[cmdline_path_len] = 0;
        const cmdline_path_z: [*:0]const u8 = cmdline_buf[0..cmdline_path_len :0];

        const fd = posix.openatZ(std.c.AT.FDCWD, cmdline_path_z, .{ .ACCMODE = .RDONLY }, 0) catch return false;
        defer _ = std.c.close(fd);

        var content: [4096]u8 = undefined;
        const read_result = std.c.read(fd, &content, content.len);
        const bytes_read: usize = if (read_result > 0) @intCast(read_result) else return false;

        // Check for claude binary (the cmdline will be just "claude" for Claude Code CLI)
        // Also check environment for npm.global/bin/claude
        const cmdline = content[0..bytes_read];

        // For now, accept ANY process named "claude" - we'll filter more precisely later
        return std.mem.indexOf(u8, cmdline, "claude") != null;
    }

    /// Known tool names that Claude Code uses
    const KNOWN_TOOLS = [_][]const u8{
        "Bash",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        "TodoWrite",
        "WebFetch",
        "WebSearch",
        "NotebookEdit",
        "AskUserQuestion",
        "EnterPlanMode",
        "ExitPlanMode",
        "Skill",
        "KillShell",
        "TaskOutput",
    };

    /// Check if a string is a known tool name
    fn isKnownTool(name: []const u8) bool {
        for (KNOWN_TOOLS) |tool| {
            if (std.mem.eql(u8, name, tool)) return true;
        }
        return false;
    }

    /// Parse tool from DEBUG hook pattern
    /// Pattern: "[DEBUG] executePreToolHooks called for tool: ToolName"
    fn parseDebugHook(buffer: []const u8, tool_name: *[128]u8) bool {
        const marker = "executePreToolHooks called for tool: ";
        if (std.mem.indexOf(u8, buffer, marker)) |pos| {
            const after_marker = buffer[pos + marker.len ..];

            // Extract tool name (until whitespace, newline, or end)
            var tool_end: usize = 0;
            while (tool_end < after_marker.len and tool_end < 127) : (tool_end += 1) {
                const ch = after_marker[tool_end];
                if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t' or ch == 0) break;
            }

            if (tool_end > 0) {
                @memcpy(tool_name[0..tool_end], after_marker[0..tool_end]);
                tool_name[tool_end] = 0;
                return true;
            }
        }
        return false;
    }

    /// Parse cognitive state from status line pattern
    /// Pattern: "[spinner]ToolName(args)"
    /// Example: "●Bash(sudo bpftool...)"
    /// Spinners: ●, ✶, ·, ✻, *, etc.
    fn parseStatusLine(buffer: []const u8, tool_name: *[128]u8, tool_args: *[1024]u8) bool {
        // Initialize outputs
        tool_name[0] = 0;
        tool_args[0] = 0;

        // Find opening paren
        const paren_open = std.mem.indexOf(u8, buffer, "(") orelse return false;

        // Skip leading non-alphanumeric characters (spinners, whitespace)
        var start: usize = 0;
        while (start < paren_open) : (start += 1) {
            const ch = buffer[start];
            // Check for ASCII letter (tool names start with uppercase letter)
            if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) break;
        }

        if (start >= paren_open) return false;

        // Extract potential tool name
        const potential_name = buffer[start..paren_open];
        if (potential_name.len == 0 or potential_name.len > 127) return false;

        // Verify it's a known tool name to avoid false positives
        if (!isKnownTool(potential_name)) return false;

        @memcpy(tool_name[0..potential_name.len], potential_name);
        tool_name[potential_name.len] = 0;

        // Find closing paren for args
        if (std.mem.lastIndexOf(u8, buffer, ")")) |paren_close| {
            if (paren_close > paren_open) {
                const args_len = paren_close - paren_open - 1;
                if (args_len > 0 and args_len < 1023) {
                    @memcpy(tool_args[0..args_len], buffer[paren_open + 1 .. paren_close]);
                    tool_args[args_len] = 0;
                }
            }
        }

        return true;
    }

    /// Parse spinner status line (no parentheses)
    /// Pattern: "[spinner]Word…" where spinner is non-ASCII and Word starts with uppercase
    /// Example: "●Hyperspacing…" or "✶Pontificating…"
    fn parseSpinnerStatus(buffer: []const u8, status_name: *[64]u8) bool {
        status_name[0] = 0;

        // Find first ASCII uppercase letter (start of status word)
        var start: usize = 0;
        while (start < buffer.len) : (start += 1) {
            const ch = buffer[start];
            if (ch >= 'A' and ch <= 'Z') break;
        }

        if (start >= buffer.len) return false;

        // Must have spinner before the word (non-ASCII or special char)
        if (start == 0) return false;

        // Extract the word (until non-letter or ellipsis)
        var end: usize = start;
        while (end < buffer.len and end - start < 63) : (end += 1) {
            const ch = buffer[end];
            // Stop at ellipsis (…), period, space, or non-letter
            if (ch < 'A' or (ch > 'Z' and ch < 'a') or ch > 'z') break;
        }

        const word_len = end - start;
        if (word_len < 3) return false; // Too short to be a state

        // Check if followed by ellipsis or "..." (common for spinner states)
        var has_ellipsis = false;
        if (end < buffer.len) {
            // Check for unicode ellipsis (…) or ASCII "..."
            if (buffer[end] == '.') has_ellipsis = true;
            // Unicode ellipsis is 3 bytes: 0xE2 0x80 0xA6
            if (end + 2 < buffer.len and buffer[end] == 0xE2 and buffer[end + 1] == 0x80 and buffer[end + 2] == 0xA6) {
                has_ellipsis = true;
            }
        }

        if (!has_ellipsis) return false;

        @memcpy(status_name[0..word_len], buffer[start..end]);
        status_name[word_len] = 0;
        return true;
    }

    /// Get null-terminated slice from buffer
    fn getZStr(buf: []const u8) []const u8 {
        for (buf, 0..) |ch, i| {
            if (ch == 0) return buf[0..i];
        }
        return buf;
    }

    /// Process individual cognitive event - SESSION-BASED AGGREGATION
    fn processCognitiveEvent(self: *CognitiveWatcher, event: *CognitiveEvent) !void {
        self.events_processed += 1;

        // Filter: Only process if this is actually Claude Code CLI
        if (!self.isClaudeCLI(event.pid)) {
            return; // Not Claude Code, ignore
        }

        // Extract buffer and strip ANSI codes
        const buffer = event.buffer[0..event.buf_size];

        // Strip ANSI escape sequences to get clean content
        const clean_buffer = stripAnsi(self.allocator, buffer) catch return;
        defer self.allocator.free(clean_buffer);

        // Get current time
        var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts);
        const now = ts.sec;

        // Get or create session for this PID
        const session = self.getOrCreateSession(event.pid);
        session.last_activity = now;

        var tool_name: [128]u8 = [_]u8{0} ** 128;
        var tool_args: [1024]u8 = [_]u8{0} ** 1024;
        var found_tool = false;

        // PRIORITY 1: Parse DEBUG hook pattern (most reliable)
        if (parseDebugHook(clean_buffer, &tool_name)) {
            found_tool = true;
        }

        // PRIORITY 2: Parse status line pattern (tool with args)
        if (!found_tool and parseStatusLine(clean_buffer, &tool_name, &tool_args)) {
            found_tool = true;
        }

        // PRIORITY 3: Parse spinner status (cognitive state)
        var spinner_status: [64]u8 = [_]u8{0} ** 64;
        var found_spinner = false;
        if (!found_tool and parseSpinnerStatus(clean_buffer, &spinner_status)) {
            found_spinner = true;
        }

        const tool_name_str = getZStr(&tool_name);
        const spinner_status_str = getZStr(&spinner_status);

        // Handle cognitive state changes
        if (found_spinner and spinner_status_str.len > 0) {
            const current_state = session.getState();

            // Check if state changed
            if (!std.mem.eql(u8, current_state, spinner_status_str)) {
                // Flush previous session if it had content
                if (session.state_len > 0) {
                    self.flushSession(session);
                }

                // Start new session with new state
                session.reset();
                session.pid = event.pid;
                session.setState(spinner_status_str);
                session.start_time = now;

                std.debug.print("🔄 STATE CHANGE: PID={d} → \"{s}\"\n", .{ event.pid, spinner_status_str });
            }
            return;
        }

        // Handle tool calls - add to current session
        if (found_tool and tool_name_str.len > 0) {
            // If no state yet, create one called "working"
            if (session.state_len == 0) {
                session.setState("Working");
                session.start_time = now;
            }

            session.addTool(tool_name_str);
            std.debug.print("🔧 TOOL: PID={d} State=\"{s}\" +{s} (total: {d})\n", .{
                event.pid,
                session.getState(),
                tool_name_str,
                session.tool_count,
            });
        }
    }

    /// Update chronosd-cognitive via D-Bus method call
    fn updateChronosdCognitive(self: *CognitiveWatcher, conn: *dbus.DBusConnection, state: []const u8, pid: u32) !void {
        // Create method call message for UpdateCognitiveState
        const msg = dbus.c.dbus_message_new_method_call(
            "io.quantumencoding.chronosd.cognitive",
            "/io/quantumencoding/chronosd/cognitive",
            "io.quantumencoding.chronosd.cognitive.StateManager",
            "UpdateCognitiveState",
        );
        if (msg == null) {
            std.debug.print("❌ Failed to create D-Bus message\n", .{});
            return;
        }
        defer dbus.c.dbus_message_unref(msg);

        // Append arguments: state (string) and pid (uint32)
        var args: dbus.c.DBusMessageIter = undefined;
        dbus.c.dbus_message_iter_init_append(msg, &args);

        // Append state string
        const state_z = self.allocator.dupeZ(u8, state) catch {
            std.debug.print("❌ Failed to allocate state string for D-Bus\n", .{});
            return;
        };
        defer self.allocator.free(state_z);

        const state_ptr: [*:0]const u8 = state_z.ptr;
        if (dbus.c.dbus_message_iter_append_basic(&args, dbus.c.DBUS_TYPE_STRING, @ptrCast(&state_ptr)) == 0) {
            std.debug.print("❌ Failed to append state to D-Bus message\n", .{});
            return;
        }

        // Append pid (u32)
        var pid_val: u32 = pid;
        if (dbus.c.dbus_message_iter_append_basic(&args, dbus.c.DBUS_TYPE_UINT32, &pid_val) == 0) {
            std.debug.print("❌ Failed to append pid to D-Bus message\n", .{});
            return;
        }

        // Send method call (non-blocking, no reply)
        if (dbus.c.dbus_connection_send(conn.conn, msg, null) == 0) {
            std.debug.print("❌ Failed to send D-Bus message\n", .{});
            return;
        }

        dbus.c.dbus_connection_flush(conn.conn);
        std.debug.print("📡 D-Bus UpdateCognitiveState(\"{s}\", {d})\n", .{ state, pid });
    }

    /// Try to load cognitive-oracle eBPF program
    pub fn loadCognitiveOracle(self: *CognitiveWatcher) !void {
        std.debug.print("🔮 Loading cognitive-oracle eBPF program...\n", .{});

        // Check if cognitive-oracle.bpf.o exists (try installed location first, then local)
        const bpf_obj_path = "/usr/local/lib/bpf/cognitive-oracle.bpf.o";

        // Check if file exists by trying to open it
        const fd = std.posix.openatZ(std.c.AT.FDCWD, bpf_obj_path, .{ .ACCMODE = .RDONLY }, 0) catch {
            std.debug.print("⚠️  eBPF object not found at {s}\n", .{bpf_obj_path});
            return error.BpfObjectNotFound;
        };
        _ = std.c.close(fd);

        // Open BPF object
        const obj = c.bpf_object__open(@ptrCast(bpf_obj_path));
        if (obj == null) {
            std.debug.print("❌ Failed to open BPF object: {s}\n", .{bpf_obj_path});
            return error.BpfOpenFailed;
        }
        defer _ = c.bpf_object__close(obj);

        // Load BPF program into kernel
        if (c.bpf_object__load(obj) != 0) {
            std.debug.print("❌ Failed to load BPF object into kernel\n", .{});
            return error.BpfLoadFailed;
        }

        std.debug.print("✓ Cognitive oracle loaded into kernel\n", .{});

        // CRITICAL: Find and attach the program to the tracepoint
        const prog = c.bpf_object__find_program_by_name(obj, "trace_write_enter");
        if (prog == null) {
            std.debug.print("❌ Failed to find program 'trace_write_enter'\n", .{});
            return error.ProgramNotFound;
        }

        const link = c.bpf_program__attach(prog);
        if (link == null) {
            std.debug.print("❌ Failed to attach program to tracepoint\n", .{});
            return error.AttachFailed;
        }

        std.debug.print("✓ Program attached to sys_enter_write tracepoint\n", .{});

        // Enable the cognitive oracle
        const config_map = c.bpf_object__find_map_by_name(obj, "cognitive_config");
        if (config_map == null) {
            return error.MapNotFound;
        }

        const config_fd = c.bpf_map__fd(config_map);
        var key: u32 = 0;
        var value: u32 = 1; // Enable

        if (c.bpf_map_update_elem(config_fd, &key, &value, c.BPF_ANY) != 0) {
            return error.MapUpdateFailed;
        }

        std.debug.print("✓ Cognitive oracle enabled\n", .{});

        // Get ring buffer map
        const rb_map = c.bpf_object__find_map_by_name(obj, "cognitive_events");
        if (rb_map == null) {
            return error.RingBufferNotFound;
        }

        const rb_fd = c.bpf_map__fd(rb_map);

        std.debug.print("✓ Ring buffer FD: {d}\n", .{rb_fd});
        std.debug.print("🔮 Beginning eternal vigil over Claude's cognitive whispers...\n\n", .{});

        // Create ring buffer consumer
        const ring_buffer = c.ring_buffer__new(
            rb_fd,
            handleCognitiveEvent,
            @ptrCast(self),
            null,
        );

        if (ring_buffer == null) {
            return error.RingBufferCreateFailed;
        }
        defer c.ring_buffer__free(ring_buffer);

        // Poll ring buffer forever
        while (self.running.load(.acquire)) {
            const poll_result = c.ring_buffer__poll(ring_buffer, 100); // 100ms timeout
            if (poll_result < 0) {
                std.debug.print("❌ Ring buffer poll error: {d}\n", .{poll_result});
                var sleep_ts = linux.timespec{ .sec = 1, .nsec = 0 };
                _ = linux.nanosleep(&sleep_ts, null);
                continue;
            }
        }
    }

    /// Run the watcher
    pub fn run(self: *CognitiveWatcher) !void {
        // Try to load and consume cognitive oracle events
        self.loadCognitiveOracle() catch |err| {
            std.debug.print("⚠️  Failed to load cognitive oracle: {any}\n", .{err});
            std.debug.print("   Possible causes:\n", .{});
            std.debug.print("   - cognitive-oracle.bpf.o not compiled\n", .{});
            std.debug.print("   - Insufficient permissions (need CAP_BPF or root)\n", .{});
            std.debug.print("   - Kernel doesn't support eBPF\n", .{});
            return err;
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var watcher = try CognitiveWatcher.init(allocator);
    defer watcher.deinit();

    // Handle SIGINT/SIGTERM for graceful shutdown
    // (simplified for now)

    try watcher.run();
}
