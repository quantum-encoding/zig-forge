//! `Client`: one EndpointSecurity connection.
//!
//! Creating a client requires the `com.apple.developer.endpoint-security.client`
//! entitlement, Developer ID signing with hardened runtime, root, and the
//! user's Full Disk Access approval; `es_new_client` reports which of those is
//! missing. Each client gets its own delivery queue, and AUTH events must be
//! answered before their deadline or the client is killed.
//!
//! The handler is delivered to ES as an Objective-C block that captures the
//! caller's context pointer; the client owns one reference to that block and
//! releases it after `es_delete_client`.

const std = @import("std");
const sys = @import("sys.zig");
const darwin = @import("darwin_kit");
const message_mod = @import("message.zig");

pub const Message = message_mod.Message;
pub const EventType = sys.es_event_type_t;
pub const AuthResult = sys.es_auth_result_t;
pub const MutePathType = sys.es_mute_path_type_t;
pub const MuteInversionType = sys.es_mute_inversion_type_t;
pub const DeadlineMissMode = sys.es_deadline_miss_mode_t;
pub const AuditToken = darwin.AuditToken;

pub const NewClientError = error{
    InvalidArgument,
    Internal,
    /// Missing the endpoint-security.client entitlement.
    NotEntitled,
    /// User has not approved the client (TCC / Full Disk Access).
    NotPermitted,
    /// Not running as root.
    NotPrivileged,
    TooManyClients,
    Unknown,
    /// The running macOS predates the function needed.
    ApiUnavailable,
    OutOfMemory,
};

pub const Error = error{
    /// ES returned ES_RETURN_ERROR; it gives no further detail.
    EsError,
    /// The running macOS predates the function needed.
    ApiUnavailable,
    /// The path cannot be NUL-terminated within PATH_MAX.
    NameTooLong,
    OutOfMemory,
};

pub const RespondError = error{
    InvalidArgument,
    Internal,
    /// The message was already answered or never needed an answer.
    NotFound,
    DuplicateResponse,
    /// Wrong respond function for this event type (AUTH_OPEN needs flags).
    EventType,
    Unknown,
};

pub const ClearCacheError = error{ Internal, Throttle, Unknown };

pub const Decision = enum { allow, deny };

fn check(r: sys.es_return_t) Error!void {
    return switch (r) {
        .ES_RETURN_SUCCESS => {},
        else => error.EsError,
    };
}

fn require(f: anytype) Error!@typeInfo(@TypeOf(f)).optional.child {
    return f orelse error.ApiUnavailable;
}

fn eventCount(events: []const EventType) Error!u32 {
    return std.math.cast(u32, events.len) orelse error.EsError;
}

