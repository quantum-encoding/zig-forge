// Models endpoint — GET /qai/v1/models, GET /qai/v1/models/pricing
// Parses models.csv at compile time via @embedFile.
// Parses model_parameters.json at runtime on first use (too big for comptime).

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

/// Tick scale: 1 USD = 10^10 ticks. Mirrors `billing.TICKS_PER_USD` and
/// `account.TICKS_PER_USD`; redefining here keeps `Model` self-contained
/// when callers use it without the billing module.
pub const TICKS_PER_USD: i64 = 10_000_000_000;

/// Pricing is stored as fixed-point integer ticks. The CSV is the source
/// of truth (dollars-per-million-tokens), but every value is parsed into
/// integer ticks at comptime so the billing math never crosses an f64
/// boundary. Cures FLOAT-OBSESSION on the most security-sensitive path
/// in the server: cents the user pays.
pub const Model = struct {
    provider: []const u8,
    category: []const u8,
    internal_id: []const u8,
    api_model_id: []const u8,
    display_name: []const u8,
    context_window: []const u8,
    /// Ticks per million input tokens. $1/M → TICKS_PER_USD ticks/M.
    input_ticks_per_million: i64,
    /// Ticks per million output tokens.
    output_ticks_per_million: i64,
    /// Ticks per million cached-input tokens (Anthropic, OpenAI).
    cached_ticks_per_million: i64,
    /// Ticks per single unit (per-image, per-audio-second, etc.). 0 if N/A.
    per_unit_ticks: i64,
    price_unit: []const u8,
    /// Margin above provider cost, in basis points. e.g. 30% → 3000 bps.
    /// CSV stores a multiplier (1.30); we subtract 1.0 and scale by 10^4
    /// at parse time so all downstream math is integer.
    margin_bps: i32,
    route: []const u8,
    notes: []const u8,
};

const csv_data = @embedFile("models.csv");
const models = parseModels();
const model_count = models.len;

/// Stable version number for the per-model parameter schema shape emitted by
/// GET /qai/v1/models. Mirrors `ai.ModelParametersSchemaVersion` in the Go
/// backend. Bump on breaking changes (new parameter kinds, new availability
/// operators, etc.) so older clients can detect and degrade gracefully.
pub const schema_version: u32 = 1;

/// Embedded per-model parameter schemas — byte-identical mirror of the Go
/// backend's `data/model_parameters.json`. Keys are API model IDs; `_comment`
/// and any other `_`-prefixed keys are treated as file-level metadata and are
/// dropped on parse.
const model_parameters_json = @embedFile("model_parameters.json");

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
        .input_ticks_per_million = parseDollarTicks(fields[6]),
        .output_ticks_per_million = parseDollarTicks(fields[7]),
        .cached_ticks_per_million = parseDollarTicks(fields[8]),
        .per_unit_ticks = parseDollarTicks(fields[9]),
        .price_unit = fields[10],
        .margin_bps = parseMarginBps(fields[12]),
        .route = fields[13],
        .notes = if (field_idx >= 14) fields[14] else "",
    };
}

/// Parse a CSV cell as a fixed-point integer with the given `scale` (10^k).
/// "1.30" with scale=10000 → 13000. Optional leading `$` is stripped.
/// Empty cell, em-dash placeholder (`—` / `-`), or any non-digit prefix
/// returns 0 so the upstream billing path treats it as "no price set".
///
/// Critical: this never goes through f64. Floating-point parsing would
/// reintroduce the precision drift this batch is curing — a "$0.0001"
/// rate that rounded to 0 ticks would mean free billing on cached input.
fn parseFixedPoint(s: []const u8, comptime scale: i64) i64 {
    if (s.len == 0) return 0;
    // "—" is UTF-8 em-dash (0xE2 0x80 0x94); the CSV uses it for "N/A".
    if (s[0] == 0xE2) return 0;
    if (s.len == 1 and s[0] == '-') return 0;

    var i: usize = if (s[0] == '$') 1 else 0;
    // Negative prices are not a thing — treat as 0 to fail closed.
    if (i < s.len and s[i] == '-') return 0;

    var int_part: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        int_part = int_part * 10 + @as(i64, s[i] - '0');
    }

    var frac_part: i64 = 0;
    var frac_mult: i64 = scale;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            frac_mult = @divTrunc(frac_mult, 10);
            // If we've run out of fractional precision (frac_mult == 0)
            // truncate silently rather than overflow. Same behaviour
            // std.fmt.parseFloat would have had on excess digits.
            if (frac_mult == 0) break;
            frac_part = frac_part * 10 + @as(i64, s[i] - '0');
        }
    }

    return int_part * scale + frac_part * frac_mult;
}

