//! `Message`, `Process`, `File`, `Thread`: views over one delivered `es_message_t`.
//!
//! A `Message` is a handle, not a copy. Inside the handler it is borrowed and
//! valid until the handler returns; to keep it longer (for example to answer an
//! AUTH event from another thread before its deadline) call `retain()` and
//! later `release()`. Both map to `es_retain_message` / `es_release_message`,
//! which are reference counts on the kernel's buffer (macOS 11+). The macOS
//! 10.15 copy/free API is not supported.

const std = @import("std");
const sys = @import("sys.zig");
const darwin = @import("darwin_kit");
const versioned = @import("versioned.zig");
const event_mod = @import("event.zig");

pub const AuditToken = darwin.AuditToken;
pub const EventType = sys.es_event_type_t;
pub const AuthResult = sys.es_auth_result_t;

pub const Error = error{
    /// The running macOS predates the function needed.
    ApiUnavailable,
};

/// What `es_message_t.action` holds.
pub const Action = union(enum) {
    /// AUTH event: the opaque id that the response must reference.
    auth: sys.es_event_id_t,
    /// NOTIFY event: what the kernel decided.
    notify: Result,
    /// A result type this SDK does not know.
    unknown,

    pub const Result = union(enum) {
        auth: AuthResult,
        flags: u32,
    };
};

pub const Message = struct {
    raw: *const sys.es_message_t,

    /// Borrow the message ES handed to the handler.
    pub fn fromRaw(raw: *const sys.es_message_t) Message {
        return .{ .raw = raw };
    }

    /// Take a reference so the message outlives the handler. Pair with `release`.
    pub fn retain(self: Message) Error!Message {
        const f = sys.es_retain_message orelse return error.ApiUnavailable;
        f(self.raw);
        return self;
    }

    /// Drop a reference taken with `retain`.
    pub fn release(self: Message) void {
        if (sys.es_release_message) |f| f(self.raw);
    }

    pub fn version(self: Message) u32 {
        return self.raw.version;
    }

    pub fn eventType(self: Message) EventType {
        return self.raw.event_type;
    }

    pub fn actionType(self: Message) sys.es_action_type_t {
        return self.raw.action_type;
    }

    /// True for AUTH events, which must be answered before `deadline`.
    pub fn isAuth(self: Message) bool {
        return self.raw.action_type == .ES_ACTION_TYPE_AUTH;
    }

    pub fn action(self: Message) Action {
        switch (self.raw.action_type) {
            .ES_ACTION_TYPE_AUTH => return .{ .auth = self.raw.action.auth },
            .ES_ACTION_TYPE_NOTIFY => {
                const r = self.raw.action.notify;
                return switch (r.result_type) {
                    .ES_RESULT_TYPE_AUTH => .{ .notify = .{ .auth = r.result.auth } },
                    .ES_RESULT_TYPE_FLAGS => .{ .notify = .{ .flags = r.result.flags } },
                    _ => .unknown,
                };
            },
            _ => return .unknown,
        }
    }

    /// The process that performed the action. For exec this is the caller;
    /// the new image is `Exec.target()`.
    pub fn process(self: Message) Process {
        return .{ .raw = self.raw.process, .version = self.raw.version };
    }

    /// Wall-clock time of the event.
    pub fn time(self: Message) sys.timespec {
        return self.raw.time;
    }

    /// Wall-clock time of the event in nanoseconds since the Unix epoch.
    pub fn timeNanos(self: Message) i128 {
        return darwin.machtime.timespecToNanos(self.raw.time);
    }

    /// Event time in `mach_absolute_time` ticks.
    pub fn machTime(self: Message) u64 {
        return self.raw.mach_time;
    }

    /// AUTH deadline in `mach_absolute_time` ticks. Missing it gets the client
    /// killed (or the event failed open/closed, see `es_deadline_miss_mode_t`).
    pub fn deadline(self: Message) u64 {
        return self.raw.deadline;
    }

    /// Nanoseconds left before the deadline, or null once it has passed.
    pub fn deadlineRemainingNanos(self: Message) ?u64 {
        return darwin.machtime.nanosUntil(self.raw.deadline);
    }

    /// Per-client sequence number (message version >= 2). Gaps mean dropped events.
    pub fn seqNum(self: Message) ?u64 {
        return versioned.get(sys.es_message_t, self.raw, self.raw.version, "seq_num");
    }

    /// Per-client global sequence number (message version >= 4).
    pub fn globalSeqNum(self: Message) ?u64 {
        return versioned.get(sys.es_message_t, self.raw, self.raw.version, "global_seq_num");
    }

    /// Thread that performed the action, when known (message version >= 4).
    pub fn thread(self: Message) ?Thread {
        const t = versioned.get(sys.es_message_t, self.raw, self.raw.version, "thread") orelse return null;
        return .{ .raw = t orelse return null };
    }

    /// Typed view of the event payload.
    pub fn event(self: Message) event_mod.Event {
        return event_mod.fromMessage(self.raw);
    }

    /// Exec helper when this is an exec event, else null.
    pub fn exec(self: Message) ?event_mod.Exec {
        return switch (self.event()) {
            .exec => |e| event_mod.Exec{ .raw = e, .version = self.raw.version },
            else => null,
        };
    }
};

