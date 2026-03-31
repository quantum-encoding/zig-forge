//! zig_doom/src/render/data.zig
//!
//! Texture, flat, and colormap loading from WAD.
//! Translated from: linuxdoom-1.10/r_data.c, r_data.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const Wad = @import("../wad.zig").Wad;
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;

// ============================================================================
// Texture structures
// ============================================================================

pub const TexturePatch = struct {
    originx: i16,
    originy: i16,
    patch_lump: usize, // lump number in WAD
};

pub const Texture = struct {
    name: [8]u8,
    width: u16,
    height: u16,
    patches: []TexturePatch,
    /// Column data for each x position. null = not yet composited.
    columns: ?[]?[]const u8,
    /// Composited texture data buffer
    composite: ?[]u8,
    /// Width mask for power-of-2 textures
    widthmask: u16,
};

pub const Flat = struct {
    lump: usize, // WAD lump number
};

pub const SpriteFrame = struct {
    rotate: bool,
    lump: [8]usize, // Lump number for each rotation (0-7), or just [0] for non-rotating
    flip: [8]bool, // Flip horizontally?
};

pub const SpriteDef = struct {
    name: [4]u8,
    frames: []SpriteFrame,
};

// ============================================================================
// Texture / render data store
// ============================================================================

pub const RenderData = struct {
    textures: []Texture,
    num_textures: usize,
    flats: []Flat,
    num_flats: usize,
    flat_start: usize, // first flat lump
    flat_end: usize, // last flat lump + 1
    sprite_start: usize,
    sprite_end: usize,
    colormaps: []const u8, // 34 * 256 bytes
    patchnames: []usize, // lump numbers for PNAMES
    allocator: std.mem.Allocator,
    wad: *const Wad,

    // Texture name lookups (linear search — DOOM had ~400 textures max)

    pub fn init(wad: *const Wad, alloc: std.mem.Allocator) !RenderData {
        var self = RenderData{
            .textures = &[_]Texture{},
            .num_textures = 0,
            .flats = &[_]Flat{},
            .num_flats = 0,
            .flat_start = 0,
            .flat_end = 0,
            .sprite_start = 0,
            .sprite_end = 0,
            .colormaps = &[_]u8{},
            .patchnames = &[_]usize{},
            .allocator = alloc,
            .wad = wad,
        };

        try self.loadColormaps();
        try self.loadPatchNames();
        try self.loadTextures();
        try self.loadFlats();
        self.loadSpriteMarkers();

        return self;
    }

    pub fn deinit(self: *RenderData) void {
        for (self.textures[0..self.num_textures]) |*tex| {
            self.allocator.free(tex.patches);
            if (tex.columns) |cols| self.allocator.free(cols);
            if (tex.composite) |comp| self.allocator.free(comp);
        }
        if (self.num_textures > 0) self.allocator.free(self.textures);
        if (self.num_flats > 0) self.allocator.free(self.flats);
        if (self.patchnames.len > 0) self.allocator.free(self.patchnames);
    }

    // ========================================================================
    // Colormaps
    // ========================================================================

    fn loadColormaps(self: *RenderData) !void {
        const lump = self.wad.findLump("COLORMAP") orelse return;
        self.colormaps = self.wad.lumpData(lump);
    }

    /// Get colormap for a given light level (0=brightest, 31=darkest)
    pub fn getColormap(self: *const RenderData, lightlevel: i32) []const u8 {
        if (self.colormaps.len < 256) return self.colormaps;
        const idx: usize = @intCast(std.math.clamp(lightlevel, 0, 31));
        const start = idx * 256;
        if (start + 256 > self.colormaps.len) return self.colormaps[0..256];
        return self.colormaps[start .. start + 256];
    }

    /// Get colormap index for a given sector light + distance scale
    pub fn lightIndex(light_level: i32, scale: Fixed) i32 {
        // DOOM's light diminishing:
        // startmap = ((light_level >> 4) - 24) * 256 / NUMCOLORMAPS
        // The farther away, the darker.
        const level = @as(i32, @intCast(std.math.clamp(light_level, 0, 255)));
        const startmap = (level >> 4) -% 24;
        // Scale factor: bigger scale = closer = more light
        const scale_int: i32 = scale.raw() >> fixed.FRAC_BITS;
        var idx = startmap -% @divTrunc(scale_int, 2);
        idx = std.math.clamp(idx, 0, 31);
        return idx;
    }

    // ========================================================================
    // PNAMES — patch name directory
    // ========================================================================

    fn loadPatchNames(self: *RenderData) !void {
        const lump = self.wad.findLump("PNAMES") orelse return;
        const raw = self.wad.lumpData(lump);
        if (raw.len < 4) return;

        const count: usize = @intCast(readI32(raw, 0));
        self.patchnames = try self.allocator.alloc(usize, count);

        for (0..count) |i| {
            const name_off = 4 + i * 8;
            if (name_off + 8 > raw.len) {
                self.patchnames[i] = 0;
                continue;
            }
            var name: [8]u8 = undefined;
            @memcpy(&name, raw[name_off .. name_off + 8]);
            // Uppercase and null-terminate for lookup
            for (&name) |*ch| {
                if (ch.* >= 'a' and ch.* <= 'z') ch.* -= 32;
            }
            self.patchnames[i] = self.wad.findLump(lumpNameStr(&name)) orelse 0;
        }
    }

    // ========================================================================
    // Textures (TEXTURE1, TEXTURE2)
    // ========================================================================

    fn loadTextures(self: *RenderData) !void {
        const tex1_lump = self.wad.findLump("TEXTURE1");
        const tex2_lump = self.wad.findLump("TEXTURE2");

        var count1: usize = 0;
        var count2: usize = 0;

        if (tex1_lump) |l| {
            const raw = self.wad.lumpData(l);
            if (raw.len >= 4) count1 = @intCast(readI32(raw, 0));
        }
        if (tex2_lump) |l| {
            const raw = self.wad.lumpData(l);
            if (raw.len >= 4) count2 = @intCast(readI32(raw, 0));
        }

        const total = count1 + count2;
        if (total == 0) return;

        self.textures = try self.allocator.alloc(Texture, total);
        self.num_textures = total;

        var tex_idx: usize = 0;
        if (tex1_lump) |l| {
            tex_idx = try self.parseTextureList(l, tex_idx);
        }
        if (tex2_lump) |l| {
            tex_idx = try self.parseTextureList(l, tex_idx);
        }
    }

    fn parseTextureList(self: *RenderData, lump: usize, start_idx: usize) !usize {
        const raw = self.wad.lumpData(lump);
        if (raw.len < 4) return start_idx;

        const count: usize = @intCast(readI32(raw, 0));
        var idx = start_idx;

        for (0..count) |i| {
            const off_pos = 4 + i * 4;
            if (off_pos + 4 > raw.len) break;
            const tex_off: usize = @intCast(readI32(raw, off_pos));
            if (tex_off + 22 > raw.len) break;

            var tex: Texture = undefined;
            @memcpy(&tex.name, raw[tex_off .. tex_off + 8]);
            // Skip: masked(4 bytes = tex_off+8..12)
            tex.width = readU16(raw, tex_off + 12);
            tex.height = readU16(raw, tex_off + 14);
            // Skip: columndirectory(4 bytes = tex_off+16..20)
            const patchcount: usize = @intCast(readU16(raw, tex_off + 20));

            tex.widthmask = computeWidthMask(tex.width);
            tex.columns = null;
            tex.composite = null;

            tex.patches = try self.allocator.alloc(TexturePatch, patchcount);

            for (0..patchcount) |p| {
                const patch_off = tex_off + 22 + p * 10;
                if (patch_off + 10 > raw.len) break;
                tex.patches[p] = .{
                    .originx = readI16(raw, patch_off),
                    .originy = readI16(raw, patch_off + 2),
                    .patch_lump = blk: {
                        const pidx: usize = @intCast(readU16(raw, patch_off + 4));
                        break :blk if (pidx < self.patchnames.len) self.patchnames[pidx] else 0;
                    },
                };
            }

            if (idx < self.textures.len) {
                self.textures[idx] = tex;
                idx += 1;
            }
        }
        return idx;
    }

    // ========================================================================
    // Flats (F_START..F_END)
    // ========================================================================

    fn loadFlats(self: *RenderData) !void {
        const f_start = self.wad.findLump("F_START") orelse return;
        const f_end = self.wad.findLump("F_END") orelse return;

        self.flat_start = f_start + 1;
        self.flat_end = f_end;

        const count = self.flat_end - self.flat_start;
        if (count == 0) return;

        self.flats = try self.allocator.alloc(Flat, count);
        self.num_flats = count;

        for (0..count) |i| {
            self.flats[i] = .{ .lump = self.flat_start + i };
        }
    }

    fn loadSpriteMarkers(self: *RenderData) void {
        if (self.wad.findLump("S_START")) |s| self.sprite_start = s + 1;
        if (self.wad.findLump("S_END")) |s| self.sprite_end = s;
    }

    // ========================================================================
    // Lookup by name
    // ========================================================================

    /// Find texture number by name. Returns 0 for "-" (no texture) or not found.
    pub fn textureNumForName(self: *const RenderData, name: [8]u8) i16 {
        // "-" means no texture
        if (name[0] == '-' and (name[1] == 0 or name[1] == ' ')) return 0;

        for (self.textures[0..self.num_textures], 0..) |tex, i| {
            if (nameMatch(tex.name, name)) return @intCast(i);
        }
        return -1; // Not found — will render as 0
    }

    /// Find flat number by name
    pub fn flatNumForName(self: *const RenderData, name: [8]u8) i32 {
        for (0..self.num_flats) |i| {
            const lump = self.flats[i].lump;
            if (nameMatch(self.wad.lumps[lump].name, name)) return @intCast(i);
        }
        return -1;
    }

    /// Get flat data (64x64 = 4096 bytes of palette indices)
    pub fn getFlatData(self: *const RenderData, flat_num: i32) []const u8 {
        if (flat_num < 0 or flat_num >= @as(i32, @intCast(self.num_flats))) {
            return &[_]u8{0} ** 64; // Return minimal data
        }
        const lump = self.flats[@intCast(flat_num)].lump;
        const data = self.wad.lumpData(lump);
        if (data.len >= 4096) return data[0..4096];
        return data;
    }

    /// Generate (or return cached) composite texture column data
    pub fn getTextureColumn(self: *RenderData, tex_num: usize, col: i32) []const u8 {
        if (tex_num >= self.num_textures) return &[_]u8{};

        const tex = &self.textures[tex_num];
        const actual_col: usize = @intCast(@mod(col, @as(i32, tex.width)));

        // Ensure texture is composited
        if (tex.composite == null) {
            self.generateComposite(tex_num);
        }

        if (tex.composite) |comp| {
            const col_start = actual_col * @as(usize, tex.height);
            const col_end = col_start + @as(usize, tex.height);
            if (col_end <= comp.len) {
                return comp[col_start..col_end];
            }
        }

        return &[_]u8{};
    }

    fn generateComposite(self: *RenderData, tex_num: usize) void {
        const tex = &self.textures[tex_num];
        const size = @as(usize, tex.width) * @as(usize, tex.height);
        tex.composite = self.allocator.alloc(u8, size) catch return;
        @memset(tex.composite.?, 0);

        // Composite all patches
        for (tex.patches) |tp| {
            if (tp.patch_lump == 0) continue;
            const patch_data = self.wad.lumpData(tp.patch_lump);
            if (patch_data.len < 8) continue;

            const patch_w: i32 = @intCast(readU16(patch_data, 0));
            const patch_h = readU16(patch_data, 2);

            var pcol: i32 = 0;
            while (pcol < patch_w) : (pcol += 1) {
                const tex_col = @as(i32, tp.originx) + pcol;
                if (tex_col < 0 or tex_col >= @as(i32, tex.width)) continue;

                // Read column offset
                const off_pos: usize = @intCast(8 + pcol * 4);
                if (off_pos + 4 > patch_data.len) break;
                const col_off: usize = @intCast(readU32(patch_data, off_pos));
                if (col_off >= patch_data.len) continue;

                // Parse column posts
                var post_off = col_off;
                while (post_off < patch_data.len) {
                    const topdelta = patch_data[post_off];
                    if (topdelta == 0xFF) break;
                    post_off += 1;
                    if (post_off >= patch_data.len) break;
                    const length: usize = patch_data[post_off];
                    post_off += 2; // length + padding

                    if (post_off + length + 1 > patch_data.len) break;

                    for (0..length) |p| {
                        const tex_row = @as(i32, tp.originy) + @as(i32, topdelta) + @as(i32, @intCast(p));
                        if (tex_row >= 0 and tex_row < @as(i32, tex.height)) {
                            const dest_off = @as(usize, @intCast(tex_col)) * @as(usize, tex.height) + @as(usize, @intCast(tex_row));
                            if (dest_off < size) {
                                tex.composite.?[dest_off] = patch_data[post_off + p];
                            }
                        }
                    }

                    post_off += length + 1; // data + trailing pad
                }
            }
            _ = patch_h;
        }
    }

    /// Resolve texture/flat names in sides and sectors
    pub fn resolveNames(self: *RenderData, sides: []@import("../play/setup.zig").Side, sectors: []@import("../play/setup.zig").Sector) void {
        for (sides) |*side| {
            side.toptexture = self.textureNumForName(side.top_name);
            side.bottomtexture = self.textureNumForName(side.bottom_name);
            side.midtexture = self.textureNumForName(side.mid_name);
        }
        for (sectors) |*sec| {
            sec.floorpic = self.flatNumForName(sec.floor_name);
            sec.ceilingpic = self.flatNumForName(sec.ceiling_name);
        }
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn computeWidthMask(width: u16) u16 {
    // Find largest power-of-2 <= width, then mask = pow2 - 1
    var w: u16 = 1;
    while (w * 2 <= width) w *= 2;
    return w - 1;
}

fn nameMatch(a: [8]u8, b: [8]u8) bool {
    for (0..8) |i| {
        const ac = std.ascii.toUpper(a[i]);
        const bc = std.ascii.toUpper(b[i]);
        if (ac == 0 and bc == 0) return true;
        if (ac == 0 or bc == 0) return false;
        if (ac != bc) return false;
    }
    return true;
}

fn lumpNameStr(name: *const [8]u8) []const u8 {
    for (0..8) |i| {
        if (name[i] == 0) return name[0..i];
    }
    return name[0..8];
}

fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readI16(data: []const u8, off: usize) i16 {
    return @bitCast(readU16(data, off));
}

fn readI32(data: []const u8, off: usize) i32 {
    if (off + 4 > data.len) return 0;
    return @bitCast(@as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24));
}

fn readU32(data: []const u8, off: usize) u32 {
    return @bitCast(readI32(data, off));
}

test "compute width mask" {
    try std.testing.expectEqual(@as(u16, 63), computeWidthMask(64));
    try std.testing.expectEqual(@as(u16, 127), computeWidthMask(128));
    try std.testing.expectEqual(@as(u16, 127), computeWidthMask(200));
    try std.testing.expectEqual(@as(u16, 0), computeWidthMask(1));
}

test "name match" {
    try std.testing.expect(nameMatch("STARTAN3".*,  "STARTAN3".*));
    try std.testing.expect(nameMatch("startan3".*, "STARTAN3".*));
    try std.testing.expect(!nameMatch("STARTAN2".*, "STARTAN3".*));
    const a = [8]u8{ '-', 0, 0, 0, 0, 0, 0, 0 };
    const b = [8]u8{ '-', 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(nameMatch(a, b));
}
