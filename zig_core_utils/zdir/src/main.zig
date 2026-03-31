const std = @import("std");
const posix = std.posix;
const libc = std.c;
const Io = std.Io;
const Dir = Io.Dir;

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

const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

fn compareEntries(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn listDir(allocator: std.mem.Allocator, io: anytype, path: []const u8, out: *OutputBuffer, show_all: bool, one_per_line: bool) !void {
    var dir = Dir.openDir(Dir.cwd(), io, path, .{ .iterate = true }) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "zdir: cannot access '{s}': {s}\n", .{ path, @errorName(err) }) catch return;
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        return;
    };
    defer dir.close(io);

    var entries = std.ArrayListUnmanaged(Entry).empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!show_all and entry.name.len > 0 and entry.name[0] == '.') continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try entries.append(allocator, .{
            .name = name_copy,
            .is_dir = entry.kind == .directory,
        });
    }

    std.mem.sort(Entry, entries.items, {}, compareEntries);

    if (one_per_line) {
        for (entries.items) |e| {
            out.write(e.name);
            out.writeByte('\n');
        }
    } else {
        // Column format (like dir command)
        var col: usize = 0;
        const col_width: usize = 20;
        const term_width: usize = 80;

        for (entries.items) |e| {
            if (col + e.name.len >= term_width and col > 0) {
                out.writeByte('\n');
                col = 0;
            }

            out.write(e.name);
            const padding = if (e.name.len < col_width) col_width - e.name.len else 2;
            var p: usize = 0;
            while (p < padding) : (p += 1) out.writeByte(' ');
            col += e.name.len + padding;
        }

        if (col > 0) out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const io = Io.Threaded.global_single_threaded.io();
    var out = OutputBuffer{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var show_all = false;
    var one_per_line = false;
    var paths = std.ArrayListUnmanaged([]const u8).empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg| {
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => show_all = true,
                    '1' => one_per_line = true,
                    else => {},
                }
            }
        } else if (std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zdir [OPTION]... [DIR]...
                \\List directory contents in columns.
                \\
                \\  -a, --all    include entries starting with .
                \\  -1           list one file per line
                \\      --help   display this help and exit
                \\
            ;
            out.write(help);
            out.flush();
            return;
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, ".");
    }

    for (paths.items, 0..) |path, i| {
        if (paths.items.len > 1) {
            if (i > 0) out.writeByte('\n');
            out.write(path);
            out.write(":\n");
        }
        try listDir(allocator, io, path, &out, show_all, one_per_line);
    }

    out.flush();
}
