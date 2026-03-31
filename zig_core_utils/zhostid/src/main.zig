const std = @import("std");
const libc = std.c;
const posix = std.posix;

extern "c" fn gethostid() c_long;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help = "Usage: zhostid\nPrint the numeric identifier for the current host.\n";
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        }
    }

    const hostid: u32 = @truncate(@as(u64, @bitCast(@as(i64, gethostid()))));
    outputHostid(hostid);
}

fn outputHostid(hostid: u32) void {
    var buf: [9]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    var val = hostid;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buf[7 - i] = hex_chars[@as(usize, @intCast(val & 0xf))];
        val >>= 4;
    }
    buf[8] = '\n';
    _ = libc.write(libc.STDOUT_FILENO, &buf, buf.len);
}
