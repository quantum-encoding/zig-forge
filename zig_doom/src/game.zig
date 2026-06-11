//! zig_doom/src/game.zig
//!
//! Central game loop — ties everything together.
//! Translated from: linuxdoom-1.10/g_game.c, d_main.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Game state machine:
//!   GS_LEVEL       — playing a level
//!   GS_INTERMISSION — showing level stats
//!   GS_FINALE      — text screens / cast sequence
//!   GS_DEMOSCREEN  — title screen cycle

const std = @import("std");
const defs = @import("defs.zig");
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const video = @import("video.zig");
const Wad = @import("wad.zig").Wad;
const random = @import("random.zig");
const setup = @import("play/setup.zig");
const Level = setup.Level;
const tick = @import("play/tick.zig");
const user = @import("play/user.zig");
const Player = user.Player;
const TicCmd = user.TicCmd;
const mobj_mod = @import("play/mobj.zig");
const info = @import("info.zig");
const pspr = @import("play/pspr.zig");
const world = @import("play/world.zig");
const spec = @import("play/spec.zig");
const switch_mod = @import("play/switch.zig");
const render_main = @import("render/main.zig");
const render_data = @import("render/data.zig");
const RenderData = render_data.RenderData;
const event_mod = @import("event.zig");
const Event = event_mod.Event;

// UI
const StatusBar = @import("ui/status_bar.zig").StatusBar;
const HUD = @import("ui/hud.zig").HUD;
const Intermission = @import("ui/intermission.zig").Intermission;
const LevelStats = @import("ui/intermission.zig").LevelStats;
const Automap = @import("ui/automap.zig").Automap;
const Finale = @import("ui/finale.zig").Finale;
const Wipe = @import("ui/wipe.zig").Wipe;
const Menu = @import("ui/menu.zig").Menu;
const MenuAction = @import("ui/menu.zig").MenuAction;

// Sound
const SoundEngine = @import("sound/sound.zig").SoundEngine;

// Phase 7: Save/Load, Demo, Net
const saveg = @import("play/saveg.zig");
const demo_mod = @import("play/demo.zig");
const DemoState = demo_mod.DemoState;

const MAXPLAYERS = defs.MAXPLAYERS;
const SCREENWIDTH = defs.SCREENWIDTH;
const SCREENHEIGHT = defs.SCREENHEIGHT;
const TICRATE = 35;

