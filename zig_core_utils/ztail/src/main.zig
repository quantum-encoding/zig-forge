//! ztail - Output the last part of files
//!
//! Compatible with GNU tail:
//! - -n, --lines=NUM: print last NUM lines (default 10)
//! - -c, --bytes=NUM: print last NUM bytes
//! - -f, --follow: output appended data as file grows
//! - -F: like --follow=name --retry
//! - -s, --sleep-interval=N: sleep N seconds between iterations (default 1.0)
//! - --pid=PID: terminate after process PID dies
//! - -q, --quiet: never print headers
//! - -v, --verbose: always print headers

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
    },
    else => libc.Stat,
};

// External libc declarations
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn nanosleep(req: *const libc.timespec, rem: ?*libc.timespec) c_int;

const O_FLAGS = libc.O{ .ACCMODE = .RDONLY, .CLOEXEC = true };

const FollowMode = enum {
    none,
    descriptor, // -f: follow by file descriptor (doesn't reopen on rename)
    name, // --follow=name: follow by name (reopens on rename/rotation)
};

const Config = struct {
    lines: ?u64 = 10,
    bytes: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    follow: FollowMode = .none,
    retry: bool = false, // Keep trying to open if file doesn't exist
    sleep_interval: f64 = 1.0, // Seconds between checks in follow mode
    pid: ?i32 = null, // Terminate when this PID dies
    from_start_lines: bool = false, // +N means start from line N
    from_start_bytes: bool = false, // +N means start from byte N
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(msg);
}

fn printErrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStderr(msg);
}

