//! `audit_token_t`: the kernel's 32-byte process identity (uid/gid/pid/pidversion).
//!
//! EndpointSecurity identifies every process by audit token, and `pid` alone is
//! ambiguous across exec (the `pidversion` field disambiguates). Field indices
//! follow libbsm's `audit_token_to_*`; the test suite links libbsm and checks
//! every accessor against Apple's implementation so the indices cannot drift.

const std = @import("std");

pub const AuditToken = extern struct {
    val: [8]u32,

    pub const zero = AuditToken{ .val = .{0} ** 8 };

    /// Audit user id.
    pub fn auid(self: AuditToken) std.c.uid_t {
        return self.val[0];
    }
    /// Effective user id.
    pub fn euid(self: AuditToken) std.c.uid_t {
        return self.val[1];
    }
    /// Effective group id.
    pub fn egid(self: AuditToken) std.c.gid_t {
        return self.val[2];
    }
    /// Real user id.
    pub fn ruid(self: AuditToken) std.c.uid_t {
        return self.val[3];
    }
    /// Real group id.
    pub fn rgid(self: AuditToken) std.c.gid_t {
        return self.val[4];
    }
    /// Process id.
    pub fn pid(self: AuditToken) std.c.pid_t {
        return @bitCast(self.val[5]);
    }
    /// Audit session id.
    pub fn asid(self: AuditToken) u32 {
        return self.val[6];
    }
    /// Increments on every exec; `(pid, pidversion)` names one program execution.
    pub fn pidversion(self: AuditToken) u32 {
        return self.val[7];
    }

    pub fn eql(a: AuditToken, b: AuditToken) bool {
        return std.mem.eql(u32, &a.val, &b.val);
    }

    /// Same process execution: pid and pidversion both match.
    pub fn sameExecution(a: AuditToken, b: AuditToken) bool {
        return a.val[5] == b.val[5] and a.val[7] == b.val[7];
    }

    /// The calling process's own token, from `task_info(TASK_AUDIT_TOKEN)`.
    /// Needed to mute yourself in an ES client so your own file activity does
    /// not feed back into your own handler.
    pub fn current() error{TaskInfoFailed}!AuditToken {
        var tok: AuditToken = undefined;
        var count: std.c.mach_msg_type_number_t = 8; // TASK_AUDIT_TOKEN_COUNT
        const kr = std.c.task_info(std.c.mach_task_self(), task_audit_token, @ptrCast(&tok), &count);
        if (kr != 0) return error.TaskInfoFailed;
        return tok;
    }

    const task_audit_token: std.c.task_flavor_t = 15; // TASK_AUDIT_TOKEN, <mach/task_info.h>
};

// ───────────────────────────── tests ─────────────────────────────

const bsm = struct {
    extern "c" fn audit_token_to_auid(t: AuditToken) std.c.uid_t;
    extern "c" fn audit_token_to_euid(t: AuditToken) std.c.uid_t;
    extern "c" fn audit_token_to_egid(t: AuditToken) std.c.gid_t;
    extern "c" fn audit_token_to_ruid(t: AuditToken) std.c.uid_t;
    extern "c" fn audit_token_to_rgid(t: AuditToken) std.c.gid_t;
    extern "c" fn audit_token_to_pid(t: AuditToken) std.c.pid_t;
    extern "c" fn audit_token_to_asid(t: AuditToken) u32;
    extern "c" fn audit_token_to_pidversion(t: AuditToken) u32;
};

test "anchor: field indices agree with libbsm on this process's token" {
    const t = try AuditToken.current();
    try std.testing.expectEqual(bsm.audit_token_to_auid(t), t.auid());
    try std.testing.expectEqual(bsm.audit_token_to_euid(t), t.euid());
    try std.testing.expectEqual(bsm.audit_token_to_egid(t), t.egid());
    try std.testing.expectEqual(bsm.audit_token_to_ruid(t), t.ruid());
    try std.testing.expectEqual(bsm.audit_token_to_rgid(t), t.rgid());
    try std.testing.expectEqual(bsm.audit_token_to_pid(t), t.pid());
    try std.testing.expectEqual(bsm.audit_token_to_asid(t), t.asid());
    try std.testing.expectEqual(bsm.audit_token_to_pidversion(t), t.pidversion());
}

test "anchor: current token names this process" {
    const t = try AuditToken.current();
    try std.testing.expectEqual(std.c.getpid(), t.pid());
    try std.testing.expectEqual(std.c.geteuid(), t.euid());
    try std.testing.expectEqual(std.c.getuid(), t.ruid());
    try std.testing.expect(t.pidversion() != 0);
}

test "equality helpers" {
    var a = AuditToken.zero;
    var b = AuditToken.zero;
    a.val[5] = 7;
    a.val[7] = 3;
    b.val[5] = 7;
    b.val[7] = 3;
    try std.testing.expect(a.eql(b));
    b.val[1] = 501;
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.sameExecution(b));
    b.val[7] = 4;
    try std.testing.expect(!a.sameExecution(b));
}
