//! zig_doom/src/ui/menu.zig
//!
//! Menu system — main menu, new game, options, skill select, etc.
//! Translated from: linuxdoom-1.10/m_menu.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM's menu: main menu -> new game -> episode -> skill -> start.
//! Navigation: Up/Down moves cursor, Enter selects, Escape backs out.

const std = @import("std");
const defs = @import("../defs.zig");
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;
const event = @import("../event.zig");
const Event = event.Event;
const random = @import("../random.zig");

pub const MenuType = enum {
    main_menu, // New Game, Options, Load, Save, Quit
    episode_select, // Which Episode
    skill_select, // Choose Your Skill
    options, // Sound, controls, etc.
    load_game,
    save_game,
    quit_confirm,
};

// Number of items per menu
const MAIN_ITEMS = 5;
const EPISODE_ITEMS = 4;
const SKILL_ITEMS = 5;

pub const MenuAction = enum {
    none,
    new_game, // Start new game with selected skill+episode
    quit, // Quit game
};

pub const Menu = struct {
    active: bool = false,
    current_menu: MenuType = .main_menu,
    item_on: u8 = 0, // Currently highlighted item

    // Skull cursor animation
    skull_anim_counter: i32 = 0,
    skull_anim: u8 = 0, // 0 or 1 (two skull frames)

    // Selection results
    selected_episode: u8 = 0,
    selected_skill: defs.Skill = .medium,

    // Cached WAD patches
    skull_patches: [2]?usize = [_]?usize{null} ** 2, // M_SKULL1, M_SKULL2
    main_title: ?usize = null, // M_DOOM
    new_game_patch: ?usize = null, // M_NGAME
    options_patch: ?usize = null, // M_OPTION
    load_game_patch: ?usize = null, // M_LOADG
    save_game_patch: ?usize = null, // M_SAVEG
    quit_game_patch: ?usize = null, // M_QUITG
    episode_patches: [4]?usize = [_]?usize{null} ** 4, // M_EPI1-M_EPI4
    skill_patches: [5]?usize = [_]?usize{null} ** 5, // M_JKILL-M_NMARE
    new_game_text: ?usize = null, // M_NEWG

    /// Initialize the menu by caching WAD patch lump numbers
    pub fn init(w: *const Wad) Menu {
        var self = Menu{};

        self.skull_patches[0] = w.findLump("M_SKULL1");
        self.skull_patches[1] = w.findLump("M_SKULL2");
        self.main_title = w.findLump("M_DOOM");
        self.new_game_patch = w.findLump("M_NGAME");
        self.options_patch = w.findLump("M_OPTION");
        self.load_game_patch = w.findLump("M_LOADG");
        self.save_game_patch = w.findLump("M_SAVEG");
        self.quit_game_patch = w.findLump("M_QUITG");
        self.new_game_text = w.findLump("M_NEWG");

        // Episode patches
        self.episode_patches[0] = w.findLump("M_EPI1");
        self.episode_patches[1] = w.findLump("M_EPI2");
        self.episode_patches[2] = w.findLump("M_EPI3");
        self.episode_patches[3] = w.findLump("M_EPI4");

        // Skill patches
        self.skill_patches[0] = w.findLump("M_JKILL");
        self.skill_patches[1] = w.findLump("M_ROUGH");
        self.skill_patches[2] = w.findLump("M_HURT");
        self.skill_patches[3] = w.findLump("M_ULTRA");
        self.skill_patches[4] = w.findLump("M_NMARE");

        return self;
    }

    /// Handle an input event. Returns a MenuAction if something happened.
    pub fn responder(self: *Menu, ev: *const Event) MenuAction {
        // ESC toggles menu
        if (ev.event_type == .key_down and ev.data1 == event.KEY_ESCAPE) {
            if (self.active) {
                if (self.current_menu == .main_menu) {
                    self.active = false;
                } else {
                    // Back to parent menu
                    self.goBack();
                }
            } else {
                self.active = true;
                self.current_menu = .main_menu;
                self.item_on = 0;
            }
            return .none;
        }

        if (!self.active) return .none;

        if (ev.event_type != .key_down) return .none;

        switch (ev.data1) {
            event.KEY_DOWNARROW => {
                self.item_on += 1;
                if (self.item_on >= self.itemCount()) {
                    self.item_on = 0;
                }
            },
            event.KEY_UPARROW => {
                if (self.item_on == 0) {
                    self.item_on = self.itemCount() - 1;
                } else {
                    self.item_on -= 1;
                }
            },
            event.KEY_ENTER => {
                return self.selectItem();
            },
            else => {},
        }

        return .none;
    }

    /// Animate skull cursor
    pub fn ticker(self: *Menu) void {
        if (!self.active) return;

        self.skull_anim_counter += 1;
        if (self.skull_anim_counter >= 8) {
            self.skull_anim_counter = 0;
            self.skull_anim ^= 1;
        }
    }

    /// Draw the menu to screen
    pub fn drawer(self: *const Menu, vid: *video.VideoState, w: *const Wad) void {
        if (!self.active) return;

        switch (self.current_menu) {
            .main_menu => self.drawMainMenu(vid, w),
            .episode_select => self.drawEpisodeMenu(vid, w),
            .skill_select => self.drawSkillMenu(vid, w),
            .options, .load_game, .save_game => {
                // Stub: just clear screen
                vid.clearScreen(0, 0);
            },
            .quit_confirm => {},
        }
    }

    /// Draw main menu
    fn drawMainMenu(self: *const Menu, vid: *video.VideoState, w: *const Wad) void {
        // Draw title
        if (self.main_title) |lump| {
            video.drawPatch(vid, 0, 94, 2, w.lumpData(lump));
        }

        // Menu items: y starts at 64, each item 16 pixels apart
        const items = [5]?usize{
            self.new_game_patch,
            self.options_patch,
            self.load_game_patch,
            self.save_game_patch,
            self.quit_game_patch,
        };

        for (items, 0..) |maybe_lump, i| {
            const y: i32 = 64 + @as(i32, @intCast(i)) * 16;
            if (maybe_lump) |lump| {
                video.drawPatch(vid, 0, 97, y, w.lumpData(lump));
            }
        }

        // Draw skull cursor
        const skull_y: i32 = 64 + @as(i32, self.item_on) * 16 - 5;
        if (self.skull_patches[self.skull_anim]) |lump| {
            video.drawPatch(vid, 0, 65, skull_y, w.lumpData(lump));
        }
    }

    /// Draw episode select menu
    fn drawEpisodeMenu(self: *const Menu, vid: *video.VideoState, w: *const Wad) void {
        if (self.new_game_text) |lump| {
            video.drawPatch(vid, 0, 96, 14, w.lumpData(lump));
        }

        for (self.episode_patches, 0..) |maybe_lump, i| {
            const y: i32 = 64 + @as(i32, @intCast(i)) * 16;
            if (maybe_lump) |lump| {
                video.drawPatch(vid, 0, 48, y, w.lumpData(lump));
            }
        }

        const skull_y: i32 = 64 + @as(i32, self.item_on) * 16 - 5;
        if (self.skull_patches[self.skull_anim]) |lump| {
            video.drawPatch(vid, 0, 16, skull_y, w.lumpData(lump));
        }
    }

    /// Draw skill select menu
    fn drawSkillMenu(self: *const Menu, vid: *video.VideoState, w: *const Wad) void {
        if (self.new_game_text) |lump| {
            video.drawPatch(vid, 0, 96, 14, w.lumpData(lump));
        }

        for (self.skill_patches, 0..) |maybe_lump, i| {
            const y: i32 = 64 + @as(i32, @intCast(i)) * 16;
            if (maybe_lump) |lump| {
                video.drawPatch(vid, 0, 48, y, w.lumpData(lump));
            }
        }

        const skull_y: i32 = 64 + @as(i32, self.item_on) * 16 - 5;
        if (self.skull_patches[self.skull_anim]) |lump| {
            video.drawPatch(vid, 0, 16, skull_y, w.lumpData(lump));
        }
    }

    // ========================================================================
    // Internal
    // ========================================================================

    fn itemCount(self: *const Menu) u8 {
        return switch (self.current_menu) {
            .main_menu => MAIN_ITEMS,
            .episode_select => EPISODE_ITEMS,
            .skill_select => SKILL_ITEMS,
            .options => 1,
            .load_game, .save_game => 6,
            .quit_confirm => 2,
        };
    }

    fn selectItem(self: *Menu) MenuAction {
        switch (self.current_menu) {
            .main_menu => {
                switch (self.item_on) {
                    0 => {
                        // New Game -> episode select
                        self.current_menu = .episode_select;
                        self.item_on = 0;
                    },
                    1 => {
                        // Options (stub)
                        self.current_menu = .options;
                        self.item_on = 0;
                    },
                    2 => {
                        // Load Game (stub)
                        self.current_menu = .load_game;
                        self.item_on = 0;
                    },
                    3 => {
                        // Save Game (stub)
                        self.current_menu = .save_game;
                        self.item_on = 0;
                    },
                    4 => {
                        // Quit
                        return .quit;
                    },
                    else => {},
                }
            },
            .episode_select => {
                self.selected_episode = self.item_on;
                self.current_menu = .skill_select;
                self.item_on = 2; // Default to Hurt Me Plenty
            },
            .skill_select => {
                self.selected_skill = @enumFromInt(self.item_on);
                self.active = false;
                return .new_game;
            },
            .options, .load_game, .save_game, .quit_confirm => {},
        }
        return .none;
    }

    fn goBack(self: *Menu) void {
        switch (self.current_menu) {
            .episode_select => {
                self.current_menu = .main_menu;
                self.item_on = 0;
            },
            .skill_select => {
                self.current_menu = .episode_select;
                self.item_on = self.selected_episode;
            },
            .options, .load_game, .save_game, .quit_confirm => {
                self.current_menu = .main_menu;
                self.item_on = 0;
            },
            .main_menu => {
                self.active = false;
            },
        }
    }
};

