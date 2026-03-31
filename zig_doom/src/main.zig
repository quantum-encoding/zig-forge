//! zig_doom/src/main.zig
//!
//! DOOM entry point and CLI.
//! Translated from: linuxdoom-1.10/d_main.c, i_main.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const c = @cImport({});
const wad = @import("wad.zig");
const defs = @import("defs.zig");
const zone = @import("zone.zig");
const setup = @import("play/setup.zig");
const video = @import("video.zig");
const render_main = @import("render/main.zig");
const render_data = @import("render/data.zig");
const game_mod = @import("game.zig");
const platform_mod = @import("platform/interface.zig");
const event_mod = @import("event.zig");
const net_mod = @import("net.zig");
const demo_mod = @import("play/demo.zig");
const user = @import("play/user.zig");

// Pull in test declarations from all modules
comptime {
    _ = @import("fixed.zig");
    _ = @import("tables.zig");
    _ = @import("random.zig");
    _ = @import("bbox.zig");
    _ = @import("zone.zig");
    _ = @import("wad.zig");
    _ = @import("video.zig");
    _ = @import("play/setup.zig");
    _ = @import("render/state.zig");
    _ = @import("render/data.zig");
    _ = @import("render/draw.zig");
    _ = @import("render/planes.zig");
    _ = @import("render/bsp.zig");
    _ = @import("render/segs.zig");
    _ = @import("render/things.zig");
    _ = @import("render/sky.zig");
    _ = @import("render/main.zig");
    // Phase 3: Playsim
    _ = @import("info.zig");
    _ = @import("play/level.zig");
    _ = @import("play/tick.zig");
    _ = @import("play/mobj.zig");
    _ = @import("play/maputl.zig");
    _ = @import("play/map.zig");
    _ = @import("play/enemy.zig");
    _ = @import("play/user.zig");
    _ = @import("play/inter.zig");
    _ = @import("play/sight.zig");
    _ = @import("play/pspr.zig");
    // Phase 4: Specials
    _ = @import("play/spec.zig");
    _ = @import("play/doors.zig");
    _ = @import("play/floor.zig");
    _ = @import("play/ceiling.zig");
    _ = @import("play/lights.zig");
    _ = @import("play/switch.zig");
    _ = @import("play/telept.zig");
    // Phase 5: Game Loop + UI
    _ = @import("event.zig");
    _ = @import("game.zig");
    _ = @import("sound/defs.zig");
    _ = @import("sound/sound.zig");
    _ = @import("ui/status_bar.zig");
    _ = @import("ui/hud.zig");
    _ = @import("ui/intermission.zig");
    _ = @import("ui/automap.zig");
    _ = @import("ui/finale.zig");
    _ = @import("ui/wipe.zig");
    _ = @import("ui/menu.zig");
    // Phase 6: Platform Backends
    _ = @import("platform/interface.zig");
    _ = @import("platform/tui.zig");
    _ = @import("platform/null_sound.zig");
    _ = @import("platform/alsa_sound.zig");
    // Phase 7: Save/Load + Net + Polish
    _ = @import("net.zig");
    _ = @import("play/demo.zig");
    _ = @import("play/saveg.zig");
}

const usage =
    \\zig_doom — Pure Zig DOOM Engine
    \\
    \\Usage: zig_doom [options]
    \\
    \\Options:
    \\  --iwad <path>             Path to IWAD file (doom1.wad, doom.wad, doom2.wad)
    \\  --file <path>             Load PWAD file (can specify multiple)
    \\  --platform <name>         Platform backend: tui, sdl2, fb (default: tui)
    \\
    \\Game options:
    \\  --skill <1-5>             Skill level (1=ITYTD, 2=HNTR, 3=HMP, 4=UV, 5=NM)
    \\  --episode <1-4>           Episode number
    \\  --warp <map>              Warp to map (E1M1 format or MAP01 format)
    \\  --fast                    Fast monsters
    \\  --respawn                 Respawn monsters
    \\  --nomonsters              No monsters
    \\
    \\Demo options:
    \\  --playdemo <name>         Play demo lump
    \\  --timedemo <name>         Play demo as fast as possible (benchmark)
    \\  --record <name>           Record demo to file
    \\
    \\Multiplayer (stub):
    \\  --deathmatch              Deathmatch mode
    \\  --altdeath                Alt deathmatch rules
    \\
    \\Debug:
    \\  --dump-lumps              List all lumps in the WAD
    \\  --dump-map <name>         Dump map geometry (e.g., E1M1)
    \\  --render-frame <map>      Render one frame and save as PPM
    \\  --play                    Run game loop (title screen, outputs frame.ppm)
    \\  --run                     Run interactive game with platform backend
    \\  --output <path>           Output path for --render-frame/--play (default: frame.ppm)
    \\  --devparm                 Developer mode (show tics/frame)
    \\  --help                    Show this help
    \\