fn tailFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, print_header: bool) !void {
    if (print_header) {
        printFmt("==> {s} <==\n", .{path});
    }

    if (std.mem.eql(u8, path, "-")) {
        try tailStdin(allocator, config);
        return;
    }

    // Get file size
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat_buf: Stat = undefined;
    const stat_result = stat(path_z.ptr, &stat_buf);
    if (stat_result != 0) {
        printErrFmt("ztail: cannot open '{s}' for reading: No such file\n", .{path});
        return error.FileNotFound;
    }

    const file_size: u64 = @intCast(stat_buf.size);

    const fd = libc.open(path_z.ptr, O_FLAGS, @as(libc.mode_t, 0));
    if (fd < 0) {
        printErrFmt("ztail: cannot open '{s}' for reading\n", .{path});
        return error.OpenError;
    }
    defer _ = libc.close(fd);

    if (config.bytes) |num_bytes| {
        var start_pos: u64 = undefined;

        if (config.from_start_bytes) {
            // +N: start from byte N (1-indexed)
            start_pos = if (num_bytes > 0) num_bytes - 1 else 0;
            if (start_pos > file_size) start_pos = file_size;
        } else {
            // -N: last N bytes
            start_pos = if (num_bytes >= file_size) 0 else file_size - num_bytes;
        }

        var buf: [8192]u8 = undefined;

        // Read from start_pos using positional read
        var pos: u64 = start_pos;
        while (pos < file_size) {
            const to_read = @min(file_size - pos, buf.len);
            const bytes_read = pread(fd, &buf, to_read, @intCast(pos));
            if (bytes_read <= 0) break;
            writeStdout(buf[0..@intCast(bytes_read)]);
            pos += @intCast(bytes_read);
        }
    } else if (config.lines) |num_lines| {
        if (config.from_start_lines) {
            // +N: start from line N (1-indexed)
            // Read forward, skip first N-1 lines, output the rest
            var buf: [8192]u8 = undefined;
            var lines_skipped: u64 = 0;
            const lines_to_skip = if (num_lines > 0) num_lines - 1 else 0;
            var pos: u64 = 0;

            // Skip first N-1 lines
            while (lines_skipped < lines_to_skip and pos < file_size) {
                const to_read = @min(file_size - pos, buf.len);
                const bytes_read = pread(fd, &buf, to_read, @intCast(pos));
                if (bytes_read <= 0) break;

                const read_count: usize = @intCast(bytes_read);
                for (buf[0..read_count], 0..) |byte, idx| {
                    if (byte == '\n') {
                        lines_skipped += 1;
                        if (lines_skipped >= lines_to_skip) {
                            pos += idx + 1;
                            break;
                        }
                    }
                } else {
                    pos += read_count;
                }
            }

            // Output from current position to end
            while (pos < file_size) {
                const to_read = @min(file_size - pos, buf.len);
                const bytes_read = pread(fd, &buf, to_read, @intCast(pos));
                if (bytes_read <= 0) break;
                writeStdout(buf[0..@intCast(bytes_read)]);
                pos += @intCast(bytes_read);
            }
        } else {
            // -N: last N lines
            // Strategy: read backwards in chunks to find line positions
            const chunk_size: u64 = 8192;
            var line_positions: std.ArrayListUnmanaged(u64) = .empty;
            defer line_positions.deinit(allocator);

            // Add end of file as implicit line ending
            try line_positions.append(allocator, file_size);

            var search_pos: u64 = file_size;
            var buf: [8192]u8 = undefined;

            // Search backwards for newlines
            outer: while (search_pos > 0 and line_positions.items.len <= num_lines) {
                const read_size = @min(search_pos, chunk_size);
                const read_start = search_pos - read_size;

                const bytes_read = pread(fd, &buf, read_size, @intCast(read_start));
                if (bytes_read <= 0) break;

                const read_count: usize = @intCast(bytes_read);

                // Scan backwards through buffer
                var i: usize = read_count;
                while (i > 0) {
                    i -= 1;
                    if (buf[i] == '\n') {
                        const line_pos = read_start + i + 1;
                        if (line_pos < file_size) {
                            try line_positions.append(allocator, line_pos);
                            if (line_positions.items.len > num_lines) break :outer;
                        }
                    }
                }

                search_pos = read_start;
            }

            // Determine start position
            // line_positions[0] = file_size, [1] = start of last line, [2] = start of 2nd-to-last, etc.
            const start_pos = if (line_positions.items.len > num_lines)
                line_positions.items[num_lines]
            else if (search_pos == 0)
                0
            else
                line_positions.items[line_positions.items.len - 1];

            // Read and output from start_pos
            var pos: u64 = start_pos;
            while (pos < file_size) {
                const to_read = @min(file_size - pos, buf.len);
                const bytes_read = pread(fd, &buf, to_read, @intCast(pos));
                if (bytes_read <= 0) break;
                writeStdout(buf[0..@intCast(bytes_read)]);
                pos += @intCast(bytes_read);
            }
        }
    }
}

fn tailStdin(allocator: std.mem.Allocator, config: *const Config) !void {
    // For stdin, we need to buffer everything since we can't seek
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = libc.read(libc.STDIN_FILENO, &buf, buf.len);
        if (bytes_read <= 0) break;
        try content.appendSlice(allocator, buf[0..@intCast(bytes_read)]);
    }

    const data = content.items;

    if (config.bytes) |num_bytes| {
        if (config.from_start_bytes) {
            // +N: start from byte N (1-indexed)
            const start = if (num_bytes > 0) @min(num_bytes - 1, data.len) else 0;
            writeStdout(data[@intCast(start)..]);
        } else {
            const start = if (num_bytes >= data.len) 0 else data.len - @as(usize, @intCast(num_bytes));
            writeStdout(data[start..]);
        }
    } else if (config.lines) |num_lines| {
        if (config.from_start_lines) {
            // +N: start from line N (1-indexed), skip first N-1 lines
            var lines_skipped: u64 = 0;
            const lines_to_skip = if (num_lines > 0) num_lines - 1 else 0;
            var pos: usize = 0;

            while (pos < data.len and lines_skipped < lines_to_skip) {
                if (data[pos] == '\n') {
                    lines_skipped += 1;
                }
                pos += 1;
            }
            writeStdout(data[pos..]);
        } else {
            // Find last N newlines
            var line_count: u64 = 0;
            // Skip trailing newline (same as file-based path)
            var pos: usize = data.len;
            if (pos > 0 and data[pos - 1] == '\n') {
                pos -= 1;
            }

            while (pos > 0 and line_count < num_lines) {
                pos -= 1;
                if (data[pos] == '\n') {
                    line_count += 1;
                }
            }

            // Adjust if we found enough lines
            if (line_count >= num_lines and pos > 0) {
                pos += 1; // Move past the newline
            } else if (line_count < num_lines) {
                pos = 0;
            }

            writeStdout(data[pos..]);
        }
    }
}

