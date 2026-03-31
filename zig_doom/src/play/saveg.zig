//! zig_doom/src/play/saveg.zig
//!
//! Save/Load game serialization.
//! Translated from: linuxdoom-1.10/p_saveg.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM saves the complete game state to a linear byte stream.
//! Pointer fields are converted to indices (sector, line, mobj ordinal).

const std = @import("std");
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const info = @import("../info.zig");
const StateNum = info.StateNum;
const MobjType = info.MobjType;
const tick = @import("tick.zig");
const Thinker = tick.Thinker;
const mobj_mod = @import("mobj.zig");
const MapObject = mobj_mod.MapObject;
const user = @import("user.zig");
const Player = user.Player;
const TicCmd = user.TicCmd;
const setup = @import("setup.zig");
const Level = setup.Level;
const doors = @import("doors.zig");
const VerticalDoor = doors.VerticalDoor;
const floor_mod = @import("floor.zig");
const FloorMover = floor_mod.FloorMover;
const ceiling = @import("ceiling.zig");
const CeilingMover = ceiling.CeilingMover;
const lights = @import("lights.zig");
const LightFlash = lights.LightFlash;
const StrobeFlash = lights.StrobeFlash;
const Glow = lights.Glow;

const c = @cImport({
    @cInclude("stdio.h");
});

const MAXPLAYERS = defs.MAXPLAYERS;

// Save format version
const SAVE_VERSION: u8 = 0x6D; // 109 = DOOM 1.9

// Thinker class markers
const TC_END: u8 = 0x01;
const TC_MOBJ: u8 = 0x02;
const TC_CEILING: u8 = 0x03;
const TC_DOOR: u8 = 0x04;
const TC_FLOOR: u8 = 0x05;
const TC_PLAT: u8 = 0x06;
const TC_FLASH: u8 = 0x07;
const TC_STROBE: u8 = 0x08;
const TC_GLOW: u8 = 0x09;

// Description length
const SAVE_DESC_LEN = 24;

// Maximum save buffer size (1 MB should be enough for any DOOM level)
const MAX_SAVE_SIZE = 1024 * 1024;

// ============================================================================
// Save Buffer — linear byte stream writer/reader
// ============================================================================

const SaveBuffer = struct {
    data: []u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ?SaveBuffer {
        const data = allocator.alloc(u8, MAX_SAVE_SIZE) catch return null;
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *SaveBuffer) void {
        self.allocator.free(self.data);
    }

    // Writers
    fn writeByte(self: *SaveBuffer, v: u8) void {
        if (self.pos < self.data.len) {
            self.data[self.pos] = v;
            self.pos += 1;
        }
    }

    fn writeI16(self: *SaveBuffer, v: i16) void {
        const bytes: [2]u8 = @bitCast(v);
        self.writeByte(bytes[0]);
        self.writeByte(bytes[1]);
    }

    fn writeI32(self: *SaveBuffer, v: i32) void {
        const bytes: [4]u8 = @bitCast(v);
        for (bytes) |b| self.writeByte(b);
    }

    fn writeU32(self: *SaveBuffer, v: u32) void {
        const bytes: [4]u8 = @bitCast(v);
        for (bytes) |b| self.writeByte(b);
    }

    fn writeU16(self: *SaveBuffer, v: u16) void {
        const bytes: [2]u8 = @bitCast(v);
        self.writeByte(bytes[0]);
        self.writeByte(bytes[1]);
    }

    fn writeFixed(self: *SaveBuffer, v: Fixed) void {
        self.writeI32(v.raw());
    }

    fn writeBytes(self: *SaveBuffer, bytes: []const u8) void {
        for (bytes) |b| self.writeByte(b);
    }

    // Readers
    fn readByte(self: *SaveBuffer) u8 {
        if (self.pos < self.data.len) {
            const v = self.data[self.pos];
            self.pos += 1;
            return v;
        }
        return 0;
    }

    fn readI16(self: *SaveBuffer) i16 {
        var bytes: [2]u8 = undefined;
        bytes[0] = self.readByte();
        bytes[1] = self.readByte();
        return @bitCast(bytes);
    }

    fn readI32(self: *SaveBuffer) i32 {
        var bytes: [4]u8 = undefined;
        for (&bytes) |*b| b.* = self.readByte();
        return @bitCast(bytes);
    }

    fn readU32(self: *SaveBuffer) u32 {
        var bytes: [4]u8 = undefined;
        for (&bytes) |*b| b.* = self.readByte();
        return @bitCast(bytes);
    }

    fn readU16(self: *SaveBuffer) u16 {
        var bytes: [2]u8 = undefined;
        bytes[0] = self.readByte();
        bytes[1] = self.readByte();
        return @bitCast(bytes);
    }

    fn readFixed(self: *SaveBuffer) Fixed {
        return Fixed.fromRaw(self.readI32());
    }

    fn readBytes(self: *SaveBuffer, out: []u8) void {
        for (out) |*b| b.* = self.readByte();
    }
};

