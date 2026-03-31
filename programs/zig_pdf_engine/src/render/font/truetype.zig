// TrueType/OpenType Font Parser
//
// Parses TrueType (.ttf) and OpenType (.otf) font files.
// Extracts glyph outlines, metrics, and character mappings.
//
// Key tables parsed:
// - head: Font header (units per em, bounds)
// - hhea: Horizontal header (ascender, descender)
// - hmtx: Horizontal metrics (advance width, left bearing)
// - maxp: Maximum profile (num glyphs)
// - cmap: Character to glyph mapping
// - loca: Index to location table
// - glyf: Glyph data (outlines)
// - name: Font naming info

const std = @import("std");

/// Fixed-point number (16.16)
pub const Fixed = struct {
    value: i32,

    pub fn toFloat(self: Fixed) f32 {
        return @as(f32, @floatFromInt(self.value)) / 65536.0;
    }

    pub fn fromBigEndian(bytes: *const [4]u8) Fixed {
        return .{ .value = @bitCast(std.mem.bigToNative(u32, @as(*const u32, @ptrCast(bytes)).*)) };
    }
};

/// F2Dot14 fixed-point number (2.14)
pub const F2Dot14 = struct {
    value: i16,

    pub fn toFloat(self: F2Dot14) f32 {
        return @as(f32, @floatFromInt(self.value)) / 16384.0;
    }
};

/// Table directory entry
pub const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

/// Font head table
pub const HeadTable = struct {
    units_per_em: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    index_to_loc_format: i16, // 0 = short, 1 = long
    // ... more fields available
};

/// Font hhea table (horizontal header)
pub const HheaTable = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    advance_width_max: u16,
    num_of_long_hor_metrics: u16,
};

/// Font maxp table
pub const MaxpTable = struct {
    num_glyphs: u16,
};

/// Glyph horizontal metrics
pub const HMetrics = struct {
    advance_width: u16,
    left_side_bearing: i16,
};

/// Point in glyph outline (in font units)
pub const GlyphPoint = struct {
    x: i16,
    y: i16,
    on_curve: bool, // True = on-curve point, false = control point
};

