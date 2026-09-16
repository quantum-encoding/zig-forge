//! In-memory `es_message_t` fixtures for tests that run without the ES
//! entitlement. The layouts are the ones `anchors_test.zig` verifies against
//! clang, so a fixture built here has the byte layout ES would deliver; what it
//! cannot imitate is the opaque tail the `es_exec_arg*` functions read, so
//! tests never call those on a fixture.

const std = @import("std");
const sys = @import("sys.zig");
const darwin = @import("darwin_kit");

pub const Fixture = struct {
    message: sys.es_message_t,
    process: sys.es_process_t,
    target: sys.es_process_t,
    executable: sys.es_file_t,
    target_executable: sys.es_file_t,
    cwd: sys.es_file_t,
    thread: sys.es_thread_t,

    pub const exe_path = "/usr/local/bin/tool";
    pub const target_path = "/bin/zsh";
    pub const cwd_path = "/Users/tester/project";

    pub fn init() Fixture {
        var fx: Fixture = undefined;
        fx.thread = .{ .thread_id = 0x7777 };
        fx.executable = makeFile(exe_path, 1234);
        fx.target_executable = makeFile(target_path, 1_500_000);
        fx.cwd = makeFile(cwd_path, 96);
        fx.process = makeProcess(4242, 501, &fx.executable, "com.example.tool", "ABCDE12345");
        fx.target = makeProcess(4242, 501, &fx.target_executable, "com.apple.zsh", "");
        fx.target.is_platform_binary = true;
        fx.message = std.mem.zeroes(sys.es_message_t);
        fx.message.version = 10;
        fx.message.process = &fx.process;
        fx.message.action_type = .ES_ACTION_TYPE_NOTIFY;
        fx.message.event_type = .ES_EVENT_TYPE_NOTIFY_EXEC;
        fx.message.event = .{ .exec = std.mem.zeroes(sys.es_event_exec_t) };
        fx.message.event.exec.target = &fx.target;
        fx.message.event.exec.v.fields.cwd = &fx.cwd;
        fx.message.event.exec.v.fields.script = null;
        fx.message.event.exec.v.fields.last_fd = 7;
        fx.message.event.exec.dyld_exec_path = token("/bin/sh");
        fx.message.thread = null;
        return fx;
    }

    pub fn token(s: []const u8) sys.es_string_token_t {
        return .{ .length = s.len, .data = s.ptr };
    }

    fn makeFile(path: []const u8, size: i64) sys.es_file_t {
        var f = std.mem.zeroes(sys.es_file_t);
        f.path = token(path);
        f.stat.size = size;
        f.stat.mode = 0o100755;
        return f;
    }

    fn makeProcess(pid: u32, ppid: u32, exe: *sys.es_file_t, signing_id: []const u8, team_id: []const u8) sys.es_process_t {
        var p = std.mem.zeroes(sys.es_process_t);
        p.audit_token.val = .{ 501, 501, 20, 501, 20, pid, 100_000, 3 };
        p.ppid = @intCast(ppid);
        p.original_ppid = @intCast(ppid);
        p.group_id = @intCast(pid);
        p.session_id = @intCast(ppid);
        p.executable = exe;
        p.signing_id = token(signing_id);
        p.team_id = token(team_id);
        p.responsible_audit_token.val = .{ 501, 501, 20, 501, 20, 1, 100_000, 1 };
        p.parent_audit_token.val = .{ 501, 501, 20, 501, 20, ppid, 100_000, 2 };
        p.cs_validation_category = .ES_CS_VALIDATION_CATEGORY_DEVELOPER_ID;
        return p;
    }
};
