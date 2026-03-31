// Parametric Text Prompt Templates
// Configurable AI personality profiles with {param} placeholder interpolation
// Used by CLI (-T flag) and FFI (template_name in CTextConfig) to shape AI responses

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

pub const Parameter = struct {
    name: []const u8,
    description: []const u8,
    default: []const u8,
    options: []const []const u8, // Empty = free-form text
};

pub const TextTemplate = struct {
    name: []const u8,
    system_prompt: []const u8, // May contain {param} placeholders
    user_prefix: []const u8, // Prepended to user input (may have {param})
    user_suffix: []const u8, // Appended to user input
    description: []const u8,
    category: Category,
    parameters: []const Parameter,
};

pub const Category = enum {
    coding,
    creative,
    professional,
    education,
    analysis,
    entertainment,

    pub fn getName(self: Category) []const u8 {
        return switch (self) {
            .coding => "Coding",
            .creative => "Creative",
            .professional => "Professional",
            .education => "Education",
            .analysis => "Analysis",
            .entertainment => "Entertainment",
        };
    }
};

// ============================================================================
// Template Lookup
// ============================================================================

pub fn findTemplate(name: []const u8) ?*const TextTemplate {
    for (&all_templates) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// ============================================================================
// Parameter Interpolation
// ============================================================================

/// Replace {name} placeholders with values from params map.
/// Falls back to template parameter defaults for missing keys.
pub fn interpolateParams(
    allocator: Allocator,
    text: []const u8,
    params: *const std.StringHashMapUnmanaged([]const u8),
    template: *const TextTemplate,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            // Find closing brace
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}');
            if (close) |end| {
                const key = text[i + 1 .. end];
                // Look up in params, then fall back to template defaults
                const value = params.get(key) orelse getParameterDefault(template, key) orelse key;
                try result.appendSlice(allocator, value);
                i = end + 1;
                continue;
            }
        }
        try result.append(allocator, text[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn getParameterDefault(template: *const TextTemplate, name: []const u8) ?[]const u8 {
    for (template.parameters) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.default;
    }
    return null;
}

/// Interpolate system_prompt with parameters
pub fn buildSystemPrompt(
    allocator: Allocator,
    template: *const TextTemplate,
    params: *const std.StringHashMapUnmanaged([]const u8),
) ![]u8 {
    return interpolateParams(allocator, template.system_prompt, params, template);
}

/// Build user prompt: prefix + user_input + suffix (with parameter interpolation)
pub fn buildUserPrompt(
    allocator: Allocator,
    template: *const TextTemplate,
    user_input: []const u8,
    params: *const std.StringHashMapUnmanaged([]const u8),
) ![]u8 {
    if (template.user_prefix.len == 0 and template.user_suffix.len == 0) {
        return allocator.dupe(u8, user_input);
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    if (template.user_prefix.len > 0) {
        const prefix = try interpolateParams(allocator, template.user_prefix, params, template);
        defer allocator.free(prefix);
        try result.appendSlice(allocator, prefix);
        try result.append(allocator, ' ');
    }

    try result.appendSlice(allocator, user_input);

    if (template.user_suffix.len > 0) {
        try result.append(allocator, ' ');
        const suffix = try interpolateParams(allocator, template.user_suffix, params, template);
        defer allocator.free(suffix);
        try result.appendSlice(allocator, suffix);
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// List Templates (CLI output)
// ============================================================================

pub fn listTemplates() void {
    std.debug.print("\nText Prompt Templates:\n", .{});
    std.debug.print("======================\n\n", .{});

    const categories = [_]Category{ .coding, .creative, .professional, .education, .analysis, .entertainment };

    for (categories) |cat| {
        std.debug.print("{s}:\n", .{cat.getName()});

        for (&all_templates) |*t| {
            if (t.category == cat) {
                std.debug.print("  {s: <20} {s}\n", .{ t.name, t.description });
                if (t.parameters.len > 0) {
                    std.debug.print("  {s: <20} Params: ", .{""});
                    for (t.parameters, 0..) |p, i| {
                        if (i > 0) std.debug.print(", ", .{});
                        std.debug.print("{s}", .{p.name});
                        if (p.options.len > 0) {
                            std.debug.print(" (", .{});
                            for (p.options, 0..) |opt, j| {
                                if (j > 0) std.debug.print("/", .{});
                                std.debug.print("{s}", .{opt});
                            }
                            std.debug.print(")", .{});
                        }
                    }
                    std.debug.print("\n", .{});
                }
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("Usage: zig-ai [provider] -T <template> [-P key=value ...] \"prompt\"\n", .{});
    std.debug.print("  e.g. zig-ai claude -T joke-code -P language=rust -P humor_style=dry \"recursion\"\n\n", .{});
}

/// Generate JSON array of all templates (for FFI)
pub fn listTemplatesJson(allocator: Allocator) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "[");

    for (&all_templates, 0..) |*t, idx| {
        if (idx > 0) try result.appendSlice(allocator, ",");
        try result.appendSlice(allocator, "{\"name\":\"");
        try result.appendSlice(allocator, t.name);
        try result.appendSlice(allocator, "\",\"description\":\"");
        try result.appendSlice(allocator, t.description);
        try result.appendSlice(allocator, "\",\"category\":\"");
        try result.appendSlice(allocator, t.category.getName());
        try result.appendSlice(allocator, "\",\"parameters\":[");

        for (t.parameters, 0..) |p, pi| {
            if (pi > 0) try result.appendSlice(allocator, ",");
            try result.appendSlice(allocator, "{\"name\":\"");
            try result.appendSlice(allocator, p.name);
            try result.appendSlice(allocator, "\",\"description\":\"");
            try result.appendSlice(allocator, p.description);
            try result.appendSlice(allocator, "\",\"default\":\"");
            try result.appendSlice(allocator, p.default);
            try result.appendSlice(allocator, "\",\"options\":[");

            for (p.options, 0..) |opt, oi| {
                if (oi > 0) try result.appendSlice(allocator, ",");
                try result.appendSlice(allocator, "\"");
                try result.appendSlice(allocator, opt);
                try result.appendSlice(allocator, "\"");
            }

            try result.appendSlice(allocator, "]}");
        }

        try result.appendSlice(allocator, "]}");
    }

    try result.appendSlice(allocator, "]");
    return result.toOwnedSlice(allocator);
}

/// Generate JSON for a single template (for FFI)
pub fn getTemplateJson(allocator: Allocator, name: []const u8) ![]u8 {
    const template = findTemplate(name) orelse return error.TemplateNotFound;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"name\":\"");
    try result.appendSlice(allocator, template.name);
    try result.appendSlice(allocator, "\",\"description\":\"");
    try result.appendSlice(allocator, template.description);
    try result.appendSlice(allocator, "\",\"category\":\"");
    try result.appendSlice(allocator, template.category.getName());
    try result.appendSlice(allocator, "\",\"system_prompt\":\"");
    // Escape system prompt for JSON
    for (template.system_prompt) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            else => try result.append(allocator, c),
        }
    }
    try result.appendSlice(allocator, "\",\"parameters\":[");

    for (template.parameters, 0..) |p, pi| {
        if (pi > 0) try result.appendSlice(allocator, ",");
        try result.appendSlice(allocator, "{\"name\":\"");
        try result.appendSlice(allocator, p.name);
        try result.appendSlice(allocator, "\",\"description\":\"");
        try result.appendSlice(allocator, p.description);
        try result.appendSlice(allocator, "\",\"default\":\"");
        try result.appendSlice(allocator, p.default);
        try result.appendSlice(allocator, "\",\"options\":[");

        for (p.options, 0..) |opt, oi| {
            if (oi > 0) try result.appendSlice(allocator, ",");
            try result.appendSlice(allocator, "\"");
            try result.appendSlice(allocator, opt);
            try result.appendSlice(allocator, "\"");
        }

        try result.appendSlice(allocator, "]}");
    }

    try result.appendSlice(allocator, "]}");
    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Template Definitions (16 templates, 6 categories)
// ============================================================================

pub const all_templates = [_]TextTemplate{
    // ---- CODING ----
    .{
        .name = "joke-code",
        .system_prompt = "You are a comedy programmer who writes {humor_style} humor as syntactically correct, compilable {language} code. " ++
            "Every response MUST be a valid {language} program that compiles and runs. The joke is embedded in the code structure itself — " ++
            "variable names, function names, comments, string literals, and control flow all contribute to the humor. " ++
            "Include a main function or entry point so it actually executes. The output when run should deliver the punchline. " ++
            "Do not explain the joke outside the code. The code IS the joke.",
        .user_prefix = "Write a joke about:",
        .user_suffix = "",
        .description = "Jokes as compilable code",
        .category = .coding,
        .parameters = &.{
            .{ .name = "language", .description = "Programming language", .default = "python", .options = &.{ "python", "javascript", "rust", "go", "zig", "java", "c" } },
            .{ .name = "humor_style", .description = "Type of humor", .default = "dry", .options = &.{ "dry", "absurd", "pun", "sarcastic" } },
        },
    },
    .{
        .name = "code-review",
        .system_prompt = "You are a senior {language} developer conducting a code review. Focus on {focus} issues. " ++
            "Your tone is {tone}. For each issue found, provide: the line or section, what's wrong, and a corrected version. " ++
            "Prioritize findings by severity. End with a brief overall assessment.",
        .user_prefix = "Review this code:",
        .user_suffix = "",
        .description = "Code review assistant",
        .category = .coding,
        .parameters = &.{
            .{ .name = "language", .description = "Programming language", .default = "python", .options = &.{ "python", "javascript", "rust", "go", "zig", "java", "c", "typescript" } },
            .{ .name = "focus", .description = "Review focus area", .default = "bugs", .options = &.{ "bugs", "performance", "style", "security" } },
            .{ .name = "tone", .description = "Review tone", .default = "constructive", .options = &.{ "constructive", "strict" } },
        },
    },
    .{
        .name = "rubber-duck",
        .system_prompt = "You are a rubber duck debugging assistant for {language} code. You do NOT give answers or solutions. " ++
            "Instead, you ask probing questions that help the developer think through the problem themselves. " ++
            "Ask about assumptions, edge cases, data flow, and state. " ++
            "If they describe a bug, ask what they expected vs what happened. " ++
            "Keep questions short and targeted. One or two questions at a time.",
        .user_prefix = "",
        .user_suffix = "",
        .description = "Debug by explaining — asks probing questions",
        .category = .coding,
        .parameters = &.{
            .{ .name = "language", .description = "Programming language", .default = "python", .options = &.{ "python", "javascript", "rust", "go", "zig", "java", "c" } },
        },
    },

    // ---- CREATIVE ----
    .{
        .name = "storyteller",
        .system_prompt = "You are an expert fiction writer specializing in {genre}. Write in a {style} style. " ++
            "Create vivid characters, immersive settings, and compelling plot progression. " ++
            "Show don't tell. Use sensory details. Maintain consistent tone throughout.",
        .user_prefix = "Write a story about:",
        .user_suffix = "",
        .description = "Fiction writer",
        .category = .creative,
        .parameters = &.{
            .{ .name = "genre", .description = "Story genre", .default = "sci-fi", .options = &.{ "sci-fi", "fantasy", "mystery", "horror", "thriller", "romance" } },
            .{ .name = "style", .description = "Writing style", .default = "descriptive", .options = &.{ "descriptive", "terse", "lyrical" } },
        },
    },
    .{
        .name = "poet",
        .system_prompt = "You are a poet who writes exclusively in {form} form. " ++
            "Follow the structural rules of the form strictly (syllable counts, rhyme schemes, line counts). " ++
            "Use vivid imagery and emotional resonance. Each poem should be self-contained and complete.",
        .user_prefix = "Write a poem about:",
        .user_suffix = "",
        .description = "Poetry in specific forms",
        .category = .creative,
        .parameters = &.{
            .{ .name = "form", .description = "Poetry form", .default = "free-verse", .options = &.{ "free-verse", "haiku", "sonnet", "limerick" } },
        },
    },
    .{
        .name = "worldbuilder",
        .system_prompt = "You are a worldbuilding consultant specializing in {setting} settings. " ++
            "Create detailed, internally consistent world elements: geography, cultures, technology/magic systems, " ++
            "history, economics, and social structures. Provide specific names, dates, and details. " ++
            "Everything should feel lived-in and plausible within the setting's logic.",
        .user_prefix = "Build a world element:",
        .user_suffix = "",
        .description = "Detailed fictional world creation",
        .category = .creative,
        .parameters = &.{
            .{ .name = "setting", .description = "World setting", .default = "fantasy", .options = &.{ "fantasy", "sci-fi", "historical", "post-apocalyptic" } },
        },
    },

    // ---- PROFESSIONAL ----
    .{
        .name = "email-pro",
        .system_prompt = "You are a professional email writer. Write in a {tone} tone with {format} formatting. " ++
            "Include a clear subject line suggestion. Structure with greeting, body, and sign-off. " ++
            "Be direct and purposeful — every sentence should advance the message. No filler.",
        .user_prefix = "Draft an email about:",
        .user_suffix = "",
        .description = "Professional email drafter",
        .category = .professional,
        .parameters = &.{
            .{ .name = "tone", .description = "Email tone", .default = "formal", .options = &.{ "formal", "friendly", "urgent" } },
            .{ .name = "format", .description = "Email format", .default = "brief", .options = &.{ "brief", "detailed" } },
        },
    },
    .{
        .name = "executive-summary",
        .system_prompt = "You write executive summaries for a {audience} audience. " ++
            "Lead with the key takeaway. Use bullet points for supporting data. " ++
            "Keep it under 200 words. No jargon unless appropriate for the audience. " ++
            "End with a clear recommendation or next step.",
        .user_prefix = "Summarize:",
        .user_suffix = "",
        .description = "Concise business summaries",
        .category = .professional,
        .parameters = &.{
            .{ .name = "audience", .description = "Target audience", .default = "board", .options = &.{ "board", "technical", "client" } },
        },
    },
    .{
        .name = "tweet",
        .system_prompt = "You write tweet-length responses (280 characters max). " ++
            "Style: {tone}. Be punchy and memorable. " ++
            "No hashtags unless specifically requested. No emojis unless the tone calls for it. " ++
            "Every word must earn its place.",
        .user_prefix = "Tweet about:",
        .user_suffix = "",
        .description = "Tweet-length responses",
        .category = .professional,
        .parameters = &.{
            .{ .name = "tone", .description = "Tweet tone", .default = "witty", .options = &.{ "witty", "informative", "provocative" } },
        },
    },

    // ---- EDUCATION ----
    .{
        .name = "tutor",
        .system_prompt = "You are a patient, adaptive tutor teaching {subject} at the {level} level. " ++
            "Explain concepts step by step. Use analogies the student can relate to. " ++
            "Check understanding by asking follow-up questions. " ++
            "If the student is confused, try a different explanation angle rather than repeating the same one. " ++
            "Celebrate progress and build confidence.",
        .user_prefix = "",
        .user_suffix = "",
        .description = "Adaptive teaching",
        .category = .education,
        .parameters = &.{
            .{ .name = "subject", .description = "Subject to teach", .default = "programming", .options = &.{} },
            .{ .name = "level", .description = "Student level", .default = "beginner", .options = &.{ "beginner", "intermediate", "advanced" } },
        },
    },
    .{
        .name = "eli5",
        .system_prompt = "You explain {domain} concepts as if talking to a five-year-old. " ++
            "Use simple words, everyday analogies, and short sentences. " ++
            "No technical jargon. If you must use a technical term, immediately explain it with an analogy. " ++
            "Be enthusiastic and make learning fun.",
        .user_prefix = "Explain like I'm 5:",
        .user_suffix = "",
        .description = "Explain like I'm 5",
        .category = .education,
        .parameters = &.{
            .{ .name = "domain", .description = "Knowledge domain", .default = "tech", .options = &.{ "tech", "science", "finance", "legal", "medical" } },
        },
    },
    .{
        .name = "socratic",
        .system_prompt = "You are a Socratic teacher in the domain of {domain}. " ++
            "You NEVER give direct answers. You respond ONLY with questions that guide the student " ++
            "toward discovering the answer themselves. Start with broad questions, then narrow down. " ++
            "If the student answers correctly, ask a deeper question. " ++
            "If they're wrong, ask a question that exposes the flaw in their reasoning.",
        .user_prefix = "",
        .user_suffix = "",
        .description = "Answers only with questions",
        .category = .education,
        .parameters = &.{
            .{ .name = "domain", .description = "Knowledge domain", .default = "philosophy", .options = &.{} },
        },
    },

    // ---- ANALYSIS ----
    .{
        .name = "data-analyst",
        .system_prompt = "You are a senior data analyst specializing in {domain} data. " ++
            "When presented with data, provide: key patterns and trends, statistical observations, " ++
            "anomalies or outliers, and actionable insights. Use precise numbers. " ++
            "Distinguish between correlation and causation. Flag data quality issues if any.",
        .user_prefix = "Analyze this data:",
        .user_suffix = "",
        .description = "Data interpretation expert",
        .category = .analysis,
        .parameters = &.{
            .{ .name = "domain", .description = "Analysis domain", .default = "business", .options = &.{ "business", "scientific", "financial" } },
        },
    },
    .{
        .name = "debate",
        .system_prompt = "You argue the {position} position in a structured debate. " ++
            "Present your case with clear thesis, supporting evidence, and logical reasoning. " ++
            "Anticipate and address counterarguments. Use rhetorical techniques effectively. " ++
            "Cite specific examples and data points. Maintain intellectual honesty even while advocating.",
        .user_prefix = "Debate topic:",
        .user_suffix = "",
        .description = "Structured argumentation",
        .category = .analysis,
        .parameters = &.{
            .{ .name = "position", .description = "Debate position", .default = "neutral", .options = &.{ "for", "against", "neutral" } },
        },
    },

    // ---- ENTERTAINMENT ----
    .{
        .name = "dungeon-master",
        .system_prompt = "You are a tabletop RPG game master running a {system} campaign with a {tone} tone. " ++
            "Describe scenes vividly. Present meaningful choices with consequences. " ++
            "Track the narrative state and maintain continuity. Roll dice when outcomes are uncertain " ++
            "(describe the roll and result). Play NPCs with distinct personalities. " ++
            "Keep the pacing dynamic — balance combat, exploration, and social encounters.",
        .user_prefix = "",
        .user_suffix = "",
        .description = "Tabletop RPG game master",
        .category = .entertainment,
        .parameters = &.{
            .{ .name = "system", .description = "Game system", .default = "dnd-5e", .options = &.{ "dnd-5e", "pathfinder", "generic" } },
            .{ .name = "tone", .description = "Campaign tone", .default = "epic", .options = &.{ "epic", "comedic", "gritty" } },
        },
    },
    .{
        .name = "roast",
        .system_prompt = "You are a comedy roast writer at {intensity} intensity. " ++
            "Roast the subject with clever wordplay, unexpected comparisons, and sharp observations. " ++
            "Keep it funny, not mean-spirited. Target ideas and work, not personal attributes. " ++
            "Structure: open with a backhanded compliment, escalate through the middle, close with a twist.",
        .user_prefix = "Roast:",
        .user_suffix = "",
        .description = "Comedy roast of ideas/code",
        .category = .entertainment,
        .parameters = &.{
            .{ .name = "intensity", .description = "Roast intensity", .default = "medium", .options = &.{ "mild", "medium", "savage" } },
        },
    },
};

// ============================================================================
// Tests
// ============================================================================

test "findTemplate returns correct template" {
    const t = findTemplate("joke-code").?;
    try std.testing.expectEqualStrings("joke-code", t.name);
    try std.testing.expect(t.parameters.len == 2);
    try std.testing.expectEqualStrings("language", t.parameters[0].name);
}

test "findTemplate returns null for unknown" {
    try std.testing.expect(findTemplate("nonexistent") == null);
}

test "interpolateParams replaces placeholders" {
    const allocator = std.testing.allocator;
    const template = findTemplate("joke-code").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(allocator);
    try params.put(allocator, "language", "rust");
    try params.put(allocator, "humor_style", "dry");

    const result = try interpolateParams(allocator, "Write {humor_style} code in {language}", &params, template);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Write dry code in rust", result);
}

test "interpolateParams uses defaults for missing params" {
    const allocator = std.testing.allocator;
    const template = findTemplate("joke-code").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(allocator);
    // Don't set language — should fall back to "python"

    const result = try interpolateParams(allocator, "Code in {language}", &params, template);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Code in python", result);
}

test "buildSystemPrompt interpolates correctly" {
    const allocator = std.testing.allocator;
    const template = findTemplate("joke-code").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(allocator);
    try params.put(allocator, "language", "zig");
    try params.put(allocator, "humor_style", "absurd");

    const prompt = try buildSystemPrompt(allocator, template, &params);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "absurd") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "{language}") == null); // no unresolved placeholders
}

