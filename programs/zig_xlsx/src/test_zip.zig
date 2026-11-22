// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Test helper: builds a STORED (uncompressed) zip archive in memory, so unit
//! tests can hand the readers a synthetic .xlsx without fixture files.

const std = @import("std");

pub const File = struct {
    name: []const u8,
    data: []const u8,
};

/// A zip of `files`, every entry stored. Caller frees with `allocator`.
pub fn build(allocator: std.mem.Allocator, files: []const File) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const offsets = try allocator.alloc(u32, files.len);
    defer allocator.free(offsets);

    for (files, 0..) |f, i| {
        offsets[i] = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(f.data);
        try putU32(allocator, &out, 0x04034b50);
        try putU16(allocator, &out, 20); // version needed
        try putU16(allocator, &out, 0); // flags
        try putU16(allocator, &out, 0); // method: stored
        try putU16(allocator, &out, 0); // time
        try putU16(allocator, &out, 0); // date
        try putU32(allocator, &out, crc);
        try putU32(allocator, &out, @intCast(f.data.len));
        try putU32(allocator, &out, @intCast(f.data.len));
        try putU16(allocator, &out, @intCast(f.name.len));
        try putU16(allocator, &out, 0); // extra length
        try out.appendSlice(allocator, f.name);
        try out.appendSlice(allocator, f.data);
    }

    const cd_start: u32 = @intCast(out.items.len);
    for (files, 0..) |f, i| {
        const crc = std.hash.Crc32.hash(f.data);
        try putU32(allocator, &out, 0x02014b50);
        try putU16(allocator, &out, 20); // version made by
        try putU16(allocator, &out, 20); // version needed
        try putU16(allocator, &out, 0); // flags
        try putU16(allocator, &out, 0); // method
        try putU16(allocator, &out, 0); // time
        try putU16(allocator, &out, 0); // date
        try putU32(allocator, &out, crc);
        try putU32(allocator, &out, @intCast(f.data.len));
        try putU32(allocator, &out, @intCast(f.data.len));
        try putU16(allocator, &out, @intCast(f.name.len));
        try putU16(allocator, &out, 0); // extra
        try putU16(allocator, &out, 0); // comment
        try putU16(allocator, &out, 0); // disk
        try putU16(allocator, &out, 0); // internal attrs
        try putU32(allocator, &out, 0); // external attrs
        try putU32(allocator, &out, offsets[i]);
        try out.appendSlice(allocator, f.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.items.len)) - cd_start;

    try putU32(allocator, &out, 0x06054b50);
    try putU16(allocator, &out, 0); // this disk
    try putU16(allocator, &out, 0); // cd disk
    try putU16(allocator, &out, @intCast(files.len));
    try putU16(allocator, &out, @intCast(files.len));
    try putU32(allocator, &out, cd_size);
    try putU32(allocator, &out, cd_start);
    try putU16(allocator, &out, 0); // comment length

    return out.toOwnedSlice(allocator);
}

fn putU16(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(allocator, &b);
}

fn putU32(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(allocator, &b);
}
