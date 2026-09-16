//! A single human-readable diagnostic with an optional source line. Library
//! functions that can fail on user input take a `*Diag` and fill it before
//! returning an error; the CLI prints it.

const std = @import("std");

pub const Diag = struct {
    line: u32 = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, line: u32, comptime fmt: []const u8, args: anytype) void {
        self.line = line;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // Message longer than the buffer: keep the truncated prefix.
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }

    pub fn text(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};
