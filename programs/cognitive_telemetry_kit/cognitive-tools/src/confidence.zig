const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const DB_PATH = "/var/lib/cognitive-watcher/cognitive-states.db";

// Confidence scoring for Claude's cognitive states
// Based on what each state indicates about code quality and development process
pub const StateConfidence = struct {
    state: []const u8,
    confidence: f32, // 0.0 (bad) to 1.0 (excellent)
    category: Category,
    description: []const u8,

    pub const Category = enum {
        excellent, // High confidence, productive work
        good, // Solid progress, minor uncertainty
        neutral, // Standard operations
        concerning, // Uncertainty or inefficiency
        problematic, // Confusion, guessing, or poor practices
    };
};

// Cognitive state confidence mappings
pub const STATE_SCORES = [_]StateConfidence{
    // EXCELLENT (0.9-1.0) - Clear intent, focused execution
    .{ .state = "Channelling", .confidence = 1.0, .category = .excellent, .description = "Deep focus, knows exactly what to do" },
    .{ .state = "Executing", .confidence = 0.95, .category = .excellent, .description = "Confident execution of plan" },
    .{ .state = "Implementing", .confidence = 0.95, .category = .excellent, .description = "Focused implementation" },
    .{ .state = "Synthesizing", .confidence = 0.93, .category = .excellent, .description = "Combining concepts effectively" },
    .{ .state = "Crystallizing", .confidence = 0.92, .category = .excellent, .description = "Solidifying solution" },
    .{ .state = "Verifying", .confidence = 0.91, .category = .excellent, .description = "Quality assurance" },
    .{ .state = "Recombobulating", .confidence = 0.90, .category = .excellent, .description = "Fixing issues with clear understanding" },

    // GOOD (0.7-0.89) - Productive with minor exploration
    .{ .state = "Computing", .confidence = 0.85, .category = .good, .description = "Processing information systematically" },
    .{ .state = "Orchestrating", .confidence = 0.83, .category = .good, .description = "Coordinating multiple components" },
    .{ .state = "Hashing", .confidence = 0.82, .category = .good, .description = "Working through details" },
    .{ .state = "Proofing", .confidence = 0.81, .category = .good, .description = "Testing and validation" },
    .{ .state = "Refining", .confidence = 0.80, .category = .good, .description = "Improving existing work" },
    .{ .state = "Optimizing", .confidence = 0.79, .category = .good, .description = "Performance improvements" },
    .{ .state = "Precipitating", .confidence = 0.78, .category = .good, .description = "Bringing solution together" },
    .{ .state = "Percolating", .confidence = 0.77, .category = .good, .description = "Processing gradually" },
    .{ .state = "Sprouting", .confidence = 0.75, .category = .good, .description = "Initial development" },
    .{ .state = "Churning", .confidence = 0.72, .category = .good, .description = "Active processing" },
    .{ .state = "Whirring", .confidence = 0.70, .category = .good, .description = "Working steadily" },

    // NEUTRAL (0.5-0.69) - Standard operations, no strong signal
    .{ .state = "Thinking", .confidence = 0.65, .category = .neutral, .description = "General processing" },
    .{ .state = "Pondering", .confidence = 0.63, .category = .neutral, .description = "Considering options" },
    .{ .state = "Contemplating", .confidence = 0.62, .category = .neutral, .description = "Reflection" },
    .{ .state = "Reading", .confidence = 0.60, .category = .neutral, .description = "Gathering information" },
    .{ .state = "Writing", .confidence = 0.60, .category = .neutral, .description = "Creating content" },
    .{ .state = "Doing", .confidence = 0.58, .category = .neutral, .description = "Generic action" },
    .{ .state = "Nesting", .confidence = 0.57, .category = .neutral, .description = "Organizing structure" },
    .{ .state = "Burrowing", .confidence = 0.55, .category = .neutral, .description = "Deep dive" },
    .{ .state = "Scurrying", .confidence = 0.53, .category = .neutral, .description = "Quick work" },
    .{ .state = "Composing", .confidence = 0.52, .category = .neutral, .description = "Creating" },
    .{ .state = "Compacting conversation", .confidence = 0.50, .category = .neutral, .description = "Managing context" },

    // CONCERNING (0.3-0.49) - Uncertainty, exploration without clear direction
    .{ .state = "Noodling", .confidence = 0.48, .category = .concerning, .description = "Exploring without clear plan" },
    .{ .state = "Finagling", .confidence = 0.45, .category = .concerning, .description = "Working around issues unclearly" },
    .{ .state = "Meandering", .confidence = 0.43, .category = .concerning, .description = "Wandering without focus" },
    .{ .state = "Gallivanting", .confidence = 0.42, .category = .concerning, .description = "Unfocused exploration" },
    .{ .state = "Frolicking", .confidence = 0.40, .category = .concerning, .description = "Playful but unproductive" },
    .{ .state = "Swooping", .confidence = 0.38, .category = .concerning, .description = "Rapid changes without clarity" },
    .{ .state = "Zigzagging", .confidence = 0.35, .category = .concerning, .description = "Inconsistent direction" },
    .{ .state = "Gusting", .confidence = 0.33, .category = .concerning, .description = "Erratic progress" },
    .{ .state = "Nebulizing", .confidence = 0.32, .category = .concerning, .description = "Making things unclear" },
    .{ .state = "Billowing", .confidence = 0.30, .category = .concerning, .description = "Expanding without control" },

    // PROBLEMATIC (0.0-0.29) - Confusion, guessing, poor practices
    .{ .state = "Discombobulating", .confidence = 0.25, .category = .problematic, .description = "Confused, not knowing what to do" },
    .{ .state = "Embellishing", .confidence = 0.23, .category = .problematic, .description = "Over-documenting instead of solving" },
    .{ .state = "Bloviating", .confidence = 0.20, .category = .problematic, .description = "Verbose without substance" },
    .{ .state = "Lollygagging", .confidence = 0.18, .category = .problematic, .description = "Wasting time" },
    .{ .state = "Honking", .confidence = 0.15, .category = .problematic, .description = "Making noise without progress" },
    .{ .state = "Zesting", .confidence = 0.12, .category = .problematic, .description = "Adding unnecessary flair" },
    .{ .state = "Julienning", .confidence = 0.10, .category = .problematic, .description = "Over-slicing, excessive refactoring" },
};

