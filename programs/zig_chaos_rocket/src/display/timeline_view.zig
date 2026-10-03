// timeline_view.zig — Visual mission timeline with fault injection markers

const std = @import("std");
const timeline_mod = @import("../sim/timeline.zig");

// ANSI
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const GREEN = ESC ++ "[32m";
const CYAN = ESC ++ "[36m";
const BRIGHT_GREEN = ESC ++ "[92m";
const BRIGHT_CYAN = ESC ++ "[96m";

// Separator line constants (Zig 0.16 does not support fill patterns)
const SEPARATOR_DASH_68 = repeatStr("─", 68);

pub fn renderTimeline(tl: *const timeline_mod.Timeline, writer: anytype) void {
    writer.print("\n{s}{s}  MISSION TIMELINE{s}\n", .{ BOLD, BRIGHT_CYAN, RESET }) catch {};
    writer.print("  {s}\n", .{SEPARATOR_DASH_68}) catch {};

    for (tl.milestones) |m| {
        const status_icon: []const u8 = if (m.triggered) "[+]" else "[ ]";
        const color: []const u8 = if (m.triggered) BRIGHT_GREEN else DIM;
        const time_s = m.met_seconds;

        if (time_s < 0) {
            writer.print("  {s}{s} T{d:>5.0}s  {s:<18} {s}{s}\n", .{
                color, status_icon, time_s, m.name, m.description, RESET,
            }) catch {};
        } else {
            writer.print("  {s}{s} T+{d:>4.0}s  {s:<18} {s}{s}\n", .{
                color, status_icon, time_s, m.name, m.description, RESET,
            }) catch {};
        }
    }
    writer.print("\n", .{}) catch {};
}

/// Comptime string repetition (`s` concatenated `n` times).
fn repeatStr(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk &final;
    };
}
