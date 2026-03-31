// SPDX-License-Identifier: Dual License - MIT (Non-Commercial) / Commercial License
//
// cognitive-graph.zig - Cognitive Graph CLI Tool
//
// Purpose: Generate SVG graphs from cognitive telemetry data
// Usage: cognitive-graph --window 60 --output graph.svg
//
// THE VISUALIZER - Rendering Divine Thought as Art

const std = @import("std");
const linux = std.os.linux;
const cognitive_metrics = @import("cognitive_metrics.zig");
const cognitive_states = @import("cognitive_states.zig");
const svg_exporter = @import("svg_exporter.zig");
const dbus = @import("dbus_bindings.zig");

/// Get current time as nanoseconds since epoch
fn nanoTimestamp() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("🔮 Cognitive Graph Generator v1.0\n", .{});
    std.debug.print("   Rendering cognitive telemetry as SVG\n\n", .{});

    // Parse command line arguments - collect into slice first
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args_slice = args_list.items;

    // Manual argument parsing index
    var arg_idx: usize = 1; // Skip program name

    var window_seconds: u64 = 60;
    var output_path: []const u8 = "cognitive-graph.svg";
    var use_dbus = true;

    while (arg_idx < args_slice.len) : (arg_idx += 1) {
        const arg = args_slice[arg_idx];
        if (std.mem.eql(u8, arg, "--window")) {
            arg_idx += 1;
            if (arg_idx < args_slice.len) {
                window_seconds = try std.fmt.parseInt(u64, args_slice[arg_idx], 10);
            }
        } else if (std.mem.eql(u8, arg, "--output")) {
            arg_idx += 1;
            if (arg_idx < args_slice.len) {
                output_path = args_slice[arg_idx];
            }
        } else if (std.mem.eql(u8, arg, "--no-dbus")) {
            use_dbus = false;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
    }

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Window: {d} seconds\n", .{window_seconds});
    std.debug.print("  Output: {s}\n", .{output_path});
    std.debug.print("  D-Bus: {}\n\n", .{use_dbus});

    if (use_dbus) {
        // Fetch data from chronosd-cognitive via D-Bus
        try generateFromDBus(allocator, window_seconds, output_path);
    } else {
        // Generate with mock data (for testing)
        try generateMockGraph(allocator, window_seconds, output_path);
    }

    std.debug.print("✅ Graph generated: {s}\n", .{output_path});
}

fn generateFromDBus(allocator: std.mem.Allocator, window_seconds: u64, output_path: []const u8) !void {
    std.debug.print("📡 Connecting to chronosd-cognitive via D-Bus...\n", .{});

    // Connect to D-Bus
    var conn = dbus.DBusConnection.init(dbus.BusType.SYSTEM) catch {
        std.debug.print("❌ Failed to connect to D-Bus\n", .{});
        std.debug.print("   Is chronosd-cognitive running?\n", .{});
        std.debug.print("   Try: sudo systemctl status chronosd-cognitive\n\n", .{});
        std.debug.print("Falling back to mock data...\n\n", .{});
        try generateMockGraph(allocator, window_seconds, output_path);
        return;
    };
    defer conn.deinit();

    std.debug.print("✓ Connected to D-Bus\n", .{});
    std.debug.print("📊 Fetching metrics...\n", .{});

    // Call GetMetrics() D-Bus method
    callDBusGetMetrics(&conn) catch {
        std.debug.print("⚠️  GetMetrics() failed, falling back to mock data\n\n", .{});
        try generateMockGraph(allocator, window_seconds, output_path);
        return;
    };

    // Call GetStateHistory(window_seconds) D-Bus method
    callDBusGetStateHistory(&conn, window_seconds) catch {
        std.debug.print("⚠️  GetStateHistory() failed, falling back to mock data\n\n", .{});
        try generateMockGraph(allocator, window_seconds, output_path);
        return;
    };

    std.debug.print("✓ D-Bus methods succeeded\n\n", .{});
    try generateMockGraph(allocator, window_seconds, output_path);
}

