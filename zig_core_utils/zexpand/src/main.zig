const std = @import("std");
const posix = std.posix;
const libc = std.c;

const TabStops = struct {
    stops: [64]usize = undefined,
    count: usize = 0,
    repeat_interval: usize = 8, // Default repeat interval after explicit stops

    fn parse(s: []const u8) TabStops {
        var result = TabStops{};

        // Check for incremental format (+N)
        if (s.len > 0 and s[0] == '+') {
            result.repeat_interval = std.fmt.parseInt(usize, s[1..], 10) catch 8;
            if (result.repeat_interval == 0) result.repeat_interval = 8;
            return result;
        }

        // Parse comma-separated list
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            if (part.len == 0) continue;

            // Check for +N format in list
            if (part[0] == '+' and result.count > 0) {
                result.repeat_interval = std.fmt.parseInt(usize, part[1..], 10) catch 8;
                if (result.repeat_interval == 0) result.repeat_interval = 8;
                break;
            }

            if (result.count < result.stops.len) {
                const val = std.fmt.parseInt(usize, part, 10) catch continue;
                if (val > 0) {
                    result.stops[result.count] = val;
                    result.count += 1;
                }
            }
        }

        // If only one number, treat as repeat interval
        if (result.count == 1 and std.mem.indexOf(u8, s, ",") == null) {
            result.repeat_interval = result.stops[0];
            result.count = 0;
        }

        return result;
    }

    fn nextTabStop(self: *const TabStops, col: usize) usize {
        // Check explicit stops
        for (self.stops[0..self.count]) |stop| {
            if (stop > col) return stop;
        }

        // Use repeat interval
        if (self.count > 0) {
            const last = self.stops[self.count - 1];
            if (col >= last) {
                return col + self.repeat_interval - ((col - last) % self.repeat_interval);
            }
        }

        // Simple periodic tabs
        return col + self.repeat_interval - (col % self.repeat_interval);
    }
};

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

    fn writeSpaces(self: *OutputBuffer, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.writeByte(' ');
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn expandLine(line: []const u8, out: *OutputBuffer, tabs: *const TabStops, initial_only: bool) void {
    var col: usize = 0;
    var past_initial = false;

    for (line) |c| {
        if (c == '\t') {
            if (initial_only and past_initial) {
                out.writeByte('\t');
                const next = tabs.nextTabStop(col);
                col = next;
            } else {
                const next = tabs.nextTabStop(col);
                const spaces = next - col;
                out.writeSpaces(spaces);
                col = next;
            }
        } else {
            if (c != ' ') past_initial = true;
            out.writeByte(c);
            if (c == '\n') {
                col = 0;
                past_initial = false;
            } else {
                col += 1;
            }
        }
    }
}

fn processStdin(out: *OutputBuffer, tabs: *const TabStops, initial_only: bool) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n_ret = libc.read(libc.STDIN_FILENO, &buf, buf.len);
        if (n_ret <= 0) break;
        const n: usize = @intCast(n_ret);
        expandLine(buf[0..n], out, tabs, initial_only);
    }
}

fn processFile(path: []const u8, out: *OutputBuffer, tabs: *const TabStops, initial_only: bool) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "zexpand: {s}: No such file or directory\n", .{path}) catch return false;
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        return false;
    }
    defer _ = libc.close(fd);

    var buf: [65536]u8 = undefined;
    while (true) {
        const n_ret = libc.read(fd, &buf, buf.len);
        if (n_ret <= 0) break;
        const n: usize = @intCast(n_ret);
        expandLine(buf[0..n], out, tabs, initial_only);
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    var out = OutputBuffer{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var tabs = TabStops{};
    var initial_only = false;
    var files_count: usize = 0;
    var files: [256][]const u8 = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zexpand [OPTION]... [FILE]...
                \\Convert tabs to spaces in each FILE, or stdin if none.
                \\
                \\  -i, --initial       only convert leading tabs
                \\  -t, --tabs=N        set tab width to N (default 8)
                \\  -t, --tabs=N1,N2,... set tabs at columns N1, N2, ...
                \\      --help          display this help and exit
                \\
                \\Examples:
                \\  zexpand file.txt           Expand with 8-space tabs
                \\  zexpand -t 4 file.txt      Expand with 4-space tabs
                \\  zexpand -t 4,8,12 file.txt Tab stops at columns 4, 8, 12
                \\
            ;
            out.write(help);
            out.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--initial")) {
            initial_only = true;
        } else if (std.mem.startsWith(u8, arg, "-t")) {
            const tab_str = if (arg.len > 2) arg[2..] else args.next() orelse "8";
            tabs = TabStops.parse(tab_str);
        } else if (std.mem.startsWith(u8, arg, "--tabs=")) {
            tabs = TabStops.parse(arg[7..]);
        } else if (arg.len > 0 and arg[0] != '-') {
            if (files_count < files.len) {
                files[files_count] = arg;
                files_count += 1;
            }
        }
    }

    if (files_count == 0) {
        processStdin(&out, &tabs, initial_only);
    } else {
        for (files[0..files_count]) |path| {
            if (std.mem.eql(u8, path, "-")) {
                processStdin(&out, &tabs, initial_only);
            } else {
                _ = processFile(path, &out, &tabs, initial_only);
            }
        }
    }

    out.flush();
}
