const std = @import("std");
const posix = std.posix;
const libc = std.c;

const OutputBuffer = struct {
    buf: [16384]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
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

fn reverseLines(allocator: std.mem.Allocator, content: []const u8, out: *OutputBuffer) !void {
    // Find all line endings
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            try lines.append(allocator, content[start .. i + 1]);
            start = i + 1;
        }
    }
    // Handle last line without newline
    if (start < content.len) {
        try lines.append(allocator, content[start..]);
    }

    // Output in reverse order
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        out.write(lines.items[i]);
    }
}

fn readAll(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [65536]u8 = undefined;

    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try content.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    return content.toOwnedSlice(allocator);
}

fn processFile(allocator: std.mem.Allocator, path: []const u8, out: *OutputBuffer) !void {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        _ = libc.write(libc.STDERR_FILENO, "ztac: ", 6);
        _ = libc.write(libc.STDERR_FILENO, path.ptr, path.len);
        _ = libc.write(libc.STDERR_FILENO, ": cannot open\n", 14);
        return;
    }
    defer _ = libc.close(fd);

    const content = try readAll(allocator, fd);
    defer allocator.free(content);

    try reverseLines(allocator, content, out);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var files_count: usize = 0;
    var files: [256][]const u8 = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: ztac [FILE]...
                \\Write each FILE to standard output, last line first.
                \\With no FILE, or when FILE is -, read standard input.
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else {
            if (files_count < files.len) {
                files[files_count] = arg;
                files_count += 1;
            }
        }
    }

    var out = OutputBuffer{};

    if (files_count == 0) {
        const content = try readAll(allocator, posix.STDIN_FILENO);
        defer allocator.free(content);
        try reverseLines(allocator, content, &out);
    } else {
        for (files[0..files_count]) |path| {
            if (std.mem.eql(u8, path, "-")) {
                const content = try readAll(allocator, posix.STDIN_FILENO);
                defer allocator.free(content);
                try reverseLines(allocator, content, &out);
            } else {
                try processFile(allocator, path, &out);
            }
        }
    }

    out.flush();
}
