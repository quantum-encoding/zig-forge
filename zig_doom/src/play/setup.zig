//! zig_doom/src/play/setup.zig
//!
//! Map loading — reads WAD lumps and builds runtime level structures.
//! Translated from: linuxdoom-1.10/p_setup.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Wad = @import("../wad.zig").Wad;

// ============================================================================
// Runtime level structures (resolved pointers, Fixed-point coords)
// ============================================================================

pub const Vertex = struct {
    x: Fixed,
    y: Fixed,
};

pub const Sector = struct {
    floorheight: Fixed,
    ceilingheight: Fixed,
    floorpic: i32, // flat number
    ceilingpic: i32, // flat number
    lightlevel: i16,
    special: i16,
    tag: i16,
    // Rendering state
    floor_name: [8]u8,
    ceiling_name: [8]u8,
    // Sound propagation (P_NoiseAlert / P_RecursiveSound)
    soundtarget: ?*anyopaque = null, // *MapObject that made noise here
    soundtraversed: i32 = 0, // 0 = untraversed, 1,2 = sndlines crossed
    validcount: i32 = 0, // flood-fill visit marker
    // A floor mover (plat/floor) is active on this sector (vanilla specialdata)
    floordata_busy: bool = false,
    // Active door/ceiling thinker on this sector (vanilla specialdata) —
    // points at a doors.VerticalDoor so a re-press can reverse it
    ceilingdata: ?*anyopaque = null,
    // Blockmap cell range touched by this sector's lines ±MAXRADIUS
    // (vanilla P_GroupLines): [top, bottom, left, right]
    blockbox: [4]i32 = .{ 0, 0, 0, 0 },
};

pub const Side = struct {
    textureoffset: Fixed,
    rowoffset: Fixed,
    toptexture: i16,
    bottomtexture: i16,
    midtexture: i16,
    sector: u16, // index into sectors
    top_name: [8]u8,
    bottom_name: [8]u8,
    mid_name: [8]u8,
};

pub const Line = struct {
    v1: u16, // index into vertices
    v2: u16,
    flags: i16,
    special: i16,
    tag: i16,
    sidenum: [2]i16, // -1 = no side
    // Precomputed
    dx: Fixed,
    dy: Fixed,
    slopetype: SlopeType,
    frontsector: ?u16, // index into sectors
    backsector: ?u16,
    // Bounding box
    bbox: [4]Fixed,
};

pub const SlopeType = enum {
    horizontal,
    vertical,
    positive,
    negative,
};

pub const Seg = struct {
    v1: u16, // index into vertices
    v2: u16,
    offset: Fixed,
    angle: u32, // binary angle (Angle)
    sidedef: u16, // index into sides
    linedef: u16, // index into lines
    frontsector: ?u16, // index into sectors
    backsector: ?u16,
};

pub const Subsector = struct {
    numlines: u16,
    firstline: u16,
    sector: ?u16, // sector from first seg
};

pub const Node = struct {
    x: Fixed, // partition line origin
    y: Fixed,
    dx: Fixed, // partition line direction
    dy: Fixed,
    bbox: [2][4]Fixed, // bounding boxes [right, left]
    children: [2]u16, // right and left child
};