;

const Command = enum {
    none,
    dump_lumps,
    dump_map,
    render_frame,
    play,
    run,
    playdemo,
    timedemo,
    help,
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    // Parse command line args
    var iwad_path: ?[]const u8 = null;
    var command = Command.none;
    var map_name: ?[]const u8 = null;
    var output_path: []const u8 = "frame.ppm";
    var platform_name: []const u8 = "tui";
    var opt_skill: ?defs.Skill = null;
    var opt_episode: ?u8 = null;
    var opt_warp: ?[]const u8 = null;
    var demo_name: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            command = .help;
        } else if (std.mem.eql(u8, arg, "--iwad")) {
            iwad_path = args.next();
        } else if (std.mem.eql(u8, arg, "--file")) {
            // PWAD loading stub — skip the argument
            _ = args.next();
        } else if (std.mem.eql(u8, arg, "--dump-lumps")) {
            command = .dump_lumps;
        } else if (std.mem.eql(u8, arg, "--dump-map")) {
            command = .dump_map;
            map_name = args.next();
        } else if (std.mem.eql(u8, arg, "--render-frame")) {
            command = .render_frame;
            map_name = args.next();
        } else if (std.mem.eql(u8, arg, "--play")) {
            command = .play;
        } else if (std.mem.eql(u8, arg, "--run")) {
            command = .run;
        } else if (std.mem.eql(u8, arg, "--platform")) {
            if (args.next()) |p| platform_name = p;
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (args.next()) |p| output_path = p;
        } else if (std.mem.eql(u8, arg, "--skill")) {
            if (args.next()) |s| {
                if (s.len > 0 and s[0] >= '1' and s[0] <= '5') {
                    opt_skill = @enumFromInt(s[0] - '1');
                }
            }
        } else if (std.mem.eql(u8, arg, "--episode")) {
            if (args.next()) |s| {
                if (s.len > 0 and s[0] >= '1' and s[0] <= '4') {
                    opt_episode = s[0] - '0';
                }
            }
        } else if (std.mem.eql(u8, arg, "--warp")) {
            opt_warp = args.next();
        } else if (std.mem.eql(u8, arg, "--fast") or
            std.mem.eql(u8, arg, "--respawn") or
            std.mem.eql(u8, arg, "--nomonsters") or
            std.mem.eql(u8, arg, "--deathmatch") or
            std.mem.eql(u8, arg, "--altdeath") or
            std.mem.eql(u8, arg, "--devparm"))
        {
            // Flags parsed but not yet wired (Phase 7 stubs)
        } else if (std.mem.eql(u8, arg, "--playdemo")) {
            command = .playdemo;
            demo_name = args.next();
        } else if (std.mem.eql(u8, arg, "--timedemo")) {
            command = .timedemo;
            demo_name = args.next();
        } else if (std.mem.eql(u8, arg, "--record")) {
            // Record demo — stub, consume the argument
            _ = args.next();
        }
    }

    if (command == .help or (command == .none and iwad_path == null)) {
        try writeStr(usage);
        return;
    }

    const wad_path = iwad_path orelse {
        try writeStr("Error: --iwad <path> is required\n");
        return;
    };

    // Open WAD
    try writeStr("Opening WAD: ");
    try writeStr(wad_path);
    try writeStr("\n");

    var w = wad.Wad.open(wad_path, alloc) catch |err| {
        try writeStr("Error opening WAD: ");
        try writeStr(@errorName(err));
        try writeStr("\n");
        return;
    };
    defer w.close();

    // Print WAD info
    var buf: [256]u8 = undefined;
    const type_str: []const u8 = if (w.is_iwad) "IWAD" else "PWAD";
    var len = formatStr(&buf, type_str);
    try writeStr(buf[0..len]);
    try writeStr(" with ");

    len = formatInt(&buf, w.numLumps());
    try writeStr(buf[0..len]);
    try writeStr(" lumps\n");

    // Detect game mode
    const mode = w.detectGameMode();
    try writeStr("Game mode: ");
    try writeStr(switch (mode) {
        .shareware => "DOOM Shareware (Episode 1)",
        .registered => "DOOM Registered (Episodes 1-3)",
        .commercial => "DOOM II / Final DOOM",
        .retail => "Ultimate DOOM (Episodes 1-4)",
        .indetermined => "Unknown",
    });
    try writeStr("\n");

    switch (command) {
        .dump_lumps => try dumpLumps(&w, &buf),
        .dump_map => try dumpMap(&w, map_name orelse "E1M1", alloc, &buf),
        .render_frame => try renderFrameCmd(&w, map_name orelse "E1M1", output_path, alloc),
        .play => try playCmd(&w, output_path, alloc),
        .run => try runCmd(&w, platform_name, alloc, opt_skill, opt_episode, opt_warp),
        .playdemo => try playDemoCmd(&w, demo_name orelse "DEMO1", output_path, alloc),
        .timedemo => try playDemoCmd(&w, demo_name orelse "DEMO1", output_path, alloc),
        .none => try writeStr("DOOM initialized. Use --dump-lumps, --dump-map, --render-frame, --play, or --run.\n"),
        .help => {},
    }
}

