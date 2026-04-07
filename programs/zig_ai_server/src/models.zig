// Models endpoint — GET /qai/v1/models, GET /qai/v1/models/pricing
// Parses models.csv at compile time via @embedFile

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

pub const Model = struct {
    provider: []const u8,
    category: []const u8,
    internal_id: []const u8,
    api_model_id: []const u8,
    display_name: []const u8,
    context_window: []const u8,
    input_per_million: f64,
    output_per_million: f64,
    cached_per_million: f64,
    per_unit_price: f64,
    price_unit: []const u8,
    margin: f64,
    route: []const u8,
    notes: []const u8,
};

const csv_data = @embedFile("models.csv");
const models = parseModels();
const model_count = models.len;

fn parseModels() []const Model {
    @setEvalBranchQuota(500000);
    comptime {
        var result: [256]Model = undefined;
        var count: usize = 0;
        var line_iter = std.mem.splitScalar(u8, csv_data, '\n');

        // Skip header
        _ = line_iter.next();

        while (line_iter.next()) |line| {
            // Skip empty lines and comments
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            const m = parseLine(line) orelse continue;
            result[count] = m;
            count += 1;
        }

        const final = result[0..count].*;
        return &final;
    }
}

fn parseLine(line: []const u8) ?Model {
    // CSV: Provider,Category,Internal ID,API Model ID,Display Name,Context Window,
    //      Input ($/1M),Output ($/1M),Cached ($/1M),Per Unit Price,Price Unit,RPM,Margin,Route,Notes
    var fields: [15][]const u8 = .{""} ** 15;
    var field_idx: usize = 0;
    var i: usize = 0;

    while (i < line.len and field_idx < 15) {
        if (line[i] == ',') {
            field_idx += 1;
            i += 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ',') : (i += 1) {}
            fields[field_idx] = line[start..i];
            if (i < line.len and line[i] == ',') {
                field_idx += 1;
                i += 1;
            }
        }
    }

    // Need at least API Model ID (field 3) and Display Name (field 4)
    if (fields[3].len == 0 or fields[4].len == 0) return null;

    return .{
        .provider = fields[0],
        .category = fields[1],
        .internal_id = fields[2],
        .api_model_id = fields[3],
        .display_name = fields[4],
        .context_window = fields[5],
        .input_per_million = parseDollar(fields[6]),
        .output_per_million = parseDollar(fields[7]),
        .cached_per_million = parseDollar(fields[8]),
        .per_unit_price = parseDollar(fields[9]),
        .price_unit = fields[10],
        .margin = parseFloat(fields[12]),
        .route = fields[13],
        .notes = if (field_idx >= 14) fields[14] else "",
    };
}

fn parseDollar(s: []const u8) f64 {
    if (s.len == 0 or std.mem.eql(u8, s, "—") or std.mem.eql(u8, s, "-")) return 0;
    // Strip leading $
    const clean = if (s.len > 0 and s[0] == '$') s[1..] else s;
    return parseFloat(clean);
}

fn parseFloat(s: []const u8) f64 {
    if (s.len == 0) return 0;
    // "—" is UTF-8 em-dash (0xE2 0x80 0x94)
    if (s[0] == 0xE2 or s[0] == '-') return 0;
    @setEvalBranchQuota(10000);
    return std.fmt.parseFloat(f64, s) catch 0;
}

/// GET /qai/v1/models — full model registry
pub fn handleModels(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const json = buildModelsJson(allocator) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build models list"}
        };
    };
    return .{ .body = json };
}

/// GET /qai/v1/models/pricing — pricing table
pub fn handlePricing(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const json = buildPricingJson(allocator) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build pricing list"}
        };
    };
    return .{ .body = json };
}

