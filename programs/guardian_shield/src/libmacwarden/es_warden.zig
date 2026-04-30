//! es_warden - Endpoint Security based Guardian Shield for macOS
//!
//! Uses Apple's Endpoint Security framework for system-wide file protection.
//! Monitors AUTH events (unlink, rename, truncate, link, create, clone,
//! exchangedata, setextattr, deleteextattr) and blocks operations on
//! protected paths.
//!
//! Copyright (c) 2025-2026 Richard Tune / Quantum Encoding Ltd
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! Required entitlement: com.apple.developer.endpoint-security.client
//! Must be code-signed with Developer ID and hardened runtime.
//! Must run as root (sudo).

const std = @import("std");
const builtin = @import("builtin");
const ctk = @import("ctk");

// ═══════════════════════════════════════════════════════════════════════════════
// C imports (signals, unistd — no ES headers, we define those manually)
// ═══════════════════════════════════════════════════════════════════════════════

const c = std.c;

// ═══════════════════════════════════════════════════════════════════════════════
// Endpoint Security type bindings (manual — ES headers use ObjC blocks)
// ═══════════════════════════════════════════════════════════════════════════════

// Opaque client handle
const es_client_t = opaque {};

// String token — pointer + length (NOT null-terminated)
const es_string_token_t = extern struct {
    length: usize,
    data: ?[*]const u8,

    fn slice(self: es_string_token_t) []const u8 {
        if (self.data) |d| {
            return d[0..self.length];
        }
        return "";
    }
};

// File info — path + stat
const es_file_t = extern struct {
    path: es_string_token_t,
    path_truncated: bool,
    stat: extern struct {
        st_dev: i32,
        st_mode: u16,
        st_nlink: u16,
        st_ino: u64,
        st_uid: u32,
        st_gid: u32,
        st_rdev: i32,
        st_atime: c.timespec,
        st_mtime: c.timespec,
        st_ctime: c.timespec,
        st_btime: c.timespec,
        st_size: i64,
        st_blocks: i64,
        st_blksize: i32,
        st_flags: u32,
        st_gen: u32,
        st_spare: i32,
        st_reserved: [2]i64,
    },
};

// Process info (simplified — we only need audit_token and executable)
const audit_token_t = extern struct {
    val: [8]u32,
};

const es_process_t = extern struct {
    audit_token: audit_token_t,
    ppid: i32,
    original_ppid: i32,
    group_id: i32,
    session_id: i32,
    codesigning_flags: u32,
    is_platform_binary: bool,
    is_es_client: bool,
    cdhash: [20]u8,
    signing_id: es_string_token_t,
    team_id: es_string_token_t,
    executable: *es_file_t,
    tty: ?*es_file_t, // version >= 2
    start_time: extern struct { tv_sec: i64, tv_usec: i64 }, // version >= 3 (struct timeval)
    responsible_audit_token: audit_token_t, // version >= 4 — the key field
    parent_audit_token: audit_token_t, // version >= 4

    /// Extract PID from an audit_token_t. PID is at index 5 in the val array.
    pub fn pidFromToken(token: audit_token_t) u32 {
        return token.val[5];
    }
};

// Event type enum
const es_event_type_t = enum(u32) {
    ES_EVENT_TYPE_AUTH_EXEC = 0,
    ES_EVENT_TYPE_AUTH_OPEN = 2,
    ES_EVENT_TYPE_AUTH_CREATE = 10,
    ES_EVENT_TYPE_AUTH_UNLINK = 17,
    ES_EVENT_TYPE_AUTH_LINK = 20,
    ES_EVENT_TYPE_AUTH_RENAME = 21,
    ES_EVENT_TYPE_AUTH_TRUNCATE = 27,
    ES_EVENT_TYPE_AUTH_CLONE = 36,
    ES_EVENT_TYPE_AUTH_EXCHANGEDATA = 37,
    ES_EVENT_TYPE_AUTH_SETEXTATTR = 49,
    ES_EVENT_TYPE_AUTH_DELETEEXTATTR = 51,
    _,
};