// ============================================================================
// Save Game
// ============================================================================

/// Save the current game state to a file.
/// Returns true on success.
pub fn saveGame(
    path: []const u8,
    description: []const u8,
    skill: defs.Skill,
    episode: u8,
    map: u8,
    player_in_game: [MAXPLAYERS]bool,
    players: []const Player,
    level_time: i32,
    allocator: std.mem.Allocator,
) bool {
    var buf = SaveBuffer.init(allocator) orelse return false;
    defer buf.deinit();

    // Write description (24 bytes, null-padded)
    var desc_buf: [SAVE_DESC_LEN]u8 = [_]u8{0} ** SAVE_DESC_LEN;
    const copy_len = @min(description.len, SAVE_DESC_LEN);
    @memcpy(desc_buf[0..copy_len], description[0..copy_len]);
    buf.writeBytes(&desc_buf);

    // Version
    buf.writeByte(SAVE_VERSION);

    // Game params
    buf.writeByte(@intFromEnum(skill));
    buf.writeByte(episode);
    buf.writeByte(map);

    // Player in game flags
    for (0..MAXPLAYERS) |i| {
        buf.writeByte(if (player_in_game[i]) 1 else 0);
    }

    // Level time
    buf.writeI32(level_time);

    // --- Thinker data ---
    saveThinkers(&buf);

    // --- Player data ---
    for (0..MAXPLAYERS) |i| {
        if (player_in_game[i]) {
            if (i < players.len) {
                savePlayer(&buf, &players[i]);
            }
        }
    }

    // End marker
    buf.writeByte(TC_END);

    // Write to file
    const f = c.fopen(path.ptr, "wb");
    if (f == null) return false;
    defer _ = c.fclose(f);
    _ = c.fwrite(buf.data.ptr, 1, buf.pos, f);

    return true;
}

/// Write all thinkers to the save buffer
fn saveThinkers(buf: *SaveBuffer) void {
    const cap = tick.getThinkerCap();
    var current = cap.next;

    while (current != null and current != cap) {
        const thinker = current.?;

        if (thinker.function) |func| {
            // Identify thinker type by function pointer
            if (func == @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) {
                buf.writeByte(TC_MOBJ);
                const mo: *MapObject = @fieldParentPtr("thinker", thinker);
                saveMobj(buf, mo);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&doors.T_VerticalDoor))) {
                buf.writeByte(TC_DOOR);
                const door: *VerticalDoor = @fieldParentPtr("thinker", thinker);
                saveDoor(buf, door);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&floor_mod.T_MoveFloor))) {
                buf.writeByte(TC_FLOOR);
                const fm: *FloorMover = @fieldParentPtr("thinker", thinker);
                saveFloor(buf, fm);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&ceiling.T_MoveCeiling))) {
                buf.writeByte(TC_CEILING);
                const cm: *CeilingMover = @fieldParentPtr("thinker", thinker);
                saveCeiling(buf, cm);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&lights.T_LightFlash))) {
                buf.writeByte(TC_FLASH);
                const lf: *LightFlash = @fieldParentPtr("thinker", thinker);
                saveLightFlash(buf, lf);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&lights.T_StrobeFlash))) {
                buf.writeByte(TC_STROBE);
                const sf: *StrobeFlash = @fieldParentPtr("thinker", thinker);
                saveStrobeFlash(buf, sf);
            } else if (func == @as(tick.ThinkFn, @ptrCast(&lights.T_Glow))) {
                buf.writeByte(TC_GLOW);
                const glow: *Glow = @fieldParentPtr("thinker", thinker);
                saveGlow(buf, glow);
            }
        }

        current = thinker.next;
    }

    buf.writeByte(TC_END);
}

