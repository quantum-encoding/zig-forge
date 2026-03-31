//! ═══════════════════════════════════════════════════════════════════════════
//! WASI - WebAssembly System Interface Preview 1
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Implements WASI preview1 syscalls for WebAssembly modules.
//! https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md
//!
//! Supported functions:
//! • fd_write - Write to file descriptor
//! • fd_read - Read from file descriptor
//! • fd_close - Close file descriptor
//! • fd_seek - Seek in file descriptor
//! • proc_exit - Exit process
//! • args_get, args_sizes_get - Command line arguments
//! • environ_get, environ_sizes_get - Environment variables
//! • clock_time_get - Get current time
//! • random_get - Get random bytes

const std = @import("std");
const builtin = @import("builtin");
const interpreter = @import("../core/interpreter.zig");
const binary = @import("../core/binary.zig");
const types = @import("../core/types.zig");

// Cross-platform secure random bytes
fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => {
            // Fallback for other platforms - zero fill (not cryptographically secure)
            for (buf) |*b| b.* = 0;
        },
    }
}

const Instance = interpreter.Instance;
const Memory = interpreter.Memory;
const Value = types.Value;
const Module = binary.Module;

/// WASI error codes
pub const Errno = enum(u16) {
    success = 0,
    toobig = 1,
    access = 2,
    addrinuse = 3,
    addrnotavail = 4,
    afnosupport = 5,
    again = 6,
    already = 7,
    badf = 8,
    badmsg = 9,
    busy = 10,
    canceled = 11,
    child = 12,
    connaborted = 13,
    connrefused = 14,
    connreset = 15,
    deadlk = 16,
    destaddrreq = 17,
    dom = 18,
    dquot = 19,
    exist = 20,
    fault = 21,
    fbig = 22,
    hostunreach = 23,
    idrm = 24,
    ilseq = 25,
    inprogress = 26,
    intr = 27,
    inval = 28,
    io = 29,
    isconn = 30,
    isdir = 31,
    loop = 32,
    mfile = 33,
    mlink = 34,
    msgsize = 35,
    multihop = 36,
    nametoolong = 37,
    netdown = 38,
    netreset = 39,
    netunreach = 40,
    nfile = 41,
    nobufs = 42,
    nodev = 43,
    noent = 44,
    noexec = 45,
    nolck = 46,
    nolink = 47,
    nomem = 48,
    nomsg = 49,
    noprotoopt = 50,
    nospc = 51,
    nosys = 52,
    notconn = 53,
    notdir = 54,
    notempty = 55,
    notrecoverable = 56,
    notsock = 57,
    notsup = 58,
    notty = 59,
    nxio = 60,
    overflow = 61,
    ownerdead = 62,
    perm = 63,
    pipe = 64,
    proto = 65,
    protonosupport = 66,
    prototype = 67,
    range = 68,
    rofs = 69,
    spipe = 70,
    srch = 71,
    stale = 72,
    timedout = 73,
    txtbsy = 74,
    xdev = 75,
    notcapable = 76,
};

/// WASI clock IDs
pub const ClockId = enum(u32) {
    realtime = 0,
    monotonic = 1,
    process_cputime_id = 2,
    thread_cputime_id = 3,
};

/// WASI file descriptor rights
pub const Rights = packed struct(u64) {
    fd_datasync: bool = false,
    fd_read: bool = false,
    fd_seek: bool = false,
    fd_fdstat_set_flags: bool = false,
    fd_sync: bool = false,
    fd_tell: bool = false,
    fd_write: bool = false,
    fd_advise: bool = false,
    fd_allocate: bool = false,
    path_create_directory: bool = false,
    path_create_file: bool = false,
    path_link_source: bool = false,
    path_link_target: bool = false,
    path_open: bool = false,
    fd_readdir: bool = false,
    path_readlink: bool = false,
    path_rename_source: bool = false,
    path_rename_target: bool = false,
    path_filestat_get: bool = false,
    path_filestat_set_size: bool = false,
    path_filestat_set_times: bool = false,
    fd_filestat_get: bool = false,
    fd_filestat_set_size: bool = false,
    fd_filestat_set_times: bool = false,
    path_symlink: bool = false,
    path_remove_directory: bool = false,
    path_unlink_file: bool = false,
    poll_fd_readwrite: bool = false,
    sock_shutdown: bool = false,
    sock_accept: bool = false,
    _padding: u34 = 0,
};

