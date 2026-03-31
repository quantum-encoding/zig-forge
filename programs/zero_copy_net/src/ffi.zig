//! C-compatible FFI for zero_copy_net
//!
//! This FFI layer enables cross-language integration with Rust, C, C++, etc.
//! It provides a stateful, callback-based API for ultra-low-latency TCP networking.
//!
//! Architecture:
//! - Opaque handles for type safety
//! - User-data pattern for callback state
//! - Explicit polling for event loop control
//! - Borrow semantics for zero-copy data access
//!
//! Thread Safety:
//! - ZCN_Server is NOT thread-safe
//! - All operations must be called from the same thread
//! - Callbacks will be invoked on the same thread as run_once()

const std = @import("std");
const net = @import("main.zig");
const TcpServer = net.TcpServer;
const BufferPool = net.BufferPool;
const IoUring = net.IoUring;

// Zig 0.16 compatible Mutex using pthread
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// ============================================================================
// Types
// ============================================================================

/// Opaque server handle
pub const ZCN_Server = opaque {};

/// Configuration for server creation
pub const ZCN_Config = extern struct {
    address: [*:0]const u8,
    port: u16,
    io_uring_entries: u32,
    buffer_pool_size: u32,
    buffer_size: u32,
};

/// Error codes
pub const ZCN_Error = enum(c_int) {
    SUCCESS = 0,
    INVALID_CONFIG = -1,
    OUT_OF_MEMORY = -2,
    IO_URING_INIT = -3,
    BIND_FAILED = -4,
    LISTEN_FAILED = -5,
    INVALID_HANDLE = -6,
    CONNECTION_NOT_FOUND = -7,
    NO_BUFFER = -8,
    SEND_FAILED = -9,
};

/// Callback function types
pub const ZCN_OnAccept = ?*const fn (user_data: ?*anyopaque, fd: c_int) callconv(.c) void;
pub const ZCN_OnData = ?*const fn (user_data: ?*anyopaque, fd: c_int, data: [*]const u8, len: usize) callconv(.c) void;
pub const ZCN_OnClose = ?*const fn (user_data: ?*anyopaque, fd: c_int) callconv(.c) void;

/// Statistics
pub const ZCN_Stats = extern struct {
    total_buffers: usize,
    buffers_in_use: usize,
    buffers_free: usize,
    connections_active: usize,
};

// ============================================================================
// Internal Server Context
// ============================================================================

const ServerContext = struct {
    allocator: std.mem.Allocator,
    ring: IoUring,
    pool: BufferPool,
    server: TcpServer,

    // C callbacks
    user_data: ?*anyopaque,
    on_accept: ZCN_OnAccept,
    on_data: ZCN_OnData,
    on_close: ZCN_OnClose,

    fn init(allocator: std.mem.Allocator, config: *const ZCN_Config) !*ServerContext {
        const ctx = try allocator.create(ServerContext);
        errdefer allocator.destroy(ctx);

        // Initialize io_uring (cast to u16 as IoUring.init expects u16)
        const entries: u16 = @intCast(@min(config.io_uring_entries, 65535));
        ctx.ring = IoUring.init(entries, 0) catch return error.IoUringInit;
        errdefer ctx.ring.deinit();

        // Initialize buffer pool
        ctx.pool = BufferPool.init(
            allocator,
            config.buffer_size,
            config.buffer_pool_size,
        ) catch return error.OutOfMemory;
        errdefer ctx.pool.deinit();

        // Parse address
        const addr_slice = std.mem.span(config.address);

        // Initialize TCP server
        ctx.server = TcpServer.init(
            allocator,
            &ctx.ring,
            &ctx.pool,
            addr_slice,
            config.port,
        ) catch return error.BindFailed;
        errdefer ctx.server.deinit();

        ctx.allocator = allocator;
        ctx.user_data = null;
        ctx.on_accept = null;
        ctx.on_data = null;
        ctx.on_close = null;

        // Set up internal callbacks to trampoline to C callbacks
        ctx.server.on_accept = &acceptTrampoline;
        ctx.server.on_data = &dataTrampoline;
        ctx.server.on_close = &closeTrampoline;

        return ctx;
    }

    fn deinit(ctx: *ServerContext) void {
        ctx.server.deinit();
        ctx.pool.deinit();
        ctx.ring.deinit();
        ctx.allocator.destroy(ctx);
    }

    // Trampoline functions to bridge Zig callbacks to C callbacks
    fn acceptTrampoline(fd: std.posix.socket_t) void {
        // Get context from server (we'll store this in a global map)
        if (getContextForFd(fd)) |ctx| {
            if (ctx.on_accept) |callback| {
                callback(ctx.user_data, @intCast(fd));
            }
        }
    }

    fn dataTrampoline(fd: std.posix.socket_t, data: []u8) void {
        if (getContextForFd(fd)) |ctx| {
            if (ctx.on_data) |callback| {
                callback(ctx.user_data, @intCast(fd), data.ptr, data.len);
            }
        }
    }

    fn closeTrampoline(fd: std.posix.socket_t) void {
        if (getContextForFd(fd)) |ctx| {
            if (ctx.on_close) |callback| {
                callback(ctx.user_data, @intCast(fd));
            }
            // Remove from context map
            removeContextForFd(fd);
        }
    }
};

// ============================================================================
// Global Context Management
// ============================================================================

// We need a way to get the ServerContext from within callbacks
// Since Zig callbacks don't have user_data, we use a global map
var context_mutex: Mutex = .{};
var context_map: std.AutoHashMap(*ServerContext, void) = undefined;
var context_map_initialized: bool = false;