pub fn getConfidenceScore(state: []const u8) StateConfidence {
    // Try exact match first
    for (STATE_SCORES) |score| {
        if (std.mem.eql(u8, score.state, state)) {
            return score;
        }
    }

    // Try case-insensitive partial match
    for (STATE_SCORES) |score| {
        if (std.ascii.startsWithIgnoreCase(state, score.state)) {
            return score;
        }
    }

    // Default: neutral unknown state
    return StateConfidence{
        .state = "Unknown",
        .confidence = 0.50,
        .category = .neutral,
        .description = "Unrecognized state",
    };
}

pub fn getCategoryColor(category: StateConfidence.Category) []const u8 {
    return switch (category) {
        .excellent => "\x1b[92m", // Bright green
        .good => "\x1b[32m", // Green
        .neutral => "\x1b[37m", // White
        .concerning => "\x1b[33m", // Yellow
        .problematic => "\x1b[91m", // Bright red
    };
}

pub fn getCategoryEmoji(category: StateConfidence.Category) []const u8 {
    return switch (category) {
        .excellent => "✨",
        .good => "✅",
        .neutral => "➖",
        .concerning => "⚠️",
        .problematic => "🚨",
    };
}

const RESET = "\x1b[0m";

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Command: cognitive-confidence [session|stats|score]
    if (args.len < 2) {
        try printUsage();
        return 0;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "stats")) {
        try printStats(allocator);
    } else if (std.mem.eql(u8, command, "session") and args.len >= 3) {
        const pid = try std.fmt.parseInt(u32, args[2], 10);
        try printSessionConfidence(allocator, pid);
    } else if (std.mem.eql(u8, command, "score") and args.len >= 3) {
        const state = args[2];
        try printStateScore(state);
    } else if (std.mem.eql(u8, command, "legend")) {
        try printLegend();
    } else {
        try printUsage();
    }

    return 0;
}

fn printUsage() !void {
    // Use std.debug.print instead
    std.debug.print(
        \\🧠 COGNITIVE CONFIDENCE ANALYZER
        \\
        \\Usage:
        \\  cognitive-confidence stats              - Show confidence stats for all states
        \\  cognitive-confidence session <PID>      - Analyze confidence for a specific session
        \\  cognitive-confidence score <state>      - Get confidence score for a state
        \\  cognitive-confidence legend             - Show confidence scoring legend
        \\
        \\Examples:
        \\  cognitive-confidence stats
        \\  cognitive-confidence session 12862
        \\  cognitive-confidence score "Channelling"
        \\
    , .{});
}

