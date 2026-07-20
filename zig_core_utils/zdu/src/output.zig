//! Output formatting for zdu
//! Supports human-readable, SI, and block-size formats

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const Options = main.Options;
const DirStat = main.DirStat;

/// Print a single entry to the caller-owned writer.
///
/// The writer is created ONCE by the caller and reused for the whole run. A
/// previous version created a fresh `File.stdout()` writer per call; because a
/// File.Writer tracks a logical position that starts at 0, each positional
/// write landed at offset 0 and overwrote the output when stdout was a regular
/// file (redirection), leaving only a corrupt fragment of the last line. Using
/// one streaming writer keeps every line and preserves order.
pub fn printEntry(w: *Io.Writer, entry: DirStat, options: Options) void {
    const size = calculateDisplaySize(entry, options);
    const size_str = formatSize(size, options);

    const terminator: u8 = if (options.null_terminator) 0 else '\n';
    w.print("{s}\t{s}{c}", .{ size_str, entry.path, terminator }) catch {};
}

/// Print grand total to the caller-owned writer.
pub fn printTotal(w: *Io.Writer, total_size: u64, total_blocks: u64, options: Options) void {
    // Use apparent size if -b/--apparent-size, otherwise use blocks
    const raw_size = if (options.apparent_size)
        total_size
    else
        total_blocks * 512;

    const display_size = scaleByBlockSize(raw_size, options);
    const size_str = formatSize(display_size, options);

    const terminator: u8 = if (options.null_terminator) 0 else '\n';
    w.print("{s}\ttotal{c}", .{ size_str, terminator }) catch {};
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
    return formatHuman(bytes, buf, 1024, &.{ "", "K", "M", "G", "T", "P", "E" });
}

fn formatHumanSI(bytes: u64, buf: []u8) []const u8 {
    return formatHuman(bytes, buf, 1000, &.{ "", "k", "M", "G", "T", "P", "E" });
}

/// Human-readable size formatting matching GNU du.
///
/// GNU rounds sizes UP (ceiling) to the precision shown -- 12.3k is displayed
/// as "13k", not "12k" (coreutils human.c uses human_ceiling). Rounding to
/// nearest, as the previous implementation did, produced off-by-one sizes vs
/// `du -h` / `du --si`. Values below the divisor are printed as exact byte
/// counts; single-digit scaled values keep one decimal (ceil to 0.1), larger
/// values are whole numbers (ceil to 1).
fn formatHuman(bytes: u64, buf: []u8, comptime divisor: f64, units: []const []const u8) []const u8 {
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= divisor and unit_idx < units.len - 1) {
        size /= divisor;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "???";
    } else if (size < 10) {
        // Ceil to one decimal place.
        const v = std.math.ceil(size * 10.0) / 10.0;
        // A ceil that lands on 10.0 promotes to the next display rule.
        if (v >= 10.0) {
            return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ v, units[unit_idx] }) catch "???";
        }
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ v, units[unit_idx] }) catch "???";
    } else {
        const v = std.math.ceil(size);
        return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ v, units[unit_idx] }) catch "???";
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
