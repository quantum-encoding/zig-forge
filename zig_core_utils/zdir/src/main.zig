const std = @import("std");
const posix = std.posix;
const libc = std.c;
const Io = std.Io;
const Dir = Io.Dir;

// GNU dir exit-status contract:
//   0  success
//   1  minor problem (e.g. cannot access a subfile of a listed directory)
//   2  serious problem (e.g. cannot access a command-line operand)
// The highest code seen wins.
var exit_code: u8 = 0;

fn setExit(code: u8) void {
    if (code > exit_code) exit_code = code;
}

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
        writeAll(libc.STDOUT_FILENO, self.buf[0..self.pos]);
        self.pos = 0;
    }
};

// Loop until every byte is written, tolerating short writes and EINTR.
// On a genuine error (e.g. EPIPE) we stop; there is nowhere left to report to.
fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            return; // EPIPE / EIO / etc. — cannot recover, stop.
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Fall back to a truncated fixed message rather than dropping the
        // diagnostic entirely (the pre-fix code silently returned here).
        const trunc = "zdir: error (message too long)\n";
        writeAll(libc.STDERR_FILENO, trunc);
        return;
    };
    writeAll(libc.STDERR_FILENO, msg);
}

// strerror-style text for the errors we surface, matching GNU wording.
fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        error.SystemResources => "Cannot allocate memory",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        else => @errorName(err),
    };
}

// GNU `dir` == `ls -C -b`: names are always emitted with C-style backslash
// escapes for space, backslash and non-graphic bytes (the "escape" quoting
// style), regardless of whether stdout is a terminal. Table verified against
// coreutils 9.10 `gdir -1`:
//   space -> "\ ", backslash -> "\\", TAB -> "\t", 0x01 -> "\001", etc.
//   shell metacharacters (" ! # $ & ' ( ) * ; > | …) are left literal.
fn escapeAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (name) |b| {
        switch (b) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            ' ' => try out.appendSlice(allocator, "\\ "),
            0x07 => try out.appendSlice(allocator, "\\a"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x09 => try out.appendSlice(allocator, "\\t"),
            0x0a => try out.appendSlice(allocator, "\\n"),
            0x0b => try out.appendSlice(allocator, "\\v"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x0d => try out.appendSlice(allocator, "\\r"),
            else => {
                if (b < 0x20 or b == 0x7f) {
                    var oct: [4]u8 = undefined;
                    const s = std.fmt.bufPrint(&oct, "\\{o:0>3}", .{b}) catch unreachable;
                    try out.appendSlice(allocator, s);
                } else {
                    try out.append(allocator, b);
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

// A directory entry, carrying both the raw name (for byte-order sorting, which
// matches GNU under LC_ALL=C) and the display form (backslash-escaped).
const Entry = struct {
    name: []const u8, // raw, owned
    display: []const u8, // escaped, owned
    is_dir: bool,
};

fn compareEntries(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn compareStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn printListing(out: *OutputBuffer, displays: []const []const u8, one_per_line: bool) void {
    if (one_per_line) {
        for (displays) |d| {
            out.write(d);
            out.writeByte('\n');
        }
        return;
    }
    // Horizontal fixed-width column fill (20-char columns, 80-col wrap).
    // NOTE: this is NOT GNU's vertical dynamically-sized layout; it is a
    // deliberately simple approximation. Byte-exact multi-column parity with
    // GNU is out of scope — the anchored tests use -1 (one-per-line) mode.
    var col: usize = 0;
    const col_width: usize = 20;
    const term_width: usize = 80;
    for (displays, 0..) |d, i| {
        const is_last = i + 1 == displays.len;
        if (col + d.len >= term_width and col > 0) {
            out.writeByte('\n');
            col = 0;
        }
        out.write(d);
        col += d.len;
        // Pad to the next column boundary, but never emit trailing spaces at
        // the end of the listing or before a wrap (avoids trailing whitespace).
        const padding = if (d.len < col_width) col_width - d.len else 2;
        const next_wraps = !is_last and (col + padding + displays[i + 1].len >= term_width);
        if (!is_last and !next_wraps) {
            var p: usize = 0;
            while (p < padding) : (p += 1) out.writeByte(' ');
            col += padding;
        }
    }
    if (displays.len > 0) out.writeByte('\n');
}

fn listDir(
    allocator: std.mem.Allocator,
    io: anytype,
    path: []const u8,
    out: *OutputBuffer,
    show_hidden: bool,
    show_dots: bool,
    one_per_line: bool,
) void {
    var dir = Dir.openDir(Dir.cwd(), io, path, .{ .iterate = true }) catch |err| {
        stderrPrint("zdir: cannot open directory '{s}': {s}\n", .{ path, errText(err) });
        setExit(2);
        return;
    };
    defer dir.close(io);

    var entries = std.ArrayListUnmanaged(Entry).empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.display);
        }
        entries.deinit(allocator);
    }

    // GNU `-a` includes the synthesized "." and ".." entries (Zig's iterator
    // never yields them); `-A` (almost-all) shows hidden files but omits them.
    if (show_dots) {
        appendEntry(allocator, &entries, ".", true) catch return;
        appendEntry(allocator, &entries, "..", true) catch return;
    }

    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        stderrPrint("zdir: reading directory '{s}': {s}\n", .{ path, errText(err) });
        setExit(2);
        return;
    }) |entry| {
        if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        appendEntry(allocator, &entries, entry.name, entry.kind == .directory) catch return;
    }

    std.mem.sort(Entry, entries.items, {}, compareEntries);

    var displays = std.ArrayListUnmanaged([]const u8).empty;
    defer displays.deinit(allocator);
    for (entries.items) |e| displays.append(allocator, e.display) catch return;

    printListing(out, displays.items, one_per_line);
}

fn appendEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    name: []const u8,
    is_dir: bool,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const display = try escapeAlloc(allocator, name);
    errdefer allocator.free(display);
    try entries.append(allocator, .{ .name = name_copy, .display = display, .is_dir = is_dir });
}

