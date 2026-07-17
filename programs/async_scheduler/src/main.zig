//! Async Task Scheduler
//!
//! Work-stealing concurrent execution

pub const scheduler = @import("scheduler/worksteal.zig");
pub const task = @import("task/handle.zig");
pub const executor = @import("executor/threadpool.zig");
pub const deque = @import("deque/worksteal.zig");

pub const Scheduler = scheduler.Scheduler;
pub const Task = task.Task;
pub const ThreadPool = executor.ThreadPool;
pub const WorkStealDeque = deque.WorkStealDeque;

test {
    @import("std").testing.refAllDecls(@This());
    // End-to-end scheduler tests + concurrency stress tests. This file was
    // orphaned (imported by nothing) and never ran under `zig build test`;
    // wiring it in makes it the regression net for the injector/UAF fixes.
    _ = @import("test_scheduler.zig");
}
