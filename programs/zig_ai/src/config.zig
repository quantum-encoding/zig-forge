const std = @import("std");
const toml = @import("zig_toml");
const Allocator = std.mem.Allocator;

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

/// Model configuration loaded from TOML files.
/// Priority: user config (~/.config/zig_ai/models.toml) > project config (./config/models.toml) > defaults
pub const ModelConfig = struct {
    allocator: Allocator,
    /// Parsed document root. `toml.Table` owns its keys and values
    /// recursively — one `deinit` frees the whole tree.
    data: ?toml.Table,

    const Self = @This();

    /// Initialize and load model configuration
    pub fn init(allocator: Allocator) Self {
        var config = Self{
            .allocator = allocator,
            .data = null,
        };
        config.load();
        return config;
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Self) void {
        if (self.data) |*d| {
            d.deinit(self.allocator);
            self.data = null;
        }
    }

    /// Load config files (project first, then user override)
    fn load(self: *Self) void {
        // Try project config first
        const project_config = self.loadFile("config/models.toml");
        if (project_config) |pc| {
            self.data = pc;
        }

        // Try user config (overrides project)
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.span(home_ptr);
        var path_buf: [512]u8 = undefined;
        const user_path = std.fmt.bufPrint(&path_buf, "{s}/.config/zig_ai/models.toml", .{home}) catch return;

        if (self.loadFile(user_path)) |uc| {
            if (self.data) |*existing| {
                // Merge user config into existing
                self.mergeConfigs(existing, uc);
                // The merge deep-copies everything it keeps, so the user
                // config's own tree is freed whole.
                var uc_mut = uc;
                uc_mut.deinit(self.allocator);
            } else {
                self.data = uc;
            }
        }
    }

    /// Load a single config file
    fn loadFile(self: *Self, path: []const u8) ?toml.Table {
        // Create null-terminated path for C
        var path_buf: [512]u8 = undefined;
        if (path.len >= path_buf.len - 1) return null;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Open file using C API
        const file = fopen(path_buf[0..path.len :0], "rb") orelse return null;
        defer _ = fclose(file);

        // Get file size
        if (fseek(file, 0, SEEK_END) != 0) return null;
        const size_long = ftell(file);
        if (size_long < 0) return null;
        const size: usize = @intCast(size_long);
        if (size > 1024 * 1024) return null; // Max 1MB
        if (fseek(file, 0, SEEK_SET) != 0) return null;

        // Read content
        const content = self.allocator.alloc(u8, size) catch return null;
        defer self.allocator.free(content);

        const bytes_read = fread(content.ptr, 1, size, file);
        if (bytes_read != size) return null;

        // Parse TOML. `parseToml` owns the parser lifecycle and frees partial
        // state on error, so a malformed file yields null with nothing leaked.
        return toml.parseToml(self.allocator, content) catch null;
    }

    /// Merge source config into target (source values override)
    fn mergeConfigs(self: *Self, target: *toml.Table, source: toml.Table) void {
        var source_mut = source;
        var iter = source_mut.iterator();
        while (iter.next()) |entry| {
            // A section present in both configs merges key-by-key, so a user
            // config that overrides one model does not drop the rest of the
            // project's section. Anything below that level is replaced whole:
            // models.toml is section/key shaped, and staying iterative here
            // avoids recursing over a `[a.b.c…]` chain, which can nest deeper
            // than the parser's inline-depth cap.
            if (entry.value_ptr.* == .table) {
                if (target.get(entry.key_ptr.*)) |existing| {
                    if (existing == .table) {
                        var section_iter = entry.value_ptr.table.iterator();
                        while (section_iter.next()) |src_entry| {
                            self.putOwned(existing.table, src_entry.key_ptr.*, src_entry.value_ptr.*);
                        }
                        continue;
                    }
                }
            }

            self.putOwned(target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Deep-copy `value` under `key` into `table`, freeing whatever the table
    /// already held there. On allocation failure the table is left untouched —
    /// a partial merge keeps the lower-priority config rather than a torn one.
    fn putOwned(self: *Self, table: *toml.Table, key: []const u8, value: toml.Value) void {
        var cloned = self.cloneValue(value) catch return;

        const owned_key = self.allocator.dupe(u8, key) catch {
            cloned.deinit(self.allocator);
            return;
        };
        const gop = table.entries.getOrPut(owned_key) catch {
            self.allocator.free(owned_key);
            cloned.deinit(self.allocator);
            return;
        };
        if (gop.found_existing) {
            // The table already owns an equal key; keep it and drop the copy.
            self.allocator.free(owned_key);
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = cloned;
    }

    /// Clone a Value (deep copy)
    fn cloneValue(self: *Self, val: toml.Value) !toml.Value {
        return switch (val) {
            .string => |s| toml.Value{ .string = try self.allocator.dupe(u8, s) },
            .integer => |i| toml.Value{ .integer = i },
            .float => |f| toml.Value{ .float = f },
            .boolean => |b| toml.Value{ .boolean = b },
            .datetime => |d| toml.Value{ .datetime = try self.allocator.dupe(u8, d) },
            .array => |arr| {
                var new_arr: toml.Array = .{ .items = .empty, .is_aot = arr.is_aot };
                errdefer new_arr.deinit(self.allocator);

                try new_arr.items.ensureTotalCapacityPrecise(self.allocator, arr.items.items.len);
                for (arr.items.items) |item| {
                    new_arr.items.appendAssumeCapacity(try self.cloneValue(item));
                }
                return toml.Value{ .array = new_arr };
            },
            .table => |t| {
                // Nested tables are heap-allocated for pointer stability, the
                // same contract the parser builds them under.
                const new_table = try self.allocator.create(toml.Table);
                errdefer self.allocator.destroy(new_table);
                new_table.* = toml.Table.init(self.allocator);
                new_table.kind = t.kind;
                errdefer new_table.deinit(self.allocator);

                var iter = t.iterator();
                while (iter.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(key);
                    var value = try self.cloneValue(entry.value_ptr.*);
                    errdefer value.deinit(self.allocator);
                    try new_table.entries.put(key, value);
                }
                return toml.Value{ .table = new_table };
            },
        };
    }

    /// Get a model name from config
    /// Example: getModel("anthropic", "default") returns "claude-3-7-sonnet-20250219"
    pub fn getModel(self: *const Self, section: []const u8, key: []const u8) ?[]const u8 {
        const data = self.data orelse return null;
        const section_value = data.get(section) orelse return null;
        if (section_value != .table) return null;
        const table = section_value.table;
        const value = table.get(key) orelse return null;
        if (value != .string) return null;
        return value.string;
    }

    /// Get model or return a default
    pub fn getModelOr(self: *const Self, section: []const u8, key: []const u8, default: []const u8) []const u8 {
        return self.getModel(section, key) orelse default;
    }

    /// Get main (best quality) model for a provider section
    /// Tries "main" first, falls back to "default"
    pub fn getMainModel(self: *const Self, section: []const u8) ?[]const u8 {
        return self.getModel(section, "main") orelse self.getModel(section, "default");
    }

    /// Get small (cheapest/fastest) model for a provider section
    /// Tries "small" first, falls back to main model
    pub fn getSmallModel(self: *const Self, section: []const u8) ?[]const u8 {
        return self.getModel(section, "small") orelse self.getMainModel(section);
    }

    /// Get all available model names from a section (model_1, model_2, etc.)
    /// Returns models in a caller-provided buffer. Returns count of models found.
    pub fn getAvailableModels(self: *const Self, section: []const u8, buf: [][]const u8) usize {
        const data = self.data orelse return 0;
        const section_value = data.get(section) orelse return 0;
        if (section_value != .table) return 0;
        const table = section_value.table;

        var count: usize = 0;
        // Collect model_1 through model_20
        var i: usize = 1;
        while (i <= 20 and count < buf.len) : (i += 1) {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "model_{d}", .{i}) catch break;
            if (table.get(key)) |value| {
                if (value == .string) {
                    buf[count] = value.string;
                    count += 1;
                }
            }
        }
        return count;
    }
};

// Convenience functions for specific providers
pub const Providers = struct {
    pub const anthropic = "anthropic";
    pub const deepseek = "deepseek";
    pub const google = "google";
    pub const vertex = "vertex";
    pub const xai = "xai";
    pub const openai = "openai";
    pub const image = "image";
    pub const video = "video";
    pub const music = "music";
};

/// Hardcoded defaults (fallback when no config loaded)
/// Tiered: main = best quality, small = cheapest/fastest
pub const Defaults = struct {
    // Text models — main tier (updated 2026-03)
    pub const anthropic_default = "claude-sonnet-4-6";
    pub const deepseek_default = "deepseek-chat";
    pub const google_default = "gemini-2.5-flash";
    pub const vertex_default = "gemini-2.5-pro";
    pub const xai_default = "grok-4-1-fast-non-reasoning";
    pub const openai_default = "gpt-5.2";

    // Text models — small tier
    pub const anthropic_small = "claude-haiku-4-5-20251001";
    pub const deepseek_small = "deepseek-chat";
    pub const google_small = "gemini-2.5-flash-lite";
    pub const vertex_small = "gemini-2.5-flash";
    pub const xai_small = "grok-4-1-fast-non-reasoning";
    pub const openai_small = "gpt-5-mini";

    // Codex models
    pub const openai_codex = "gpt-5.2-codex";
    pub const openai_codex_v5 = "gpt-5-codex";

    // Image models
    pub const dalle3 = "dall-e-3";
    pub const dalle2 = "dall-e-2";
    pub const gpt_image = "gpt-image-1";
    pub const grok_image = "grok-2-image";
    pub const imagen_genai = "imagen-4.0-generate-001";
    pub const imagen_vertex = "imagegeneration@006";
    pub const gemini_flash_image = "gemini-2.5-flash-image";

    // Video models
    pub const sora = "sora-2-2025-12-08";
    pub const veo = "veo-3.1-generate-001";

    // Music models
    pub const lyria = "lyria-002";
    pub const lyria_realtime = "lyria-realtime-exp";
};

/// Global config instance (lazy initialized)
var global_config: ?ModelConfig = null;
var global_config_allocator: ?Allocator = null;

/// Get or create the global config instance
pub fn getGlobalConfig(allocator: Allocator) *ModelConfig {
    if (global_config == null) {
        global_config = ModelConfig.init(allocator);
        global_config_allocator = allocator;
    }
    return &global_config.?;
}

/// Cleanup global config
pub fn deinitGlobalConfig() void {
    if (global_config) |*gc| {
        gc.deinit();
        global_config = null;
        global_config_allocator = null;
    }
}

// Tests
test "ModelConfig defaults" {
    const allocator = std.testing.allocator;

    // No document loaded, so every lookup misses and the caller's default
    // wins. Constructed directly rather than through `init`, which reads the
    // real ~/.config/zig_ai/models.toml — asserting a specific model after
    // that would make this pass or fail on whose machine it runs.
    var config = ModelConfig{ .allocator = allocator, .data = null };
    defer config.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), config.getModel(Providers.anthropic, "default"));
    const model = config.getModelOr(Providers.anthropic, "default", Defaults.anthropic_default);
    try std.testing.expectEqualStrings(Defaults.anthropic_default, model);
}

test "ModelConfig.init parses and frees whatever config is on disk" {
    // Environment-dependent by nature, so it asserts only that the load path
    // survives the real files: parse, merge, and free without leaking (the
    // testing allocator fails the test on a leak) — never that a particular
    // model is configured.
    var config = ModelConfig.init(std.testing.allocator);
    defer config.deinit();

    _ = config.getModelOr(Providers.anthropic, "default", Defaults.anthropic_default);
}

test "Defaults constants" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", Defaults.anthropic_default);
    try std.testing.expectEqualStrings("dall-e-3", Defaults.dalle3);
    try std.testing.expectEqualStrings("lyria-002", Defaults.lyria);
}