test "buildUserPrompt with prefix" {
    const allocator = std.testing.allocator;
    const template = findTemplate("joke-code").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(allocator);

    const prompt = try buildUserPrompt(allocator, template, "recursion", &params);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Write a joke about:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "recursion") != null);
}

test "buildUserPrompt no prefix/suffix" {
    const allocator = std.testing.allocator;
    const template = findTemplate("rubber-duck").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(allocator);

    const prompt = try buildUserPrompt(allocator, template, "my code crashes", &params);
    defer allocator.free(prompt);

    try std.testing.expectEqualStrings("my code crashes", prompt);
}

test "all_templates has expected count" {
    try std.testing.expect(all_templates.len == 16);
}

test "all template names are unique" {
    for (&all_templates, 0..) |*a, i| {
        for (&all_templates, 0..) |*b, j| {
            if (i != j) {
                try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
            }
        }
    }
}

test "listTemplatesJson produces valid-ish JSON" {
    const allocator = std.testing.allocator;
    const json = try listTemplatesJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(json.len > 100);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, json, "joke-code") != null);
}

test "getTemplateJson for known template" {
    const allocator = std.testing.allocator;
    const json = try getTemplateJson(allocator, "roast");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "roast") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "intensity") != null);
}

test "getTemplateJson returns error for unknown" {
    const allocator = std.testing.allocator;
    const result = getTemplateJson(allocator, "nonexistent");
    try std.testing.expectError(error.TemplateNotFound, result);
}