/// Serialize a MapObject
fn saveMobj(buf: *SaveBuffer, mo: *const MapObject) void {
    buf.writeFixed(mo.x);
    buf.writeFixed(mo.y);
    buf.writeFixed(mo.z);
    buf.writeU32(mo.angle);
    buf.writeU16(@intFromEnum(mo.sprite));
    buf.writeI32(mo.frame);
    buf.writeFixed(mo.floorz);
    buf.writeFixed(mo.ceilingz);
    buf.writeFixed(mo.radius);
    buf.writeFixed(mo.height);
    buf.writeFixed(mo.momx);
    buf.writeFixed(mo.momy);
    buf.writeFixed(mo.momz);
    buf.writeU16(@intFromEnum(mo.mobj_type));
    buf.writeI32(mo.tics);
    buf.writeU16(@intFromEnum(mo.state_num));
    buf.writeU32(mo.flags);
    buf.writeI32(mo.health);
    buf.writeI32(mo.movedir);
    buf.writeI32(mo.movecount);
    buf.writeI32(mo.reaction_time);
    buf.writeI32(mo.threshold);
    buf.writeI32(mo.last_look);

    // Spawn point
    buf.writeI16(mo.spawn_point.x);
    buf.writeI16(mo.spawn_point.y);
    buf.writeI16(mo.spawn_point.angle);
    buf.writeI16(mo.spawn_point.thing_type);
    buf.writeI16(mo.spawn_point.options);

    // Subsector (as index, -1 for null)
    if (mo.subsector_id) |ss| {
        buf.writeI32(@intCast(ss));
    } else {
        buf.writeI32(-1);
    }

    // Has player? (boolean flag)
    buf.writeByte(if (mo.player != null) 1 else 0);
}

/// Serialize a VerticalDoor
fn saveDoor(buf: *SaveBuffer, door: *const VerticalDoor) void {
    buf.writeByte(@intFromEnum(door.door_type));
    buf.writeU16(door.sector_idx);
    buf.writeFixed(door.top_height);
    buf.writeFixed(door.speed);
    buf.writeI32(door.direction);
    buf.writeI32(door.top_wait);
    buf.writeI32(door.top_count_down);
}

/// Serialize a FloorMover
fn saveFloor(buf: *SaveBuffer, fm: *const FloorMover) void {
    buf.writeByte(@intFromEnum(fm.floor_type));
    buf.writeByte(if (fm.crush) 1 else 0);
    buf.writeU16(fm.sector_idx);
    buf.writeI32(fm.direction);
    buf.writeI16(fm.new_special);
    buf.writeI16(fm.texture);
    buf.writeFixed(fm.floor_dest_height);
    buf.writeFixed(fm.speed);
}

/// Serialize a CeilingMover
fn saveCeiling(buf: *SaveBuffer, cm: *const CeilingMover) void {
    buf.writeByte(@intFromEnum(cm.ceiling_type));
    buf.writeU16(cm.sector_idx);
    buf.writeFixed(cm.bottom_height);
    buf.writeFixed(cm.top_height);
    buf.writeFixed(cm.speed);
    buf.writeByte(if (cm.crush) 1 else 0);
    buf.writeI32(cm.direction);
    buf.writeI16(cm.tag);
    buf.writeI32(cm.old_direction);
}

/// Serialize a LightFlash
fn saveLightFlash(buf: *SaveBuffer, lf: *const LightFlash) void {
    buf.writeU16(lf.sector_idx);
    buf.writeI32(lf.count);
    buf.writeI16(lf.max_light);
    buf.writeI16(lf.min_light);
}

/// Serialize a StrobeFlash
fn saveStrobeFlash(buf: *SaveBuffer, sf: *const StrobeFlash) void {
    buf.writeU16(sf.sector_idx);
    buf.writeI32(sf.count);
    buf.writeI16(sf.min_light);
    buf.writeI16(sf.max_light);
    buf.writeI32(sf.dark_time);
    buf.writeI32(sf.bright_time);
}

/// Serialize a Glow
fn saveGlow(buf: *SaveBuffer, glow: *const Glow) void {
    buf.writeU16(glow.sector_idx);
    buf.writeI16(glow.min_light);
    buf.writeI16(glow.max_light);
    buf.writeI32(glow.direction);
}

// ============================================================================
// Save Player
// ============================================================================

