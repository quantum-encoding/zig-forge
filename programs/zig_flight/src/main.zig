//! zig-flight — X-Plane 12 Avionics MFD
//!
//! Full-screen TUI display with 5 pages: PFD, NAV, EICAS, FMS, STATUS.
//! Alert system evaluates each frame against aircraft envelope limits.
//! Interactive commands adjust autopilot settings in real time.
//! Demo mode records/plays flights without X-Plane.
//!
//! Usage: zig-flight [--host HOST] [--port PORT] [--aircraft TYPE]
//!                   [--record FILE] [--play FILE]

const std = @import("std");
const Io = std.Io;
const flight = @import("zig-flight");
const limits = flight.limits;
const demo_mod = flight.demo;

extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

const Mode = enum { live, record, play };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    // Stdout for pre-TUI messages, stderr for errors
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Parse args
    var host: []const u8 = "localhost";
    var port: u16 = 8086;
    var aircraft_limits: limits.AircraftLimits = limits.GENERIC_JET;
    var mode: Mode = .live;
    var demo_path: ?[*:0]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 8086;
        } else if (std.mem.eql(u8, arg, "--aircraft") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "cessna172")) {
                aircraft_limits = limits.CESSNA_172;
            } else if (std.mem.eql(u8, args[i], "transport")) {
                aircraft_limits = limits.TRANSPORT;
            }
        } else if (std.mem.eql(u8, arg, "--record") and i + 1 < args.len) {
            i += 1;
            mode = .record;
            demo_path = @ptrCast(args[i].ptr);
        } else if (std.mem.eql(u8, arg, "--play") and i + 1 < args.len) {
            i += 1;
            mode = .play;
            demo_path = @ptrCast(args[i].ptr);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print(
                \\zig-flight — X-Plane 12 Avionics MFD
                \\
                \\Full-screen terminal display with 5 avionics pages.
                \\Connects to X-Plane 12's Web API for real-time flight data.
                \\
                \\Usage: zig-flight [OPTIONS]
                \\
                \\Options:
                \\  --host HOST      X-Plane host (default: localhost)
                \\  --port PORT      X-Plane API port (default: 8086)
                \\  --aircraft TYPE  Aircraft preset: jet, cessna172, transport (default: jet)
                \\  --record FILE    Record flight data to file (requires X-Plane connection)
                \\  --play FILE      Play back a recorded flight (no X-Plane needed)
                \\  -h, --help       Show this help
                \\
                \\Page keys:
                \\  1-5    Switch pages (PFD, NAV, EICAS, FMS, STATUS)
                \\  q      Quit
                \\
                \\Command keys (live mode):
                \\  a      Toggle autopilot
                \\  h/H    Heading +1/-1
                \\  v/V    Altitude +100/-100
                \\  s/S    Speed +1/-1
                \\  w/W    VS +100/-100
                \\
            , .{});
            try stdout.flush();
            return;
        }
    }

    switch (mode) {
        .play => {
            const path = demo_path orelse {
                try stderr.print("Error: --play requires a file path\n", .{});
                try stderr.flush();
                return;
            };
            try runDemoPlayback(stdout, stderr, path, aircraft_limits);
        },
        .live, .record => {
            try runLiveMode(stdout, stderr, arena, host, port, aircraft_limits, mode, demo_path);
        },
    }
}

fn runDemoPlayback(
    stdout: anytype,
    stderr: anytype,
    path: [*:0]const u8,
    aircraft_limits: limits.AircraftLimits,
) !void {
    try stdout.print("zig_flight MFD — Demo playback mode\n", .{});
    try stdout.flush();

    var player = demo_mod.DemoPlayer.init(path) catch |err| {
        try stderr.print("Error: cannot open demo file: {any}\n", .{err});
        try stderr.flush();
        return;
    };
    defer player.deinit();

    try stdout.print("Loaded {d} frames. Entering TUI mode...\n", .{player.frameCount()});
    try stdout.flush();

    // Enter TUI
    const tui = flight.display.tui_backend;
    var raw_mode = tui.RawMode.enter(std.posix.STDIN_FILENO) catch {
        try stderr.print("Error: cannot enter raw mode. Not a terminal?\n", .{});
        try stderr.flush();
        return;
    };
    defer raw_mode.exit();

    tui.enterAltScreen();
    tui.hideCursor();
    defer {
        tui.showCursor();
        tui.exitAltScreen();
    }

    var mfd = flight.display.mfd.Mfd.init();
    mfd.aircraft_limits = aircraft_limits;
    mfd.demo_mode = true;
    var fd = flight.FlightData{};
    var dummy_reg = flight.DatarefRegistry.init();

    // 100ms sleep for 10Hz playback
    const sleep_ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };

    while (!mfd.quit_requested) {
        const key = tui.readKey();
        if (key != 0) {
            _ = mfd.handleInput(key, &fd);
        }

        if (!player.nextFrame(&fd)) {
            // Loop playback
            player.reset();
            if (!player.nextFrame(&fd)) break; // Empty recording
        }
        fd.computeDerived();

        mfd.render(&fd, &dummy_reg);
        _ = nanosleep(&sleep_ts, null);
    }
}