fn runCmd(w: *wad.Wad, platform_name: []const u8, alloc: std.mem.Allocator, opt_skill: ?defs.Skill, opt_episode: ?u8, opt_warp: ?[]const u8) !void {
    try writeStr("Starting interactive game with platform: ");
    try writeStr(platform_name);
    try writeStr("\n");

    // Create platform backend
    const platform = platform_mod.createPlatform(platform_name, alloc) orelse {
        try writeStr("Error: Failed to create platform '");
        try writeStr(platform_name);
        try writeStr("'. Available: tui, sdl2, framebuffer\n");
        return;
    };

    // Initialize video
    if (!platform.initVideo(platform.impl, 640, 400)) {
        try writeStr("Error: Failed to initialize video\n");
        return;
    }

    // Initialize sound (non-fatal if it fails)
    _ = platform.initSound(platform.impl);

    // Initialize game
    var game = game_mod.Game.init(w, alloc);

    // Start the game on a map
    {
        const skill = opt_skill orelse .medium;
        var episode: u8 = opt_episode orelse 1;
        var map_num: u8 = 1;

        if (opt_warp) |warp_str| {
            // Parse warp string: "E1M1" or "MAP01" or just a number
            if (warp_str.len >= 4 and (warp_str[0] == 'E' or warp_str[0] == 'e')) {
                // Episodic format E?M?
                if (warp_str[1] >= '1' and warp_str[1] <= '4') episode = warp_str[1] - '0';
                if (warp_str.len >= 4 and warp_str[3] >= '1' and warp_str[3] <= '9') map_num = warp_str[3] - '0';
            } else if (warp_str.len >= 5 and (warp_str[0] == 'M' or warp_str[0] == 'm')) {
                // MAP format
                episode = 0;
                if (warp_str[3] >= '0' and warp_str[3] <= '9' and warp_str[4] >= '0' and warp_str[4] <= '9') {
                    map_num = (warp_str[3] - '0') * 10 + (warp_str[4] - '0');
                }
            } else if (warp_str.len > 0 and warp_str[0] >= '1' and warp_str[0] <= '9') {
                // Just a number
                map_num = warp_str[0] - '0';
            }
        }
        // Always start on a level (default E1M1)
        game.doNewGame(skill, episode, map_num);
    }

    // Load palette
    var vid = video.VideoState.init();
    if (w.findLump("PLAYPAL")) |pal_lump| {
        vid.loadPalette(w.lumpData(pal_lump));
    }

    // Initialize net state for input
    var net = net_mod.NetState.init();

    // Main game loop
    var gametic: u32 = 0;
    var event_buf: [64]event_mod.Event = undefined;

    while (!platform.isQuitRequested(platform.impl)) {
        // 1. Pump input events
        const events = platform.getEvents(platform.impl, &event_buf);

        // Feed events to game responder and net state
        for (events) |*ev| {
            _ = game.responder(ev);
        }

        // 2. Build tic command from input
        if (game.state == .level and !game.paused and !game.demo_playback) {
            var cmd = user.TicCmd{};
            net.buildTicCmd(&cmd, events);
            game.players[game.consoleplayer].cmd = cmd;
        }

        // 3. Run game tics to catch up with wall clock
        const current_tic = platform.getTics(platform.impl);
        var tics_ran: u32 = 0;
        while (gametic < current_tic) : (gametic += 1) {
            game.ticker();
            tics_ran += 1;
            if (tics_ran >= 4) break; // Don't run more than 4 tics per frame
        }

        // 4. Only draw and blit when a tic actually ran (limits to ~35 fps)
        if (tics_ran > 0) {
            game.drawer(&vid);
            platform.finishUpdate(platform.impl, &vid.screens[0], &vid.palette);
            platform.updateSound(platform.impl);
        }

        // 5. Sleep until next tic (~28ms per tic at 35fps)
        // Sleep shorter to stay responsive to input
        platform.sleep(platform.impl, 8);
    }

    // Cleanup
    if (game.rdata) |*rd| {
        rd.deinit();
    }
    if (game.level) |*lvl| {
        lvl.deinit();
    }

    platform.deinitSound(platform.impl);
    platform.deinitVideo(platform.impl);
}

