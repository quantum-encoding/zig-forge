//! Typed view of `es_message_t.event`.
//!
//! `Event` has one member per `es_events_t` member, holding a pointer into the
//! message (inline members and pointer members alike come out as
//! `*const es_event_x_t`). `Event.fromMessage` dispatches on `event_type`
//! through a table built at compile time from the enum, so every
//! `ES_EVENT_TYPE_{AUTH,NOTIFY}_X` maps to member `x` and anything the SDK
//! does not name comes out as `.unknown`.

const std = @import("std");
const sys = @import("sys.zig");
const versioned = @import("versioned.zig");
const message = @import("message.zig");

pub const EventType = sys.es_event_type_t;

/// One member per `es_events_t` member, each a pointer into the message.
/// Written out in full because the member list is what the coverage tests
/// below check against the SDK union and enum.
pub const Event = union(enum) {
    access: *const sys.es_event_access_t,
    chdir: *const sys.es_event_chdir_t,
    chroot: *const sys.es_event_chroot_t,
    clone: *const sys.es_event_clone_t,
    close: *const sys.es_event_close_t,
    copyfile: *const sys.es_event_copyfile_t,
    create: *const sys.es_event_create_t,
    cs_invalidated: *const sys.es_event_cs_invalidated_t,
    deleteextattr: *const sys.es_event_deleteextattr_t,
    dup: *const sys.es_event_dup_t,
    exchangedata: *const sys.es_event_exchangedata_t,
    exec: *const sys.es_event_exec_t,
    exit: *const sys.es_event_exit_t,
    file_provider_materialize: *const sys.es_event_file_provider_materialize_t,
    file_provider_update: *const sys.es_event_file_provider_update_t,
    fcntl: *const sys.es_event_fcntl_t,
    fork: *const sys.es_event_fork_t,
    fsgetpath: *const sys.es_event_fsgetpath_t,
    get_task: *const sys.es_event_get_task_t,
    get_task_read: *const sys.es_event_get_task_read_t,
    get_task_inspect: *const sys.es_event_get_task_inspect_t,
    get_task_name: *const sys.es_event_get_task_name_t,
    getattrlist: *const sys.es_event_getattrlist_t,
    getextattr: *const sys.es_event_getextattr_t,
    iokit_open: *const sys.es_event_iokit_open_t,
    kextload: *const sys.es_event_kextload_t,
    kextunload: *const sys.es_event_kextunload_t,
    link: *const sys.es_event_link_t,
    listextattr: *const sys.es_event_listextattr_t,
    lookup: *const sys.es_event_lookup_t,
    mmap: *const sys.es_event_mmap_t,
    mount: *const sys.es_event_mount_t,
    mprotect: *const sys.es_event_mprotect_t,
    open: *const sys.es_event_open_t,
    proc_check: *const sys.es_event_proc_check_t,
    proc_suspend_resume: *const sys.es_event_proc_suspend_resume_t,
    pty_close: *const sys.es_event_pty_close_t,
    pty_grant: *const sys.es_event_pty_grant_t,
    readdir: *const sys.es_event_readdir_t,
    readlink: *const sys.es_event_readlink_t,
    remote_thread_create: *const sys.es_event_remote_thread_create_t,
    remount: *const sys.es_event_remount_t,
    rename: *const sys.es_event_rename_t,
    searchfs: *const sys.es_event_searchfs_t,
    setacl: *const sys.es_event_setacl_t,
    setattrlist: *const sys.es_event_setattrlist_t,
    setextattr: *const sys.es_event_setextattr_t,
    setflags: *const sys.es_event_setflags_t,
    setmode: *const sys.es_event_setmode_t,
    setowner: *const sys.es_event_setowner_t,
    settime: *const sys.es_event_settime_t,
    setuid: *const sys.es_event_setuid_t,
    setgid: *const sys.es_event_setgid_t,
    seteuid: *const sys.es_event_seteuid_t,
    setegid: *const sys.es_event_setegid_t,
    setreuid: *const sys.es_event_setreuid_t,
    setregid: *const sys.es_event_setregid_t,
    signal: *const sys.es_event_signal_t,
    stat: *const sys.es_event_stat_t,
    trace: *const sys.es_event_trace_t,
    truncate: *const sys.es_event_truncate_t,
    uipc_bind: *const sys.es_event_uipc_bind_t,
    uipc_connect: *const sys.es_event_uipc_connect_t,
    unlink: *const sys.es_event_unlink_t,
    unmount: *const sys.es_event_unmount_t,
    utimes: *const sys.es_event_utimes_t,
    write: *const sys.es_event_write_t,
    authentication: *const sys.es_event_authentication_t,
    xp_malware_detected: *const sys.es_event_xp_malware_detected_t,
    xp_malware_remediated: *const sys.es_event_xp_malware_remediated_t,
    lw_session_login: *const sys.es_event_lw_session_login_t,
    lw_session_logout: *const sys.es_event_lw_session_logout_t,
    lw_session_lock: *const sys.es_event_lw_session_lock_t,
    lw_session_unlock: *const sys.es_event_lw_session_unlock_t,
    screensharing_attach: *const sys.es_event_screensharing_attach_t,
    screensharing_detach: *const sys.es_event_screensharing_detach_t,
    openssh_login: *const sys.es_event_openssh_login_t,
    openssh_logout: *const sys.es_event_openssh_logout_t,
    login_login: *const sys.es_event_login_login_t,
    login_logout: *const sys.es_event_login_logout_t,
    btm_launch_item_add: *const sys.es_event_btm_launch_item_add_t,
    btm_launch_item_remove: *const sys.es_event_btm_launch_item_remove_t,
    profile_add: *const sys.es_event_profile_add_t,
    profile_remove: *const sys.es_event_profile_remove_t,
    su: *const sys.es_event_su_t,
    authorization_petition: *const sys.es_event_authorization_petition_t,
    authorization_judgement: *const sys.es_event_authorization_judgement_t,
    sudo: *const sys.es_event_sudo_t,
    od_group_add: *const sys.es_event_od_group_add_t,
    od_group_remove: *const sys.es_event_od_group_remove_t,
    od_group_set: *const sys.es_event_od_group_set_t,
    od_modify_password: *const sys.es_event_od_modify_password_t,
    od_disable_user: *const sys.es_event_od_disable_user_t,
    od_enable_user: *const sys.es_event_od_enable_user_t,
    od_attribute_value_add: *const sys.es_event_od_attribute_value_add_t,
    od_attribute_value_remove: *const sys.es_event_od_attribute_value_remove_t,
    od_attribute_set: *const sys.es_event_od_attribute_set_t,
    od_create_user: *const sys.es_event_od_create_user_t,
    od_create_group: *const sys.es_event_od_create_group_t,
    od_delete_user: *const sys.es_event_od_delete_user_t,
    od_delete_group: *const sys.es_event_od_delete_group_t,
    xpc_connect: *const sys.es_event_xpc_connect_t,
    gatekeeper_user_override: *const sys.es_event_gatekeeper_user_override_t,
    tcc_modify: *const sys.es_event_tcc_modify_t,
    bootstrap_check_in: *const sys.es_event_bootstrap_check_in_t,
    bootstrap_look_up: *const sys.es_event_bootstrap_look_up_t,
    /// An event type this SDK does not name (reserved or newer than the SDK).
    unknown,
};

