const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const version_text = "zexpand (zig-forge coreutils) 1.0\n";

// --- Tab-stop specification -------------------------------------------------

const TabError = enum {
    none, // valid
    zero, // "tab size cannot be 0"
    invalid, // "tab size contains invalid character(s)"
    not_ascending, // "tab sizes must be ascending"
};

const TabStops = struct {
    stops: [64]usize = undefined,
    count: usize = 0,
    repeat_interval: usize = 8, // Default repeat interval after explicit stops

    // Parse a GNU expand tab specification. Accepts a comma/blank separated
    // list of ascending positive integers, an optional trailing `+N`
    // increment element, or a leading `+N`. Reports GNU-compatible errors
    // (zero / invalid char / non-ascending) rather than silently coercing.
    fn parse(s: []const u8) struct { tabs: TabStops, err: TabError } {
        var result = TabStops{};

        // Leading '+N' — pure repeat interval (no explicit stops).
        if (s.len > 0 and s[0] == '+') {
            const iv = parseNum(s[1..]) orelse return .{ .tabs = result, .err = .invalid };
            if (iv == 0) return .{ .tabs = result, .err = .zero };
            result.repeat_interval = iv;
            return .{ .tabs = result, .err = .none };
        }

        var it = std.mem.tokenizeAny(u8, s, ", \t");
        var saw_increment = false;
        while (it.next()) |part| {
            if (part.len == 0) continue;

            // Trailing '+N' increment element (only meaningful once at least
            // one explicit stop has been seen).
            if (part[0] == '+' and result.count > 0) {
                const iv = parseNum(part[1..]) orelse return .{ .tabs = result, .err = .invalid };
                if (iv == 0) return .{ .tabs = result, .err = .zero };
                result.repeat_interval = iv;
                saw_increment = true;
                continue;
            }

            const val = parseNum(part) orelse return .{ .tabs = result, .err = .invalid };
            if (val == 0) return .{ .tabs = result, .err = .zero };

            // Stops must be strictly ascending (GNU: "tab sizes must be ascending").
            if (result.count > 0 and val <= result.stops[result.count - 1]) {
                return .{ .tabs = result, .err = .not_ascending };
            }
            if (result.count < result.stops.len) {
                result.stops[result.count] = val;
                result.count += 1;
            }
        }

        // A single bare number is a periodic tab width, not a fixed stop.
        if (result.count == 1 and !saw_increment) {
            result.repeat_interval = result.stops[0];
            result.count = 0;
        }

        return .{ .tabs = result, .err = .none };
    }

    // Strict positive-integer parse: digits only, non-empty.
    fn parseNum(s: []const u8) ?usize {
        if (s.len == 0) return null;
        var v: usize = 0;
        for (s) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        return v;
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

// --- Output buffering -------------------------------------------------------

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
        writeAll(libc.STDOUT_FILENO, self.buf[0..self.pos]);
        self.pos = 0;
    }
};

// Loop until every byte is written, retrying on EINTR / short writes.
fn writeAll(fd: anytype, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(posix.E.INTR)) continue;
            return; // real write error — nothing useful we can do here
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

// --- Expansion --------------------------------------------------------------

// Per-run expansion state that must persist across read-chunk boundaries.
const ExpandState = struct {
    col: usize = 0,
    past_initial: bool = false,
};

fn expandChunk(
    chunk: []const u8,
    out: *OutputBuffer,
    tabs: *const TabStops,
    initial_only: bool,
    st: *ExpandState,
) void {
    for (chunk) |c| {
        if (c == '\t') {
            if (initial_only and st.past_initial) {
                out.writeByte('\t');
                st.col = tabs.nextTabStop(st.col);
            } else {
                const next = tabs.nextTabStop(st.col);
                out.writeSpaces(next - st.col);
                st.col = next;
            }
        } else {
            if (c != ' ') st.past_initial = true;
            out.writeByte(c);
            if (c == '\n') {
                st.col = 0;
                st.past_initial = false;
            } else if (c == '\x08') {
                // Backspace moves the cursor back one column (GNU parity).
                if (st.col > 0) st.col -= 1;
            } else {
                st.col += 1;
            }
        }
    }
}

// EINTR-safe read wrapper. Returns bytes read (0 = EOF), or null on real error.
fn readRetry(fd: anytype, buf: []u8) ?usize {
    while (true) {
        const n = libc.read(fd, buf.ptr, buf.len);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(posix.E.INTR)) continue;
            return null;
        }
        return @intCast(n);
    }
}

fn processStdin(out: *OutputBuffer, tabs: *const TabStops, initial_only: bool) bool {
    var buf: [65536]u8 = undefined;
    var st = ExpandState{};
    while (true) {
        const n = readRetry(libc.STDIN_FILENO, &buf) orelse return false;
        if (n == 0) break;
        expandChunk(buf[0..n], out, tabs, initial_only, &st);
    }
    return true;
}

