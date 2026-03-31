const std = @import("std");
const posix = std.posix;
const libc = std.c;

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| {
            self.buf[self.pos] = c;
            self.pos += 1;
            if (self.pos == self.buf.len) self.flush();
        }
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn dirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // Remove trailing slashes
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }

    // Find last slash
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |idx| {
        if (idx == 0) return "/";
        // Remove trailing slashes from result
        var result = p[0..idx];
        while (result.len > 1 and result[result.len - 1] == '/') {
            result = result[0 .. result.len - 1];
        }
        return result;
    }

    return ".";
}

pub fn main(init: std.process.Init) !void {
    var out = OutputBuffer{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var zero_terminated = false;
    var had_paths = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero")) {
            zero_terminated = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zdirname [OPTION] NAME...
                \\Output each NAME with its last non-slash component removed.
                \\
                \\  -z, --zero   end each output line with NUL, not newline
                \\      --help   display this help and exit
                \\
            ;
            out.write(help);
            out.flush();
            return;
        } else {
            had_paths = true;
            const dir = dirname(arg);
            out.write(dir);
            out.writeByte(if (zero_terminated) 0 else '\n');
        }
    }

    if (!had_paths) {
        const msg = "zdirname: missing operand\n";
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    }

    out.flush();
}
