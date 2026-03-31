//! Task handle and state

const std = @import("std");

pub const Task = struct {
    id: u64,
    state: std.atomic.Value(State),
    result: ?*anyopaque,

    pub const State = enum(u32) {
        pending = 0,
        running = 1,
        completed = 2,
        cancelled = 3,
    };

    pub fn init(id: u64) Task {
        return Task{
            .id = id,
            .state = std.atomic.Value(State).init(.pending),
            .result = null,
        };
    }

    pub fn complete(self: *Task, result: ?*anyopaque) void {
        self.state.store(.completed, .release);
        self.result = result;
    }

    pub fn cancel(self: *Task) void {
        self.state.store(.cancelled, .release);
    }

    pub fn getState(self: *const Task) State {
        return self.state.load(.acquire);
    }

    pub fn isCompleted(self: *const Task) bool {
        const s = self.state.load(.acquire);
        return s == .completed or s == .cancelled;
    }
};