pub const Game = struct {
    // Game state machine
    state: defs.GameState = .demoscreen,
    action: defs.GameAction = .nothing,
    game_mode: defs.GameMode = .indetermined,
    game_mission: defs.GameMission = .none,

    // Current game parameters
    skill: defs.Skill = .medium,
    episode: u8 = 0,
    map: u8 = 0,

    // Players
    players: [MAXPLAYERS]Player = [_]Player{.{}} ** MAXPLAYERS,
    player_in_game: [MAXPLAYERS]bool = blk: {
        var arr = [_]bool{false} ** MAXPLAYERS;
        arr[0] = true; // Player 1 is always in game
        break :blk arr;
    },
    consoleplayer: u8 = 0,
    displayplayer: u8 = 0,

    // Level
    level: ?Level = null,
    rdata: ?RenderData = null,
    level_time: i32 = 0,
    total_kills: i32 = 0,
    total_items: i32 = 0,
    total_secrets: i32 = 0,

    // Demo state
    demo_playback: bool = false,
    demo_recording: bool = false,
    demo_state: DemoState = .{},

    // Save/load
    save_slot: u8 = 0,
    quicksave_slot: i8 = -1, // -1 = not set
    save_description: [24]u8 = [_]u8{0} ** 24,

    // Misc
    paused: bool = false,
    game_tic: u32 = 0,

    // Demo screen cycle — DOOM title screen pattern:
    // TITLEPIC ~170 tics -> DEMO1 -> CREDIT ~200 tics -> DEMO2 -> CREDIT ~200 tics -> DEMO3 -> loop
    demo_page_tic: i32 = 0,
    demo_page: u8 = 0,
    demo_sequence: u8 = 0, // 0=TITLEPIC, 1=DEMO1, 2=CREDIT, 3=DEMO2, 4=CREDIT, 5=DEMO3

    // UI components
    status_bar: StatusBar = .{},
    hud: HUD = .{},
    intermission: Intermission = .{},
    automap: Automap = .{},
    finale: Finale = .{},
    wipe: Wipe = .{},
    menu: Menu = .{},
    sound: SoundEngine = .{},

    // WAD and allocator
    wad: *Wad = undefined,
    allocator: std.mem.Allocator = undefined,

    /// Initialize the game state
    pub fn init(w: *Wad, alloc: std.mem.Allocator) Game {
        var game = Game{};
        game.wad = w;
        game.allocator = alloc;
        game.game_mode = w.detectGameMode();

        // Determine mission
        game.game_mission = switch (game.game_mode) {
            .commercial => .doom2,
            .shareware, .registered, .retail => .doom,
            .indetermined => .none,
        };

        // Initialize UI components
        game.status_bar = StatusBar.init(w);
        game.hud = HUD.init(w);
        game.menu = Menu.init(w);

        // Initialize player 1
        game.players[0].player_num = 0;

        // Start on title screen
        game.state = .demoscreen;
        game.demo_page = 0;
        game.demo_page_tic = TICRATE * 11; // ~11 seconds per page

        return game;
    }

    /// Main per-tic entry point — called once per game tic (35 fps)
    pub fn ticker(self: *Game) void {
        // Menu always ticks
        self.menu.ticker();

        // Check for actions
        if (self.action != .nothing) {
            self.executeAction();
        }

        // Game state tic
        switch (self.state) {
            .level => {
                if (!self.paused) {
                    self.doTick();
                    self.level_time += 1;
                }
                self.status_bar.ticker(&self.players[self.consoleplayer]);
                self.hud.ticker();
                self.automap.ticker(&self.players[self.consoleplayer]);
            },
            .intermission => {
                if (self.intermission.ticker()) {
                    self.action = .world_done;
                }
            },
            .finale => {
                if (self.finale.ticker()) {
                    self.action = .world_done;
                }
            },
            .demoscreen => {
                self.demo_page_tic -= 1;
                if (self.demo_page_tic <= 0) {
                    self.advanceDemoPage();
                }
            },
        }

        self.game_tic +%= 1;
    }

    /// Dispatch an input event to the appropriate handler
    pub fn responder(self: *Game, ev: *const Event) bool {
        // Menu gets first shot at events
        const menu_action = self.menu.responder(ev);
        switch (menu_action) {
            .new_game => {
                self.doNewGame(
                    self.menu.selected_skill,
                    self.menu.selected_episode + 1,
                    1,
                );
                return true;
            },
            .quit => {
                // Quit action — in Phase 6 this would exit
                return true;
            },
            .none => {
                if (self.menu.active) return true;
            },
        }

        // Automap
        if (self.state == .level) {
            if (self.automap.responder(ev)) return true;
        }

        // Intermission: USE key advances
        if (self.state == .intermission) {
            if (ev.event_type == .key_down and ev.data1 == event_mod.KEY_USE) {
                self.intermission.accelerateStage();
                return true;
            }
        }

        // Finale: any key accelerates
        if (self.state == .finale) {
            if (ev.event_type == .key_down) {
                self.finale.accelerate();
                return true;
            }
        }

        // Function key shortcuts
        if (ev.event_type == .key_down) {
            switch (ev.data1) {
                event_mod.KEY_F2 => {
                    // F2 = Save game (use slot 0 as default)
                    if (self.state == .level) {
                        self.save_slot = 0;
                        self.action = .save_game;
                    }
                    return true;
                },
                event_mod.KEY_F3 => {
                    // F3 = Load game (use slot 0 as default)
                    self.save_slot = 0;
                    self.action = .load_game;
                    return true;
                },
                event_mod.KEY_F6 => {
                    // F6 = Quicksave
                    if (self.state == .level) {
                        if (self.quicksave_slot < 0) {
                            self.quicksave_slot = 0;
                        }
                        self.save_slot = @intCast(self.quicksave_slot);
                        self.action = .save_game;
                    }
                    return true;
                },
                event_mod.KEY_F9 => {
                    // F9 = Quickload
                    if (self.quicksave_slot >= 0) {
                        self.save_slot = @intCast(self.quicksave_slot);
                        self.action = .load_game;
                    }
                    return true;
                },
                event_mod.KEY_PAUSE => {
                    // Pause toggle
                    if (self.state == .level) {
                        self.paused = !self.paused;
                    }
                    return true;
                },
                else => {},
            }
        }

        // Demo screen: any key opens menu
        if (self.state == .demoscreen) {
            if (ev.event_type == .key_down) {
                // Stop demo playback if playing
                if (self.demo_playback) {
                    self.demo_state.stopPlayback();
                    self.demo_playback = false;
                }
                self.menu.active = true;
                self.menu.current_menu = .main_menu;
                self.menu.item_on = 0;
                return true;
            }
        }

        return false;
    }

    /// Draw current game state to video
    pub fn drawer(self: *Game, vid: *video.VideoState) void {
        switch (self.state) {
            .level => {
                if (self.automap.active) {
                    if (self.level) |*lvl| {
                        self.automap.drawer(lvl, &self.players[self.displayplayer], vid);
                    }
                } else {
                    // Render 3D view from the player's CURRENT viewpoint so
                    // movement and turning are reflected on screen.
                    if (self.level) |*lvl| {
                        if (self.rdata) |*rdata| {
                            const player = &self.players[self.displayplayer];
                            if (player.mobj) |mo| {
                                _ = render_main.renderView(self.wad, lvl, rdata, vid, mo.x, mo.y, player.viewz, mo.angle, player);
                            } else {
                                _ = render_main.renderFrame(self.wad, lvl, rdata, vid, self.allocator);
                            }
                        } else {
                            vid.clearScreen(0, 0);
                        }
                    }
                }

                // Status bar always drawn on top
                self.status_bar.drawer(&self.players[self.displayplayer], vid, self.wad);

                // HUD messages on top
                self.hud.drawer(vid, self.wad);
            },
            .intermission => {
                self.intermission.drawer(vid, self.wad);
            },
            .finale => {
                self.finale.drawer(vid, self.wad);
            },
            .demoscreen => {
                self.drawDemoPage(vid);
            },
        }

        // Menu drawn on top of everything
        self.menu.drawer(vid, self.wad);

        // Wipe effect
        if (self.wipe.active) {
            _ = self.wipe.doWipe(vid);
        }
    }

    // ========================================================================
    // Actions
    // ========================================================================

    /// Start a new game
    pub fn doNewGame(self: *Game, skill: defs.Skill, episode: u8, map: u8) void {
        self.skill = skill;
        self.episode = episode;
        self.map = map;
        self.action = .load_level;

        // Reset player state for new game
        self.players[self.consoleplayer] = Player{};
        self.players[self.consoleplayer].player_num = @intCast(self.consoleplayer);
    }

    /// Load a level
    pub fn doLoadLevel(self: *Game) void {
        // Unload previous level
        if (self.rdata) |*rd| {
            rd.deinit();
            self.rdata = null;
        }
        if (self.level) |*lvl| {
            lvl.deinit();
            self.level = null;
        }

        // Build map name
        var map_name_buf: [8]u8 = undefined;
        const map_name = buildMapName(self.episode, self.map, &map_name_buf);

        // Clear random for demo sync
        random.clearRandom();

        // Initialize thinkers
        tick.initThinkers();

        // Load map from WAD
        self.level = setup.loadMap(self.wad, map_name, self.allocator) catch {
            // Failed to load — return to title screen
            self.state = .demoscreen;
            return;
        };

        // Initialize render data for this level
        if (self.rdata) |*rd| {
            rd.deinit();
            self.rdata = null;
        }
        self.rdata = RenderData.init(self.wad, self.allocator) catch null;

        // Reset level state
        self.level_time = 0;
        self.total_kills = 0;
        self.total_items = 0;
        self.total_secrets = 0;

        // Publish the playsim world context (used by AI, collision, attacks)
        world.reset();
        world.level = if (self.level) |*l| l else null;
        world.players = @ptrCast(&self.players);
        world.player_in_game = &self.player_in_game;
        world.sound = &self.sound;
        world.allocator = self.allocator;
        world.episode = self.episode;
        world.map = self.map;
        world.sky_flatnum = if (self.rdata) |*rd| rd.flatNumForName("F_SKY1\x00\x00".*) else -1;

        // Spawn sector specials (door/floor/light thinkers, animations)
        if (self.level) |*lvl| {
            spec.spawnSpecials(lvl, self.allocator);
        }

        // Spawn player and all map things
        if (self.level) |lvl| {
            // Skill bit for thing filtering (baby/easy share MTF_EASY,
            // hard/nightmare share MTF_HARD — vanilla behavior)
            const skill_bit: i16 = switch (self.skill) {
                .baby, .easy => defs.MTF_EASY,
                .medium => defs.MTF_NORMAL,
                .hard, .nightmare => defs.MTF_HARD,
            };

            for (lvl.things) |thing| {
                // Player 1 start (type 1)
                if (thing.thing_type == 1) {
                    self.spawnPlayer(0, thing);
                    continue;
                }
                // Player 2-4 starts and deathmatch starts: not used in single player
                if (thing.thing_type >= 2 and thing.thing_type <= 4) continue;
                if (thing.thing_type == 11) continue;
                // Multiplayer-only things (bit 16)
                if (thing.options & 16 != 0) continue;
                // Skill filter
                if (thing.options & skill_bit == 0) continue;

                const mo = mobj_mod.spawnMapThing(&thing, self.allocator) catch null orelse continue;

                // spawnMobj computed z from floorz/ceilingz before they were
                // known (both 0 at spawn) — fix them up from the real sector.
                self.updateMobjSectorZ(mo);
                if (mo.flags & info.MF_SPAWNCEILING != 0) {
                    mo.z = Fixed.sub(mo.ceilingz, mo.height);
                } else {
                    mo.z = mo.floorz;
                }

                if (mo.flags & info.MF_COUNTKILL != 0) self.total_kills += 1;
                if (mo.flags & info.MF_COUNTITEM != 0) self.total_items += 1;
            }
        }

        self.state = .level;
    }

    /// Handle level completion
    pub fn doCompleteLevel(self: *Game) void {
        // Calculate level stats for intermission
        const player = &self.players[self.consoleplayer];
        const stats = LevelStats{
            .kills = player.kill_count,
            .total_kills = self.total_kills,
            .items = player.item_count,
            .total_items = self.total_items,
            .secrets = player.secret_count,
            .total_secrets = self.total_secrets,
            .time_tics = self.level_time,
            .par_tics = getParTime(self.episode, self.map),
            .last_level = self.map -% 1,
            .next_level = self.map,
            .episode = self.episode -% 1,
        };

        self.intermission.start(stats, self.wad);
        self.state = .intermission;
    }

    /// Called when intermission is done — advance to next level or finale
    pub fn worldDone(self: *Game) void {
        if (self.state == .intermission) {
            // Check for episode ending
            if (isLastLevelInEpisode(self.episode, self.map)) {
                // Start finale
                self.finale.start(self.episode, self.wad);
                self.state = .finale;
            } else {
                // Advance to next map
                self.map += 1;
                self.action = .load_level;
            }
        } else if (self.state == .finale) {
            // Finale done — back to title
            self.state = .demoscreen;
            self.demo_page = 0;
            self.demo_page_tic = TICRATE * 11;
        }
    }

    // ========================================================================
    // Internal
    // ========================================================================

    /// Execute pending game action
    fn executeAction(self: *Game) void {
        const action = self.action;
        self.action = .nothing;

        switch (action) {
            .load_level, .new_game => self.doLoadLevel(),
            .completed => self.doCompleteLevel(),
            .world_done => self.worldDone(),
            .victory => {
                self.finale.start(self.episode, self.wad);
                self.state = .finale;
            },
            .save_game => self.doSaveGame(),
            .load_game => self.doLoadGame(),
            else => {},
        }
    }

    /// Run one game tic (thinkers, player movement, etc.)
    fn doTick(self: *Game) void {
        // Respawn requested (death + use): single player restarts the level
        if (self.players[self.consoleplayer].player_state == .reborn) {
            const pn = self.players[self.consoleplayer].player_num;
            self.players[self.consoleplayer] = Player{};
            self.players[self.consoleplayer].player_num = pn;
            self.action = .load_level;
            return;
        }

        // Process player input (dead players still think — death camera/respawn)
        for (0..MAXPLAYERS) |i| {
            if (self.player_in_game[i]) {
                // Keep the player's floor/ceiling heights synced to the sector
                // they're standing in BEFORE thinking — calcHeight clamps the
                // eye view to [floorz+1, ceilingz-4], and a stale ceilingz of 0
                // would drag the view below the floor (black floors).
                if (self.players[i].mobj) |mo| self.updateMobjSectorZ(mo);
                user.playerThink(&self.players[i]);
                pspr.movePSprites(&self.players[i]);
            }
        }

        // Run all thinkers (monsters, projectiles, etc.)
        tick.runThinkers();

        // Sector specials: moving floors/ceilings/lights, texture animations,
        // switch button timeouts, damage floors.
        world.leveltime = self.level_time;
        if (self.level) |*lvl| {
            spec.updateSpecials(lvl);
            switch_mod.checkButtons(lvl);

            for (0..MAXPLAYERS) |i| {
                if (!self.player_in_game[i]) continue;
                const player = &self.players[i];
                const mo = player.mobj orelse continue;
                // Damage floors only hurt players standing on the ground
                if (mo.z.raw() == mo.floorz.raw()) {
                    if (self.sectorAt(mo.x, mo.y)) |sec| {
                        if (sec.special != 0) spec.playerInSpecialSector(player, sec);
                    }
                }
            }
        }

        // Exit triggers raised by line specials this tic
        if (world.exit_level or world.exit_secret) {
            world.exit_level = false;
            world.exit_secret = false;
            self.action = .completed;
        }

        // Update sound positions
        if (self.players[self.consoleplayer].mobj) |mo| {
            self.sound.setListener(mo.x, mo.y, mo.angle);
        }
        self.sound.update();
    }

    /// Spawn a player at a map thing position
    fn spawnPlayer(self: *Game, player_num: usize, thing: defs.MapThing) void {
        const x = Fixed.fromInt(@as(i32, thing.x));
        const y = Fixed.fromInt(@as(i32, thing.y));

        const mo = mobj_mod.spawnMobj(x, y, mobj_mod.ONFLOORZ, .MT_PLAYER, self.allocator) catch return;

        // spawnMobj leaves floorz/ceilingz at 0; set them from the actual sector
        // and seat the player on the real floor.
        self.updateMobjSectorZ(mo);
        mo.z = mo.floorz;

        mo.angle = @as(Angle, @intCast(thing.angle)) *% (0x100000000 / 360);
        mo.player = @ptrCast(&self.players[player_num]);

        self.players[player_num].mobj = mo;
        self.players[player_num].player_state = .alive;

        // Bring up the ready weapon (psprite state machine)
        pspr.setupPSprites(&self.players[player_num]);
    }

    /// Sector containing a map point (BSP point-location), or null.
    fn sectorAt(self: *Game, x: Fixed, y: Fixed) ?*setup.Sector {
        const lvl = if (self.level) |*l| l else return null;
        if (lvl.num_nodes == 0) {
            if (lvl.subsectors.len > 0) {
                if (lvl.subsectors[0].sector) |si| {
                    if (si < lvl.sectors.len) return &lvl.sectors[si];
                }
            }
            return null;
        }
        var node_id: u16 = @intCast(lvl.num_nodes - 1);
        while (node_id & defs.NF_SUBSECTOR == 0) {
            if (node_id >= lvl.nodes.len) return null;
            const node = &lvl.nodes[node_id];
            node_id = node.children[pointOnSideNode(x, y, node)];
        }
        const ssi = node_id & ~@as(u16, defs.NF_SUBSECTOR);
        if (ssi < lvl.subsectors.len) {
            if (lvl.subsectors[ssi].sector) |si| {
                if (si < lvl.sectors.len) return &lvl.sectors[si];
            }
        }
        return null;
    }

    /// Set a mobj's floorz/ceilingz from the sector it currently occupies
    /// (BSP point-location). Without this, mobjs keep floorz=ceilingz=0.
    fn updateMobjSectorZ(self: *Game, mo: *mobj_mod.MapObject) void {
        const lvl = if (self.level) |*l| l else return;
        if (lvl.num_nodes == 0) {
            if (lvl.subsectors.len > 0) {
                if (lvl.subsectors[0].sector) |si| {
                    if (si < lvl.sectors.len) {
                        mo.floorz = lvl.sectors[si].floorheight;
                        mo.ceilingz = lvl.sectors[si].ceilingheight;
                    }
                }
            }
            return;
        }
        var node_id: u16 = @intCast(lvl.num_nodes - 1);
        while (node_id & defs.NF_SUBSECTOR == 0) {
            if (node_id >= lvl.nodes.len) return;
            const node = &lvl.nodes[node_id];
            node_id = node.children[pointOnSideNode(mo.x, mo.y, node)];
        }
        const ssi = node_id & ~@as(u16, defs.NF_SUBSECTOR);
        if (ssi < lvl.subsectors.len) {
            if (lvl.subsectors[ssi].sector) |si| {
                if (si < lvl.sectors.len) {
                    mo.floorz = lvl.sectors[si].floorheight;
                    mo.ceilingz = lvl.sectors[si].ceilingheight;
                }
            }
        }
    }

    /// Which child of a BSP node a point falls on (0 = front/right, 1 = back/left).
    fn pointOnSideNode(x: Fixed, y: Fixed, node: *const setup.Node) usize {
        if (node.dx.raw() == 0) {
            if (x.raw() <= node.x.raw()) return if (node.dy.raw() > 0) 1 else 0;
            return if (node.dy.raw() > 0) 0 else 1;
        }
        if (node.dy.raw() == 0) {
            if (y.raw() <= node.y.raw()) return if (node.dx.raw() < 0) 1 else 0;
            return if (node.dx.raw() < 0) 0 else 1;
        }
        const dx: i64 = @as(i64, x.raw()) - @as(i64, node.x.raw());
        const dy: i64 = @as(i64, y.raw()) - @as(i64, node.y.raw());
        const left: i64 = @as(i64, node.dy.raw()) * dx;
        const right: i64 = dy * @as(i64, node.dx.raw());
        if (right < left) return 0;
        return 1;
    }

    /// Draw title/demo screen page
    fn drawDemoPage(self: *Game, vid: *video.VideoState) void {
        const page_name: []const u8 = switch (self.demo_page) {
            0 => "TITLEPIC",
            1 => "CREDIT",
            2 => "HELP2",
            else => "TITLEPIC",
        };

        if (self.wad.findLump(page_name)) |lump| {
            const data = self.wad.lumpData(lump);
            // These are full-screen graphics (320x200)
            // Check if it's a patch or raw image
            if (data.len == defs.SCREENSIZE) {
                // Raw 320x200 image
                @memcpy(&vid.screens[0], data[0..defs.SCREENSIZE]);
            } else if (data.len > 8) {
                // Patch format
                video.drawPatch(vid, 0, 0, 0, data);
            }
        } else {
            vid.clearScreen(0, 0);
        }
    }

    /// Advance to next title screen page / demo in the cycle
    /// Cycle: TITLEPIC -> DEMO1 -> CREDIT -> DEMO2 -> CREDIT -> DEMO3 -> loop
    fn advanceDemoPage(self: *Game) void {
        self.demo_sequence += 1;
        if (self.demo_sequence > 5) self.demo_sequence = 0;

        switch (self.demo_sequence) {
            0 => {
                // TITLEPIC
                self.demo_page = 0;
                self.demo_page_tic = TICRATE * 5; // ~5 seconds (170 tics)
            },
            1 => {
                // Play DEMO1
                self.startDemoPlayback("DEMO1");
            },
            2 => {
                // CREDIT screen
                self.demo_page = 1;
                self.demo_page_tic = TICRATE * 6; // ~200 tics
            },
            3 => {
                // Play DEMO2
                self.startDemoPlayback("DEMO2");
            },
            4 => {
                // CREDIT/HELP2 screen
                self.demo_page = 2;
                self.demo_page_tic = TICRATE * 6;
            },
            5 => {
                // Play DEMO3
                self.startDemoPlayback("DEMO3");
            },
            else => {
                self.demo_sequence = 0;
                self.demo_page = 0;
                self.demo_page_tic = TICRATE * 5;
            },
        }
    }

    /// Start playing a demo lump from the WAD during title screen cycle
    fn startDemoPlayback(self: *Game, lump_name: []const u8) void {
        if (self.wad.findLump(lump_name)) |lump| {
            const data = self.wad.lumpData(lump);
            if (self.demo_state.startPlayback(data)) {
                self.demo_playback = true;
                // Start the level the demo uses
                const skill: defs.Skill = @enumFromInt(self.demo_state.skill);
                self.doNewGame(skill, self.demo_state.episode, self.demo_state.map);
                return;
            }
        }
        // If demo not found, just show next page quickly
        self.demo_page_tic = TICRATE * 2;
    }

    /// Read a demo ticcmd for the current tic
    pub fn readDemoTiccmd(self: *Game, cmd: *TicCmd) void {
        if (!self.demo_state.readTicCmd(cmd)) {
            // Demo ended — return to title screen cycle
            self.demo_playback = false;
            self.state = .demoscreen;
            self.advanceDemoPage();
        }
    }

    /// Write a demo ticcmd (for recording)
    pub fn writeDemoTiccmd(self: *Game, cmd: *TicCmd) void {
        if (self.demo_recording) {
            self.demo_state.writeTicCmd(cmd, self.allocator);
        }
    }

    // ========================================================================
    // Save / Load
    // ========================================================================

    /// Save the current game to a file
    fn doSaveGame(self: *Game) void {
        var path_buf: [64]u8 = undefined;
        const filename = saveg.getSaveFilename(self.save_slot, &path_buf);

        // Default description
        var desc: [24]u8 = undefined;
        @memcpy(&desc, &self.save_description);
        if (desc[0] == 0) {
            const default_desc = "DOOM Save";
            @memcpy(desc[0..default_desc.len], default_desc);
            desc[default_desc.len] = 0;
        }

        _ = saveg.saveGame(
            filename,
            &desc,
            self.skill,
            self.episode,
            self.map,
            self.player_in_game,
            &self.players,
            self.level_time,
            self.allocator,
        );

        // Remember quicksave slot
        self.quicksave_slot = @intCast(self.save_slot);
    }

    /// Load a game from a file
    fn doLoadGame(self: *Game) void {
        var path_buf: [64]u8 = undefined;
        const filename = saveg.getSaveFilename(self.save_slot, &path_buf);

        var skill: defs.Skill = .medium;
        var episode: u8 = 1;
        var map_val: u8 = 1;
        var pig: [MAXPLAYERS]bool = undefined;
        var level_time: i32 = 0;

        if (!saveg.loadGame(
            filename,
            &skill,
            &episode,
            &map_val,
            &pig,
            &level_time,
            &self.players,
            self.allocator,
        )) {
            return; // Load failed
        }

        // Set game parameters
        self.skill = skill;
        self.episode = episode;
        self.map = map_val;
        self.player_in_game = pig;

        // Load the level
        self.doLoadLevel();

        // Restore level time (doLoadLevel resets it)
        self.level_time = level_time;

        // Re-link player to mobj (find player mobj in thinker list)
        self.relinkPlayerMobjs();
    }

    /// After loading, re-link player pointers to their mobjs
    fn relinkPlayerMobjs(self: *Game) void {
        const cap = tick.getThinkerCap();
        var current = cap.next;
        while (current != null and current != cap) {
            const thinker = current.?;
            if (thinker.function) |func| {
                if (func == @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) {
                    const mo: *mobj_mod.MapObject = @fieldParentPtr("thinker", thinker);
                    if (mo.mobj_type == .MT_PLAYER) {
                        // Re-link player 0 (single player)
                        mo.player = @ptrCast(&self.players[self.consoleplayer]);
                        self.players[self.consoleplayer].mobj = mo;
                    }
                }
            }
            current = thinker.next;
        }
    }
};

