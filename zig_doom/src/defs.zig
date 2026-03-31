//! zig_doom/src/defs.zig
//!
//! DOOM type definitions, constants, and enums.
//! Translated from: linuxdoom-1.10/doomdef.h, doomtype.h, doomdata.h, doomstat.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const Fixed = @import("fixed.zig").Fixed;

// ============================================================================
// Game mode / mission
// ============================================================================

pub const GameMode = enum {
    shareware, // DOOM shareware (Episode 1 only)
    registered, // DOOM registered (Episodes 1-3)
    commercial, // DOOM II / Final DOOM
    retail, // Ultimate DOOM (Episodes 1-4)
    indetermined,
};

pub const GameMission = enum {
    doom, // DOOM / Ultimate DOOM
    doom2, // DOOM II: Hell on Earth
    pack_tnt, // Final DOOM: TNT Evilution
    pack_plut, // Final DOOM: The Plutonia Experiment
    none,
};

pub const Language = enum {
    english,
    french,
    german,
    unknown,
};

// ============================================================================
// Skill level
// ============================================================================

pub const Skill = enum(u8) {
    baby = 0, // I'm too young to die
    easy = 1, // Hey, not too rough
    medium = 2, // Hurt me plenty
    hard = 3, // Ultra-Violence
    nightmare = 4, // Nightmare!
};

// ============================================================================
// Key cards
// ============================================================================

pub const Card = enum(u8) {
    blue_card = 0,
    yellow_card = 1,
    red_card = 2,
    blue_skull = 3,
    yellow_skull = 4,
    red_skull = 5,
};
pub const NUMCARDS = 6;

// ============================================================================
// Weapons
// ============================================================================

pub const WeaponType = enum(u8) {
    fist = 0,
    pistol = 1,
    shotgun = 2,
    chaingun = 3,
    missile = 4, // Rocket launcher
    plasma = 5,
    bfg = 6,
    chainsaw = 7,
    super_shotgun = 8, // DOOM II only
};
pub const NUMWEAPONS = 9;

pub const AmmoType = enum(u8) {
    clip = 0, // Pistol / chaingun
    shell = 1, // Shotgun
    cell = 2, // Plasma / BFG
    missile = 3, // Rocket launcher
    no_ammo = 4, // Fist / chainsaw
};
pub const NUMAMMO = 4;

// ============================================================================
// Powers (powerups)
// ============================================================================

pub const PowerType = enum(u8) {
    invulnerability = 0,
    strength = 1, // Berserk
    invisibility = 2, // Partial invisibility
    iron_feet = 3, // Radiation suit
    all_map = 4, // Computer area map
    infrared = 5, // Light amplification visor
};
pub const NUMPOWERS = 6;

// ============================================================================
// Map data structures — these match the binary layout in WAD lumps.
// All use align(1) extern struct to match WAD's packed format.
// ============================================================================

pub const MAXPLAYERS = 4;

/// WAD vertex lump (VERTEXES)
pub const MapVertex = extern struct {
    x: i16 align(1),
    y: i16 align(1),
};

/// WAD linedef lump (LINEDEFS)
pub const MapLinedef = extern struct {
    v1: i16 align(1),
    v2: i16 align(1),
    flags: i16 align(1),
    special: i16 align(1),
    tag: i16 align(1),
    sidenum: [2]i16 align(1),
};

/// WAD sidedef lump (SIDEDEFS)
pub const MapSidedef = extern struct {
    textureoffset: i16 align(1),
    rowoffset: i16 align(1),
    toptexture: [8]u8,
    bottomtexture: [8]u8,
    midtexture: [8]u8,
    sector: i16 align(1),
};

/// WAD sector lump (SECTORS)
pub const MapSector = extern struct {
    floorheight: i16 align(1),
    ceilingheight: i16 align(1),
    floorpic: [8]u8,
    ceilingpic: [8]u8,
    lightlevel: i16 align(1),
    special: i16 align(1),
    tag: i16 align(1),
};

/// WAD seg lump (SEGS)
pub const MapSeg = extern struct {
    v1: i16 align(1),
    v2: i16 align(1),
    angle: i16 align(1),
    linedef: i16 align(1),
    side: i16 align(1),
    offset: i16 align(1),
};

/// WAD subsector lump (SSECTORS)
pub const MapSubsector = extern struct {
    numsegs: i16 align(1),
    firstseg: i16 align(1),
};

/// WAD BSP node lump (NODES)
pub const MapNode = extern struct {
    x: i16 align(1), // Partition line start
    y: i16 align(1),
    dx: i16 align(1), // Partition line direction
    dy: i16 align(1),
    bbox: [2][4]i16 align(1), // Bounding boxes [right, left][top, bottom, left, right]
    children: [2]u16 align(1), // Right and left child (bit 15 = subsector flag)
};

/// WAD thing lump (THINGS)
pub const MapThing = extern struct {
    x: i16 align(1),
    y: i16 align(1),
    angle: i16 align(1),
    thing_type: i16 align(1),
    options: i16 align(1),
};

/// WAD blockmap header
pub const BlockmapHeader = extern struct {
    originx: i16 align(1),
    originy: i16 align(1),
    columns: i16 align(1),
    rows: i16 align(1),
};

// ============================================================================
// Linedef flags
// ============================================================================

pub const ML_BLOCKING = 1; // Blocks players and monsters
pub const ML_BLOCKMONSTERS = 2; // Blocks monsters only
pub const ML_TWOSIDED = 4; // Backside will not be present
pub const ML_DONTPEGTOP = 8; // Upper texture unpegged
pub const ML_DONTPEGBOTTOM = 16; // Lower texture unpegged
pub const ML_SECRET = 32; // Secret (shows as 1-sided on automap)
pub const ML_SOUNDBLOCK = 64; // Blocks sound propagation
pub const ML_DONTDRAW = 128; // Don't draw on automap
pub const ML_MAPPED = 256; // Already on automap

// ============================================================================
// BSP node child flag
// ============================================================================

pub const NF_SUBSECTOR: u16 = 0x8000;

// ============================================================================
// Thing options flags
// ============================================================================

pub const MTF_EASY = 1;
pub const MTF_NORMAL = 2;
pub const MTF_HARD = 4;
pub const MTF_AMBUSH = 8; // Deaf monster

// ============================================================================
// Screen dimensions
// ============================================================================

pub const SCREENWIDTH = 320;
pub const SCREENHEIGHT = 200;
pub const SCREENSIZE = SCREENWIDTH * SCREENHEIGHT;

// ============================================================================
// Game state
// ============================================================================

pub const GameState = enum {
    level,
    intermission,
    finale,
    demoscreen,
};

pub const GameAction = enum {
    nothing,
    load_level,
    new_game,
    load_game,
    save_game,
    playdemo,
    completed,
    victory,
    world_done,
    screenshot,
};