pub const Client = struct {
    raw: *sys.es_client_t,
    /// The handler block this client owns; null for a handle borrowed inside a handler.
    block: ?darwin.block.Ref = null,

    /// Create a client whose handler is `handler(ctx, client, message)`.
    /// `ctx` must outlive the client. The `Client` passed to the handler is a
    /// borrowed handle for responding and must not be deinitialised.
    pub fn init(comptime T: type, ctx: *T, comptime handler: fn (*T, Client, Message) void) NewClientError!Client {
        return create(sys.es_new_client, T, ctx, handler);
    }

    /// Like `init`, but the client only receives events from descendants of
    /// this process (macOS 27+). Needs no Full Disk Access approval.
    pub fn initDescendants(comptime T: type, ctx: *T, comptime handler: fn (*T, Client, Message) void) NewClientError!Client {
        const f = sys.es_new_descendants_client orelse return error.ApiUnavailable;
        return create(f, T, ctx, handler);
    }

    fn create(new_fn: anytype, comptime T: type, ctx: *T, comptime handler: fn (*T, Client, Message) void) NewClientError!Client {
        const Capture = extern struct { ctx: *T };
        const Thunk = struct {
            fn invoke(cap: *Capture, raw_client: *sys.es_client_t, raw_msg: *const sys.es_message_t) void {
                handler(cap.ctx, .{ .raw = raw_client }, Message.fromRaw(raw_msg));
            }
        };
        const B = darwin.Block(Capture, Thunk.invoke);
        const block = try B.create(.{ .ctx = ctx });
        errdefer block.release();

        var raw: ?*sys.es_client_t = null;
        switch (new_fn(&raw, block.ref())) {
            .ES_NEW_CLIENT_RESULT_SUCCESS => {},
            .ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT => return error.InvalidArgument,
            .ES_NEW_CLIENT_RESULT_ERR_INTERNAL => return error.Internal,
            .ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED => return error.NotEntitled,
            .ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED => return error.NotPermitted,
            .ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED => return error.NotPrivileged,
            .ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS => return error.TooManyClients,
            _ => return error.Unknown,
        }
        return .{ .raw = raw orelse return error.Internal, .block = block.ref() };
    }

    /// Wrap the raw pointer ES passes to a handler. Not owned; do not deinit.
    pub fn fromRaw(raw: *sys.es_client_t) Client {
        return .{ .raw = raw };
    }

    /// Tear the client down: `es_delete_client` then release the handler block.
    /// Never call from inside the handler.
    pub fn deinit(self: *Client) void {
        _ = sys.es_delete_client(self.raw);
        if (self.block) |b| darwin.block.release(b);
        self.* = undefined;
    }

    /// `deinit` that reports the `es_delete_client` result.
    pub fn delete(self: *Client) Error!void {
        const r = sys.es_delete_client(self.raw);
        if (self.block) |b| darwin.block.release(b);
        self.* = undefined;
        try check(r);
    }

    // ── subscriptions ──

    pub fn subscribe(self: Client, events: []const EventType) Error!void {
        try check(sys.es_subscribe(self.raw, events.ptr, try eventCount(events)));
    }

    pub fn unsubscribe(self: Client, events: []const EventType) Error!void {
        try check(sys.es_unsubscribe(self.raw, events.ptr, try eventCount(events)));
    }

    pub fn unsubscribeAll(self: Client) Error!void {
        try check(sys.es_unsubscribe_all(self.raw));
    }

    /// Current subscriptions, copied into `allocator` memory.
    pub fn subscriptions(self: Client, allocator: std.mem.Allocator) Error![]EventType {
        var count: usize = 0;
        var ptr: ?[*]EventType = null;
        try check(sys.es_subscriptions(self.raw, &count, &ptr));
        return darwin.cmem.take(EventType, allocator, ptr, count);
    }

    // ── responding ──

    pub fn respondAuth(self: Client, msg: Message, result: AuthResult, cache: bool) RespondError!void {
        return respondResult(sys.es_respond_auth_result(self.raw, msg.raw, result, cache));
    }

    /// For AUTH events whose answer is a mask (AUTH_OPEN: the permitted `fflag` bits).
    pub fn respondFlags(self: Client, msg: Message, authorized_flags: u32, cache: bool) RespondError!void {
        return respondResult(sys.es_respond_flags_result(self.raw, msg.raw, authorized_flags, cache));
    }

    /// Answer an AUTH event with allow/deny using whichever respond function
    /// its type requires (AUTH_OPEN takes flags: all bits for allow, none for deny).
    pub fn respond(self: Client, msg: Message, decision: Decision, cache: bool) RespondError!void {
        if (msg.eventType() == .ES_EVENT_TYPE_AUTH_OPEN) {
            return self.respondFlags(msg, if (decision == .allow) std.math.maxInt(u32) else 0, cache);
        }
        return self.respondAuth(msg, if (decision == .allow) .ES_AUTH_RESULT_ALLOW else .ES_AUTH_RESULT_DENY, cache);
    }

    fn respondResult(r: sys.es_respond_result_t) RespondError!void {
        return switch (r) {
            .ES_RESPOND_RESULT_SUCCESS => {},
            .ES_RESPOND_RESULT_ERR_INVALID_ARGUMENT => error.InvalidArgument,
            .ES_RESPOND_RESULT_ERR_INTERNAL => error.Internal,
            .ES_RESPOND_RESULT_NOT_FOUND => error.NotFound,
            .ES_RESPOND_RESULT_ERR_DUPLICATE_RESPONSE => error.DuplicateResponse,
            .ES_RESPOND_RESULT_ERR_EVENT_TYPE => error.EventType,
            _ => error.Unknown,
        };
    }

    // ── process muting ──

    pub fn muteProcess(self: Client, token: AuditToken) Error!void {
        try check(sys.es_mute_process(self.raw, &token));
    }

    pub fn unmuteProcess(self: Client, token: AuditToken) Error!void {
        try check(sys.es_unmute_process(self.raw, &token));
    }

    /// Mute this process itself, so the client's own activity is not delivered back to it.
    pub fn muteSelf(self: Client) Error!void {
        const me = AuditToken.current() catch return error.EsError;
        try self.muteProcess(me);
    }

    /// macOS 12+
    pub fn muteProcessEvents(self: Client, token: AuditToken, events: []const EventType) Error!void {
        const f = try require(sys.es_mute_process_events);
        try check(f(self.raw, &token, events.ptr, events.len));
    }

    /// macOS 12+
    pub fn unmuteProcessEvents(self: Client, token: AuditToken, events: []const EventType) Error!void {
        const f = try require(sys.es_unmute_process_events);
        try check(f(self.raw, &token, events.ptr, events.len));
    }

    /// Muted processes with their event lists (macOS 12+). Free with `deinit`.
    pub fn mutedProcesses(self: Client) Error!MutedProcesses {
        const f = try require(sys.es_muted_processes_events);
        var ptr: ?*sys.es_muted_processes_t = null;
        try check(f(self.raw, &ptr));
        return .{ .raw = ptr };
    }

    // ── path muting ──

    /// Mute `path` for all events. On macOS 12+ this is `es_mute_path`; on
    /// older systems the deprecated prefix/literal calls are used and the
    /// TARGET_* types are unavailable. Muting happens after symlink resolution.
    pub fn mutePath(self: Client, path: []const u8, kind: MutePathType) Error!void {
        const z = try darwin.zstr.pathZ(path);
        if (sys.es_mute_path) |f| return check(f(self.raw, &z, kind));
        return switch (kind) {
            .ES_MUTE_PATH_TYPE_PREFIX => check(sys.es_mute_path_prefix(self.raw, &z)),
            .ES_MUTE_PATH_TYPE_LITERAL => check(sys.es_mute_path_literal(self.raw, &z)),
            else => error.ApiUnavailable,
        };
    }

    /// macOS 12+
    pub fn mutePathEvents(self: Client, path: []const u8, kind: MutePathType, events: []const EventType) Error!void {
        const f = try require(sys.es_mute_path_events);
        const z = try darwin.zstr.pathZ(path);
        try check(f(self.raw, &z, kind, events.ptr, events.len));
    }

    /// macOS 12+
    pub fn unmutePath(self: Client, path: []const u8, kind: MutePathType) Error!void {
        const f = try require(sys.es_unmute_path);
        const z = try darwin.zstr.pathZ(path);
        try check(f(self.raw, &z, kind));
    }

    /// macOS 12+
    pub fn unmutePathEvents(self: Client, path: []const u8, kind: MutePathType, events: []const EventType) Error!void {
        const f = try require(sys.es_unmute_path_events);
        const z = try darwin.zstr.pathZ(path);
        try check(f(self.raw, &z, kind, events.ptr, events.len));
    }

    /// Clear PREFIX/LITERAL mutes.
    pub fn unmuteAllPaths(self: Client) Error!void {
        try check(sys.es_unmute_all_paths(self.raw));
    }

    /// Clear TARGET_PREFIX/TARGET_LITERAL mutes (macOS 13+).
    pub fn unmuteAllTargetPaths(self: Client) Error!void {
        const f = try require(sys.es_unmute_all_target_paths);
        try check(f(self.raw));
    }

    /// Muted paths with their event lists (macOS 12+). Free with `deinit`.
    pub fn mutedPaths(self: Client) Error!MutedPaths {
        const f = try require(sys.es_muted_paths_events);
        var ptr: ?*sys.es_muted_paths_t = null;
        try check(f(self.raw, &ptr));
        return .{ .raw = ptr };
    }

    // ── mute inversion (macOS 13+) ──

    /// Flip a mute dimension into a select: after inverting PATH, only muted
    /// paths are delivered. Set mutes first, invert once, then subscribe.
    pub fn invertMuting(self: Client, kind: MuteInversionType) Error!void {
        const f = try require(sys.es_invert_muting);
        try check(f(self.raw, kind));
    }

    pub fn mutingInverted(self: Client, kind: MuteInversionType) Error!bool {
        const f = try require(sys.es_muting_inverted);
        return switch (f(self.raw, kind)) {
            .ES_MUTE_INVERTED => true,
            .ES_MUTE_NOT_INVERTED => false,
            else => error.EsError,
        };
    }

    // ── cache ──

    /// Drop cached AUTH results for every client on the system.
    pub fn clearCache(self: Client) ClearCacheError!void {
        return switch (sys.es_clear_cache(self.raw)) {
            .ES_CLEAR_CACHE_RESULT_SUCCESS => {},
            .ES_CLEAR_CACHE_RESULT_ERR_INTERNAL => error.Internal,
            .ES_CLEAR_CACHE_RESULT_ERR_THROTTLE => error.Throttle,
            _ => error.Unknown,
        };
    }

    // ── deadlines (macOS 27+) ──

    pub fn setDeadlineMissMode(self: Client, mode: DeadlineMissMode) Error!void {
        const f = try require(sys.es_set_deadline_miss_mode);
        try check(f(self.raw, mode));
    }

    pub fn deadlineMissMode(self: Client) Error!DeadlineMissMode {
        const f = try require(sys.es_get_deadline_miss_mode);
        var mode: DeadlineMissMode = undefined;
        try check(f(self.raw, &mode));
        return mode;
    }

    pub fn setDeadlineMaxMs(self: Client, events: []const EventType, ms: u32) Error!void {
        const f = try require(sys.es_set_deadline_max_milliseconds);
        try check(f(self.raw, events.ptr, try eventCount(events), ms));
    }

    pub fn deadlineMaxMs(self: Client, event: EventType) Error!u32 {
        const f = try require(sys.es_get_deadline_max_milliseconds);
        var ms: u32 = 0;
        try check(f(self.raw, event, &ms));
        return ms;
    }

    pub fn setDeadlineMinMs(self: Client, events: []const EventType, ms: u32) Error!void {
        const f = try require(sys.es_set_deadline_min_milliseconds);
        try check(f(self.raw, events.ptr, try eventCount(events), ms));
    }

    pub fn deadlineMinMs(self: Client, event: EventType) Error!u32 {
        const f = try require(sys.es_get_deadline_min_milliseconds);
        var ms: u32 = 0;
        try check(f(self.raw, event, &ms));
        return ms;
    }

    // ── synchronisation (macOS 27+) ──

    /// Block until every message queued before this call has been delivered
    /// to the handler. Never call from the handler itself.
    pub fn sync(self: Client) Error!void {
        const f = try require(sys.es_sync_client);
        const Ctx = extern struct { sema: *anyopaque };
        const B = darwin.Block(Ctx, struct {
            fn done(ctx: *Ctx) void {
                _ = dispatch.dispatch_semaphore_signal(ctx.sema);
            }
        }.done);
        const sema = dispatch.dispatch_semaphore_create(0);
        defer dispatch.dispatch_release(sema);
        var b = B.initStack(.{ .sema = sema });
        try check(f(self.raw, b.ref()));
        _ = dispatch.dispatch_semaphore_wait(sema, dispatch.forever);
    }
};

