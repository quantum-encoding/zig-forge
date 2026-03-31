//! eBPF Consumer for claude-shepherd
//!
//! Event-driven monitoring using kernel eBPF hooks.
//! No polling required - events are delivered via ring buffer.

const std = @import("std");
const State = @import("state.zig").State;
const ClaudeInstance = @import("state.zig").ClaudeInstance;
const PolicyEngine = @import("policy/engine.zig").PolicyEngine;
const JsonExporter = @import("export.zig").JsonExporter;

// C bindings for libbpf and file operations
const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

// Event types (must match shepherd.bpf.c)
const EVENT_TTY_WRITE: u32 = 1;
const EVENT_PROCESS_EXEC: u32 = 2;
const EVENT_PROCESS_EXIT: u32 = 3;
const EVENT_PERMISSION_REQUEST: u32 = 4;

// Config keys
const CONFIG_ENABLED: u32 = 0;
const CONFIG_EVENT_COUNT: u32 = 1;

// Event structure (must match shepherd.bpf.c)
const ShepherdEvent = extern struct {
    event_type: u32,
    pid: u32,
    timestamp_ns: u64,
    comm: [16]u8,
    buf_size: u32,
    exit_code: u32,
    buffer: [256]u8,
};

// Global state for callback
var g_state: ?*State = null;
var g_policy: ?*PolicyEngine = null;
var g_exporter: ?*JsonExporter = null;
var g_running: bool = true;

// C time function
extern "c" fn time(t: ?*i64) i64;

// Signal handler
fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_running = false;
}

pub const EbpfConsumer = struct {
    allocator: std.mem.Allocator,
    obj: ?*c.bpf_object = null,
    rb: ?*c.ring_buffer = null,
    config_fd: c_int = -1,
    state: *State,
    policy: *PolicyEngine,
    exporter: *JsonExporter,

    const BPF_OBJECT_PATH = "shepherd.bpf.o";

    pub fn init(allocator: std.mem.Allocator, state: *State, policy: *PolicyEngine, exporter: *JsonExporter) !EbpfConsumer {
        var consumer = EbpfConsumer{
            .allocator = allocator,
            .state = state,
            .policy = policy,
            .exporter = exporter,
        };

        // Set global pointers for callback
        g_state = state;
        g_policy = policy;
        g_exporter = exporter;

        // Try to load eBPF program
        consumer.loadBpf() catch |err| {
            log("WARN", "eBPF not available: {any}, falling back to polling", .{err});
            return consumer;
        };

        return consumer;
    }

    pub fn deinit(self: *EbpfConsumer) void {
        if (self.rb) |rb| {
            c.ring_buffer__free(rb);
        }
        if (self.obj) |obj| {
            c.bpf_object__close(obj);
        }
        g_state = null;
        g_policy = null;
        g_exporter = null;
    }

    fn loadBpf(self: *EbpfConsumer) !void {
        // Find BPF object file
        var path_buf: [512]u8 = undefined;

        // Try multiple locations
        const paths = [_][]const u8{
            "shepherd.bpf.o",
            "zig-out/bin/shepherd.bpf.o",
            "/usr/local/lib/claude-shepherd/shepherd.bpf.o",
        };

        var found_path: ?[*:0]const u8 = null;
        for (paths) |path| {
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
            if (c.access(path_z, c.F_OK) == 0) {
                found_path = path_z;
                break;
            }
        }

        if (found_path == null) {
            return error.BpfObjectNotFound;
        }

        // Open BPF object
        self.obj = c.bpf_object__open_file(found_path.?, null);
        if (self.obj == null) {
            return error.BpfOpenFailed;
        }

        // Load BPF program into kernel
        if (c.bpf_object__load(self.obj.?) != 0) {
            return error.BpfLoadFailed;
        }

        // Find and attach programs
        var prog = c.bpf_object__next_program(self.obj.?, null);
        while (prog != null) {
            const link = c.bpf_program__attach(prog);
            if (link == null) {
                log("WARN", "Failed to attach BPF program", .{});
            }
            prog = c.bpf_object__next_program(self.obj.?, prog);
        }

        // Get ring buffer map
        const rb_map = c.bpf_object__find_map_by_name(self.obj.?, "events");
        if (rb_map == null) {
            return error.BpfMapNotFound;
        }

        const rb_fd = c.bpf_map__fd(rb_map);
        if (rb_fd < 0) {
            return error.BpfMapFdFailed;
        }

        // Create ring buffer consumer
        self.rb = c.ring_buffer__new(rb_fd, handleEvent, null, null);
        if (self.rb == null) {
            return error.RingBufferFailed;
        }

        // Get config map and enable monitoring
        const config_map = c.bpf_object__find_map_by_name(self.obj.?, "config");
        if (config_map != null) {
            self.config_fd = c.bpf_map__fd(config_map);
            if (self.config_fd >= 0) {
                var enabled: u64 = 1;
                _ = c.bpf_map_update_elem(self.config_fd, &CONFIG_ENABLED, &enabled, c.BPF_ANY);
            }
        }

        log("INFO", "eBPF monitoring enabled", .{});
    }

    pub fn isEbpfEnabled(self: *EbpfConsumer) bool {
        return self.rb != null;
    }

    /// Poll for events (non-blocking with timeout)
    pub fn poll(self: *EbpfConsumer, timeout_ms: c_int) !void {
        if (self.rb) |rb| {
            const ret = c.ring_buffer__poll(rb, timeout_ms);
            if (ret < 0 and ret != -c.EINTR) {
                return error.PollFailed;
            }
        }
    }

    /// Run event loop (blocking)
    pub fn run(self: *EbpfConsumer) !void {
        if (self.rb == null) {
            return error.NotInitialized;
        }

        // Setup signal handlers
        _ = c.signal(c.SIGINT, @ptrCast(&signalHandler));
        _ = c.signal(c.SIGTERM, @ptrCast(&signalHandler));

        log("INFO", "Starting eBPF event loop", .{});

        while (g_running) {
            // Poll with 100ms timeout
            const ret = c.ring_buffer__poll(self.rb.?, 100);
            if (ret < 0) {
                if (ret == -c.EINTR) continue;
                log("ERROR", "ring_buffer__poll failed: {d}", .{ret});
                break;
            }

            // Export state for GNOME extension
            if (g_exporter) |exp| {
                exp.exportAll();
            }
        }

        log("INFO", "eBPF event loop stopped", .{});
    }
};