const help_text =
    \\Usage: zdir [OPTION]... [FILE]...
    \\List information about the FILEs (the current directory by default).
    \\Sort entries alphabetically.
    \\
    \\  -a, --all          do not ignore entries starting with .
    \\  -A, --almost-all   do not list implied . and ..
    \\  -1                 list one file per line
    \\      --help         display this help and exit
    \\      --version      output version information and exit
    \\
;

const version_text =
    \\zdir (zig-forge coreutils) 1.0
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const io = Io.Threaded.global_single_threaded.io();
    var out = OutputBuffer{};
    defer {
        out.flush();
        std.process.exit(exit_code);
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var show_all = false; // -a
    var almost_all = false; // -A
    var one_per_line = false; // -1
    var no_more_opts = false; // seen "--"
    var paths = std.ArrayListUnmanaged([]const u8).empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg| {
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
        } else if (!no_more_opts and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long option.
            if (std.mem.eql(u8, arg, "--all")) {
                show_all = true;
            } else if (std.mem.eql(u8, arg, "--almost-all")) {
                almost_all = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                out.write(help_text);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                out.write(version_text);
                return;
            } else {
                stderrPrint("zdir: unrecognized option '{s}'\nTry 'zdir --help' for more information.\n", .{arg});
                setExit(2);
                return;
            }
        } else if (!no_more_opts and arg.len > 1 and arg[0] == '-') {
            // Short option cluster.
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => show_all = true,
                    'A' => almost_all = true,
                    '1' => one_per_line = true,
                    else => {
                        stderrPrint("zdir: invalid option -- '{c}'\nTry 'zdir --help' for more information.\n", .{c});
                        setExit(2);
                        return;
                    },
                }
            }
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, ".");
    }

    // GNU lists non-directory operands first (no header), then directory
    // operands (each with a "name:" header when more than one thing is
    // listed). Classify each operand up front.
    var file_operands = std.ArrayListUnmanaged([]const u8).empty;
    defer file_operands.deinit(allocator);
    var dir_operands = std.ArrayListUnmanaged([]const u8).empty;
    defer dir_operands.deinit(allocator);

    for (paths.items) |path| {
        const st = Dir.statFile(Dir.cwd(), io, path, .{}) catch |err| {
            stderrPrint("zdir: cannot access '{s}': {s}\n", .{ path, errText(err) });
            setExit(2);
            continue;
        };
        if (st.kind == .directory) {
            try dir_operands.append(allocator, path);
        } else {
            try file_operands.append(allocator, path);
        }
    }

    std.mem.sort([]const u8, file_operands.items, {}, compareStrings);
    std.mem.sort([]const u8, dir_operands.items, {}, compareStrings);

    const show_hidden = show_all or almost_all;
    const show_dots = show_all and !almost_all;
    const need_headers = (file_operands.items.len + dir_operands.items.len) > 1;

    var wrote_something = false;

    // Non-directory operands: a single listing, escaped, no header.
    if (file_operands.items.len > 0) {
        var displays = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (displays.items) |d| allocator.free(d);
            displays.deinit(allocator);
        }
        for (file_operands.items) |f| {
            const d = try escapeAlloc(allocator, f);
            try displays.append(allocator, d);
        }
        printListing(&out, displays.items, one_per_line);
        wrote_something = true;
    }

    // Directory operands.
    for (dir_operands.items) |path| {
        if (need_headers) {
            if (wrote_something) out.writeByte('\n');
            const d = escapeAlloc(allocator, path) catch path;
            defer if (d.ptr != path.ptr) allocator.free(d);
            out.write(d);
            out.write(":\n");
        }
        listDir(allocator, io, path, &out, show_hidden, show_dots, one_per_line);
        wrote_something = true;
    }
}