pub const Process = struct {
    raw: *const sys.es_process_t,
    version: u32,

    pub fn auditToken(self: Process) AuditToken {
        return self.raw.audit_token;
    }

    pub fn pid(self: Process) sys.pid_t {
        return self.raw.audit_token.pid();
    }

    /// Parent pid at the time of the event. Prefer `parentAuditToken` when present.
    pub fn ppid(self: Process) sys.pid_t {
        return self.raw.ppid;
    }

    /// Parent pid at process creation; unchanged by reparenting.
    pub fn originalPpid(self: Process) sys.pid_t {
        return self.raw.original_ppid;
    }

    pub fn groupId(self: Process) sys.pid_t {
        return self.raw.group_id;
    }

    pub fn sessionId(self: Process) sys.pid_t {
        return self.raw.session_id;
    }

    /// `CS_*` flags from <kern/cs_blobs.h>.
    pub fn codesigningFlags(self: Process) u32 {
        return self.raw.codesigning_flags;
    }

    /// Signed by Apple. For exec decisions check the *target* process, not the
    /// caller: nearly everything is spawned through `xpcproxy`, a platform binary.
    pub fn isPlatformBinary(self: Process) bool {
        return self.raw.is_platform_binary;
    }

    /// Holds the EndpointSecurity entitlement (another ES client).
    pub fn isEsClient(self: Process) bool {
        return self.raw.is_es_client;
    }

    pub fn cdhash(self: Process) *const sys.es_cdhash_t {
        return &self.raw.cdhash;
    }

    pub fn signingId(self: Process) []const u8 {
        return self.raw.signing_id.slice();
    }

    pub fn teamId(self: Process) []const u8 {
        return self.raw.team_id.slice();
    }

    pub fn executable(self: Process) File {
        return .{ .raw = self.raw.executable };
    }

    /// Controlling TTY of the process's session (message version >= 2).
    pub fn tty(self: Process) ?File {
        const t = versioned.get(sys.es_process_t, self.raw, self.version, "tty") orelse return null;
        return .{ .raw = t orelse return null };
    }

    /// Fork time (message version >= 3).
    pub fn startTime(self: Process) ?sys.timeval {
        return versioned.get(sys.es_process_t, self.raw, self.version, "start_time");
    }

    /// The process responsible for this one, or the process itself when there
    /// is none (message version >= 4). This is the root an agent's tree hangs from.
    pub fn responsibleAuditToken(self: Process) ?AuditToken {
        return versioned.get(sys.es_process_t, self.raw, self.version, "responsible_audit_token");
    }

    /// Parent's token (message version >= 4).
    pub fn parentAuditToken(self: Process) ?AuditToken {
        return versioned.get(sys.es_process_t, self.raw, self.version, "parent_audit_token");
    }

    /// Code-signing validation category (message version >= 10).
    pub fn csValidationCategory(self: Process) ?sys.es_cs_validation_category_t {
        return versioned.get(sys.es_process_t, self.raw, self.version, "cs_validation_category");
    }

    /// Full-length CDHash (message version >= 11).
    pub fn cdhashFull(self: Process) ?[]const u8 {
        const t = versioned.get(sys.es_process_t, self.raw, self.version, "cdhash_full") orelse return null;
        return t.slice();
    }
};

