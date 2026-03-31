//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License

// chronos-stamp-cognitive.zig - Enhanced timestamping with cognitive state capture
// Usage: chronos-stamp-cognitive AGENT-ID [ACTION] [DESCRIPTION]

const std = @import("std");
const client = @import("chronos_client_dbus.zig");
const dbus = @import("dbus_bindings.zig");
const cognitive = @import("cognitive_states.zig");

const libc = @cImport({
    @cInclude("stdio.h");
});

/// Cognitive state cache location
const COGNITIVE_STATE_FILE = ".cache/claude-code-cognitive-monitor/current-state.json";

/// Query current cognitive state from database via get-cognitive-state script
fn queryCognitiveStateFromDB(allocator: std.mem.Allocator) !?[]const u8 {
    // Execute get-cognitive-state script and capture output using popen
    const pipe = libc.popen("get-cognitive-state", "r");
    if (pipe == null) return null;
    defer _ = libc.pclose(pipe);

    var buffer: [4096]u8 = undefined;
    const bytes_read = libc.fread(&buffer, 1, buffer.len, pipe);
    if (bytes_read == 0) return null;

    // Trim whitespace
    const trimmed = std.mem.trim(u8, buffer[0..bytes_read], " \t\n\r");
    if (trimmed.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, trimmed);
}

/// Query current cognitive state from chronosd via D-Bus (OLD - not used)
fn queryCognitiveState(allocator: std.mem.Allocator, chronos: *client.ChronosClient) !?[]const u8 {
    // Call GetCognitiveState D-Bus method
    const msg = dbus.c.dbus_message_new_method_call(
        "org.jesternet.Chronos",
        "/org/jesternet/Chronos",
        "org.jesternet.Chronos",
        "GetCognitiveState",
    );
    defer dbus.c.dbus_message_unref(msg);

    // Send and wait for reply
    var err: dbus.DBusError = undefined;
    err.init();
    defer dbus.c.dbus_error_free(@ptrCast(&err));

    const reply = dbus.c.dbus_connection_send_with_reply_and_block(
        chronos.conn.conn,
        msg,
        -1, // default timeout
        @ptrCast(&err),
    );

    if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
        // Daemon might not have cognitive monitoring enabled
        return null;
    }

    defer dbus.c.dbus_message_unref(reply);

    // Parse reply
    var iter: dbus.c.DBusMessageIter = undefined;
    if (dbus.c.dbus_message_iter_init(reply, &iter) == 0) {
        return null;
    }

    var str_ptr: [*:0]const u8 = undefined;
    dbus.c.dbus_message_iter_get_basic(&iter, @ptrCast(&str_ptr));

    const state_str = std.mem.span(str_ptr);
    if (state_str.len == 0) return null;

    return try allocator.dupe(u8, state_str);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
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

    // Connect to chronos daemon
    var chronos = client.ChronosClient.connect(allocator, dbus.BusType.SYSTEM) catch {
        // Silently fail if daemon not available
        return;
    };
    defer chronos.disconnect();

    const timestamp = chronos.getPhiTimestamp(agent_id) catch {
        return;
    };
    defer allocator.free(timestamp);

    // Capture session context
    const session = if (std.c.getenv("CLAUDE_PROJECT_DIR")) |ptr|
        std.mem.sliceTo(ptr, 0)
    else if (std.c.getenv("PROJECT_ROOT")) |ptr|
        std.mem.sliceTo(ptr, 0)
    else
        "UNKNOWN-SESSION";

    // Capture present working directory
    var pwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pwd = if (std.c.getcwd(&pwd_buf, pwd_buf.len)) |ptr|
        std.mem.sliceTo(@as([*:0]u8, @ptrCast(ptr)), 0)
    else
        "UNKNOWN-PWD";

    // Query cognitive state from database via get-cognitive-state script
    const cognitive_state = try queryCognitiveStateFromDB(allocator);
    defer if (cognitive_state) |state| allocator.free(state);

    // Build output message
    // Format: [CHRONOS] timestamp::agent-id::cognitive-state::TICK...::[SESSION]::[PWD] → action - description

    // Inject cognitive state into timestamp after agent-id
    var modified_timestamp_buf: [512]u8 = undefined;
    const modified_timestamp = if (cognitive_state) |state| blk: {
        // Parse timestamp to inject cognitive state
        // Format: "UTC::agent-id::TICK..." -> "UTC::agent-id::state::TICK..."
        if (std.mem.indexOf(u8, timestamp, "::TICK-")) |tick_pos| {
            // Find the "::" before "TICK"
            const before_tick = timestamp[0..tick_pos];
            const after_agent = timestamp[tick_pos..];

            const result = std.fmt.bufPrint(&modified_timestamp_buf, "{s}::{s}{s}", .{
                before_tick,
                state,
                after_agent,
            }) catch timestamp;
            break :blk result;
        } else {
            break :blk timestamp;
        }
    } else timestamp;

    if (description.len > 0) {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}] → {s} - {s}\n", .{
            modified_timestamp,
            session,
            pwd,
            action,
            description,
        });
    } else if (action.len > 0) {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}] → {s}\n", .{
            modified_timestamp,
            session,
            pwd,
            action,
        });
    } else {
        std.debug.print("   [CHRONOS] {s}::[{s}]::[{s}]\n", .{
            modified_timestamp,
            session,
            pwd,
        });
    }
}