fn ensureContextMapInitialized() void {
    if (!context_map_initialized) {
        context_map = std.AutoHashMap(*ServerContext, void).init(std.heap.c_allocator);
        context_map_initialized = true;
    }
}

fn registerContext(ctx: *ServerContext) !void {
    context_mutex.lock();
    defer context_mutex.unlock();
    ensureContextMapInitialized();
    try context_map.put(ctx, {});
}

fn unregisterContext(ctx: *ServerContext) void {
    context_mutex.lock();
    defer context_mutex.unlock();
    _ = context_map.remove(ctx);
}

fn getContextForFd(_: std.posix.socket_t) ?*ServerContext {
    // HACK: We can't efficiently map fd -> context without storing fd in context
    // For now, assume single server instance
    context_mutex.lock();
    defer context_mutex.unlock();

    var it = context_map.keyIterator();
    if (it.next()) |ctx_ptr| {
        return ctx_ptr.*;
    }
    return null;
}

fn removeContextForFd(_: std.posix.socket_t) void {
    // No-op for now
}

// ============================================================================
// Exported FFI Functions
// ============================================================================

/// Create a new TCP server
export fn zcn_server_create(config: *const ZCN_Config, out_error: ?*ZCN_Error) ?*ZCN_Server {
    // Validate config
    if (config.port == 0 or config.io_uring_entries == 0 or
        config.buffer_pool_size == 0 or config.buffer_size == 0) {
        if (out_error) |err| err.* = .INVALID_CONFIG;
        return null;
    }

    const allocator = std.heap.c_allocator;

    const ctx = ServerContext.init(allocator, config) catch |err| {
        if (out_error) |e| {
            e.* = switch (err) {
                error.IoUringInit => .IO_URING_INIT,
                error.OutOfMemory => .OUT_OF_MEMORY,
                error.BindFailed => .BIND_FAILED,
            };
        }
        return null;
    };

    registerContext(ctx) catch {
        ctx.deinit();
        if (out_error) |err| err.* = .OUT_OF_MEMORY;
        return null;
    };

    if (out_error) |err| err.* = .SUCCESS;
    return @ptrCast(ctx);
}

/// Destroy server and free resources
export fn zcn_server_destroy(server: ?*ZCN_Server) void {
    if (server) |srv| {
        const ctx: *ServerContext = @ptrCast(@alignCast(srv));
        unregisterContext(ctx);
        ctx.deinit();
    }
}

/// Set callback functions
export fn zcn_server_set_callbacks(
    server: ?*ZCN_Server,
    user_data: ?*anyopaque,
    on_accept: ZCN_OnAccept,
    on_data: ZCN_OnData,
    on_close: ZCN_OnClose,
) void {
    if (server) |srv| {
        const ctx: *ServerContext = @ptrCast(@alignCast(srv));
        ctx.user_data = user_data;
        ctx.on_accept = on_accept;
        ctx.on_data = on_data;
        ctx.on_close = on_close;
    }
}

/// Start accepting connections
export fn zcn_server_start(server: ?*ZCN_Server) ZCN_Error {
    const ctx: *ServerContext = @ptrCast(@alignCast(server orelse return .INVALID_HANDLE));
    ctx.server.start() catch return .IO_URING_INIT;
    return .SUCCESS;
}

/// Run event loop once (poll for events)
export fn zcn_server_run_once(server: ?*ZCN_Server) ZCN_Error {
    const ctx: *ServerContext = @ptrCast(@alignCast(server orelse return .INVALID_HANDLE));
    ctx.server.runOnce() catch return .IO_URING_INIT;
    return .SUCCESS;
}

/// Send data to a connection
export fn zcn_server_send(
    server: ?*ZCN_Server,
    fd: c_int,
    data: [*]const u8,
    len: usize,
) ZCN_Error {
    const ctx: *ServerContext = @ptrCast(@alignCast(server orelse return .INVALID_HANDLE));
    const data_slice = data[0..len];
    ctx.server.send(@intCast(fd), data_slice) catch |err| {
        return switch (err) {
            error.ConnectionNotFound => .CONNECTION_NOT_FOUND,
            error.NoBuffer => .NO_BUFFER,
            else => .SEND_FAILED,
        };
    };
    return .SUCCESS;
}

/// Get server statistics
export fn zcn_server_get_stats(server: ?*const ZCN_Server) ZCN_Stats {
    const ctx: *const ServerContext = @ptrCast(@alignCast(server orelse {
        return ZCN_Stats{
            .total_buffers = 0,
            .buffers_in_use = 0,
            .buffers_free = 0,
            .connections_active = 0,
        };
    }));

    const pool_stats = ctx.pool.getStats();
    return ZCN_Stats{
        .total_buffers = pool_stats.total,
        .buffers_in_use = pool_stats.in_use,
        .buffers_free = pool_stats.free,
        .connections_active = ctx.server.connections.count(),
    };
}

/// Get human-readable error string
export fn zcn_error_string(error_code: ZCN_Error) [*:0]const u8 {
    return switch (error_code) {
        .SUCCESS => "Success",
        .INVALID_CONFIG => "Invalid configuration",
        .OUT_OF_MEMORY => "Out of memory",
        .IO_URING_INIT => "Failed to initialize io_uring",
        .BIND_FAILED => "Failed to bind to address",
        .LISTEN_FAILED => "Failed to listen on socket",
        .INVALID_HANDLE => "Invalid server handle",
        .CONNECTION_NOT_FOUND => "Connection not found",
        .NO_BUFFER => "No buffer available",
        .SEND_FAILED => "Send operation failed",
    };
}