pub const File = struct {
    raw: *const sys.es_file_t,

    /// Absolute path; may be truncated (see `pathTruncated`), currently at 16 KiB.
    pub fn path(self: File) []const u8 {
        return self.raw.path.slice();
    }

    pub fn pathTruncated(self: File) bool {
        return self.raw.path_truncated;
    }

    pub fn stat(self: File) *const sys.struct_stat {
        return &self.raw.stat;
    }

    pub fn basename(self: File) []const u8 {
        return std.fs.path.basename(self.path());
    }
};

pub const Thread = struct {
    raw: *const sys.es_thread_t,

    pub fn threadId(self: Thread) u64 {
        return self.raw.thread_id;
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing_support = @import("testing_support.zig");

test "action decoding" {
    var fx = testing_support.Fixture.init();
    fx.message.action_type = .ES_ACTION_TYPE_AUTH;
    const m = Message.fromRaw(&fx.message);
    try std.testing.expect(m.isAuth());
    try std.testing.expect(m.action() == .auth);

    fx.message.action_type = .ES_ACTION_TYPE_NOTIFY;
    fx.message.action.notify = .{ .result_type = .ES_RESULT_TYPE_FLAGS, .result = .{ .flags = 0x3 } };
    try std.testing.expectEqual(@as(u32, 0x3), m.action().notify.flags);
    fx.message.action.notify = .{ .result_type = .ES_RESULT_TYPE_AUTH, .result = .{ .auth = .ES_AUTH_RESULT_DENY } };
    try std.testing.expectEqual(AuthResult.ES_AUTH_RESULT_DENY, m.action().notify.auth);
    fx.message.action_type = @enumFromInt(77);
    try std.testing.expect(m.action() == .unknown);
}

test "version-gated message and process fields" {
    var fx = testing_support.Fixture.init();
    fx.message.version = 1;
    const m = Message.fromRaw(&fx.message);
    try std.testing.expect(m.seqNum() == null);
    try std.testing.expect(m.globalSeqNum() == null);
    try std.testing.expect(m.thread() == null);
    try std.testing.expect(m.process().tty() == null);
    try std.testing.expect(m.process().responsibleAuditToken() == null);

    fx.message.version = 4;
    fx.message.seq_num = 9;
    fx.message.global_seq_num = 10;
    fx.message.thread = &fx.thread;
    try std.testing.expectEqual(@as(?u64, 9), m.seqNum());
    try std.testing.expectEqual(@as(?u64, 10), m.globalSeqNum());
    try std.testing.expectEqual(@as(u64, 0x7777), m.thread().?.threadId());
    try std.testing.expectEqual(@as(sys.pid_t, 1), m.process().responsibleAuditToken().?.pid());
    try std.testing.expectEqual(@as(sys.pid_t, 501), m.process().parentAuditToken().?.pid());
    try std.testing.expect(m.process().csValidationCategory() == null);

    fx.message.version = 10;
    try std.testing.expectEqual(sys.es_cs_validation_category_t.ES_CS_VALIDATION_CATEGORY_DEVELOPER_ID, m.process().csValidationCategory().?);
}

test "process and file accessors" {
    var fx = testing_support.Fixture.init();
    const p = Message.fromRaw(&fx.message).process();
    try std.testing.expectEqual(@as(sys.pid_t, 4242), p.pid());
    try std.testing.expectEqual(@as(sys.pid_t, 501), p.ppid());
    try std.testing.expectEqualStrings("com.example.tool", p.signingId());
    try std.testing.expectEqualStrings("ABCDE12345", p.teamId());
    try std.testing.expectEqualStrings("/usr/local/bin/tool", p.executable().path());
    try std.testing.expectEqualStrings("tool", p.executable().basename());
    try std.testing.expect(!p.executable().pathTruncated());
    try std.testing.expect(!p.isPlatformBinary());
    try std.testing.expectEqual(@as(i64, 1234), p.executable().stat().size);
}

test "deadline arithmetic uses the mach clock" {
    var fx = testing_support.Fixture.init();
    const m = Message.fromRaw(&fx.message);
    fx.message.deadline = darwin.machtime.now() + darwin.machtime.nanosToTicks(std.time.ns_per_s);
    const left = m.deadlineRemainingNanos() orelse return error.TestUnexpectedResult;
    try std.testing.expect(left > std.time.ns_per_s / 2 and left <= std.time.ns_per_s);
    fx.message.deadline = 1;
    try std.testing.expect(m.deadlineRemainingNanos() == null);
}
