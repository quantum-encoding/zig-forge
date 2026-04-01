//! Cognitive state definitions, confidence scoring, and tool activity tracking.
//!
//! Canonical source of all Claude Code cognitive states. Extracted from
//! chronos_engine/cognitive_states.zig and cognitive-tools/confidence scoring.

const std = @import("std");

/// All known cognitive states from Claude Code status line.
/// Updated from Linux and macOS observation.
pub const STATES = [_][]const u8{
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

pub const state_count = STATES.len;

/// Tool-based cognitive activities detected via hooks.
pub const ToolActivity = enum(u8) {
    executing_command = 0, // Bash
    planning_tasks = 1, // TodoWrite
    reading_file = 2, // Read
    writing_file = 3, // Write
    editing_file = 4, // Edit
    searching_files = 5, // Glob
    searching_code = 6, // Grep
    fetching_web_content = 7, // WebFetch
    searching_web = 8, // WebSearch
    running_background_agent = 9, // Agent/Task
    awaiting_user_input = 10, // AskUserQuestion
    editing_notebook = 11, // NotebookEdit
    unknown = 255,

    pub fn fromToolName(name: []const u8) ToolActivity {
        const map = .{
            .{ "Bash", .executing_command },
            .{ "TodoWrite", .planning_tasks },
            .{ "Read", .reading_file },
            .{ "Write", .writing_file },
            .{ "Edit", .editing_file },
            .{ "Glob", .searching_files },
            .{ "Grep", .searching_code },
            .{ "WebFetch", .fetching_web_content },
            .{ "WebSearch", .searching_web },
            .{ "Task", .running_background_agent },
            .{ "Agent", .running_background_agent },
            .{ "AskUserQuestion", .awaiting_user_input },
            .{ "NotebookEdit", .editing_notebook },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .unknown;
    }

    pub fn displayName(self: ToolActivity) []const u8 {
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
            .unknown => "unknown",
        };
    }
};

/// Confidence level derived from cognitive state.
pub const Confidence = enum(u8) {
    excellent = 0, // 0.90-1.0: Channelling, Executing, Synthesizing
    good = 1, // 0.70-0.89: Computing, Processing, Working
    neutral = 2, // 0.50-0.69: Thinking, Pondering, Reading
    concerning = 3, // 0.30-0.49: Noodling, Finagling, Meandering
    problematic = 4, // 0.00-0.29: Discombobulating, Wibbling

    pub fn score(self: Confidence) f32 {
        return switch (self) {
            .excellent => 0.95,
            .good => 0.80,
            .neutral => 0.60,
            .concerning => 0.40,
            .problematic => 0.15,
        };
    }
};

pub fn confidenceFromState(state: []const u8) Confidence {
    const excellent = [_][]const u8{ "Channelling", "Synthesizing", "Accomplishing", "Computing", "Forging" };
    for (excellent) |s| if (std.mem.eql(u8, state, s)) return .excellent;

    const good = [_][]const u8{ "Processing", "Working", "Creating", "Crafting", "Determining", "Calculating", "Generating", "Implementing" };
    for (good) |s| if (std.mem.eql(u8, state, s)) return .good;

    const concerning = [_][]const u8{ "Noodling", "Finagling", "Meandering", "Moseying", "Wandering", "Puttering" };
    for (concerning) |s| if (std.mem.eql(u8, state, s)) return .concerning;

    const problematic = [_][]const u8{ "Discombobulating", "Wibbling", "Flibbertigibbeting", "Honking", "Smooshing" };
    for (problematic) |s| if (std.mem.eql(u8, state, s)) return .problematic;

    return .neutral;
}

test "cognitive: confidenceFromState coverage" {
    // Excellent tier
    try std.testing.expectEqual(Confidence.excellent, confidenceFromState("Channelling"));
    try std.testing.expectEqual(Confidence.excellent, confidenceFromState("Synthesizing"));
    try std.testing.expectEqual(Confidence.excellent, confidenceFromState("Accomplishing"));
    try std.testing.expectEqual(Confidence.excellent, confidenceFromState("Computing"));
    try std.testing.expectEqual(Confidence.excellent, confidenceFromState("Forging"));

    // Good tier
    try std.testing.expectEqual(Confidence.good, confidenceFromState("Processing"));
    try std.testing.expectEqual(Confidence.good, confidenceFromState("Working"));
    try std.testing.expectEqual(Confidence.good, confidenceFromState("Creating"));
    try std.testing.expectEqual(Confidence.good, confidenceFromState("Crafting"));
    try std.testing.expectEqual(Confidence.good, confidenceFromState("Generating"));

    // Neutral tier (default for any unrecognised state)
    try std.testing.expectEqual(Confidence.neutral, confidenceFromState("Thinking"));
    try std.testing.expectEqual(Confidence.neutral, confidenceFromState("Pondering"));
    try std.testing.expectEqual(Confidence.neutral, confidenceFromState("UnknownState"));

    // Concerning tier
    try std.testing.expectEqual(Confidence.concerning, confidenceFromState("Noodling"));
    try std.testing.expectEqual(Confidence.concerning, confidenceFromState("Meandering"));
    try std.testing.expectEqual(Confidence.concerning, confidenceFromState("Wandering"));
    try std.testing.expectEqual(Confidence.concerning, confidenceFromState("Finagling"));

    // Problematic tier
    try std.testing.expectEqual(Confidence.problematic, confidenceFromState("Discombobulating"));
    try std.testing.expectEqual(Confidence.problematic, confidenceFromState("Wibbling"));
    try std.testing.expectEqual(Confidence.problematic, confidenceFromState("Honking"));
    try std.testing.expectEqual(Confidence.problematic, confidenceFromState("Smooshing"));
}

test "cognitive: confidenceFromState score values" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), confidenceFromState("Channelling").score(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), confidenceFromState("Working").score(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.60), confidenceFromState("Thinking").score(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), confidenceFromState("Noodling").score(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), confidenceFromState("Wibbling").score(), 0.001);
}

/// Extract cognitive state from Claude status line output.
/// Matches patterns like "* Thinking (esc to interrupt" or "⏺ Thinking… (ctrl+c"
pub fn extractState(output: []const u8) ?[]const u8 {
    // Pattern 1: "* STATE (" or "* STATE…"
    if (std.mem.indexOf(u8, output, "* ")) |star_pos| {
        const after = output[star_pos + 2 ..];
        // Find end: " (" or "…" or "..."
        for (after, 0..) |ch, i| {
            if (ch == '(' or ch == '\xe2') { // \xe2 = start of … (U+2026)
                if (i > 0) return std.mem.trim(u8, after[0..i], " ");
            }
        }
    }
    return null;
}

test "cognitive: extractState with paren delimiter" {
    // "* STATE (esc to interrupt)"
    const r1 = extractState("* Thinking (esc to interrupt)");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("Thinking", r1.?);

    const r2 = extractState("* Synthesizing (ctrl+c to stop)");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("Synthesizing", r2.?);
}

test "cognitive: extractState with ellipsis delimiter" {
    // "* STATE…" — U+2026 encoded as \xe2\x80\xa6
    const r1 = extractState("* Forging\xe2\x80\xa6");
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("Forging", r1.?);

    const r2 = extractState("* Processing\xe2\x80\xa6 (ctrl+c)");
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("Processing", r2.?);
}

test "cognitive: extractState returns null when no match" {
    try std.testing.expect(extractState("") == null);
    try std.testing.expect(extractState("some other output") == null);
    // Has "* " but no terminator → null
    try std.testing.expect(extractState("* Thinking without end") == null);
}
