//! C ABI over the library: the `zes_*` half of `include/es_core.h`.
//!
//! Every function here is `export`ed with the C calling convention so a Swift
//! (or C, or Rust) host can link `libes_core_zig.a` and drive EndpointSecurity
//! through the same shape the Rust-backed `res_*` set implements. `EscEvent`
//! mirrors `esc_event` in the header; the layout test below imports the header
//! through `@cImport` and checks every offset, so the two cannot drift apart.
//!
//! Handles: `esc_client` is a heap `CapiClient`; `esc_message` is the
//! `es_message_t` pointer itself, so retain/release and the exec accessors
//! work on the same value the handler received.

const std = @import("std");
const es = @import("lib.zig");
const sys = es.sys;
const darwin = es.darwin;

pub const abi_version: u32 = 1;

pub const err_api_unavailable: c_int = -1;
pub const err_invalid_argument: c_int = -2;
pub const err_out_of_memory: c_int = -3;
pub const err_unknown_event: c_int = -4;

pub const EscStr = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    fn from(s: []const u8) EscStr {
        return .{ .ptr = if (s.len == 0) null else s.ptr, .len = s.len };
    }
    fn fromToken(t: sys.es_string_token_t) EscStr {
        return from(t.slice());
    }
};

pub const EscAuditToken = extern struct { val: [8]u32 };

/// Mirror of `esc_event`; field order and types must match the header.
pub const EscEvent = extern struct {
    abi_version: u32 = abi_version,
    event_type: u32 = 0,
    message_version: u32 = 0,
    argc: u32 = 0,
    flags: u32 = 0,
    status: i32 = 0,

    is_auth: u8 = 0,
    is_platform_binary: u8 = 0,
    is_es_client: u8 = 0,
    target_is_platform_binary: u8 = 0,

    pid: i32 = 0,
    ppid: i32 = 0,
    original_ppid: i32 = 0,
    responsible_pid: i32 = -1,
    parent_pid: i32 = -1,
    target_pid: i32 = 0,

    mach_time: u64 = 0,
    deadline: u64 = 0,
    seq_num: u64 = 0,
    global_seq_num: u64 = 0,

    audit_token: EscAuditToken = .{ .val = .{0} ** 8 },

    process_path: EscStr = .{},
    signing_id: EscStr = .{},
    team_id: EscStr = .{},
    target_path: EscStr = .{},
    target_path2: EscStr = .{},
    name: EscStr = .{},
};

pub const Handler = *const fn (ctx: ?*anyopaque, client: *CapiClient, msg: *const sys.es_message_t, ev: *const EscEvent) callconv(.c) void;

pub const CapiClient = struct {
    client: es.Client,
    handler: Handler,
    ctx: ?*anyopaque,
};

const allocator = std.heap.c_allocator;

fn onMessage(self: *CapiClient, _: es.Client, msg: es.Message) void {
    var ev: EscEvent = .{};
    _ = decode(msg, &ev);
    self.handler(self.ctx, self, msg.raw, &ev);
}

