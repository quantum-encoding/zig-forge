//! Header Generator Tool
//!
//! Extracts the C_HEADER constant from quantum_vault_ffi.zig and writes it
//! to include/quantum_vault.h

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;
const ffi = @import("quantum_vault_ffi");

pub fn main() !void {
    const io = Io.Threaded.global_single_threaded.io();
    const cwd = Dir.cwd();

    // Create include directory
    cwd.createDir(io, "include", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write header file
    const file = try cwd.createFile(io, "include/quantum_vault.h", .{});
    defer file.close(io);

    // Write the header content
    try file.writeStreamingAll(io, ffi.C_HEADER);

    // Print success message using std.fmt with a buffer
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Generated include/quantum_vault.h ({d} bytes)\n", .{ffi.C_HEADER.len}) catch "Generated include/quantum_vault.h\n";

    const stdout = Io.File.stdout();
    try stdout.writeStreamingAll(io, msg);
}