/// Ring buffer event callback (called from libbpf)
fn handleEvent(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = ctx;
    _ = size;

    if (data == null) return 0;

    const event: *const ShepherdEvent = @ptrCast(@alignCast(data.?));
    const state = g_state orelse return 0;
    const policy = g_policy orelse return 0;

    // Get null-terminated comm
    var comm_buf: [17]u8 = undefined;
    @memcpy(comm_buf[0..16], &event.comm);
    comm_buf[16] = 0;

    switch (event.event_type) {
        EVENT_PROCESS_EXEC => {
            // New Claude instance started
            log("INFO", "Claude started: PID={d} comm={s}", .{ event.pid, comm_buf[0..16] });

            state.addInstance(event.pid, "New instance", "/tmp") catch {};
        },
        EVENT_PROCESS_EXIT => {
            // Claude instance exited
            log("INFO", "Claude exited: PID={d}", .{event.pid});

            state.updateInstance(event.pid, .completed);
            state.removeInstance(event.pid);
        },
        EVENT_TTY_WRITE => {
            // Terminal output - update activity
            state.updateInstance(event.pid, .running);
        },
        EVENT_PERMISSION_REQUEST => {
            // Permission request detected
            log("INFO", "Permission request: PID={d}", .{event.pid});

            // Extract command from buffer
            var cmd_buf: [64]u8 = undefined;
            const cmd_len = @min(event.buf_size, 63);
            @memcpy(cmd_buf[0..cmd_len], event.buffer[0..cmd_len]);
            cmd_buf[cmd_len] = 0;

            // Evaluate policy
            const decision = policy.evaluate(cmd_buf[0..cmd_len], "");
            switch (decision) {
                .allow => {
                    log("INFO", "Auto-approved by policy", .{});
                    state.updateInstance(event.pid, .running);
                },
                .deny => {
                    log("INFO", "Auto-denied by policy", .{});
                    state.updateInstance(event.pid, .running);
                },
                .prompt => {
                    // Add to pending requests
                    _ = state.addPermissionRequest(
                        event.pid,
                        cmd_buf[0..cmd_len],
                        "",
                        "Permission required",
                    ) catch {};
                },
            }
        },
        else => {},
    }

    return 0;
}

fn log(comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var time_buf: [32]u8 = undefined;

    const timestamp = std.fmt.bufPrint(&time_buf, "{d}", .{time(null)}) catch "?";
    const msg = std.fmt.bufPrint(&buf, "[{s}] [{s}] " ++ fmt ++ "\n", .{timestamp} ++ .{level} ++ args) catch return;

    // Write to log file
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "/tmp/claude-shepherd.log", .{}) catch return;

    const fd = c.open(@ptrCast(path_z.ptr), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    _ = c.write(fd, msg.ptr, msg.len);
}