/// FileState tracks the state of a file being followed
const FileState = struct {
    path: []const u8,
    fd: c_int = -1,
    inode: u64 = 0,
    dev: u64 = 0,
    pos: i64 = 0, // i64 for pread offset
    ignore: bool = false,

    fn close(self: *FileState) void {
        if (self.fd >= 0) {
            _ = libc.close(self.fd);
            self.fd = -1;
        }
    }
};

/// Check if a PID is still alive
fn isPidAlive(pid: i32) bool {
    // Signal 0 tests for PID existence without sending a real signal
    const result = kill(@intCast(pid), 0);
    if (result == 0) return true;
    // Check if errno is ESRCH (no such process)
    const err = std.c.errno(result);
    return err != .SRCH;
}

fn doSleep(sleep_ns: u64) void {
    const secs: i64 = @intCast(sleep_ns / 1_000_000_000);
    const nsecs: i64 = @intCast(sleep_ns % 1_000_000_000);
    var ts = libc.timespec{ .sec = secs, .nsec = nsecs };
    _ = nanosleep(&ts, null);
}

/// Follow files for new content using polling (cross-platform)
fn followFiles(allocator: std.mem.Allocator, config: *const Config, file_states: []FileState) !void {
    const sleep_ns: u64 = @intFromFloat(config.sleep_interval * 1_000_000_000);
    var last_printed_idx: ?usize = null;

    while (true) {
        // Check if PID died
        if (config.pid) |pid| {
            if (!isPidAlive(pid)) {
                break;
            }
        }

        // Check each file for new content
        for (file_states, 0..) |*state, idx| {
            if (state.ignore or std.mem.eql(u8, state.path, "-")) continue;

            // Try to reopen if needed (for follow by name or retry)
            if (state.fd < 0) {
                if (config.follow == .name or config.retry) {
                    const path_z = allocator.dupeZ(u8, state.path) catch continue;
                    defer allocator.free(path_z);

                    const fd = libc.open(path_z.ptr, O_FLAGS, @as(libc.mode_t, 0));
                    if (fd >= 0) {
                        state.fd = fd;
                        state.pos = 0;

                        // Get new inode
                        var stat_buf2: Stat = undefined;
                        _ = stat(path_z.ptr, &stat_buf2);
                        state.inode = stat_buf2.ino;
                        state.dev = @intCast(stat_buf2.dev);

                        // Print header if multiple files
                        if (file_states.len > 1 and !config.quiet) {
                            if (last_printed_idx != idx) {
                                printFmt("\n==> {s} <==\n", .{state.path});
                                last_printed_idx = idx;
                            }
                        }
                    }
                }
                continue;
            }

            // Check if file was replaced (different inode) for follow by name
            if (config.follow == .name) {
                const path_z = allocator.dupeZ(u8, state.path) catch continue;
                defer allocator.free(path_z);

                var stat_buf: Stat = undefined;
                const stat_result = stat(path_z.ptr, &stat_buf);
                if (stat_result == 0) {
                    if (stat_buf.ino != state.inode) {
                        // File was replaced, reopen
                        state.close();
                        const fd = libc.open(path_z.ptr, O_FLAGS, @as(libc.mode_t, 0));
                        if (fd >= 0) {
                            state.fd = fd;
                            state.pos = 0;
                            state.inode = stat_buf.ino;

                            if (file_states.len > 1 and !config.quiet) {
                                printFmt("\n==> {s} <==\n", .{state.path});
                                last_printed_idx = idx;
                            }
                        }
                    }
                } else if (config.retry) {
                    // File deleted, close and wait for it to reappear
                    state.close();
                    continue;
                }
            }

            // Read new content
            var buf: [8192]u8 = undefined;
            while (true) {
                const n = pread(state.fd, &buf, buf.len, state.pos);
                if (n <= 0) break;

                // Print header if switching files
                if (file_states.len > 1 and !config.quiet and last_printed_idx != idx) {
                    printFmt("\n==> {s} <==\n", .{state.path});
                    last_printed_idx = idx;
                }

                writeStdout(buf[0..@intCast(n)]);
                state.pos += n;
            }
        }

        // Sleep before next iteration
        doSleep(sleep_ns);
    }
}