fn savePlayer(buf: *SaveBuffer, player: *const Player) void {
    buf.writeByte(@intFromEnum(player.player_state));
    buf.writeI32(player.health);
    buf.writeI32(player.armor_points);
    buf.writeI32(player.armor_type);

    // Keys
    for (player.cards) |has_card| {
        buf.writeByte(if (has_card) 1 else 0);
    }
    buf.writeByte(if (player.backpack) 1 else 0);

    // Weapons
    buf.writeByte(@intFromEnum(player.ready_weapon));
    buf.writeByte(@intFromEnum(player.pending_weapon));
    for (player.weapon_owned) |owned| {
        buf.writeByte(if (owned) 1 else 0);
    }

    // Ammo
    for (player.ammo) |count| {
        buf.writeI32(count);
    }
    for (player.max_ammo) |max| {
        buf.writeI32(max);
    }

    // Powers
    for (player.powers) |pwr| {
        buf.writeI32(pwr);
    }

    // Stats
    buf.writeI32(player.kill_count);
    buf.writeI32(player.item_count);
    buf.writeI32(player.secret_count);

    // Damage
    buf.writeI32(player.damage_count);
    buf.writeI32(player.bonus_count);
    buf.writeI32(player.extra_light);

    // Cheats
    buf.writeU32(player.cheats);

    // View
    buf.writeFixed(player.viewz);
    buf.writeFixed(player.viewheight);
    buf.writeFixed(player.deltaviewheight);
    buf.writeFixed(player.bob);

    buf.writeI32(player.player_num);
}

// ============================================================================
// Load Game
// ============================================================================

/// Load game state from a file.
/// Returns true on success. On success, the caller should use the
/// returned skill/episode/map to call doLoadLevel, then apply the loaded state.
pub fn loadGame(
    path: []const u8,
    out_skill: *defs.Skill,
    out_episode: *u8,
    out_map: *u8,
    out_player_in_game: *[MAXPLAYERS]bool,
    out_level_time: *i32,
    players: []Player,
    allocator: std.mem.Allocator,
) bool {
    // Read file
    const f = c.fopen(path.ptr, "rb");
    if (f == null) return false;
    defer _ = c.fclose(f);

    var buf = SaveBuffer.init(allocator) orelse return false;
    defer buf.deinit();

    const bytes_read = c.fread(buf.data.ptr, 1, MAX_SAVE_SIZE, f);
    if (bytes_read <= 0) return false;

    // Skip description
    buf.pos = SAVE_DESC_LEN;

    // Version check
    const version = buf.readByte();
    if (version != SAVE_VERSION) return false;

    // Game params
    const skill_val = buf.readByte();
    if (skill_val > 4) return false;
    out_skill.* = @enumFromInt(skill_val);
    out_episode.* = buf.readByte();
    out_map.* = buf.readByte();

    // Player in game flags
    for (0..MAXPLAYERS) |i| {
        out_player_in_game.*[i] = buf.readByte() != 0;
    }

    // Level time
    out_level_time.* = buf.readI32();

    // --- Thinkers ---
    loadThinkers(&buf, allocator);

    // --- Players ---
    for (0..MAXPLAYERS) |i| {
        if (out_player_in_game.*[i] and i < players.len) {
            loadPlayer(&buf, &players[i]);
        }
    }

    return true;
}

