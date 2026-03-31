// Structured Output Templates
// Built-in templates that bundle JSON Schema + system prompt + parameters
// Used by CLI (-T flag in structured subcommand) and FFI for structured output generation

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

// ============================================================================
// Types
// ============================================================================

pub const Parameter = struct {
    name: []const u8,
    description: []const u8,
    default: []const u8,
    options: []const []const u8,
};

pub const StructuredTemplate = struct {
    name: []const u8,
    description: []const u8,
    category: Category,
    schema_name: []const u8,
    schema_json: []const u8, // Full JSON Schema (comptime const)
    system_prompt: []const u8, // May contain {param} placeholders
    parameters: []const Parameter,
};

pub const Category = enum {
    business,
    analysis,
    coding,
    creative,
    education,

    pub fn getName(self: Category) []const u8 {
        return switch (self) {
            .business => "Business",
            .analysis => "Analysis",
            .coding => "Coding",
            .creative => "Creative",
            .education => "Education",
        };
    }
};

// ============================================================================
// Template Lookup
// ============================================================================

pub fn findTemplate(name: []const u8) ?*const StructuredTemplate {
    for (&all_templates) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// ============================================================================
// Schema Bridge — comptime []const u8 → heap Schema
// ============================================================================

pub fn toSchema(allocator: Allocator, template: *const StructuredTemplate) !types.Schema {
    return .{
        .name = try allocator.dupe(u8, template.schema_name),
        .description = if (template.description.len > 0)
            try allocator.dupe(u8, template.description)
        else
            null,
        .schema_json = try allocator.dupe(u8, template.schema_json),
        .allocator = allocator,
    };
}

// ============================================================================
// Parameter Interpolation (same algorithm as text/templates.zig)
// ============================================================================

pub fn interpolateParams(
    allocator: Allocator,
    text: []const u8,
    params: *const std.StringHashMapUnmanaged([]const u8),
    template: *const StructuredTemplate,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}');
            if (close) |end| {
                const key = text[i + 1 .. end];
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

fn getParameterDefault(template: *const StructuredTemplate, name: []const u8) ?[]const u8 {
    for (template.parameters) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.default;
    }
    return null;
}

pub fn buildSystemPrompt(
    allocator: Allocator,
    template: *const StructuredTemplate,
    params: *const std.StringHashMapUnmanaged([]const u8),
) ![]u8 {
    return interpolateParams(allocator, template.system_prompt, params, template);
}

// ============================================================================
// List Templates (CLI output)
// ============================================================================

pub fn listTemplates() void {
    std.debug.print("\nStructured Output Templates:\n", .{});
    std.debug.print("============================\n\n", .{});

    const categories = [_]Category{ .business, .analysis, .coding, .creative, .education };

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

    std.debug.print("Usage: zig-ai structured -T <template> [-P key=value ...] \"prompt\"\n", .{});
    std.debug.print("  e.g. zig-ai structured -T product-listing -P detail_level=comprehensive \"iPhone 16\"\n\n", .{});
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

/// Generate JSON for a single template (for FFI) — includes schema_json
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
    try result.appendSlice(allocator, "\",\"schema\":");
    try result.appendSlice(allocator, template.schema_json);
    try result.appendSlice(allocator, ",\"system_prompt\":\"");
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
// Template Definitions (12 templates, 5 categories)
// ============================================================================

pub const all_templates = [_]StructuredTemplate{
    // ---- BUSINESS ----
    .{
        .name = "product-listing",
        .description = "Product details with features, pricing, and specs",
        .category = .business,
        .schema_name = "product_listing",
        .schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Product name"},"price":{"type":"number","description":"Price in USD"},"currency":{"type":"string","description":"Currency code"},"description":{"type":"string","description":"Product description"},"features":{"type":"array","items":{"type":"string"},"description":"Key features"},"categories":{"type":"array","items":{"type":"string"},"description":"Product categories"},"specs":{"type":"object","additionalProperties":{"type":"string"},"description":"Technical specifications"}},"required":["name","price","description","features","categories"],"additionalProperties":false}
        ,
        .system_prompt = "You are a product catalog assistant. Extract or generate structured product information at the {detail_level} detail level. " ++
            "For 'brief': name, price, short description, 3 features. " ++
            "For 'standard': all fields with moderate detail. " ++
            "For 'comprehensive': detailed description, 5+ features, full specs, multiple categories. " ++
            "Always return valid JSON matching the schema. Prices should be numeric (no currency symbols in the price field).",
        .parameters = &.{
            .{ .name = "detail_level", .description = "Amount of detail", .default = "standard", .options = &.{ "brief", "standard", "comprehensive" } },
        },
    },
    .{
        .name = "meeting-notes",
        .description = "Meeting summary with attendees, actions, and decisions",
        .category = .business,
        .schema_name = "meeting_notes",
        .schema_json =
        \\{"type":"object","properties":{"title":{"type":"string","description":"Meeting title"},"date":{"type":"string","description":"Meeting date (ISO 8601)"},"attendees":{"type":"array","items":{"type":"string"},"description":"List of attendees"},"discussion_points":{"type":"array","items":{"type":"object","properties":{"topic":{"type":"string"},"summary":{"type":"string"},"raised_by":{"type":"string"}},"required":["topic","summary"]},"description":"Discussion topics"},"action_items":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"assignee":{"type":"string"},"due_date":{"type":"string"}},"required":["task","assignee"]},"description":"Action items"},"decisions":{"type":"array","items":{"type":"object","properties":{"decision":{"type":"string"},"rationale":{"type":"string"}},"required":["decision"]},"description":"Decisions made"}},"required":["title","attendees","discussion_points","action_items","decisions"],"additionalProperties":false}
        ,
        .system_prompt = "You are a meeting notes assistant. Extract structured meeting information in {format} format. " ++
            "For 'action-items': focus on action items and assignees, brief discussion summaries. " ++
            "For 'full-minutes': comprehensive discussion summaries with who said what. " ++
            "For 'decisions-only': only decisions and their rationale. " ++
            "Infer dates and attendees from context. Use ISO 8601 for dates.",
        .parameters = &.{
            .{ .name = "format", .description = "Notes format", .default = "action-items", .options = &.{ "action-items", "full-minutes", "decisions-only" } },
        },
    },
    .{
        .name = "invoice",
        .description = "Invoice with line items, totals, and tax",
        .category = .business,
        .schema_name = "invoice",
        .schema_json =
        \\{"type":"object","properties":{"invoice_number":{"type":"string","description":"Invoice number"},"date":{"type":"string","description":"Invoice date (ISO 8601)"},"due_date":{"type":"string","description":"Payment due date"},"from":{"type":"object","properties":{"name":{"type":"string"},"address":{"type":"string"},"email":{"type":"string"}},"required":["name"]},"to":{"type":"object","properties":{"name":{"type":"string"},"address":{"type":"string"},"email":{"type":"string"}},"required":["name"]},"items":{"type":"array","items":{"type":"object","properties":{"description":{"type":"string"},"quantity":{"type":"number"},"unit_price":{"type":"number"},"total":{"type":"number"}},"required":["description","quantity","unit_price","total"]}},"subtotal":{"type":"number"},"tax_rate":{"type":"number","description":"Tax rate as percentage"},"tax_amount":{"type":"number"},"total":{"type":"number"},"currency":{"type":"string"}},"required":["invoice_number","date","items","subtotal","total","currency"],"additionalProperties":false}
        ,
        .system_prompt = "You are an invoice generation assistant. Create structured invoice data in {currency}. " ++
            "Calculate line item totals (quantity * unit_price). Sum for subtotal. Apply appropriate tax rate. " ++
            "Generate a plausible invoice number. All monetary values are numbers (no currency symbols). " ++
            "Tax rate is a percentage (e.g., 20 for 20%).",
        .parameters = &.{
            .{ .name = "currency", .description = "Currency code", .default = "USD", .options = &.{ "USD", "EUR", "GBP" } },
        },
    },
    .{
        .name = "resume-parse",
        .description = "Parsed resume with experience, education, and skills",
        .category = .business,
        .schema_name = "resume",
        .schema_json =
        \\{"type":"object","properties":{"name":{"type":"string"},"contact":{"type":"object","properties":{"email":{"type":"string"},"phone":{"type":"string"},"location":{"type":"string"},"linkedin":{"type":"string"}},"required":["email"]},"summary":{"type":"string","description":"Professional summary"},"experience":{"type":"array","items":{"type":"object","properties":{"company":{"type":"string"},"title":{"type":"string"},"start_date":{"type":"string"},"end_date":{"type":"string"},"achievements":{"type":"array","items":{"type":"string"}}},"required":["company","title"]}},"education":{"type":"array","items":{"type":"object","properties":{"institution":{"type":"string"},"degree":{"type":"string"},"field":{"type":"string"},"year":{"type":"string"}},"required":["institution","degree"]}},"skills":{"type":"array","items":{"type":"string"}}},"required":["name","experience","education","skills"],"additionalProperties":false}
        ,
        .system_prompt = "You are a resume parsing assistant using {format} format conventions. " ++
            "For 'standard': extract all sections with moderate detail. " ++
            "For 'tech': emphasize technical skills, projects, and technologies. " ++
            "For 'academic': emphasize publications, research, and academic achievements. " ++
            "Extract structured data from the resume text. Normalize dates to 'YYYY-MM' or 'YYYY' format.",
        .parameters = &.{
            .{ .name = "format", .description = "Resume format focus", .default = "standard", .options = &.{ "standard", "tech", "academic" } },
        },
    },

    // ---- ANALYSIS ----
    .{
        .name = "sentiment",
        .description = "Sentiment analysis with confidence and aspects",
        .category = .analysis,
        .schema_name = "sentiment_analysis",
        .schema_json =
        \\{"type":"object","properties":{"sentiment":{"type":"string","enum":["positive","negative","neutral","mixed"],"description":"Overall sentiment"},"confidence":{"type":"number","minimum":0,"maximum":1,"description":"Confidence score 0-1"},"aspects":{"type":"array","items":{"type":"object","properties":{"topic":{"type":"string","description":"Aspect being evaluated"},"sentiment":{"type":"string","enum":["positive","negative","neutral"]},"evidence":{"type":"string","description":"Quote or paraphrase supporting this"}},"required":["topic","sentiment","evidence"]},"description":"Per-aspect breakdown"},"summary":{"type":"string","description":"Brief natural language summary"}},"required":["sentiment","confidence","summary"],"additionalProperties":false}
        ,
        .system_prompt = "You are a sentiment analysis engine. Analyze text at the {granularity} level. " ++
            "For 'simple': overall sentiment, confidence, and summary only. " ++
            "For 'detailed': include 3-5 aspect breakdowns with evidence quotes. " ++
            "For 'aspect-based': comprehensive per-aspect analysis with all evidence. " ++
            "Confidence is a float between 0 and 1. Always include a human-readable summary.",
        .parameters = &.{
            .{ .name = "granularity", .description = "Analysis depth", .default = "detailed", .options = &.{ "simple", "detailed", "aspect-based" } },
        },
    },
    .{
        .name = "entity-extraction",
        .description = "Named entities with types, context, and relationships",
        .category = .analysis,
        .schema_name = "entities",
        .schema_json =
        \\{"type":"object","properties":{"entities":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string","description":"The entity text"},"type":{"type":"string","enum":["person","organization","location","date","money","product","event","other"],"description":"Entity type"},"context":{"type":"string","description":"Surrounding context"},"confidence":{"type":"number","minimum":0,"maximum":1}},"required":["text","type","confidence"]}},"relationships":{"type":"array","items":{"type":"object","properties":{"subject":{"type":"string"},"predicate":{"type":"string"},"object":{"type":"string"}},"required":["subject","predicate","object"]},"description":"Relationships between entities"},"entity_count":{"type":"integer"}},"required":["entities","entity_count"],"additionalProperties":false}
        ,
        .system_prompt = "You are a named entity recognition engine. Extract {entity_types} entities from the text. " ++
            "For 'people': focus on person names and their roles. " ++
            "For 'orgs': focus on organizations, companies, and institutions. " ++
            "For 'locations': focus on places, addresses, and geographic references. " ++
            "For 'all': extract all entity types. " ++
            "Include confidence scores and surrounding context. Identify relationships between entities where apparent.",
        .parameters = &.{
            .{ .name = "entity_types", .description = "Types to extract", .default = "all", .options = &.{ "people", "orgs", "locations", "all" } },
        },
    },
    .{
        .name = "classification",
        .description = "Text classification with label, confidence, and reasoning",
        .category = .analysis,
        .schema_name = "classification",
        .schema_json =
        \\{"type":"object","properties":{"label":{"type":"string","description":"Primary classification label"},"confidence":{"type":"number","minimum":0,"maximum":1,"description":"Confidence 0-1"},"reasoning":{"type":"string","description":"Why this classification was chosen"},"secondary_labels":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"confidence":{"type":"number","minimum":0,"maximum":1}},"required":["label","confidence"]},"description":"Alternative classifications"}},"required":["label","confidence","reasoning"],"additionalProperties":false}
        ,
        .system_prompt = "You are a text classification engine using {taxonomy} taxonomy. " ++
            "For 'topic': classify by subject matter (technology, politics, sports, science, etc.). " ++
            "For 'intent': classify by user intent (question, request, complaint, feedback, etc.). " ++
            "For 'priority': classify by urgency (critical, high, medium, low). " ++
            "Always provide reasoning for your primary classification and up to 3 secondary labels with confidence scores.",
        .parameters = &.{
            .{ .name = "taxonomy", .description = "Classification system", .default = "topic", .options = &.{ "topic", "intent", "priority" } },
        },
    },

    // ---- CODING ----
    .{
        .name = "code-review",
        .description = "Code review with issues, severity, and suggestions",
        .category = .coding,
        .schema_name = "code_review",
        .schema_json =
        \\{"type":"object","properties":{"issues":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["critical","warning","info"],"description":"Issue severity"},"line":{"type":"string","description":"Line number or code section"},"description":{"type":"string","description":"What is wrong"},"suggestion":{"type":"string","description":"How to fix it"}},"required":["severity","description","suggestion"]}},"summary":{"type":"string","description":"Overall assessment"},"score":{"type":"integer","minimum":0,"maximum":100,"description":"Code quality score 0-100"}},"required":["issues","summary","score"],"additionalProperties":false}
        ,
        .system_prompt = "You are a senior {language} code reviewer focusing on {focus} issues. " ++
            "For 'bugs': look for logic errors, off-by-one, null dereferences, race conditions. " ++
            "For 'security': look for injection, auth issues, data exposure, input validation. " ++
            "For 'performance': look for O(n^2) algorithms, unnecessary allocations, blocking calls. " ++
            "For 'style': look for naming, formatting, code organization, readability. " ++
            "Rate severity as critical/warning/info. Score 0-100 (100 = perfect).",
        .parameters = &.{
            .{ .name = "language", .description = "Programming language", .default = "python", .options = &.{ "python", "javascript", "rust", "go", "zig", "java", "c", "typescript" } },
            .{ .name = "focus", .description = "Review focus", .default = "bugs", .options = &.{ "bugs", "security", "performance", "style" } },
        },
    },
    .{
        .name = "api-spec",
        .description = "API specification with endpoints and models",
        .category = .coding,
        .schema_name = "api_spec",
        .schema_json =
        \\{"type":"object","properties":{"title":{"type":"string","description":"API title"},"version":{"type":"string","description":"API version"},"base_url":{"type":"string","description":"Base URL"},"endpoints":{"type":"array","items":{"type":"object","properties":{"method":{"type":"string","enum":["GET","POST","PUT","PATCH","DELETE"]},"path":{"type":"string"},"description":{"type":"string"},"parameters":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"in":{"type":"string","enum":["query","path","header","body"]},"type":{"type":"string"},"required":{"type":"boolean"}},"required":["name","in","type"]}},"request_body":{"type":"object","additionalProperties":true},"response":{"type":"object","additionalProperties":true}},"required":["method","path","description"]}},"models":{"type":"object","additionalProperties":{"type":"object","additionalProperties":true},"description":"Data models referenced by endpoints"}},"required":["title","endpoints"],"additionalProperties":false}
        ,
        .system_prompt = "You are an API design assistant generating {style} specifications. " ++
            "For 'openapi': generate REST-style endpoints with standard HTTP methods. " ++
            "For 'graphql': generate query/mutation structure adapted to the JSON schema format. " ++
            "Include request/response schemas, parameters, and data models. " ++
            "Follow REST best practices: plural nouns for resources, proper HTTP methods, consistent error responses.",
        .parameters = &.{
            .{ .name = "style", .description = "API style", .default = "openapi", .options = &.{ "openapi", "graphql" } },
        },
    },

    // ---- CREATIVE ----
    .{
        .name = "recipe",
        .description = "Recipe with ingredients, steps, and nutrition",
        .category = .creative,
        .schema_name = "recipe",
        .schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"Recipe name"},"servings":{"type":"integer","description":"Number of servings"},"prep_time_minutes":{"type":"integer"},"cook_time_minutes":{"type":"integer"},"difficulty":{"type":"string","enum":["easy","medium","hard"]},"ingredients":{"type":"array","items":{"type":"object","properties":{"item":{"type":"string"},"amount":{"type":"string"},"unit":{"type":"string"},"notes":{"type":"string"}},"required":["item","amount"]}},"steps":{"type":"array","items":{"type":"string"},"description":"Cooking steps in order"},"nutrition":{"type":"object","properties":{"calories":{"type":"integer"},"protein_g":{"type":"integer"},"carbs_g":{"type":"integer"},"fat_g":{"type":"integer"},"fiber_g":{"type":"integer"}},"description":"Per-serving nutrition estimate"},"tags":{"type":"array","items":{"type":"string"}}},"required":["name","servings","ingredients","steps"],"additionalProperties":false}
        ,
        .system_prompt = "You are a chef specializing in {cuisine} cuisine with {dietary} dietary considerations. " ++
            "For 'any' cuisine: use the best cuisine match for the requested dish. " ++
            "For specific cuisines: use authentic ingredients and techniques. " ++
            "For 'none' dietary: no restrictions. For 'vegan': no animal products. For 'gluten-free': no gluten. " ++
            "Include precise measurements, step-by-step instructions, and estimated nutrition per serving.",
        .parameters = &.{
            .{ .name = "cuisine", .description = "Cuisine type", .default = "any", .options = &.{ "any", "italian", "asian", "mexican", "french", "indian" } },
            .{ .name = "dietary", .description = "Dietary restrictions", .default = "none", .options = &.{ "none", "vegan", "gluten-free", "vegetarian", "keto" } },
        },
    },

    // ---- EDUCATION ----
    .{
        .name = "lesson-plan",
        .description = "Lesson plan with objectives, activities, and assessment",
        .category = .education,
        .schema_name = "lesson_plan",
        .schema_json =
        \\{"type":"object","properties":{"topic":{"type":"string","description":"Lesson topic"},"level":{"type":"string","description":"Student level"},"duration_minutes":{"type":"integer"},"objectives":{"type":"array","items":{"type":"string"},"description":"Learning objectives"},"materials":{"type":"array","items":{"type":"string"},"description":"Required materials"},"activities":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"duration_minutes":{"type":"integer"},"description":{"type":"string"},"type":{"type":"string","enum":["lecture","discussion","exercise","group-work","assessment"]}},"required":["name","duration_minutes","description","type"]},"description":"Lesson activities in order"},"assessment":{"type":"object","properties":{"method":{"type":"string"},"criteria":{"type":"array","items":{"type":"string"}}},"required":["method","criteria"]}},"required":["topic","level","duration_minutes","objectives","activities","assessment"],"additionalProperties":false}
        ,
        .system_prompt = "You are a curriculum designer creating lesson plans for {level} students. " ++
            "Duration: {duration} minutes. " ++
            "Include clear learning objectives (use Bloom's taxonomy verbs). " ++
            "Activities should be varied (mix of lecture, discussion, exercises, group work). " ++
            "Activity durations must sum to the total lesson duration. " ++
            "Assessment criteria should be specific and measurable.",
        .parameters = &.{
            .{ .name = "level", .description = "Student level", .default = "high", .options = &.{ "elementary", "middle", "high", "college" } },
            .{ .name = "duration", .description = "Lesson duration", .default = "45min", .options = &.{ "30min", "45min", "60min", "90min" } },
        },
    },
    .{
        .name = "quiz",
        .description = "Quiz with questions, answers, and explanations",
        .category = .education,
        .schema_name = "quiz",
        .schema_json =
        \\{"type":"object","properties":{"title":{"type":"string","description":"Quiz title"},"topic":{"type":"string","description":"Quiz topic"},"difficulty":{"type":"string","enum":["easy","medium","hard"]},"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"type":{"type":"string","enum":["multiple-choice","short-answer","true-false"]},"options":{"type":"array","items":{"type":"string"},"description":"Options for multiple-choice"},"correct_answer":{"type":"string"},"explanation":{"type":"string","description":"Why this is the correct answer"}},"required":["question","type","correct_answer","explanation"]}}},"required":["title","topic","difficulty","questions"],"additionalProperties":false}
        ,
        .system_prompt = "You are a quiz generator creating {difficulty} difficulty questions. " ++
            "Question types: {question_types}. " ++
            "For 'multiple-choice': provide 4 options (A-D), one correct. " ++
            "For 'short-answer': expect 1-3 sentence answers. " ++
            "For 'mixed': use a variety of question types. " ++
            "For 'true-false': clear true/false statements. " ++
            "Every question must have an explanation of the correct answer. Generate 5-10 questions.",
        .parameters = &.{
            .{ .name = "difficulty", .description = "Question difficulty", .default = "medium", .options = &.{ "easy", "medium", "hard" } },
            .{ .name = "question_types", .description = "Question format", .default = "multiple-choice", .options = &.{ "multiple-choice", "short-answer", "true-false", "mixed" } },
        },
    },
};

// ============================================================================
// Tests
// ============================================================================

test "findTemplate returns correct template" {
    const t = findTemplate("product-listing").?;
    try std.testing.expectEqualStrings("product-listing", t.name);
    try std.testing.expect(t.parameters.len == 1);
    try std.testing.expectEqualStrings("detail_level", t.parameters[0].name);
}

test "findTemplate returns null for unknown" {
    try std.testing.expect(findTemplate("nonexistent") == null);
}

test "all_templates has expected count" {
    try std.testing.expect(all_templates.len == 12);
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

test "toSchema bridges comptime to heap" {
    const alloc = std.testing.allocator;
    const template = findTemplate("sentiment").?;
    var schema = try toSchema(alloc, template);
    defer schema.deinit();

    try std.testing.expectEqualStrings("sentiment_analysis", schema.name);
    try std.testing.expect(schema.schema_json.len > 50);
    try std.testing.expect(schema.description != null);
}

test "interpolateParams replaces placeholders" {
    const alloc = std.testing.allocator;
    const template = findTemplate("code-review").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(alloc);
    try params.put(alloc, "language", "rust");
    try params.put(alloc, "focus", "security");

    const result = try interpolateParams(alloc, "Review {language} for {focus} issues", &params, template);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("Review rust for security issues", result);
}

test "interpolateParams uses defaults" {
    const alloc = std.testing.allocator;
    const template = findTemplate("sentiment").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(alloc);

    const result = try interpolateParams(alloc, "Analyze at {granularity} level", &params, template);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("Analyze at detailed level", result);
}

test "buildSystemPrompt interpolates correctly" {
    const alloc = std.testing.allocator;
    const template = findTemplate("recipe").?;

    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(alloc);
    try params.put(alloc, "cuisine", "italian");
    try params.put(alloc, "dietary", "vegan");

    const prompt = try buildSystemPrompt(alloc, template, &params);
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "italian") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "vegan") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "{cuisine}") == null);
}

test "listTemplatesJson produces valid JSON" {
    const alloc = std.testing.allocator;
    const json = try listTemplatesJson(alloc);
    defer alloc.free(json);

    try std.testing.expect(json.len > 100);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, json, "product-listing") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sentiment") != null);
}

test "getTemplateJson includes schema" {
    const alloc = std.testing.allocator;
    const json = try getTemplateJson(alloc, "invoice");
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "invoice") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "currency") != null);
}

test "getTemplateJson returns error for unknown" {
    const alloc = std.testing.allocator;
    const result = getTemplateJson(alloc, "nonexistent");
    try std.testing.expectError(error.TemplateNotFound, result);
}

test "all schemas start with valid JSON object" {
    for (&all_templates) |*t| {
        try std.testing.expect(t.schema_json.len > 10);
        try std.testing.expect(t.schema_json[0] == '{');
        try std.testing.expect(t.schema_json[t.schema_json.len - 1] == '}');
    }
}