/// Play a demo lump from the WAD
fn playDemoCmd(w: *wad.Wad, demo_name: []const u8, output_path: []const u8, alloc: std.mem.Allocator) !void {
    try writeStr("Playing demo: ");
    try writeStr(demo_name);
    try writeStr("\n");

    // Find demo lump
    const lump = w.findLump(demo_name) orelse {
        try writeStr("Error: Demo lump not found in WAD\n");
        return;
    };
    const demo_data = w.lumpData(lump);

    // Parse demo header
    var demo_state = demo_mod.DemoState{};
    if (!demo_state.startPlayback(demo_data)) {
        try writeStr("Error: Invalid demo format\n");
        return;
    }

    try writeStr("Demo skill=");
    var buf: [256]u8 = undefined;
    var len = formatInt(&buf, demo_state.skill);
    try writeStr(buf[0..len]);
    try writeStr(" episode=");
    len = formatInt(&buf, demo_state.episode);
    try writeStr(buf[0..len]);
    try writeStr(" map=");
    len = formatInt(&buf, demo_state.map);
    try writeStr(buf[0..len]);
    try writeStr("\n");

    // Initialize game and load the demo's level
    var game = game_mod.Game.init(w, alloc);
    game.demo_playback = true;

    const skill: defs.Skill = @enumFromInt(demo_state.skill);
    game.doNewGame(skill, demo_state.episode, demo_state.map);
    game.doLoadLevel();

    // Load palette
    var vid = video.VideoState.init();
    if (w.findLump("PLAYPAL")) |pal_lump| {
        vid.loadPalette(w.lumpData(pal_lump));
    }

    // Run demo tics
    var tic_count: u32 = 0;
    const max_tics: u32 = 35 * 60 * 10; // Max 10 minutes

    while (demo_state.playing and tic_count < max_tics) {
        var cmd = user.TicCmd{};
        if (!demo_state.readTicCmd(&cmd)) break;

        game.players[game.consoleplayer].cmd = cmd;
        game.ticker();
        tic_count += 1;
    }

    // Draw final frame
    game.drawer(&vid);

    // Write output
    try writeStr("Demo ran for ");
    len = formatInt(&buf, tic_count);
    try writeStr(buf[0..len]);
    try writeStr(" tics\n");

    try writeStr("Writing frame to: ");
    try writeStr(output_path);
    try writeStr("\n");

    if (vid.writePPM(0, output_path, alloc)) {
        try writeStr("Done!\n");
    } else {
        try writeStr("Error: Failed to write PPM\n");
    }

    if (game.level) |*lvl| {
        lvl.deinit();
    }
}

fn playCmd(w: *wad.Wad, output_path: []const u8, alloc: std.mem.Allocator) !void {
    try writeStr("Initializing game loop...\n");

    // Initialize game
    var game = game_mod.Game.init(w, alloc);

    // Load palette
    var vid = video.VideoState.init();
    if (w.findLump("PLAYPAL")) |pal_lump| {
        vid.loadPalette(w.lumpData(pal_lump));
    }

    try writeStr("Game state: title screen (demoscreen)\n");

    // Run a few tics of the title screen cycle
    const num_tics: u32 = 70; // 2 seconds at 35fps
    for (0..num_tics) |i| {
        game.ticker();

        // Draw every 35 tics (once per second) for progress
        if (i % 35 == 0) {
            game.drawer(&vid);
        }
    }

    // Draw final frame
    game.drawer(&vid);

    // Write output
    try writeStr("Writing title screen to: ");
    try writeStr(output_path);
    try writeStr("\n");

    if (vid.writePPM(0, output_path, alloc)) {
        try writeStr("Done! Title screen written to ");
        try writeStr(output_path);
        try writeStr("\n");
    } else {
        try writeStr("Error: Failed to write PPM file\n");
    }

    // Clean up level if one was loaded
    if (game.level) |*lvl| {
        lvl.deinit();
    }

    try writeStr("Game loop test complete.\n");
}

