//! zig_doom/src/bbox.zig
//!
//! Bounding box operations.
//! Translated from: linuxdoom-1.10/m_bbox.c, m_bbox.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const Fixed = @import("fixed.zig").Fixed;

// Bounding box array indices
pub const BOXTOP = 0;
pub const BOXBOTTOM = 1;
pub const BOXLEFT = 2;
pub const BOXRIGHT = 3;

pub const BBox = [4]Fixed;

pub fn clear(box: *BBox) void {
    box[BOXTOP] = Fixed.MIN;
    box[BOXRIGHT] = Fixed.MIN;
    box[BOXBOTTOM] = Fixed.MAX;
    box[BOXLEFT] = Fixed.MAX;
}

pub fn addPoint(box: *BBox, x: Fixed, y: Fixed) void {
    if (x.lt(box[BOXLEFT])) box[BOXLEFT] = x;
    if (x.gt(box[BOXRIGHT])) box[BOXRIGHT] = x;
    if (y.lt(box[BOXBOTTOM])) box[BOXBOTTOM] = y;
    if (y.gt(box[BOXTOP])) box[BOXTOP] = y;
}

test "bbox clear and add" {
    var box: BBox = undefined;
    clear(&box);

    addPoint(&box, Fixed.fromInt(10), Fixed.fromInt(20));
    try std.testing.expectEqual(@as(i32, 10), box[BOXLEFT].toInt());
    try std.testing.expectEqual(@as(i32, 10), box[BOXRIGHT].toInt());
    try std.testing.expectEqual(@as(i32, 20), box[BOXBOTTOM].toInt());
    try std.testing.expectEqual(@as(i32, 20), box[BOXTOP].toInt());

    addPoint(&box, Fixed.fromInt(-5), Fixed.fromInt(30));
    try std.testing.expectEqual(@as(i32, -5), box[BOXLEFT].toInt());
    try std.testing.expectEqual(@as(i32, 10), box[BOXRIGHT].toInt());
    try std.testing.expectEqual(@as(i32, 20), box[BOXBOTTOM].toInt());
    try std.testing.expectEqual(@as(i32, 30), box[BOXTOP].toInt());
}