/// AUTH_X and NOTIFY_X share a payload; this is X.
pub const Kind = std.meta.Tag(Event);

/// Which `es_events_t` member an event type selects, or null for reserved types.
pub fn kindOf(t: EventType) Kind {
    const i = @intFromEnum(t);
    if (i >= kind_table.len) return .unknown;
    return kind_table[i];
}

pub fn isAuth(t: EventType) bool {
    return std.mem.startsWith(u8, @tagName(t), "ES_EVENT_TYPE_AUTH_");
}

pub fn isNotify(t: EventType) bool {
    return std.mem.startsWith(u8, @tagName(t), "ES_EVENT_TYPE_NOTIFY_");
}

/// "AUTH_EXEC", "NOTIFY_OPEN", ... without the `ES_EVENT_TYPE_` prefix, or
/// the raw number for values this SDK does not know.
pub fn shortName(t: EventType) []const u8 {
    const full = @tagName(t);
    const prefix = "ES_EVENT_TYPE_";
    if (std.mem.startsWith(u8, full, prefix)) return full[prefix.len..];
    return full;
}

const kind_table: [@intFromEnum(EventType.ES_EVENT_TYPE_LAST)]Kind = blk: {
    @setEvalBranchQuota(50_000);
    var table: [@intFromEnum(EventType.ES_EVENT_TYPE_LAST)]Kind = undefined;
    for (&table) |*k| k.* = .unknown;
    for (std.meta.fields(EventType)) |f| {
        const member = memberName(f.name) orelse continue;
        if (f.value >= table.len) continue;
        table[f.value] = @field(Kind, member);
    }
    break :blk table;
};

