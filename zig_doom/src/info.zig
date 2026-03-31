//! zig_doom/src/info.zig
//!
//! State, sprite, and thing type definition tables.
//! Translated from: linuxdoom-1.10/info.c, info.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! This defines every object type in DOOM: animation states, sprite names,
//! and thing properties. Focus is on E1M1 shareware-essential types.

const std = @import("std");
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;

// ============================================================================
// Sprite Names — 4-char identifiers for sprite lumps
// ============================================================================

pub const SpriteNum = enum(u16) {
    SPR_TROO = 0,
    SPR_SHTG,
    SPR_PUNG,
    SPR_PISG,
    SPR_PISF,
    SPR_SHTF,
    SPR_SHT2,
    SPR_CHGG,
    SPR_CHGF,
    SPR_MISG,
    SPR_MISF,
    SPR_SAWG,
    SPR_PLSG,
    SPR_PLSF,
    SPR_BFGG,
    SPR_BFGF,
    SPR_BLUD,
    SPR_PUFF,
    SPR_BAL1,
    SPR_BAL2,
    SPR_PLSS,
    SPR_PLSE,
    SPR_MISL,
    SPR_BFS1,
    SPR_BFE1,
    SPR_BFE2,
    SPR_TFOG,
    SPR_IFOG,
    SPR_PLAY,
    SPR_POSS,
    SPR_SPOS,
    SPR_VILE,
    SPR_FIRE,
    SPR_FATB,
    SPR_FBXP,
    SPR_SKEL,
    SPR_MANF,
    SPR_FATT,
    SPR_CPOS,
    SPR_SARG,
    SPR_HEAD,
    SPR_BAL7,
    SPR_BOSS,
    SPR_BOS2,
    SPR_SKUL,
    SPR_SPID,
    SPR_BSPI,
    SPR_APLS,
    SPR_APBX,
    SPR_CYBR,
    SPR_PAIN,
    SPR_SSWV,
    SPR_KEEN,
    SPR_BBRN,
    SPR_BOSF,
    SPR_ARM1,
    SPR_ARM2,
    SPR_BAR1,
    SPR_BEXP,
    SPR_FCAN,
    SPR_BON1,
    SPR_BON2,
    SPR_BKEY,
    SPR_RKEY,
    SPR_YKEY,
    SPR_BSKU,
    SPR_RSKU,
    SPR_YSKU,
    SPR_STIM,
    SPR_MEDI,
    SPR_SOUL,
    SPR_PINV,
    SPR_PSTR,
    SPR_PINS,
    SPR_MEGA,
    SPR_SUIT,
    SPR_PMAP,
    SPR_PVIS,
    SPR_CLIP,
    SPR_AMMO,
    SPR_ROCK,
    SPR_BROK,
    SPR_CELL,
    SPR_CELP,
    SPR_SHEL,
    SPR_SBOX,
    SPR_BPAK,
    SPR_BFUG,
    SPR_MGUN,
    SPR_CSAW,
    SPR_LAUN,
    SPR_PLAS,
    SPR_SHOT,
    SPR_SGN2,
    SPR_COLU,
    SPR_SMT2,
    SPR_GOR1,
    SPR_POL2,
    SPR_POL5,
    SPR_POL4,
    SPR_POL3,
    SPR_POL1,
    SPR_POL6,
    SPR_GOR2,
    SPR_GOR3,
    SPR_GOR4,
    SPR_GOR5,
    SPR_SMIT,
    SPR_COL1,
    SPR_COL2,
    SPR_COL3,
    SPR_COL4,
    SPR_COL5,
    SPR_COL6,
    SPR_DETH,
    SPR_CEYE,
    SPR_FSKU,
    SPR_SMBT,
    SPR_SMGT,
    SPR_SMRT,
    SPR_HDB1,
    SPR_HDB2,
    SPR_HDB3,
    SPR_HDB4,
    SPR_HDB5,
    SPR_HDB6,
    SPR_TBLU,
    SPR_TGRN,
    SPR_TRED,
    NUMSPRITES,
    _,
};

// Sprite name strings for lump lookup
pub const sprnames = [_][4]u8{
    "TROO".*, "SHTG".*, "PUNG".*, "PISG".*, "PISF".*, "SHTF".*, "SHT2".*, "CHGG".*,
    "CHGF".*, "MISG".*, "MISF".*, "SAWG".*, "PLSG".*, "PLSF".*, "BFGG".*, "BFGF".*,
    "BLUD".*, "PUFF".*, "BAL1".*, "BAL2".*, "PLSS".*, "PLSE".*, "MISL".*, "BFS1".*,
    "BFE1".*, "BFE2".*, "TFOG".*, "IFOG".*, "PLAY".*, "POSS".*, "SPOS".*, "VILE".*,
    "FIRE".*, "FATB".*, "FBXP".*, "SKEL".*, "MANF".*, "FATT".*, "CPOS".*, "SARG".*,
    "HEAD".*, "BAL7".*, "BOSS".*, "BOS2".*, "SKUL".*, "SPID".*, "BSPI".*, "APLS".*,
    "APBX".*, "CYBR".*, "PAIN".*, "SSWV".*, "KEEN".*, "BBRN".*, "BOSF".*, "ARM1".*,
    "ARM2".*, "BAR1".*, "BEXP".*, "FCAN".*, "BON1".*, "BON2".*, "BKEY".*, "RKEY".*,
    "YKEY".*, "BSKU".*, "RSKU".*, "YSKU".*, "STIM".*, "MEDI".*, "SOUL".*, "PINV".*,
    "PSTR".*, "PINS".*, "MEGA".*, "SUIT".*, "PMAP".*, "PVIS".*, "CLIP".*, "AMMO".*,
    "ROCK".*, "BROK".*, "CELL".*, "CELP".*, "SHEL".*, "SBOX".*, "BPAK".*, "BFUG".*,
    "MGUN".*, "CSAW".*, "LAUN".*, "PLAS".*, "SHOT".*, "SGN2".*, "COLU".*, "SMT2".*,
    "GOR1".*, "POL2".*, "POL5".*, "POL4".*, "POL3".*, "POL1".*, "POL6".*, "GOR2".*,
    "GOR3".*, "GOR4".*, "GOR5".*, "SMIT".*, "COL1".*, "COL2".*, "COL3".*, "COL4".*,
    "COL5".*, "COL6".*, "DETH".*, "CEYE".*, "FSKU".*, "SMBT".*, "SMGT".*, "SMRT".*,
    "HDB1".*, "HDB2".*, "HDB3".*, "HDB4".*, "HDB5".*, "HDB6".*, "TBLU".*, "TGRN".*,
    "TRED".*,
};

// ============================================================================
// Full-bright flag — OR'd into frame number for always-bright frames
// ============================================================================

pub const FF_FULLBRIGHT = 0x8000;
pub const FF_FRAMEMASK = 0x7FFF;

// ============================================================================
// Action function type — called when a state is entered
// ============================================================================

pub const ActionFn = *const fn (*anyopaque) void;

// ============================================================================
// State Definition
// ============================================================================

pub const State = struct {
    sprite: SpriteNum,
    frame: i32,
    tics: i32,
    action: ?ActionFn,
    next_state: StateNum,
};

// ============================================================================
// State Numbers — indices into the states table
// ============================================================================

pub const StateNum = enum(u16) {
    S_NULL = 0,
    // Light states (for weapon flashes)
    S_LIGHTDONE,
    // Fist
    S_PUNCH, S_PUNCHDOWN, S_PUNCHUP, S_PUNCH1, S_PUNCH2, S_PUNCH3, S_PUNCH4, S_PUNCH5,
    // Pistol
    S_PISTOL, S_PISTOLDOWN, S_PISTOLUP, S_PISTOL1, S_PISTOL2, S_PISTOL3, S_PISTOL4,
    S_PISTOLFLASH,
    // Shotgun
    S_SGUN, S_SGUNDOWN, S_SGUNUP, S_SGUN1, S_SGUN2, S_SGUN3, S_SGUN4, S_SGUN5,
    S_SGUN6, S_SGUN7, S_SGUN8, S_SGUN9, S_SGUNFLASH1, S_SGUNFLASH2,
    // Chaingun
    S_CHAIN, S_CHAINDOWN, S_CHAINUP, S_CHAIN1, S_CHAIN2, S_CHAIN3,
    S_CHAINFLASH1, S_CHAINFLASH2,
    // Missile (rocket launcher)
    S_MISSILE, S_MISSILEDOWN, S_MISSILEUP, S_MISSILE1, S_MISSILE2, S_MISSILE3,
    S_MISSILEFLASH1, S_MISSILEFLASH2, S_MISSILEFLASH3, S_MISSILEFLASH4,
    // Chainsaw
    S_SAW, S_SAWB, S_SAWDOWN, S_SAWUP, S_SAW1, S_SAW2, S_SAW3,
    // Plasma
    S_PLASMA, S_PLASMADOWN, S_PLASMAUP, S_PLASMA1, S_PLASMA2, S_PLASMAFLASH1, S_PLASMAFLASH2,
    // BFG
    S_BFG, S_BFGDOWN, S_BFGUP, S_BFG1, S_BFG2, S_BFG3, S_BFG4, S_BFGFLASH1, S_BFGFLASH2,
    // Blood
    S_BLOOD1, S_BLOOD2, S_BLOOD3,
    // Puff
    S_PUFF1, S_PUFF2, S_PUFF3, S_PUFF4,
    // Imp fireball (BAL1)
    S_TBALL1, S_TBALL2, S_TBALLX1, S_TBALLX2, S_TBALLX3,
    // Cacodemon fireball (BAL2)
    S_RBALL1, S_RBALL2, S_RBALLX1, S_RBALLX2, S_RBALLX3,
    // Plasma bolt
    S_PLASBALL, S_PLASBALL2, S_PLASEXP, S_PLASEXP2, S_PLASEXP3, S_PLASEXP4, S_PLASEXP5,
    // Rocket projectile
    S_ROCKET, S_BFGSHOT, S_BFGSHOT2,
    // BFG explosion
    S_BFGLAND, S_BFGLAND2, S_BFGLAND3, S_BFGLAND4, S_BFGLAND5, S_BFGLAND6,
    // Rocket explosion
    S_EXPLODE1, S_EXPLODE2, S_EXPLODE3,
    // Teleport fog
    S_TFOG, S_TFOG01, S_TFOG02, S_TFOG2, S_TFOG3, S_TFOG4, S_TFOG5, S_TFOG6,
    S_TFOG7, S_TFOG8, S_TFOG9, S_TFOG10,
    // Item fog
    S_IFOG, S_IFOG01, S_IFOG02, S_IFOG2, S_IFOG3, S_IFOG4, S_IFOG5,
    // Player
    S_PLAY, S_PLAY_RUN1, S_PLAY_RUN2, S_PLAY_RUN3, S_PLAY_RUN4,
    S_PLAY_ATK1, S_PLAY_ATK2,
    S_PLAY_PAIN, S_PLAY_PAIN2,
    S_PLAY_DIE1, S_PLAY_DIE2, S_PLAY_DIE3, S_PLAY_DIE4, S_PLAY_DIE5, S_PLAY_DIE6, S_PLAY_DIE7,
    S_PLAY_XDIE1, S_PLAY_XDIE2, S_PLAY_XDIE3, S_PLAY_XDIE4, S_PLAY_XDIE5, S_PLAY_XDIE6,
    S_PLAY_XDIE7, S_PLAY_XDIE8, S_PLAY_XDIE9,
    // Zombieman (POSS)
    S_POSS_STND, S_POSS_STND2,
    S_POSS_RUN1, S_POSS_RUN2, S_POSS_RUN3, S_POSS_RUN4, S_POSS_RUN5, S_POSS_RUN6,
    S_POSS_RUN7, S_POSS_RUN8,
    S_POSS_ATK1, S_POSS_ATK2, S_POSS_ATK3,
    S_POSS_PAIN, S_POSS_PAIN2,
    S_POSS_DIE1, S_POSS_DIE2, S_POSS_DIE3, S_POSS_DIE4, S_POSS_DIE5,
    S_POSS_XDIE1, S_POSS_XDIE2, S_POSS_XDIE3, S_POSS_XDIE4, S_POSS_XDIE5,
    S_POSS_XDIE6, S_POSS_XDIE7, S_POSS_XDIE8, S_POSS_XDIE9,
    S_POSS_RAISE1, S_POSS_RAISE2, S_POSS_RAISE3, S_POSS_RAISE4,
    // Shotgun guy (SPOS)
    S_SPOS_STND, S_SPOS_STND2,
    S_SPOS_RUN1, S_SPOS_RUN2, S_SPOS_RUN3, S_SPOS_RUN4, S_SPOS_RUN5, S_SPOS_RUN6,
    S_SPOS_RUN7, S_SPOS_RUN8,
    S_SPOS_ATK1, S_SPOS_ATK2, S_SPOS_ATK3,
    S_SPOS_PAIN, S_SPOS_PAIN2,
    S_SPOS_DIE1, S_SPOS_DIE2, S_SPOS_DIE3, S_SPOS_DIE4, S_SPOS_DIE5,
    S_SPOS_XDIE1, S_SPOS_XDIE2, S_SPOS_XDIE3, S_SPOS_XDIE4, S_SPOS_XDIE5,
    S_SPOS_XDIE6, S_SPOS_XDIE7, S_SPOS_XDIE8, S_SPOS_XDIE9,
    S_SPOS_RAISE1, S_SPOS_RAISE2, S_SPOS_RAISE3, S_SPOS_RAISE4, S_SPOS_RAISE5,
    // Imp (TROO)
    S_TROO_STND, S_TROO_STND2,
    S_TROO_RUN1, S_TROO_RUN2, S_TROO_RUN3, S_TROO_RUN4, S_TROO_RUN5, S_TROO_RUN6,
    S_TROO_RUN7, S_TROO_RUN8,
    S_TROO_ATK1, S_TROO_ATK2, S_TROO_ATK3,
    S_TROO_PAIN, S_TROO_PAIN2,
    S_TROO_DIE1, S_TROO_DIE2, S_TROO_DIE3, S_TROO_DIE4, S_TROO_DIE5,
    S_TROO_XDIE1, S_TROO_XDIE2, S_TROO_XDIE3, S_TROO_XDIE4, S_TROO_XDIE5,
    S_TROO_XDIE6, S_TROO_XDIE7, S_TROO_XDIE8,
    S_TROO_RAISE1, S_TROO_RAISE2, S_TROO_RAISE3, S_TROO_RAISE4, S_TROO_RAISE5,
    // Demon (SARG)
    S_SARG_STND, S_SARG_STND2,
    S_SARG_RUN1, S_SARG_RUN2, S_SARG_RUN3, S_SARG_RUN4, S_SARG_RUN5, S_SARG_RUN6,
    S_SARG_RUN7, S_SARG_RUN8,
    S_SARG_ATK1, S_SARG_ATK2, S_SARG_ATK3,
    S_SARG_PAIN, S_SARG_PAIN2,
    S_SARG_DIE1, S_SARG_DIE2, S_SARG_DIE3, S_SARG_DIE4, S_SARG_DIE5, S_SARG_DIE6,
    S_SARG_RAISE1, S_SARG_RAISE2, S_SARG_RAISE3, S_SARG_RAISE4, S_SARG_RAISE5, S_SARG_RAISE6,
    // Cacodemon (HEAD)
    S_HEAD_STND,
    S_HEAD_RUN1,
    S_HEAD_ATK1, S_HEAD_ATK2, S_HEAD_ATK3,
    S_HEAD_PAIN, S_HEAD_PAIN2, S_HEAD_PAIN3,
    S_HEAD_DIE1, S_HEAD_DIE2, S_HEAD_DIE3, S_HEAD_DIE4, S_HEAD_DIE5, S_HEAD_DIE6,
    S_HEAD_RAISE1, S_HEAD_RAISE2, S_HEAD_RAISE3, S_HEAD_RAISE4, S_HEAD_RAISE5, S_HEAD_RAISE6,
    // Baron of Hell (BOSS)
    S_BOSS_STND, S_BOSS_STND2,
    S_BOSS_RUN1, S_BOSS_RUN2, S_BOSS_RUN3, S_BOSS_RUN4, S_BOSS_RUN5, S_BOSS_RUN6,
    S_BOSS_RUN7, S_BOSS_RUN8,
    S_BOSS_ATK1, S_BOSS_ATK2, S_BOSS_ATK3,
    S_BOSS_PAIN, S_BOSS_PAIN2,
    S_BOSS_DIE1, S_BOSS_DIE2, S_BOSS_DIE3, S_BOSS_DIE4, S_BOSS_DIE5, S_BOSS_DIE6, S_BOSS_DIE7,
    S_BOSS_RAISE1, S_BOSS_RAISE2, S_BOSS_RAISE3, S_BOSS_RAISE4, S_BOSS_RAISE5,
    S_BOSS_RAISE6, S_BOSS_RAISE7,
    // Hell Knight (BOS2) — same states as baron with different sprite
    S_BOS2_STND, S_BOS2_STND2,
    S_BOS2_RUN1, S_BOS2_RUN2, S_BOS2_RUN3, S_BOS2_RUN4, S_BOS2_RUN5, S_BOS2_RUN6,
    S_BOS2_RUN7, S_BOS2_RUN8,
    S_BOS2_ATK1, S_BOS2_ATK2, S_BOS2_ATK3,
    S_BOS2_PAIN, S_BOS2_PAIN2,
    S_BOS2_DIE1, S_BOS2_DIE2, S_BOS2_DIE3, S_BOS2_DIE4, S_BOS2_DIE5, S_BOS2_DIE6, S_BOS2_DIE7,
    S_BOS2_RAISE1, S_BOS2_RAISE2, S_BOS2_RAISE3, S_BOS2_RAISE4, S_BOS2_RAISE5,
    S_BOS2_RAISE6, S_BOS2_RAISE7,
    // Lost Soul (SKUL)
    S_SKULL_STND, S_SKULL_STND2,
    S_SKULL_RUN1, S_SKULL_RUN2,
    S_SKULL_ATK1, S_SKULL_ATK2, S_SKULL_ATK3, S_SKULL_ATK4,
    S_SKULL_PAIN, S_SKULL_PAIN2,
    S_SKULL_DIE1, S_SKULL_DIE2, S_SKULL_DIE3, S_SKULL_DIE4, S_SKULL_DIE5, S_SKULL_DIE6,
    // Baron/Knight fireball (BAL7)
    S_BRBALL1, S_BRBALL2, S_BRBALLX1, S_BRBALLX2, S_BRBALLX3,
    // Barrel (BAR1)
    S_BAR1, S_BAR2, S_BEXP, S_BEXP2, S_BEXP3, S_BEXP4, S_BEXP5,
    // Pickup items
    S_ARM1, S_ARM1A, S_ARM2, S_ARM2A,
    S_BON1, S_BON1A, S_BON1B, S_BON1C, S_BON1D, S_BON1E,
    S_BON2, S_BON2A, S_BON2B, S_BON2C, S_BON2D, S_BON2E,
    S_BKEY, S_BKEY2, S_RKEY, S_RKEY2, S_YKEY, S_YKEY2,
    S_BSKULL, S_BSKULL2, S_RSKULL, S_RSKULL2, S_YSKULL, S_YSKULL2,
    S_STIM, S_MEDI,
    S_SOUL, S_SOUL2, S_SOUL3, S_SOUL4, S_SOUL5, S_SOUL6,
    S_PINV, S_PINV2, S_PINV3, S_PINV4,
    S_PSTR,
    S_PINS, S_PINS2, S_PINS3, S_PINS4,
    S_MEGA, S_MEGA2, S_MEGA3, S_MEGA4,
    S_SUIT,
    S_PMAP, S_PMAP2, S_PMAP3, S_PMAP4, S_PMAP5, S_PMAP6,
    S_PVIS, S_PVIS2,
    // Ammo
    S_CLIP, S_AMMO, S_ROCK, S_BROK, S_CELL, S_CELP, S_SHEL, S_SBOX, S_BPAK,
    // Weapon pickups
    S_BFUG, S_MGUN, S_CSAW, S_LAUN, S_PLAS, S_SHOT, S_SGN2,
    // Decorations
    S_COLU, S_SMT2, S_POL2, S_POL5, S_POL4, S_POL3, S_POL1,
    S_POL6, S_GOR1, S_GOR2, S_GOR3, S_GOR4, S_GOR5,
    // Cyberdemon (placeholder states)
    S_CYBER_STND, S_CYBER_STND2,
    S_CYBER_RUN1, S_CYBER_RUN2, S_CYBER_RUN3, S_CYBER_RUN4,
    S_CYBER_RUN5, S_CYBER_RUN6, S_CYBER_RUN7, S_CYBER_RUN8,
    S_CYBER_ATK1, S_CYBER_ATK2, S_CYBER_ATK3, S_CYBER_ATK4, S_CYBER_ATK5, S_CYBER_ATK6,
    S_CYBER_PAIN,
    S_CYBER_DIE1, S_CYBER_DIE2, S_CYBER_DIE3, S_CYBER_DIE4, S_CYBER_DIE5,
    S_CYBER_DIE6, S_CYBER_DIE7, S_CYBER_DIE8, S_CYBER_DIE9, S_CYBER_DIE10,
    // Spider Mastermind (placeholder)
    S_SPID_STND, S_SPID_STND2,
    S_SPID_RUN1, S_SPID_RUN2, S_SPID_RUN3, S_SPID_RUN4,
    S_SPID_RUN5, S_SPID_RUN6, S_SPID_RUN7, S_SPID_RUN8,
    S_SPID_RUN9, S_SPID_RUN10, S_SPID_RUN11, S_SPID_RUN12,
    S_SPID_ATK1, S_SPID_ATK2, S_SPID_ATK3, S_SPID_ATK4,
    S_SPID_PAIN, S_SPID_PAIN2,
    S_SPID_DIE1, S_SPID_DIE2, S_SPID_DIE3, S_SPID_DIE4, S_SPID_DIE5,
    S_SPID_DIE6, S_SPID_DIE7, S_SPID_DIE8, S_SPID_DIE9, S_SPID_DIE10, S_SPID_DIE11,
    // Teleport destination
    S_TELEPORT,
    NUMSTATES,
    _,
};

