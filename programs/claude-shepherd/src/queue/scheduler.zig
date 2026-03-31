//! Task Queue Scheduler for claude-shepherd
//!
//! Manages a queue of tasks to be dispatched to Claude Code instances.
//! Supports task dependencies, pre-queued responses, and priority ordering.

const std = @import("std");
const State = @import("../state.zig").State;

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

pub const Task = struct {
    id: u64,
    prompt: []const u8,
    working_dir: []const u8,
    status: Status,
    priority: Priority,
    depends_on: ?u64 = null,
    pre_response: ?[]const u8 = null,
    created_at: i64,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,
    assigned_pid: ?u32 = null,
    error_message: ?[]const u8 = null,

    pub const Status = enum {
        queued,
        waiting_dependency,
        running,
        completed,
        failed,
        cancelled,
    };

    pub const Priority = enum(u8) {
        low = 0,
        normal = 1,
        high = 2,
        critical = 3,
    };
};

pub const PreResponse = struct {
    trigger: []const u8, // Pattern to match in Claude's output
    response: []const u8, // Pre-approved response to inject
    count: ?u32 = null, // null = unlimited uses
    scope: Scope = .session,

    pub const Scope = enum {
        session, // Valid for current session only
        permanent, // Persisted across restarts
        once, // Single use
    };
};

