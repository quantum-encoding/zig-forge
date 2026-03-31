//! Header Generator Tool
//!
//! Extracts the C_HEADER constant from ffi.zig and writes it
//! to include/zigqr.h

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const ffi = @import("zigqr_ffi");

pub fn main() !void {
    const io = Io.Threaded.global_single_threaded.io();
    const cwd = Dir.cwd();

    // Create include directory
    cwd.createDir(io, "include", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write header file
    const file = try cwd.createFile(io, "include/zigqr.h", .{});
    defer file.close(io);

    try file.writeStreamingAll(io, ffi.C_HEADER);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Generated include/zigqr.h ({d} bytes)\n", .{ffi.C_HEADER.len}) catch "Generated include/zigqr.h\n";

    const stdout = Io.File.stdout();
    try stdout.writeStreamingAll(io, msg);
}
