// guardian_shield_loader.zig
// Userspace loader and policy manager for Guardian Shield LSM BPF programs
//
// Build: zig build-exe guardian_shield_loader.zig -lbpf -lelf -lz

const std = @import("std");
const os = std.os;
const fs = std.fs;
const mem = std.mem;
const json = std.json;

// Import libbpf C API
const c = @cImport({
    @cInclude("bpf/libbpf.h");
    @cInclude("bpf/bpf.h");
    @cInclude("linux/bpf.h");
});

const MAX_PATH_LEN = 256;
const MAX_COMM_LEN = 16;
const MAX_PROTECTED_PATHS = 100;

// Mirror of kernel-side structures
const ViolationEvent = extern struct {
    timestamp: u64,
    pid: u32,
    uid: u32,
    gid: u32,
    comm: [MAX_COMM_LEN]u8,
    event_type: u8,
    path: [MAX_PATH_LEN]u8,
    target_path: [MAX_PATH_LEN]u8,
    error_code: i32,
};

const PathRule = extern struct {
    prefix: [MAX_PATH_LEN]u8,
    prefix_len: u32,
    action: u8, // 0 = allow, 1 = block
};

const ProcessRule = extern struct {
    comm: [MAX_COMM_LEN]u8,
    exempt: u8,
};

const EventType = enum(u8) {
    unlink_blocked = 1,
    rename_blocked = 2,
    chmod_blocked = 3,
    chown_blocked = 4,
    truncate_blocked = 5,
    link_blocked = 6,
    symlink_blocked = 7,
    mkdir_blocked = 8,
    rmdir_blocked = 9,
};

// Configuration structure
const Config = struct {
    protected_paths: []const []const u8,
    exempt_processes: []const []const u8,
    log_file: []const u8,
    verbose: bool,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <config.json> [--verbose]\n", .{args[0]});
        return error.InvalidArgs;
    }

    const config_path = args[1];
    const verbose = blk: {
        for (args) |arg| {
            if (mem.eql(u8, arg, "--verbose")) break :blk true;
        }
        break :blk false;
    };

    // Load configuration
    const config = try loadConfig(allocator, config_path);
    defer allocator.free(config.protected_paths);
    defer allocator.free(config.exempt_processes);
    defer allocator.free(config.log_file);

    std.log.info("Guardian Shield LSM BPF Loader starting...", .{});
    std.log.info("Protected paths: {d}", .{config.protected_paths.len});
    std.log.info("Exempt processes: {d}", .{config.exempt_processes.len});

    // Load BPF object
    var loader = try BpfLoader.init(allocator, config);
    defer loader.deinit();

    try loader.load();
    try loader.attach();

    std.log.info("Guardian Shield active. Press Ctrl+C to stop.", .{});

    // Main event loop
    try loader.eventLoop();
}

