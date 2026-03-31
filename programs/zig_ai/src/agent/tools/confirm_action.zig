// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! confirm_action tool implementation
//! Human-in-the-loop confirmation gate for dangerous operations

const std = @import("std");
const types = @import("types.zig");

pub const ConfirmActionArgs = struct {
    action: []const u8,
    details: ?[]const u8 = null,
    risk_level: RiskLevel = .medium,

    pub const RiskLevel = enum {
        low,
        medium,
        high,
        critical,

        pub fn fromString(s: []const u8) RiskLevel {
            if (std.mem.eql(u8, s, "low")) return .low;
            if (std.mem.eql(u8, s, "high")) return .high;
            if (std.mem.eql(u8, s, "critical")) return .critical;
            return .medium;
        }

        pub fn symbol(self: RiskLevel) []const u8 {
            return switch (self) {
                .low => "[LOW]",
                .medium => "[MEDIUM]",
                .high => "[HIGH]",
                .critical => "[CRITICAL]",
            };
        }

        pub fn color(self: RiskLevel) []const u8 {
            return switch (self) {
                .low => "\x1b[32m",    // green
                .medium => "\x1b[33m", // yellow
                .high => "\x1b[91m",   // light red
                .critical => "\x1b[31;1m", // bold red
            };
        }
    };
};

/// Execute confirm_action tool - prompts user for confirmation
pub fn execute(
    allocator: std.mem.Allocator,
    args: ConfirmActionArgs,
) !types.ToolOutput {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";

    // Build the confirmation prompt
    var prompt_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt_buf.deinit(allocator);

    // Header with risk level
    try prompt_buf.appendSlice(allocator, "\n");
    try prompt_buf.appendSlice(allocator, args.risk_level.color());
    try prompt_buf.appendSlice(allocator, bold);
    try prompt_buf.appendSlice(allocator, "=== CONFIRMATION REQUIRED ");
    try prompt_buf.appendSlice(allocator, args.risk_level.symbol());
    try prompt_buf.appendSlice(allocator, " ===");
    try prompt_buf.appendSlice(allocator, reset);
    try prompt_buf.appendSlice(allocator, "\n\n");

    // Action description
    try prompt_buf.appendSlice(allocator, bold);
    try prompt_buf.appendSlice(allocator, "Action: ");
    try prompt_buf.appendSlice(allocator, reset);
    try prompt_buf.appendSlice(allocator, args.action);
    try prompt_buf.appendSlice(allocator, "\n");

    // Details if provided
    if (args.details) |details| {
        try prompt_buf.appendSlice(allocator, bold);
        try prompt_buf.appendSlice(allocator, "Details: ");
        try prompt_buf.appendSlice(allocator, reset);
        try prompt_buf.appendSlice(allocator, details);
        try prompt_buf.appendSlice(allocator, "\n");
    }

    try prompt_buf.appendSlice(allocator, "\n");
    try prompt_buf.appendSlice(allocator, args.risk_level.color());
    try prompt_buf.appendSlice(allocator, "Approve this action? [y/N]: ");
    try prompt_buf.appendSlice(allocator, reset);

    // Write prompt to stderr (so it shows even if stdout is redirected)
    // Use C API for Zig 0.16 compatibility
    _ = std.c.write(2, prompt_buf.items.ptr, prompt_buf.items.len);

    // Read user input from stdin
    var input_buf: [256]u8 = undefined;
    const bytes_read = std.c.read(0, &input_buf, input_buf.len);

    if (bytes_read <= 0) {
        return types.ToolOutput{
            .success = false,
            .content = try allocator.dupe(u8, "denied"),
            .error_message = try allocator.dupe(u8, "No input received - action denied"),
            .allocator = allocator,
        };
    }

    const input = std.mem.trim(u8, input_buf[0..@intCast(bytes_read)], &[_]u8{ ' ', '\t', '\n', '\r' });

    // Check for approval (y, yes, Y, Yes, YES)
    const approved = input.len > 0 and (input[0] == 'y' or input[0] == 'Y');

    if (approved) {
        // Log approval
        const approved_msg = "\x1b[32mApproved\x1b[0m\n\n";
        _ = std.c.write(2, approved_msg.ptr, approved_msg.len);

        return types.ToolOutput{
            .success = true,
            .content = try allocator.dupe(u8, "approved"),
            .allocator = allocator,
        };
    } else {
        // Log denial
        const denied_msg = "\x1b[31mDenied\x1b[0m\n\n";
        _ = std.c.write(2, denied_msg.ptr, denied_msg.len);

        return types.ToolOutput{
            .success = false,
            .content = try allocator.dupe(u8, "denied"),
            .error_message = try allocator.dupe(u8, "Action denied by user"),
            .allocator = allocator,
        };
    }
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !ConfirmActionArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const action = obj.get("action") orelse return error.InvalidArguments;

    return ConfirmActionArgs{
        .action = try allocator.dupe(u8, action.string),
        .details = if (obj.get("details")) |d| try allocator.dupe(u8, d.string) else null,
        .risk_level = if (obj.get("risk_level")) |r| ConfirmActionArgs.RiskLevel.fromString(r.string) else .medium,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: ConfirmActionArgs) void {
    allocator.free(args.action);
    if (args.details) |d| allocator.free(d);
}
