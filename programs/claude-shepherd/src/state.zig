//! Global state management for claude-shepherd

const std = @import("std");
const PolicyEngine = @import("policy/engine.zig").PolicyEngine;

// C function for timestamp
extern "c" fn time(t: ?*i64) i64;

// Custom Mutex implementation for Zig 0.16 compatibility
// std.Thread.Mutex was removed; use pthread directly
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

pub const ClaudeInstance = struct {
    pid: u32,
    task: []const u8,
    working_dir: []const u8,
    status: Status,
    started_at: i64,
    last_activity: i64,
    pty_fd: ?i32 = null,

    pub const Status = enum {
        running,
        waiting_permission,
        paused,
        completed,
        failed,
    };
};

pub const PermissionRequest = struct {
    id: u64,
    pid: u32,
    command: []const u8,
    args: []const u8,
    reason: []const u8,
    timestamp: i64,
    status: Status,

    pub const Status = enum {
        pending,
        approved,
        denied,
        auto_approved,
    };
};

pub const State = struct {
    allocator: std.mem.Allocator,
    instances: std.AutoHashMapUnmanaged(u32, ClaudeInstance),
    permission_requests: std.ArrayListUnmanaged(PermissionRequest),
    next_request_id: u64,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) !State {
        return State{
            .allocator = allocator,
            .instances = .{},
            .permission_requests = .empty,
            .next_request_id = 1,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *State) void {
        // Free instance strings
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.task);
            self.allocator.free(entry.value_ptr.working_dir);
        }
        self.instances.deinit(self.allocator);

        // Free permission request strings
        for (self.permission_requests.items) |req| {
            self.allocator.free(req.command);
            self.allocator.free(req.args);
            self.allocator.free(req.reason);
        }
        self.permission_requests.deinit(self.allocator);
    }

    pub fn addInstance(self: *State, pid: u32, task: []const u8, working_dir: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_copy = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(task_copy);

        const dir_copy = try self.allocator.dupe(u8, working_dir);
        errdefer self.allocator.free(dir_copy);

        const now = time(null);

        try self.instances.put(self.allocator, pid, ClaudeInstance{
            .pid = pid,
            .task = task_copy,
            .working_dir = dir_copy,
            .status = .running,
            .started_at = now,
            .last_activity = now,
        });
    }

    pub fn updateInstance(self: *State, pid: u32, status: ClaudeInstance.Status) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.instances.getPtr(pid)) |instance| {
            instance.status = status;
            instance.last_activity = time(null);
        }
    }

    pub fn removeInstance(self: *State, pid: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.instances.fetchRemove(pid)) |kv| {
            self.allocator.free(kv.value.task);
            self.allocator.free(kv.value.working_dir);
        }
    }

    pub fn getInstance(self: *State, pid: u32) ?ClaudeInstance {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.instances.get(pid);
    }

    pub fn getActiveCount(self: *State) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .running) {
                count += 1;
            }
        }
        return count;
    }

    pub fn addPermissionRequest(self: *State, pid: u32, command: []const u8, args: []const u8, reason: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_request_id;
        self.next_request_id += 1;

        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        const args_copy = try self.allocator.dupe(u8, args);
        errdefer self.allocator.free(args_copy);

        const reason_copy = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(reason_copy);

        try self.permission_requests.append(self.allocator, PermissionRequest{
            .id = id,
            .pid = pid,
            .command = cmd_copy,
            .args = args_copy,
            .reason = reason_copy,
            .timestamp = time(null),
            .status = .pending,
        });

        // Update instance status
        if (self.instances.getPtr(pid)) |instance| {
            instance.status = .waiting_permission;
        }

        return id;
    }

    pub fn resolvePermissionRequest(self: *State, id: u64, approved: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.permission_requests.items) |*req| {
            if (req.id == id and req.status == .pending) {
                req.status = if (approved) .approved else .denied;

                // Update instance status back to running
                if (self.instances.getPtr(req.pid)) |instance| {
                    instance.status = .running;
                }
                break;
            }
        }
    }

    pub fn processPendingRequests(self: *State, policy: *PolicyEngine) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.permission_requests.items) |*req| {
            if (req.status != .pending) continue;

            // Check policy engine
            const decision = policy.evaluate(req.command, req.args);

            switch (decision) {
                .allow => {
                    req.status = .auto_approved;
                    if (self.instances.getPtr(req.pid)) |instance| {
                        instance.status = .running;
                    }
                },
                .deny => {
                    req.status = .denied;
                    if (self.instances.getPtr(req.pid)) |instance| {
                        instance.status = .running;
                    }
                },
                .prompt => {
                    // Stays pending, needs user interaction
                },
            }
        }
    }

    pub fn getPendingRequests(self: *State) []const PermissionRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Return slice of pending requests
        var count: usize = 0;
        for (self.permission_requests.items) |req| {
            if (req.status == .pending) count += 1;
        }

        return self.permission_requests.items;
    }

    pub fn getAllInstances(self: *State, allocator: std.mem.Allocator) ![]ClaudeInstance {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayListUnmanaged(ClaudeInstance).empty;
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            try list.append(allocator, entry.value_ptr.*);
        }

        return list.toOwnedSlice(allocator);
    }
};

test "State add and remove instance" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator);
    defer state.deinit();

    try state.addInstance(12345, "test task", "/tmp/test");

    const instance = state.getInstance(12345);
    try std.testing.expect(instance != null);
    try std.testing.expectEqualStrings("test task", instance.?.task);

    state.removeInstance(12345);
    try std.testing.expect(state.getInstance(12345) == null);
}