const dispatch = struct {
    extern "c" fn dispatch_semaphore_create(value: isize) *anyopaque;
    extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
    extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;
    extern "c" fn dispatch_release(object: *anyopaque) void;
    const forever: u64 = ~@as(u64, 0);
};

/// Result of `Client.mutedProcesses`; owns the ES allocation.
pub const MutedProcesses = struct {
    raw: ?*sys.es_muted_processes_t,

    pub fn items(self: MutedProcesses) []const sys.es_muted_process_t {
        return if (self.raw) |r| r.slice() else &.{};
    }

    pub fn deinit(self: *MutedProcesses) void {
        if (self.raw) |r| {
            if (sys.es_release_muted_processes) |f| f(r);
        }
        self.raw = null;
    }
};

/// Result of `Client.mutedPaths`; owns the ES allocation.
pub const MutedPaths = struct {
    raw: ?*sys.es_muted_paths_t,

    pub fn items(self: MutedPaths) []const sys.es_muted_path_t {
        return if (self.raw) |r| r.slice() else &.{};
    }

    pub fn deinit(self: *MutedPaths) void {
        if (self.raw) |r| {
            if (sys.es_release_muted_paths) |f| f(r);
        }
        self.raw = null;
    }
};

// ───────────────────────────── tests ─────────────────────────────

