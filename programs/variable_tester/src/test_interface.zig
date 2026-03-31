//! Test Function Interface - Standard ABI for Dynamic Loading
//!
//! This defines the C ABI interface that all test functions must implement.
//! Test functions are compiled as shared libraries (.so) and loaded by workers
//! at runtime via dlopen().
//!
//! Each test library must export:
//!   - swarm_test_init(config_data, config_len) -> bool
//!   - swarm_test_execute(task_data, task_len, result_buf, result_buf_len) -> i32
//!   - swarm_test_cleanup() -> void
//!
//! Return codes for swarm_test_execute:
//!   > 0: Success, return value is result length written to result_buf
//!   = 0: Task processed but no match/success
//!   < 0: Error

const std = @import("std");

/// Result of a test execution
pub const TestResult = extern struct {
    success: u8, // 1 = success, 0 = fail
    score: f64, // Quality score (e.g., compression ratio)
    result_len: u32, // Length of result data
    // Result data follows in buffer
};

/// Test configuration passed during initialization
pub const TestConfig = extern struct {
    test_id: u32,
    flags: u32,
    // Configuration data follows (test-specific)
};

/// Function pointer types for dynamic loading
pub const InitFn = *const fn (config: [*]const u8, config_len: usize) callconv(.c) bool;
pub const ExecuteFn = *const fn (
    task_data: [*]const u8,
    task_len: usize,
    result_buf: [*]u8,
    result_buf_len: usize,
) callconv(.c) i32;
pub const CleanupFn = *const fn () callconv(.c) void;

/// Names of exported symbols
pub const INIT_SYMBOL = "swarm_test_init";
pub const EXECUTE_SYMBOL = "swarm_test_execute";
pub const CLEANUP_SYMBOL = "swarm_test_cleanup";

/// Test library handle
pub const TestLibrary = struct {
    handle: ?*anyopaque,
    init_fn: ?InitFn,
    execute_fn: ?ExecuteFn,
    cleanup_fn: ?CleanupFn,
    initialized: bool,

    pub fn load(path: []const u8) !TestLibrary {
        // Convert to null-terminated string
        var path_buf: [512]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const handle = std.c.dlopen(@ptrCast(&path_buf), .{ .LAZY = false, .NOW = true });
        if (handle == null) {
            std.debug.print("dlopen failed: {s}\n", .{std.c.dlerror() orelse "unknown error"});
            return error.LibraryLoadFailed;
        }

        var lib = TestLibrary{
            .handle = handle,
            .init_fn = null,
            .execute_fn = null,
            .cleanup_fn = null,
            .initialized = false,
        };

        // Load required symbols
        lib.init_fn = @ptrCast(@alignCast(std.c.dlsym(handle, INIT_SYMBOL)));
        lib.execute_fn = @ptrCast(@alignCast(std.c.dlsym(handle, EXECUTE_SYMBOL)));
        lib.cleanup_fn = @ptrCast(@alignCast(std.c.dlsym(handle, CLEANUP_SYMBOL)));

        if (lib.execute_fn == null) {
            std.debug.print("Missing required symbol: {s}\n", .{EXECUTE_SYMBOL});
            lib.unload();
            return error.MissingSymbol;
        }

        return lib;
    }

    pub fn init(self: *TestLibrary, config: []const u8) bool {
        if (self.init_fn) |init_fn| {
            self.initialized = init_fn(config.ptr, config.len);
            return self.initialized;
        }
        self.initialized = true; // No init required
        return true;
    }

    pub fn execute(self: *TestLibrary, task_data: []const u8, result_buf: []u8) i32 {
        if (self.execute_fn) |exec_fn| {
            return exec_fn(task_data.ptr, task_data.len, result_buf.ptr, result_buf.len);
        }
        return -1;
    }

    pub fn cleanup(self: *TestLibrary) void {
        if (self.initialized) {
            if (self.cleanup_fn) |cleanup_fn| {
                cleanup_fn();
            }
            self.initialized = false;
        }
    }

    pub fn unload(self: *TestLibrary) void {
        self.cleanup();
        if (self.handle) |h| {
            _ = std.c.dlclose(h);
            self.handle = null;
        }
    }
};

/// Build path to test library
pub fn getLibraryPath(allocator: std.mem.Allocator, test_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "./libtest_{s}.so", .{test_name});
}