fn printLegend() !void {
    // Use std.debug.print instead
    std.debug.print("\n🎯 COGNITIVE CONFIDENCE SCORING LEGEND\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    std.debug.print("✨ EXCELLENT (0.90-1.00) - High Confidence, Focused Execution\n", .{});
    std.debug.print("  States indicate clear understanding and purposeful action\n\n", .{});

    std.debug.print("✅ GOOD (0.70-0.89) - Productive Progress\n", .{});
    std.debug.print("  Solid work with minor exploration or iteration\n\n", .{});

    std.debug.print("➖ NEUTRAL (0.50-0.69) - Standard Operations\n", .{});
    std.debug.print("  Normal processing, no strong quality signal\n\n", .{});

    std.debug.print("⚠️  CONCERNING (0.30-0.49) - Uncertainty Detected\n", .{});
    std.debug.print("  Exploration without clear direction, potential inefficiency\n\n", .{});

    std.debug.print("🚨 PROBLEMATIC (0.00-0.29) - Quality Issues\n", .{});
    std.debug.print("  Confusion, guessing, or poor development practices\n\n", .{});

    std.debug.print("Examples:\n", .{});
    std.debug.print("  ✨ Channelling      (1.00) - Deep focus, knows exactly what to do\n", .{});
    std.debug.print("  ✅ Computing        (0.85) - Processing information systematically\n", .{});
    std.debug.print("  ➖ Thinking         (0.65) - General processing\n", .{});
    std.debug.print("  ⚠️  Noodling        (0.48) - Exploring without clear plan\n", .{});
    std.debug.print("  🚨 Discombobulating (0.25) - Confused, not knowing what to do\n\n", .{});
}

fn printStateScore(state: []const u8) !void {
    // Use std.debug.print instead
    const score = getConfidenceScore(state);
    const color = getCategoryColor(score.category);
    const emoji = getCategoryEmoji(score.category);

    std.debug.print("\n{s}{s} State: {s}{s}\n", .{ color, emoji, state, RESET });
    std.debug.print("   Confidence: {s}{d:.2}{s}\n", .{ color, score.confidence, RESET });
    std.debug.print("   Category: {s}\n", .{@tagName(score.category)});
    std.debug.print("   Meaning: {s}\n\n", .{score.description});
}

fn printStats(allocator: std.mem.Allocator) !void {
    // Use std.debug.print instead

    // Open database with immutable flag
    var db: ?*c.sqlite3 = null;
    const db_uri = "file:" ++ DB_PATH ++ "?immutable=1";
    const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI;
    if (c.sqlite3_open_v2(db_uri.ptr, &db, flags, null) != c.SQLITE_OK) {
        std.debug.print("Error: Cannot open database at {s}\n", .{DB_PATH});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_close(db);

    const query =
        \\SELECT
        \\  replace(replace(substr(raw_content, instr(raw_content, '* ') + 2,
        \\    instr(raw_content || ' (', ' (') - instr(raw_content, '* ') - 2),
        \\    char(10), ''), char(13), '') as state,
        \\  COUNT(*) as count
        \\FROM cognitive_states
        \\WHERE raw_content LIKE '%* %' AND raw_content LIKE '%(esc to interrupt%'
        \\GROUP BY state
        \\ORDER BY count DESC;
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Error: Failed to prepare query\n", .{});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n🧠 COGNITIVE STATE CONFIDENCE ANALYSIS\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════\n\n", .{});

    var total_states: u64 = 0;
    var weighted_confidence: f64 = 0.0;

    // Collect all states first
    var states = std.ArrayList(struct { state: []const u8, count: u64 }).empty;
    defer states.deinit(allocator);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const state_ptr = c.sqlite3_column_text(stmt, 0);
        const count = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 1)));

        if (state_ptr != null) {
            const state = std.mem.span(state_ptr);
            try states.append(allocator, .{
                .state = try allocator.dupe(u8, state),
                .count = count,
            });

            const score = getConfidenceScore(state);
            total_states += count;
            weighted_confidence += @as(f64, @floatFromInt(count)) * score.confidence;
        }
    }

    // Print overall confidence
    const avg_confidence = if (total_states > 0) weighted_confidence / @as(f64, @floatFromInt(total_states)) else 0.0;
    const overall_category = if (avg_confidence >= 0.90) StateConfidence.Category.excellent else if (avg_confidence >= 0.70) StateConfidence.Category.good else if (avg_confidence >= 0.50) StateConfidence.Category.neutral else if (avg_confidence >= 0.30) StateConfidence.Category.concerning else StateConfidence.Category.problematic;

    const overall_color = getCategoryColor(overall_category);
    const overall_emoji = getCategoryEmoji(overall_category);

    std.debug.print("{s}{s} Overall Session Confidence: {d:.3}{s}\n", .{ overall_color, overall_emoji, avg_confidence, RESET });
    std.debug.print("   Total cognitive states: {d}\n\n", .{total_states});

    // Print states grouped by category
    const categories = [_]StateConfidence.Category{ .excellent, .good, .neutral, .concerning, .problematic };

    for (categories) |category| {
        const color = getCategoryColor(category);
        const emoji = getCategoryEmoji(category);
        std.debug.print("{s}{s} {s} States:{s}\n", .{ color, emoji, @tagName(category), RESET });

        var found = false;
        for (states.items) |item| {
            const score = getConfidenceScore(item.state);
            if (score.category == category) {
                std.debug.print("   {s}{d:.2}{s}  {s: <25} ({d: >5} occurrences)\n", .{
                    color,
                    score.confidence,
                    RESET,
                    item.state,
                    item.count,
                });
                found = true;
            }
        }
        if (!found) {
            std.debug.print("   (none)\n", .{});
        }
        std.debug.print("\n", .{});
    }

    // Cleanup
    for (states.items) |item| {
        allocator.free(item.state);
    }
}