/// Build map name string (e.g., "E1M1" or "MAP01")
fn buildMapName(episode: u8, map: u8, buf: *[8]u8) []const u8 {
    if (episode == 0) {
        // Commercial format: MAP01-MAP32
        buf[0] = 'M';
        buf[1] = 'A';
        buf[2] = 'P';
        buf[3] = '0' + map / 10;
        buf[4] = '0' + @as(u8, @intCast(@mod(map, 10)));
        buf[5] = 0;
        return buf[0..5];
    } else {
        // Episodic format: E1M1-E4M9
        buf[0] = 'E';
        buf[1] = '0' + episode;
        buf[2] = 'M';
        buf[3] = '0' + map;
        buf[4] = 0;
        return buf[0..4];
    }
}

/// Get par time in tics for a level
fn getParTime(episode: u8, map: u8) i32 {
    // Episode 1 par times (in seconds, converted to tics)
    const e1_pars = [9]i32{ 30, 75, 120, 90, 165, 180, 180, 30, 165 };

    if (episode >= 1 and episode <= 3 and map >= 1 and map <= 9) {
        if (episode == 1) {
            return e1_pars[map - 1] * TICRATE;
        }
        // Default par time for other episodes
        return 120 * TICRATE;
    }
    return 120 * TICRATE;
}

