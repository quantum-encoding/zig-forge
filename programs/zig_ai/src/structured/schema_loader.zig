// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Schema loader for structured output JSON schemas
//!
//! Loads schemas from:
//! 1. User schemas: ~/.config/zig_ai/schemas/*.json (priority)
//! 2. Project schemas: ./config/schemas/*.json
//!
//! Schema file format:
//! {
//!   "name": "schema_name",
//!   "description": "Optional description",
//!   "schema": { ... JSON Schema ... }
//! }

const std = @import("std");
const types = @import("types.zig");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn opendir(name: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(dirp: *anyopaque) c_int;
extern "c" fn readdir(dirp: *anyopaque) ?*Dirent;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

pub const SchemaLoader = struct {
    allocator: std.mem.Allocator,
    schemas: std.StringHashMap(types.Schema),

    pub fn init(allocator: std.mem.Allocator) SchemaLoader {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(types.Schema).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaLoader) void {
        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            var schema = entry.value_ptr.*;
            schema.deinit();
        }
        self.schemas.deinit();
    }

    /// Load all schemas from config directories
    pub fn loadAll(self: *SchemaLoader) !void {
        // Load project schemas first (lower priority)
        self.loadFromDirectory("config/schemas") catch {};

        // Load user schemas (higher priority, overrides project)
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.span(home_ptr);

        var user_path_buf: [512]u8 = undefined;
        const user_path = std.fmt.bufPrint(&user_path_buf, "{s}/.config/zig_ai/schemas", .{home}) catch return;

        // Null-terminate for C
        if (user_path.len < user_path_buf.len) {
            user_path_buf[user_path.len] = 0;
            self.loadFromDirectory(user_path_buf[0..user_path.len :0]) catch {};
        }
    }

    /// Get schema by name
    pub fn get(self: *const SchemaLoader, name: []const u8) ?*const types.Schema {
        return self.schemas.getPtr(name);
    }

    /// Get number of loaded schemas
    pub fn count(self: *const SchemaLoader) usize {
        return self.schemas.count();
    }

    /// List all available schema names
    pub fn listNames(self: *const SchemaLoader, allocator: std.mem.Allocator) ![][]const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(allocator);

        var iter = self.schemas.keyIterator();
        while (iter.next()) |key| {
            try names.append(allocator, key.*);
        }

        return names.toOwnedSlice(allocator);
    }

    /// Load schemas from a directory
    fn loadFromDirectory(self: *SchemaLoader, dir_path: [:0]const u8) !void {
        const dir = opendir(dir_path) orelse return error.OpenDirFailed;
        defer _ = closedir(dir);

        while (readdir(dir)) |entry| {
            const name_len = entry.d_namlen;
            if (name_len == 0) continue;

            const name = entry.d_name[0..name_len];

            // Skip . and ..
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            // Only process .json files
            if (!std.mem.endsWith(u8, name, ".json")) continue;

            // Build full path
            var path_buf: [1024]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

            // Null-terminate
            if (full_path.len < path_buf.len) {
                path_buf[full_path.len] = 0;
                self.loadSchemaFile(path_buf[0..full_path.len :0]) catch |err| {
                    std.debug.print("Warning: Failed to load schema {s}: {any}\n", .{ name, err });
                };
            }
        }
    }

    /// Load a single schema from file
    fn loadSchemaFile(self: *SchemaLoader, path: [:0]const u8) !void {
        // Read file content
        const content = try self.readFile(path);
        defer self.allocator.free(content);

        // Parse JSON
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            content,
            .{ .allocate = .alloc_always },
        ) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidSchema;

        // Extract name
        const name_value = root.object.get("name") orelse return error.InvalidSchema;
        if (name_value != .string) return error.InvalidSchema;
        const name = try self.allocator.dupe(u8, name_value.string);
        errdefer self.allocator.free(name);

        // Extract description (optional)
        var description: ?[]u8 = null;
        if (root.object.get("description")) |desc_value| {
            if (desc_value == .string) {
                description = try self.allocator.dupe(u8, desc_value.string);
            }
        }
        errdefer if (description) |d| self.allocator.free(d);

        // Extract schema and re-serialize to JSON string
        const schema_value = root.object.get("schema") orelse return error.InvalidSchema;
        const schema_json = try stringifyJson(self.allocator, schema_value);
        errdefer self.allocator.free(schema_json);

        // Create schema struct
        const schema = types.Schema{
            .name = name,
            .description = description,
            .schema_json = schema_json,
            .allocator = self.allocator,
        };

        // Add to map (overwrites if exists - user schemas override project)
        if (self.schemas.getPtr(name)) |existing| {
            existing.deinit();
        }
        try self.schemas.put(name, schema);
    }

    /// Read file content using C API
    fn readFile(self: *SchemaLoader, path: [:0]const u8) ![]u8 {
        const file = fopen(path, "rb") orelse return error.FileOpenFailed;
        defer _ = fclose(file);

        // Get file size
        if (fseek(file, 0, SEEK_END) != 0) return error.FileReadFailed;
        const size_long = ftell(file);
        if (size_long < 0) return error.FileReadFailed;
        const size: usize = @intCast(size_long);

        if (fseek(file, 0, SEEK_SET) != 0) return error.FileReadFailed;

        // Read content
        const content = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(content);

        const bytes_read = fread(content.ptr, 1, size, file);
        if (bytes_read != size) return error.FileReadFailed;

        return content;
    }
};

/// Stringify a JSON value back to a string
fn stringifyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    try stringifyJsonValue(allocator, &list, value);

    return list.toOwnedSlice(allocator);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try list.appendSlice(allocator, "null"),
        .bool => |b| try list.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try list.appendSlice(allocator, str);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try list.appendSlice(allocator, str);
        },
        .number_string => |s| try list.appendSlice(allocator, s),
        .string => |s| {
            try list.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try list.appendSlice(allocator, "\\\""),
                    '\\' => try list.appendSlice(allocator, "\\\\"),
                    '\n' => try list.appendSlice(allocator, "\\n"),
                    '\r' => try list.appendSlice(allocator, "\\r"),
                    '\t' => try list.appendSlice(allocator, "\\t"),
                    else => {
                        if (c < 0x20) {
                            var buf: [6]u8 = undefined;
                            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                            try list.appendSlice(allocator, hex);
                        } else {
                            try list.append(allocator, c);
                        }
                    },
                }
            }
            try list.append(allocator, '"');
        },
        .array => |arr| {
            try list.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try list.append(allocator, ',');
                try stringifyJsonValue(allocator, list, item);
            }
            try list.append(allocator, ']');
        },
        .object => |obj| {
            try list.append(allocator, '{');
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try list.append(allocator, ',');
                first = false;

                // Key
                try list.append(allocator, '"');
                try list.appendSlice(allocator, entry.key_ptr.*);
                try list.append(allocator, '"');
                try list.append(allocator, ':');

                // Value
                try stringifyJsonValue(allocator, list, entry.value_ptr.*);
            }
            try list.append(allocator, '}');
        },
    }
}

test "SchemaLoader basic" {
    const allocator = std.testing.allocator;
    var loader = SchemaLoader.init(allocator);
    defer loader.deinit();

    try std.testing.expectEqual(@as(usize, 0), loader.count());
}