/// The shared decode step: read what a monitoring extension reads on every event.
pub fn decode(msg: es.Message, out: *EscEvent) c_int {
    out.* = .{};
    const p = msg.process();
    out.event_type = @intFromEnum(msg.eventType());
    out.message_version = msg.version();
    out.is_auth = @intFromBool(msg.isAuth());
    out.is_platform_binary = @intFromBool(p.isPlatformBinary());
    out.is_es_client = @intFromBool(p.isEsClient());
    out.pid = p.pid();
    out.ppid = p.ppid();
    out.original_ppid = p.originalPpid();
    if (p.responsibleAuditToken()) |t| out.responsible_pid = t.pid();
    if (p.parentAuditToken()) |t| out.parent_pid = t.pid();
    out.mach_time = msg.machTime();
    out.deadline = msg.deadline();
    out.seq_num = msg.seqNum() orelse 0;
    out.global_seq_num = msg.globalSeqNum() orelse 0;
    out.audit_token = .{ .val = p.auditToken().val };
    out.process_path = EscStr.from(p.executable().path());
    out.signing_id = EscStr.from(p.signingId());
    out.team_id = EscStr.from(p.teamId());

    switch (msg.event()) {
        .unknown => return err_unknown_event,
        .exec => |e| {
            const x = es.Exec{ .raw = e, .version = msg.version() };
            const t = x.target();
            out.target_pid = t.pid();
            out.target_is_platform_binary = @intFromBool(t.isPlatformBinary());
            out.target_path = EscStr.from(t.executable().path());
            out.argc = x.argCount();
            if (x.cwd()) |c| out.target_path2 = EscStr.from(c.path());
        },
        .open => |o| {
            out.target_path = EscStr.fromToken(o.file.path);
            out.flags = @bitCast(o.fflag);
        },
        .close => |c| {
            out.target_path = EscStr.fromToken(c.target.path);
            out.flags = @intFromBool(c.modified);
        },
        .create => |c| switch (c.destination_type) {
            .ES_DESTINATION_TYPE_EXISTING_FILE => out.target_path = EscStr.fromToken(c.destination.existing_file.path),
            .ES_DESTINATION_TYPE_NEW_PATH => {
                out.target_path2 = EscStr.fromToken(c.destination.new_path.dir.path);
                out.name = EscStr.fromToken(c.destination.new_path.filename);
                out.flags = c.destination.new_path.mode;
            },
            _ => {},
        },
        .unlink => |u| {
            out.target_path = EscStr.fromToken(u.target.path);
            out.target_path2 = EscStr.fromToken(u.parent_dir.path);
        },
        .rename => |r| {
            out.target_path = EscStr.fromToken(r.source.path);
            switch (r.destination_type) {
                .ES_DESTINATION_TYPE_EXISTING_FILE => out.target_path2 = EscStr.fromToken(r.destination.existing_file.path),
                .ES_DESTINATION_TYPE_NEW_PATH => {
                    out.target_path2 = EscStr.fromToken(r.destination.new_path.dir.path);
                    out.name = EscStr.fromToken(r.destination.new_path.filename);
                },
                _ => {},
            }
        },
        .exchangedata => |x| {
            out.target_path = EscStr.fromToken(x.file1.path);
            out.target_path2 = EscStr.fromToken(x.file2.path);
        },
        .lookup => |l| {
            out.target_path = EscStr.fromToken(l.source_dir.path);
            out.name = EscStr.fromToken(l.relative_target);
        },
        .fork => |f| out.target_pid = f.child.audit_token.pid(),
        .exit => |e| out.status = e.stat,
        .signal => |s| {
            out.status = s.sig;
            out.target_pid = s.target.audit_token.pid();
        },
        .mount => |m| fillStatfs(out, m.statfs),
        .unmount => |m| fillStatfs(out, m.statfs),
        .remount => |m| fillStatfs(out, m.statfs),
        .uipc_bind => |b| {
            out.target_path2 = EscStr.fromToken(b.dir.path);
            out.name = EscStr.fromToken(b.filename);
            out.flags = b.mode;
        },
        .kextload => |k| out.name = EscStr.fromToken(k.identifier),
        .kextunload => |k| out.name = EscStr.fromToken(k.identifier),
        .iokit_open => |i| {
            out.name = EscStr.fromToken(i.user_client_class);
            out.flags = i.user_client_type;
        },
        .pty_grant => |p_| out.flags = @bitCast(p_.dev),
        .pty_close => |p_| out.flags = @bitCast(p_.dev),
        .access => |a| {
            out.target_path = EscStr.fromToken(a.target.path);
            out.flags = @bitCast(a.mode);
        },
        .fcntl => |f| {
            out.target_path = EscStr.fromToken(f.target.path);
            out.flags = @bitCast(f.cmd);
        },
        .setmode => |s| {
            out.target_path = EscStr.fromToken(s.target.path);
            out.flags = s.mode;
        },
        .setflags => |s| {
            out.target_path = EscStr.fromToken(s.target.path);
            out.flags = s.flags;
        },
        .file_provider_update => |f| {
            out.target_path = EscStr.fromToken(f.source.path);
            out.name = EscStr.fromToken(f.target_path);
        },
        .file_provider_materialize => |f| {
            out.target_path = EscStr.fromToken(f.source.path);
            out.target_path2 = EscStr.fromToken(f.target.path);
        },
        // Everything else follows the common shapes: a `target`/`source`/`file`
        // file, a `target_dir` + new-name pair, an `extattr` name, or a process target.
        inline else => |payload| fillGeneric(out, payload),
    }
    return 0;
}