/// Simple glyph (contour-based outline)
pub const SimpleGlyph = struct {
    contour_end_points: []const u16,
    points: []const GlyphPoint,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

/// Compound glyph component
pub const GlyphComponent = struct {
    glyph_index: u16,
    // Transformation
    a: f32, // Scale X
    b: f32, // Skew Y
    c: f32, // Skew X
    d: f32, // Scale Y
    e: f32, // Translate X
    f: f32, // Translate Y
};

/// Glyph data
pub const Glyph = union(enum) {
    empty, // No outline (e.g., space character)
    simple: SimpleGlyph,
    compound: []const GlyphComponent,
};

/// TrueType/OpenType font parser
pub const Font = struct {
    data: []const u8,
    allocator: std.mem.Allocator,

    // Table offsets
    head_offset: ?u32 = null,
    hhea_offset: ?u32 = null,
    hmtx_offset: ?u32 = null,
    maxp_offset: ?u32 = null,
    cmap_offset: ?u32 = null,
    loca_offset: ?u32 = null,
    glyf_offset: ?u32 = null,
    name_offset: ?u32 = null,

    // Parsed header info
    head: ?HeadTable = null,
    hhea: ?HheaTable = null,
    maxp: ?MaxpTable = null,

    // Caches
    cmap_cache: ?CmapCache = null,
    loca_cache: ?[]u32 = null,

    const CmapCache = struct {
        format: u16,
        offset: u32,
        // For format 4
        seg_count: u16,
        end_codes: []const u16,
        start_codes: []const u16,
        id_deltas: []const i16,
        id_range_offsets: []const u16,
        glyph_ids_offset: u32,
    };

    /// Initialize font from data
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Font {
        if (data.len < 12) return error.InvalidFont;

        var font = Font{
            .data = data,
            .allocator = allocator,
        };

        try font.parseTableDirectory();
        try font.parseHeaders();

        return font;
    }

    pub fn deinit(self: *Font) void {
        if (self.loca_cache) |cache| {
            self.allocator.free(cache);
        }
    }

    /// Parse the table directory to find table offsets
    fn parseTableDirectory(self: *Font) !void {
        // Check signature
        const sfnt_version = self.readU32(0);
        if (sfnt_version != 0x00010000 and sfnt_version != 0x4F54544F) {
            // Not TrueType (0x00010000) or OpenType CFF (OTTO)
            return error.InvalidFont;
        }

        const num_tables = self.readU16(4);

        // Parse each table record
        var offset: usize = 12; // After header
        for (0..num_tables) |_| {
            if (offset + 16 > self.data.len) break;

            const tag = self.data[offset..][0..4].*;
            const table_offset = self.readU32(@intCast(offset + 8));
            // const table_length = self.readU32(offset + 12);

            if (std.mem.eql(u8, &tag, "head")) self.head_offset = table_offset;
            if (std.mem.eql(u8, &tag, "hhea")) self.hhea_offset = table_offset;
            if (std.mem.eql(u8, &tag, "hmtx")) self.hmtx_offset = table_offset;
            if (std.mem.eql(u8, &tag, "maxp")) self.maxp_offset = table_offset;
            if (std.mem.eql(u8, &tag, "cmap")) self.cmap_offset = table_offset;
            if (std.mem.eql(u8, &tag, "loca")) self.loca_offset = table_offset;
            if (std.mem.eql(u8, &tag, "glyf")) self.glyf_offset = table_offset;
            if (std.mem.eql(u8, &tag, "name")) self.name_offset = table_offset;

            offset += 16;
        }
    }

    /// Parse header tables
    fn parseHeaders(self: *Font) !void {
        // Parse head table
        if (self.head_offset) |off| {
            self.head = .{
                .units_per_em = self.readU16(off + 18),
                .x_min = self.readI16(off + 36),
                .y_min = self.readI16(off + 38),
                .x_max = self.readI16(off + 40),
                .y_max = self.readI16(off + 42),
                .index_to_loc_format = self.readI16(off + 50),
            };
        }

        // Parse hhea table
        if (self.hhea_offset) |off| {
            self.hhea = .{
                .ascender = self.readI16(off + 4),
                .descender = self.readI16(off + 6),
                .line_gap = self.readI16(off + 8),
                .advance_width_max = self.readU16(off + 10),
                .num_of_long_hor_metrics = self.readU16(off + 34),
            };
        }

        // Parse maxp table
        if (self.maxp_offset) |off| {
            self.maxp = .{
                .num_glyphs = self.readU16(off + 4),
            };
        }
    }

    /// Get units per em (for scaling)
    pub fn getUnitsPerEm(self: *const Font) u16 {
        return if (self.head) |h| h.units_per_em else 1000;
    }

    /// Get ascender in font units
    pub fn getAscender(self: *const Font) i16 {
        return if (self.hhea) |h| h.ascender else 0;
    }

    /// Get descender in font units (usually negative)
    pub fn getDescender(self: *const Font) i16 {
        return if (self.hhea) |h| h.descender else 0;
    }

    /// Get number of glyphs
    pub fn getNumGlyphs(self: *const Font) u16 {
        return if (self.maxp) |m| m.num_glyphs else 0;
    }

    /// Map character code to glyph index
    pub fn getGlyphIndex(self: *Font, char_code: u32) !u16 {
        // Initialize cmap cache if needed
        if (self.cmap_cache == null) {
            try self.parseCmap();
        }

        const cache = self.cmap_cache orelse return 0;

        switch (cache.format) {
            4 => return self.cmapFormat4Lookup(char_code, cache),
            12 => return self.cmapFormat12Lookup(char_code, cache),
            else => return 0,
        }
    }

    /// Parse cmap table
    fn parseCmap(self: *Font) !void {
        const cmap_off = self.cmap_offset orelse return error.NoCmapTable;

        const num_tables = self.readU16(cmap_off + 2);

        // Find best subtable (prefer format 12 or 4 for Unicode)
        var best_offset: ?u32 = null;
        var best_format: u16 = 0;

        var i: u32 = 0;
        while (i < num_tables) : (i += 1) {
            const record_off = cmap_off + 4 + i * 8;
            const platform_id = self.readU16(record_off);
            const encoding_id = self.readU16(record_off + 2);
            const subtable_offset = self.readU32(record_off + 4);

            const subtable_off = cmap_off + subtable_offset;
            const format = self.readU16(subtable_off);

            // Prefer Unicode platform (0 or 3)
            if ((platform_id == 0 or (platform_id == 3 and encoding_id == 1) or
                (platform_id == 3 and encoding_id == 10)))
            {
                if (format == 12 or (format == 4 and best_format != 12)) {
                    best_offset = subtable_off;
                    best_format = format;
                }
            }
        }

        if (best_offset == null) return error.NoUnicodeCmap;

        self.cmap_cache = .{
            .format = best_format,
            .offset = best_offset.?,
            .seg_count = 0,
            .end_codes = &[_]u16{},
            .start_codes = &[_]u16{},
            .id_deltas = &[_]i16{},
            .id_range_offsets = &[_]u16{},
            .glyph_ids_offset = 0,
        };

        // Parse format-specific data
        if (best_format == 4) {
            const off = best_offset.?;
            const seg_count_x2 = self.readU16(off + 6);
            self.cmap_cache.?.seg_count = seg_count_x2 / 2;

            // The arrays are inline in the font data, we'll read them directly
            // Store offset for lookup
            self.cmap_cache.?.glyph_ids_offset = off + 16 + seg_count_x2 * 4;
        }
    }

    /// cmap format 4 lookup
    fn cmapFormat4Lookup(self: *const Font, char_code: u32, cache: CmapCache) u16 {
        if (char_code > 0xFFFF) return 0;
        const c: u16 = @intCast(char_code);

        const off = cache.offset;
        const seg_count = cache.seg_count;

        // Binary search through segments
        var lo: u16 = 0;
        var hi: u16 = seg_count;

        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const end_code = self.readU16(off + 14 + @as(u32, mid) * 2);

            if (c > end_code) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo >= seg_count) return 0;

        const seg_idx: u32 = lo;
        const end_code = self.readU16(off + 14 + seg_idx * 2);
        const start_off = off + 16 + @as(u32, seg_count) * 2; // Skip reserved word
        const start_code = self.readU16(start_off + seg_idx * 2);

        if (c < start_code or c > end_code) return 0;

        const delta_off = start_off + @as(u32, seg_count) * 2;
        const id_delta = self.readI16(delta_off + seg_idx * 2);

        const range_off_base = delta_off + @as(u32, seg_count) * 2;
        const id_range_offset = self.readU16(range_off_base + seg_idx * 2);

        if (id_range_offset == 0) {
            // Simple offset
            return @intCast(@as(i32, c) + @as(i32, id_delta));
        } else {
            // Indirect through glyph ID array
            const glyph_off = range_off_base + seg_idx * 2 + id_range_offset + (c - start_code) * 2;
            const glyph_id = self.readU16(glyph_off);
            if (glyph_id == 0) return 0;
            return @intCast(@as(i32, glyph_id) + @as(i32, id_delta));
        }
    }

    /// cmap format 12 lookup
    fn cmapFormat12Lookup(self: *const Font, char_code: u32, cache: CmapCache) u16 {
        const off = cache.offset;
        const num_groups = self.readU32(off + 12);

        // Binary search through groups
        var lo: u32 = 0;
        var hi: u32 = num_groups;

        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const group_off = off + 16 + mid * 12;

            const start_char = self.readU32(group_off);
            const end_char = self.readU32(group_off + 4);

            if (char_code < start_char) {
                hi = mid;
            } else if (char_code > end_char) {
                lo = mid + 1;
            } else {
                // Found
                const start_glyph = self.readU32(group_off + 8);
                return @intCast(start_glyph + (char_code - start_char));
            }
        }

        return 0;
    }

    /// Get horizontal metrics for a glyph
    pub fn getHMetrics(self: *const Font, glyph_index: u16) HMetrics {
        const hmtx_off = self.hmtx_offset orelse return .{ .advance_width = 0, .left_side_bearing = 0 };
        const hhea = self.hhea orelse return .{ .advance_width = 0, .left_side_bearing = 0 };

        if (glyph_index < hhea.num_of_long_hor_metrics) {
            // Full record
            const record_off = hmtx_off + @as(u32, glyph_index) * 4;
            return .{
                .advance_width = self.readU16(record_off),
                .left_side_bearing = self.readI16(record_off + 2),
            };
        } else {
            // Use last advance width, separate LSB
            const last_width_off = hmtx_off + (@as(u32, hhea.num_of_long_hor_metrics) - 1) * 4;
            const lsb_off = hmtx_off + @as(u32, hhea.num_of_long_hor_metrics) * 4 +
                (@as(u32, glyph_index) - @as(u32, hhea.num_of_long_hor_metrics)) * 2;

            return .{
                .advance_width = self.readU16(last_width_off),
                .left_side_bearing = self.readI16(lsb_off),
            };
        }
    }

    /// Get glyph outline
    pub fn getGlyph(self: *Font, glyph_index: u16) !Glyph {
        const glyf_off = self.glyf_offset orelse return .empty;
        const loca = try self.getLocaTable();

        if (glyph_index >= loca.len - 1) return .empty;

        const glyph_start = loca[glyph_index];
        const glyph_end = loca[glyph_index + 1];

        if (glyph_start == glyph_end) return .empty; // Empty glyph

        const off = glyf_off + glyph_start;
        const num_contours = self.readI16(off);

        if (num_contours >= 0) {
            return self.parseSimpleGlyph(off, @intCast(num_contours));
        } else {
            return self.parseCompoundGlyph(off);
        }
    }

    /// Get loca table (builds cache)
    fn getLocaTable(self: *Font) ![]u32 {
        if (self.loca_cache) |cache| return cache;

        const loca_off = self.loca_offset orelse return error.NoLocaTable;
        const head = self.head orelse return error.NoHeadTable;
        const maxp = self.maxp orelse return error.NoMaxpTable;

        const num_glyphs: u32 = maxp.num_glyphs;
        var loca = try self.allocator.alloc(u32, num_glyphs + 1);
        errdefer self.allocator.free(loca);

        if (head.index_to_loc_format == 0) {
            // Short format (16-bit offsets, multiply by 2)
            for (0..num_glyphs + 1) |i| {
                loca[i] = @as(u32, self.readU16(loca_off + @as(u32, @intCast(i)) * 2)) * 2;
            }
        } else {
            // Long format (32-bit offsets)
            for (0..num_glyphs + 1) |i| {
                loca[i] = self.readU32(loca_off + @as(u32, @intCast(i)) * 4);
            }
        }

        self.loca_cache = loca;
        return loca;
    }

    /// Parse a simple glyph
    fn parseSimpleGlyph(self: *Font, off: u32, num_contours: u16) !Glyph {
        // Read bounding box
        const x_min = self.readI16(off + 2);
        const y_min = self.readI16(off + 4);
        const x_max = self.readI16(off + 6);
        const y_max = self.readI16(off + 8);

        // Read end points of contours
        var end_points = try self.allocator.alloc(u16, num_contours);
        errdefer self.allocator.free(end_points);

        var contour_off = off + 10;
        for (0..num_contours) |i| {
            end_points[i] = self.readU16(contour_off + @as(u32, @intCast(i)) * 2);
        }
        contour_off += @as(u32, num_contours) * 2;

        if (num_contours == 0) {
            return .{ .simple = .{
                .contour_end_points = end_points,
                .points = &[_]GlyphPoint{},
                .x_min = x_min,
                .y_min = y_min,
                .x_max = x_max,
                .y_max = y_max,
            } };
        }

        const num_points: u32 = @as(u32, end_points[num_contours - 1]) + 1;

        // Skip instructions
        const instruction_length = self.readU16(contour_off);
        contour_off += 2 + instruction_length;

        // Read flags
        var flags = try self.allocator.alloc(u8, num_points);
        defer self.allocator.free(flags);

        var flag_idx: u32 = 0;
        while (flag_idx < num_points) {
            if (contour_off >= self.data.len) break;
            const flag = self.data[contour_off];
            contour_off += 1;

            flags[flag_idx] = flag;
            flag_idx += 1;

            // Check repeat flag
            if ((flag & 0x08) != 0 and flag_idx < num_points) {
                if (contour_off >= self.data.len) break;
                const repeat_count = self.data[contour_off];
                contour_off += 1;

                var r: u8 = 0;
                while (r < repeat_count and flag_idx < num_points) : (r += 1) {
                    flags[flag_idx] = flag;
                    flag_idx += 1;
                }
            }
        }

        // Read X coordinates
        var points = try self.allocator.alloc(GlyphPoint, num_points);
        errdefer self.allocator.free(points);

        var x: i16 = 0;
        for (0..num_points) |i| {
            const flag = flags[i];
            if ((flag & 0x02) != 0) {
                // 1-byte X
                if (contour_off >= self.data.len) break;
                const dx = self.data[contour_off];
                contour_off += 1;
                if ((flag & 0x10) != 0) {
                    x += @as(i16, dx);
                } else {
                    x -= @as(i16, dx);
                }
            } else if ((flag & 0x10) == 0) {
                // 2-byte X
                x += self.readI16(contour_off);
                contour_off += 2;
            }
            // else: same as previous
            points[i].x = x;
            points[i].on_curve = (flag & 0x01) != 0;
        }

        // Read Y coordinates
        var y: i16 = 0;
        for (0..num_points) |i| {
            const flag = flags[i];
            if ((flag & 0x04) != 0) {
                // 1-byte Y
                if (contour_off >= self.data.len) break;
                const dy = self.data[contour_off];
                contour_off += 1;
                if ((flag & 0x20) != 0) {
                    y += @as(i16, dy);
                } else {
                    y -= @as(i16, dy);
                }
            } else if ((flag & 0x20) == 0) {
                // 2-byte Y
                y += self.readI16(contour_off);
                contour_off += 2;
            }
            points[i].y = y;
        }

        return .{ .simple = .{
            .contour_end_points = end_points,
            .points = points,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        } };
    }

    /// Parse a compound glyph
    fn parseCompoundGlyph(self: *Font, off: u32) !Glyph {
        var components: std.ArrayList(GlyphComponent) = .empty;
        errdefer components.deinit(self.allocator);

        var comp_off = off + 10; // Skip header

        const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
        const ARGS_ARE_XY_VALUES: u16 = 0x0002;
        const WE_HAVE_A_SCALE: u16 = 0x0008;
        const MORE_COMPONENTS: u16 = 0x0020;
        const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
        const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

        var flags: u16 = MORE_COMPONENTS;

        while ((flags & MORE_COMPONENTS) != 0) {
            flags = self.readU16(comp_off);
            comp_off += 2;

            const glyph_idx = self.readU16(comp_off);
            comp_off += 2;

            var component = GlyphComponent{
                .glyph_index = glyph_idx,
                .a = 1,
                .b = 0,
                .c = 0,
                .d = 1,
                .e = 0,
                .f = 0,
            };

            // Read arguments
            if ((flags & ARG_1_AND_2_ARE_WORDS) != 0) {
                if ((flags & ARGS_ARE_XY_VALUES) != 0) {
                    component.e = @floatFromInt(self.readI16(comp_off));
                    component.f = @floatFromInt(self.readI16(comp_off + 2));
                }
                comp_off += 4;
            } else {
                if ((flags & ARGS_ARE_XY_VALUES) != 0) {
                    component.e = @floatFromInt(@as(i8, @bitCast(self.data[comp_off])));
                    component.f = @floatFromInt(@as(i8, @bitCast(self.data[comp_off + 1])));
                }
                comp_off += 2;
            }

            // Read transformation
            if ((flags & WE_HAVE_A_SCALE) != 0) {
                const scale = F2Dot14{ .value = self.readI16(comp_off) };
                component.a = scale.toFloat();
                component.d = component.a;
                comp_off += 2;
            } else if ((flags & WE_HAVE_AN_X_AND_Y_SCALE) != 0) {
                component.a = (F2Dot14{ .value = self.readI16(comp_off) }).toFloat();
                component.d = (F2Dot14{ .value = self.readI16(comp_off + 2) }).toFloat();
                comp_off += 4;
            } else if ((flags & WE_HAVE_A_TWO_BY_TWO) != 0) {
                component.a = (F2Dot14{ .value = self.readI16(comp_off) }).toFloat();
                component.b = (F2Dot14{ .value = self.readI16(comp_off + 2) }).toFloat();
                component.c = (F2Dot14{ .value = self.readI16(comp_off + 4) }).toFloat();
                component.d = (F2Dot14{ .value = self.readI16(comp_off + 6) }).toFloat();
                comp_off += 8;
            }

            try components.append(self.allocator, component);
        }

        return .{ .compound = try components.toOwnedSlice(self.allocator) };
    }

    // === Byte reading helpers ===

    fn readU16(self: *const Font, offset: u32) u16 {
        if (offset + 2 > self.data.len) return 0;
        return std.mem.bigToNative(u16, @as(*const u16, @alignCast(@ptrCast(self.data.ptr + offset))).*);
    }

    fn readI16(self: *const Font, offset: u32) i16 {
        return @bitCast(self.readU16(offset));
    }

    fn readU32(self: *const Font, offset: u32) u32 {
        if (offset + 4 > self.data.len) return 0;
        return std.mem.bigToNative(u32, @as(*const u32, @alignCast(@ptrCast(self.data.ptr + offset))).*);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "fixed point conversion" {
    const fixed = Fixed{ .value = 0x00020000 }; // 2.0
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), fixed.toFloat(), 0.001);

    const f2dot14 = F2Dot14{ .value = 0x4000 }; // 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f2dot14.toFloat(), 0.001);
}