fn buildModelsJson(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"models\":[");

    var first = true;
    for (models) |m| {
        if (!first) try buf.append(allocator, ',');
        first = false;

        // Build entry with all fields
        const has_token_pricing = m.input_per_million > 0 or m.output_per_million > 0;
        const has_unit_pricing = m.per_unit_price > 0;

        if (has_token_pricing and has_unit_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","context_window":"{s}","input_per_million":{d:.4},"output_per_million":{d:.4},"cached_per_million":{d:.4},"per_unit_price":{d:.4},"price_unit":"{s}","route":"{s}"}}
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.context_window, m.input_per_million, m.output_per_million, m.cached_per_million, m.per_unit_price, m.price_unit, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else if (has_token_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","context_window":"{s}","input_per_million":{d:.4},"output_per_million":{d:.4},"cached_per_million":{d:.4},"route":"{s}"}}
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.context_window, m.input_per_million, m.output_per_million, m.cached_per_million, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else if (has_unit_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","per_unit_price":{d:.4},"price_unit":"{s}","route":"{s}"}}
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.per_unit_price, m.price_unit, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","route":"{s}"}}
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        }
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn buildPricingJson(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"pricing\":[");

    var first = true;
    for (models) |m| {
        // Only include models with pricing
        if (m.input_per_million == 0 and m.output_per_million == 0 and m.per_unit_price == 0) continue;

        if (!first) try buf.append(allocator, ',');
        first = false;

        const entry = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","provider":"{s}","display_name":"{s}","input_per_million":{d:.4},"output_per_million":{d:.4},"per_unit_price":{d:.4},"price_unit":"{s}"}}
        , .{ m.api_model_id, m.provider, m.display_name, m.input_per_million, m.output_per_million, m.per_unit_price, m.price_unit });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Lookup pricing for a model by API ID. Returns (input_per_million, output_per_million).
pub fn getPricing(model_id: []const u8) struct { input: f64, output: f64 } {
    // Exact match first
    for (models) |m| {
        if (std.mem.eql(u8, m.api_model_id, model_id)) {
            return .{ .input = m.input_per_million, .output = m.output_per_million };
        }
    }
    // Prefix match (e.g. "claude-sonnet-4-6" matches "claude-sonnet-4-6-20250929")
    for (models) |m| {
        if (model_id.len >= m.api_model_id.len and
            std.mem.startsWith(u8, model_id, m.api_model_id))
        {
            return .{ .input = m.input_per_million, .output = m.output_per_million };
        }
    }
    // Default
    return .{ .input = 3.0, .output = 15.0 };
}

/// Lookup a model by API ID. Returns the full Model (provider, route, pricing, etc.)
pub fn getModel(model_id: []const u8) ?Model {
    // Exact match first
    for (models) |m| {
        if (std.mem.eql(u8, m.api_model_id, model_id)) return m;
    }
    // Prefix match (e.g. "claude-sonnet-4-6" matches "claude-sonnet-4-6-20250929")
    for (models) |m| {
        if (model_id.len >= m.api_model_id.len and
            std.mem.startsWith(u8, model_id, m.api_model_id))
        {
            return m;
        }
    }
    return null;
}

/// Route type for provider dispatch
pub const Route = enum {
    direct,        // Direct API: Anthropic, DeepSeek, xAI, OpenAI (API key auth)
    vertex_maas,   // Vertex Model-as-a-Service (GCP token auth, OpenAI-compat)
    vertex_native, // Vertex native Gemini (GCP token auth, generateContent)
    vertex_dedicated, // Vertex dedicated endpoints (GCP token auth)
    google_genai,  // Google AI Studio (API key auth, generativelanguage.googleapis.com)
    unknown,

    pub fn fromString(s: []const u8) Route {
        if (std.mem.eql(u8, s, "direct")) return .direct;
        if (std.mem.eql(u8, s, "cloud-run-egress")) return .direct; // same as direct
        if (std.mem.eql(u8, s, "vertex-maas")) return .vertex_maas;
        if (std.mem.eql(u8, s, "vertex-native")) return .vertex_native;
        if (std.mem.eql(u8, s, "vertex-dedicated")) return .vertex_dedicated;
        if (std.mem.eql(u8, s, "google-genai")) return .google_genai;
        return .unknown;
    }
};

/// Get the route for a model — determines which provider handler to use.
pub fn getRoute(model_id: []const u8) Route {
    if (getModel(model_id)) |m| return Route.fromString(m.route);
    return .unknown;
}

/// Get total number of models in registry
pub fn getModelCount() usize {
    return model_count;
}