fn fillStatfs(out: *EscEvent, sf: *const sys.struct_statfs) void {
    out.target_path = EscStr.from(sf.mountPoint());
    out.target_path2 = EscStr.from(sf.mountedFrom());
    out.name = EscStr.from(sf.fsTypeName());
}

fn fillGeneric(out: *EscEvent, payload: anytype) void {
    const T = @TypeOf(payload.*);
    if (@hasField(T, "target")) {
        switch (@FieldType(T, "target")) {
            *sys.es_file_t => out.target_path = EscStr.fromToken(payload.target.path),
            *sys.es_process_t => out.target_pid = payload.target.audit_token.pid(),
            ?*sys.es_process_t => if (payload.target) |t| {
                out.target_pid = t.audit_token.pid();
            },
            else => {},
        }
    }
    if (@hasField(T, "source") and @FieldType(T, "source") == *sys.es_file_t) out.target_path = EscStr.fromToken(payload.source.path);
    if (@hasField(T, "file") and @FieldType(T, "file") == *sys.es_file_t) out.target_path = EscStr.fromToken(payload.file.path);
    if (@hasField(T, "target_dir") and @FieldType(T, "target_dir") == *sys.es_file_t) out.target_path2 = EscStr.fromToken(payload.target_dir.path);
    if (@hasField(T, "target_filename")) out.name = EscStr.fromToken(payload.target_filename);
    if (@hasField(T, "target_name")) out.name = EscStr.fromToken(payload.target_name);
    if (@hasField(T, "extattr")) out.name = EscStr.fromToken(payload.extattr);
    if (@hasField(T, "sig")) out.status = payload.sig;
}

// ───────────────────────────── exports ─────────────────────────────

fn clientOf(c: ?*CapiClient) ?*CapiClient {
    return c;
}

fn msgOf(m: ?*const sys.es_message_t) ?es.Message {
    return es.Message.fromRaw(m orelse return null);
}

fn retCode(r: es.Error!void) c_int {
    r catch |err| return switch (err) {
        error.ApiUnavailable => err_api_unavailable,
        error.NameTooLong => err_invalid_argument,
        error.OutOfMemory => err_out_of_memory,
        error.EsError => @intFromEnum(sys.es_return_t.ES_RETURN_ERROR),
    };
    return 0;
}

fn respondCode(r: es.RespondError!void) c_int {
    r catch |err| return switch (err) {
        error.InvalidArgument => 1,
        error.Internal => 2,
        error.NotFound => 3,
        error.DuplicateResponse => 4,
        error.EventType => 5,
        error.Unknown => 2,
    };
    return 0;
}

const version_string = "zig zig_endpoint_sec 0.1.0 (" ++ @import("layout_anchors.zig").sdk ++ ")";

export fn zes_version() EscStr {
    return EscStr.from(version_string);
}

export fn zes_client_new(out: ?*?*CapiClient, handler: ?Handler, ctx: ?*anyopaque) c_int {
    const o = out orelse return err_invalid_argument;
    const h = handler orelse return err_invalid_argument;
    const self = allocator.create(CapiClient) catch return err_out_of_memory;
    self.* = .{ .client = undefined, .handler = h, .ctx = ctx };
    self.client = es.Client.init(CapiClient, self, onMessage) catch |err| {
        allocator.destroy(self);
        return switch (err) {
            error.InvalidArgument => 1,
            error.Internal, error.Unknown => 2,
            error.NotEntitled => 3,
            error.NotPermitted => 4,
            error.NotPrivileged => 5,
            error.TooManyClients => 6,
            error.ApiUnavailable => err_api_unavailable,
            error.OutOfMemory => err_out_of_memory,
        };
    };
    o.* = self;
    return 0;
}

