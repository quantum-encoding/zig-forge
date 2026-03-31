//! Output formatting for zdu
//! Supports human-readable, SI, and block-size formats

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const Options = main.Options;
const DirStat = main.DirStat;

/// Print a single entry
pub fn printEntry(entry: DirStat, options: Options) void {
    const size = calculateDisplaySize(entry, options);
    const size_str = formatSize(size, options);

    const terminator: u8 = if (options.null_terminator) 0 else '\n';

    // Use Zig 0.16 I/O API
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.print("{s}\t{s}{c}", .{ size_str, entry.path, terminator }) catch {};
    writer.interface.flush() catch {};
}

/// Print grand total
pub fn printTotal(total_size: u64, total_blocks: u64, options: Options) void {
    // Use apparent size if -b/--apparent-size, otherwise use blocks
    const raw_size = if (options.apparent_size)
        total_size
    else
        total_blocks * 512;

    const display_size = scaleByBlockSize(raw_size, options);
    const size_str = formatSize(display_size, options);

    const terminator: u8 = if (options.null_terminator) 0 else '\n';

    // Use Zig 0.16 I/O API
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.print("{s}\ttotal{c}", .{ size_str, terminator }) catch {};
    writer.interface.flush() catch {};
}

fn calculateDisplaySize(entry: DirStat, options: Options) u64 {
    const raw_size = if (options.apparent_size)
        entry.size
    else
        // blocks is in 512-byte units
        entry.blocks * 512;

    return scaleByBlockSize(raw_size, options);
}

fn scaleByBlockSize(bytes: u64, options: Options) u64 {
    if (options.human_readable or options.si) {
        return bytes; // Human-readable handles its own scaling
    }
    // Divide by block size, rounding up
    return (bytes + options.block_size - 1) / options.block_size;
}

fn formatSize(size: u64, options: Options) []const u8 {
    // Static buffer for formatting
    const S = struct {
        var buf: [32]u8 = undefined;
    };

    if (options.human_readable) {
        return formatHumanBinary(size, &S.buf);
    } else if (options.si) {
        return formatHumanSI(size, &S.buf);
    } else {
        return formatNumeric(size, &S.buf);
    }
}

fn formatNumeric(size: u64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{size}) catch "???";
}

fn formatHumanBinary(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "", "K", "M", "G", "T", "P", "E" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "???";
    } else if (size < 10) {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ size, units[unit_idx] }) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ size, units[unit_idx] }) catch "???";
    }
}

fn formatHumanSI(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "", "k", "M", "G", "T", "P", "E" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1000 and unit_idx < units.len - 1) {
        size /= 1000;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "???";
    } else if (size < 10) {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ size, units[unit_idx] }) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ size, units[unit_idx] }) catch "???";
    }
}

test "format human binary" {
    var buf: [32]u8 = undefined;

    const kb = formatHumanBinary(1024, &buf);
    try std.testing.expectEqualStrings("1.0K", kb);

    const mb = formatHumanBinary(1048576, &buf);
    try std.testing.expectEqualStrings("1.0M", mb);

    const gb = formatHumanBinary(1073741824, &buf);
    try std.testing.expectEqualStrings("1.0G", gb);
}

test "format human SI" {
    var buf: [32]u8 = undefined;

    const kb = formatHumanSI(1000, &buf);
    try std.testing.expectEqualStrings("1.0k", kb);

    const mb = formatHumanSI(1000000, &buf);
    try std.testing.expectEqualStrings("1.0M", mb);
}