fn renderFrameCmd(w: *const wad.Wad, map_name_arg: []const u8, output_path: []const u8, alloc: std.mem.Allocator) !void {
    try writeStr("Loading map: ");
    try writeStr(map_name_arg);
    try writeStr("\n");

    // Load map
    var level = setup.loadMap(w, map_name_arg, alloc) catch |err| {
        try writeStr("Error loading map: ");
        try writeStr(@errorName(err));
        try writeStr("\n");
        return;
    };
    defer level.deinit();

    var buf: [256]u8 = undefined;

    // Print map stats
    try writeStr("  Vertices: ");
    var map_len = formatInt(&buf, level.vertices.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n  Linedefs: ");
    map_len = formatInt(&buf, level.lines.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n  Sidedefs: ");
    map_len = formatInt(&buf, level.sides.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n  Sectors:  ");
    map_len = formatInt(&buf, level.sectors.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n  Segs:     ");
    map_len = formatInt(&buf, level.segs.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n  Nodes:    ");
    map_len = formatInt(&buf, level.nodes.len);
    try writeStr(buf[0..map_len]);
    try writeStr("\n");

    // Find player 1 start
    const p1 = level.findPlayer1Start() orelse {
        try writeStr("Error: No player 1 start found\n");
        return;
    };
    try writeStr("Player 1 start: x=");
    map_len = formatSignedInt(&buf, p1.x);
    try writeStr(buf[0..map_len]);
    try writeStr(" y=");
    map_len = formatSignedInt(&buf, p1.y);
    try writeStr(buf[0..map_len]);
    try writeStr(" angle=");
    map_len = formatSignedInt(&buf, p1.angle);
    try writeStr(buf[0..map_len]);
    try writeStr("\n");

    // Initialize render data (textures, flats, colormaps)
    try writeStr("Loading textures and colormaps...\n");
    var rdata = render_data.RenderData.init(w, alloc) catch |err| {
        try writeStr("Error loading render data: ");
        try writeStr(@errorName(err));
        try writeStr("\n");
        return;
    };
    defer rdata.deinit();

    // Initialize video state
    var vid = video.VideoState.init();

    // Render the frame
    try writeStr("Rendering frame...\n");
    const ok = render_main.renderFrame(w, &level, &rdata, &vid, alloc);
    if (!ok) {
        try writeStr("Error: Rendering failed\n");
        return;
    }

    // Write PPM output
    try writeStr("Writing output: ");
    try writeStr(output_path);
    try writeStr("\n");

    if (vid.writePPM(0, output_path, alloc)) {
        try writeStr("Done! Frame written to ");
        try writeStr(output_path);
        try writeStr("\n");
    } else {
        try writeStr("Error: Failed to write PPM file\n");
    }
}

fn dumpLumps(w: *const wad.Wad, buf: *[256]u8) !void {
    try writeStr("\n--- Lump Directory ---\n");
    try writeStr("  #    Size  Name\n");

    for (0..w.numLumps()) |i| {
        // Index
        var len = formatIntPad(buf, i, 5);
        try writeStr(buf[0..len]);
        try writeStr(" ");

        // Size
        len = formatIntPad(buf, w.lumps[i].size, 7);
        try writeStr(buf[0..len]);
        try writeStr("  ");

        // Name
        try writeStr(w.lumpName(i));
        try writeStr("\n");
    }
}

fn dumpMap(w: *const wad.Wad, name: []const u8, _: std.mem.Allocator, buf: *[256]u8) !void {
    try writeStr("\n--- Map: ");
    try writeStr(name);
    try writeStr(" ---\n");

    // Find the map marker lump
    const map_lump = w.findLump(name) orelse {
        try writeStr("Map not found in WAD\n");
        return;
    };

    // Map data lumps follow the marker in order:
    // THINGS, LINEDEFS, SIDEDEFS, VERTEXES, SEGS, SSECTORS, NODES, SECTORS, REJECT, BLOCKMAP
    const lump_names = [_][]const u8{
        "THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS", "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP",
    };
    const struct_sizes = [_]usize{
        @sizeOf(defs.MapThing), @sizeOf(defs.MapLinedef), @sizeOf(defs.MapSidedef), @sizeOf(defs.MapVertex),
        @sizeOf(defs.MapSeg),   @sizeOf(defs.MapSubsector), @sizeOf(defs.MapNode), @sizeOf(defs.MapSector),
        1,                      1, // REJECT and BLOCKMAP are variable
    };

    for (lump_names, struct_sizes) |lname, ssize| {
        const lump_idx = w.findLumpAfter(lname, map_lump + 1) orelse {
            try writeStr("  ");
            try writeStr(lname);
            try writeStr(": NOT FOUND\n");
            continue;
        };

        // Only count entries for known structures
        const size = w.lumps[lump_idx].size;
        try writeStr("  ");
        try writeStr(lname);
        try writeStr(": ");

        var len = formatInt(buf, size);
        try writeStr(buf[0..len]);
        try writeStr(" bytes");

        if (ssize > 1) {
            const count = size / ssize;
            try writeStr(" (");
            len = formatInt(buf, count);
            try writeStr(buf[0..len]);
            try writeStr(" entries)");
        }
        try writeStr("\n");
    }

    // Dump first few vertices
    const vtx_lump = w.findLumpAfter("VERTEXES", map_lump + 1) orelse return;
    const vertices = w.lumpAs(vtx_lump, defs.MapVertex);

    try writeStr("\n  First 10 vertices:\n");
    const show = @min(vertices.len, 10);
    for (0..show) |i| {
        const v = vertices[i];
        try writeStr("    [");
        var len = formatInt(buf, i);
        try writeStr(buf[0..len]);
        try writeStr("] x=");
        len = formatSignedInt(buf, v.x);
        try writeStr(buf[0..len]);
        try writeStr(" y=");
        len = formatSignedInt(buf, v.y);
        try writeStr(buf[0..len]);
        try writeStr("\n");
    }

    // Dump first few things
    const thing_lump = w.findLumpAfter("THINGS", map_lump + 1) orelse return;
    const map_things = w.lumpAs(thing_lump, defs.MapThing);

    try writeStr("\n  First 10 things:\n");
    const show_things = @min(map_things.len, 10);
    for (0..show_things) |i| {
        const t = map_things[i];
        try writeStr("    [");
        var len = formatInt(buf, i);
        try writeStr(buf[0..len]);
        try writeStr("] type=");
        len = formatSignedInt(buf, t.thing_type);
        try writeStr(buf[0..len]);
        try writeStr(" x=");
        len = formatSignedInt(buf, t.x);
        try writeStr(buf[0..len]);
        try writeStr(" y=");
        len = formatSignedInt(buf, t.y);
        try writeStr(buf[0..len]);
        try writeStr(" angle=");
        len = formatSignedInt(buf, t.angle);
        try writeStr(buf[0..len]);
        try writeStr("\n");
    }
}

// ============================================================================
// Simple output helpers (avoid std.fmt which may not work in all targets)
// ============================================================================

fn writeStr(s: []const u8) !void {
    var remaining = s;
    while (remaining.len > 0) {
        const written = std.c.write(1, remaining.ptr, remaining.len);
        if (written < 0) return;
        remaining = remaining[@intCast(written)..];
    }
}

fn formatStr(buf: *[256]u8, s: []const u8) usize {
    const len = @min(s.len, 256);
    @memcpy(buf[0..len], s[0..len]);
    return len;
}

fn formatInt(buf: *[256]u8, value: usize) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = value;
    var len: usize = 0;
    while (v > 0) : (v /= 10) {
        len += 1;
    }
    v = value;
    var i = len;
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return len;
}

fn formatIntPad(buf: *[256]u8, value: usize, width: usize) usize {
    const len = formatInt(buf, value);
    if (len >= width) return len;
    // Shift right and pad with spaces
    const shift = width - len;
    var i: usize = width;
    while (i > shift) {
        i -= 1;
        buf[i] = buf[i - shift];
    }
    for (0..shift) |j| {
        buf[j] = ' ';
    }
    return width;
}

fn formatSignedInt(buf: *[256]u8, value: i16) usize {
    if (value < 0) {
        buf[0] = '-';
        const abs_val: usize = @intCast(-@as(i32, value));
        var tmp: [256]u8 = undefined;
        const len = formatInt(&tmp, abs_val);
        @memcpy(buf[1 .. 1 + len], tmp[0..len]);
        return len + 1;
    }
    return formatInt(buf, @intCast(value));
}
