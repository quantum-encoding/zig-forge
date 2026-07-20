//! zunexpand - Convert spaces to tabs
//!
//! A Zig implementation of unexpand.
//! Converts blanks (spaces) in input to tabs.
//!
//! Usage: zunexpand [OPTIONS] [FILE]...
//!
//! The blank-run tabification is a faithful port of GNU coreutils
//! `src/unexpand.c` (`unexpand()` + `get_next_tab_column()`), so a maximal run
//! of blanks (spaces AND tabs together) is treated as one unit and re-emitted
//! as optimal tabs+spaces, and `-t`/`--tabs` implies `-a` (convert-all).

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const TabParseError = error{ TabSizeZero, InvalidTabChar };

const TabStops = struct {
    stops: [64]usize = undefined,
    count: usize = 0,
    // Mirrors GNU's `tab_size`: nonzero means "tab stops every tab_size
    // columns" (default 8, or a single explicit `-tN`). Zero means an explicit
    // multi-value list is in `stops`, with NO tab stops past the last one.
    tab_size: usize = 8,

    /// Parse a -t / --tabs argument. Returns an error on a non-numeric or zero
    /// tab size, matching GNU unexpand which errors rather than silently
    /// falling back to width 8.
    fn parse(s: []const u8) TabParseError!TabStops {
        var result = TabStops{};
        result.count = 0;

        if (s.len == 0) return result; // empty spec -> default width 8

        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const val = try parseSize(part);
            if (result.count < result.stops.len) {
                result.stops[result.count] = val;
                result.count += 1;
            }
        }

        // finalize_tab_stops: default 8, single value -> that value, else 0.
        if (result.count == 0) {
            result.tab_size = 8;
        } else if (result.count == 1) {
            result.tab_size = result.stops[0];
        } else {
            result.tab_size = 0;
        }

        return result;
    }

    fn parseSize(part: []const u8) TabParseError!usize {
        const v = std.fmt.parseInt(usize, part, 10) catch return error.InvalidTabChar;
        if (v == 0) return error.TabSizeZero;
        return v;
    }

    /// Port of GNU `get_next_tab_column`. Returns the first tab stop after
    /// `column`. `tab_index` is advanced through the explicit list. `last_tab`
    /// is set when we are past the last explicit stop (column+1 is returned as
    /// a sentinel; the caller stops converting for the rest of the line).
    fn nextTabColumn(self: *const TabStops, column: usize, tab_index: *usize, last_tab: *bool) usize {
        last_tab.* = false;

        if (self.tab_size != 0) {
            return column + (self.tab_size - column % self.tab_size);
        }

        while (tab_index.* < self.count) : (tab_index.* += 1) {
            const tab = self.stops[tab_index.*];
            if (column < tab) return tab;
        }

        last_tab.* = true;
        return column + 1;
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

    // Options. `convert_all` == GNU's convert_entire_line.
    var convert_all = false;
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
        } else if (std.mem.eql(u8, arg, "--first-only")) {
            convert_all = false;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tabs")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zunexpand: option requires an argument -- 't'\n", .{});
                std.process.exit(1);
            }
            tabs = parseTabsOrExit(args[i]);
            // -t/--tabs implies convert-all (GNU unexpand behavior).
            convert_all = true;
        } else if (std.mem.startsWith(u8, arg, "--tabs=")) {
            tabs = parseTabsOrExit(arg[7..]);
            convert_all = true;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options or -t<N>
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'a' => {
                        convert_all = true;
                    },
                    't' => {
                        // Rest of arg is the tab spec
                        if (j + 1 < arg.len) {
                            tabs = parseTabsOrExit(arg[j + 1 ..]);
                            convert_all = true;
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zunexpand: option requires an argument -- 't'\n", .{});
                                std.process.exit(1);
                            }
                            tabs = parseTabsOrExit(args[i]);
                            convert_all = true;
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
            processStdin(allocator, &tabs, convert_all) catch {
                errors += 1;
            };
        } else {
            // processFile prints its own diagnostic with the real errno.
            processFile(allocator, file, &tabs, convert_all) catch {
                errors += 1;
            };
        }
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

/// Parse a tab spec, or print the GNU-style diagnostic and exit(1).
fn parseTabsOrExit(spec: []const u8) TabStops {
    return TabStops.parse(spec) catch |err| {
        switch (err) {
            error.TabSizeZero => writeStderr("zunexpand: tab size cannot be 0\n", .{}),
            error.InvalidTabChar => writeStderr(
                "zunexpand: tab size contains invalid character(s): '{s}'\n",
                .{spec},
            ),
        }
        std.process.exit(1);
    };
}

fn processStdin(allocator: std.mem.Allocator, tabs: *const TabStops, convert_all: bool) !void {
    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const n = c_read(0, &buf, buf.len);
        if (n < 0) {
            writeStderr("zunexpand: -: {s}\n", .{std.mem.span(strerror(std.c._errno().*))});
            return error.ReadFailed;
        }
        if (n == 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                try processLine(allocator, line_buf.items, tabs, convert_all);
                writeStdoutRaw("\n");
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    if (line_buf.items.len > 0) {
        try processLine(allocator, line_buf.items, tabs, convert_all);
    }
}

fn processFile(allocator: std.mem.Allocator, path: []const u8, tabs: *const TabStops, convert_all: bool) !void {
    var path_z: [4097]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const O_RDONLY: c_int = 0;
    const fd = open(@ptrCast(&path_z), O_RDONLY, 0);
    if (fd < 0) {
        writeStderr("zunexpand: {s}: {s}\n", .{ path, std.mem.span(strerror(std.c._errno().*)) });
        return error.OpenFailed;
    }
    defer _ = close(fd);

    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const n = c_read(fd, &buf, buf.len);
        if (n < 0) {
            // A directory read yields EISDIR here -> "Is a directory".
            writeStderr("zunexpand: {s}: {s}\n", .{ path, std.mem.span(strerror(std.c._errno().*)) });
            return error.ReadFailed;
        }
        if (n == 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                try processLine(allocator, line_buf.items, tabs, convert_all);
                writeStdoutRaw("\n");
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    if (line_buf.items.len > 0) {
        try processLine(allocator, line_buf.items, tabs, convert_all);
    }
}

/// Faithful port of GNU coreutils `unexpand()` for a single line (the caller
/// splits input on '\n' and re-emits the newline, matching GNU's per-line
/// state reset). `convert_all` is GNU's `convert_entire_line`.
fn processLine(allocator: std.mem.Allocator, line: []const u8, tabs: *const TabStops, convert_all: bool) !void {
    if (line.len == 0) return;

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // Pending blank bytes; `pending.items.len` is GNU's `pending` count. Ensure
    // at least one slot so `pending_blank[0] = '\t'` is always writable even
    // when the count is momentarily zero (mirrors GNU's preallocated buffer).
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(allocator);
    try pending.ensureTotalCapacity(allocator, 1);

    var convert = true;
    var column: usize = 0;
    var next_tab_column: usize = 0;
    var tab_index: usize = 0;
    var one_blank_before_tab_stop = false;
    var prev_blank = true; // initial blanks are treated as preceded by a blank

    for (line) |ch| {
        var emit_char = true; // GNU's g.len: cleared when the char is absorbed into a tab

        if (convert) {
            const blank = ch == ' ' or ch == '\t';

            if (blank) {
                var last_tab = false;
                next_tab_column = tabs.nextTabColumn(column, &tab_index, &last_tab);

                if (last_tab) convert = false;

                if (convert) {
                    if (ch == '\t') {
                        column = next_tab_column;
                        if (pending.items.len > 0) pending.items[0] = '\t';
                    } else {
                        column += 1;
                        if (!(prev_blank and column >= next_tab_column)) {
                            // Keep accumulating; not yet known if it becomes a tab.
                            if (column == next_tab_column) one_blank_before_tab_stop = true;
                            try pending.append(allocator, ch);
                            prev_blank = true;
                            continue;
                        }
                        // Replace the pending blanks by a tab.
                        emit_char = false;
                        try output.append(allocator, '\t');
                        pending.items.ptr[0] = '\t';
                    }
                    // Discard pending blanks, unless it was a single blank just
                    // before the previous tab stop.
                    pending.items.len = if (one_blank_before_tab_stop) 1 else 0;
                }
            } else if (ch == 0x08) { // backspace
                if (column > 0) column -= 1;
                next_tab_column = column;
                if (tab_index > 0) tab_index -= 1;
            } else {
                column += 1;
            }

            if (pending.items.len > 0) {
                if (pending.items.len > 1 and one_blank_before_tab_stop) pending.items[0] = '\t';
                try output.appendSlice(allocator, pending.items);
                pending.items.len = 0;
                one_blank_before_tab_stop = false;
            }

            prev_blank = blank;
            convert = convert and (convert_all or blank);
        }

        if (emit_char) try output.append(allocator, ch);
    }

    // Flush any blanks still pending at end of line.
    if (pending.items.len > 0) {
        if (pending.items.len > 1 and one_blank_before_tab_stop) pending.items[0] = '\t';
        try output.appendSlice(allocator, pending.items);
    }

    writeStdoutRaw(output.items);
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
        \\                   (enables -a)
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