test "user config overrides one model without dropping the rest of the section" {
    const allocator = std.testing.allocator;

    const project = try toml.parseToml(allocator,
        \\[anthropic]
        \\main = "claude-opus-4"
        \\small = "claude-haiku-4"
        \\
        \\[openai]
        \\main = "gpt-5"
        \\
    );
    var config = ModelConfig{ .allocator = allocator, .data = project };
    defer config.deinit();

    var user = try toml.parseToml(allocator,
        \\[anthropic]
        \\main = "claude-sonnet-4-6"
        \\
        \\[xai]
        \\main = "grok-4-1"
        \\
    );
    config.mergeConfigs(&config.data.?, user);
    // Free the source before reading the result: a merge that borrowed rather
    // than copied would be reading freed memory from here on.
    user.deinit(allocator);

    try std.testing.expectEqualStrings("claude-sonnet-4-6", config.getModel("anthropic", "main").?);
    // The regression this pins: a section present in both configs must merge
    // key-by-key, not replace wholesale.
    try std.testing.expectEqualStrings("claude-haiku-4", config.getModel("anthropic", "small").?);
    try std.testing.expectEqualStrings("gpt-5", config.getModel("openai", "main").?);
    try std.testing.expectEqualStrings("grok-4-1", config.getModel("xai", "main").?);
}