// ============================================================================
// MobjType — indices into mobjinfo table
// ============================================================================

pub const MobjType = enum(u16) {
    MT_PLAYER = 0,
    MT_POSSESSED,
    MT_SHOTGUY,
    MT_VILE,
    MT_FIRE,
    MT_UNDEAD,
    MT_TRACER,
    MT_SMOKE,
    MT_FATSO,
    MT_FATSHOT,
    MT_CHAINGUY,
    MT_TROOP,
    MT_SERGEANT,
    MT_SHADOWS,
    MT_HEAD,
    MT_BRUISER,
    MT_BRUISERSHOT,
    MT_KNIGHT,
    MT_SKULL,
    MT_SPIDER,
    MT_BABY,
    MT_CYBORG,
    MT_PAIN,
    MT_WOLFSS,
    MT_KEEN,
    MT_BOSSBRAIN,
    MT_BOSSSPIT,
    MT_BOSSTARGET,
    MT_TROOPSHOT,
    MT_HEADSHOT,
    MT_ROCKET,
    MT_PLASMA,
    MT_BFG,
    MT_ARACHPLAZ,
    MT_PUFF,
    MT_BLOOD,
    MT_TFOG,
    MT_IFOG,
    MT_TELEPORTMAN,
    MT_EXTRABFG,
    MT_MISC0, // green armor
    MT_MISC1, // blue armor
    MT_MISC2, // health bonus
    MT_MISC3, // armor bonus
    MT_MISC4, // blue keycard
    MT_MISC5, // red keycard
    MT_MISC6, // yellow keycard
    MT_MISC7, // yellow skull
    MT_MISC8, // red skull
    MT_MISC9, // blue skull
    MT_MISC10, // stimpack
    MT_MISC11, // medikit
    MT_MISC12, // soulsphere
    MT_INV, // invulnerability
    MT_MISC13, // berserk
    MT_INS, // invisibility
    MT_MISC14, // radiation suit
    MT_MISC15, // computer area map
    MT_MISC16, // light amp visor
    MT_MEGA, // megasphere
    MT_CLIP,
    MT_MISC17, // box of ammo
    MT_MISC18, // rocket
    MT_MISC19, // box of rockets
    MT_MISC20, // cell charge
    MT_MISC21, // cell pack
    MT_MISC22, // shells
    MT_MISC23, // box of shells
    MT_MISC24, // backpack
    MT_MISC25, // bfg
    MT_CHAINGUN,
    MT_MISC26, // chainsaw
    MT_MISC27, // rocket launcher
    MT_MISC28, // plasma rifle
    MT_MISC29, // shotgun
    MT_MISC30, // super shotgun
    MT_BARREL,
    MT_MISC31, // tall green pillar
    MT_MISC32, // short green pillar
    MT_MISC33, // tall red pillar
    MT_MISC34, // short red pillar
    MT_MISC35, // candlestick
    MT_MISC36, // candelabra
    MT_MISC37, // short green pillar w/heart
    MT_MISC38, // short red pillar w/skull
    MT_MISC39, // red pillar w/skull
    MT_MISC40, // skull on pole
    MT_MISC41, // evil eye
    MT_MISC42, // floating skull
    MT_MISC43, // torched tree
    MT_MISC44, // tall blue torch
    MT_MISC45, // tall green torch
    MT_MISC46, // tall red torch
    MT_MISC47, // short blue torch
    MT_MISC48, // short green torch
    MT_MISC49, // short red torch
    MT_MISC50, // stalagtite
    MT_MISC51, // tech pillar
    MT_MISC52, // candle
    MT_MISC53, // candelabra
    MT_MISC54, // bloody twitch
    MT_MISC55, // meat2
    MT_MISC56, // meat3
    MT_MISC57, // meat4
    MT_MISC58, // meat5
    MT_MISC59, // hanging no guts
    MT_MISC60, // hanging body
    MT_MISC61, // hanging torso open
    MT_MISC62, // hanging torso
    MT_MISC63, // hanging arms out
    MT_MISC64, // hanging leg
    MT_MISC65, // hanging no brain
    MT_MISC66, // hanging no brain2
    MT_MISC67, // hanging no brain3
    MT_MISC68, // hanging no brain4
    MT_MISC69, // hanging no brain5
    MT_MISC70, // dead player
    MT_MISC71, // dead poss
    MT_MISC72, // dead spos
    MT_MISC73, // dead troo
    MT_MISC74, // dead sarg
    MT_MISC75, // dead head
    MT_MISC76, // pool of blood
    MT_MISC77, // pool of blood2
    MT_MISC78, // pile of skulls
    NUMMOBJTYPES,
    _,
};

// ============================================================================
// MF_* Map object flags
// ============================================================================

pub const MF_SPECIAL: u32 = 0x00000001;
pub const MF_SOLID: u32 = 0x00000002;
pub const MF_SHOOTABLE: u32 = 0x00000004;
pub const MF_NOSECTOR: u32 = 0x00000008;
pub const MF_NOBLOCKMAP: u32 = 0x00000010;
pub const MF_AMBUSH: u32 = 0x00000020;
pub const MF_JUSTHIT: u32 = 0x00000040;
pub const MF_JUSTATTACKED: u32 = 0x00000080;
pub const MF_SPAWNCEILING: u32 = 0x00000100;
pub const MF_NOGRAVITY: u32 = 0x00000200;
pub const MF_DROPOFF: u32 = 0x00000400;
pub const MF_PICKUP: u32 = 0x00000800;
pub const MF_NOCLIP: u32 = 0x00001000;
pub const MF_SLIDE: u32 = 0x00002000;
pub const MF_FLOAT: u32 = 0x00004000;
pub const MF_TELEPORT: u32 = 0x00008000;
pub const MF_MISSILE: u32 = 0x00010000;
pub const MF_DROPPED: u32 = 0x00020000;
pub const MF_SHADOW: u32 = 0x00040000;
pub const MF_NOBLOOD: u32 = 0x00080000;
pub const MF_CORPSE: u32 = 0x00100000;
pub const MF_INFLOAT: u32 = 0x00200000;
pub const MF_COUNTKILL: u32 = 0x00400000;
pub const MF_COUNTITEM: u32 = 0x00800000;
pub const MF_SKULLFLY: u32 = 0x01000000;
pub const MF_NOTDMATCH: u32 = 0x02000000;
pub const MF_TRANSLATION: u32 = 0x0C000000;
pub const MF_TRANSSHIFT: u32 = 26;

// ============================================================================
// MobjInfo — static properties for each thing type
// ============================================================================

pub const MobjInfo = struct {
    doomednum: i32,
    spawn_state: StateNum,
    spawn_health: i32,
    see_state: StateNum,
    see_sound: i32,
    reaction_time: i32,
    attack_sound: i32,
    pain_state: StateNum,
    pain_chance: i32,
    pain_sound: i32,
    melee_state: StateNum,
    missile_state: StateNum,
    death_state: StateNum,
    xdeath_state: StateNum,
    death_sound: i32,
    speed: i32,
    radius: Fixed,
    height: Fixed,
    mass: i32,
    damage: i32,
    active_sound: i32,
    flags: u32,
    raise_state: StateNum,
};

// ============================================================================
// State table — all animation states
// ============================================================================

// Helper to make state definition less verbose
fn S(sprite: SpriteNum, frame: i32, tics: i32, action: ?ActionFn, next: StateNum) State {
    return .{
        .sprite = sprite,
        .frame = frame,
        .tics = tics,
        .action = action,
        .next_state = next,
    };
}

pub const states = buildStateTable();

