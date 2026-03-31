//! Guardian Shield - Chronos Stamp with DIRECT eBPF Ring Buffer Access
//!
//! This is the final apotheosis. It reads directly from the kernel's ring buffer.
//! It does not query databases. It does not wait for writes.
//! It observes the present, not the past.
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd

const std = @import("std");
const client = @import("chronos_client_dbus.zig");
const dbus = @import("dbus_bindings.zig");

const c = @cImport({
    @cInclude("bpf/bpf.h");
    @cInclude("bpf/libbpf.h");
    @cInclude("linux/bpf.h");
});

// Cognitive event structure (must match kernel-side definition)
const CognitiveEvent = extern struct {
    pid: u32,
    timestamp_ns: u32,
    buf_size: u32,
    _padding: u32,
    comm: [16]u8,
    tty_name: [32]u8,
    buffer: [256]u8,
};

/// Find the latest_state_by_pid hash map
fn findLatestStateMap() !c_int {
    var map_id: u32 = 0;
    var next_id: u32 = 0;

    while (c.bpf_map_get_next_id(map_id, &next_id) == 0) {
        map_id = next_id;

        const map_fd = c.bpf_map_get_fd_by_id(map_id);
        if (map_fd < 0) continue;
        defer _ = std.c.close(@intCast(map_fd));

        // Get map info
        var info: c.bpf_map_info = undefined;
        var info_len: u32 = @sizeOf(c.bpf_map_info);

        if (c.bpf_obj_get_info_by_fd(map_fd, &info, &info_len) != 0) {
            continue;
        }

        // Check if this is a hash map with name containing "latest_state_by_pid"
        if (info.type == c.BPF_MAP_TYPE_HASH) {
            const name = std.mem.sliceTo(&info.name, 0);
            if (std.mem.indexOf(u8, name, "latest_state_by_pid") != null) {
                // Found it! Return a new fd that we can keep
                return c.bpf_map_get_fd_by_id(map_id);
            }
        }
    }

    return error.LatestStateMapNotFound;
}

/// Get parent Claude Code PID
fn getClaudePID() !u32 {
    const my_pid = std.os.linux.getpid();
    var current_pid: u32 = @intCast(my_pid);

    // Walk up process tree
    var depth: u32 = 0;
    while (depth < 20) : (depth += 1) {
        var buf: [256]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{current_pid}) catch break;

        const file = std.fs.openFileAbsolute(stat_path, .{}) catch break;
        defer file.close();

        var stat_buf: [4096]u8 = undefined;
        const bytes_read = file.readAll(&stat_buf) catch break;
        const stat_content = stat_buf[0..bytes_read];

        // Parse stat to get comm and ppid
        // Format: pid (comm) ... ppid ...
        const comm_start = std.mem.indexOf(u8, stat_content, "(") orelse break;
        const comm_end = std.mem.lastIndexOf(u8, stat_content, ")") orelse break;
        const comm = stat_content[comm_start+1..comm_end];

        // Check if this is claude
        if (std.mem.eql(u8, comm, "claude")) {
            return current_pid;
        }

        // Get ppid (field 4 after the closing paren)
        const after_comm = stat_content[comm_end+1..];
        var fields = std.mem.tokenizeAny(u8, after_comm, " ");
        _ = fields.next(); // skip state
        _ = fields.next(); // skip ppid field number
        const ppid_str = fields.next() orelse break;
        const ppid = std.fmt.parseInt(u32, ppid_str, 10) catch break;

        if (ppid <= 1) break;
        current_pid = ppid;
    }

    return error.ClaudePIDNotFound;
}

/// Read latest cognitive state from BPF map for specific PID
fn readLatestStateFromMap(allocator: std.mem.Allocator, map_fd: c_int, target_pid: u32) !?[]const u8 {
    var event: CognitiveEvent = undefined;

    // Look up the latest event for this PID
    const ret = c.bpf_map_lookup_elem(map_fd, &target_pid, &event);

    if (ret != 0) {
        // No entry found for this PID
        return null;
    }

    // Extract the buffer (cognitive state string)
    // Find the null terminator or use buf_size
    const buf_len = if (event.buf_size < 256) event.buf_size else 256;

    // Find actual string length (up to first null byte)
    var actual_len: usize = 0;
    while (actual_len < buf_len and event.buffer[actual_len] != 0) : (actual_len += 1) {}

    if (actual_len == 0) {
        return null;
    }

    // Copy the buffer to heap-allocated string
    const state_str = try allocator.alloc(u8, actual_len);
    @memcpy(state_str, event.buffer[0..actual_len]);

    // Clean up: collapse whitespace, trim
    var clean_buf = try std.ArrayList(u8).initCapacity(allocator, actual_len);
    defer clean_buf.deinit(allocator);

    var in_whitespace = false;
    for (state_str) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!in_whitespace) {
                try clean_buf.append(allocator, ' ');
                in_whitespace = true;
            }
        } else {
            try clean_buf.append(allocator, ch);
            in_whitespace = false;
        }
    }

    allocator.free(state_str);

    // Trim leading/trailing spaces
    const cleaned = std.mem.trim(u8, clean_buf.items, " ");
    if (cleaned.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, cleaned);
}