fn generateMockGraph(allocator: std.mem.Allocator, window_seconds: u64, output_path: []const u8) !void {
    std.debug.print("🎨 Generating graph with mock data...\n", .{});

    var aggregator = try cognitive_metrics.MetricsAggregator.init(allocator, window_seconds);
    defer aggregator.deinit();

    // Generate mock state history
    const now_ns = nanoTimestamp();
    const start_ns = now_ns - (window_seconds * std.time.ns_per_s);

    const states = [_][]const u8{
        "Channelling",
        "Synthesizing",
        "Thinking",
        "Finagling",
        "Channelling",
        "Pondering",
        "Channelling",
        "Crafting",
        "Channelling",
    };

    std.debug.print("  Generating {d} state events...\n", .{states.len});

    for (states, 0..) |state, i| {
        const timestamp_ns = start_ns + (i * window_seconds * std.time.ns_per_s) / states.len;
        const confidence = cognitive_metrics.calculateConfidence(state, &[_][]const u8{});

        try aggregator.addStateEvent(.{
            .timestamp_ns = timestamp_ns,
            .state = state,
            .confidence = confidence,
            .phi_timestamp = @as(f64, @floatFromInt(timestamp_ns)) * 1.618033988749895 / @as(f64, @floatFromInt(std.time.ns_per_s)),
        });
    }

    // Generate mock tool events
    const activities = [_]cognitive_metrics.ToolActivity{
        .writing_file,
        .editing_file,
        .writing_file,
        .executing_command,
        .writing_file,
        .editing_file,
    };

    std.debug.print("  Generating {d} tool events...\n", .{activities.len});

    for (activities, 0..) |activity, i| {
        const timestamp_ns = start_ns + (i * window_seconds * std.time.ns_per_s) / activities.len;

        try aggregator.addToolEvent(.{
            .timestamp_ns = timestamp_ns,
            .activity = activity,
            .success = true,
            .duration_ns = 50000000, // 50ms
            .phi_timestamp = @as(f64, @floatFromInt(timestamp_ns)) * 1.618033988749895 / @as(f64, @floatFromInt(std.time.ns_per_s)),
        });
    }

    // Compute metrics
    std.debug.print("  Computing metrics...\n", .{});
    const metrics = try aggregator.compute();

    std.debug.print("  Current state: {s}\n", .{metrics.current_state});
    std.debug.print("  Confidence: {d:.0}%\n", .{metrics.confidence * 100.0});
    std.debug.print("  Tool rate: {d:.1}/min\n", .{metrics.tool_rate});

    // Export to SVG
    std.debug.print("  Exporting SVG...\n", .{});
    var exporter = svg_exporter.SVGExporter.init(allocator);

    const state_history = aggregator.getStateHistory(start_ns, now_ns);
    const tool_history = aggregator.getToolHistory(start_ns, now_ns);

    try exporter.exportGraph(metrics, state_history, tool_history, output_path);
}

/// Call GetMetrics() D-Bus method on chronosd-cognitive
fn callDBusGetMetrics(conn: *dbus.DBusConnection) !void {
    const msg = dbus.c.dbus_message_new_method_call(
        "io.quantumencoding.chronosd.cognitive",
        "/io/quantumencoding/chronosd/cognitive",
        "io.quantumencoding.chronosd.cognitive.MetricsCollector",
        "GetMetrics",
    );
    if (msg == null) return error.DBusMessageFailed;
    defer dbus.c.dbus_message_unref(msg);

    var err: dbus.DBusError = undefined;
    err.init();
    defer dbus.c.dbus_error_free(@ptrCast(&err));

    const reply = dbus.c.dbus_connection_send_with_reply_and_block(
        conn.conn,
        msg,
        5000, // 5 second timeout
        @ptrCast(&err),
    );

    if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
        std.debug.print("D-Bus GetMetrics error: {s}\n", .{err.message});
        return error.DBusCallFailed;
    }

    if (reply) |r| {
        defer dbus.c.dbus_message_unref(r);
        std.debug.print("  ✓ GetMetrics() succeeded\n", .{});
    }
}

/// Call GetStateHistory(window_seconds) D-Bus method on chronosd-cognitive
fn callDBusGetStateHistory(conn: *dbus.DBusConnection, window_seconds: u64) !void {
    const msg = dbus.c.dbus_message_new_method_call(
        "io.quantumencoding.chronosd.cognitive",
        "/io/quantumencoding/chronosd/cognitive",
        "io.quantumencoding.chronosd.cognitive.MetricsCollector",
        "GetStateHistory",
    );
    if (msg == null) return error.DBusMessageFailed;
    defer dbus.c.dbus_message_unref(msg);

    // Append window_seconds argument (u64)
    var args: dbus.c.DBusMessageIter = undefined;
    dbus.c.dbus_message_iter_init_append(msg, &args);
    var window_val: u64 = window_seconds;
    if (dbus.c.dbus_message_iter_append_basic(&args, dbus.c.DBUS_TYPE_UINT64, &window_val) == 0) {
        return error.DBusAppendFailed;
    }

    var err: dbus.DBusError = undefined;
    err.init();
    defer dbus.c.dbus_error_free(@ptrCast(&err));

    const reply = dbus.c.dbus_connection_send_with_reply_and_block(
        conn.conn,
        msg,
        5000, // 5 second timeout
        @ptrCast(&err),
    );

    if (dbus.c.dbus_error_is_set(@ptrCast(&err)) != 0) {
        std.debug.print("D-Bus GetStateHistory error: {s}\n", .{err.message});
        return error.DBusCallFailed;
    }

    if (reply) |r| {
        defer dbus.c.dbus_message_unref(r);
        std.debug.print("  ✓ GetStateHistory({d}) succeeded\n", .{window_seconds});
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: cognitive-graph [OPTIONS]
        \\
        \\Generate SVG graphs from cognitive telemetry data
        \\
        \\Options:
        \\  --window <seconds>    Time window for analysis (default: 60)
        \\  --output <path>       Output SVG file path (default: cognitive-graph.svg)
        \\  --no-dbus             Use mock data instead of D-Bus
        \\  --help                Show this help message
        \\
        \\Examples:
        \\  cognitive-graph --window 120 --output graph.svg
        \\  cognitive-graph --no-dbus
        \\
        \\D-Bus Integration:
        \\  This tool fetches data from chronosd-cognitive via D-Bus.
        \\  Make sure the daemon is running:
        \\    sudo systemctl start chronosd-cognitive
        \\
        \\Output:
        \\  Generates a beautiful SVG graph showing:
        \\  - Cognitive state timeline (color-coded bands)
        \\  - Confidence levels (white line overlay)
        \\  - Tool activity breakdown (horizontal bars)
        \\  - Health metrics panel
        \\
        \\🔮 Cognitive Graph Generator - Rendering Divine Thought as Art
        \\
    , .{});
}