fn buildStateTable() [@intFromEnum(StateNum.NUMSTATES)]State {
    @setEvalBranchQuota(50000);
    var tbl: [@intFromEnum(StateNum.NUMSTATES)]State = undefined;

    // Fill with null state as default
    for (&tbl) |*s| {
        s.* = S(.SPR_TROO, 0, -1, null, .S_NULL);
    }

    // S_NULL — the void
    tbl[@intFromEnum(StateNum.S_NULL)] = S(.SPR_TROO, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_LIGHTDONE)] = S(.SPR_SHTG, 4, 0, null, .S_NULL); // A_Light0 placeholder

    // ---- Fist weapon ----
    tbl[@intFromEnum(StateNum.S_PUNCH)] = S(.SPR_PUNG, 0, 1, null, .S_PUNCHDOWN);
    tbl[@intFromEnum(StateNum.S_PUNCHDOWN)] = S(.SPR_PUNG, 0, 1, null, .S_PUNCHDOWN); // A_Lower
    tbl[@intFromEnum(StateNum.S_PUNCHUP)] = S(.SPR_PUNG, 0, 1, null, .S_PUNCHUP); // A_Raise
    tbl[@intFromEnum(StateNum.S_PUNCH1)] = S(.SPR_PUNG, 1, 4, null, .S_PUNCH2);
    tbl[@intFromEnum(StateNum.S_PUNCH2)] = S(.SPR_PUNG, 2, 4, null, .S_PUNCH3); // A_Punch
    tbl[@intFromEnum(StateNum.S_PUNCH3)] = S(.SPR_PUNG, 3, 5, null, .S_PUNCH4);
    tbl[@intFromEnum(StateNum.S_PUNCH4)] = S(.SPR_PUNG, 2, 4, null, .S_PUNCH5);
    tbl[@intFromEnum(StateNum.S_PUNCH5)] = S(.SPR_PUNG, 1, 5, null, .S_PUNCH); // A_ReFire

    // ---- Pistol weapon ----
    tbl[@intFromEnum(StateNum.S_PISTOL)] = S(.SPR_PISG, 0, 1, null, .S_PISTOL); // A_WeaponReady
    tbl[@intFromEnum(StateNum.S_PISTOLDOWN)] = S(.SPR_PISG, 0, 1, null, .S_PISTOLDOWN); // A_Lower
    tbl[@intFromEnum(StateNum.S_PISTOLUP)] = S(.SPR_PISG, 0, 1, null, .S_PISTOLUP); // A_Raise
    tbl[@intFromEnum(StateNum.S_PISTOL1)] = S(.SPR_PISG, 0, 4, null, .S_PISTOL2);
    tbl[@intFromEnum(StateNum.S_PISTOL2)] = S(.SPR_PISG, 1, 6, null, .S_PISTOL3); // A_FirePistol
    tbl[@intFromEnum(StateNum.S_PISTOL3)] = S(.SPR_PISG, 2, 4, null, .S_PISTOL4);
    tbl[@intFromEnum(StateNum.S_PISTOL4)] = S(.SPR_PISG, 1, 5, null, .S_PISTOL); // A_ReFire
    tbl[@intFromEnum(StateNum.S_PISTOLFLASH)] = S(.SPR_PISF, 0 | FF_FULLBRIGHT, 7, null, .S_LIGHTDONE); // A_Light1

    // ---- Shotgun weapon ----
    tbl[@intFromEnum(StateNum.S_SGUN)] = S(.SPR_SHTG, 0, 1, null, .S_SGUN);
    tbl[@intFromEnum(StateNum.S_SGUNDOWN)] = S(.SPR_SHTG, 0, 1, null, .S_SGUNDOWN);
    tbl[@intFromEnum(StateNum.S_SGUNUP)] = S(.SPR_SHTG, 0, 1, null, .S_SGUNUP);
    tbl[@intFromEnum(StateNum.S_SGUN1)] = S(.SPR_SHTG, 0, 3, null, .S_SGUN2);
    tbl[@intFromEnum(StateNum.S_SGUN2)] = S(.SPR_SHTG, 0, 7, null, .S_SGUN3); // A_FireShotgun
    tbl[@intFromEnum(StateNum.S_SGUN3)] = S(.SPR_SHTG, 1, 5, null, .S_SGUN4);
    tbl[@intFromEnum(StateNum.S_SGUN4)] = S(.SPR_SHTG, 2, 5, null, .S_SGUN5);
    tbl[@intFromEnum(StateNum.S_SGUN5)] = S(.SPR_SHTG, 3, 4, null, .S_SGUN6);
    tbl[@intFromEnum(StateNum.S_SGUN6)] = S(.SPR_SHTG, 2, 5, null, .S_SGUN7);
    tbl[@intFromEnum(StateNum.S_SGUN7)] = S(.SPR_SHTG, 1, 5, null, .S_SGUN8);
    tbl[@intFromEnum(StateNum.S_SGUN8)] = S(.SPR_SHTG, 0, 3, null, .S_SGUN9);
    tbl[@intFromEnum(StateNum.S_SGUN9)] = S(.SPR_SHTG, 0, 7, null, .S_SGUN); // A_ReFire
    tbl[@intFromEnum(StateNum.S_SGUNFLASH1)] = S(.SPR_SHTF, 0 | FF_FULLBRIGHT, 4, null, .S_SGUNFLASH2);
    tbl[@intFromEnum(StateNum.S_SGUNFLASH2)] = S(.SPR_SHTF, 1 | FF_FULLBRIGHT, 3, null, .S_LIGHTDONE);

    // ---- Chaingun weapon ----
    tbl[@intFromEnum(StateNum.S_CHAIN)] = S(.SPR_CHGG, 0, 1, null, .S_CHAIN);
    tbl[@intFromEnum(StateNum.S_CHAINDOWN)] = S(.SPR_CHGG, 0, 1, null, .S_CHAINDOWN);
    tbl[@intFromEnum(StateNum.S_CHAINUP)] = S(.SPR_CHGG, 0, 1, null, .S_CHAINUP);
    tbl[@intFromEnum(StateNum.S_CHAIN1)] = S(.SPR_CHGG, 0, 4, null, .S_CHAIN2); // A_FireCGun
    tbl[@intFromEnum(StateNum.S_CHAIN2)] = S(.SPR_CHGG, 1, 4, null, .S_CHAIN3); // A_FireCGun
    tbl[@intFromEnum(StateNum.S_CHAIN3)] = S(.SPR_CHGG, 1, 0, null, .S_CHAIN); // A_ReFire
    tbl[@intFromEnum(StateNum.S_CHAINFLASH1)] = S(.SPR_CHGF, 0 | FF_FULLBRIGHT, 5, null, .S_LIGHTDONE);
    tbl[@intFromEnum(StateNum.S_CHAINFLASH2)] = S(.SPR_CHGF, 1 | FF_FULLBRIGHT, 5, null, .S_LIGHTDONE);

    // ---- Rocket launcher weapon ----
    tbl[@intFromEnum(StateNum.S_MISSILE)] = S(.SPR_MISG, 0, 1, null, .S_MISSILE);
    tbl[@intFromEnum(StateNum.S_MISSILEDOWN)] = S(.SPR_MISG, 0, 1, null, .S_MISSILEDOWN);
    tbl[@intFromEnum(StateNum.S_MISSILEUP)] = S(.SPR_MISG, 0, 1, null, .S_MISSILEUP);
    tbl[@intFromEnum(StateNum.S_MISSILE1)] = S(.SPR_MISG, 1, 8, null, .S_MISSILE2); // A_GunFlash
    tbl[@intFromEnum(StateNum.S_MISSILE2)] = S(.SPR_MISG, 1, 12, null, .S_MISSILE3); // A_FireMissile
    tbl[@intFromEnum(StateNum.S_MISSILE3)] = S(.SPR_MISG, 1, 0, null, .S_MISSILE); // A_ReFire
    tbl[@intFromEnum(StateNum.S_MISSILEFLASH1)] = S(.SPR_MISF, 0 | FF_FULLBRIGHT, 3, null, .S_MISSILEFLASH2);
    tbl[@intFromEnum(StateNum.S_MISSILEFLASH2)] = S(.SPR_MISF, 1 | FF_FULLBRIGHT, 4, null, .S_MISSILEFLASH3);
    tbl[@intFromEnum(StateNum.S_MISSILEFLASH3)] = S(.SPR_MISF, 2 | FF_FULLBRIGHT, 4, null, .S_MISSILEFLASH4);
    tbl[@intFromEnum(StateNum.S_MISSILEFLASH4)] = S(.SPR_MISF, 3 | FF_FULLBRIGHT, 4, null, .S_LIGHTDONE);

    // ---- Chainsaw weapon ----
    tbl[@intFromEnum(StateNum.S_SAW)] = S(.SPR_SAWG, 2, 4, null, .S_SAWB); // A_WeaponReady
    tbl[@intFromEnum(StateNum.S_SAWB)] = S(.SPR_SAWG, 3, 4, null, .S_SAW); // A_WeaponReady
    tbl[@intFromEnum(StateNum.S_SAWDOWN)] = S(.SPR_SAWG, 2, 1, null, .S_SAWDOWN);
    tbl[@intFromEnum(StateNum.S_SAWUP)] = S(.SPR_SAWG, 2, 1, null, .S_SAWUP);
    tbl[@intFromEnum(StateNum.S_SAW1)] = S(.SPR_SAWG, 0, 4, null, .S_SAW2); // A_Saw
    tbl[@intFromEnum(StateNum.S_SAW2)] = S(.SPR_SAWG, 1, 4, null, .S_SAW3); // A_Saw
    tbl[@intFromEnum(StateNum.S_SAW3)] = S(.SPR_SAWG, 1, 0, null, .S_SAW); // A_ReFire

    // ---- Plasma weapon ----
    tbl[@intFromEnum(StateNum.S_PLASMA)] = S(.SPR_PLSG, 0, 1, null, .S_PLASMA);
    tbl[@intFromEnum(StateNum.S_PLASMADOWN)] = S(.SPR_PLSG, 0, 1, null, .S_PLASMADOWN);
    tbl[@intFromEnum(StateNum.S_PLASMAUP)] = S(.SPR_PLSG, 0, 1, null, .S_PLASMAUP);
    tbl[@intFromEnum(StateNum.S_PLASMA1)] = S(.SPR_PLSG, 0, 3, null, .S_PLASMA2); // A_FirePlasma
    tbl[@intFromEnum(StateNum.S_PLASMA2)] = S(.SPR_PLSG, 1, 20, null, .S_PLASMA); // A_ReFire
    tbl[@intFromEnum(StateNum.S_PLASMAFLASH1)] = S(.SPR_PLSF, 0 | FF_FULLBRIGHT, 4, null, .S_LIGHTDONE);
    tbl[@intFromEnum(StateNum.S_PLASMAFLASH2)] = S(.SPR_PLSF, 1 | FF_FULLBRIGHT, 4, null, .S_LIGHTDONE);

    // ---- BFG weapon ----
    tbl[@intFromEnum(StateNum.S_BFG)] = S(.SPR_BFGG, 0, 1, null, .S_BFG);
    tbl[@intFromEnum(StateNum.S_BFGDOWN)] = S(.SPR_BFGG, 0, 1, null, .S_BFGDOWN);
    tbl[@intFromEnum(StateNum.S_BFGUP)] = S(.SPR_BFGG, 0, 1, null, .S_BFGUP);
    tbl[@intFromEnum(StateNum.S_BFG1)] = S(.SPR_BFGG, 0, 20, null, .S_BFG2); // A_BFGsound
    tbl[@intFromEnum(StateNum.S_BFG2)] = S(.SPR_BFGG, 1, 10, null, .S_BFG3); // A_GunFlash
    tbl[@intFromEnum(StateNum.S_BFG3)] = S(.SPR_BFGG, 1, 10, null, .S_BFG4); // A_FireBFG
    tbl[@intFromEnum(StateNum.S_BFG4)] = S(.SPR_BFGG, 1, 20, null, .S_BFG); // A_ReFire
    tbl[@intFromEnum(StateNum.S_BFGFLASH1)] = S(.SPR_BFGF, 0 | FF_FULLBRIGHT, 11, null, .S_BFGFLASH2);
    tbl[@intFromEnum(StateNum.S_BFGFLASH2)] = S(.SPR_BFGF, 1 | FF_FULLBRIGHT, 6, null, .S_LIGHTDONE);

    // ---- Blood ----
    tbl[@intFromEnum(StateNum.S_BLOOD1)] = S(.SPR_BLUD, 2, 8, null, .S_BLOOD2);
    tbl[@intFromEnum(StateNum.S_BLOOD2)] = S(.SPR_BLUD, 1, 8, null, .S_BLOOD3);
    tbl[@intFromEnum(StateNum.S_BLOOD3)] = S(.SPR_BLUD, 0, 8, null, .S_NULL);

    // ---- Bullet puff ----
    tbl[@intFromEnum(StateNum.S_PUFF1)] = S(.SPR_PUFF, 0 | FF_FULLBRIGHT, 4, null, .S_PUFF2);
    tbl[@intFromEnum(StateNum.S_PUFF2)] = S(.SPR_PUFF, 1, 4, null, .S_PUFF3);
    tbl[@intFromEnum(StateNum.S_PUFF3)] = S(.SPR_PUFF, 2, 4, null, .S_PUFF4);
    tbl[@intFromEnum(StateNum.S_PUFF4)] = S(.SPR_PUFF, 3, 4, null, .S_NULL);

    // ---- Imp fireball (BAL1) ----
    tbl[@intFromEnum(StateNum.S_TBALL1)] = S(.SPR_BAL1, 0 | FF_FULLBRIGHT, 4, null, .S_TBALL2);
    tbl[@intFromEnum(StateNum.S_TBALL2)] = S(.SPR_BAL1, 1 | FF_FULLBRIGHT, 4, null, .S_TBALL1);
    tbl[@intFromEnum(StateNum.S_TBALLX1)] = S(.SPR_BAL1, 2 | FF_FULLBRIGHT, 6, null, .S_TBALLX2);
    tbl[@intFromEnum(StateNum.S_TBALLX2)] = S(.SPR_BAL1, 3 | FF_FULLBRIGHT, 6, null, .S_TBALLX3);
    tbl[@intFromEnum(StateNum.S_TBALLX3)] = S(.SPR_BAL1, 4 | FF_FULLBRIGHT, 6, null, .S_NULL);

    // ---- Cacodemon fireball (BAL2) ----
    tbl[@intFromEnum(StateNum.S_RBALL1)] = S(.SPR_BAL2, 0 | FF_FULLBRIGHT, 4, null, .S_RBALL2);
    tbl[@intFromEnum(StateNum.S_RBALL2)] = S(.SPR_BAL2, 1 | FF_FULLBRIGHT, 4, null, .S_RBALL1);
    tbl[@intFromEnum(StateNum.S_RBALLX1)] = S(.SPR_BAL2, 2 | FF_FULLBRIGHT, 6, null, .S_RBALLX2);
    tbl[@intFromEnum(StateNum.S_RBALLX2)] = S(.SPR_BAL2, 3 | FF_FULLBRIGHT, 6, null, .S_RBALLX3);
    tbl[@intFromEnum(StateNum.S_RBALLX3)] = S(.SPR_BAL2, 4 | FF_FULLBRIGHT, 6, null, .S_NULL);

    // ---- Plasma bolt ----
    tbl[@intFromEnum(StateNum.S_PLASBALL)] = S(.SPR_PLSS, 0 | FF_FULLBRIGHT, 6, null, .S_PLASBALL2);
    tbl[@intFromEnum(StateNum.S_PLASBALL2)] = S(.SPR_PLSS, 1 | FF_FULLBRIGHT, 6, null, .S_PLASBALL);
    tbl[@intFromEnum(StateNum.S_PLASEXP)] = S(.SPR_PLSE, 0 | FF_FULLBRIGHT, 4, null, .S_PLASEXP2);
    tbl[@intFromEnum(StateNum.S_PLASEXP2)] = S(.SPR_PLSE, 1 | FF_FULLBRIGHT, 4, null, .S_PLASEXP3);
    tbl[@intFromEnum(StateNum.S_PLASEXP3)] = S(.SPR_PLSE, 2 | FF_FULLBRIGHT, 4, null, .S_PLASEXP4);
    tbl[@intFromEnum(StateNum.S_PLASEXP4)] = S(.SPR_PLSE, 3 | FF_FULLBRIGHT, 4, null, .S_PLASEXP5);
    tbl[@intFromEnum(StateNum.S_PLASEXP5)] = S(.SPR_PLSE, 4 | FF_FULLBRIGHT, 4, null, .S_NULL);

    // ---- Rocket projectile ----
    tbl[@intFromEnum(StateNum.S_ROCKET)] = S(.SPR_MISL, 0 | FF_FULLBRIGHT, 1, null, .S_ROCKET);
    tbl[@intFromEnum(StateNum.S_BFGSHOT)] = S(.SPR_BFS1, 0 | FF_FULLBRIGHT, 4, null, .S_BFGSHOT2);
    tbl[@intFromEnum(StateNum.S_BFGSHOT2)] = S(.SPR_BFS1, 1 | FF_FULLBRIGHT, 4, null, .S_BFGSHOT);

    // ---- BFG explosion ----
    tbl[@intFromEnum(StateNum.S_BFGLAND)] = S(.SPR_BFE1, 0 | FF_FULLBRIGHT, 8, null, .S_BFGLAND2);
    tbl[@intFromEnum(StateNum.S_BFGLAND2)] = S(.SPR_BFE1, 1 | FF_FULLBRIGHT, 8, null, .S_BFGLAND3);
    tbl[@intFromEnum(StateNum.S_BFGLAND3)] = S(.SPR_BFE1, 2 | FF_FULLBRIGHT, 8, null, .S_BFGLAND4); // A_BFGSpray
    tbl[@intFromEnum(StateNum.S_BFGLAND4)] = S(.SPR_BFE1, 3 | FF_FULLBRIGHT, 8, null, .S_BFGLAND5);
    tbl[@intFromEnum(StateNum.S_BFGLAND5)] = S(.SPR_BFE1, 4 | FF_FULLBRIGHT, 8, null, .S_BFGLAND6);
    tbl[@intFromEnum(StateNum.S_BFGLAND6)] = S(.SPR_BFE1, 5 | FF_FULLBRIGHT, 8, null, .S_NULL);

    // ---- Rocket explosion ----
    tbl[@intFromEnum(StateNum.S_EXPLODE1)] = S(.SPR_MISL, 1 | FF_FULLBRIGHT, 8, null, .S_EXPLODE2);
    tbl[@intFromEnum(StateNum.S_EXPLODE2)] = S(.SPR_MISL, 2 | FF_FULLBRIGHT, 6, null, .S_EXPLODE3);
    tbl[@intFromEnum(StateNum.S_EXPLODE3)] = S(.SPR_MISL, 3 | FF_FULLBRIGHT, 4, null, .S_NULL);

    // ---- Teleport fog ----
    tbl[@intFromEnum(StateNum.S_TFOG)] = S(.SPR_TFOG, 0 | FF_FULLBRIGHT, 6, null, .S_TFOG01);
    tbl[@intFromEnum(StateNum.S_TFOG01)] = S(.SPR_TFOG, 1 | FF_FULLBRIGHT, 6, null, .S_TFOG02);
    tbl[@intFromEnum(StateNum.S_TFOG02)] = S(.SPR_TFOG, 0 | FF_FULLBRIGHT, 6, null, .S_TFOG2);
    tbl[@intFromEnum(StateNum.S_TFOG2)] = S(.SPR_TFOG, 1 | FF_FULLBRIGHT, 6, null, .S_TFOG3);
    tbl[@intFromEnum(StateNum.S_TFOG3)] = S(.SPR_TFOG, 2 | FF_FULLBRIGHT, 6, null, .S_TFOG4);
    tbl[@intFromEnum(StateNum.S_TFOG4)] = S(.SPR_TFOG, 3 | FF_FULLBRIGHT, 6, null, .S_TFOG5);
    tbl[@intFromEnum(StateNum.S_TFOG5)] = S(.SPR_TFOG, 4 | FF_FULLBRIGHT, 6, null, .S_TFOG6);
    tbl[@intFromEnum(StateNum.S_TFOG6)] = S(.SPR_TFOG, 5 | FF_FULLBRIGHT, 6, null, .S_TFOG7);
    tbl[@intFromEnum(StateNum.S_TFOG7)] = S(.SPR_TFOG, 6 | FF_FULLBRIGHT, 6, null, .S_TFOG8);
    tbl[@intFromEnum(StateNum.S_TFOG8)] = S(.SPR_TFOG, 7 | FF_FULLBRIGHT, 6, null, .S_TFOG9);
    tbl[@intFromEnum(StateNum.S_TFOG9)] = S(.SPR_TFOG, 8 | FF_FULLBRIGHT, 6, null, .S_TFOG10);
    tbl[@intFromEnum(StateNum.S_TFOG10)] = S(.SPR_TFOG, 9 | FF_FULLBRIGHT, 6, null, .S_NULL);

    // ---- Item fog ----
    tbl[@intFromEnum(StateNum.S_IFOG)] = S(.SPR_IFOG, 0 | FF_FULLBRIGHT, 6, null, .S_IFOG01);
    tbl[@intFromEnum(StateNum.S_IFOG01)] = S(.SPR_IFOG, 1 | FF_FULLBRIGHT, 6, null, .S_IFOG02);
    tbl[@intFromEnum(StateNum.S_IFOG02)] = S(.SPR_IFOG, 0 | FF_FULLBRIGHT, 6, null, .S_IFOG2);
    tbl[@intFromEnum(StateNum.S_IFOG2)] = S(.SPR_IFOG, 1 | FF_FULLBRIGHT, 6, null, .S_IFOG3);
    tbl[@intFromEnum(StateNum.S_IFOG3)] = S(.SPR_IFOG, 2 | FF_FULLBRIGHT, 6, null, .S_IFOG4);
    tbl[@intFromEnum(StateNum.S_IFOG4)] = S(.SPR_IFOG, 3 | FF_FULLBRIGHT, 6, null, .S_IFOG5);
    tbl[@intFromEnum(StateNum.S_IFOG5)] = S(.SPR_IFOG, 4 | FF_FULLBRIGHT, 6, null, .S_NULL);

    // ---- Player (PLAY) ----
    tbl[@intFromEnum(StateNum.S_PLAY)] = S(.SPR_PLAY, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_PLAY_RUN1)] = S(.SPR_PLAY, 0, 4, null, .S_PLAY_RUN2);
    tbl[@intFromEnum(StateNum.S_PLAY_RUN2)] = S(.SPR_PLAY, 1, 4, null, .S_PLAY_RUN3);
    tbl[@intFromEnum(StateNum.S_PLAY_RUN3)] = S(.SPR_PLAY, 2, 4, null, .S_PLAY_RUN4);
    tbl[@intFromEnum(StateNum.S_PLAY_RUN4)] = S(.SPR_PLAY, 3, 4, null, .S_PLAY_RUN1);
    tbl[@intFromEnum(StateNum.S_PLAY_ATK1)] = S(.SPR_PLAY, 4, 12, null, .S_PLAY);
    tbl[@intFromEnum(StateNum.S_PLAY_ATK2)] = S(.SPR_PLAY, 5 | FF_FULLBRIGHT, 6, null, .S_PLAY_ATK1);
    tbl[@intFromEnum(StateNum.S_PLAY_PAIN)] = S(.SPR_PLAY, 6, 4, null, .S_PLAY_PAIN2);
    tbl[@intFromEnum(StateNum.S_PLAY_PAIN2)] = S(.SPR_PLAY, 6, 4, null, .S_PLAY); // A_Pain
    tbl[@intFromEnum(StateNum.S_PLAY_DIE1)] = S(.SPR_PLAY, 7, 10, null, .S_PLAY_DIE2);
    tbl[@intFromEnum(StateNum.S_PLAY_DIE2)] = S(.SPR_PLAY, 8, 10, null, .S_PLAY_DIE3); // A_PlayerScream
    tbl[@intFromEnum(StateNum.S_PLAY_DIE3)] = S(.SPR_PLAY, 9, 10, null, .S_PLAY_DIE4); // A_Fall
    tbl[@intFromEnum(StateNum.S_PLAY_DIE4)] = S(.SPR_PLAY, 10, 10, null, .S_PLAY_DIE5);
    tbl[@intFromEnum(StateNum.S_PLAY_DIE5)] = S(.SPR_PLAY, 11, 10, null, .S_PLAY_DIE6);
    tbl[@intFromEnum(StateNum.S_PLAY_DIE6)] = S(.SPR_PLAY, 12, 10, null, .S_PLAY_DIE7);
    tbl[@intFromEnum(StateNum.S_PLAY_DIE7)] = S(.SPR_PLAY, 13, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE1)] = S(.SPR_PLAY, 14, 5, null, .S_PLAY_XDIE2);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE2)] = S(.SPR_PLAY, 15, 5, null, .S_PLAY_XDIE3); // A_XScream
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE3)] = S(.SPR_PLAY, 16, 5, null, .S_PLAY_XDIE4); // A_Fall
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE4)] = S(.SPR_PLAY, 17, 5, null, .S_PLAY_XDIE5);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE5)] = S(.SPR_PLAY, 18, 5, null, .S_PLAY_XDIE6);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE6)] = S(.SPR_PLAY, 19, 5, null, .S_PLAY_XDIE7);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE7)] = S(.SPR_PLAY, 20, 5, null, .S_PLAY_XDIE8);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE8)] = S(.SPR_PLAY, 21, 5, null, .S_PLAY_XDIE9);
    tbl[@intFromEnum(StateNum.S_PLAY_XDIE9)] = S(.SPR_PLAY, 22, -1, null, .S_NULL);

    // ---- Zombieman (POSS) ----
    tbl[@intFromEnum(StateNum.S_POSS_STND)] = S(.SPR_POSS, 0, 10, null, .S_POSS_STND2); // A_Look
    tbl[@intFromEnum(StateNum.S_POSS_STND2)] = S(.SPR_POSS, 1, 10, null, .S_POSS_STND); // A_Look
    tbl[@intFromEnum(StateNum.S_POSS_RUN1)] = S(.SPR_POSS, 0, 4, null, .S_POSS_RUN2); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN2)] = S(.SPR_POSS, 0, 4, null, .S_POSS_RUN3); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN3)] = S(.SPR_POSS, 1, 4, null, .S_POSS_RUN4); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN4)] = S(.SPR_POSS, 1, 4, null, .S_POSS_RUN5); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN5)] = S(.SPR_POSS, 2, 4, null, .S_POSS_RUN6); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN6)] = S(.SPR_POSS, 2, 4, null, .S_POSS_RUN7); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN7)] = S(.SPR_POSS, 3, 4, null, .S_POSS_RUN8); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_RUN8)] = S(.SPR_POSS, 3, 4, null, .S_POSS_RUN1); // A_Chase
    tbl[@intFromEnum(StateNum.S_POSS_ATK1)] = S(.SPR_POSS, 4, 10, null, .S_POSS_ATK2); // A_FaceTarget
    tbl[@intFromEnum(StateNum.S_POSS_ATK2)] = S(.SPR_POSS, 5, 8, null, .S_POSS_ATK3); // A_PosAttack
    tbl[@intFromEnum(StateNum.S_POSS_ATK3)] = S(.SPR_POSS, 4, 8, null, .S_POSS_RUN1);
    tbl[@intFromEnum(StateNum.S_POSS_PAIN)] = S(.SPR_POSS, 6, 3, null, .S_POSS_PAIN2);
    tbl[@intFromEnum(StateNum.S_POSS_PAIN2)] = S(.SPR_POSS, 6, 3, null, .S_POSS_RUN1); // A_Pain
    tbl[@intFromEnum(StateNum.S_POSS_DIE1)] = S(.SPR_POSS, 7, 5, null, .S_POSS_DIE2);
    tbl[@intFromEnum(StateNum.S_POSS_DIE2)] = S(.SPR_POSS, 8, 5, null, .S_POSS_DIE3); // A_Scream
    tbl[@intFromEnum(StateNum.S_POSS_DIE3)] = S(.SPR_POSS, 9, 5, null, .S_POSS_DIE4); // A_Fall
    tbl[@intFromEnum(StateNum.S_POSS_DIE4)] = S(.SPR_POSS, 10, 5, null, .S_POSS_DIE5);
    tbl[@intFromEnum(StateNum.S_POSS_DIE5)] = S(.SPR_POSS, 11, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE1)] = S(.SPR_POSS, 12, 5, null, .S_POSS_XDIE2);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE2)] = S(.SPR_POSS, 13, 5, null, .S_POSS_XDIE3); // A_XScream
    tbl[@intFromEnum(StateNum.S_POSS_XDIE3)] = S(.SPR_POSS, 14, 5, null, .S_POSS_XDIE4); // A_Fall
    tbl[@intFromEnum(StateNum.S_POSS_XDIE4)] = S(.SPR_POSS, 15, 5, null, .S_POSS_XDIE5);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE5)] = S(.SPR_POSS, 16, 5, null, .S_POSS_XDIE6);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE6)] = S(.SPR_POSS, 17, 5, null, .S_POSS_XDIE7);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE7)] = S(.SPR_POSS, 18, 5, null, .S_POSS_XDIE8);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE8)] = S(.SPR_POSS, 19, 5, null, .S_POSS_XDIE9);
    tbl[@intFromEnum(StateNum.S_POSS_XDIE9)] = S(.SPR_POSS, 20, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POSS_RAISE1)] = S(.SPR_POSS, 10, 5, null, .S_POSS_RAISE2);
    tbl[@intFromEnum(StateNum.S_POSS_RAISE2)] = S(.SPR_POSS, 9, 5, null, .S_POSS_RAISE3);
    tbl[@intFromEnum(StateNum.S_POSS_RAISE3)] = S(.SPR_POSS, 8, 5, null, .S_POSS_RAISE4);
    tbl[@intFromEnum(StateNum.S_POSS_RAISE4)] = S(.SPR_POSS, 7, 5, null, .S_POSS_RUN1);

    // ---- Shotgun Guy (SPOS) ----
    tbl[@intFromEnum(StateNum.S_SPOS_STND)] = S(.SPR_SPOS, 0, 10, null, .S_SPOS_STND2);
    tbl[@intFromEnum(StateNum.S_SPOS_STND2)] = S(.SPR_SPOS, 1, 10, null, .S_SPOS_STND);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN1)] = S(.SPR_SPOS, 0, 3, null, .S_SPOS_RUN2);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN2)] = S(.SPR_SPOS, 0, 3, null, .S_SPOS_RUN3);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN3)] = S(.SPR_SPOS, 1, 3, null, .S_SPOS_RUN4);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN4)] = S(.SPR_SPOS, 1, 3, null, .S_SPOS_RUN5);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN5)] = S(.SPR_SPOS, 2, 3, null, .S_SPOS_RUN6);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN6)] = S(.SPR_SPOS, 2, 3, null, .S_SPOS_RUN7);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN7)] = S(.SPR_SPOS, 3, 3, null, .S_SPOS_RUN8);
    tbl[@intFromEnum(StateNum.S_SPOS_RUN8)] = S(.SPR_SPOS, 3, 3, null, .S_SPOS_RUN1);
    tbl[@intFromEnum(StateNum.S_SPOS_ATK1)] = S(.SPR_SPOS, 4, 10, null, .S_SPOS_ATK2);
    tbl[@intFromEnum(StateNum.S_SPOS_ATK2)] = S(.SPR_SPOS, 5 | FF_FULLBRIGHT, 10, null, .S_SPOS_ATK3); // A_SPosAttack
    tbl[@intFromEnum(StateNum.S_SPOS_ATK3)] = S(.SPR_SPOS, 4, 10, null, .S_SPOS_RUN1);
    tbl[@intFromEnum(StateNum.S_SPOS_PAIN)] = S(.SPR_SPOS, 6, 3, null, .S_SPOS_PAIN2);
    tbl[@intFromEnum(StateNum.S_SPOS_PAIN2)] = S(.SPR_SPOS, 6, 3, null, .S_SPOS_RUN1);
    tbl[@intFromEnum(StateNum.S_SPOS_DIE1)] = S(.SPR_SPOS, 7, 5, null, .S_SPOS_DIE2);
    tbl[@intFromEnum(StateNum.S_SPOS_DIE2)] = S(.SPR_SPOS, 8, 5, null, .S_SPOS_DIE3); // A_Scream
    tbl[@intFromEnum(StateNum.S_SPOS_DIE3)] = S(.SPR_SPOS, 9, 5, null, .S_SPOS_DIE4); // A_Fall
    tbl[@intFromEnum(StateNum.S_SPOS_DIE4)] = S(.SPR_SPOS, 10, 5, null, .S_SPOS_DIE5);
    tbl[@intFromEnum(StateNum.S_SPOS_DIE5)] = S(.SPR_SPOS, 11, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE1)] = S(.SPR_SPOS, 12, 5, null, .S_SPOS_XDIE2);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE2)] = S(.SPR_SPOS, 13, 5, null, .S_SPOS_XDIE3);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE3)] = S(.SPR_SPOS, 14, 5, null, .S_SPOS_XDIE4);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE4)] = S(.SPR_SPOS, 15, 5, null, .S_SPOS_XDIE5);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE5)] = S(.SPR_SPOS, 16, 5, null, .S_SPOS_XDIE6);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE6)] = S(.SPR_SPOS, 17, 5, null, .S_SPOS_XDIE7);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE7)] = S(.SPR_SPOS, 18, 5, null, .S_SPOS_XDIE8);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE8)] = S(.SPR_SPOS, 19, 5, null, .S_SPOS_XDIE9);
    tbl[@intFromEnum(StateNum.S_SPOS_XDIE9)] = S(.SPR_SPOS, 20, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SPOS_RAISE1)] = S(.SPR_SPOS, 11, 5, null, .S_SPOS_RAISE2);
    tbl[@intFromEnum(StateNum.S_SPOS_RAISE2)] = S(.SPR_SPOS, 10, 5, null, .S_SPOS_RAISE3);
    tbl[@intFromEnum(StateNum.S_SPOS_RAISE3)] = S(.SPR_SPOS, 9, 5, null, .S_SPOS_RAISE4);
    tbl[@intFromEnum(StateNum.S_SPOS_RAISE4)] = S(.SPR_SPOS, 8, 5, null, .S_SPOS_RAISE5);
    tbl[@intFromEnum(StateNum.S_SPOS_RAISE5)] = S(.SPR_SPOS, 7, 5, null, .S_SPOS_RUN1);

    // ---- Imp (TROO) ----
    tbl[@intFromEnum(StateNum.S_TROO_STND)] = S(.SPR_TROO, 0, 10, null, .S_TROO_STND2);
    tbl[@intFromEnum(StateNum.S_TROO_STND2)] = S(.SPR_TROO, 1, 10, null, .S_TROO_STND);
    tbl[@intFromEnum(StateNum.S_TROO_RUN1)] = S(.SPR_TROO, 0, 3, null, .S_TROO_RUN2);
    tbl[@intFromEnum(StateNum.S_TROO_RUN2)] = S(.SPR_TROO, 0, 3, null, .S_TROO_RUN3);
    tbl[@intFromEnum(StateNum.S_TROO_RUN3)] = S(.SPR_TROO, 1, 3, null, .S_TROO_RUN4);
    tbl[@intFromEnum(StateNum.S_TROO_RUN4)] = S(.SPR_TROO, 1, 3, null, .S_TROO_RUN5);
    tbl[@intFromEnum(StateNum.S_TROO_RUN5)] = S(.SPR_TROO, 2, 3, null, .S_TROO_RUN6);
    tbl[@intFromEnum(StateNum.S_TROO_RUN6)] = S(.SPR_TROO, 2, 3, null, .S_TROO_RUN7);
    tbl[@intFromEnum(StateNum.S_TROO_RUN7)] = S(.SPR_TROO, 3, 3, null, .S_TROO_RUN8);
    tbl[@intFromEnum(StateNum.S_TROO_RUN8)] = S(.SPR_TROO, 3, 3, null, .S_TROO_RUN1);
    tbl[@intFromEnum(StateNum.S_TROO_ATK1)] = S(.SPR_TROO, 4, 8, null, .S_TROO_ATK2); // A_FaceTarget
    tbl[@intFromEnum(StateNum.S_TROO_ATK2)] = S(.SPR_TROO, 5, 8, null, .S_TROO_ATK3); // A_FaceTarget
    tbl[@intFromEnum(StateNum.S_TROO_ATK3)] = S(.SPR_TROO, 6, 6, null, .S_TROO_RUN1); // A_TroopAttack
    tbl[@intFromEnum(StateNum.S_TROO_PAIN)] = S(.SPR_TROO, 7, 2, null, .S_TROO_PAIN2);
    tbl[@intFromEnum(StateNum.S_TROO_PAIN2)] = S(.SPR_TROO, 7, 2, null, .S_TROO_RUN1);
    tbl[@intFromEnum(StateNum.S_TROO_DIE1)] = S(.SPR_TROO, 8, 8, null, .S_TROO_DIE2);
    tbl[@intFromEnum(StateNum.S_TROO_DIE2)] = S(.SPR_TROO, 9, 8, null, .S_TROO_DIE3); // A_Scream
    tbl[@intFromEnum(StateNum.S_TROO_DIE3)] = S(.SPR_TROO, 10, 6, null, .S_TROO_DIE4);
    tbl[@intFromEnum(StateNum.S_TROO_DIE4)] = S(.SPR_TROO, 11, 6, null, .S_TROO_DIE5); // A_Fall
    tbl[@intFromEnum(StateNum.S_TROO_DIE5)] = S(.SPR_TROO, 12, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE1)] = S(.SPR_TROO, 13, 5, null, .S_TROO_XDIE2);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE2)] = S(.SPR_TROO, 14, 5, null, .S_TROO_XDIE3);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE3)] = S(.SPR_TROO, 15, 5, null, .S_TROO_XDIE4);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE4)] = S(.SPR_TROO, 16, 5, null, .S_TROO_XDIE5);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE5)] = S(.SPR_TROO, 17, 5, null, .S_TROO_XDIE6);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE6)] = S(.SPR_TROO, 18, 5, null, .S_TROO_XDIE7);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE7)] = S(.SPR_TROO, 19, 5, null, .S_TROO_XDIE8);
    tbl[@intFromEnum(StateNum.S_TROO_XDIE8)] = S(.SPR_TROO, 20, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_TROO_RAISE1)] = S(.SPR_TROO, 12, 8, null, .S_TROO_RAISE2);
    tbl[@intFromEnum(StateNum.S_TROO_RAISE2)] = S(.SPR_TROO, 11, 8, null, .S_TROO_RAISE3);
    tbl[@intFromEnum(StateNum.S_TROO_RAISE3)] = S(.SPR_TROO, 10, 6, null, .S_TROO_RAISE4);
    tbl[@intFromEnum(StateNum.S_TROO_RAISE4)] = S(.SPR_TROO, 9, 6, null, .S_TROO_RAISE5);
    tbl[@intFromEnum(StateNum.S_TROO_RAISE5)] = S(.SPR_TROO, 8, 6, null, .S_TROO_RUN1);

    // ---- Demon (SARG) ----
    tbl[@intFromEnum(StateNum.S_SARG_STND)] = S(.SPR_SARG, 0, 10, null, .S_SARG_STND2);
    tbl[@intFromEnum(StateNum.S_SARG_STND2)] = S(.SPR_SARG, 1, 10, null, .S_SARG_STND);
    tbl[@intFromEnum(StateNum.S_SARG_RUN1)] = S(.SPR_SARG, 0, 2, null, .S_SARG_RUN2);
    tbl[@intFromEnum(StateNum.S_SARG_RUN2)] = S(.SPR_SARG, 0, 2, null, .S_SARG_RUN3);
    tbl[@intFromEnum(StateNum.S_SARG_RUN3)] = S(.SPR_SARG, 1, 2, null, .S_SARG_RUN4);
    tbl[@intFromEnum(StateNum.S_SARG_RUN4)] = S(.SPR_SARG, 1, 2, null, .S_SARG_RUN5);
    tbl[@intFromEnum(StateNum.S_SARG_RUN5)] = S(.SPR_SARG, 2, 2, null, .S_SARG_RUN6);
    tbl[@intFromEnum(StateNum.S_SARG_RUN6)] = S(.SPR_SARG, 2, 2, null, .S_SARG_RUN7);
    tbl[@intFromEnum(StateNum.S_SARG_RUN7)] = S(.SPR_SARG, 3, 2, null, .S_SARG_RUN8);
    tbl[@intFromEnum(StateNum.S_SARG_RUN8)] = S(.SPR_SARG, 3, 2, null, .S_SARG_RUN1);
    tbl[@intFromEnum(StateNum.S_SARG_ATK1)] = S(.SPR_SARG, 4, 8, null, .S_SARG_ATK2);
    tbl[@intFromEnum(StateNum.S_SARG_ATK2)] = S(.SPR_SARG, 5, 8, null, .S_SARG_ATK3);
    tbl[@intFromEnum(StateNum.S_SARG_ATK3)] = S(.SPR_SARG, 6, 8, null, .S_SARG_RUN1); // A_SargAttack
    tbl[@intFromEnum(StateNum.S_SARG_PAIN)] = S(.SPR_SARG, 7, 2, null, .S_SARG_PAIN2);
    tbl[@intFromEnum(StateNum.S_SARG_PAIN2)] = S(.SPR_SARG, 7, 2, null, .S_SARG_RUN1);
    tbl[@intFromEnum(StateNum.S_SARG_DIE1)] = S(.SPR_SARG, 8, 8, null, .S_SARG_DIE2);
    tbl[@intFromEnum(StateNum.S_SARG_DIE2)] = S(.SPR_SARG, 9, 8, null, .S_SARG_DIE3);
    tbl[@intFromEnum(StateNum.S_SARG_DIE3)] = S(.SPR_SARG, 10, 4, null, .S_SARG_DIE4);
    tbl[@intFromEnum(StateNum.S_SARG_DIE4)] = S(.SPR_SARG, 11, 4, null, .S_SARG_DIE5);
    tbl[@intFromEnum(StateNum.S_SARG_DIE5)] = S(.SPR_SARG, 12, 4, null, .S_SARG_DIE6);
    tbl[@intFromEnum(StateNum.S_SARG_DIE6)] = S(.SPR_SARG, 13, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE1)] = S(.SPR_SARG, 13, 5, null, .S_SARG_RAISE2);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE2)] = S(.SPR_SARG, 12, 5, null, .S_SARG_RAISE3);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE3)] = S(.SPR_SARG, 11, 5, null, .S_SARG_RAISE4);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE4)] = S(.SPR_SARG, 10, 5, null, .S_SARG_RAISE5);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE5)] = S(.SPR_SARG, 9, 5, null, .S_SARG_RAISE6);
    tbl[@intFromEnum(StateNum.S_SARG_RAISE6)] = S(.SPR_SARG, 8, 5, null, .S_SARG_RUN1);

    // ---- Cacodemon (HEAD) ----
    tbl[@intFromEnum(StateNum.S_HEAD_STND)] = S(.SPR_HEAD, 0, 10, null, .S_HEAD_STND);
    tbl[@intFromEnum(StateNum.S_HEAD_RUN1)] = S(.SPR_HEAD, 0, 3, null, .S_HEAD_RUN1);
    tbl[@intFromEnum(StateNum.S_HEAD_ATK1)] = S(.SPR_HEAD, 1, 5, null, .S_HEAD_ATK2);
    tbl[@intFromEnum(StateNum.S_HEAD_ATK2)] = S(.SPR_HEAD, 2, 5, null, .S_HEAD_ATK3);
    tbl[@intFromEnum(StateNum.S_HEAD_ATK3)] = S(.SPR_HEAD, 3 | FF_FULLBRIGHT, 5, null, .S_HEAD_RUN1); // A_HeadAttack
    tbl[@intFromEnum(StateNum.S_HEAD_PAIN)] = S(.SPR_HEAD, 4, 3, null, .S_HEAD_PAIN2);
    tbl[@intFromEnum(StateNum.S_HEAD_PAIN2)] = S(.SPR_HEAD, 4, 3, null, .S_HEAD_PAIN3);
    tbl[@intFromEnum(StateNum.S_HEAD_PAIN3)] = S(.SPR_HEAD, 4, 6, null, .S_HEAD_RUN1);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE1)] = S(.SPR_HEAD, 5, 8, null, .S_HEAD_DIE2);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE2)] = S(.SPR_HEAD, 6, 8, null, .S_HEAD_DIE3);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE3)] = S(.SPR_HEAD, 7, 8, null, .S_HEAD_DIE4);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE4)] = S(.SPR_HEAD, 8, 8, null, .S_HEAD_DIE5);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE5)] = S(.SPR_HEAD, 9, 8, null, .S_HEAD_DIE6);
    tbl[@intFromEnum(StateNum.S_HEAD_DIE6)] = S(.SPR_HEAD, 10, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE1)] = S(.SPR_HEAD, 10, 8, null, .S_HEAD_RAISE2);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE2)] = S(.SPR_HEAD, 9, 8, null, .S_HEAD_RAISE3);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE3)] = S(.SPR_HEAD, 8, 8, null, .S_HEAD_RAISE4);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE4)] = S(.SPR_HEAD, 7, 8, null, .S_HEAD_RAISE5);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE5)] = S(.SPR_HEAD, 6, 8, null, .S_HEAD_RAISE6);
    tbl[@intFromEnum(StateNum.S_HEAD_RAISE6)] = S(.SPR_HEAD, 5, 8, null, .S_HEAD_RUN1);

    // ---- Baron of Hell (BOSS) ----
    tbl[@intFromEnum(StateNum.S_BOSS_STND)] = S(.SPR_BOSS, 0, 10, null, .S_BOSS_STND2);
    tbl[@intFromEnum(StateNum.S_BOSS_STND2)] = S(.SPR_BOSS, 1, 10, null, .S_BOSS_STND);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN1)] = S(.SPR_BOSS, 0, 3, null, .S_BOSS_RUN2);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN2)] = S(.SPR_BOSS, 0, 3, null, .S_BOSS_RUN3);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN3)] = S(.SPR_BOSS, 1, 3, null, .S_BOSS_RUN4);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN4)] = S(.SPR_BOSS, 1, 3, null, .S_BOSS_RUN5);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN5)] = S(.SPR_BOSS, 2, 3, null, .S_BOSS_RUN6);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN6)] = S(.SPR_BOSS, 2, 3, null, .S_BOSS_RUN7);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN7)] = S(.SPR_BOSS, 3, 3, null, .S_BOSS_RUN8);
    tbl[@intFromEnum(StateNum.S_BOSS_RUN8)] = S(.SPR_BOSS, 3, 3, null, .S_BOSS_RUN1);
    tbl[@intFromEnum(StateNum.S_BOSS_ATK1)] = S(.SPR_BOSS, 4, 8, null, .S_BOSS_ATK2);
    tbl[@intFromEnum(StateNum.S_BOSS_ATK2)] = S(.SPR_BOSS, 5, 8, null, .S_BOSS_ATK3);
    tbl[@intFromEnum(StateNum.S_BOSS_ATK3)] = S(.SPR_BOSS, 6 | FF_FULLBRIGHT, 8, null, .S_BOSS_RUN1); // A_BruisAttack
    tbl[@intFromEnum(StateNum.S_BOSS_PAIN)] = S(.SPR_BOSS, 7, 2, null, .S_BOSS_PAIN2);
    tbl[@intFromEnum(StateNum.S_BOSS_PAIN2)] = S(.SPR_BOSS, 7, 2, null, .S_BOSS_RUN1);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE1)] = S(.SPR_BOSS, 8, 8, null, .S_BOSS_DIE2);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE2)] = S(.SPR_BOSS, 9, 8, null, .S_BOSS_DIE3);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE3)] = S(.SPR_BOSS, 10, 8, null, .S_BOSS_DIE4);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE4)] = S(.SPR_BOSS, 11, 8, null, .S_BOSS_DIE5);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE5)] = S(.SPR_BOSS, 12, 8, null, .S_BOSS_DIE6);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE6)] = S(.SPR_BOSS, 13, 8, null, .S_BOSS_DIE7);
    tbl[@intFromEnum(StateNum.S_BOSS_DIE7)] = S(.SPR_BOSS, 14, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE1)] = S(.SPR_BOSS, 14, 8, null, .S_BOSS_RAISE2);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE2)] = S(.SPR_BOSS, 13, 8, null, .S_BOSS_RAISE3);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE3)] = S(.SPR_BOSS, 12, 8, null, .S_BOSS_RAISE4);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE4)] = S(.SPR_BOSS, 11, 8, null, .S_BOSS_RAISE5);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE5)] = S(.SPR_BOSS, 10, 8, null, .S_BOSS_RAISE6);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE6)] = S(.SPR_BOSS, 9, 8, null, .S_BOSS_RAISE7);
    tbl[@intFromEnum(StateNum.S_BOSS_RAISE7)] = S(.SPR_BOSS, 8, 8, null, .S_BOSS_RUN1);

    // ---- Hell Knight (BOS2) ----
    tbl[@intFromEnum(StateNum.S_BOS2_STND)] = S(.SPR_BOS2, 0, 10, null, .S_BOS2_STND2);
    tbl[@intFromEnum(StateNum.S_BOS2_STND2)] = S(.SPR_BOS2, 1, 10, null, .S_BOS2_STND);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN1)] = S(.SPR_BOS2, 0, 3, null, .S_BOS2_RUN2);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN2)] = S(.SPR_BOS2, 0, 3, null, .S_BOS2_RUN3);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN3)] = S(.SPR_BOS2, 1, 3, null, .S_BOS2_RUN4);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN4)] = S(.SPR_BOS2, 1, 3, null, .S_BOS2_RUN5);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN5)] = S(.SPR_BOS2, 2, 3, null, .S_BOS2_RUN6);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN6)] = S(.SPR_BOS2, 2, 3, null, .S_BOS2_RUN7);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN7)] = S(.SPR_BOS2, 3, 3, null, .S_BOS2_RUN8);
    tbl[@intFromEnum(StateNum.S_BOS2_RUN8)] = S(.SPR_BOS2, 3, 3, null, .S_BOS2_RUN1);
    tbl[@intFromEnum(StateNum.S_BOS2_ATK1)] = S(.SPR_BOS2, 4, 8, null, .S_BOS2_ATK2);
    tbl[@intFromEnum(StateNum.S_BOS2_ATK2)] = S(.SPR_BOS2, 5, 8, null, .S_BOS2_ATK3);
    tbl[@intFromEnum(StateNum.S_BOS2_ATK3)] = S(.SPR_BOS2, 6 | FF_FULLBRIGHT, 8, null, .S_BOS2_RUN1);
    tbl[@intFromEnum(StateNum.S_BOS2_PAIN)] = S(.SPR_BOS2, 7, 2, null, .S_BOS2_PAIN2);
    tbl[@intFromEnum(StateNum.S_BOS2_PAIN2)] = S(.SPR_BOS2, 7, 2, null, .S_BOS2_RUN1);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE1)] = S(.SPR_BOS2, 8, 8, null, .S_BOS2_DIE2);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE2)] = S(.SPR_BOS2, 9, 8, null, .S_BOS2_DIE3);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE3)] = S(.SPR_BOS2, 10, 8, null, .S_BOS2_DIE4);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE4)] = S(.SPR_BOS2, 11, 8, null, .S_BOS2_DIE5);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE5)] = S(.SPR_BOS2, 12, 8, null, .S_BOS2_DIE6);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE6)] = S(.SPR_BOS2, 13, 8, null, .S_BOS2_DIE7);
    tbl[@intFromEnum(StateNum.S_BOS2_DIE7)] = S(.SPR_BOS2, 14, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE1)] = S(.SPR_BOS2, 14, 8, null, .S_BOS2_RAISE2);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE2)] = S(.SPR_BOS2, 13, 8, null, .S_BOS2_RAISE3);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE3)] = S(.SPR_BOS2, 12, 8, null, .S_BOS2_RAISE4);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE4)] = S(.SPR_BOS2, 11, 8, null, .S_BOS2_RAISE5);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE5)] = S(.SPR_BOS2, 10, 8, null, .S_BOS2_RAISE6);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE6)] = S(.SPR_BOS2, 9, 8, null, .S_BOS2_RAISE7);
    tbl[@intFromEnum(StateNum.S_BOS2_RAISE7)] = S(.SPR_BOS2, 8, 8, null, .S_BOS2_RUN1);

    // ---- Lost Soul (SKUL) ----
    tbl[@intFromEnum(StateNum.S_SKULL_STND)] = S(.SPR_SKUL, 0 | FF_FULLBRIGHT, 10, null, .S_SKULL_STND2);
    tbl[@intFromEnum(StateNum.S_SKULL_STND2)] = S(.SPR_SKUL, 1 | FF_FULLBRIGHT, 10, null, .S_SKULL_STND);
    tbl[@intFromEnum(StateNum.S_SKULL_RUN1)] = S(.SPR_SKUL, 0 | FF_FULLBRIGHT, 6, null, .S_SKULL_RUN2);
    tbl[@intFromEnum(StateNum.S_SKULL_RUN2)] = S(.SPR_SKUL, 1 | FF_FULLBRIGHT, 6, null, .S_SKULL_RUN1);
    tbl[@intFromEnum(StateNum.S_SKULL_ATK1)] = S(.SPR_SKUL, 2 | FF_FULLBRIGHT, 10, null, .S_SKULL_ATK2);
    tbl[@intFromEnum(StateNum.S_SKULL_ATK2)] = S(.SPR_SKUL, 3 | FF_FULLBRIGHT, 4, null, .S_SKULL_ATK3); // A_SkullAttack
    tbl[@intFromEnum(StateNum.S_SKULL_ATK3)] = S(.SPR_SKUL, 2 | FF_FULLBRIGHT, 4, null, .S_SKULL_ATK4);
    tbl[@intFromEnum(StateNum.S_SKULL_ATK4)] = S(.SPR_SKUL, 3 | FF_FULLBRIGHT, 4, null, .S_SKULL_ATK3);
    tbl[@intFromEnum(StateNum.S_SKULL_PAIN)] = S(.SPR_SKUL, 4 | FF_FULLBRIGHT, 3, null, .S_SKULL_PAIN2);
    tbl[@intFromEnum(StateNum.S_SKULL_PAIN2)] = S(.SPR_SKUL, 4 | FF_FULLBRIGHT, 3, null, .S_SKULL_RUN1);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE1)] = S(.SPR_SKUL, 5 | FF_FULLBRIGHT, 6, null, .S_SKULL_DIE2);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE2)] = S(.SPR_SKUL, 6 | FF_FULLBRIGHT, 6, null, .S_SKULL_DIE3);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE3)] = S(.SPR_SKUL, 7 | FF_FULLBRIGHT, 6, null, .S_SKULL_DIE4);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE4)] = S(.SPR_SKUL, 8 | FF_FULLBRIGHT, 6, null, .S_SKULL_DIE5);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE5)] = S(.SPR_SKUL, 9, 6, null, .S_SKULL_DIE6);
    tbl[@intFromEnum(StateNum.S_SKULL_DIE6)] = S(.SPR_SKUL, 10, 6, null, .S_NULL);

    // ---- Baron/Knight fireball (BAL7) ----
    tbl[@intFromEnum(StateNum.S_BRBALL1)] = S(.SPR_BAL7, 0 | FF_FULLBRIGHT, 4, null, .S_BRBALL2);
    tbl[@intFromEnum(StateNum.S_BRBALL2)] = S(.SPR_BAL7, 1 | FF_FULLBRIGHT, 4, null, .S_BRBALL1);
    tbl[@intFromEnum(StateNum.S_BRBALLX1)] = S(.SPR_BAL7, 2 | FF_FULLBRIGHT, 6, null, .S_BRBALLX2);
    tbl[@intFromEnum(StateNum.S_BRBALLX2)] = S(.SPR_BAL7, 3 | FF_FULLBRIGHT, 6, null, .S_BRBALLX3);
    tbl[@intFromEnum(StateNum.S_BRBALLX3)] = S(.SPR_BAL7, 4 | FF_FULLBRIGHT, 6, null, .S_NULL);

    // ---- Barrel (BAR1) ----
    tbl[@intFromEnum(StateNum.S_BAR1)] = S(.SPR_BAR1, 0, 6, null, .S_BAR2);
    tbl[@intFromEnum(StateNum.S_BAR2)] = S(.SPR_BAR1, 1, 6, null, .S_BAR1);
    tbl[@intFromEnum(StateNum.S_BEXP)] = S(.SPR_BEXP, 0 | FF_FULLBRIGHT, 5, null, .S_BEXP2);
    tbl[@intFromEnum(StateNum.S_BEXP2)] = S(.SPR_BEXP, 1 | FF_FULLBRIGHT, 5, null, .S_BEXP3);
    tbl[@intFromEnum(StateNum.S_BEXP3)] = S(.SPR_BEXP, 2 | FF_FULLBRIGHT, 5, null, .S_BEXP4);
    tbl[@intFromEnum(StateNum.S_BEXP4)] = S(.SPR_BEXP, 3 | FF_FULLBRIGHT, 10, null, .S_BEXP5); // A_Explode
    tbl[@intFromEnum(StateNum.S_BEXP5)] = S(.SPR_BEXP, 4 | FF_FULLBRIGHT, 10, null, .S_NULL);

    // ---- Pickup Items ----
    tbl[@intFromEnum(StateNum.S_ARM1)] = S(.SPR_ARM1, 0, 6, null, .S_ARM1A);
    tbl[@intFromEnum(StateNum.S_ARM1A)] = S(.SPR_ARM1, 1, 7, null, .S_ARM1);
    tbl[@intFromEnum(StateNum.S_ARM2)] = S(.SPR_ARM2, 0, 6, null, .S_ARM2A);
    tbl[@intFromEnum(StateNum.S_ARM2A)] = S(.SPR_ARM2, 1, 6, null, .S_ARM2);

    tbl[@intFromEnum(StateNum.S_BON1)] = S(.SPR_BON1, 0, 6, null, .S_BON1A);
    tbl[@intFromEnum(StateNum.S_BON1A)] = S(.SPR_BON1, 1, 6, null, .S_BON1B);
    tbl[@intFromEnum(StateNum.S_BON1B)] = S(.SPR_BON1, 2, 6, null, .S_BON1C);
    tbl[@intFromEnum(StateNum.S_BON1C)] = S(.SPR_BON1, 3, 6, null, .S_BON1D);
    tbl[@intFromEnum(StateNum.S_BON1D)] = S(.SPR_BON1, 2, 6, null, .S_BON1E);
    tbl[@intFromEnum(StateNum.S_BON1E)] = S(.SPR_BON1, 1, 6, null, .S_BON1);

    tbl[@intFromEnum(StateNum.S_BON2)] = S(.SPR_BON2, 0, 6, null, .S_BON2A);
    tbl[@intFromEnum(StateNum.S_BON2A)] = S(.SPR_BON2, 1, 6, null, .S_BON2B);
    tbl[@intFromEnum(StateNum.S_BON2B)] = S(.SPR_BON2, 2, 6, null, .S_BON2C);
    tbl[@intFromEnum(StateNum.S_BON2C)] = S(.SPR_BON2, 3, 6, null, .S_BON2D);
    tbl[@intFromEnum(StateNum.S_BON2D)] = S(.SPR_BON2, 2, 6, null, .S_BON2E);
    tbl[@intFromEnum(StateNum.S_BON2E)] = S(.SPR_BON2, 1, 6, null, .S_BON2);

    tbl[@intFromEnum(StateNum.S_BKEY)] = S(.SPR_BKEY, 0, 10, null, .S_BKEY2);
    tbl[@intFromEnum(StateNum.S_BKEY2)] = S(.SPR_BKEY, 1 | FF_FULLBRIGHT, 10, null, .S_BKEY);
    tbl[@intFromEnum(StateNum.S_RKEY)] = S(.SPR_RKEY, 0, 10, null, .S_RKEY2);
    tbl[@intFromEnum(StateNum.S_RKEY2)] = S(.SPR_RKEY, 1 | FF_FULLBRIGHT, 10, null, .S_RKEY);
    tbl[@intFromEnum(StateNum.S_YKEY)] = S(.SPR_YKEY, 0, 10, null, .S_YKEY2);
    tbl[@intFromEnum(StateNum.S_YKEY2)] = S(.SPR_YKEY, 1 | FF_FULLBRIGHT, 10, null, .S_YKEY);
    tbl[@intFromEnum(StateNum.S_BSKULL)] = S(.SPR_BSKU, 0, 10, null, .S_BSKULL2);
    tbl[@intFromEnum(StateNum.S_BSKULL2)] = S(.SPR_BSKU, 1 | FF_FULLBRIGHT, 10, null, .S_BSKULL);
    tbl[@intFromEnum(StateNum.S_RSKULL)] = S(.SPR_RSKU, 0, 10, null, .S_RSKULL2);
    tbl[@intFromEnum(StateNum.S_RSKULL2)] = S(.SPR_RSKU, 1 | FF_FULLBRIGHT, 10, null, .S_RSKULL);
    tbl[@intFromEnum(StateNum.S_YSKULL)] = S(.SPR_YSKU, 0, 10, null, .S_YSKULL2);
    tbl[@intFromEnum(StateNum.S_YSKULL2)] = S(.SPR_YSKU, 1 | FF_FULLBRIGHT, 10, null, .S_YSKULL);

    tbl[@intFromEnum(StateNum.S_STIM)] = S(.SPR_STIM, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_MEDI)] = S(.SPR_MEDI, 0, -1, null, .S_NULL);

    tbl[@intFromEnum(StateNum.S_SOUL)] = S(.SPR_SOUL, 0 | FF_FULLBRIGHT, 6, null, .S_SOUL2);
    tbl[@intFromEnum(StateNum.S_SOUL2)] = S(.SPR_SOUL, 1 | FF_FULLBRIGHT, 6, null, .S_SOUL3);
    tbl[@intFromEnum(StateNum.S_SOUL3)] = S(.SPR_SOUL, 2 | FF_FULLBRIGHT, 6, null, .S_SOUL4);
    tbl[@intFromEnum(StateNum.S_SOUL4)] = S(.SPR_SOUL, 3 | FF_FULLBRIGHT, 6, null, .S_SOUL5);
    tbl[@intFromEnum(StateNum.S_SOUL5)] = S(.SPR_SOUL, 2 | FF_FULLBRIGHT, 6, null, .S_SOUL6);
    tbl[@intFromEnum(StateNum.S_SOUL6)] = S(.SPR_SOUL, 1 | FF_FULLBRIGHT, 6, null, .S_SOUL);

    tbl[@intFromEnum(StateNum.S_PINV)] = S(.SPR_PINV, 0 | FF_FULLBRIGHT, 6, null, .S_PINV2);
    tbl[@intFromEnum(StateNum.S_PINV2)] = S(.SPR_PINV, 1 | FF_FULLBRIGHT, 6, null, .S_PINV3);
    tbl[@intFromEnum(StateNum.S_PINV3)] = S(.SPR_PINV, 2 | FF_FULLBRIGHT, 6, null, .S_PINV4);
    tbl[@intFromEnum(StateNum.S_PINV4)] = S(.SPR_PINV, 3 | FF_FULLBRIGHT, 6, null, .S_PINV);
    tbl[@intFromEnum(StateNum.S_PSTR)] = S(.SPR_PSTR, 0 | FF_FULLBRIGHT, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_PINS)] = S(.SPR_PINS, 0 | FF_FULLBRIGHT, 6, null, .S_PINS2);
    tbl[@intFromEnum(StateNum.S_PINS2)] = S(.SPR_PINS, 1 | FF_FULLBRIGHT, 6, null, .S_PINS3);
    tbl[@intFromEnum(StateNum.S_PINS3)] = S(.SPR_PINS, 2 | FF_FULLBRIGHT, 6, null, .S_PINS4);
    tbl[@intFromEnum(StateNum.S_PINS4)] = S(.SPR_PINS, 3 | FF_FULLBRIGHT, 6, null, .S_PINS);
    tbl[@intFromEnum(StateNum.S_MEGA)] = S(.SPR_MEGA, 0 | FF_FULLBRIGHT, 6, null, .S_MEGA2);
    tbl[@intFromEnum(StateNum.S_MEGA2)] = S(.SPR_MEGA, 1 | FF_FULLBRIGHT, 6, null, .S_MEGA3);
    tbl[@intFromEnum(StateNum.S_MEGA3)] = S(.SPR_MEGA, 2 | FF_FULLBRIGHT, 6, null, .S_MEGA4);
    tbl[@intFromEnum(StateNum.S_MEGA4)] = S(.SPR_MEGA, 3 | FF_FULLBRIGHT, 6, null, .S_MEGA);
    tbl[@intFromEnum(StateNum.S_SUIT)] = S(.SPR_SUIT, 0 | FF_FULLBRIGHT, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_PMAP)] = S(.SPR_PMAP, 0 | FF_FULLBRIGHT, 6, null, .S_PMAP2);
    tbl[@intFromEnum(StateNum.S_PMAP2)] = S(.SPR_PMAP, 1 | FF_FULLBRIGHT, 6, null, .S_PMAP3);
    tbl[@intFromEnum(StateNum.S_PMAP3)] = S(.SPR_PMAP, 2 | FF_FULLBRIGHT, 6, null, .S_PMAP4);
    tbl[@intFromEnum(StateNum.S_PMAP4)] = S(.SPR_PMAP, 3 | FF_FULLBRIGHT, 6, null, .S_PMAP5);
    tbl[@intFromEnum(StateNum.S_PMAP5)] = S(.SPR_PMAP, 2 | FF_FULLBRIGHT, 6, null, .S_PMAP6);
    tbl[@intFromEnum(StateNum.S_PMAP6)] = S(.SPR_PMAP, 1 | FF_FULLBRIGHT, 6, null, .S_PMAP);
    tbl[@intFromEnum(StateNum.S_PVIS)] = S(.SPR_PVIS, 0 | FF_FULLBRIGHT, 6, null, .S_PVIS2);
    tbl[@intFromEnum(StateNum.S_PVIS2)] = S(.SPR_PVIS, 1, 6, null, .S_PVIS);

    // ---- Ammo ----
    tbl[@intFromEnum(StateNum.S_CLIP)] = S(.SPR_CLIP, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_AMMO)] = S(.SPR_AMMO, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_ROCK)] = S(.SPR_ROCK, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_BROK)] = S(.SPR_BROK, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_CELL)] = S(.SPR_CELL, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_CELP)] = S(.SPR_CELP, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SHEL)] = S(.SPR_SHEL, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SBOX)] = S(.SPR_SBOX, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_BPAK)] = S(.SPR_BPAK, 0, -1, null, .S_NULL);

    // ---- Weapon pickups ----
    tbl[@intFromEnum(StateNum.S_BFUG)] = S(.SPR_BFUG, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_MGUN)] = S(.SPR_MGUN, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_CSAW)] = S(.SPR_CSAW, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_LAUN)] = S(.SPR_LAUN, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_PLAS)] = S(.SPR_PLAS, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SHOT)] = S(.SPR_SHOT, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SGN2)] = S(.SPR_SGN2, 0, -1, null, .S_NULL);

    // ---- Decorations ----
    tbl[@intFromEnum(StateNum.S_COLU)] = S(.SPR_COLU, 0 | FF_FULLBRIGHT, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_SMT2)] = S(.SPR_SMT2, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POL2)] = S(.SPR_POL2, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POL5)] = S(.SPR_POL5, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POL4)] = S(.SPR_POL4, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POL3)] = S(.SPR_POL3, 0 | FF_FULLBRIGHT, 6, null, .S_POL3);
    tbl[@intFromEnum(StateNum.S_POL1)] = S(.SPR_POL1, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_POL6)] = S(.SPR_POL6, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_GOR1)] = S(.SPR_GOR1, 0, 10, null, .S_GOR1);
    tbl[@intFromEnum(StateNum.S_GOR2)] = S(.SPR_GOR2, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_GOR3)] = S(.SPR_GOR3, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_GOR4)] = S(.SPR_GOR4, 0, -1, null, .S_NULL);
    tbl[@intFromEnum(StateNum.S_GOR5)] = S(.SPR_GOR5, 0, -1, null, .S_NULL);

    // ---- Cyberdemon ----
    tbl[@intFromEnum(StateNum.S_CYBER_STND)] = S(.SPR_CYBR, 0, 10, null, .S_CYBER_STND2);
    tbl[@intFromEnum(StateNum.S_CYBER_STND2)] = S(.SPR_CYBR, 1, 10, null, .S_CYBER_STND);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN1)] = S(.SPR_CYBR, 0, 3, null, .S_CYBER_RUN2);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN2)] = S(.SPR_CYBR, 0, 3, null, .S_CYBER_RUN3);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN3)] = S(.SPR_CYBR, 1, 3, null, .S_CYBER_RUN4);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN4)] = S(.SPR_CYBR, 1, 3, null, .S_CYBER_RUN5);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN5)] = S(.SPR_CYBR, 2, 3, null, .S_CYBER_RUN6);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN6)] = S(.SPR_CYBR, 2, 3, null, .S_CYBER_RUN7);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN7)] = S(.SPR_CYBR, 3, 3, null, .S_CYBER_RUN8);
    tbl[@intFromEnum(StateNum.S_CYBER_RUN8)] = S(.SPR_CYBR, 3, 3, null, .S_CYBER_RUN1);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK1)] = S(.SPR_CYBR, 4, 6, null, .S_CYBER_ATK2);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK2)] = S(.SPR_CYBR, 5, 12, null, .S_CYBER_ATK3);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK3)] = S(.SPR_CYBR, 4, 12, null, .S_CYBER_ATK4);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK4)] = S(.SPR_CYBR, 5, 12, null, .S_CYBER_ATK5);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK5)] = S(.SPR_CYBR, 4, 12, null, .S_CYBER_ATK6);
    tbl[@intFromEnum(StateNum.S_CYBER_ATK6)] = S(.SPR_CYBR, 5, 12, null, .S_CYBER_RUN1);
    tbl[@intFromEnum(StateNum.S_CYBER_PAIN)] = S(.SPR_CYBR, 6, 10, null, .S_CYBER_RUN1);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE1)] = S(.SPR_CYBR, 7, 10, null, .S_CYBER_DIE2);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE2)] = S(.SPR_CYBR, 8, 10, null, .S_CYBER_DIE3);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE3)] = S(.SPR_CYBR, 9, 10, null, .S_CYBER_DIE4);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE4)] = S(.SPR_CYBR, 10, 10, null, .S_CYBER_DIE5);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE5)] = S(.SPR_CYBR, 11, 10, null, .S_CYBER_DIE6);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE6)] = S(.SPR_CYBR, 12, 10, null, .S_CYBER_DIE7);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE7)] = S(.SPR_CYBR, 13, 10, null, .S_CYBER_DIE8);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE8)] = S(.SPR_CYBR, 14, 10, null, .S_CYBER_DIE9);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE9)] = S(.SPR_CYBR, 15, 30, null, .S_CYBER_DIE10);
    tbl[@intFromEnum(StateNum.S_CYBER_DIE10)] = S(.SPR_CYBR, 15, -1, null, .S_NULL);

    // ---- Spider Mastermind ----
    tbl[@intFromEnum(StateNum.S_SPID_STND)] = S(.SPR_SPID, 0, 10, null, .S_SPID_STND2);
    tbl[@intFromEnum(StateNum.S_SPID_STND2)] = S(.SPR_SPID, 1, 10, null, .S_SPID_STND);
    tbl[@intFromEnum(StateNum.S_SPID_RUN1)] = S(.SPR_SPID, 0, 3, null, .S_SPID_RUN2);
    tbl[@intFromEnum(StateNum.S_SPID_RUN2)] = S(.SPR_SPID, 0, 3, null, .S_SPID_RUN3);
    tbl[@intFromEnum(StateNum.S_SPID_RUN3)] = S(.SPR_SPID, 1, 3, null, .S_SPID_RUN4);
    tbl[@intFromEnum(StateNum.S_SPID_RUN4)] = S(.SPR_SPID, 1, 3, null, .S_SPID_RUN5);
    tbl[@intFromEnum(StateNum.S_SPID_RUN5)] = S(.SPR_SPID, 2, 3, null, .S_SPID_RUN6);
    tbl[@intFromEnum(StateNum.S_SPID_RUN6)] = S(.SPR_SPID, 2, 3, null, .S_SPID_RUN7);
    tbl[@intFromEnum(StateNum.S_SPID_RUN7)] = S(.SPR_SPID, 3, 3, null, .S_SPID_RUN8);
    tbl[@intFromEnum(StateNum.S_SPID_RUN8)] = S(.SPR_SPID, 3, 3, null, .S_SPID_RUN9);
    tbl[@intFromEnum(StateNum.S_SPID_RUN9)] = S(.SPR_SPID, 4, 3, null, .S_SPID_RUN10);
    tbl[@intFromEnum(StateNum.S_SPID_RUN10)] = S(.SPR_SPID, 4, 3, null, .S_SPID_RUN11);
    tbl[@intFromEnum(StateNum.S_SPID_RUN11)] = S(.SPR_SPID, 5, 3, null, .S_SPID_RUN12);
    tbl[@intFromEnum(StateNum.S_SPID_RUN12)] = S(.SPR_SPID, 5, 3, null, .S_SPID_RUN1);
    tbl[@intFromEnum(StateNum.S_SPID_ATK1)] = S(.SPR_SPID, 0, 20, null, .S_SPID_ATK2);
    tbl[@intFromEnum(StateNum.S_SPID_ATK2)] = S(.SPR_SPID, 6 | FF_FULLBRIGHT, 4, null, .S_SPID_ATK3);
    tbl[@intFromEnum(StateNum.S_SPID_ATK3)] = S(.SPR_SPID, 7 | FF_FULLBRIGHT, 4, null, .S_SPID_ATK4);
    tbl[@intFromEnum(StateNum.S_SPID_ATK4)] = S(.SPR_SPID, 7 | FF_FULLBRIGHT, 1, null, .S_SPID_RUN1);
    tbl[@intFromEnum(StateNum.S_SPID_PAIN)] = S(.SPR_SPID, 8, 3, null, .S_SPID_PAIN2);
    tbl[@intFromEnum(StateNum.S_SPID_PAIN2)] = S(.SPR_SPID, 8, 3, null, .S_SPID_RUN1);
    tbl[@intFromEnum(StateNum.S_SPID_DIE1)] = S(.SPR_SPID, 9, 20, null, .S_SPID_DIE2);
    tbl[@intFromEnum(StateNum.S_SPID_DIE2)] = S(.SPR_SPID, 10, 10, null, .S_SPID_DIE3);
    tbl[@intFromEnum(StateNum.S_SPID_DIE3)] = S(.SPR_SPID, 11, 10, null, .S_SPID_DIE4);
    tbl[@intFromEnum(StateNum.S_SPID_DIE4)] = S(.SPR_SPID, 12, 10, null, .S_SPID_DIE5);
    tbl[@intFromEnum(StateNum.S_SPID_DIE5)] = S(.SPR_SPID, 13, 10, null, .S_SPID_DIE6);
    tbl[@intFromEnum(StateNum.S_SPID_DIE6)] = S(.SPR_SPID, 14, 10, null, .S_SPID_DIE7);
    tbl[@intFromEnum(StateNum.S_SPID_DIE7)] = S(.SPR_SPID, 15, 10, null, .S_SPID_DIE8);
    tbl[@intFromEnum(StateNum.S_SPID_DIE8)] = S(.SPR_SPID, 16, 10, null, .S_SPID_DIE9);
    tbl[@intFromEnum(StateNum.S_SPID_DIE9)] = S(.SPR_SPID, 17, 10, null, .S_SPID_DIE10);
    tbl[@intFromEnum(StateNum.S_SPID_DIE10)] = S(.SPR_SPID, 18, 30, null, .S_SPID_DIE11);
    tbl[@intFromEnum(StateNum.S_SPID_DIE11)] = S(.SPR_SPID, 18, -1, null, .S_NULL);

    // ---- Teleport destination ----
    tbl[@intFromEnum(StateNum.S_TELEPORT)] = S(.SPR_TROO, 0, -1, null, .S_NULL);

    return tbl;
}