/// "$3.00" / "3.00" → 30_000_000_000 ticks. Em-dash / empty → 0.
fn parseDollarTicks(s: []const u8) i64 {
    return parseFixedPoint(s, TICKS_PER_USD);
}

/// "1.30" → 3000 bps (30% margin). Empty / em-dash → 0 bps.
/// CSV margin is a multiplier; we subtract 1.0 at the integer scale so
/// downstream code can write `cost + (cost * margin_bps / 10_000)` and
/// stay in integers end-to-end.
fn parseMarginBps(s: []const u8) i32 {
    const scaled = parseFixedPoint(s, 10_000);
    if (scaled == 0) return 0;
    return @intCast(scaled - 10_000);
}

// ── Parameter registry ──────────────────────────────────────────────
//
// The Go backend lazily loads the parameter JSON on first lookup. We do the
// same here: parse into a map on first access, keep serialized array bytes
// per-model so subsequent response builds are zero-allocation slices.

const ParamRegistry = struct {
    /// Backing storage for the parsed JSON — must outlive `table` because
    /// hashmap values are slices into serialized buffers it owns.
    arena: std.heap.ArenaAllocator,
    /// model_id → serialized JSON array bytes (e.g. `[{"id":"..."}, ...]`).
    /// Missing keys mean "no schema registered" — callers omit the field.
    table: std.StringHashMapUnmanaged([]const u8),
};

var param_registry: ?ParamRegistry = null;
/// 0 = uninitialised, 1 = init in progress, 2 = ready.
/// Avoids needing an IO-coupled Mutex for a one-shot init.
var param_registry_state: std.atomic.Value(u32) = .init(0);

/// Initialize the parameter registry. Idempotent and thread-safe.
/// Called implicitly on first parameter lookup, but exposed so the server
/// can front-load the work at startup (main.zig).
pub fn initModelParameters(gpa: std.mem.Allocator) void {
    // Fast path: already ready.
    if (param_registry_state.load(.acquire) == 2) return;
    // Elect one initializer via CAS. Losers spin until state == 2.
    if (param_registry_state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        while (param_registry_state.load(.acquire) != 2) std.Thread.yield() catch {};
        return;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    const aa = arena.allocator();

    var table: std.StringHashMapUnmanaged([]const u8) = .{};

    // Parse the whole blob as a dynamic JSON object.
    const parsed = std.json.parseFromSlice(std.json.Value, aa, model_parameters_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Corrupt embedded JSON — leave registry empty, log once.
        std.debug.print("models: failed to parse model_parameters.json — parameters will be omitted\n", .{});
        param_registry = .{ .arena = arena, .table = table };
        param_registry_state.store(2, .release);
        return;
    };

    if (parsed.value != .object) {
        std.debug.print("models: model_parameters.json root is not an object\n", .{});
        param_registry = .{ .arena = arena, .table = table };
        param_registry_state.store(2, .release);
        return;
    }

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // File-level metadata keys (leading underscore) are comments/reserved.
        if (key.len == 0 or key[0] == '_') continue;

        // Each value must be an array of ParameterSpec objects. Drop empty/non-array.
        const v = entry.value_ptr.*;
        if (v != .array) continue;
        if (v.array.items.len == 0) continue;

        // Serialize this array once — later responses splice these bytes.
        const serialized = std.json.Stringify.valueAlloc(aa, v, .{}) catch continue;
        const key_copy = aa.dupe(u8, key) catch continue;
        table.put(aa, key_copy, serialized) catch continue;
    }

    param_registry = .{ .arena = arena, .table = table };
    param_registry_state.store(2, .release);
}