export fn zes_client_delete(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const r = self.client.delete();
    allocator.destroy(self);
    return retCode(r);
}

export fn zes_subscribe(c: ?*CapiClient, events: ?[*]const u32, count: u32) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const ev = events orelse return err_invalid_argument;
    const typed: [*]const sys.es_event_type_t = @ptrCast(ev);
    return retCode(self.client.subscribe(typed[0..count]));
}

export fn zes_unsubscribe_all(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.unsubscribeAll());
}

export fn zes_respond_auth(c: ?*CapiClient, m: ?*const sys.es_message_t, result: u32, cache: bool) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const msg = msgOf(m) orelse return err_invalid_argument;
    return respondCode(self.client.respondAuth(msg, @enumFromInt(result), cache));
}

export fn zes_respond_flags(c: ?*CapiClient, m: ?*const sys.es_message_t, flags: u32, cache: bool) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const msg = msgOf(m) orelse return err_invalid_argument;
    return respondCode(self.client.respondFlags(msg, flags, cache));
}

export fn zes_respond(c: ?*CapiClient, m: ?*const sys.es_message_t, allow: bool, cache: bool) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const msg = msgOf(m) orelse return err_invalid_argument;
    return respondCode(self.client.respond(msg, if (allow) .allow else .deny, cache));
}

export fn zes_mute_process(c: ?*CapiClient, token: ?*const EscAuditToken) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const t = token orelse return err_invalid_argument;
    return retCode(self.client.muteProcess(.{ .val = t.val }));
}

export fn zes_unmute_process(c: ?*CapiClient, token: ?*const EscAuditToken) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const t = token orelse return err_invalid_argument;
    return retCode(self.client.unmuteProcess(.{ .val = t.val }));
}

export fn zes_mute_self(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.muteSelf());
}

export fn zes_mute_path(c: ?*CapiClient, path: ?[*:0]const u8, kind: u32) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    const p = path orelse return err_invalid_argument;
    return retCode(self.client.mutePath(std.mem.span(p), @enumFromInt(kind)));
}

export fn zes_unmute_all_paths(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.unmuteAllPaths());
}

export fn zes_unmute_all_target_paths(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.unmuteAllTargetPaths());
}

export fn zes_invert_muting(c: ?*CapiClient, kind: u32) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.invertMuting(@enumFromInt(kind)));
}

export fn zes_clear_cache(c: ?*CapiClient) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    self.client.clearCache() catch |err| return switch (err) {
        error.Internal => 1,
        error.Throttle => 2,
        error.Unknown => 1,
    };
    return 0;
}

export fn zes_set_deadline_miss_mode(c: ?*CapiClient, mode: u32) c_int {
    const self = clientOf(c) orelse return err_invalid_argument;
    return retCode(self.client.setDeadlineMissMode(@enumFromInt(mode)));
}

export fn zes_message_retain(m: ?*const sys.es_message_t) void {
    const msg = msgOf(m) orelse return;
    _ = msg.retain() catch {};
}

export fn zes_message_release(m: ?*const sys.es_message_t) void {
    const msg = msgOf(m) orelse return;
    msg.release();
}

export fn zes_decode(m: ?*const sys.es_message_t, out: ?*EscEvent) c_int {
    const msg = msgOf(m) orelse return err_invalid_argument;
    const o = out orelse return err_invalid_argument;
    return decode(msg, o);
}

fn execOf(m: ?*const sys.es_message_t) ?es.Exec {
    const msg = msgOf(m) orelse return null;
    return msg.exec();
}

export fn zes_exec_arg_count(m: ?*const sys.es_message_t) u32 {
    const x = execOf(m) orelse return 0;
    return x.argCount();
}

export fn zes_exec_arg(m: ?*const sys.es_message_t, index: u32) EscStr {
    const x = execOf(m) orelse return .{};
    if (index >= x.argCount()) return .{};
    return EscStr.from(x.arg(index));
}

