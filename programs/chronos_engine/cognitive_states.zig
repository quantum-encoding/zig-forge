//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License

// cognitive_states.zig - Claude Code cognitive state definitions and detection

const std = @import("std");

/// Tool-based cognitive activities (detected via eBPF hooks)
pub const ToolActivity = enum {
    // Phase 1: High-confidence detection via hooks
    executing_command,     // Bash
    planning_tasks,        // TodoWrite

    // Phase 2: Inferred from output patterns
    reading_file,          // Read
    writing_file,          // Write
    editing_file,          // Edit
    searching_files,       // Glob
    searching_code,        // Grep

    // Phase 3: Advanced tools (future)
    fetching_web_content,  // WebFetch
    searching_web,         // WebSearch
    running_background_agent, // Task
    awaiting_user_input,   // AskUserQuestion
    editing_notebook,      // NotebookEdit

    unknown,

    pub fn fromToolName(tool_name: []const u8) ToolActivity {
        if (std.mem.eql(u8, tool_name, "Bash")) return .executing_command;
        if (std.mem.eql(u8, tool_name, "TodoWrite")) return .planning_tasks;
        if (std.mem.eql(u8, tool_name, "Read")) return .reading_file;
        if (std.mem.eql(u8, tool_name, "Write")) return .writing_file;
        if (std.mem.eql(u8, tool_name, "Edit")) return .editing_file;
        if (std.mem.eql(u8, tool_name, "Glob")) return .searching_files;
        if (std.mem.eql(u8, tool_name, "Grep")) return .searching_code;
        if (std.mem.eql(u8, tool_name, "WebFetch")) return .fetching_web_content;
        if (std.mem.eql(u8, tool_name, "WebSearch")) return .searching_web;
        if (std.mem.eql(u8, tool_name, "Task")) return .running_background_agent;
        if (std.mem.eql(u8, tool_name, "AskUserQuestion")) return .awaiting_user_input;
        if (std.mem.eql(u8, tool_name, "NotebookEdit")) return .editing_notebook;
        return .unknown;
    }

    pub fn toString(self: ToolActivity) []const u8 {
        return switch (self) {
            .executing_command => "executing-command",
            .planning_tasks => "planning-tasks",
            .reading_file => "reading-file",
            .writing_file => "writing-file",
            .editing_file => "editing-file",
            .searching_files => "searching-files",
            .searching_code => "searching-code",
            .fetching_web_content => "fetching-web-content",
            .searching_web => "searching-web",
            .running_background_agent => "running-background-agent",
            .awaiting_user_input => "awaiting-user-input",
            .editing_notebook => "editing-notebook",
            .unknown => "unknown-tool",
        };
    }
};

/// All 84 cognitive states extracted from Claude Code CLI
pub const COGNITIVE_STATES = [_][]const u8{
    "Accomplishing",
    "Actioning",
    "Actualizing",
    "Baking",
    "Booping",
    "Brewing",
    "Calculating",
    "Cerebrating",
    "Channelling",
    "Churning",
    "Clauding",
    "Coalescing",
    "Cogitating",
    "Computing",
    "Combobulating",
    "Concocting",
    "Considering",
    "Contemplating",
    "Cooking",
    "Crafting",
    "Creating",
    "Crunching",
    "Deciphering",
    "Deliberating",
    "Determining",
    "Discombobulating",
    "Doing",
    "Effecting",
    "Elucidating",
    "Enchanting",
    "Envisioning",
    "Finagling",
    "Flibbertigibbeting",
    "Forging",
    "Forming",
    "Frolicking",
    "Generating",
    "Germinating",
    "Hatching",
    "Herding",
    "Honking",
    "Ideating",
    "Imagining",
    "Incubating",
    "Inferring",
    "Manifesting",
    "Marinating",
    "Meandering",
    "Moseying",
    "Mulling",
    "Mustering",
    "Musing",
    "Noodling",
    "Percolating",
    "Perusing",
    "Philosophising",
    "Pontificating",
    "Pondering",
    "Processing",
    "Puttering",
    "Puzzling",
    "Reticulating",
    "Ruminating",
    "Scheming",
    "Schlepping",
    "Shimmying",
    "Simmering",
    "Smooshing",
    "Spelunking",
    "Spinning",
    "Stewing",
    "Sussing",
    "Synthesizing",
    "Thinking",
    "Tinkering",
    "Transmuting",
    "Unfurling",
    "Unravelling",
    "Vibing",
    "Wandering",
    "Whirring",
    "Wibbling",
    "Working",
    "Wrangling",
};