/// Returns serialized JSON array bytes for the given model's parameter
/// schema, or null if no schema is registered. The returned slice is owned
/// by the registry and valid for the process lifetime.
pub fn getModelParametersJson(allocator: std.mem.Allocator, model_id: []const u8) ?[]const u8 {
    initModelParameters(allocator);
    const reg = &(param_registry orelse return null);
    return reg.table.get(model_id);
}

/// Count of models that have a registered parameter schema. Testing helper.
pub fn getParameterModelCount(allocator: std.mem.Allocator) usize {
    initModelParameters(allocator);
    const reg = &(param_registry orelse return 0);
    return reg.table.count();
}

/// Tear down the parameter registry — releases arena memory.
/// Intended for tests; production keeps the registry alive for the process
/// lifetime (embedded data, lookup on every /qai/v1/models call).
pub fn deinitModelParameters() void {
    if (param_registry_state.load(.acquire) != 2) return;
    if (param_registry) |*reg| {
        reg.arena.deinit();
    }
    param_registry = null;
    param_registry_state.store(0, .release);
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

pub fn buildModelsJson(allocator: std.mem.Allocator) ![]u8 {
    // Front-load parameter parse so the first response isn't slow. Idempotent.
    initModelParameters(allocator);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Top-level envelope — schema_version + count + models. Mirrors the Go
    // backend's shape so CosmicDuckOS clients treat both backends identically.
    try buf.print(allocator,
        \\{{"schema_version":{d},"count":{d},"models":[
    , .{ schema_version, model_count });

    var first = true;
    for (models) |m| {
        if (!first) try buf.append(allocator, ',');
        first = false;

        // Build entry with all fields
        const has_token_pricing = m.input_ticks_per_million > 0 or m.output_ticks_per_million > 0;
        const has_unit_pricing = m.per_unit_ticks > 0;

        var in_buf: [32]u8 = undefined;
        var out_buf: [32]u8 = undefined;
        var cached_buf: [32]u8 = undefined;
        var unit_buf: [32]u8 = undefined;
        const in_str = formatDollarsPerMillion(&in_buf, m.input_ticks_per_million);
        const out_str = formatDollarsPerMillion(&out_buf, m.output_ticks_per_million);
        const cached_str = formatDollarsPerMillion(&cached_buf, m.cached_ticks_per_million);
        const unit_str = formatDollars(&unit_buf, m.per_unit_ticks);

        if (has_token_pricing and has_unit_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","context_window":"{s}","input_per_million":{s},"output_per_million":{s},"cached_per_million":{s},"per_unit_price":{s},"price_unit":"{s}","route":"{s}"
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.context_window, in_str, out_str, cached_str, unit_str, m.price_unit, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else if (has_token_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","context_window":"{s}","input_per_million":{s},"output_per_million":{s},"cached_per_million":{s},"route":"{s}"
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.context_window, in_str, out_str, cached_str, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else if (has_unit_pricing) {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","per_unit_price":{s},"price_unit":"{s}","route":"{s}"
            , .{ m.api_model_id, m.provider, m.display_name, m.category, unit_str, m.price_unit, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        } else {
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"id":"{s}","provider":"{s}","display_name":"{s}","category":"{s}","route":"{s}"
            , .{ m.api_model_id, m.provider, m.display_name, m.category, m.route });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        }

        // Append the parameters array only when a schema is registered. Omit
        // entirely otherwise — matches Go's `omitempty` so clients can use
        // hasOwnProperty("parameters") to detect schema availability.
        if (getModelParametersJson(allocator, m.api_model_id)) |params_json| {
            try buf.appendSlice(allocator, ",\"parameters\":");
            try buf.appendSlice(allocator, params_json);
        }

        try buf.append(allocator, '}');
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
        if (m.input_ticks_per_million == 0 and m.output_ticks_per_million == 0 and m.per_unit_ticks == 0) continue;

        if (!first) try buf.append(allocator, ',');
        first = false;

        var in_buf: [32]u8 = undefined;
        var out_buf: [32]u8 = undefined;
        var unit_buf: [32]u8 = undefined;
        const in_str = formatDollarsPerMillion(&in_buf, m.input_ticks_per_million);
        const out_str = formatDollarsPerMillion(&out_buf, m.output_ticks_per_million);
        const unit_str = formatDollars(&unit_buf, m.per_unit_ticks);

        const entry = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","provider":"{s}","display_name":"{s}","input_per_million":{s},"output_per_million":{s},"per_unit_price":{s},"price_unit":"{s}"}}
        , .{ m.api_model_id, m.provider, m.display_name, in_str, out_str, unit_str, m.price_unit });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Render an integer tick value as a decimal dollar string with 4
/// fractional digits — the precision the previous f64 `{d:.4}` formatter
/// emitted. e.g. `30_000_000_000 → "3.0000"`, `1_000_000 → "0.0001"`.
/// Integer truncation only (no rounding); matches the precision the CSV
/// holds. Buffer needs ~24 bytes (i64 dollars + '.' + 4 digits).
fn formatTicksDecimal4dp(buf: []u8, ticks: i64) []const u8 {
    // 10^10 ticks per USD; we want 4 fractional digits, so collapse the
    // trailing 10^(10-4) = 10^6 ticks via @divTrunc, then split into the
    // integer dollar part and the 4-digit fractional part.
    const dollars_scaled_4dp = @divTrunc(ticks, 1_000_000);
    const integer_part = @divTrunc(dollars_scaled_4dp, 10_000);
    const frac_part = @mod(dollars_scaled_4dp, 10_000);
    return std.fmt.bufPrint(buf, "{d}.{d:0>4}", .{ integer_part, frac_part }) catch buf[0..0];
}

fn formatDollarsPerMillion(buf: []u8, ticks_per_million: i64) []const u8 {
    return formatTicksDecimal4dp(buf, ticks_per_million);
}

fn formatDollars(buf: []u8, ticks: i64) []const u8 {
    return formatTicksDecimal4dp(buf, ticks);
}

pub const PricingError = error{UnknownModel};

/// Lookup pricing for a model by API ID. Returns
/// `error.UnknownModel` if the model isn't in the registry.
///
/// Audit H7 + H10. The previous implementation:
///   * Fell back to prefix-match (`startsWith`) when the exact match
///     failed. CSV order determined which prefix won — a caller
///     asking for `gpt-4o-2024-…` against a registry that includes a
///     cheap `gpt-4` could be billed at the cheap rate while the
///     actual upstream call hit the expensive model (the string
///     forwards verbatim).
///   * Silently fell back to `(input=3.0, output=15.0)` (Claude-Opus
///     rates) for unknown models — wildly wrong in both directions
///     depending on the actual upstream model.
/// Both paths are removed. Exact match only; unknown → error so the
/// chat handler can return 400 BEFORE the provider call.
pub fn getPricing(model_id: []const u8) PricingError!struct {
    input_ticks_per_million: i64,
    output_ticks_per_million: i64,
} {
    for (models) |m| {
        if (std.mem.eql(u8, m.api_model_id, model_id)) {
            return .{
                .input_ticks_per_million = m.input_ticks_per_million,
                .output_ticks_per_million = m.output_ticks_per_million,
            };
        }
    }
    return PricingError.UnknownModel;
}

/// Lookup a model by API ID. Returns the full Model
/// (provider, route, pricing, etc.). Same exact-match-only contract
/// as `getPricing`. Unknown returns null; callers must surface a
/// 400-class error rather than silently dispatching.
pub fn getModel(model_id: []const u8) ?Model {
    for (models) |m| {
        if (std.mem.eql(u8, m.api_model_id, model_id)) return m;
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