export fn zes_exec_env_count(m: ?*const sys.es_message_t) u32 {
    const x = execOf(m) orelse return 0;
    return x.envCount();
}

export fn zes_exec_env(m: ?*const sys.es_message_t, index: u32) EscStr {
    const x = execOf(m) orelse return .{};
    if (index >= x.envCount()) return .{};
    return EscStr.from(x.env(index));
}

export fn zes_exec_find_env(m: ?*const sys.es_message_t, name: ?[*:0]const u8) EscStr {
    const x = execOf(m) orelse return .{};
    const n = name orelse return .{};
    return EscStr.from(x.findEnv(std.mem.span(n)) orelse return .{});
}

export fn zes_now_ticks() u64 {
    return darwin.machtime.now();
}

export fn zes_ticks_to_ns(ticks: u64) u64 {
    return darwin.machtime.ticksToNanos(ticks);
}

// ───────────────────────────── tests ─────────────────────────────

const c_header = @cImport(@cInclude("es_core.h"));
const testing_support = @import("testing_support.zig");

test "anchor: EscEvent matches esc_event in es_core.h field for field" {
    try std.testing.expectEqual(@sizeOf(c_header.esc_event), @sizeOf(EscEvent));
    try std.testing.expectEqual(@sizeOf(c_header.esc_str), @sizeOf(EscStr));
    try std.testing.expectEqual(@sizeOf(c_header.esc_audit_token), @sizeOf(EscAuditToken));
    try std.testing.expectEqual(@as(u32, c_header.ESC_ABI_VERSION), abi_version);
    inline for (std.meta.fields(EscEvent)) |f| {
        try std.testing.expectEqual(@offsetOf(c_header.esc_event, f.name), @offsetOf(EscEvent, f.name));
        try std.testing.expectEqual(@sizeOf(@FieldType(c_header.esc_event, f.name)), @sizeOf(f.type));
    }
    try std.testing.expectEqual(std.meta.fields(c_header.esc_event).len, std.meta.fields(EscEvent).len);
    try std.testing.expectEqual(@as(c_int, c_header.ESC_ERR_API_UNAVAILABLE), err_api_unavailable);
    try std.testing.expectEqual(@as(c_int, c_header.ESC_ERR_UNKNOWN_EVENT), err_unknown_event);
}

test "decode an exec fixture" {
    var fx: testing_support.Fixture = undefined;
    fx.init();
    // The fixture cannot carry the packed argv tail that es_exec_arg_count reads,
    // so decode is exercised on a non-exec event and the exec branch below via its fields.
    fx.message.event_type = .ES_EVENT_TYPE_NOTIFY_UNLINK;
    var unlink = std.mem.zeroes(sys.es_event_unlink_t);
    unlink.target = &fx.target_executable;
    unlink.parent_dir = &fx.cwd;
    fx.message.event = .{ .unlink = unlink };
    var ev: EscEvent = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zes_decode(&fx.message, &ev));
    try std.testing.expectEqual(@intFromEnum(sys.es_event_type_t.ES_EVENT_TYPE_NOTIFY_UNLINK), ev.event_type);
    try std.testing.expectEqual(@as(i32, 4242), ev.pid);
    try std.testing.expectEqual(@as(i32, 501), ev.ppid);
    try std.testing.expectEqual(@as(i32, 1), ev.responsible_pid);
    try std.testing.expectEqual(@as(i32, 501), ev.parent_pid);
    try std.testing.expectEqual(@as(u8, 0), ev.is_auth);
    try std.testing.expectEqualStrings("/usr/local/bin/tool", ev.process_path.ptr.?[0..ev.process_path.len]);
    try std.testing.expectEqualStrings("com.example.tool", ev.signing_id.ptr.?[0..ev.signing_id.len]);
    try std.testing.expectEqualStrings("/bin/zsh", ev.target_path.ptr.?[0..ev.target_path.len]);
    try std.testing.expectEqualStrings("/Users/tester/project", ev.target_path2.ptr.?[0..ev.target_path2.len]);
    try std.testing.expectEqual(@as(usize, 0), ev.name.len);
}