// ============================================================================
// MobjInfo table — properties for each thing type
// ============================================================================

// Helper for fixed point radius/height
fn FX(v: i32) Fixed {
    return Fixed.fromRaw(v * 65536);
}

pub const mobjinfo = buildMobjInfoTable();

fn buildMobjInfoTable() [@intFromEnum(MobjType.NUMMOBJTYPES)]MobjInfo {
    @setEvalBranchQuota(50000);
    var tbl: [@intFromEnum(MobjType.NUMMOBJTYPES)]MobjInfo = undefined;

    // Default placeholder
    const placeholder = MobjInfo{
        .doomednum = -1,
        .spawn_state = .S_NULL,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = 0,
        .raise_state = .S_NULL,
    };

    for (&tbl) |*m| {
        m.* = placeholder;
    }

    // MT_PLAYER
    tbl[@intFromEnum(MobjType.MT_PLAYER)] = .{
        .doomednum = -1,
        .spawn_state = .S_PLAY,
        .spawn_health = 100,
        .see_state = .S_PLAY_RUN1,
        .see_sound = 0,
        .reaction_time = 0,
        .attack_sound = 0,
        .pain_state = .S_PLAY_PAIN,
        .pain_chance = 255,
        .pain_sound = 0, // sfx_plpain
        .melee_state = .S_NULL,
        .missile_state = .S_PLAY_ATK1,
        .death_state = .S_PLAY_DIE1,
        .xdeath_state = .S_PLAY_XDIE1,
        .death_sound = 0, // sfx_pldeth
        .speed = 0,
        .radius = FX(16),
        .height = FX(56),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_DROPOFF | MF_PICKUP | MF_NOTDMATCH,
        .raise_state = .S_NULL,
    };

    // MT_POSSESSED — Zombieman (doomednum 3004)
    tbl[@intFromEnum(MobjType.MT_POSSESSED)] = .{
        .doomednum = 3004,
        .spawn_state = .S_POSS_STND,
        .spawn_health = 20,
        .see_state = .S_POSS_RUN1,
        .see_sound = 0, // sfx_posit1
        .reaction_time = 8,
        .attack_sound = 0, // sfx_pistol
        .pain_state = .S_POSS_PAIN,
        .pain_chance = 200,
        .pain_sound = 0, // sfx_popain
        .melee_state = .S_NULL,
        .missile_state = .S_POSS_ATK1,
        .death_state = .S_POSS_DIE1,
        .xdeath_state = .S_POSS_XDIE1,
        .death_sound = 0, // sfx_podth1
        .speed = 8,
        .radius = FX(20),
        .height = FX(56),
        .mass = 100,
        .damage = 0,
        .active_sound = 0, // sfx_posact
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_POSS_RAISE1,
    };

    // MT_SHOTGUY — Shotgun Guy (doomednum 9)
    tbl[@intFromEnum(MobjType.MT_SHOTGUY)] = .{
        .doomednum = 9,
        .spawn_state = .S_SPOS_STND,
        .spawn_health = 30,
        .see_state = .S_SPOS_RUN1,
        .see_sound = 0, // sfx_posit2
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_SPOS_PAIN,
        .pain_chance = 170,
        .pain_sound = 0, // sfx_popain
        .melee_state = .S_NULL,
        .missile_state = .S_SPOS_ATK1,
        .death_state = .S_SPOS_DIE1,
        .xdeath_state = .S_SPOS_XDIE1,
        .death_sound = 0, // sfx_podth2
        .speed = 8,
        .radius = FX(20),
        .height = FX(56),
        .mass = 100,
        .damage = 0,
        .active_sound = 0, // sfx_posact
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_SPOS_RAISE1,
    };

    // MT_TROOP — Imp (doomednum 3001)
    tbl[@intFromEnum(MobjType.MT_TROOP)] = .{
        .doomednum = 3001,
        .spawn_state = .S_TROO_STND,
        .spawn_health = 60,
        .see_state = .S_TROO_RUN1,
        .see_sound = 0, // sfx_bgsit1
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_TROO_PAIN,
        .pain_chance = 200,
        .pain_sound = 0, // sfx_popain
        .melee_state = .S_TROO_ATK1,
        .missile_state = .S_TROO_ATK1,
        .death_state = .S_TROO_DIE1,
        .xdeath_state = .S_TROO_XDIE1,
        .death_sound = 0, // sfx_bgdth1
        .speed = 8,
        .radius = FX(20),
        .height = FX(56),
        .mass = 100,
        .damage = 0,
        .active_sound = 0, // sfx_bgact
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_TROO_RAISE1,
    };

    // MT_SERGEANT — Demon (doomednum 3002)
    tbl[@intFromEnum(MobjType.MT_SERGEANT)] = .{
        .doomednum = 3002,
        .spawn_state = .S_SARG_STND,
        .spawn_health = 150,
        .see_state = .S_SARG_RUN1,
        .see_sound = 0, // sfx_sgtsit
        .reaction_time = 8,
        .attack_sound = 0, // sfx_sgtatk
        .pain_state = .S_SARG_PAIN,
        .pain_chance = 180,
        .pain_sound = 0, // sfx_dmpain
        .melee_state = .S_SARG_ATK1,
        .missile_state = .S_NULL,
        .death_state = .S_SARG_DIE1,
        .xdeath_state = .S_SARG_DIE1,
        .death_sound = 0, // sfx_sgtdth
        .speed = 10,
        .radius = FX(30),
        .height = FX(56),
        .mass = 400,
        .damage = 0,
        .active_sound = 0, // sfx_dmact
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_SARG_RAISE1,
    };

    // MT_SHADOWS — Spectre (doomednum 58)
    tbl[@intFromEnum(MobjType.MT_SHADOWS)] = .{
        .doomednum = 58,
        .spawn_state = .S_SARG_STND,
        .spawn_health = 150,
        .see_state = .S_SARG_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_SARG_PAIN,
        .pain_chance = 180,
        .pain_sound = 0,
        .melee_state = .S_SARG_ATK1,
        .missile_state = .S_NULL,
        .death_state = .S_SARG_DIE1,
        .xdeath_state = .S_SARG_DIE1,
        .death_sound = 0,
        .speed = 10,
        .radius = FX(30),
        .height = FX(56),
        .mass = 400,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_SHADOW | MF_COUNTKILL,
        .raise_state = .S_SARG_RAISE1,
    };

    // MT_HEAD — Cacodemon (doomednum 3005)
    tbl[@intFromEnum(MobjType.MT_HEAD)] = .{
        .doomednum = 3005,
        .spawn_state = .S_HEAD_STND,
        .spawn_health = 400,
        .see_state = .S_HEAD_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_HEAD_PAIN,
        .pain_chance = 128,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_HEAD_ATK1,
        .death_state = .S_HEAD_DIE1,
        .xdeath_state = .S_HEAD_DIE1,
        .death_sound = 0,
        .speed = 8,
        .radius = FX(31),
        .height = FX(56),
        .mass = 400,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_FLOAT | MF_NOGRAVITY | MF_COUNTKILL,
        .raise_state = .S_HEAD_RAISE1,
    };

    // MT_BRUISER — Baron of Hell (doomednum 3003)
    tbl[@intFromEnum(MobjType.MT_BRUISER)] = .{
        .doomednum = 3003,
        .spawn_state = .S_BOSS_STND,
        .spawn_health = 1000,
        .see_state = .S_BOSS_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_BOSS_PAIN,
        .pain_chance = 50,
        .pain_sound = 0,
        .melee_state = .S_BOSS_ATK1,
        .missile_state = .S_BOSS_ATK1,
        .death_state = .S_BOSS_DIE1,
        .xdeath_state = .S_BOSS_DIE1,
        .death_sound = 0,
        .speed = 8,
        .radius = FX(24),
        .height = FX(64),
        .mass = 1000,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_BOSS_RAISE1,
    };

    // MT_BRUISERSHOT — Baron/Knight fireball
    tbl[@intFromEnum(MobjType.MT_BRUISERSHOT)] = .{
        .doomednum = -1,
        .spawn_state = .S_BRBALL1,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_BRBALLX1,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 15 * 65536,
        .radius = FX(6),
        .height = FX(8),
        .mass = 100,
        .damage = 8,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_KNIGHT — Hell Knight (doomednum 69)
    tbl[@intFromEnum(MobjType.MT_KNIGHT)] = .{
        .doomednum = 69,
        .spawn_state = .S_BOS2_STND,
        .spawn_health = 500,
        .see_state = .S_BOS2_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_BOS2_PAIN,
        .pain_chance = 50,
        .pain_sound = 0,
        .melee_state = .S_BOS2_ATK1,
        .missile_state = .S_BOS2_ATK1,
        .death_state = .S_BOS2_DIE1,
        .xdeath_state = .S_BOS2_DIE1,
        .death_sound = 0,
        .speed = 8,
        .radius = FX(24),
        .height = FX(64),
        .mass = 1000,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_BOS2_RAISE1,
    };

    // MT_SKULL — Lost Soul (doomednum 3006)
    tbl[@intFromEnum(MobjType.MT_SKULL)] = .{
        .doomednum = 3006,
        .spawn_state = .S_SKULL_STND,
        .spawn_health = 100,
        .see_state = .S_SKULL_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_SKULL_PAIN,
        .pain_chance = 256,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_SKULL_ATK1,
        .death_state = .S_SKULL_DIE1,
        .xdeath_state = .S_SKULL_DIE1,
        .death_sound = 0,
        .speed = 8,
        .radius = FX(16),
        .height = FX(56),
        .mass = 50,
        .damage = 3,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_FLOAT | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_SPIDER — Spider Mastermind (doomednum 7)
    tbl[@intFromEnum(MobjType.MT_SPIDER)] = .{
        .doomednum = 7,
        .spawn_state = .S_SPID_STND,
        .spawn_health = 3000,
        .see_state = .S_SPID_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_SPID_PAIN,
        .pain_chance = 40,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_SPID_ATK1,
        .death_state = .S_SPID_DIE1,
        .xdeath_state = .S_SPID_DIE1,
        .death_sound = 0,
        .speed = 12,
        .radius = FX(128),
        .height = FX(100),
        .mass = 1000,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_NULL,
    };

    // MT_CYBORG — Cyberdemon (doomednum 16)
    tbl[@intFromEnum(MobjType.MT_CYBORG)] = .{
        .doomednum = 16,
        .spawn_state = .S_CYBER_STND,
        .spawn_health = 4000,
        .see_state = .S_CYBER_RUN1,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_CYBER_PAIN,
        .pain_chance = 20,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_CYBER_ATK1,
        .death_state = .S_CYBER_DIE1,
        .xdeath_state = .S_CYBER_DIE1,
        .death_sound = 0,
        .speed = 16,
        .radius = FX(40),
        .height = FX(110),
        .mass = 1000,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL,
        .raise_state = .S_NULL,
    };

    // MT_TROOPSHOT — Imp fireball
    tbl[@intFromEnum(MobjType.MT_TROOPSHOT)] = .{
        .doomednum = -1,
        .spawn_state = .S_TBALL1,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_TBALLX1,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 10 * 65536,
        .radius = FX(6),
        .height = FX(8),
        .mass = 100,
        .damage = 3,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_HEADSHOT — Cacodemon fireball
    tbl[@intFromEnum(MobjType.MT_HEADSHOT)] = .{
        .doomednum = -1,
        .spawn_state = .S_RBALL1,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_RBALLX1,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 10 * 65536,
        .radius = FX(6),
        .height = FX(8),
        .mass = 100,
        .damage = 5,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_ROCKET — Player rocket
    tbl[@intFromEnum(MobjType.MT_ROCKET)] = .{
        .doomednum = -1,
        .spawn_state = .S_ROCKET,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0, // sfx_rlaunc
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_EXPLODE1,
        .xdeath_state = .S_NULL,
        .death_sound = 0, // sfx_barexp
        .speed = 20 * 65536,
        .radius = FX(11),
        .height = FX(8),
        .mass = 100,
        .damage = 20,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_PLASMA — Plasma bolt
    tbl[@intFromEnum(MobjType.MT_PLASMA)] = .{
        .doomednum = -1,
        .spawn_state = .S_PLASBALL,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0, // sfx_plasma
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_PLASEXP,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 25 * 65536,
        .radius = FX(13),
        .height = FX(8),
        .mass = 100,
        .damage = 5,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_BFG — BFG ball
    tbl[@intFromEnum(MobjType.MT_BFG)] = .{
        .doomednum = -1,
        .spawn_state = .S_BFGSHOT,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_BFGLAND,
        .xdeath_state = .S_NULL,
        .death_sound = 0, // sfx_rxplod
        .speed = 25 * 65536,
        .radius = FX(13),
        .height = FX(8),
        .mass = 100,
        .damage = 100,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_MISSILE | MF_DROPOFF | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_PUFF — Bullet puff
    tbl[@intFromEnum(MobjType.MT_PUFF)] = .{
        .doomednum = -1,
        .spawn_state = .S_PUFF1,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_BLOOD — Blood splat
    tbl[@intFromEnum(MobjType.MT_BLOOD)] = .{
        .doomednum = -1,
        .spawn_state = .S_BLOOD1,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP,
        .raise_state = .S_NULL,
    };

    // MT_TFOG — Teleport fog
    tbl[@intFromEnum(MobjType.MT_TFOG)] = .{
        .doomednum = -1,
        .spawn_state = .S_TFOG,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_IFOG — Item respawn fog
    tbl[@intFromEnum(MobjType.MT_IFOG)] = .{
        .doomednum = -1,
        .spawn_state = .S_IFOG,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_NOBLOCKMAP | MF_NOGRAVITY,
        .raise_state = .S_NULL,
    };

    // MT_TELEPORTMAN — Teleport destination
    tbl[@intFromEnum(MobjType.MT_TELEPORTMAN)] = .{
        .doomednum = 14,
        .spawn_state = .S_NULL,
        .spawn_health = 1000,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_NULL,
        .xdeath_state = .S_NULL,
        .death_sound = 0,
        .speed = 0,
        .radius = FX(20),
        .height = FX(16),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_NOSECTOR | MF_NOBLOCKMAP,
        .raise_state = .S_NULL,
    };

    // MT_BARREL (doomednum 2035)
    tbl[@intFromEnum(MobjType.MT_BARREL)] = .{
        .doomednum = 2035,
        .spawn_state = .S_BAR1,
        .spawn_health = 20,
        .see_state = .S_NULL,
        .see_sound = 0,
        .reaction_time = 8,
        .attack_sound = 0,
        .pain_state = .S_NULL,
        .pain_chance = 0,
        .pain_sound = 0,
        .melee_state = .S_NULL,
        .missile_state = .S_NULL,
        .death_state = .S_BEXP,
        .xdeath_state = .S_NULL,
        .death_sound = 0, // sfx_barexp
        .speed = 0,
        .radius = FX(10),
        .height = FX(42),
        .mass = 100,
        .damage = 0,
        .active_sound = 0,
        .flags = MF_SOLID | MF_SHOOTABLE | MF_NOBLOOD,
        .raise_state = .S_NULL,
    };

    // Pickup items
    // MT_MISC0 — Green armor (doomednum 2018)
    tbl[@intFromEnum(MobjType.MT_MISC0)] = .{ .doomednum = 2018, .spawn_state = .S_ARM1, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_MISC1 — Blue armor (doomednum 2019)
    tbl[@intFromEnum(MobjType.MT_MISC1)] = .{ .doomednum = 2019, .spawn_state = .S_ARM2, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_MISC2 — Health bonus (doomednum 2014)
    tbl[@intFromEnum(MobjType.MT_MISC2)] = .{ .doomednum = 2014, .spawn_state = .S_BON1, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL | MF_COUNTITEM, .raise_state = .S_NULL };
    // MT_MISC3 — Armor bonus (doomednum 2015)
    tbl[@intFromEnum(MobjType.MT_MISC3)] = .{ .doomednum = 2015, .spawn_state = .S_BON2, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL | MF_COUNTITEM, .raise_state = .S_NULL };
    // MT_MISC4 — Blue keycard (doomednum 5)
    tbl[@intFromEnum(MobjType.MT_MISC4)] = .{ .doomednum = 5, .spawn_state = .S_BKEY, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL | MF_NOTDMATCH, .raise_state = .S_NULL };
    // MT_MISC5 — Red keycard (doomednum 13)
    tbl[@intFromEnum(MobjType.MT_MISC5)] = .{ .doomednum = 13, .spawn_state = .S_RKEY, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL | MF_NOTDMATCH, .raise_state = .S_NULL };
    // MT_MISC6 — Yellow keycard (doomednum 6)
    tbl[@intFromEnum(MobjType.MT_MISC6)] = .{ .doomednum = 6, .spawn_state = .S_YKEY, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL | MF_NOTDMATCH, .raise_state = .S_NULL };
    // MT_MISC10 — Stimpack (doomednum 2011)
    tbl[@intFromEnum(MobjType.MT_MISC10)] = .{ .doomednum = 2011, .spawn_state = .S_STIM, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_MISC11 — Medikit (doomednum 2012)
    tbl[@intFromEnum(MobjType.MT_MISC11)] = .{ .doomednum = 2012, .spawn_state = .S_MEDI, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_CLIP — Ammo clip (doomednum 2007)
    tbl[@intFromEnum(MobjType.MT_CLIP)] = .{ .doomednum = 2007, .spawn_state = .S_CLIP, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_MISC22 — Shells (doomednum 2008)
    tbl[@intFromEnum(MobjType.MT_MISC22)] = .{ .doomednum = 2008, .spawn_state = .S_SHEL, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_MISC29 — Shotgun pickup (doomednum 2001)
    tbl[@intFromEnum(MobjType.MT_MISC29)] = .{ .doomednum = 2001, .spawn_state = .S_SHOT, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };
    // MT_CHAINGUN — Chaingun pickup (doomednum 2002)
    tbl[@intFromEnum(MobjType.MT_CHAINGUN)] = .{ .doomednum = 2002, .spawn_state = .S_MGUN, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(20), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SPECIAL, .raise_state = .S_NULL };

    // Decorations — column (doomednum 2028)
    tbl[@intFromEnum(MobjType.MT_MISC31)] = .{ .doomednum = 30, .spawn_state = .S_COLU, .spawn_health = 1000, .see_state = .S_NULL, .see_sound = 0, .reaction_time = 8, .attack_sound = 0, .pain_state = .S_NULL, .pain_chance = 0, .pain_sound = 0, .melee_state = .S_NULL, .missile_state = .S_NULL, .death_state = .S_NULL, .xdeath_state = .S_NULL, .death_sound = 0, .speed = 0, .radius = FX(16), .height = FX(16), .mass = 100, .damage = 0, .active_sound = 0, .flags = MF_SOLID, .raise_state = .S_NULL };

    return tbl;
}

/// Find MobjType by doomednum (editor thing number)
pub fn findMobjType(doomednum: i32) ?MobjType {
    for (0..@intFromEnum(MobjType.NUMMOBJTYPES)) |i| {
        if (mobjinfo[i].doomednum == doomednum) {
            return @enumFromInt(i);
        }
    }
    return null;
}

test "info table sizes" {
    try std.testing.expect(states.len == @intFromEnum(StateNum.NUMSTATES));
    try std.testing.expect(mobjinfo.len == @intFromEnum(MobjType.NUMMOBJTYPES));
    try std.testing.expect(sprnames.len == @intFromEnum(SpriteNum.NUMSPRITES));
}

test "imp state chain" {
    // Imp spawn -> stnd -> stnd2 -> stnd (loop)
    const stnd = states[@intFromEnum(StateNum.S_TROO_STND)];
    try std.testing.expectEqual(SpriteNum.SPR_TROO, stnd.sprite);
    try std.testing.expectEqual(@as(i32, 10), stnd.tics);
    try std.testing.expectEqual(StateNum.S_TROO_STND2, stnd.next_state);

    const stnd2 = states[@intFromEnum(StateNum.S_TROO_STND2)];
    try std.testing.expectEqual(StateNum.S_TROO_STND, stnd2.next_state);
}

test "mobjinfo lookup" {
    // Imp is doomednum 3001
    const imp_type = findMobjType(3001);
    try std.testing.expect(imp_type != null);
    try std.testing.expectEqual(MobjType.MT_TROOP, imp_type.?);

    const imp_info = mobjinfo[@intFromEnum(MobjType.MT_TROOP)];
    try std.testing.expectEqual(@as(i32, 60), imp_info.spawn_health);
    try std.testing.expectEqual(StateNum.S_TROO_STND, imp_info.spawn_state);
}

test "flags correct" {
    const poss_info = mobjinfo[@intFromEnum(MobjType.MT_POSSESSED)];
    try std.testing.expect(poss_info.flags & MF_SOLID != 0);
    try std.testing.expect(poss_info.flags & MF_SHOOTABLE != 0);
    try std.testing.expect(poss_info.flags & MF_COUNTKILL != 0);

    const skull_info = mobjinfo[@intFromEnum(MobjType.MT_SKULL)];
    try std.testing.expect(skull_info.flags & MF_FLOAT != 0);
    try std.testing.expect(skull_info.flags & MF_NOGRAVITY != 0);
}

test "projectile speed is fixed point" {
    const troopshot = mobjinfo[@intFromEnum(MobjType.MT_TROOPSHOT)];
    try std.testing.expectEqual(@as(i32, 10 * 65536), troopshot.speed);

    const rocket = mobjinfo[@intFromEnum(MobjType.MT_ROCKET)];
    try std.testing.expectEqual(@as(i32, 20 * 65536), rocket.speed);
}