const BpfLoader = struct {
    allocator: mem.Allocator,
    config: Config,
    bpf_obj: ?*c.bpf_object,
    violation_rb: ?*c.ring_buffer,
    log_file: ?fs.File,

    pub fn init(allocator: mem.Allocator, config: Config) !BpfLoader {
        const log_file = try fs.cwd().createFile(config.log_file, .{});
        
        return BpfLoader{
            .allocator = allocator,
            .config = config,
            .bpf_obj = null,
            .violation_rb = null,
            .log_file = log_file,
        };
    }

    pub fn deinit(self: *BpfLoader) void {
        if (self.violation_rb) |rb| {
            c.ring_buffer__free(rb);
        }
        if (self.bpf_obj) |obj| {
            c.bpf_object__close(obj);
        }
        if (self.log_file) |file| {
            file.close();
        }
    }

    pub fn load(self: *BpfLoader) !void {
        // Open BPF object file
        const obj = c.bpf_object__open_file("guardian_shield_lsm_filesystem.bpf.o", null);
        if (obj == null) {
            std.log.err("Failed to open BPF object file", .{});
            return error.BpfOpenFailed;
        }
        self.bpf_obj = obj;

        // Load BPF programs into kernel
        const load_result = c.bpf_object__load(obj);
        if (load_result != 0) {
            std.log.err("Failed to load BPF object: {d}", .{load_result});
            return error.BpfLoadFailed;
        }

        std.log.info("BPF programs loaded successfully", .{});

        // Populate protected paths map
        try self.populateProtectedPaths();

        // Populate process allowlist map
        try self.populateProcessAllowlist();
    }

    pub fn attach(self: *BpfLoader) !void {
        const obj = self.bpf_obj orelse return error.BpfNotLoaded;

        // Attach all LSM hooks
        const attach_result = c.bpf_object__attach_skeleton(obj);
        if (attach_result != 0) {
            std.log.err("Failed to attach BPF programs: {d}", .{attach_result});
            return error.BpfAttachFailed;
        }

        std.log.info("LSM BPF hooks attached", .{});

        // Setup ring buffer for event monitoring
        const map = c.bpf_object__find_map_by_name(obj, "violation_events");
        if (map == null) {
            return error.MapNotFound;
        }

        const map_fd = c.bpf_map__fd(map);
        
        const rb = c.ring_buffer__new(map_fd, handleViolation, null, null);
        if (rb == null) {
            return error.RingBufferInitFailed;
        }
        self.violation_rb = rb;

        std.log.info("Event monitoring initialized", .{});
    }

    fn populateProtectedPaths(self: *BpfLoader) !void {
        const obj = self.bpf_obj orelse return error.BpfNotLoaded;
        
        const map = c.bpf_object__find_map_by_name(obj, "protected_paths");
        if (map == null) return error.MapNotFound;

        const map_fd = c.bpf_map__fd(map);

        for (self.config.protected_paths, 0..) |path, i| {
            var rule = PathRule{
                .prefix = undefined,
                .prefix_len = @intCast(path.len),
                .action = 1, // Block
            };

            // Copy path to rule
            @memset(&rule.prefix, 0);
            @memcpy(rule.prefix[0..path.len], path);

            const key: u32 = @intCast(i);
            const update_result = c.bpf_map_update_elem(
                map_fd,
                &key,
                &rule,
                c.BPF_ANY
            );

            if (update_result != 0) {
                std.log.err("Failed to add protected path: {s}", .{path});
                return error.MapUpdateFailed;
            }
        }

        std.log.info("Loaded {d} protected path rules", .{self.config.protected_paths.len});
    }

    fn populateProcessAllowlist(self: *BpfLoader) !void {
        const obj = self.bpf_obj orelse return error.BpfNotLoaded;
        
        const map = c.bpf_object__find_map_by_name(obj, "process_allowlist");
        if (map == null) return error.MapNotFound;

        const map_fd = c.bpf_map__fd(map);

        for (self.config.exempt_processes) |process_name| {
            var rule = ProcessRule{
                .comm = undefined,
                .exempt = 1,
            };

            // Copy process name to rule
            @memset(&rule.comm, 0);
            const copy_len = @min(process_name.len, MAX_COMM_LEN - 1);
            @memcpy(rule.comm[0..copy_len], process_name[0..copy_len]);

            const update_result = c.bpf_map_update_elem(
                map_fd,
                &rule.comm,
                &rule,
                c.BPF_ANY
            );

            if (update_result != 0) {
                std.log.err("Failed to add exempt process: {s}", .{process_name});
                return error.MapUpdateFailed;
            }
        }

        std.log.info("Loaded {d} exempt process rules", .{self.config.exempt_processes.len});
    }

    pub fn eventLoop(self: *BpfLoader) !void {
        const rb = self.violation_rb orelse return error.RingBufferNotInit;

        while (true) {
            const poll_result = c.ring_buffer__poll(rb, 1000); // 1 second timeout
            if (poll_result < 0) {
                std.log.err("Ring buffer polling error: {d}", .{poll_result});
                return error.RingBufferPollFailed;
            }
        }
    }

    // Callback for ring buffer events (must be C ABI compatible)
    export fn handleViolation(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.C) c_int {
        _ = ctx;
        _ = size;

        if (data == null) return 0;

        const event: *ViolationEvent = @ptrCast(@alignCast(data));

        // Convert comm and path from C strings
        const comm_len = std.mem.indexOfScalar(u8, &event.comm, 0) orelse MAX_COMM_LEN;
        const comm = event.comm[0..comm_len];

        const path_len = std.mem.indexOfScalar(u8, &event.path, 0) orelse MAX_PATH_LEN;
        const path = event.path[0..path_len];

        const target_len = std.mem.indexOfScalar(u8, &event.target_path, 0) orelse 0;
        const target = if (target_len > 0) event.target_path[0..target_len] else "";

        // Format timestamp
        const timestamp_sec = event.timestamp / 1_000_000_000;
        const timestamp_ns = event.timestamp % 1_000_000_000;

        // Log to console
        const event_type_str = switch (@as(EventType, @enumFromInt(event.event_type))) {
            .unlink_blocked => "UNLINK",
            .rename_blocked => "RENAME",
            .chmod_blocked => "CHMOD",
            .chown_blocked => "CHOWN",
            .truncate_blocked => "TRUNCATE",
            .link_blocked => "LINK",
            .symlink_blocked => "SYMLINK",
            .mkdir_blocked => "MKDIR",
            .rmdir_blocked => "RMDIR",
        };

        if (target.len > 0) {
            std.debug.print(
                "[{d}.{d:0>9}] BLOCKED {s}: pid={d} uid={d} comm={s} path={s} target={s} err={d}\n",
                .{timestamp_sec, timestamp_ns, event_type_str, event.pid, event.uid, comm, path, target, event.error_code}
            );
        } else {
            std.debug.print(
                "[{d}.{d:0>9}] BLOCKED {s}: pid={d} uid={d} comm={s} path={s} err={d}\n",
                .{timestamp_sec, timestamp_ns, event_type_str, event.pid, event.uid, comm, path, event.error_code}
            );
        }

        return 0;
    }
};

fn loadConfig(allocator: mem.Allocator, path: []const u8) !Config {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    var parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Parse protected paths
    const paths_json = root.get("protected_paths").?.array;
    const protected_paths = try allocator.alloc([]const u8, paths_json.items.len);
    for (paths_json.items, 0..) |item, i| {
        protected_paths[i] = try allocator.dupe(u8, item.string);
    }

    // Parse exempt processes
    const procs_json = root.get("exempt_processes").?.array;
    const exempt_processes = try allocator.alloc([]const u8, procs_json.items.len);
    for (procs_json.items, 0..) |item, i| {
        exempt_processes[i] = try allocator.dupe(u8, item.string);
    }

    const log_file = try allocator.dupe(u8, root.get("log_file").?.string);

    return Config{
        .protected_paths = protected_paths,
        .exempt_processes = exempt_processes,
        .log_file = log_file,
        .verbose = root.get("verbose").?.bool,
    };
}
