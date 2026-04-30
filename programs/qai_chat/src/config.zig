//! Minimal TOML-ish config loader for qai_chat.
//!
//! Supports a flat global section + named sections, key=value pairs with
//! quoted-string / int / float / bool values. Comments start with `#`.
//! Not a full TOML parser — just enough for our config surface.

const std = @import("std");

pub const Provider = enum {
    anthropic,
    openai,
    gemini,
    grok,
    deepseek,

    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "anthropic") or std.mem.eql(u8, s, "claude")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "gemini") or std.mem.eql(u8, s, "google")) return .gemini;
        if (std.mem.eql(u8, s, "grok") or std.mem.eql(u8, s, "xai")) return .grok;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        return null;
    }

    pub fn name(self: Provider) []const u8 {
        return @tagName(self);
    }

    pub fn defaultBaseUrl(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "https://api.anthropic.com",
            .openai => "https://api.openai.com/v1",
            .gemini => "https://generativelanguage.googleapis.com/v1beta",
            .grok => "https://api.x.ai/v1",
            .deepseek => "https://api.deepseek.com/anthropic",
        };
    }

    pub fn defaultApiKeyEnv(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "ANTHROPIC_API_KEY",
            .openai => "OPENAI_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .grok => "XAI_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
        };
    }

    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "claude-sonnet-4-6",
            .openai => "gpt-5.4",
            .gemini => "gemini-2.5-flash",
            .grok => "grok-4-1-fast-non-reasoning",
            .deepseek => "deepseek-chat",
        };
    }
};

pub const ProviderSettings = struct {
    base_url: []const u8,
    api_key_env: []const u8,
};

pub const Config = struct {
    provider: Provider,
    model: []const u8,
    max_tokens: u32,
    temperature: f32,
    system_prompt: ?[]const u8,
    /// One entry per Provider enum variant. Indexed by @intFromEnum(Provider).
    providers: [5]ProviderSettings,
    /// Owns all the strings above. Free with deinit().
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// Returns the provider settings for the active provider.
    pub fn active(self: *const Config) ProviderSettings {
        return self.providers[@intFromEnum(self.provider)];
    }
};

/// Build a Config with all defaults. Caller must deinit.
pub fn defaults(gpa: std.mem.Allocator) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const provider: Provider = .anthropic;

    var providers: [5]ProviderSettings = undefined;
    inline for (std.meta.fields(Provider), 0..) |field, i| {
        const p: Provider = @enumFromInt(field.value);
        providers[i] = .{
            .base_url = try a.dupe(u8, p.defaultBaseUrl()),
            .api_key_env = try a.dupe(u8, p.defaultApiKeyEnv()),
        };
    }

    return .{
        .provider = provider,
        .model = try a.dupe(u8, provider.defaultModel()),
        .max_tokens = 4096,
        .temperature = 1.0,
        .system_prompt = null,
        .providers = providers,
        .arena = arena,
    };
}

/// Load config from a file path; merge over defaults.
pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Config {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return defaults(gpa),
        else => return err,
    };
    defer gpa.free(data);

    return parse(gpa, data);
}

/// Parse TOML-ish text. Caller must deinit.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Config {
    var cfg = try defaults(gpa);
    errdefer cfg.deinit();
    const a = cfg.arena.allocator();

    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = trim(stripComment(raw_line));
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = trim(line[1 .. line.len - 1]);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq]);
        const raw_val = trim(line[eq + 1 ..]);

        if (section.len == 0) {
            // Global section.
            if (eql(key, "provider")) {
                const v = try parseString(a, raw_val);
                if (Provider.parse(v)) |p| cfg.provider = p;
            } else if (eql(key, "model")) {
                cfg.model = try parseString(a, raw_val);
            } else if (eql(key, "max_tokens")) {
                cfg.max_tokens = parseU32(raw_val) orelse cfg.max_tokens;
            } else if (eql(key, "temperature")) {
                cfg.temperature = parseF32(raw_val) orelse cfg.temperature;
            } else if (eql(key, "system_prompt")) {
                const v = try parseString(a, raw_val);
                cfg.system_prompt = if (v.len == 0) null else v;
            }
        } else if (Provider.parse(section)) |p| {
            const idx = @intFromEnum(p);
            if (eql(key, "base_url")) {
                cfg.providers[idx].base_url = try parseString(a, raw_val);
            } else if (eql(key, "api_key_env")) {
                cfg.providers[idx].api_key_env = try parseString(a, raw_val);
            }
        }
    }

    return cfg;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn stripComment(line: []const u8) []const u8 {
    // Comments start with # outside of strings. We don't have escaped strings,
    // so a '#' inside a quoted value is allowed; track the quote state.
    var in_quote = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '"' => in_quote = !in_quote,
            '#' => if (!in_quote) return line[0..i],
            else => {},
        }
    }
    return line;
}

fn parseString(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return try a.dupe(u8, raw[1 .. raw.len - 1]);
    }
    return try a.dupe(u8, raw);
}

fn parseU32(raw: []const u8) ?u32 {
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseF32(raw: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, raw) catch null;
}

test "defaults round-trip" {
    var cfg = try defaults(std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(Provider.anthropic, cfg.provider);
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.active().base_url);
}

test "parse override" {
    const text =
        \\provider = "openai"
        \\model = "gpt-5.1"
        \\
        \\[anthropic]
        \\base_url = "https://api.quantumencoding.ai/proxy/anthropic"
        \\api_key_env = "QAI_TOKEN"
    ;
    var cfg = try parse(std.testing.allocator, text);
    defer cfg.deinit();
    try std.testing.expectEqual(Provider.openai, cfg.provider);
    try std.testing.expectEqualStrings("gpt-5.1", cfg.model);
    const a = cfg.providers[@intFromEnum(Provider.anthropic)];
    try std.testing.expectEqualStrings("https://api.quantumencoding.ai/proxy/anthropic", a.base_url);
    try std.testing.expectEqualStrings("QAI_TOKEN", a.api_key_env);
}