/// Cognitive confidence levels based on state analysis
pub const CognitiveConfidence = enum {
    high, // 0.8-1.0
    medium, // 0.6-0.9
    low, // 0.2-0.6
    creative, // exploratory states
    analytical, // deep thinking states

    pub fn fromState(state: []const u8) CognitiveConfidence {
        // High confidence states
        const high_states = [_][]const u8{ "Channelling", "Computing", "Processing", "Working", "Accomplishing" };
        for (high_states) |s| {
            if (std.mem.eql(u8, state, s)) return .high;
        }

        // Low confidence states
        const low_states = [_][]const u8{ "Discombobulating", "Finagling", "Zigzagging", "Puzzling", "Wrangling" };
        for (low_states) |s| {
            if (std.mem.eql(u8, state, s)) return .low;
        }

        // Creative states
        const creative_states = [_][]const u8{ "Musing", "Wandering", "Vibing", "Frolicking", "Imagining" };
        for (creative_states) |s| {
            if (std.mem.eql(u8, state, s)) return .creative;
        }

        // Analytical states
        const analytical_states = [_][]const u8{ "Contemplating", "Deliberating", "Cogitating", "Ruminating", "Philosophising" };
        for (analytical_states) |s| {
            if (std.mem.eql(u8, state, s)) return .analytical;
        }

        // Default to medium for synthesis/bridging states
        return .medium;
    }
};

/// Detect cognitive state in a line of text
pub fn detectState(line: []const u8) ?[]const u8 {
    // Strip ANSI escape codes
    var clean_line_buf: [4096]u8 = undefined;
    const clean_line = stripAnsiCodes(line, &clean_line_buf) catch return null;

    // Look for cognitive state words followed by "…" or "..."
    for (COGNITIVE_STATES) |state| {
        // Check for state + ellipsis
        var pattern_buf: [256]u8 = undefined;
        const pattern1 = std.fmt.bufPrint(&pattern_buf, "{s}…", .{state}) catch continue;

        if (std.mem.indexOf(u8, clean_line, pattern1) != null) {
            return state;
        }

        const pattern2 = std.fmt.bufPrint(&pattern_buf, "{s}...", .{state}) catch continue;
        if (std.mem.indexOf(u8, clean_line, pattern2) != null) {
            return state;
        }
    }

    return null;
}

/// Strip ANSI escape codes from text
fn stripAnsiCodes(input: []const u8, out_buf: []u8) ![]const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_idx < out_buf.len) {
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            // Skip ANSI escape sequence
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if ((c >= 0x40 and c <= 0x7E) or c == 'm') break;
            }
        } else {
            out_buf[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    return out_buf[0..out_idx];
}

test "detect cognitive states" {
    const test_cases = [_]struct {
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .input = "· Synthesizing…", .expected = "Synthesizing" },
        .{ .input = "✢ Finagling…", .expected = "Finagling" },
        .{ .input = "Channelling...", .expected = "Channelling" },
        .{ .input = "Just some text", .expected = null },
    };

    for (test_cases) |tc| {
        const result = detectState(tc.input);
        if (tc.expected) |expected| {
            try std.testing.expect(result != null);
            try std.testing.expectEqualStrings(expected, result.?);
        } else {
            try std.testing.expect(result == null);
        }
    }
}

test "confidence levels" {
    try std.testing.expect(CognitiveConfidence.fromState("Channelling") == .high);
    try std.testing.expect(CognitiveConfidence.fromState("Discombobulating") == .low);
    try std.testing.expect(CognitiveConfidence.fromState("Vibing") == .creative);
    try std.testing.expect(CognitiveConfidence.fromState("Contemplating") == .analytical);
}