fn memberName(comptime tag: []const u8) ?[]const u8 {
    const auth = "ES_EVENT_TYPE_AUTH_";
    const notify = "ES_EVENT_TYPE_NOTIFY_";
    const rest = if (std.mem.startsWith(u8, tag, auth)) tag[auth.len..] else if (std.mem.startsWith(u8, tag, notify)) tag[notify.len..] else return null;
    var lower: [rest.len]u8 = undefined;
    for (rest, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const l = lower;
    return &l;
}

fn payload(comptime member: []const u8, msg: *const sys.es_message_t) @FieldType(Event, member) {
    const raw = &@field(msg.event, member);
    return switch (@typeInfo(@TypeOf(raw.*))) {
        .pointer => raw.*,
        else => raw,
    };
}

pub fn fromMessage(msg: *const sys.es_message_t) Event {
    switch (kindOf(msg.event_type)) {
        inline else => |k| {
            if (k == .unknown) return .unknown;
            return @unionInit(Event, @tagName(k), payload(@tagName(k), msg));
        },
    }
}

/// Exec events carry packed argv/envp/fd tables that only the ES accessor
/// functions can unpack; this wraps them along with the version-gated fields.
pub const Exec = struct {
    raw: *const sys.es_event_exec_t,
    version: u32,

    /// The image that will run. Code-signing fields describe it post-exec, pre-first-instruction.
    pub fn target(self: Exec) message.Process {
        return .{ .raw = self.raw.target, .version = self.version };
    }

    pub fn argCount(self: Exec) u32 {
        return sys.es_exec_arg_count(self.raw);
    }

    /// argv[i]; `i` must be below `argCount()`.
    pub fn arg(self: Exec, i: u32) []const u8 {
        return sys.es_exec_arg(self.raw, i).slice();
    }

    pub fn args(self: Exec) StringIterator {
        return .{ .exec = self.raw, .count = self.argCount(), .get = sys.es_exec_arg };
    }

    pub fn envCount(self: Exec) u32 {
        return sys.es_exec_env_count(self.raw);
    }

    /// envp[i] as "KEY=value"; `i` must be below `envCount()`.
    pub fn env(self: Exec, i: u32) []const u8 {
        return sys.es_exec_env(self.raw, i).slice();
    }

    pub fn envs(self: Exec) StringIterator {
        return .{ .exec = self.raw, .count = self.envCount(), .get = sys.es_exec_env };
    }

    /// Value of environment variable `name`, or null.
    pub fn findEnv(self: Exec, name: []const u8) ?[]const u8 {
        var it = self.envs();
        while (it.next()) |kv| {
            if (kv.len > name.len and kv[name.len] == '=' and std.mem.eql(u8, kv[0..name.len], name)) {
                return kv[name.len + 1 ..];
            }
        }
        return null;
    }

    /// Number of open file descriptors ES reported (a subset; macOS 11+).
    pub fn fdCount(self: Exec) ?u32 {
        const f = sys.es_exec_fd_count orelse return null;
        return f(self.raw);
    }

    pub fn fd(self: Exec, i: u32) ?*const sys.es_fd_t {
        const f = sys.es_exec_fd orelse return null;
        return f(self.raw, i);
    }

    /// Path handed to execve/posix_spawn before symlink resolution, or the
    /// shebang interpreter for scripts (message version >= 7).
    pub fn dyldExecPath(self: Exec) ?[]const u8 {
        const t = versioned.get(sys.es_event_exec_t, self.raw, self.version, "dyld_exec_path") orelse return null;
        return t.slice();
    }

    /// Script run directly (`./foo.sh`, not `sh foo.sh`) (message version >= 2).
    pub fn script(self: Exec) ?message.File {
        if (!versioned.has(sys.es_event_exec_t, self.version, "script")) return null;
        return .{ .raw = self.raw.v.fields.script orelse return null };
    }

    /// Working directory at exec time (message version >= 3).
    pub fn cwd(self: Exec) ?message.File {
        if (!versioned.has(sys.es_event_exec_t, self.version, "cwd")) return null;
        return .{ .raw = self.raw.v.fields.cwd };
    }

    /// Highest open fd after the exec (message version >= 4).
    pub fn lastFd(self: Exec) ?c_int {
        if (!versioned.has(sys.es_event_exec_t, self.version, "last_fd")) return null;
        return self.raw.v.fields.last_fd;
    }

    /// CPU type/subtype of the image, which under Rosetta differs from the host (message version >= 6).
    pub fn imageCpu(self: Exec) ?struct { cputype: sys.cpu_type_t, cpusubtype: sys.cpu_subtype_t } {
        if (!versioned.has(sys.es_event_exec_t, self.version, "image_cputype")) return null;
        return .{ .cputype = self.raw.v.fields.image_cputype, .cpusubtype = self.raw.v.fields.image_cpusubtype };
    }
};

/// Iterates the packed argv/envp of an exec event without allocating.
pub const StringIterator = struct {
    exec: *const sys.es_event_exec_t,
    count: u32,
    index: u32 = 0,
    get: *const fn (*const sys.es_event_exec_t, u32) callconv(.c) sys.es_string_token_t,

    pub fn next(self: *StringIterator) ?[]const u8 {
        if (self.index >= self.count) return null;
        defer self.index += 1;
        return self.get(self.exec, self.index).slice();
    }

    pub fn reset(self: *StringIterator) void {
        self.index = 0;
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing_support = @import("testing_support.zig");

test "every known event type resolves to a union member; reserved ones to unknown" {
    @setEvalBranchQuota(20_000);
    inline for (std.meta.fields(EventType)) |f| {
        const t: EventType = @enumFromInt(f.value);
        const k = kindOf(t);
        if (comptime (std.mem.startsWith(u8, f.name, "ES_EVENT_TYPE_RESERVED_") or std.mem.eql(u8, f.name, "ES_EVENT_TYPE_LAST"))) {
            try std.testing.expectEqual(Kind.unknown, k);
        } else {
            try std.testing.expect(k != .unknown);
            try std.testing.expectEqualStrings(comptime memberName(f.name).?, @tagName(k));
        }
    }
    try std.testing.expectEqual(Kind.unknown, kindOf(@enumFromInt(9999)));
}

test "Event mirrors es_events_t member for member" {
    const union_members = std.meta.fields(sys.es_events_t);
    try std.testing.expectEqual(union_members.len + 1, std.meta.fields(Event).len);
    inline for (union_members) |m| {
        try std.testing.expect(@hasField(Event, m.name));
        const Payload = switch (@typeInfo(m.type)) {
            .pointer => |p| p.child,
            else => m.type,
        };
        try std.testing.expect(@FieldType(Event, m.name) == *const Payload);
    }
}

test "auth and notify share a payload member" {
    try std.testing.expectEqual(Kind.exec, kindOf(.ES_EVENT_TYPE_AUTH_EXEC));
    try std.testing.expectEqual(Kind.exec, kindOf(.ES_EVENT_TYPE_NOTIFY_EXEC));
    try std.testing.expectEqual(Kind.open, kindOf(.ES_EVENT_TYPE_AUTH_OPEN));
    try std.testing.expectEqual(Kind.tcc_modify, kindOf(.ES_EVENT_TYPE_NOTIFY_TCC_MODIFY));
    try std.testing.expectEqual(Kind.bootstrap_look_up, kindOf(.ES_EVENT_TYPE_AUTH_BOOTSTRAP_LOOK_UP));
    try std.testing.expect(isAuth(.ES_EVENT_TYPE_AUTH_EXEC) and !isNotify(.ES_EVENT_TYPE_AUTH_EXEC));
    try std.testing.expect(isNotify(.ES_EVENT_TYPE_NOTIFY_FORK));
    try std.testing.expectEqualStrings("NOTIFY_FORK", shortName(.ES_EVENT_TYPE_NOTIFY_FORK));
}

test "fromMessage points into the message for inline and pointer members" {
    var fx: testing_support.Fixture = undefined;
    fx.init();
    switch (fromMessage(&fx.message)) {
        .exec => |e| try std.testing.expectEqual(@intFromPtr(&fx.message.event.exec), @intFromPtr(e)),
        else => return error.TestUnexpectedResult,
    }

    var tcc = std.mem.zeroes(sys.es_event_tcc_modify_t);
    tcc.service = testing_support.Fixture.token("kTCCServiceCamera");
    fx.message.event_type = .ES_EVENT_TYPE_NOTIFY_TCC_MODIFY;
    fx.message.event = .{ .tcc_modify = &tcc };
    switch (fromMessage(&fx.message)) {
        .tcc_modify => |t| try std.testing.expectEqualStrings("kTCCServiceCamera", t.service.slice()),
        else => return error.TestUnexpectedResult,
    }

    fx.message.event_type = .ES_EVENT_TYPE_RESERVED_3;
    try std.testing.expect(fromMessage(&fx.message) == .unknown);
}

test "exec gated fields follow the message version" {
    var fx: testing_support.Fixture = undefined;
    fx.init();
    const m = message.Message.fromRaw(&fx.message);
    var e = m.exec() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/bin/zsh", e.target().executable().path());
    try std.testing.expect(e.target().isPlatformBinary());
    try std.testing.expectEqualStrings("/Users/tester/project", e.cwd().?.path());
    try std.testing.expectEqual(@as(?c_int, 7), e.lastFd());
    try std.testing.expectEqualStrings("/bin/sh", e.dyldExecPath().?);
    try std.testing.expect(e.script() == null);

    e.version = 6;
    try std.testing.expect(e.dyldExecPath() == null);
    try std.testing.expect(e.imageCpu() != null);
    e.version = 2;
    try std.testing.expect(e.cwd() == null);
    try std.testing.expect(e.lastFd() == null);
    e.version = 1;
    try std.testing.expect(e.script() == null);
}

test "findEnv over a synthetic iterator" {
    const S = struct {
        var strings = [_][]const u8{ "PATH=/usr/bin", "HOME=/Users/x", "CLAUDECODE=1", "X=" };
        fn get(_: *const sys.es_event_exec_t, i: u32) callconv(.c) sys.es_string_token_t {
            return testing_support.Fixture.token(strings[i]);
        }
    };
    var fx: testing_support.Fixture = undefined;
    fx.init();
    var it = StringIterator{ .exec = &fx.message.event.exec, .count = 4, .get = S.get };
    try std.testing.expectEqualStrings("PATH=/usr/bin", it.next().?);
    try std.testing.expectEqualStrings("HOME=/Users/x", it.next().?);
    _ = it.next();
    _ = it.next();
    try std.testing.expect(it.next() == null);

    // Exercise findEnv's matching rules through the same table.
    const found = blk: {
        var it2 = StringIterator{ .exec = &fx.message.event.exec, .count = 4, .get = S.get };
        while (it2.next()) |kv| {
            const name = "CLAUDECODE";
            if (kv.len > name.len and kv[name.len] == '=' and std.mem.eql(u8, kv[0..name.len], name)) break :blk kv[name.len + 1 ..];
        }
        break :blk null;
    };
    try std.testing.expectEqualStrings("1", found.?);
}