// Destination type for rename/create
const es_destination_type_t = enum(u32) {
    ES_DESTINATION_TYPE_EXISTING_FILE = 0,
    ES_DESTINATION_TYPE_NEW_PATH = 1,
};

// Action type
const es_action_type_t = enum(u32) {
    ES_ACTION_TYPE_AUTH = 0,
    ES_ACTION_TYPE_NOTIFY = 1,
};

// ── Event structs ────────────────────────────────────────────────────

const es_event_unlink_t = extern struct {
    target: *es_file_t,
    parent_dir: *es_file_t,
    reserved: [64]u8,
};

const es_event_rename_t = extern struct {
    source: *es_file_t,
    destination_type: es_destination_type_t,
    destination: extern union {
        existing_file: *es_file_t,
        new_path: extern struct {
            dir: *es_file_t,
            filename: es_string_token_t,
        },
    },
    reserved: [64]u8,
};

const es_event_truncate_t = extern struct {
    target: *es_file_t,
    reserved: [64]u8,
};

const es_event_link_t = extern struct {
    source: *es_file_t,
    target_dir: *es_file_t,
    target_filename: es_string_token_t,
    reserved: [64]u8,
};

const es_event_create_t = extern struct {
    destination_type: es_destination_type_t,
    destination: extern union {
        existing_file: *es_file_t,
        new_path: extern struct {
            dir: *es_file_t,
            filename: es_string_token_t,
            mode: u16,
        },
    },
    reserved2: [16]u8,
    reserved: [48]u8,
};

const es_event_clone_t = extern struct {
    source: *es_file_t,
    target_dir: *es_file_t,
    target_name: es_string_token_t,
    reserved: [64]u8,
};

const es_event_exchangedata_t = extern struct {
    file1: *es_file_t,
    file2: *es_file_t,
    reserved: [64]u8,
};

const es_event_setextattr_t = extern struct {
    target: *es_file_t,
    extattr: es_string_token_t,
    reserved: [64]u8,
};

const es_event_deleteextattr_t = extern struct {
    target: *es_file_t,
    extattr: es_string_token_t,
    reserved: [64]u8,
};

const es_event_exec_t = extern struct {
    target: *es_process_t, // the NEW process (post-exec)
    dyld_exec_path: es_string_token_t, // version >= 7
    // Union with reserved/versioned fields — we access via target
    _reserved: [64]u8,
};

// The events union — only the fields we subscribe to
// All pre-macOS-13 events are inline structs; post-13 are pointers
const es_events_t = extern union {
    exec: es_event_exec_t,
    unlink: es_event_unlink_t,
    link: es_event_link_t,
    rename: es_event_rename_t,
    truncate: es_event_truncate_t,
    create: es_event_create_t,
    clone: es_event_clone_t,
    exchangedata: es_event_exchangedata_t,
    setextattr: es_event_setextattr_t,
    deleteextattr: es_event_deleteextattr_t,
    // Pad to cover the full union size (largest member)
    _raw: [512]u8,
};

// Event ID for auth actions
const es_event_id_t = extern struct {
    reserved: [32]u8,
};

// Result for notify actions
const es_result_t = extern struct {
    result_type: u32,
    result: extern union {
        auth: u32,
        flags: u32,
    },
};

// Main message struct
const es_message_t = extern struct {
    version: u32,
    time: c.timespec,
    mach_time: u64,
    deadline: u64,
    process: *es_process_t,
    seq_num: u64,
    action_type: es_action_type_t,
    action: extern union {
        auth: es_event_id_t,
        notify: es_result_t,
    },
    event_type: es_event_type_t,
    event: es_events_t,
    // thread and global_seq_num follow but we don't access them
};