pub const TaskQueue = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task),
    pre_responses: std.ArrayListUnmanaged(PreResponse),
    next_task_id: u64,
    max_concurrent: u32,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) !TaskQueue {
        return TaskQueue{
            .allocator = allocator,
            .tasks = .empty,
            .pre_responses = .empty,
            .next_task_id = 1,
            .max_concurrent = 8,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *TaskQueue) void {
        // Free task strings
        for (self.tasks.items) |task| {
            self.allocator.free(task.prompt);
            self.allocator.free(task.working_dir);
            if (task.pre_response) |pr| self.allocator.free(pr);
            if (task.error_message) |em| self.allocator.free(em);
        }
        self.tasks.deinit(self.allocator);

        // Free pre-response strings
        for (self.pre_responses.items) |pr| {
            self.allocator.free(pr.trigger);
            self.allocator.free(pr.response);
        }
        self.pre_responses.deinit(self.allocator);
    }

    /// Queue a new task for execution
    pub fn enqueue(
        self: *TaskQueue,
        prompt: []const u8,
        working_dir: []const u8,
        priority: Task.Priority,
        depends_on: ?u64,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_task_id;
        self.next_task_id += 1;

        const prompt_copy = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(prompt_copy);

        const dir_copy = try self.allocator.dupe(u8, working_dir);
        errdefer self.allocator.free(dir_copy);

        const status: Task.Status = if (depends_on != null) .waiting_dependency else .queued;

        try self.tasks.append(self.allocator, Task{
            .id = id,
            .prompt = prompt_copy,
            .working_dir = dir_copy,
            .status = status,
            .priority = priority,
            .depends_on = depends_on,
            .created_at = time(null),
        });

        return id;
    }

    /// Get the next task ready for execution
    pub fn dequeue(self: *TaskQueue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find highest priority queued task
        var best_idx: ?usize = null;
        var best_priority: u8 = 0;

        for (self.tasks.items, 0..) |*task, i| {
            if (task.status == .queued) {
                const pri = @intFromEnum(task.priority);
                if (best_idx == null or pri > best_priority) {
                    best_idx = i;
                    best_priority = pri;
                }
            }
        }

        if (best_idx) |idx| {
            return &self.tasks.items[idx];
        }
        return null;
    }

    /// Process ready tasks and dispatch to available Claude instances
    pub fn processReady(self: *TaskQueue, state: *State) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check dependencies and update waiting tasks
        for (self.tasks.items) |*task| {
            if (task.status == .waiting_dependency) {
                if (task.depends_on) |dep_id| {
                    // Check if dependency is complete
                    const dep_complete = for (self.tasks.items) |dep_task| {
                        if (dep_task.id == dep_id) {
                            break dep_task.status == .completed;
                        }
                    } else true; // Dependency not found, assume complete

                    if (dep_complete) {
                        task.status = .queued;
                    }
                }
            }
        }

        // Count currently running tasks
        var running_count: u32 = 0;
        for (self.tasks.items) |task| {
            if (task.status == .running) {
                running_count += 1;
            }
        }

        // Also count active Claude instances from state
        const active_claudes = state.getActiveCount();
        const total_running = running_count + @as(u32, @intCast(active_claudes));

        // Don't dispatch if at capacity
        if (total_running >= self.max_concurrent) {
            return;
        }

        // Find and mark next task as running (actual dispatch happens elsewhere)
        for (self.tasks.items) |*task| {
            if (task.status == .queued) {
                task.status = .running;
                task.started_at = time(null);
                break;
            }
        }
    }

    /// Mark a task as completed
    pub fn complete(self: *TaskQueue, task_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |*task| {
            if (task.id == task_id) {
                task.status = .completed;
                task.completed_at = time(null);
                break;
            }
        }
    }

    /// Mark a task as failed
    pub fn fail(self: *TaskQueue, task_id: u64, error_msg: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |*task| {
            if (task.id == task_id) {
                task.status = .failed;
                task.completed_at = time(null);
                task.error_message = try self.allocator.dupe(u8, error_msg);
                break;
            }
        }
    }

    /// Cancel a task
    pub fn cancel(self: *TaskQueue, task_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |*task| {
            if (task.id == task_id) {
                if (task.status == .queued or task.status == .waiting_dependency) {
                    task.status = .cancelled;
                    return true;
                }
                return false; // Can't cancel running/completed tasks
            }
        }
        return false;
    }

    /// Add a pre-queued response
    pub fn addPreResponse(self: *TaskQueue, trigger: []const u8, response: []const u8, count: ?u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const trigger_copy = try self.allocator.dupe(u8, trigger);
        errdefer self.allocator.free(trigger_copy);

        const response_copy = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(response_copy);

        try self.pre_responses.append(self.allocator, .{
            .trigger = trigger_copy,
            .response = response_copy,
            .count = count,
            .scope = if (count != null and count.? == 1) .once else .session,
        });
    }

    /// Check for a matching pre-response
    pub fn checkPreResponse(self: *TaskQueue, output: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.pre_responses.items.len) {
            const pr = &self.pre_responses.items[i];

            // Check if trigger pattern matches
            if (std.mem.indexOf(u8, output, pr.trigger) != null) {
                const response = pr.response;

                // Handle count-limited responses
                if (pr.count) |*count| {
                    count.* -= 1;
                    if (count.* == 0) {
                        // Remove exhausted pre-response
                        self.allocator.free(pr.trigger);
                        self.allocator.free(pr.response);
                        _ = self.pre_responses.swapRemove(i);
                        // Don't increment i since we removed an element
                        return response;
                    }
                }

                return response;
            }
            i += 1;
        }

        return null;
    }

    /// Get all queued tasks
    pub fn getQueued(self: *TaskQueue) []const Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.tasks.items;
    }

    /// Get task by ID
    pub fn getTask(self: *TaskQueue, task_id: u64) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |task| {
            if (task.id == task_id) {
                return task;
            }
        }
        return null;
    }

    /// Get queue statistics
    pub fn getStats(self: *TaskQueue) struct {
        total: usize,
        queued: usize,
        running: usize,
        completed: usize,
        failed: usize,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = .{
            .total = self.tasks.items.len,
            .queued = @as(usize, 0),
            .running = @as(usize, 0),
            .completed = @as(usize, 0),
            .failed = @as(usize, 0),
        };

        for (self.tasks.items) |task| {
            switch (task.status) {
                .queued, .waiting_dependency => stats.queued += 1,
                .running => stats.running += 1,
                .completed => stats.completed += 1,
                .failed, .cancelled => stats.failed += 1,
            }
        }

        return stats;
    }
};

test "task queue basic operations" {
    const allocator = std.testing.allocator;
    var queue = try TaskQueue.init(allocator);
    defer queue.deinit();

    // Enqueue tasks
    const id1 = try queue.enqueue("build zsort", "/home/user/project", .normal, null);
    const id2 = try queue.enqueue("test zsort", "/home/user/project", .high, id1);

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);

    // Second task should be waiting on dependency
    const task2 = queue.getTask(id2);
    try std.testing.expect(task2 != null);
    try std.testing.expectEqual(Task.Status.waiting_dependency, task2.?.status);
}

test "pre-response matching" {
    const allocator = std.testing.allocator;
    var queue = try TaskQueue.init(allocator);
    defer queue.deinit();

    try queue.addPreResponse("Permission denied", "y", 1);

    const resp = queue.checkPreResponse("Error: Permission denied for rm -rf");
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("y", resp.?);

    // Should be consumed (count was 1)
    const resp2 = queue.checkPreResponse("Permission denied again");
    try std.testing.expect(resp2 == null);
}
