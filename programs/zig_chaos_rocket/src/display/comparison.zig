// comparison.zig — Side-by-side: "what C would do" vs "what Zig does"
//
// The killer demo feature. Shows the actual code that failed alongside
// the Zig equivalent that catches the error.

const std = @import("std");
const scenarios = @import("../chaos/scenarios.zig");

// ANSI
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const RED = ESC ++ "[31m";
const GREEN = ESC ++ "[32m";
const YELLOW = ESC ++ "[33m";
const CYAN = ESC ++ "[36m";
const BRIGHT_RED = ESC ++ "[91m";
const BRIGHT_GREEN = ESC ++ "[92m";
const BRIGHT_CYAN = ESC ++ "[96m";
const BRIGHT_WHITE = ESC ++ "[97m";

// Separator line constants (Zig 0.16 does not support fill patterns)
const SEPARATOR_EQ_72 = "=" ** 72;
const SEPARATOR_DASH_34 = "─" ** 34;
const SEPARATOR_DASH_72 = "─" ** 72;

pub const ComparisonEntry = struct {
    scenario: *const scenarios.Scenario,
};

pub fn renderComparison(entry: *const ComparisonEntry, writer: anytype) void {
    const s = entry.scenario;

    writer.print("{s}{s}+--- {s} -- {s} LOST -- {d} ---+{s}\n", .{
        BOLD, BRIGHT_RED, s.name, s.cost, s.year, RESET,
    }) catch {};
    writer.print("{s}|{s}\n", .{ DIM, RESET }) catch {};
    writer.print("  {s}Root cause:{s} {s}\n", .{ BOLD, RESET, s.root_cause }) catch {};
    writer.print("\n", .{}) catch {};

    // Original code
    writer.print("  {s}{s}Original code (what flew):{s}\n", .{ BOLD, RED, RESET }) catch {};
    writer.print("  {s}{s}{s}\n", .{ DIM, SEPARATOR_DASH_34, RESET }) catch {};
    printCodeBlock(writer, s.original_code, RED);

    writer.print("\n", .{}) catch {};

    // Zig code
    writer.print("  {s}{s}Zig equivalent (what we wrote):{s}\n", .{ BOLD, GREEN, RESET }) catch {};
    writer.print("  {s}{s}{s}\n", .{ DIM, SEPARATOR_DASH_34, RESET }) catch {};
    printCodeBlock(writer, s.zig_code, GREEN);

    writer.print("\n", .{}) catch {};
    writer.print("  {s}{s}{s}{s}\n", .{ BRIGHT_WHITE, BOLD, s.explanation, RESET }) catch {};
    writer.print("{s}+{s}+{s}\n\n", .{ DIM, SEPARATOR_DASH_72, RESET }) catch {};
}

fn printCodeBlock(writer: anytype, code: []const u8, color: []const u8) void {
    var iter = std.mem.splitScalar(u8, code, '\n');
    while (iter.next()) |line| {
        writer.print("  {s}  {s}{s}\n", .{ color, line, RESET }) catch {};
    }
}

pub fn renderAllComparisons(writer: anytype) void {
    writer.print("\n{s}{s}{s}{s}\n", .{ BOLD, BRIGHT_CYAN, SEPARATOR_EQ_72, RESET }) catch {};
    writer.print("{s}{s}  REAL-WORLD DISASTER COMPARISON — C/C++/Ada vs Zig{s}\n", .{ BOLD, BRIGHT_WHITE, RESET }) catch {};
    writer.print("{s}{s}{s}\n\n", .{ BRIGHT_CYAN, SEPARATOR_EQ_72, RESET }) catch {};

    for (&scenarios.ALL_SCENARIOS) |*scenario| {
        const entry = ComparisonEntry{ .scenario = scenario };
        renderComparison(&entry, writer);
    }
}