// Result enums
const es_new_client_result_t = enum(u32) {
    ES_NEW_CLIENT_RESULT_SUCCESS = 0,
    ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT = 1,
    ES_NEW_CLIENT_RESULT_ERR_INTERNAL = 2,
    ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED = 3,
    ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED = 4,
    ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED = 5,
    ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS = 6,
};

const es_return_t = enum(u32) {
    ES_RETURN_SUCCESS = 0,
    ES_RETURN_ERROR = 1,
};

const es_auth_result_t = enum(u32) {
    ES_AUTH_RESULT_ALLOW = 0,
    ES_AUTH_RESULT_DENY = 1,
};

const es_clear_cache_result_t = enum(u32) {
    ES_CLEAR_CACHE_RESULT_SUCCESS = 0,
    ES_CLEAR_CACHE_RESULT_ERR_INTERNAL = 1,
};

// ES handler — function pointer (not ObjC block)
const es_handler_t = *const fn (*es_client_t, *const es_message_t) callconv(.c) void;

// ── External ES functions ────────────────────────────────────────────

extern "EndpointSecurity" fn es_new_client(client: **es_client_t, handler: es_handler_t) es_new_client_result_t;
extern "EndpointSecurity" fn es_delete_client(client: *es_client_t) es_return_t;
extern "EndpointSecurity" fn es_subscribe(client: *es_client_t, events: [*]const es_event_type_t, event_count: u32) es_return_t;
extern "EndpointSecurity" fn es_unsubscribe_all(client: *es_client_t) es_return_t;
extern "EndpointSecurity" fn es_respond_auth_result(client: *es_client_t, message: *const es_message_t, result: es_auth_result_t, cache: bool) es_return_t;
extern "EndpointSecurity" fn es_clear_cache(client: *es_client_t) es_clear_cache_result_t;
extern "EndpointSecurity" fn es_exec_arg_count(event: *const es_event_exec_t) u32;
extern "EndpointSecurity" fn es_exec_arg(event: *const es_event_exec_t, index: u32) es_string_token_t;

// ═══════════════════════════════════════════════════════════════════════════════
// Configuration — powered by CTK core policy engine
// ═══════════════════════════════════════════════════════════════════════════════

const EMERGENCY_DISABLE_FILE: [*:0]const u8 = "/tmp/.guardian_esd_disable";

var es_client: ?*es_client_t = null;
var running: bool = true;

// Statistics
var blocked_count: u64 = 0;
var allowed_count: u64 = 0;

// Policy engine (initialized in main, read-only in handler — no allocation needed)
var policy_config: ctk.config.Config = undefined;
var policy_engine: ctk.PolicyEngine = undefined;

