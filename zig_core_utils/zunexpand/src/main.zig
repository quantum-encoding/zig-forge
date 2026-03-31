//! zunexpand - Convert spaces to tabs
//!
//! A Zig implementation of unexpand.
//! Converts blanks (spaces) in input to tabs.
//!
//! Usage: zunexpand [OPTIONS] [FILE]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const TabStops = struct {
    stops: [64]usize = undefined,
    count: usize = 0,
    repeat_interval: usize = 8,

    fn parse(s: []const u8) TabStops {
        var result = TabStops{};

        if (s.len > 0 and s[0] == '+') {
            result.repeat_interval = std.fmt.parseInt(usize, s[1..], 10) catch 8;
            if (result.repeat_interval == 0) result.repeat_interval = 8;
            return result;
        }

        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            if (part.len == 0) continue;

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

        if (result.count == 1 and std.mem.indexOf(u8, s, ",") == null) {
            result.repeat_interval = result.stops[0];
            result.count = 0;
        }

        return result;
    }

    fn nextTabStop(self: *const TabStops, col: usize) usize {
        for (self.stops[0..self.count]) |stop| {
            if (stop > col) return stop;
        }

        if (self.count > 0) {
            const last = self.stops[self.count - 1];
            if (col >= last) {
                return col + self.repeat_interval - ((col - last) % self.repeat_interval);
            }
        }

        return col + self.repeat_interval - (col % self.repeat_interval);
    }

    fn isTabStop(self: *const TabStops, col: usize) bool {
        for (self.stops[0..self.count]) |stop| {
            if (stop == col) return true;
        }
        if (self.count > 0) {
            const last = self.stops[self.count - 1];
            if (col > last) {
                return ((col - last) % self.repeat_interval) == 0;
            }
        }
        return (col % self.repeat_interval) == 0;
    }
};

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn writeStdoutRaw(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(1, data.ptr + written, data.len - written);
        if (result <= 0) break;
        written += @intCast(result);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Options
    var convert_all = false;
    var first_only = true; // Default: only leading blanks
    var tabs = TabStops{};
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zunexpand {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            convert_all = true;
            first_only = false;
        } else if (std.mem.eql(u8, arg, "--first-only")) {
            first_only = true;
            convert_all = false;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tabs")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zunexpand: option requires an argument -- 't'\n", .{});
                std.process.exit(1);
            }
            tabs = TabStops.parse(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--tabs=")) {
            tabs = TabStops.parse(arg[7..]);
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options or -t<N>
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'a' => {
                        convert_all = true;
                        first_only = false;
                    },
                    't' => {
                        // Rest of arg is the tab spec
                        if (j + 1 < arg.len) {
                            tabs = TabStops.parse(arg[j + 1 ..]);
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zunexpand: option requires an argument -- 't'\n", .{});
                                std.process.exit(1);
                            }
                            tabs = TabStops.parse(args[i]);
                            break;
                        }
                    },
                    else => {
                        writeStderr("zunexpand: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-")) {
            try files.append(allocator, "-");
        } else {
            writeStderr("zunexpand: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Default to stdin
    if (files.items.len == 0) {
        try files.append(allocator, "-");
    }

    var errors: u32 = 0;

    for (files.items) |file| {
        if (std.mem.eql(u8, file, "-")) {
            processStdin(allocator, &tabs, convert_all, first_only) catch {
                errors += 1;
            };
        } else {
            processFile(allocator, file, &tabs, convert_all, first_only) catch {
                writeStderr("zunexpand: {s}: No such file or directory\n", .{file});
                errors += 1;
            };
        }
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

fn processStdin(allocator: std.mem.Allocator, tabs: *const TabStops, convert_all: bool, first_only: bool) !void {
    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const n = c_read(0, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                processLine(allocator, line_buf.items, tabs, convert_all, first_only);
                writeStdoutRaw("\n");
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        processLine(allocator, line_buf.items, tabs, convert_all, first_only);
    }
}

fn processFile(allocator: std.mem.Allocator, path: []const u8, tabs: *const TabStops, convert_all: bool, first_only: bool) !void {
    // Open file using C
    var path_z: [4097]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const O_RDONLY: c_int = 0;
    const fd = open(@ptrCast(&path_z), O_RDONLY, 0);
    if (fd < 0) return error.FileNotFound;
    defer _ = close(fd);

    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const n = c_read(fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                processLine(allocator, line_buf.items, tabs, convert_all, first_only);
                writeStdoutRaw("\n");
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        processLine(allocator, line_buf.items, tabs, convert_all, first_only);
    }
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

fn processLine(allocator: std.mem.Allocator, line: []const u8, tabs: *const TabStops, convert_all: bool, first_only: bool) void {
    if (line.len == 0) return;

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var col: usize = 0;
    var space_count: usize = 0;
    var space_start_col: usize = 0;
    var in_leading = true;

    for (line) |ch| {
        if (ch == ' ') {
            if (space_count == 0) {
                space_start_col = col;
            }
            space_count += 1;
            col += 1;
        } else {
            // Flush accumulated spaces
            if (space_count > 0) {
                const should_convert = if (first_only) in_leading else convert_all or in_leading;
                flushSpaces(allocator, &output, space_start_col, space_count, tabs, should_convert);
                space_count = 0;
            }

            if (ch != ' ' and ch != '\t') {
                in_leading = false;
            }

            output.append(allocator, ch) catch return;

            if (ch == '\t') {
                col = tabs.nextTabStop(col);
            } else if (ch == 0x08) { // backspace
                if (col > 0) col -= 1;
            } else {
                col += 1;
            }
        }
    }

    // Flush trailing spaces
    if (space_count > 0) {
        const should_convert = if (first_only) in_leading else convert_all or in_leading;
        flushSpaces(allocator, &output, space_start_col, space_count, tabs, should_convert);
    }

    writeStdoutRaw(output.items);
}

fn flushSpaces(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), start_col: usize, count: usize, tabs: *const TabStops, convert: bool) void {
    if (!convert or count < 2) {
        // Just output spaces
        var i: usize = 0;
        while (i < count) : (i += 1) {
            output.append(allocator, ' ') catch return;
        }
        return;
    }

    var col = start_col;
    const end_col = start_col + count;

    // Convert spaces to tabs where possible
    while (col < end_col) {
        const next_tab_stop = tabs.nextTabStop(col);

        if (next_tab_stop <= end_col and next_tab_stop > col) {
            // Can fit a tab
            const spaces_to_tab = next_tab_stop - col;
            if (spaces_to_tab > 1 or (tabs.isTabStop(col) and end_col >= next_tab_stop)) {
                output.append(allocator, '\t') catch return;
                col = next_tab_stop;
            } else {
                output.append(allocator, ' ') catch return;
                col += 1;
            }
        } else {
            // Output remaining as spaces
            output.append(allocator, ' ') catch return;
            col += 1;
        }
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: zunexpand [OPTION]... [FILE]...
        \\Convert blanks in each FILE to tabs, writing to standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -a, --all        convert all blanks, instead of just initial blanks
        \\      --first-only convert only leading sequences of blanks (default)
        \\  -t, --tabs=N     have tabs N characters apart instead of 8
        \\      --help       display this help and exit
        \\      --version    output version information and exit
        \\
        \\Examples:
        \\  zunexpand file.txt          Convert leading spaces to tabs
        \\  zunexpand -a file.txt       Convert all spaces to tabs
        \\  zunexpand -t4 file.txt      Use 4-space tabs
        \\  cat file | zunexpand -a     Process from stdin
        \\
    , .{});
}