pub const Level = struct {
    vertices: []Vertex,
    sectors: []Sector,
    sides: []Side,
    lines: []Line,
    segs: []Seg,
    subsectors: []Subsector,
    nodes: []Node,
    things: []defs.MapThing,
    blockmap_data: []const u8,
    reject_data: []const u8,
    num_nodes: u16,
    // Parsed blockmap (vanilla locality semantics for traces + collision)
    bmap_orgx: Fixed = Fixed.ZERO,
    bmap_orgy: Fixed = Fixed.ZERO,
    bmap_cols: i32 = 0,
    bmap_rows: i32 = 0,
    // Per-cell mobj chain heads (vanilla blocklinks); *MapObject as anyopaque
    blocklinks: []?*anyopaque = &[_]?*anyopaque{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Level) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.sectors);
        self.allocator.free(self.sides);
        self.allocator.free(self.lines);
        self.allocator.free(self.segs);
        self.allocator.free(self.subsectors);
        self.allocator.free(self.nodes);
        self.allocator.free(self.things);
        if (self.blocklinks.len > 0) self.allocator.free(self.blocklinks);
    }

    /// Find player 1 start thing
    /// Read a u16 from the raw blockmap lump (little-endian word index)
    pub fn bmapWord(self: *const Level, word_idx: usize) u16 {
        const off = word_idx * 2;
        if (off + 2 > self.blockmap_data.len) return 0xFFFF;
        return @as(u16, self.blockmap_data[off]) | (@as(u16, self.blockmap_data[off + 1]) << 8);
    }

    /// Iterate the linedef indices stored for blockmap cell (cx, cy).
    /// Calls cb for each line index; cb returns false to stop.
    pub fn blockLines(self: *const Level, cx: i32, cy: i32, ctx: anytype, comptime cb: fn (@TypeOf(ctx), u16) bool) bool {
        if (cx < 0 or cy < 0 or cx >= self.bmap_cols or cy >= self.bmap_rows) return true;
        const cell: usize = @intCast(cy * self.bmap_cols + cx);
        var w: usize = self.bmapWord(4 + cell);
        // VANILLA QUIRK: the list's leading 0 marker is NOT skipped — vanilla
        // reads it as linedef 0, so line 0 participates in every cell's
        // checks. Demos depend on it (the player can slide along line 0
        // from anywhere on the map).
        while (true) {
            const v = self.bmapWord(w);
            if (v == 0xFFFF) break;
            if (!cb(ctx, v)) return false;
            w += 1;
        }
        return true;
    }

    pub fn findPlayer1Start(self: *const Level) ?defs.MapThing {
        for (self.things) |t| {
            if (t.thing_type == 1) return t; // Type 1 = Player 1 start
        }
        return null;
    }
};

pub const SetupError = error{
    LumpNotFound,
    OutOfMemory,
    InvalidData,
};