/// Load thinkers from save buffer
fn loadThinkers(buf: *SaveBuffer, allocator: std.mem.Allocator) void {
    // Clear existing thinkers
    tick.initThinkers();

    while (true) {
        const tc = buf.readByte();
        if (tc == TC_END) break;

        switch (tc) {
            TC_MOBJ => {
                const mo = allocator.create(MapObject) catch continue;
                mo.* = MapObject{};
                loadMobj(buf, mo);
                mo.thinker.function = @ptrCast(&mobj_mod.mobjThinker);
                tick.addThinker(&mo.thinker);
                mo.allocator = allocator;
            },
            TC_DOOR => {
                const door = allocator.create(VerticalDoor) catch continue;
                door.* = VerticalDoor{};
                loadDoor(buf, door);
                door.thinker.function = @ptrCast(&doors.T_VerticalDoor);
                tick.addThinker(&door.thinker);
            },
            TC_FLOOR => {
                const fm = allocator.create(FloorMover) catch continue;
                fm.* = FloorMover{};
                loadFloor(buf, fm);
                fm.thinker.function = @ptrCast(&floor_mod.T_MoveFloor);
                tick.addThinker(&fm.thinker);
            },
            TC_CEILING => {
                const cm = allocator.create(CeilingMover) catch continue;
                cm.* = CeilingMover{};
                loadCeiling(buf, cm);
                cm.thinker.function = @ptrCast(&ceiling.T_MoveCeiling);
                tick.addThinker(&cm.thinker);
            },
            TC_FLASH => {
                const lf = allocator.create(LightFlash) catch continue;
                lf.* = LightFlash{};
                loadLightFlash(buf, lf);
                lf.thinker.function = @ptrCast(&lights.T_LightFlash);
                tick.addThinker(&lf.thinker);
            },
            TC_STROBE => {
                const sf = allocator.create(StrobeFlash) catch continue;
                sf.* = StrobeFlash{};
                loadStrobeFlash(buf, sf);
                sf.thinker.function = @ptrCast(&lights.T_StrobeFlash);
                tick.addThinker(&sf.thinker);
            },
            TC_GLOW => {
                const glow = allocator.create(Glow) catch continue;
                glow.* = Glow{};
                loadGlow(buf, glow);
                glow.thinker.function = @ptrCast(&lights.T_Glow);
                tick.addThinker(&glow.thinker);
            },
            else => break, // Unknown thinker type — stop loading
        }
    }
}

/// Deserialize a MapObject
fn loadMobj(buf: *SaveBuffer, mo: *MapObject) void {
    mo.x = buf.readFixed();
    mo.y = buf.readFixed();
    mo.z = buf.readFixed();
    mo.angle = buf.readU32();
    mo.sprite = @enumFromInt(buf.readU16());
    mo.frame = buf.readI32();
    mo.floorz = buf.readFixed();
    mo.ceilingz = buf.readFixed();
    mo.radius = buf.readFixed();
    mo.height = buf.readFixed();
    mo.momx = buf.readFixed();
    mo.momy = buf.readFixed();
    mo.momz = buf.readFixed();
    mo.mobj_type = @enumFromInt(buf.readU16());
    mo.tics = buf.readI32();
    mo.state_num = @enumFromInt(buf.readU16());
    mo.flags = buf.readU32();
    mo.health = buf.readI32();
    mo.movedir = buf.readI32();
    mo.movecount = buf.readI32();
    mo.reaction_time = buf.readI32();
    mo.threshold = buf.readI32();
    mo.last_look = buf.readI32();

    // Spawn point
    mo.spawn_point.x = buf.readI16();
    mo.spawn_point.y = buf.readI16();
    mo.spawn_point.angle = buf.readI16();
    mo.spawn_point.thing_type = buf.readI16();
    mo.spawn_point.options = buf.readI16();

    // Subsector
    const ss = buf.readI32();
    mo.subsector_id = if (ss >= 0) @intCast(ss) else null;

    // Player flag (pointer will be re-linked by caller)
    const has_player = buf.readByte();
    _ = has_player;
    mo.player = null;
}

/// Deserialize a VerticalDoor
fn loadDoor(buf: *SaveBuffer, door: *VerticalDoor) void {
    door.door_type = @enumFromInt(buf.readByte());
    door.sector_idx = buf.readU16();
    door.top_height = buf.readFixed();
    door.speed = buf.readFixed();
    door.direction = buf.readI32();
    door.top_wait = buf.readI32();
    door.top_count_down = buf.readI32();
}

/// Deserialize a FloorMover
fn loadFloor(buf: *SaveBuffer, fm: *FloorMover) void {
    fm.floor_type = @enumFromInt(buf.readByte());
    fm.crush = buf.readByte() != 0;
    fm.sector_idx = buf.readU16();
    fm.direction = buf.readI32();
    fm.new_special = buf.readI16();
    fm.texture = buf.readI16();
    fm.floor_dest_height = buf.readFixed();
    fm.speed = buf.readFixed();
}

/// Deserialize a CeilingMover
fn loadCeiling(buf: *SaveBuffer, cm: *CeilingMover) void {
    cm.ceiling_type = @enumFromInt(buf.readByte());
    cm.sector_idx = buf.readU16();
    cm.bottom_height = buf.readFixed();
    cm.top_height = buf.readFixed();
    cm.speed = buf.readFixed();
    cm.crush = buf.readByte() != 0;
    cm.direction = buf.readI32();
    cm.tag = buf.readI16();
    cm.old_direction = buf.readI32();
}