test "merge deep-copies arrays and nested tables out of the user config" {
    const allocator = std.testing.allocator;

    const project = try toml.parseToml(allocator,
        \\[vertex]
        \\main = "gemini-2.5-pro"
        \\regions = ["us-central1"]
        \\
    );
    var config = ModelConfig{ .allocator = allocator, .data = project };
    defer config.deinit();

    var user = try toml.parseToml(allocator,
        \\[vertex]
        \\regions = ["europe-west4", "us-east5"]
        \\limits = { rpm = 60 }
        \\
    );

    // Deep copy, not aliasing: the merged string must not point into the
    // user config's buffers.
    const user_region = user.get("vertex").?.table.get("regions").?.array.items.items[0].string;
    config.mergeConfigs(&config.data.?, user);
    const merged_vertex = config.data.?.get("vertex").?.table;
    const merged_regions = merged_vertex.get("regions").?.array;
    try std.testing.expect(merged_regions.items.items[0].string.ptr != user_region.ptr);

    user.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), merged_regions.items.items.len);
    try std.testing.expectEqualStrings("europe-west4", merged_regions.items.items[0].string);
    try std.testing.expectEqualStrings("us-east5", merged_regions.items.items[1].string);
    // A nested table added by the user config survives the copy...
    try std.testing.expectEqual(@as(i64, 60), merged_vertex.get("limits").?.table.get("rpm").?.integer);
    // ...and a key only the project config set is still there.
    try std.testing.expectEqualStrings("gemini-2.5-pro", config.getModel("vertex", "main").?);
}