fn processFile(path: []const u8, out: *OutputBuffer, tabs: *const TabStops, initial_only: bool) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        errPrint("zexpand: {s}: File name too long\n", .{path});
        return false;
    };
    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        // Report the actual errno (EACCES, EISDIR, ENOENT, ...) like GNU.
        const msg = strerror(libc._errno().*);
        errPrint("zexpand: {s}: {s}\n", .{ path, msg });
        return false;
    }
    defer _ = libc.close(fd);

    var buf: [65536]u8 = undefined;
    var st = ExpandState{};
    while (true) {
        const n = readRetry(fd, &buf) orelse {
            const msg = strerror(libc._errno().*);
            errPrint("zexpand: {s}: {s}\n", .{ path, msg });
            return false;
        };
        if (n == 0) break;
        expandChunk(buf[0..n], out, tabs, initial_only, &st);
    }
    return true;
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [4352]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    writeAll(libc.STDERR_FILENO, msg);
}

// --- Argument handling ------------------------------------------------------

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    errPrint(fmt, args);
    errPrint("Try 'zexpand --help' for more information.\n", .{});
    std.process.exit(1);
}

fn applyTabs(spec: []const u8, tabs: *TabStops) void {
    const r = TabStops.parse(spec);
    switch (r.err) {
        .none => tabs.* = r.tabs,
        .zero => usageError("zexpand: tab size cannot be 0\n", .{}),
        .invalid => usageError("zexpand: tab size contains invalid character(s): '{s}'\n", .{spec}),
        .not_ascending => usageError("zexpand: tab sizes must be ascending\n", .{}),
    }
}

const help_text =
    \\Usage: zexpand [OPTION]... [FILE]...
    \\Convert tabs to spaces in each FILE, or standard input if none.
    \\
    \\  -i, --initial        do not convert tabs after non blanks
    \\  -t, --tabs=N          have tabs N characters apart, not 8
    \\  -t, --tabs=LIST       use comma separated list of tab positions
    \\      --help            display this help and exit
    \\      --version         output version information and exit
    \\
    \\Examples:
    \\  zexpand file.txt           Expand with 8-space tabs
    \\  zexpand -t 4 file.txt      Expand with 4-space tabs
    \\  zexpand -t 4,8,12 file.txt Tab stops at columns 4, 8, 12
    \\
;

pub fn main(init: std.process.Init) !void {
    var out = OutputBuffer{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var tabs = TabStops{};
    var initial_only = false;

    // Files are collected dynamically so we never silently drop arguments.
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(init.gpa);

    var no_more_opts = false;

    while (args.next()) |arg| {
        if (no_more_opts or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            try files.append(init.gpa, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            // Long option.
            if (std.mem.eql(u8, arg, "--help")) {
                out.write(help_text);
                out.flush();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                out.write(version_text);
                out.flush();
                return;
            } else if (std.mem.eql(u8, arg, "--initial")) {
                initial_only = true;
            } else if (std.mem.eql(u8, arg, "--tabs")) {
                const spec = args.next() orelse
                    usageError("zexpand: option '--tabs' requires an argument\n", .{});
                applyTabs(spec, &tabs);
            } else if (std.mem.startsWith(u8, arg, "--tabs=")) {
                applyTabs(arg[7..], &tabs);
            } else {
                usageError("zexpand: unrecognized option '{s}'\n", .{arg});
            }
            continue;
        }

        // Obsolete numeric form: -N or -N1,N2,... (e.g. `expand -4`).
        if (arg.len >= 2 and arg[1] >= '0' and arg[1] <= '9') {
            applyTabs(arg[1..], &tabs);
            continue;
        }

        // Short-option cluster, e.g. -i, -t4, -t 4, -it4.
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            switch (arg[k]) {
                'i' => initial_only = true,
                't' => {
                    if (k + 1 < arg.len) {
                        applyTabs(arg[k + 1 ..], &tabs);
                    } else {
                        const spec = args.next() orelse
                            usageError("zexpand: option requires an argument -- 't'\n", .{});
                        applyTabs(spec, &tabs);
                    }
                    break; // rest of the cluster consumed as the tab spec
                },
                else => usageError("zexpand: invalid option -- '{c}'\n", .{arg[k]}),
            }
        }
    }

    var ok = true;
    if (files.items.len == 0) {
        if (!processStdin(&out, &tabs, initial_only)) ok = false;
    } else {
        for (files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                if (!processStdin(&out, &tabs, initial_only)) ok = false;
            } else {
                if (!processFile(path, &out, &tabs, initial_only)) ok = false;
            }
        }
    }

    out.flush();
    if (!ok) std.process.exit(1);
}