fn printSessionConfidence(_: std.mem.Allocator, pid: u32) !void {
    // Use std.debug.print instead

    // Open database with immutable flag
    var db: ?*c.sqlite3 = null;
    const db_uri = "file:" ++ DB_PATH ++ "?immutable=1";
    const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI;
    if (c.sqlite3_open_v2(db_uri.ptr, &db, flags, null) != c.SQLITE_OK) {
        std.debug.print("Error: Cannot open database at {s}\n", .{DB_PATH});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_close(db);

    const query =
        \\SELECT
        \\  timestamp_human,
        \\  replace(replace(substr(raw_content, instr(raw_content, '* ') + 2,
        \\    instr(raw_content || ' (', ' (') - instr(raw_content, '* ') - 2),
        \\    char(10), ''), char(13), '') as state
        \\FROM cognitive_states
        \\WHERE pid = ? AND raw_content LIKE '%* %' AND raw_content LIKE '%(esc to interrupt%'
        \\ORDER BY id DESC
        \\LIMIT 100;
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Error: Failed to prepare query\n", .{});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, @as(c_int, @intCast(pid)));

    std.debug.print("\n🧠 SESSION CONFIDENCE TIMELINE - PID {d}\n", .{pid});
    std.debug.print("═══════════════════════════════════════════════════════════════════\n\n", .{});

    var count: u32 = 0;
    var total_confidence: f64 = 0.0;

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const timestamp_ptr = c.sqlite3_column_text(stmt, 0);
        const state_ptr = c.sqlite3_column_text(stmt, 1);

        if (timestamp_ptr != null and state_ptr != null) {
            const timestamp = std.mem.span(timestamp_ptr);
            const state = std.mem.span(state_ptr);

            const score = getConfidenceScore(state);
            const color = getCategoryColor(score.category);
            const emoji = getCategoryEmoji(score.category);

            std.debug.print("{s} {s}{s} {d:.2}{s} - {s: <25} ({s})\n", .{
                timestamp,
                color,
                emoji,
                score.confidence,
                RESET,
                state,
                score.description,
            });

            count += 1;
            total_confidence += score.confidence;
        }
    }

    if (count > 0) {
        const avg = total_confidence / @as(f64, @floatFromInt(count));
        const category = if (avg >= 0.90) StateConfidence.Category.excellent else if (avg >= 0.70) StateConfidence.Category.good else if (avg >= 0.50) StateConfidence.Category.neutral else if (avg >= 0.30) StateConfidence.Category.concerning else StateConfidence.Category.problematic;

        const color = getCategoryColor(category);
        const emoji = getCategoryEmoji(category);

        std.debug.print("\n{s}{s} Session Average: {d:.3}{s}\n", .{ color, emoji, avg, RESET });
        std.debug.print("   States analyzed: {d}\n", .{count});
    } else {
        std.debug.print("No cognitive states found for PID {d}\n", .{pid});
    }

    std.debug.print("\n", .{});
}