/// Deserialize a LightFlash
fn loadLightFlash(buf: *SaveBuffer, lf: *LightFlash) void {
    lf.sector_idx = buf.readU16();
    lf.count = buf.readI32();
    lf.max_light = buf.readI16();
    lf.min_light = buf.readI16();
}

/// Deserialize a StrobeFlash
fn loadStrobeFlash(buf: *SaveBuffer, sf: *StrobeFlash) void {
    sf.sector_idx = buf.readU16();
    sf.count = buf.readI32();
    sf.min_light = buf.readI16();
    sf.max_light = buf.readI16();
    sf.dark_time = buf.readI32();
    sf.bright_time = buf.readI32();
}

/// Deserialize a Glow
fn loadGlow(buf: *SaveBuffer, glow: *Glow) void {
    glow.sector_idx = buf.readU16();
    glow.min_light = buf.readI16();
    glow.max_light = buf.readI16();
    glow.direction = buf.readI32();
}

/// Deserialize a Player
fn loadPlayer(buf: *SaveBuffer, player: *Player) void {
    player.player_state = @enumFromInt(buf.readByte());
    player.health = buf.readI32();
    player.armor_points = buf.readI32();
    player.armor_type = buf.readI32();

    // Keys
    for (&player.cards) |*card| {
        card.* = buf.readByte() != 0;
    }
    player.backpack = buf.readByte() != 0;

    // Weapons
    player.ready_weapon = @enumFromInt(buf.readByte());
    player.pending_weapon = @enumFromInt(buf.readByte());
    for (&player.weapon_owned) |*owned| {
        owned.* = buf.readByte() != 0;
    }

    // Ammo
    for (&player.ammo) |*count| {
        count.* = buf.readI32();
    }
    for (&player.max_ammo) |*max| {
        max.* = buf.readI32();
    }

    // Powers
    for (&player.powers) |*pwr| {
        pwr.* = buf.readI32();
    }

    // Stats
    player.kill_count = buf.readI32();
    player.item_count = buf.readI32();
    player.secret_count = buf.readI32();

    // Damage
    player.damage_count = buf.readI32();
    player.bonus_count = buf.readI32();
    player.extra_light = buf.readI32();

    // Cheats
    player.cheats = buf.readU32();

    // View
    player.viewz = buf.readFixed();
    player.viewheight = buf.readFixed();
    player.deltaviewheight = buf.readFixed();
    player.bob = buf.readFixed();

    player.player_num = buf.readI32();
}

// ============================================================================
// Save slot helpers
// ============================================================================

/// Get the save game filename for a slot (0-5)
pub fn getSaveFilename(slot: u8, buf: *[64]u8) []const u8 {
    const prefix = "doomsav";
    const suffix = ".dsg";
    @memcpy(buf[0..7], prefix);
    buf[7] = '0' + (slot % 6);
    @memcpy(buf[8..12], suffix);
    buf[12] = 0;
    return buf[0..12];
}

/// Read just the description from a save file (for menu display)
pub fn readSaveDescription(path: []const u8, desc_out: *[SAVE_DESC_LEN]u8) bool {
    const f = c.fopen(path.ptr, "rb");
    if (f == null) return false;
    defer _ = c.fclose(f);

    const n = c.fread(desc_out, 1, SAVE_DESC_LEN, f);
    return n == SAVE_DESC_LEN;
}

// ============================================================================
// Tests
// ============================================================================

test "save buffer write/read byte" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    buf.writeByte(42);
    buf.writeByte(0xFF);
    buf.pos = 0;

    try std.testing.expectEqual(@as(u8, 42), buf.readByte());
    try std.testing.expectEqual(@as(u8, 0xFF), buf.readByte());
}

test "save buffer write/read i32" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    buf.writeI32(12345);
    buf.writeI32(-99999);
    buf.pos = 0;

    try std.testing.expectEqual(@as(i32, 12345), buf.readI32());
    try std.testing.expectEqual(@as(i32, -99999), buf.readI32());
}

test "save buffer write/read fixed" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    const val = Fixed.fromInt(42);
    buf.writeFixed(val);
    buf.pos = 0;

    try std.testing.expectEqual(val, buf.readFixed());
}