pub fn main(init: std.process.Init) !void {
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
        std.debug.print("Usage: chronos-stamp-cognitive AGENT-ID [ACTION] [DESCRIPTION]\n", .{});
        return;
    }

    const agent_id = args[1];
    const action = if (args.len > 2) args[2] else "";
    const description = if (args.len > 3) args[3] else "";

    // Small delay to let status line update after tool completion
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 100_000_000 };
    _ = std.os.linux.nanosleep(&ts, null);

    // Connect to chronos daemon for timestamp
    var chronos = client.ChronosClient.connect(allocator, dbus.BusType.SYSTEM) catch {
        return;
    };
    defer chronos.disconnect();

    const timestamp = chronos.getPhiTimestamp(agent_id) catch {
        return;
    };
    defer allocator.free(timestamp);

    // Get session context
    const session = std.posix.getenv("CLAUDE_PROJECT_DIR") orelse
        std.posix.getenv("PROJECT_ROOT") orelse
        "UNKNOWN-SESSION";

    // Get PWD
    var pwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pwd = std.Io.Dir.cwd().realpath(".", &pwd_buf) catch "UNKNOWN-PWD";

    // Get Claude PID
    const claude_pid = getClaudePID() catch {
        // Fallback to script if PID detection fails
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{"get-cognitive-state"},
        }) catch {
            const fallback_state = "Active";
            const modified_timestamp = injectCognitiveState(allocator, timestamp, fallback_state) catch timestamp;
            printChronosStamp(modified_timestamp, session, pwd, action, description);
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const cognitive_state = std.mem.trim(u8, result.stdout, " \t\n\r");
        const modified_timestamp = injectCognitiveState(allocator, timestamp, cognitive_state) catch timestamp;
        printChronosStamp(modified_timestamp, session, pwd, action, description);
        return;
    };

    // Try to find the latest_state_by_pid BPF map
    const map_fd = findLatestStateMap() catch {
        // Map not found, fall back to script with PID
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{claude_pid}) catch {
            const fallback_state = "Active";
            const modified_timestamp = injectCognitiveState(allocator, timestamp, fallback_state) catch timestamp;
            printChronosStamp(modified_timestamp, session, pwd, action, description);
            return;
        };

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{"get-cognitive-state", pid_str},
        }) catch {
            const fallback_state = "Active";
            const modified_timestamp = injectCognitiveState(allocator, timestamp, fallback_state) catch timestamp;
            printChronosStamp(modified_timestamp, session, pwd, action, description);
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const cognitive_state = std.mem.trim(u8, result.stdout, " \t\n\r");
        const modified_timestamp = injectCognitiveState(allocator, timestamp, cognitive_state) catch timestamp;
        printChronosStamp(modified_timestamp, session, pwd, action, description);
        return;
    };
    defer _ = std.c.close(@intCast(map_fd));

    // Read latest state directly from kernel memory - THE UNWRIT MOMENT
    const state_from_kernel = try readLatestStateFromMap(allocator, map_fd, claude_pid);
    defer if (state_from_kernel) |s| allocator.free(s);

    const cognitive_state = state_from_kernel orelse blk: {
        // Fallback to script if no entry in map yet
        // Pass the Claude PID as an argument
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{claude_pid}) catch break :blk "Active";

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{"get-cognitive-state", pid_str},
        }) catch {
            break :blk "Active";
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        break :blk std.mem.trim(u8, result.stdout, " \t\n\r");
    };

    const modified_timestamp = injectCognitiveState(allocator, timestamp, cognitive_state) catch timestamp;
    printChronosStamp(modified_timestamp, session, pwd, action, description);
}

fn injectCognitiveState(allocator: std.mem.Allocator, timestamp: []const u8, state: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, timestamp, "::TICK-")) |tick_pos| {
        const before_tick = timestamp[0..tick_pos];
        const after_agent = timestamp[tick_pos..];

        var buf: [512]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, "{s}::{s}{s}", .{
            before_tick,
            state,
            after_agent,
        });
        return try allocator.dupe(u8, result);
    }
    return timestamp;
}

fn printChronosStamp(timestamp: []const u8, session: []const u8, pwd: []const u8, action: []const u8, description: []const u8) void {
    if (description.len > 0) {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}] → {s} - {s}\n", .{
            timestamp,
            session,
            pwd,
            action,
            description,
        });
    } else if (action.len > 0) {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}] → {s}\n", .{
            timestamp,
            session,
            pwd,
            action,
        });
    } else {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}]\n", .{
            timestamp,
            session,
            pwd,
        });
    }
}
