//! zig_doom/src/wad.zig
//!
//! WAD file reader.
//! Translated from: linuxdoom-1.10/w_wad.c, w_wad.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! WAD format:
//!   Header: 4 bytes magic ("IWAD" or "PWAD"), 4 bytes numlumps, 4 bytes infotableofs
//!   Lump directory: array of { 4 bytes filepos, 4 bytes size, 8 bytes name }
//!   Lump data: raw bytes at filepos

const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const WadError = error{
    FileNotFound,
    ReadError,
    InvalidWad,
    LumpNotFound,
    OutOfMemory,
};

/// WAD file header (12 bytes)
const WadHeader = extern struct {
    identification: [4]u8 align(1),
    numlumps: i32 align(1),
    infotableofs: i32 align(1),
};

/// WAD directory entry (16 bytes)
const FileLump = extern struct {
    filepos: i32 align(1),
    size: i32 align(1),
    name: [8]u8,
};

/// Parsed lump info
pub const LumpInfo = struct {
    name: [8]u8,
    filepos: u32,
    size: u32,
};

pub const Wad = struct {
    lumps: []LumpInfo,
    data: []const u8, // Entire WAD file contents
    is_iwad: bool,
    allocator: std.mem.Allocator,

    /// Open and parse a WAD file
    pub fn open(path: []const u8, alloc: std.mem.Allocator) WadError!Wad {
        // Use C file I/O for Zig 0.16 compatibility
        const path_z = alloc.dupeZ(u8, path) catch return WadError.OutOfMemory;
        defer alloc.free(path_z);

        const file = c.fopen(path_z.ptr, "rb") orelse return WadError.FileNotFound;
        defer _ = c.fclose(file);

        // Get file size
        _ = c.fseek(file, 0, c.SEEK_END);
        const file_size_long = c.ftell(file);
        if (file_size_long < 0) return WadError.ReadError;
        const file_size: usize = @intCast(file_size_long);
        _ = c.fseek(file, 0, c.SEEK_SET);

        // Read entire file
        const data = alloc.alloc(u8, file_size) catch return WadError.OutOfMemory;
        errdefer alloc.free(data);

        const bytes_read = c.fread(data.ptr, 1, file_size, file);
        if (bytes_read != file_size) return WadError.ReadError;

        // Parse header
        if (file_size < @sizeOf(WadHeader)) return WadError.InvalidWad;
        const header: *align(1) const WadHeader = @ptrCast(data.ptr);

        const is_iwad = std.mem.eql(u8, &header.identification, "IWAD");
        const is_pwad = std.mem.eql(u8, &header.identification, "PWAD");
        if (!is_iwad and !is_pwad) return WadError.InvalidWad;

        const numlumps: usize = @intCast(header.numlumps);
        const infotableofs: usize = @intCast(header.infotableofs);

        // Validate directory fits in file
        const dir_size = numlumps * @sizeOf(FileLump);
        if (infotableofs + dir_size > file_size) return WadError.InvalidWad;

        // Parse lump directory
        const lumps = alloc.alloc(LumpInfo, numlumps) catch return WadError.OutOfMemory;
        errdefer alloc.free(lumps);

        const dir_bytes = data[infotableofs .. infotableofs + dir_size];
        const file_lumps: [*]align(1) const FileLump = @ptrCast(dir_bytes.ptr);

        for (0..numlumps) |i| {
            const fl = file_lumps[i];
            lumps[i] = .{
                .name = fl.name,
                .filepos = @intCast(fl.filepos),
                .size = @intCast(fl.size),
            };
        }

        return .{
            .lumps = lumps,
            .data = data,
            .is_iwad = is_iwad,
            .allocator = alloc,
        };
    }

    pub fn close(self: *Wad) void {
        self.allocator.free(self.lumps);
        self.allocator.free(self.data);
    }

    /// Find a lump by name (case-insensitive, null-padded 8-char comparison)
    pub fn findLump(self: *const Wad, name: []const u8) ?usize {
        var search: [8]u8 = [_]u8{0} ** 8;
        const len = @min(name.len, 8);
        for (0..len) |i| {
            search[i] = std.ascii.toUpper(name[i]);
        }
        // Search backwards (DOOM convention: last lump with name wins for PWADs)
        var i: usize = self.lumps.len;
        while (i > 0) {
            i -= 1;
            if (lumpNameEql(self.lumps[i].name, search)) return i;
        }
        return null;
    }

    /// Find a lump starting from a given index (for map lumps)
    pub fn findLumpAfter(self: *const Wad, name: []const u8, start: usize) ?usize {
        var search: [8]u8 = [_]u8{0} ** 8;
        const len = @min(name.len, 8);
        for (0..len) |i| {
            search[i] = std.ascii.toUpper(name[i]);
        }
        for (start..self.lumps.len) |idx| {
            if (lumpNameEql(self.lumps[idx].name, search)) return idx;
        }
        return null;
    }

    /// Get raw lump data
    pub fn lumpData(self: *const Wad, lump_num: usize) []const u8 {
        const info = self.lumps[lump_num];
        return self.data[info.filepos .. info.filepos + info.size];
    }

    /// Get lump data as a typed slice (align(1) for WAD safety)
    pub fn lumpAs(self: *const Wad, lump_num: usize, comptime T: type) []align(1) const T {
        const raw = self.lumpData(lump_num);
        const count = raw.len / @sizeOf(T);
        const typed: [*]align(1) const T = @ptrCast(raw.ptr);
        return typed[0..count];
    }

    /// Get lump name as a printable string (strip null padding)
    pub fn lumpName(self: *const Wad, lump_num: usize) []const u8 {
        return lumpNameStr(&self.lumps[lump_num].name);
    }

    /// Number of lumps
    pub fn numLumps(self: *const Wad) usize {
        return self.lumps.len;
    }

    /// Detect game mode from IWAD contents
    pub fn detectGameMode(self: *const Wad) @import("defs.zig").GameMode {
        const defs = @import("defs.zig");
        if (self.findLump("MAP01") != null) return defs.GameMode.commercial;
        if (self.findLump("E4M1") != null) return defs.GameMode.retail;
        if (self.findLump("E3M1") != null) return defs.GameMode.registered;
        if (self.findLump("E1M1") != null) return defs.GameMode.shareware;
        return defs.GameMode.indetermined;
    }
};

fn lumpNameEql(a: [8]u8, b: [8]u8) bool {
    inline for (0..8) |i| {
        const ac = std.ascii.toUpper(a[i]);
        const bc = std.ascii.toUpper(b[i]);
        if (ac != bc) return false;
        if (ac == 0) return true; // Both null-terminated at same point
    }
    return true;
}

fn lumpNameStr(name: *const [8]u8) []const u8 {
    for (0..8) |i| {
        if (name[i] == 0) return name[0..i];
    }
    return name[0..8];
}

test "lump name comparison" {
    try std.testing.expect(lumpNameEql("E1M1\x00\x00\x00\x00".*, "E1M1\x00\x00\x00\x00".*));
    try std.testing.expect(lumpNameEql("e1m1\x00\x00\x00\x00".*, "E1M1\x00\x00\x00\x00".*));
    try std.testing.expect(!lumpNameEql("E1M1\x00\x00\x00\x00".*, "E1M2\x00\x00\x00\x00".*));
}