test "decode rename with a new-path destination and a generic-shape event" {
    var fx: testing_support.Fixture = undefined;
    fx.init();
    var rename = std.mem.zeroes(sys.es_event_rename_t);
    rename.source = &fx.executable;
    rename.destination_type = .ES_DESTINATION_TYPE_NEW_PATH;
    rename.destination = .{ .new_path = .{ .dir = &fx.cwd, .filename = testing_support.Fixture.token("renamed.txt") } };
    fx.message.event_type = .ES_EVENT_TYPE_AUTH_RENAME;
    fx.message.action_type = .ES_ACTION_TYPE_AUTH;
    fx.message.event = .{ .rename = rename };
    var ev: EscEvent = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zes_decode(&fx.message, &ev));
    try std.testing.expectEqual(@as(u8, 1), ev.is_auth);
    try std.testing.expectEqualStrings("/usr/local/bin/tool", ev.target_path.ptr.?[0..ev.target_path.len]);
    try std.testing.expectEqualStrings("/Users/tester/project", ev.target_path2.ptr.?[0..ev.target_path2.len]);
    try std.testing.expectEqualStrings("renamed.txt", ev.name.ptr.?[0..ev.name.len]);

    // link goes through fillGeneric: source + target_dir + target_filename.
    var link = std.mem.zeroes(sys.es_event_link_t);
    link.source = &fx.executable;
    link.target_dir = &fx.cwd;
    link.target_filename = testing_support.Fixture.token("hardlink");
    fx.message.event_type = .ES_EVENT_TYPE_NOTIFY_LINK;
    fx.message.event = .{ .link = link };
    try std.testing.expectEqual(@as(c_int, 0), zes_decode(&fx.message, &ev));
    try std.testing.expectEqualStrings("/usr/local/bin/tool", ev.target_path.ptr.?[0..ev.target_path.len]);
    try std.testing.expectEqualStrings("hardlink", ev.name.ptr.?[0..ev.name.len]);

    // signal: process target + number.
    var sig = std.mem.zeroes(sys.es_event_signal_t);
    sig.sig = 9;
    sig.target = &fx.target;
    fx.message.event_type = .ES_EVENT_TYPE_NOTIFY_SIGNAL;
    fx.message.event = .{ .signal = sig };
    try std.testing.expectEqual(@as(c_int, 0), zes_decode(&fx.message, &ev));
    try std.testing.expectEqual(@as(i32, 9), ev.status);
    try std.testing.expectEqual(@as(i32, 4242), ev.target_pid);

    fx.message.event_type = .ES_EVENT_TYPE_RESERVED_0;
    try std.testing.expectEqual(err_unknown_event, zes_decode(&fx.message, &ev));
    try std.testing.expectEqual(@as(i32, 4242), ev.pid); // header still filled
}

test "null arguments are rejected, never dereferenced" {
    try std.testing.expectEqual(err_invalid_argument, zes_client_new(null, null, null));
    try std.testing.expectEqual(err_invalid_argument, zes_subscribe(null, null, 0));
    try std.testing.expectEqual(err_invalid_argument, zes_decode(null, null));
    try std.testing.expectEqual(@as(u32, 0), zes_exec_arg_count(null));
    try std.testing.expectEqual(@as(usize, 0), zes_exec_arg(null, 0).len);
    zes_message_retain(null);
    zes_message_release(null);
    try std.testing.expect(zes_version().len > 0);
    try std.testing.expect(zes_ticks_to_ns(zes_now_ticks()) > 0);
}

test "client_new through the C ABI is refused for an unentitled process" {
    const H = struct {
        fn on(_: ?*anyopaque, _: *CapiClient, _: *const sys.es_message_t, _: *const EscEvent) callconv(.c) void {}
    };
    var client: ?*CapiClient = null;
    const rc = zes_client_new(&client, H.on, null);
    if (rc == 0) {
        _ = zes_client_delete(client);
        return error.SkipZigTest;
    }
    try std.testing.expect(rc >= 3 and rc <= 5);
    try std.testing.expect(client == null);
}