fn runLiveMode(
    stdout: anytype,
    stderr: anytype,
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    aircraft_limits: limits.AircraftLimits,
    mode: Mode,
    demo_path: ?[*:0]const u8,
) !void {
    try stdout.print("zig_flight MFD — Connecting to {s}:{d}...\n", .{ host, port });
    try stdout.flush();

    // Initialize client
    var client = flight.XPlaneClient.init(arena, host, port) catch |err| {
        try stderr.print("Error: failed to init client: {any}\n", .{err});
        try stderr.flush();
        return;
    };
    defer client.deinit();

    // Resolve datarefs
    try stdout.print("Resolving datarefs...\n", .{});
    try stdout.flush();

    var registry = flight.DatarefRegistry.init();
    registry.resolveAll(&client) catch |err| {
        try stderr.print("Error: failed to resolve datarefs: {any}\n", .{err});
        try stderr.print("Is X-Plane 12 running with the Web API enabled on port {d}?\n", .{port});
        try stderr.flush();
        return;
    };

    try stdout.print("Resolved {d} datarefs.\n", .{registry.count});
    try stdout.flush();

    if (registry.count == 0) {
        try stderr.print("Error: no datarefs resolved. Check X-Plane connection.\n", .{});
        try stderr.flush();
        return;
    }

    // Connect WebSocket
    try stdout.print("Connecting WebSocket...\n", .{});
    try stdout.flush();

    client.connectWebSocket() catch |err| {
        try stderr.print("Error: WebSocket connect failed: {any}\n", .{err});
        try stderr.flush();
        return;
    };

    registry.subscribeAll(&client) catch |err| {
        try stderr.print("Error: subscribe failed: {any}\n", .{err});
        try stderr.flush();
        return;
    };

    // Start recorder if in record mode
    var recorder: ?demo_mod.DemoRecorder = null;
    if (mode == .record) {
        if (demo_path) |path| {
            if (demo_mod.DemoRecorder.init(path)) |rec| {
                recorder = rec;
                try stdout.print("Recording to file...\n", .{});
                try stdout.flush();
            } else |err| {
                try stderr.print("Warning: cannot open record file: {any}\n", .{err});
                try stderr.flush();
            }
        }
    }
    defer {
        if (recorder) |*rec| rec.finish();
    }

    try stdout.print("Connected. Entering TUI mode...\n", .{});
    try stdout.flush();

    // === Enter TUI mode ===
    const tui = flight.display.tui_backend;

    var raw_mode = tui.RawMode.enter(std.posix.STDIN_FILENO) catch {
        try stderr.print("Error: cannot enter raw mode. Not a terminal?\n", .{});
        try stderr.flush();
        return;
    };
    defer raw_mode.exit();

    tui.enterAltScreen();
    tui.hideCursor();
    defer {
        tui.showCursor();
        tui.exitAltScreen();
    }

    // Initialize MFD and flight data
    var mfd = flight.display.mfd.Mfd.init();
    mfd.aircraft_limits = aircraft_limits;
    mfd.client = &client;
    mfd.registry = &registry;
    var fd = flight.FlightData{};

    // === Main loop ===
    while (!mfd.quit_requested and client.isConnected()) {
        // 1. Non-blocking keyboard input
        const key = tui.readKey();
        if (key != 0) {
            _ = mfd.handleInput(key, &fd);
        }

        // 2. Poll WebSocket for flight data (blocking — paces at ~10Hz)
        if (client.poll()) |maybe_batch| {
            if (maybe_batch) |batch| {
                fd.applyBatch(&batch, &registry);

                // Record frame if in record mode
                if (recorder) |*rec| {
                    rec.recordFrame(&fd);
                }
            }
        } else |_| {
            // Connection lost
            client.reconnect() catch continue;
            registry.subscribeAll(&client) catch {};
        }

        // 3. Render current MFD page
        mfd.render(&fd, &registry);
    }
}