const ParsedNumber = struct {
    value: u64,
    from_start: bool, // +N means start from position N
};

fn parseNumber(s: []const u8) ?ParsedNumber {
    if (s.len == 0) return null;

    var val: u64 = 0;
    var multiplier: u64 = 1;
    var num_str = s;
    var from_start = false;

    // Check for leading + (from start) or - (from end, same as no prefix)
    if (num_str[0] == '+') {
        from_start = true;
        num_str = num_str[1..];
        if (num_str.len == 0) return null;
    } else if (num_str[0] == '-') {
        num_str = num_str[1..];
        if (num_str.len == 0) return null;
    }

    if (num_str.len > 0) {
        const last = num_str[num_str.len - 1];
        switch (last) {
            'k', 'K' => {
                multiplier = 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            'm', 'M' => {
                multiplier = 1024 * 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            'g', 'G' => {
                multiplier = 1024 * 1024 * 1024;
                num_str = num_str[0 .. num_str.len - 1];
            },
            else => {},
        }
    }

    for (num_str) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + (ch - '0');
    }

    return .{ .value = val * multiplier, .from_start = from_start };
}

fn parseFloat(s: []const u8) ?f64 {
    var result: f64 = 0;
    var decimal_place: f64 = 0;
    var seen_dot = false;

    for (s) |ch| {
        if (ch == '.') {
            if (seen_dot) return null;
            seen_dot = true;
            decimal_place = 0.1;
        } else if (ch >= '0' and ch <= '9') {
            if (seen_dot) {
                result += @as(f64, @floatFromInt(ch - '0')) * decimal_place;
                decimal_place *= 0.1;
            } else {
                result = result * 10 + @as(f64, @floatFromInt(ch - '0'));
            }
        } else {
            return null;
        }
    }
    return result;
}

fn parseInt(s: []const u8) ?i32 {
    var val: i32 = 0;
    var negative = false;
    var start: usize = 0;

    if (s.len > 0 and s[0] == '-') {
        negative = true;
        start = 1;
    }

    for (s[start..]) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + @as(i32, @intCast(ch - '0'));
    }

    return if (negative) -val else val;
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.startsWith(u8, arg, "--lines=")) {
                    if (parseNumber(arg[8..])) |parsed| {
                        config.lines = parsed.value;
                        config.from_start_lines = parsed.from_start;
                    }
                    config.bytes = null;
                } else if (std.mem.eql(u8, arg, "--lines")) {
                    i += 1;
                    if (i >= args.len) {
                        printErrFmt("ztail: option '--lines' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseNumber(args[i])) |parsed| {
                        config.lines = parsed.value;
                        config.from_start_lines = parsed.from_start;
                    }
                    config.bytes = null;
                } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
                    if (parseNumber(arg[8..])) |parsed| {
                        config.bytes = parsed.value;
                        config.from_start_bytes = parsed.from_start;
                    }
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    i += 1;
                    if (i >= args.len) {
                        printErrFmt("ztail: option '--bytes' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseNumber(args[i])) |parsed| {
                        config.bytes = parsed.value;
                        config.from_start_bytes = parsed.from_start;
                    }
                    config.lines = null;
                } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    config.verbose = true;
                } else if (std.mem.eql(u8, arg, "--follow")) {
                    config.follow = .descriptor;
                } else if (std.mem.startsWith(u8, arg, "--follow=")) {
                    const mode = arg[9..];
                    if (std.mem.eql(u8, mode, "descriptor")) {
                        config.follow = .descriptor;
                    } else if (std.mem.eql(u8, mode, "name")) {
                        config.follow = .name;
                    } else {
                        printErrFmt("ztail: invalid argument '{s}' for '--follow'\n", .{mode});
                        std.process.exit(1);
                    }
                } else if (std.mem.eql(u8, arg, "--retry")) {
                    config.retry = true;
                } else if (std.mem.startsWith(u8, arg, "--sleep-interval=")) {
                    if (parseFloat(arg[17..])) |val| {
                        config.sleep_interval = val;
                    } else {
                        printErrFmt("ztail: invalid number '{s}'\n", .{arg[17..]});
                        std.process.exit(1);
                    }
                } else if (std.mem.eql(u8, arg, "--sleep-interval")) {
                    i += 1;
                    if (i >= args.len) {
                        printErrFmt("ztail: option '--sleep-interval' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseFloat(args[i])) |val| {
                        config.sleep_interval = val;
                    } else {
                        printErrFmt("ztail: invalid number '{s}'\n", .{args[i]});
                        std.process.exit(1);
                    }
                } else if (std.mem.startsWith(u8, arg, "--pid=")) {
                    if (parseInt(arg[6..])) |val| {
                        config.pid = val;
                    } else {
                        printErrFmt("ztail: invalid PID '{s}'\n", .{arg[6..]});
                        std.process.exit(1);
                    }
                } else if (std.mem.eql(u8, arg, "--pid")) {
                    i += 1;
                    if (i >= args.len) {
                        printErrFmt("ztail: option '--pid' requires an argument\n", .{});
                        std.process.exit(1);
                    }
                    if (parseInt(args[i])) |val| {
                        config.pid = val;
                    } else {
                        printErrFmt("ztail: invalid PID '{s}'\n", .{args[i]});
                        std.process.exit(1);
                    }
                } else {
                    printErrFmt("ztail: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            } else {
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'n' => {
                            if (j + 1 < arg.len) {
                                if (parseNumber(arg[j + 1 ..])) |parsed| {
                                    config.lines = parsed.value;
                                    config.from_start_lines = parsed.from_start;
                                }
                                config.bytes = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printErrFmt("ztail: option requires an argument -- 'n'\n", .{});
                                    std.process.exit(1);
                                }
                                if (parseNumber(args[i])) |parsed| {
                                    config.lines = parsed.value;
                                    config.from_start_lines = parsed.from_start;
                                }
                                config.bytes = null;
                            }
                        },
                        'c' => {
                            if (j + 1 < arg.len) {
                                if (parseNumber(arg[j + 1 ..])) |parsed| {
                                    config.bytes = parsed.value;
                                    config.from_start_bytes = parsed.from_start;
                                }
                                config.lines = null;
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printErrFmt("ztail: option requires an argument -- 'c'\n", .{});
                                    std.process.exit(1);
                                }
                                if (parseNumber(args[i])) |parsed| {
                                    config.bytes = parsed.value;
                                    config.from_start_bytes = parsed.from_start;
                                }
                                config.lines = null;
                            }
                        },
                        'f' => config.follow = .descriptor,
                        'F' => {
                            config.follow = .name;
                            config.retry = true;
                        },
                        's' => {
                            if (j + 1 < arg.len) {
                                if (parseFloat(arg[j + 1 ..])) |val| {
                                    config.sleep_interval = val;
                                }
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printErrFmt("ztail: option requires an argument -- 's'\n", .{});
                                    std.process.exit(1);
                                }
                                if (parseFloat(args[i])) |val| {
                                    config.sleep_interval = val;
                                }
                            }
                        },
                        'q' => config.quiet = true,
                        'v' => config.verbose = true,
                        '0'...'9' => {
                            if (parseNumber(arg[j..])) |parsed| {
                                config.lines = parsed.value;
                                config.from_start_lines = parsed.from_start;
                            }
                            config.bytes = null;
                            break;
                        },
                        else => {
                            printErrFmt("ztail: invalid option -- '{c}'\n", .{arg[j]});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printHelp() void {
    writeStdout(
        \\Usage: ztail [OPTION]... [FILE]...
        \\Print the last 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\  -c, --bytes=NUM         print the last NUM bytes
        \\  -f, --follow[=HOW]      output appended data as file grows;
        \\                          HOW is 'descriptor' (default) or 'name'
        \\  -F                      same as --follow=name --retry
        \\  -n, --lines=NUM         print the last NUM lines (default 10)
        \\      --pid=PID           terminate after process PID dies (with -f)
        \\  -q, --quiet, --silent   never print headers
        \\      --retry             keep trying to open file if inaccessible
        \\  -s, --sleep-interval=N  sleep N seconds between iterations (default 1.0)
        \\  -v, --verbose           always print headers
        \\      --help              display this help and exit
        \\      --version           output version information and exit
        \\
        \\NUM may have a multiplier suffix: k (1024), M (1024*1024), G (1024^3)
        \\
        \\With --follow (-f), tail follows by file descriptor (doesn't reopen).
        \\With --follow=name, tail reopens file by name (handles log rotation).
        \\
        \\ztail - High-performance tail utility in Zig
        \\
    );
}

fn printVersion() void {
    writeStdout("ztail 0.1.0\n");
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printErrFmt("ztail: failed to parse arguments\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    const multiple_files = config.files.items.len > 1;
    var error_occurred = false;
    var first = true;

    // Create file states for follow mode
    var file_states: []FileState = &.{};
    defer {
        for (file_states) |*state| {
            state.close();
        }
        if (file_states.len > 0) allocator.free(file_states);
    }

    if (config.follow != .none) {
        file_states = allocator.alloc(FileState, config.files.items.len) catch {
            printErrFmt("ztail: memory allocation failed\n", .{});
            std.process.exit(1);
        };
        for (file_states, 0..) |*state, i| {
            state.* = FileState{ .path = config.files.items[i] };
        }
    }

    // Print initial content
    for (config.files.items, 0..) |file, idx| {
        const print_header = (config.verbose or (multiple_files and !config.quiet));

        if (!first and print_header) {
            writeStdout("\n");
        }

        // For follow mode, track file position after initial read
        if (config.follow != .none and !std.mem.eql(u8, file, "-")) {
            const path_z = allocator.dupeZ(u8, file) catch {
                error_occurred = true;
                continue;
            };
            defer allocator.free(path_z);

            // Get initial file info
            var stat_buf3: Stat = undefined;
            const stat_result3 = stat(path_z.ptr, &stat_buf3);

            if (stat_result3 == 0) {
                file_states[idx].inode = stat_buf3.ino;
                file_states[idx].dev = @intCast(stat_buf3.dev);
                file_states[idx].pos = @intCast(stat_buf3.size); // Start from end after initial display

                // Open file descriptor for follow mode
                const fd = libc.open(path_z.ptr, O_FLAGS, @as(libc.mode_t, 0));
                if (fd >= 0) {
                    file_states[idx].fd = fd;
                }
            } else if (!config.retry) {
                file_states[idx].ignore = true;
            }
        }

        tailFile(allocator, file, &config, print_header) catch {
            error_occurred = true;
            if (config.follow != .none and idx < file_states.len) {
                if (!config.retry) {
                    file_states[idx].ignore = true;
                }
            }
        };
        first = false;
    }

    // Enter follow mode if requested
    if (config.follow != .none) {
        followFiles(allocator, &config, file_states) catch |err| {
            printErrFmt("ztail: follow error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    if (error_occurred and config.follow == .none) {
        std.process.exit(1);
    }
}
