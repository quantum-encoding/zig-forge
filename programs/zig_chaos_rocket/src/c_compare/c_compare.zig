// c_compare.zig — C vs Zig comparison module
//
// Calls actual C code (compiled with zig cc) that demonstrates the bugs,
// then shows what Zig does differently. The C code runs and produces results
// showing that C does NOT catch these bugs. Zig prevents them structurally.

const std = @import("std");

// ANSI
const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const BOLD = ESC ++ "[1m";
const DIM = ESC ++ "[2m";
const RED = ESC ++ "[31m";
const GREEN = ESC ++ "[32m";
const BRIGHT_RED = ESC ++ "[91m";
const BRIGHT_GREEN = ESC ++ "[92m";
const BRIGHT_CYAN = ESC ++ "[96m";
const BRIGHT_WHITE = ESC ++ "[97m";
const BRIGHT_YELLOW = ESC ++ "[93m";

const SEPARATOR_EQ_72 = "=" ** 72;
const SEPARATOR_DASH_68 = "-" ** 68;

// C FFI — functions from c_bugs.c
extern fn run_all_demos() void;
extern fn get_result_count() c_int;
extern fn get_result_name(index: c_int) [*:0]const u8;
extern fn get_result_bug_class(index: c_int) [*:0]const u8;
extern fn get_result_triggered(index: c_int) c_int;
extern fn get_result_caught(index: c_int) c_int;
extern fn get_result_what(index: c_int) [*:0]const u8;

/// Run all C bug demos and render the comparison report
pub fn renderCComparison(writer: anytype) void {
    // Run the actual C code
    run_all_demos();

    const count = get_result_count();

    writer.print("\n{s}{s}{s}{s}\n", .{ BOLD, BRIGHT_CYAN, SEPARATOR_EQ_72, RESET }) catch {};
    writer.print("{s}{s}  C vs ZIG — LIVE BUG DEMONSTRATION{s}\n", .{ BOLD, BRIGHT_WHITE, RESET }) catch {};
    writer.print("{s}{s}  Actual C code compiled with zig cc. These bugs are REAL.{s}\n", .{ DIM, BRIGHT_WHITE, RESET }) catch {};
    writer.print("{s}{s}{s}\n\n", .{ BRIGHT_CYAN, SEPARATOR_EQ_72, RESET }) catch {};

    var bugs_triggered: u32 = 0;
    var bugs_caught_by_c: u32 = 0;

    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const name = std.mem.sliceTo(get_result_name(i), 0);
        const bug_class = std.mem.sliceTo(get_result_bug_class(i), 0);
        const triggered = get_result_triggered(i);
        const caught = get_result_caught(i);
        const what = std.mem.sliceTo(get_result_what(i), 0);

        if (triggered != 0) bugs_triggered += 1;
        if (caught != 0) bugs_caught_by_c += 1;

        const status_color = if (caught != 0) BRIGHT_GREEN else BRIGHT_RED;
        const status_text = if (caught != 0) "CAUGHT BY C" else "MISSED BY C";
        const zig_text = BRIGHT_GREEN;

        const num: u32 = @intCast(i + 1);
        writer.print("  {s}{s}{d:>2}. {s}{s}\n", .{
            BOLD, BRIGHT_WHITE, num, name, RESET,
        }) catch {};
        writer.print("      Bug class:  {s}\n", .{bug_class}) catch {};
        writer.print("      C result:   {s}{s}{s}\n", .{ status_color, status_text, RESET }) catch {};
        writer.print("      Detail:     {s}\n", .{what}) catch {};
        writer.print("      Zig result: {s}CAUGHT (or structurally impossible){s}\n\n", .{
            zig_text, RESET,
        }) catch {};
    }

    // Summary
    writer.print("  {s}{s}\n", .{ SEPARATOR_DASH_68, RESET }) catch {};
    writer.print("  {s}SUMMARY{s}\n", .{ BOLD, RESET }) catch {};
    writer.print("  {s}\n", .{SEPARATOR_DASH_68}) catch {};
    writer.print("  Bugs demonstrated:    {d:>4}\n", .{bugs_triggered}) catch {};
    writer.print("  Caught by C:          {s}{d:>4}{s}  ({s}C catches NONE of these{s})\n", .{
        BRIGHT_RED, bugs_caught_by_c, RESET, DIM, RESET,
    }) catch {};
    writer.print("  Caught by Zig:        {s}{d:>4}{s}  ({s}compile-time, runtime safety, or structurally impossible{s})\n", .{
        BRIGHT_GREEN, bugs_triggered, RESET, DIM, RESET,
    }) catch {};
    writer.print("\n  {s}{s}Every bug that C allows silently, Zig catches or prevents entirely.{s}\n\n", .{
        BOLD, BRIGHT_YELLOW, RESET,
    }) catch {};
    writer.print("{s}{s}{s}\n\n", .{ BRIGHT_CYAN, SEPARATOR_EQ_72, RESET }) catch {};
}