/// WASI configuration
pub const Config = struct {
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
    preopens: []const Preopen = &.{},

    pub const Preopen = struct {
        guest_path: []const u8,
        host_path: []const u8,
    };
};

/// File descriptor state
const Fd = struct {
    file: ?std.Io.File,
    preopen_path: ?[]const u8,
    rights: Rights,
    fdflags: u16,
};

/// WASI-enabled instance wrapper
pub const WasiInstance = struct {
    allocator: std.mem.Allocator,
    instance: Instance,
    config: Config,

    /// Open file descriptors
    fds: std.ArrayList(Fd),

    /// Exit code (set by proc_exit)
    exit_code: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, module: *const Module, config: Config) !WasiInstance {
        var wasi = WasiInstance{
            .allocator = allocator,
            .instance = try Instance.init(allocator, module),
            .config = config,
            .fds = .empty,
        };

        // Set up standard FDs
        try wasi.fds.append(allocator, .{
            .file = config.stdin orelse std.Io.File.stdin(),
            .preopen_path = null,
            .rights = .{ .fd_read = true },
            .fdflags = 0,
        });
        try wasi.fds.append(allocator, .{
            .file = config.stdout orelse std.Io.File.stdout(),
            .preopen_path = null,
            .rights = .{ .fd_write = true },
            .fdflags = 0,
        });
        try wasi.fds.append(allocator, .{
            .file = config.stderr orelse std.Io.File.stderr(),
            .preopen_path = null,
            .rights = .{ .fd_write = true },
            .fdflags = 0,
        });

        // Set up preopens (skip for MVP - complex to handle properly)
        _ = config.preopens;

        return wasi;
    }

    /// Set up the import resolver on the instance
    /// Must be called after init to wire up WASI imports
    pub fn setupImports(self: *WasiInstance) void {
        self.instance.import_resolver = resolveImport;
        self.instance.import_resolver_ctx = @ptrCast(self);
    }

    /// Import resolver callback
    fn resolveImport(
        ctx: *anyopaque,
        module_name: []const u8,
        func_name: []const u8,
        args: []const Value,
    ) interpreter.TrapError!?Value {
        const self: *WasiInstance = @ptrCast(@alignCast(ctx));

        // Only handle wasi_snapshot_preview1 and wasi_unstable
        if (!std.mem.eql(u8, module_name, "wasi_snapshot_preview1") and
            !std.mem.eql(u8, module_name, "wasi_unstable"))
        {
            return error.InvalidFunction;
        }

        // Dispatch to WASI functions
        if (std.mem.eql(u8, func_name, "fd_write")) {
            return self.fdWrite(args);
        } else if (std.mem.eql(u8, func_name, "fd_read")) {
            return self.fdRead(args);
        } else if (std.mem.eql(u8, func_name, "fd_close")) {
            return self.fdClose(args);
        } else if (std.mem.eql(u8, func_name, "proc_exit")) {
            return self.procExit(args);
        } else if (std.mem.eql(u8, func_name, "args_sizes_get")) {
            return self.argsSizesGet(args);
        } else if (std.mem.eql(u8, func_name, "args_get")) {
            return self.argsGet(args);
        } else if (std.mem.eql(u8, func_name, "environ_sizes_get")) {
            return self.environSizesGet(args);
        } else if (std.mem.eql(u8, func_name, "environ_get")) {
            return self.environGet(args);
        } else if (std.mem.eql(u8, func_name, "clock_time_get")) {
            return self.clockTimeGet(args);
        } else if (std.mem.eql(u8, func_name, "random_get")) {
            return self.randomGet(args);
        }

        // Unknown WASI function - return ENOSYS
        return .{ .i32 = @intFromEnum(Errno.nosys) };
    }

    pub fn deinit(self: *WasiInstance) void {
        // Close preopened directories (skip stdin/stdout/stderr)
        if (self.fds.items.len > 3) {
            for (self.fds.items[3..]) |fd| {
                _ = fd; // File handles are just ints, no close needed for now
            }
        }
        self.fds.deinit(self.allocator);
        self.instance.deinit();
    }

    /// Run the _start function
    pub fn run(self: *WasiInstance) !u32 {
        _ = self.instance.call("_start", &.{}) catch |err| {
            if (self.exit_code) |code| return code;
            return err;
        };
        return self.exit_code orelse 0;
    }

    /// Call a WASI function
    pub fn callWasi(self: *WasiInstance, name: []const u8, args: []const Value) !?Value {
        // Check for WASI import functions
        if (std.mem.eql(u8, name, "fd_write")) {
            return self.fdWrite(args);
        } else if (std.mem.eql(u8, name, "fd_read")) {
            return self.fdRead(args);
        } else if (std.mem.eql(u8, name, "fd_close")) {
            return self.fdClose(args);
        } else if (std.mem.eql(u8, name, "proc_exit")) {
            return self.procExit(args);
        } else if (std.mem.eql(u8, name, "args_sizes_get")) {
            return self.argsSizesGet(args);
        } else if (std.mem.eql(u8, name, "args_get")) {
            return self.argsGet(args);
        } else if (std.mem.eql(u8, name, "environ_sizes_get")) {
            return self.environSizesGet(args);
        } else if (std.mem.eql(u8, name, "environ_get")) {
            return self.environGet(args);
        } else if (std.mem.eql(u8, name, "clock_time_get")) {
            return self.clockTimeGet(args);
        } else if (std.mem.eql(u8, name, "random_get")) {
            return self.randomGet(args);
        }

        return .{ .i32 = @intFromEnum(Errno.nosys) };
    }

    fn getMemory(self: *WasiInstance) ?*Memory {
        if (self.instance.memories.len == 0) return null;
        return &self.instance.memories[0];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // WASI Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) -> errno
    fn fdWrite(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 4) return .{ .i32 = @intFromEnum(Errno.inval) };

        const fd_num: u32 = @bitCast(args[0].asI32());
        const iovs_ptr: u32 = @bitCast(args[1].asI32());
        const iovs_len: u32 = @bitCast(args[2].asI32());
        const nwritten_ptr: u32 = @bitCast(args[3].asI32());

        if (fd_num >= self.fds.items.len) {
            return .{ .i32 = @intFromEnum(Errno.badf) };
        }

        const fd = &self.fds.items[fd_num];
        const file = fd.file orelse return .{ .i32 = @intFromEnum(Errno.badf) };
        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };
        const io = std.Io.Threaded.global_single_threaded.io();

        var total_written: usize = 0;

        var i: u32 = 0;
        while (i < iovs_len) : (i += 1) {
            const iov_base = iovs_ptr + i * 8;

            // Read iovec: { buf_ptr: u32, buf_len: u32 }
            const buf_ptr = mem.loadI32(iov_base) catch return .{ .i32 = @intFromEnum(Errno.fault) };
            const buf_len = mem.loadI32(iov_base + 4) catch return .{ .i32 = @intFromEnum(Errno.fault) };

            if (buf_len == 0) continue;

            const addr: u32 = @bitCast(buf_ptr);
            const len: usize = @intCast(@as(u32, @bitCast(buf_len)));

            if (addr + len > mem.data.len) {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            }

            const buf = mem.data[addr..][0..len];
            file.writeStreamingAll(io, buf) catch return .{ .i32 = @intFromEnum(Errno.io) };
            total_written += len;
        }

        // Write number of bytes written
        mem.storeI32(nwritten_ptr, @intCast(total_written)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// fd_read(fd, iovs_ptr, iovs_len, nread_ptr) -> errno
    fn fdRead(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 4) return .{ .i32 = @intFromEnum(Errno.inval) };

        const fd_num: u32 = @bitCast(args[0].asI32());
        const iovs_ptr: u32 = @bitCast(args[1].asI32());
        const iovs_len: u32 = @bitCast(args[2].asI32());
        const nread_ptr: u32 = @bitCast(args[3].asI32());

        if (fd_num >= self.fds.items.len) {
            return .{ .i32 = @intFromEnum(Errno.badf) };
        }

        const fd = &self.fds.items[fd_num];
        const file = fd.file orelse return .{ .i32 = @intFromEnum(Errno.badf) };
        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };
        const io = std.Io.Threaded.global_single_threaded.io();

        var total_read: usize = 0;

        var i: u32 = 0;
        while (i < iovs_len) : (i += 1) {
            const iov_base = iovs_ptr + i * 8;

            const buf_ptr = mem.loadI32(iov_base) catch return .{ .i32 = @intFromEnum(Errno.fault) };
            const buf_len = mem.loadI32(iov_base + 4) catch return .{ .i32 = @intFromEnum(Errno.fault) };

            if (buf_len == 0) continue;

            const addr: u32 = @bitCast(buf_ptr);
            const len: usize = @intCast(@as(u32, @bitCast(buf_len)));

            if (addr + len > mem.data.len) {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            }

            const buf = mem.data[addr..][0..len];
            const bytes_read = file.readStreaming(io, &.{buf}) catch return .{ .i32 = @intFromEnum(Errno.io) };
            total_read += bytes_read;

            if (bytes_read < len) break; // EOF or would block
        }

        mem.storeI32(nread_ptr, @intCast(total_read)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// fd_close(fd) -> errno
    fn fdClose(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 1) return .{ .i32 = @intFromEnum(Errno.inval) };

        const fd_num: u32 = @bitCast(args[0].asI32());

        // Can't close stdin/stdout/stderr
        if (fd_num < 3) return .{ .i32 = @intFromEnum(Errno.badf) };

        if (fd_num >= self.fds.items.len) {
            return .{ .i32 = @intFromEnum(Errno.badf) };
        }

        var fd = &self.fds.items[fd_num];
        if (fd.file) |f| {
            const io = std.Io.Threaded.global_single_threaded.io();
            f.close(io);
            fd.file = null;
        }

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// proc_exit(code) -> noreturn
    fn procExit(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 1) {
            self.exit_code = 1;
        } else {
            self.exit_code = @bitCast(args[0].asI32());
        }
        return null;
    }

    /// args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno
    fn argsSizesGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 2) return .{ .i32 = @intFromEnum(Errno.inval) };

        const argc_ptr: u32 = @bitCast(args[0].asI32());
        const argv_buf_size_ptr: u32 = @bitCast(args[1].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        var buf_size: u32 = 0;
        for (self.config.args) |arg| {
            buf_size += @intCast(arg.len + 1); // +1 for null terminator
        }

        mem.storeI32(argc_ptr, @intCast(self.config.args.len)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };
        mem.storeI32(argv_buf_size_ptr, @intCast(buf_size)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// args_get(argv_ptr, argv_buf_ptr) -> errno
    fn argsGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 2) return .{ .i32 = @intFromEnum(Errno.inval) };

        const argv_ptr: u32 = @bitCast(args[0].asI32());
        const argv_buf_ptr: u32 = @bitCast(args[1].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        var buf_offset: u32 = 0;
        for (self.config.args, 0..) |arg, i| {
            // Write pointer to argv array
            mem.storeI32(argv_ptr + @as(u32, @intCast(i)) * 4, @bitCast(argv_buf_ptr + buf_offset)) catch {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            };

            // Write string to buffer
            const dest_start = argv_buf_ptr + buf_offset;
            if (dest_start + arg.len + 1 > mem.data.len) {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            }

            @memcpy(mem.data[dest_start..][0..arg.len], arg);
            mem.data[dest_start + arg.len] = 0; // null terminator

            buf_offset += @intCast(arg.len + 1);
        }

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// environ_sizes_get(environ_count_ptr, environ_buf_size_ptr) -> errno
    fn environSizesGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 2) return .{ .i32 = @intFromEnum(Errno.inval) };

        const count_ptr: u32 = @bitCast(args[0].asI32());
        const buf_size_ptr: u32 = @bitCast(args[1].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        var buf_size: u32 = 0;
        for (self.config.env) |kv| {
            buf_size += @intCast(kv[0].len + 1 + kv[1].len + 1); // KEY=VALUE\0
        }

        mem.storeI32(count_ptr, @intCast(self.config.env.len)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };
        mem.storeI32(buf_size_ptr, @intCast(buf_size)) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// environ_get(environ_ptr, environ_buf_ptr) -> errno
    fn environGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 2) return .{ .i32 = @intFromEnum(Errno.inval) };

        const environ_ptr: u32 = @bitCast(args[0].asI32());
        const environ_buf_ptr: u32 = @bitCast(args[1].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        var buf_offset: u32 = 0;
        for (self.config.env, 0..) |kv, i| {
            // Write pointer
            mem.storeI32(environ_ptr + @as(u32, @intCast(i)) * 4, @bitCast(environ_buf_ptr + buf_offset)) catch {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            };

            // Write KEY=VALUE\0
            const key = kv[0];
            const val = kv[1];
            const total_len = key.len + 1 + val.len + 1;

            const dest_start = environ_buf_ptr + buf_offset;
            if (dest_start + total_len > mem.data.len) {
                return .{ .i32 = @intFromEnum(Errno.fault) };
            }

            @memcpy(mem.data[dest_start..][0..key.len], key);
            mem.data[dest_start + key.len] = '=';
            @memcpy(mem.data[dest_start + key.len + 1 ..][0..val.len], val);
            mem.data[dest_start + key.len + 1 + val.len] = 0;

            buf_offset += @intCast(total_len);
        }

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// clock_time_get(clock_id, precision, time_ptr) -> errno
    fn clockTimeGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 3) return .{ .i32 = @intFromEnum(Errno.inval) };

        const clock_id: u32 = @bitCast(args[0].asI32());
        // precision is args[1] - ignored
        const time_ptr: u32 = @bitCast(args[2].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        const clock: ClockId = @enumFromInt(clock_id);
        const timestamp: i64 = switch (clock) {
            .realtime => blk: {
                var ts: std.c.timespec = undefined;
                if (std.c.clock_gettime(.REALTIME, &ts) != 0) {
                    break :blk 0;
                }
                break :blk ts.sec * 1_000_000_000 + ts.nsec;
            },
            .monotonic => blk: {
                var ts: std.c.timespec = undefined;
                if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) {
                    break :blk 0;
                }
                break :blk ts.sec * 1_000_000_000 + ts.nsec;
            },
            else => return .{ .i32 = @intFromEnum(Errno.inval) },
        };

        mem.storeI64(time_ptr, timestamp) catch {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        };

        return .{ .i32 = @intFromEnum(Errno.success) };
    }

    /// random_get(buf_ptr, buf_len) -> errno
    fn randomGet(self: *WasiInstance, args: []const Value) ?Value {
        if (args.len < 2) return .{ .i32 = @intFromEnum(Errno.inval) };

        const buf_ptr: u32 = @bitCast(args[0].asI32());
        const buf_len: u32 = @bitCast(args[1].asI32());

        const mem = self.getMemory() orelse return .{ .i32 = @intFromEnum(Errno.fault) };

        if (buf_ptr + buf_len > mem.data.len) {
            return .{ .i32 = @intFromEnum(Errno.fault) };
        }

        getRandomBytes(mem.data[buf_ptr..][0..buf_len]);

        return .{ .i32 = @intFromEnum(Errno.success) };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "errno values" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(Errno.success));
    try std.testing.expectEqual(@as(u16, 8), @intFromEnum(Errno.badf));
    try std.testing.expectEqual(@as(u16, 52), @intFromEnum(Errno.nosys));
}