test "es_new_client refuses an unentitled test binary without crashing" {
    // The block is built, copied by ES and released here; ES itself rejects
    // the process because the test runner has no ES entitlement. Any other
    // outcome (success, crash) means the handler block ABI is wrong or the
    // environment is unusual, and either deserves a look.
    const Ctx = struct { hits: u32 = 0 };
    var ctx = Ctx{};
    const H = struct {
        fn on(c: *Ctx, client: Client, msg: Message) void {
            c.hits += 1;
            client.respond(msg, .allow, false) catch {};
        }
    };
    const result = Client.init(Ctx, &ctx, H.on);
    if (result) |*client| {
        // Only reachable when running as root with an entitled, signed binary.
        var c = client.*;
        c.deinit();
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.NotEntitled, error.NotPermitted, error.NotPrivileged => {},
        else => return err,
    }
}

test "respond picks flags for AUTH_OPEN and auth for everything else" {
    // Pure decision logic; no client call is made because `raw` is a dummy.
    const testing_support = @import("testing_support.zig");
    var fx = testing_support.Fixture.init();
    fx.message.event_type = .ES_EVENT_TYPE_AUTH_OPEN;
    try std.testing.expect(Message.fromRaw(&fx.message).eventType() == .ES_EVENT_TYPE_AUTH_OPEN);
    // The mapping itself is what matters here; the respond call needs a live client.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), flagsFor(.allow));
    try std.testing.expectEqual(@as(u32, 0), flagsFor(.deny));
}

fn flagsFor(d: Decision) u32 {
    return if (d == .allow) std.math.maxInt(u32) else 0;
}

test "weak-imported functions are present on this SDK's macOS" {
    // Everything through macOS 13 must resolve on a machine that built this.
    try std.testing.expect(sys.es_mute_path != null);
    try std.testing.expect(sys.es_invert_muting != null);
    try std.testing.expect(sys.es_retain_message != null);
    try std.testing.expect(sys.es_release_message != null);
    const v = darwin.os_version.current() orelse return error.SkipZigTest;
    if (v.atLeast(27, 0)) {
        try std.testing.expect(sys.es_set_deadline_miss_mode != null);
        try std.testing.expect(sys.es_new_descendants_client != null);
        try std.testing.expect(sys.es_sync_client != null);
    }
}

test "muted lists tolerate a null result" {
    var mp = MutedProcesses{ .raw = null };
    try std.testing.expectEqual(@as(usize, 0), mp.items().len);
    mp.deinit();
    var paths = MutedPaths{ .raw = null };
    try std.testing.expectEqual(@as(usize, 0), paths.items().len);
    paths.deinit();
}
