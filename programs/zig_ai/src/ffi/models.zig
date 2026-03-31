// FFI Model Discovery — runtime model listing from TOML config
//
// Provides C-compatible functions for app dropdowns:
//   zig_ai_get_main_model(provider) → model name
//   zig_ai_get_small_model(provider) → model name
//   zig_ai_list_models(provider) → JSON array

const std = @import("std");
const types = @import("types.zig");
const config = @import("../config.zig");

const CTextProvider = types.CTextProvider;
const CString = types.CString;
const CStringResult = types.CStringResult;

/// Map CTextProvider to config section name
fn providerSection(provider: CTextProvider) []const u8 {
    return switch (provider) {
        .claude => config.Providers.anthropic,
        .deepseek => config.Providers.deepseek,
        .gemini => config.Providers.google,
        .grok => config.Providers.xai,
        .openai => config.Providers.openai,
        .vertex => config.Providers.vertex,
        .unknown => "unknown",
    };
}

/// Get main model for a provider (comptime fallback if no config)
fn mainFallback(provider: CTextProvider) []const u8 {
    return switch (provider) {
        .claude => config.Defaults.anthropic_default,
        .deepseek => config.Defaults.deepseek_default,
        .gemini => config.Defaults.google_default,
        .grok => config.Defaults.xai_default,
        .openai => config.Defaults.openai_default,
        .vertex => config.Defaults.vertex_default,
        .unknown => "unknown",
    };
}

/// Get small model for a provider (comptime fallback)
fn smallFallback(provider: CTextProvider) []const u8 {
    return switch (provider) {
        .claude => config.Defaults.anthropic_small,
        .deepseek => config.Defaults.deepseek_small,
        .gemini => config.Defaults.google_small,
        .grok => config.Defaults.xai_small,
        .openai => config.Defaults.openai_small,
        .vertex => config.Defaults.vertex_small,
        .unknown => "unknown",
    };
}

// Use a simple allocator for FFI string allocations

pub fn getMainModelForProvider(provider: CTextProvider) CString {
    const section = providerSection(provider);
    const allocator = std.heap.c_allocator;

    var cfg = config.ModelConfig.init(allocator);
    defer cfg.deinit();

    const model = cfg.getMainModel(section) orelse mainFallback(provider);
    return CString.fromSlice(model);
}

pub fn getSmallModelForProvider(provider: CTextProvider) CString {
    const section = providerSection(provider);
    const allocator = std.heap.c_allocator;

    var cfg = config.ModelConfig.init(allocator);
    defer cfg.deinit();

    const model = cfg.getSmallModel(section) orelse smallFallback(provider);
    return CString.fromSlice(model);
}

pub fn listModelsForProvider(provider: CTextProvider) CStringResult {
    const section = providerSection(provider);
    const allocator = std.heap.c_allocator;

    var cfg = config.ModelConfig.init(allocator);
    defer cfg.deinit();

    var model_buf: [20][]const u8 = undefined;
    const count = cfg.getAvailableModels(section, &model_buf);

    // If no models in config, return fallback main+small
    if (count == 0) {
        const main_m = mainFallback(provider);
        const small_m = smallFallback(provider);

        if (std.mem.eql(u8, main_m, small_m)) {
            // Only one unique model
            const json = std.fmt.allocPrint(allocator, "[\"{s}\"]", .{main_m}) catch {
                return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
            };
            const json_z = allocator.allocSentinel(u8, json.len, 0) catch {
                allocator.free(json);
                return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
            };
            @memcpy(json_z, json);
            allocator.free(json);
            return CStringResult{ .success = true, .error_code = 0, .error_message = .{ .ptr = null, .len = 0 }, .value = .{ .ptr = json_z.ptr, .len = json_z.len } };
        } else {
            const json = std.fmt.allocPrint(allocator, "[\"{s}\",\"{s}\"]", .{ main_m, small_m }) catch {
                return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
            };
            const json_z = allocator.allocSentinel(u8, json.len, 0) catch {
                allocator.free(json);
                return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
            };
            @memcpy(json_z, json);
            allocator.free(json);
            return CStringResult{ .success = true, .error_code = 0, .error_message = .{ .ptr = null, .len = 0 }, .value = .{ .ptr = json_z.ptr, .len = json_z.len } };
        }
    }

    // Build JSON array from config models
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    json_buf.append(allocator, '[') catch {
        return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
    };

    for (model_buf[0..count], 0..) |model, i| {
        if (i > 0) json_buf.append(allocator, ',') catch break;
        json_buf.append(allocator, '"') catch break;
        json_buf.appendSlice(allocator, model) catch break;
        json_buf.append(allocator, '"') catch break;
    }

    json_buf.append(allocator, ']') catch {};

    // Copy to null-terminated allocation for C consumer
    const json_z = allocator.allocSentinel(u8, json_buf.items.len, 0) catch {
        return CStringResult{ .success = false, .error_code = types.ErrorCode.OUT_OF_MEMORY, .error_message = CString.fromSlice("out of memory"), .value = .{ .ptr = null, .len = 0 } };
    };
    @memcpy(json_z, json_buf.items);

    return CStringResult{ .success = true, .error_code = 0, .error_message = .{ .ptr = null, .len = 0 }, .value = .{ .ptr = json_z.ptr, .len = json_z.len } };
}

pub fn freeString(s: CString) void {
    if (s.ptr) |p| {
        // Reconstruct the sentinel-terminated slice and free it
        const slice = p[0..s.len :0];
        std.heap.c_allocator.free(slice);
    }
}