/// Check if this is the last level in the episode
fn isLastLevelInEpisode(episode: u8, map: u8) bool {
    if (episode == 0) {
        // Commercial: MAP30 is last
        return map == 30;
    }
    // Episodic: M8 is boss level
    return map == 8;
}

test "build map name episodic" {
    var buf: [8]u8 = undefined;
    const name = buildMapName(1, 1, &buf);
    try std.testing.expectEqualStrings("E1M1", name);
}

test "build map name episodic e2m3" {
    var buf: [8]u8 = undefined;
    const name = buildMapName(2, 3, &buf);
    try std.testing.expectEqualStrings("E2M3", name);
}

test "build map name commercial" {
    var buf: [8]u8 = undefined;
    const name = buildMapName(0, 1, &buf);
    try std.testing.expectEqualStrings("MAP01", name);
}

test "par time" {
    // E1M1 par time is 30 seconds = 1050 tics
    try std.testing.expectEqual(@as(i32, 30 * 35), getParTime(1, 1));
    // E1M2 par time is 75 seconds
    try std.testing.expectEqual(@as(i32, 75 * 35), getParTime(1, 2));
}

test "is last level" {
    try std.testing.expect(isLastLevelInEpisode(1, 8));
    try std.testing.expect(!isLastLevelInEpisode(1, 7));
    try std.testing.expect(isLastLevelInEpisode(0, 30));
    try std.testing.expect(!isLastLevelInEpisode(0, 15));
}