// ═══════════════════════════════════════════════════════════════════════════════
// Logging (raw syscalls to avoid any libc reentrancy issues)
// ═══════════════════════════════════════════════════════════════════════════════

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[es-warden] " ++ fmt ++ "\n", args) catch return;
    _ = c.write(2, msg.ptr, msg.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Event handler — the hot path
// ═══════════════════════════════════════════════════════════════════════════════

fn handleEvent(client: *es_client_t, message: *const es_message_t) callconv(.c) void {
    // Emergency disable check
    if (c.access(EMERGENCY_DISABLE_FILE, 0) == 0) {
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_ALLOW, false);
        return;
    }

    // The process that PERFORMED the action (the parent/caller)
    const process = message.process;
    const proc_path = process.executable.path.slice();
    const pid = es_process_t.pidFromToken(process.audit_token);

    // Responsible process — the root of the process tree (e.g. Claude Code)
    // Available in message version >= 4 (macOS 12.3+)
    const responsible_pid = if (message.version >= 4)
        es_process_t.pidFromToken(process.responsible_audit_token)
    else
        pid;

    const parent_pid = if (message.version >= 4)
        es_process_t.pidFromToken(process.parent_audit_token)
    else
        @as(u32, @intCast(process.ppid));

    // Handle AUTH_EXEC separately — it has a target process, not a target path
    if (message.event_type == .ES_EVENT_TYPE_AUTH_EXEC) {
        handleExec(client, message, process, pid, responsible_pid, parent_pid);
        return;
    }

    // Extract target path for file operations
    const target_path = getTargetPath(message) orelse {
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_ALLOW, false);
        allowed_count += 1;
        return;
    };

    // Map ES event type to CTK event kind
    const event_kind = esEventToKind(message.event_type) orelse {
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_ALLOW, false);
        allowed_count += 1;
        return;
    };

    // Build a CTK Event and evaluate against the unified policy engine
    const agent_id: ?[]const u8 = if (responsible_pid != pid) "claude" else null;
    const event = ctk.Event{
        .timestamp_ns = message.mach_time,
        .pid = pid,
        .process_path = proc_path,
        .kind = event_kind,
        .target_path = target_path,
        .agent_id = agent_id,
        .responsible_pid = responsible_pid,
        .parent_pid = parent_pid,
    };

    const decision = policy_engine.evaluate(&event);

    if (decision == .deny) {
        blocked_count += 1;
        const event_name = getEventName(message.event_type);
        log("BLOCKED {s}: {s}", .{ event_name, target_path });
        log("  Process: {s} (PID: {d}, parent: {d}, responsible: {d})", .{ proc_path, pid, parent_pid, responsible_pid });
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_DENY, false);
    } else {
        allowed_count += 1;
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_ALLOW, false);
    }
}

fn handleExec(
    client: *es_client_t,
    message: *const es_message_t,
    process: *es_process_t,
    pid: u32,
    responsible_pid: u32,
    parent_pid: u32,
) void {
    // The exec target — the NEW executable about to run
    const exec_target = message.event.exec.target;
    const exec_path = exec_target.executable.path.slice();
    const caller_path = process.executable.path.slice();

    // Build CTK Event for exec — target_path is the executable being launched,
    // detail is the binary name (for denied_command matching)
    const exec_name = std.fs.path.basename(exec_path);

    // If responsible_pid != pid, this exec was spawned by another process.
    // Set agent_id to signal that agent-scoped rules should apply.
    const agent_id: ?[]const u8 = if (responsible_pid != pid) "claude" else null;

    const event = ctk.Event{
        .timestamp_ns = message.mach_time,
        .pid = pid,
        .process_path = caller_path,
        .kind = .exec,
        .target_path = exec_path,
        .detail = exec_name,
        .agent_id = agent_id,
        .responsible_pid = responsible_pid,
        .parent_pid = parent_pid,
    };

    var decision = policy_engine.evaluate(&event);

    // Handle askpass gate: allow only if sudo is invoked with -A flag
    if (decision == .allow_if_askpass) {
        if (execHasAskpassFlag(message)) {
            log("ASKPASS exec: {s} (human review via GUI prompt)", .{exec_path});
            log("  Agent PID: {d}, Responsible PID: {d}", .{ pid, responsible_pid });
            decision = .allow;
        } else {
            log("BLOCKED exec: {s} (agent sudo without askpass)", .{exec_path});
            log("  Use: SUDO_ASKPASS=~/.local/bin/sudo-askpass sudo -A <cmd>", .{});
            decision = .deny;
        }
    }

    if (decision == .deny) {
        blocked_count += 1;
        log("BLOCKED exec: {s}", .{exec_path});
        log("  Called by: {s} (PID: {d})", .{ caller_path, pid });
        log("  Parent PID: {d}, Responsible PID: {d}", .{ parent_pid, responsible_pid });
        if (responsible_pid != pid) {
            log("  Attribution: responsible process {d} spawned chain → {d} → exec({s})", .{ responsible_pid, pid, exec_name });
        }
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_DENY, false);
    } else {
        allowed_count += 1;
        _ = es_respond_auth_result(client, message, .ES_AUTH_RESULT_ALLOW, false);
    }
}