test "menu init" {
    const menu = Menu{};
    try std.testing.expect(!menu.active);
    try std.testing.expectEqual(MenuType.main_menu, menu.current_menu);
}

test "menu navigation" {
    var menu = Menu{};
    menu.active = true;

    // Move down
    const down_ev = Event{
        .event_type = .key_down,
        .data1 = event.KEY_DOWNARROW,
        .data2 = 0,
        .data3 = 0,
    };
    _ = menu.responder(&down_ev);
    try std.testing.expectEqual(@as(u8, 1), menu.item_on);

    _ = menu.responder(&down_ev);
    try std.testing.expectEqual(@as(u8, 2), menu.item_on);

    // Move up
    const up_ev = Event{
        .event_type = .key_down,
        .data1 = event.KEY_UPARROW,
        .data2 = 0,
        .data3 = 0,
    };
    _ = menu.responder(&up_ev);
    try std.testing.expectEqual(@as(u8, 1), menu.item_on);
}

test "menu select new game flow" {
    var menu = Menu{};
    menu.active = true;
    menu.item_on = 0; // New Game

    const enter_ev = Event{
        .event_type = .key_down,
        .data1 = event.KEY_ENTER,
        .data2 = 0,
        .data3 = 0,
    };

    // Select New Game -> goes to episode select
    _ = menu.responder(&enter_ev);
    try std.testing.expectEqual(MenuType.episode_select, menu.current_menu);

    // Select episode 0
    _ = menu.responder(&enter_ev);
    try std.testing.expectEqual(MenuType.skill_select, menu.current_menu);
    try std.testing.expectEqual(@as(u8, 0), menu.selected_episode);

    // Select skill (item_on is 2 = medium by default)
    const action = menu.responder(&enter_ev);
    try std.testing.expectEqual(MenuAction.new_game, action);
    try std.testing.expectEqual(defs.Skill.medium, menu.selected_skill);
    try std.testing.expect(!menu.active);
}