/// Load a complete map from the WAD
pub fn loadMap(w: *const Wad, map_name: []const u8, alloc: std.mem.Allocator) SetupError!Level {
    // Find the map marker lump
    const map_lump = w.findLump(map_name) orelse return SetupError.LumpNotFound;

    // Load raw WAD data for each lump
    const things_lump = w.findLumpAfter("THINGS", map_lump + 1) orelse return SetupError.LumpNotFound;
    const linedefs_lump = w.findLumpAfter("LINEDEFS", map_lump + 1) orelse return SetupError.LumpNotFound;
    const sidedefs_lump = w.findLumpAfter("SIDEDEFS", map_lump + 1) orelse return SetupError.LumpNotFound;
    const vertexes_lump = w.findLumpAfter("VERTEXES", map_lump + 1) orelse return SetupError.LumpNotFound;
    const segs_lump = w.findLumpAfter("SEGS", map_lump + 1) orelse return SetupError.LumpNotFound;
    const ssectors_lump = w.findLumpAfter("SSECTORS", map_lump + 1) orelse return SetupError.LumpNotFound;
    const nodes_lump = w.findLumpAfter("NODES", map_lump + 1) orelse return SetupError.LumpNotFound;
    const sectors_lump = w.findLumpAfter("SECTORS", map_lump + 1) orelse return SetupError.LumpNotFound;

    // Load vertices
    const raw_verts = w.lumpAs(vertexes_lump, defs.MapVertex);
    const vertices = alloc.alloc(Vertex, raw_verts.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(vertices);
    for (raw_verts, 0..) |rv, i| {
        vertices[i] = .{
            .x = Fixed.fromInt(@as(i32, rv.x)),
            .y = Fixed.fromInt(@as(i32, rv.y)),
        };
    }

    // Load sectors
    const raw_sectors = w.lumpAs(sectors_lump, defs.MapSector);
    const sectors = alloc.alloc(Sector, raw_sectors.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(sectors);
    for (raw_sectors, 0..) |rs, i| {
        sectors[i] = .{
            .floorheight = Fixed.fromInt(@as(i32, rs.floorheight)),
            .ceilingheight = Fixed.fromInt(@as(i32, rs.ceilingheight)),
            .floorpic = 0, // resolved later by texture loader
            .ceilingpic = 0,
            .lightlevel = rs.lightlevel,
            .special = rs.special,
            .tag = rs.tag,
            .floor_name = rs.floorpic,
            .ceiling_name = rs.ceilingpic,
        };
    }

    // Load sidedefs
    const raw_sides = w.lumpAs(sidedefs_lump, defs.MapSidedef);
    const sides = alloc.alloc(Side, raw_sides.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(sides);
    for (raw_sides, 0..) |rs, i| {
        sides[i] = .{
            .textureoffset = Fixed.fromInt(@as(i32, rs.textureoffset)),
            .rowoffset = Fixed.fromInt(@as(i32, rs.rowoffset)),
            .toptexture = 0, // resolved later
            .bottomtexture = 0,
            .midtexture = 0,
            .sector = @intCast(rs.sector),
            .top_name = rs.toptexture,
            .bottom_name = rs.bottomtexture,
            .mid_name = rs.midtexture,
        };
    }

    // Load linedefs
    const raw_lines = w.lumpAs(linedefs_lump, defs.MapLinedef);
    const lines = alloc.alloc(Line, raw_lines.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(lines);
    for (raw_lines, 0..) |rl, i| {
        const v1_idx: u16 = @intCast(rl.v1);
        const v2_idx: u16 = @intCast(rl.v2);
        const dx = Fixed.sub(vertices[v2_idx].x, vertices[v1_idx].x);
        const dy = Fixed.sub(vertices[v2_idx].y, vertices[v1_idx].y);

        // Determine slope type
        const slopetype: SlopeType = blk: {
            if (dx.raw() == 0) break :blk .vertical;
            if (dy.raw() == 0) break :blk .horizontal;
            if (Fixed.div(dy, dx).raw() > 0) break :blk .positive;
            break :blk .negative;
        };

        // Front sector
        const front_sector: ?u16 = if (rl.sidenum[0] >= 0)
            sides[@intCast(rl.sidenum[0])].sector
        else
            null;

        // Back sector
        const back_sector: ?u16 = if (rl.sidenum[1] >= 0)
            sides[@intCast(rl.sidenum[1])].sector
        else
            null;

        // Bounding box
        var bbox: [4]Fixed = undefined;
        if (vertices[v1_idx].x.lt(vertices[v2_idx].x)) {
            bbox[2] = vertices[v1_idx].x; // BOXLEFT
            bbox[3] = vertices[v2_idx].x; // BOXRIGHT
        } else {
            bbox[2] = vertices[v2_idx].x;
            bbox[3] = vertices[v1_idx].x;
        }
        if (vertices[v1_idx].y.lt(vertices[v2_idx].y)) {
            bbox[1] = vertices[v1_idx].y; // BOXBOTTOM
            bbox[0] = vertices[v2_idx].y; // BOXTOP
        } else {
            bbox[1] = vertices[v2_idx].y;
            bbox[0] = vertices[v1_idx].y;
        }

        lines[i] = .{
            .v1 = v1_idx,
            .v2 = v2_idx,
            .flags = rl.flags,
            .special = rl.special,
            .tag = rl.tag,
            .sidenum = rl.sidenum,
            .dx = dx,
            .dy = dy,
            .slopetype = slopetype,
            .frontsector = front_sector,
            .backsector = back_sector,
            .bbox = bbox,
        };
    }

    // Load segs
    const raw_segs = w.lumpAs(segs_lump, defs.MapSeg);
    const segs = alloc.alloc(Seg, raw_segs.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(segs);
    for (raw_segs, 0..) |rs, i| {
        const linedef_idx: u16 = @intCast(rs.linedef);
        const line = lines[linedef_idx];
        const side_idx: u16 = @intCast(rs.side);

        const sidedef_idx: u16 = @intCast(line.sidenum[side_idx]);

        segs[i] = .{
            .v1 = @intCast(rs.v1),
            .v2 = @intCast(rs.v2),
            .offset = Fixed.fromInt(@as(i32, rs.offset)),
            .angle = @as(u32, @as(u16, @bitCast(rs.angle))) << 16,
            .sidedef = sidedef_idx,
            .linedef = linedef_idx,
            .frontsector = if (side_idx == 0) line.frontsector else line.backsector,
            .backsector = if (side_idx == 0) line.backsector else line.frontsector,
        };
    }

    // Load subsectors
    const raw_ssectors = w.lumpAs(ssectors_lump, defs.MapSubsector);
    const subsectors = alloc.alloc(Subsector, raw_ssectors.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(subsectors);
    for (raw_ssectors, 0..) |rs, i| {
        const first: u16 = @intCast(rs.firstseg);
        subsectors[i] = .{
            .numlines = @intCast(rs.numsegs),
            .firstline = first,
            .sector = if (first < segs.len) segs[first].frontsector else null,
        };
    }

    // Load nodes
    const raw_nodes = w.lumpAs(nodes_lump, defs.MapNode);
    const nodes = alloc.alloc(Node, raw_nodes.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(nodes);
    for (raw_nodes, 0..) |rn, i| {
        var node: Node = .{
            .x = Fixed.fromInt(@as(i32, rn.x)),
            .y = Fixed.fromInt(@as(i32, rn.y)),
            .dx = Fixed.fromInt(@as(i32, rn.dx)),
            .dy = Fixed.fromInt(@as(i32, rn.dy)),
            .bbox = undefined,
            .children = rn.children,
        };
        // Convert bounding boxes
        for (0..2) |side| {
            for (0..4) |coord| {
                node.bbox[side][coord] = Fixed.fromInt(@as(i32, rn.bbox[side][coord]));
            }
        }
        nodes[i] = node;
    }

    // Load things (copy raw data)
    const raw_things = w.lumpAs(things_lump, defs.MapThing);
    const things = alloc.alloc(defs.MapThing, raw_things.len) catch return SetupError.OutOfMemory;
    errdefer alloc.free(things);
    for (raw_things, 0..) |rt, i| {
        things[i] = rt;
    }

    // Get blockmap and reject raw data (keep as slices into WAD data)
    const reject_lump = w.findLumpAfter("REJECT", map_lump + 1);
    const blockmap_lump = w.findLumpAfter("BLOCKMAP", map_lump + 1);

    var lvl = Level{
        .vertices = vertices,
        .sectors = sectors,
        .sides = sides,
        .lines = lines,
        .segs = segs,
        .subsectors = subsectors,
        .nodes = nodes,
        .things = things,
        .blockmap_data = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{},
        .reject_data = if (reject_lump) |rl| w.lumpData(rl) else &[_]u8{},
        .bmap_orgx = blk: {
            const bd = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{};
            if (bd.len < 8) break :blk Fixed.ZERO;
            const v: i16 = @bitCast(@as(u16, bd[0]) | (@as(u16, bd[1]) << 8));
            break :blk Fixed.fromInt(v);
        },
        .bmap_orgy = blk: {
            const bd = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{};
            if (bd.len < 8) break :blk Fixed.ZERO;
            const v: i16 = @bitCast(@as(u16, bd[2]) | (@as(u16, bd[3]) << 8));
            break :blk Fixed.fromInt(v);
        },
        .bmap_cols = blk: {
            const bd = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{};
            if (bd.len < 8) break :blk 0;
            break :blk @as(i32, @as(u16, bd[4]) | (@as(u16, bd[5]) << 8));
        },
        .bmap_rows = blk: {
            const bd = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{};
            if (bd.len < 8) break :blk 0;
            break :blk @as(i32, @as(u16, bd[6]) | (@as(u16, bd[7]) << 8));
        },
        .num_nodes = @intCast(nodes.len),
        .allocator = alloc,
        .blocklinks = blk: {
            const bd = if (blockmap_lump) |bl| w.lumpData(bl) else &[_]u8{};
            if (bd.len < 8) break :blk &[_]?*anyopaque{};
            const cols: usize = @as(u16, bd[4]) | (@as(u16, bd[5]) << 8);
            const rows: usize = @as(u16, bd[6]) | (@as(u16, bd[7]) << 8);
            const links = alloc.alloc(?*anyopaque, cols * rows) catch break :blk &[_]?*anyopaque{};
            @memset(links, null);
            break :blk links;
        },
    };

    // Per-sector blockmap bounding boxes (vanilla P_GroupLines): bbox over
    // every line touching the sector, expanded by MAXRADIUS, in block coords.
    // blockbox indices: [top, bottom, left, right] (m_bbox.h order).
    if (lvl.bmap_cols > 0 and lvl.bmap_rows > 0) {
        const MAXRADIUS: i32 = 32 * 0x10000;
        const MAPBLOCKSHIFT: u5 = 23;
        for (lvl.sectors, 0..) |*sec, si| {
            var left: i32 = std.math.maxInt(i32);
            var bottom: i32 = std.math.maxInt(i32);
            var right: i32 = std.math.minInt(i32);
            var top: i32 = std.math.minInt(i32);
            for (lvl.lines) |*li| {
                const fs = li.frontsector;
                const bs = li.backsector;
                const touches = (fs != null and fs.? == si) or
                    (bs != null and bs.? == si and (fs == null or fs.? != bs.?));
                if (!touches) continue;
                for ([2]u16{ li.v1, li.v2 }) |vi| {
                    const vx = lvl.vertices[vi].x.raw();
                    const vy = lvl.vertices[vi].y.raw();
                    if (vx < left) left = vx;
                    if (vx > right) right = vx;
                    if (vy < bottom) bottom = vy;
                    if (vy > top) top = vy;
                }
            }
            if (right < left) { // sector with no lines
                sec.blockbox = .{ 0, 0, 0, 0 };
                continue;
            }
            var block: i32 = (top - lvl.bmap_orgy.raw() + MAXRADIUS) >> MAPBLOCKSHIFT;
            sec.blockbox[0] = if (block >= lvl.bmap_rows) lvl.bmap_rows - 1 else block;
            block = (bottom - lvl.bmap_orgy.raw() - MAXRADIUS) >> MAPBLOCKSHIFT;
            sec.blockbox[1] = if (block < 0) 0 else block;
            block = (right - lvl.bmap_orgx.raw() + MAXRADIUS) >> MAPBLOCKSHIFT;
            sec.blockbox[3] = if (block >= lvl.bmap_cols) lvl.bmap_cols - 1 else block;
            block = (left - lvl.bmap_orgx.raw() - MAXRADIUS) >> MAPBLOCKSHIFT;
            sec.blockbox[2] = if (block < 0) 0 else block;
        }
    }

    return lvl;
}

test "level struct sizes" {
    // Verify our runtime structs have reasonable sizes
    try std.testing.expect(@sizeOf(Vertex) > 0);
    try std.testing.expect(@sizeOf(Sector) > 0);
    try std.testing.expect(@sizeOf(Line) > 0);
    try std.testing.expect(@sizeOf(Seg) > 0);
    try std.testing.expect(@sizeOf(Subsector) > 0);
    try std.testing.expect(@sizeOf(Node) > 0);
}