test "save filename" {
    var buf: [64]u8 = undefined;
    const name = getSaveFilename(0, &buf);
    try std.testing.expectEqualStrings("doomsav0.dsg", name);
}

test "save filename slot 5" {
    var buf: [64]u8 = undefined;
    const name = getSaveFilename(5, &buf);
    try std.testing.expectEqualStrings("doomsav5.dsg", name);
}

test "player save/load roundtrip" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    // Create a player with non-default state
    var player = Player{};
    player.health = 75;
    player.armor_points = 100;
    player.armor_type = 2;
    player.cards[0] = true; // blue card
    player.cards[3] = true; // blue skull
    player.weapon_owned[2] = true; // shotgun
    player.ammo[0] = 150;
    player.ammo[1] = 25;
    player.kill_count = 42;
    player.player_num = 0;

    // Save
    savePlayer(&buf, &player);

    // Load
    buf.pos = 0;
    var loaded = Player{};
    loadPlayer(&buf, &loaded);

    // Verify
    try std.testing.expectEqual(@as(i32, 75), loaded.health);
    try std.testing.expectEqual(@as(i32, 100), loaded.armor_points);
    try std.testing.expectEqual(@as(i32, 2), loaded.armor_type);
    try std.testing.expect(loaded.cards[0]);
    try std.testing.expect(!loaded.cards[1]);
    try std.testing.expect(loaded.cards[3]);
    try std.testing.expect(loaded.weapon_owned[2]);
    try std.testing.expectEqual(@as(i32, 150), loaded.ammo[0]);
    try std.testing.expectEqual(@as(i32, 25), loaded.ammo[1]);
    try std.testing.expectEqual(@as(i32, 42), loaded.kill_count);
}

test "door save/load roundtrip" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    const door = VerticalDoor{
        .door_type = .blaze_raise,
        .sector_idx = 42,
        .top_height = Fixed.fromInt(128),
        .speed = Fixed.fromRaw(0x40000),
        .direction = 1,
        .top_wait = 150,
        .top_count_down = 75,
    };

    saveDoor(&buf, &door);
    buf.pos = 0;

    var loaded = VerticalDoor{};
    loadDoor(&buf, &loaded);

    try std.testing.expectEqual(doors.DoorType.blaze_raise, loaded.door_type);
    try std.testing.expectEqual(@as(u16, 42), loaded.sector_idx);
    try std.testing.expectEqual(Fixed.fromInt(128), loaded.top_height);
    try std.testing.expectEqual(@as(i32, 1), loaded.direction);
    try std.testing.expectEqual(@as(i32, 150), loaded.top_wait);
    try std.testing.expectEqual(@as(i32, 75), loaded.top_count_down);
}

test "floor mover save/load roundtrip" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    const fm = FloorMover{
        .floor_type = .raise_floor,
        .crush = true,
        .sector_idx = 7,
        .direction = 1,
        .new_special = 3,
        .texture = 5,
        .floor_dest_height = Fixed.fromInt(64),
        .speed = Fixed.fromRaw(0x10000),
    };

    saveFloor(&buf, &fm);
    buf.pos = 0;

    var loaded = FloorMover{};
    loadFloor(&buf, &loaded);

    try std.testing.expectEqual(floor_mod.FloorType.raise_floor, loaded.floor_type);
    try std.testing.expect(loaded.crush);
    try std.testing.expectEqual(@as(u16, 7), loaded.sector_idx);
    try std.testing.expectEqual(@as(i32, 1), loaded.direction);
    try std.testing.expectEqual(Fixed.fromInt(64), loaded.floor_dest_height);
}

test "light flash save/load roundtrip" {
    const allocator = std.testing.allocator;
    var buf = SaveBuffer.init(allocator) orelse return error.OutOfMemory;
    defer buf.deinit();

    const lf = LightFlash{
        .sector_idx = 10,
        .count = 35,
        .max_light = 200,
        .min_light = 100,
    };

    saveLightFlash(&buf, &lf);
    buf.pos = 0;

    var loaded = LightFlash{};
    loadLightFlash(&buf, &loaded);

    try std.testing.expectEqual(@as(u16, 10), loaded.sector_idx);
    try std.testing.expectEqual(@as(i32, 35), loaded.count);
    try std.testing.expectEqual(@as(i16, 200), loaded.max_light);
    try std.testing.expectEqual(@as(i16, 100), loaded.min_light);
}