/// Check if a sudo exec has the -A (askpass) flag in its arguments.
fn execHasAskpassFlag(message: *const es_message_t) bool {
    const exec_event = &message.event.exec;
    const argc = es_exec_arg_count(exec_event);
    var i: u32 = 0;
    while (i < argc) : (i += 1) {
        const arg = es_exec_arg(exec_event, i).slice();
        if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--askpass")) return true;
        // Also check combined flags like -As
        if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |ch| {
                if (ch == 'A') return true;
            }
        }
    }
    return false;
}

fn esEventToKind(event_type: es_event_type_t) ?ctk.Event.Kind {
    return switch (event_type) {
        .ES_EVENT_TYPE_AUTH_EXEC => .exec,
        .ES_EVENT_TYPE_AUTH_UNLINK => .file_unlink,
        .ES_EVENT_TYPE_AUTH_RENAME => .file_rename,
        .ES_EVENT_TYPE_AUTH_TRUNCATE => .file_truncate,
        .ES_EVENT_TYPE_AUTH_LINK => .file_link,
        .ES_EVENT_TYPE_AUTH_CREATE => .file_create,
        .ES_EVENT_TYPE_AUTH_CLONE => .file_clone,
        .ES_EVENT_TYPE_AUTH_EXCHANGEDATA => .file_exchangedata,
        .ES_EVENT_TYPE_AUTH_SETEXTATTR => .file_setextattr,
        .ES_EVENT_TYPE_AUTH_DELETEEXTATTR => .file_deleteextattr,
        else => null,
    };
}

fn getTargetPath(message: *const es_message_t) ?[]const u8 {
    return switch (message.event_type) {
        .ES_EVENT_TYPE_AUTH_UNLINK => message.event.unlink.target.path.slice(),
        .ES_EVENT_TYPE_AUTH_RENAME => message.event.rename.source.path.slice(),
        .ES_EVENT_TYPE_AUTH_TRUNCATE => message.event.truncate.target.path.slice(),
        .ES_EVENT_TYPE_AUTH_LINK => message.event.link.target_dir.path.slice(),
        .ES_EVENT_TYPE_AUTH_CREATE => blk: {
            if (message.event.create.destination_type == .ES_DESTINATION_TYPE_NEW_PATH) {
                break :blk message.event.create.destination.new_path.dir.path.slice();
            } else {
                break :blk message.event.create.destination.existing_file.path.slice();
            }
        },
        .ES_EVENT_TYPE_AUTH_CLONE => message.event.clone.target_dir.path.slice(),
        .ES_EVENT_TYPE_AUTH_EXCHANGEDATA => message.event.exchangedata.file1.path.slice(),
        .ES_EVENT_TYPE_AUTH_SETEXTATTR => message.event.setextattr.target.path.slice(),
        .ES_EVENT_TYPE_AUTH_DELETEEXTATTR => message.event.deleteextattr.target.path.slice(),
        else => null,
    };
}

