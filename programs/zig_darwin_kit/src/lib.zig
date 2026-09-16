//! zig_darwin_kit: the pieces Zig lacks when calling Apple's C frameworks.
//!
//! * `block`       Objective-C block ABI, so Zig functions can be passed to APIs that take `^` blocks.
//! * `machtime`    mach_absolute_time ticks ⇄ nanoseconds, deadline arithmetic.
//! * `audit_token` `audit_token_t` field access and the current process's token.
//! * `os_version`  runtime macOS version for availability checks.
//! * `cmem`        ownership of `malloc`ed buffers returned through out-parameters.
//! * `zstr`        NUL-termination of length-prefixed strings for `const char *` parameters.

pub const block = @import("block.zig");
pub const machtime = @import("machtime.zig");
pub const audit_token = @import("audit_token.zig");
pub const os_version = @import("os_version.zig");
pub const cmem = @import("cmem.zig");
pub const zstr = @import("zstr.zig");

pub const Block = block.Block;
pub const AuditToken = audit_token.AuditToken;
pub const Version = os_version.Version;

test {
    @import("std").testing.refAllDecls(@This());
}
