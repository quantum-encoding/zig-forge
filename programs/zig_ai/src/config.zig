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
    data: ?std.StringHashMap(toml.Value),

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
            var iter = d.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            d.deinit();
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
                // Free user config after merge (keys were duped)
                var uc_mut = uc;
                uc_mut.deinit();
            } else {
                self.data = uc;
            }
        }
    }

    /// Load a single config file
    fn loadFile(self: *Self, path: []const u8) ?std.StringHashMap(toml.Value) {
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

        // Parse TOML
        var parser = toml.Parser.init(self.allocator, content);
        return parser.parse() catch null;
    }

    /// Merge source config into target (source values override)
    fn mergeConfigs(self: *Self, target: *std.StringHashMap(toml.Value), source: std.StringHashMap(toml.Value)) void {
        var iter = source.iterator();
        while (iter.next()) |entry| {
            const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;

            // If both are tables, merge recursively
            if (entry.value_ptr.* == .table) {
                if (target.get(key)) |existing| {
                    if (existing == .table) {
                        // Both are tables - merge at the table level
                        var existing_table = existing.table;
                        var source_table_iter = entry.value_ptr.table.iterator();
                        while (source_table_iter.next()) |src_entry| {
                            const sub_key = self.allocator.dupe(u8, src_entry.key_ptr.*) catch continue;
                            const sub_val = self.cloneValue(src_entry.value_ptr.*) catch continue;
                            existing_table.put(sub_key, sub_val) catch {
                                self.allocator.free(sub_key);
                            };
                        }
                        self.allocator.free(key);
                        continue;
                    }
                }
            }

            // Clone the value for insertion
            const cloned = self.cloneValue(entry.value_ptr.*) catch {
                self.allocator.free(key);
                continue;
            };
            target.put(key, cloned) catch {
                self.allocator.free(key);
            };
        }
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
                const new_arr = try self.allocator.alloc(toml.Value, arr.len);
                for (arr, 0..) |item, i| {
                    new_arr[i] = try self.cloneValue(item);
                }
                return toml.Value{ .array = new_arr };
            },
            .table => |t| {
                var new_table = std.StringHashMap(toml.Value).init(self.allocator);
                var iter = t.iterator();
                while (iter.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const value = try self.cloneValue(entry.value_ptr.*);
                    try new_table.put(key, value);
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
    var config = ModelConfig.init(allocator);
    defer config.deinit();

    // Without a config file, getModel returns null
    // getModelOr should return the default
    const model = config.getModelOr(Providers.anthropic, "default", Defaults.anthropic_default);
    try std.testing.expectEqualStrings(Defaults.anthropic_default, model);
}

test "Defaults constants" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", Defaults.anthropic_default);
    try std.testing.expectEqualStrings("dall-e-3", Defaults.dalle3);
    try std.testing.expectEqualStrings("lyria-002", Defaults.lyria);
}