fn getEventName(event_type: es_event_type_t) []const u8 {
    return switch (event_type) {
        .ES_EVENT_TYPE_AUTH_EXEC => "exec",
        .ES_EVENT_TYPE_AUTH_UNLINK => "unlink",
        .ES_EVENT_TYPE_AUTH_RENAME => "rename",
        .ES_EVENT_TYPE_AUTH_TRUNCATE => "truncate",
        .ES_EVENT_TYPE_AUTH_LINK => "link",
        .ES_EVENT_TYPE_AUTH_CREATE => "create",
        .ES_EVENT_TYPE_AUTH_CLONE => "clone",
        .ES_EVENT_TYPE_AUTH_EXCHANGEDATA => "exchangedata",
        .ES_EVENT_TYPE_AUTH_SETEXTATTR => "setextattr",
        .ES_EVENT_TYPE_AUTH_DELETEEXTATTR => "deleteextattr",
        else => "unknown",
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Signal handler
// ═══════════════════════════════════════════════════════════════════════════════

fn signalHandler(_: c_int) callconv(.c) void {
    running = false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    log("Guardian Shield - Endpoint Security Edition", .{});
    log("Copyright (c) 2025-2026 Quantum Encoding Ltd", .{});

    // Check root
    if (c.getuid() != 0) {
        log("ERROR: Must run as root. Usage: sudo ./es-warden", .{});
        std.process.exit(1);
    }

    // Load configuration via CTK core
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    policy_config = ctk.config.load(allocator, ctk.config.DEFAULT_CONFIG_PATH);
    policy_engine = .{ .rules = policy_config.rules.items };
    log("Loaded {d} policy rules from CTK core", .{policy_config.rules.items.len});

    // Signal handlers (use extern directly since std.c doesn't expose signal on macOS in 0.16)
    const signal_fn = struct {
        extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) callconv(.c) ?*const fn (c_int) callconv(.c) void;
    }.signal;
    _ = signal_fn(2, signalHandler); // SIGINT
    _ = signal_fn(15, signalHandler); // SIGTERM

    // Create ES client
    var client: *es_client_t = undefined;
    const result = es_new_client(&client, handleEvent);

    switch (result) {
        .ES_NEW_CLIENT_RESULT_SUCCESS => {
            log("Endpoint Security client created", .{});
        },
        .ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED => {
            log("ERROR: Missing ES entitlement", .{});
            log("  Need: com.apple.developer.endpoint-security.client", .{});
            log("  Sign with: codesign --sign 'Developer ID' --entitlements es_warden.entitlements --options runtime es-warden", .{});
            std.process.exit(1);
        },
        .ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED => {
            log("ERROR: Not permitted — grant Full Disk Access in System Settings", .{});
            std.process.exit(1);
        },
        .ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED => {
            log("ERROR: Insufficient privileges — run as root (sudo)", .{});
            std.process.exit(1);
        },
        .ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS => {
            log("ERROR: Too many ES clients — is another instance running?", .{});
            std.process.exit(1);
        },
        else => {
            log("ERROR: Failed to create ES client (code {d})", .{@intFromEnum(result)});
            std.process.exit(1);
        },
    }

    es_client = client;
    defer {
        if (es_client) |cl| {
            _ = es_unsubscribe_all(cl);
            _ = es_delete_client(cl);
            log("ES client destroyed", .{});
        }
    }

    // Clear cache
    _ = es_clear_cache(client);

    // Subscribe to events
    const events = [_]es_event_type_t{
        .ES_EVENT_TYPE_AUTH_EXEC, // process spawn control
        .ES_EVENT_TYPE_AUTH_UNLINK,
        .ES_EVENT_TYPE_AUTH_RENAME,
        .ES_EVENT_TYPE_AUTH_TRUNCATE,
        .ES_EVENT_TYPE_AUTH_LINK,
        .ES_EVENT_TYPE_AUTH_CREATE,
        .ES_EVENT_TYPE_AUTH_CLONE,
        .ES_EVENT_TYPE_AUTH_EXCHANGEDATA,
        .ES_EVENT_TYPE_AUTH_SETEXTATTR,
        .ES_EVENT_TYPE_AUTH_DELETEEXTATTR,
    };

    if (es_subscribe(client, &events, events.len) != .ES_RETURN_SUCCESS) {
        log("ERROR: Failed to subscribe to events", .{});
        std.process.exit(1);
    }

    log("Subscribed to {d} event types", .{events.len});
    log("Guardian Shield ACTIVE — kernel-level protection enabled", .{});
    log("Press Ctrl+C to stop", .{});

    // Main loop — events are delivered via the handler callback
    while (running) {
        _ = c.nanosleep(&.{ .sec = 0, .nsec = 100_000_000 }, null); // 100ms
    }

    log("Shutting down... blocked={d} allowed={d}", .{ blocked_count, allowed_count });
}
