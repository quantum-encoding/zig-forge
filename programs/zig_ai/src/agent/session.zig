// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Session - Plan persistence for resume capability
//! Saves and loads orchestration sessions to/from JSON files

const std = @import("std");
const Allocator = std.mem.Allocator;
const task_graph = @import("task_graph.zig");

pub const Session = struct {
    id: []const u8,
    created_at: i64,
    goal: []const u8,
    plan_json: []const u8,
    total_input_tokens: u32,
    total_output_tokens: u32,
    allocator: Allocator,

    pub fn create(allocator: Allocator, goal: []const u8, graph: *const task_graph.TaskGraph) !Session {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);

        // Generate a simple session ID from timestamp
        const id = try std.fmt.allocPrint(allocator, "session-{d}", .{ts.sec});

        const plan_json = try graph.toJson(allocator);

        return .{
            .id = id,
            .created_at = ts.sec,
            .goal = try allocator.dupe(u8, goal),
            .plan_json = plan_json,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.id);
        self.allocator.free(self.goal);
        self.allocator.free(self.plan_json);
    }

    /// Update plan JSON from current graph state
    pub fn updatePlan(self: *Session, graph: *const task_graph.TaskGraph) !void {
        self.allocator.free(self.plan_json);
        self.plan_json = try graph.toJson(self.allocator);
    }

    /// Save session to a JSON file
    pub fn save(self: *const Session, path: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "id": "{s}",
            \\  "created_at": {d},
            \\  "goal": "{s}",
            \\  "total_input_tokens": {d},
            \\  "total_output_tokens": {d},
            \\  "plan": {s}
            \\}}
        , .{
            self.id,
            self.created_at,
            self.goal,
            self.total_input_tokens,
            self.total_output_tokens,
            self.plan_json,
        });
        defer self.allocator.free(content);

        const path_z = try self.allocator.allocSentinel(u8, path.len, 0);
        defer self.allocator.free(path_z);
        @memcpy(path_z, path);

        const file = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
        defer _ = std.c.fclose(file);

        _ = std.c.fwrite(content.ptr, 1, content.len, file);
    }

    /// Load a session from a JSON file
    pub fn load(allocator: Allocator, path: []const u8) !Session {
        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const file = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
        defer _ = std.c.fclose(file);

        // Read file content
        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const read_count = std.c.fread(&buf, 1, buf.len, file);
            if (read_count > 0) {
                try content.appendSlice(allocator, buf[0..read_count]);
            }
            if (read_count < buf.len) break;
        }

        if (content.items.len == 0) return error.EmptyFile;

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content.items, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value.object;

        const id = try allocator.dupe(u8, (root.get("id") orelse return error.InvalidJson).string);
        errdefer allocator.free(id);

        const created_at: i64 = (root.get("created_at") orelse return error.InvalidJson).integer;

        const goal = try allocator.dupe(u8, (root.get("goal") orelse return error.InvalidJson).string);
        errdefer allocator.free(goal);

        const total_input: u32 = if (root.get("total_input_tokens")) |t| @intCast(t.integer) else 0;
        const total_output: u32 = if (root.get("total_output_tokens")) |t| @intCast(t.integer) else 0;

        // Extract plan as raw JSON string
        const plan_val = root.get("plan") orelse return error.InvalidJson;
        // Re-stringify the plan object using Zig 0.16 API
        const plan_json = std.json.Stringify.valueAlloc(allocator, plan_val, .{}) catch return error.InvalidJson;

        return .{
            .id = id,
            .created_at = created_at,
            .goal = goal,
            .plan_json = plan_json,
            .total_input_tokens = total_input,
            .total_output_tokens = total_output,
            .allocator = allocator,
        };
    }
};
