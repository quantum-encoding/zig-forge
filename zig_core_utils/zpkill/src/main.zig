//! zpkill - Send signals to processes by name
//!
//! A Zig implementation of pkill.
//! Finds processes by name pattern and sends signals to them.
//!
//! Usage: zpkill [OPTIONS] PATTERN
//!
//! NOTE ON MATCHING: PATTERN is matched as a literal substring (or, with -x, an
//! exact string). Real procps pkill treats PATTERN as an extended regular
//! expression; that regex behavior is not yet implemented here. See
//! remaining[] in the audit — do not assume '^foo$' / 'a|b' anchoring works.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

// C types and functions
const DIR = opaque {};
const dirent = extern struct {
    d_ino: c_ulong,
    d_off: c_long,
    d_reclen: c_ushort,
    d_type: u8,
    d_name: [256]u8,
};

// passwd — only the first four fields are accessed, and their order
// (pw_name, pw_passwd, pw_uid, pw_gid) is identical on Linux and the BSDs,
// so reading pw_uid is layout-safe on either platform.
const passwd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: c_uint,
    pw_gid: c_uint,
};

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;
extern "c" fn getpwnam(name: [*:0]const u8) ?*passwd;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn closedir(dirp: *DIR) c_int;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

// Linux glibc user-visible real-time signal range (see `kill -l`).
const SIGRTMIN: i32 = 34;
const SIGRTMAX: i32 = 64;

// Stderr/stdout writers
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

const ProcessInfo = struct {
    pid: i32,
    name: []const u8,
    cmdline: []const u8,
    uid: u32,
    start_time: u64,
};

/// Decide -c/--count output and exit code from the number of matches.
///
/// Anchored to GNU procps `pkill -c` documented behavior: it always prints the
/// count (including "0") and exits 1 when the count is zero, 0 otherwise. The
/// pre-fix code exited 1 *before* printing on zero matches, so a script doing
/// `n=$(zpkill -c foo)` got an empty string instead of "0".
pub const CountOutcome = struct { count: usize, exit_code: u8 };
pub fn countOutcome(match_count: usize) CountOutcome {
    return .{ .count = match_count, .exit_code = if (match_count == 0) 1 else 0 };
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
    var signal_num: i32 = 15; // SIGTERM
    var full_match = false;
    var exact_match = false;
    var count_only = false;
    var list_pids = false;
    var newest_only = false;
    var oldest_only = false;
    var user_filter: ?u32 = null;
    var pattern: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("zpkill {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--full")) {
            full_match = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exact")) {
            exact_match = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_pids = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--newest")) {
            newest_only = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--oldest")) {
            oldest_only = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uid")) {
            if (i + 1 >= args.len) {
                writeStderr("zpkill: option requires an argument -- 'u'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            user_filter = resolveUser(args[i]) orelse {
                writeStderr("zpkill: invalid user name: {s}\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
            if (i + 1 >= args.len) {
                writeStderr("zpkill: option requires an argument -- 's'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            signal_num = parseSignal(args[i]) orelse {
                writeStderr("zpkill: invalid signal: {s}\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Could be -SIGNAL or combined options
            const spec = arg[1..];
            if (parseSignal(spec)) |sig| {
                signal_num = sig;
            } else {
                // Try as combined short options
                for (spec) |ch| {
                    switch (ch) {
                        'f' => full_match = true,
                        'x' => exact_match = true,
                        'c' => count_only = true,
                        'l' => list_pids = true,
                        'n' => newest_only = true,
                        'o' => oldest_only = true,
                        else => {
                            writeStderr("zpkill: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(2);
                        },
                    }
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            pattern = arg;
        } else {
            writeStderr("zpkill: invalid option: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    // GNU pkill allows selection by -u alone (no PATTERN); it only errors when
    // NO selection criteria at all are given.
    if (pattern == null and user_filter == null) {
        writeStderr("zpkill: no process selection criteria\n", .{});
        std.process.exit(2);
    }

    // Find matching processes
    var matches: std.ArrayListUnmanaged(ProcessInfo) = .empty;
    defer {
        for (matches.items) |p| {
            allocator.free(p.name);
            allocator.free(p.cmdline);
        }
        matches.deinit(allocator);
    }

    findProcesses(allocator, &matches, pattern, full_match, exact_match, user_filter) catch |err| {
        if (err == error.ProcNotAvailable) {
            writeStderr("zpkill: /proc is not available (this tool requires a Linux /proc filesystem)\n", .{});
            std.process.exit(2);
        }
        return err;
    };

    // Filter to newest/oldest if requested (guarded for the empty case)
    var targets = matches.items;
    var single_target: [1]ProcessInfo = undefined;

    if ((newest_only or oldest_only) and targets.len > 0) {
        var selected = targets[0];
        for (targets[1..]) |p| {
            if (newest_only and p.start_time > selected.start_time) {
                selected = p;
            } else if (oldest_only and p.start_time < selected.start_time) {
                selected = p;
            }
        }
        single_target[0] = selected;
        targets = &single_target;
    }

    // Count only mode — always print the count (incl. "0"), exit 1 on zero.
    if (count_only) {
        const outcome = countOutcome(targets.len);
        writeStdout("{d}\n", .{outcome.count});
        std.process.exit(outcome.exit_code);
    }

    if (targets.len == 0) {
        std.process.exit(1); // No matches
    }

    // List mode
    if (list_pids) {
        for (targets) |p| {
            writeStdout("{d}\n", .{p.pid});
        }
        return;
    }

    // Send signals
    var killed: u32 = 0;
    var errors: u32 = 0;

    for (targets) |p| {
        const result = kill(p.pid, @intCast(signal_num));
        if (result == 0) {
            killed += 1;
        } else {
            errors += 1;
        }
    }

    if (errors > 0 and killed == 0) {
        std.process.exit(1);
    }
}

/// Resolve a -u argument to a numeric UID. Accepts a numeric UID directly, or a
/// username resolved via getpwnam(3). Comma-separated lists are not yet
/// supported (see remaining[]).
fn resolveUser(spec: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, spec, 10)) |n| {
        return n;
    } else |_| {}

    var buf: [256]u8 = undefined;
    if (spec.len >= buf.len) return null;
    @memcpy(buf[0..spec.len], spec);
    buf[spec.len] = 0;
    const pw = getpwnam(@ptrCast(&buf)) orelse return null;
    return @intCast(pw.pw_uid);
}

fn findProcesses(
    allocator: std.mem.Allocator,
    matches: *std.ArrayListUnmanaged(ProcessInfo),
    pattern: ?[]const u8,
    full_match: bool,
    exact_match: bool,
    user_filter: ?u32,
) !void {
    // Open /proc directory
    const dir = opendir("/proc") orelse return error.ProcNotAvailable;
    defer _ = closedir(dir);

    const self_pid = getpid();

    while (readdir(dir)) |entry| {
        // Get entry name (null-terminated)
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);

        // Only process numeric directories (PIDs)
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;

        // Never signal ourselves — GNU pkill excludes its own PID by default.
        if (pid == self_pid) continue;

        // Read process info
        const info = readProcessInfo(allocator, pid) catch continue;

        // Apply user filter
        if (user_filter) |uid| {
            if (info.uid != uid) {
                allocator.free(info.name);
                allocator.free(info.cmdline);
                continue;
            }
        }

        // Match pattern (null pattern = match all, subject to the user filter)
        const matched = if (pattern) |pat| blk: {
            const match_str = if (full_match) info.cmdline else info.name;
            break :blk if (exact_match)
                std.mem.eql(u8, match_str, pat)
            else
                std.mem.indexOf(u8, match_str, pat) != null;
        } else true;

        if (matched) {
            try matches.append(allocator, info);
        } else {
            allocator.free(info.name);
            allocator.free(info.cmdline);
        }
    }
}

/// Read a whole /proc/<pid>/<kind> file, looping until EOF. /proc files report
/// size 0 to stat(2), so a single read() can short-read (or truncate a long
/// cmdline); loop and grow instead. Returns null if the file can't be opened.
fn readProcFile(allocator: std.mem.Allocator, comptime kind: []const u8, pid: i32) ?[]u8 {
    var path_buf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&path_buf, "/proc/{d}/" ++ kind, .{pid}) catch return null;
    path_buf[p.len] = 0;

    const fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);

    var list: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c_read(fd, &chunk, chunk.len);
        if (n < 0) {
            list.deinit(allocator);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(allocator, chunk[0..@intCast(n)]) catch {
            list.deinit(allocator);
            return null;
        };
        if (list.items.len > (1 << 20)) break; // 1 MiB safety cap
    }
    return list.toOwnedSlice(allocator) catch null;
}

/// Extract the numeric effective UID from /proc/<pid>/status content.
/// The "Uid:" line is `Uid:\t<real>\t<eff>\t<saved>\t<fs>` (proc(5)); procps
/// matches on the real UID field (the first), which is what we return here.
pub fn parseUidFromStatus(content: []const u8) ?u32 {
    if (std.mem.indexOf(u8, content, "Uid:")) |pos| {
        var line_end = pos;
        while (line_end < content.len and content[line_end] != '\n') line_end += 1;
        const line = content[pos..line_end];
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        _ = parts.next(); // "Uid:"
        if (parts.next()) |uid_str| {
            return std.fmt.parseInt(u32, uid_str, 10) catch null;
        }
    }
    return null;
}

/// Extract starttime (field 22) from a /proc/<pid>/stat line (proc(5)).
/// comm (field 2) is parenthesized and may itself contain spaces or ')', so we
/// scan from the LAST ')' and count fields from there: after comm the tokens
/// are state(3) ppid(4) ... itrealvalue(21) starttime(22) — i.e. skip 19
/// tokens, the 20th is starttime.
pub fn parseStarttime(content: []const u8) ?u64 {
    if (std.mem.lastIndexOfScalar(u8, content, ')')) |paren_pos| {
        const after_comm = content[paren_pos + 1 ..];
        var parts = std.mem.tokenizeAny(u8, after_comm, " ");
        var field: u32 = 0;
        while (field < 19) : (field += 1) {
            _ = parts.next();
        }
        if (parts.next()) |time_str| {
            return std.fmt.parseInt(u64, time_str, 10) catch null;
        }
    }
    return null;
}

fn readProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    // Read comm (process name)
    const comm = readProcFile(allocator, "comm", pid) orelse return error.ProcessGone;
    defer allocator.free(comm);
    var name_end = comm.len;
    if (name_end > 0 and comm[name_end - 1] == '\n') name_end -= 1;
    if (name_end == 0) return error.EmptyName;
    const name = try allocator.dupe(u8, comm[0..name_end]);
    errdefer allocator.free(name);

    // Read cmdline (fall back to comm name if empty/absent)
    const cmdline = blk: {
        const raw = readProcFile(allocator, "cmdline", pid) orelse break :blk try allocator.dupe(u8, name);
        defer allocator.free(raw);
        if (raw.len == 0) break :blk try allocator.dupe(u8, name);
        // Replace null argument separators with spaces
        for (raw) |*ch| {
            if (ch.* == 0) ch.* = ' ';
        }
        var end = raw.len;
        while (end > 0 and raw[end - 1] == ' ') end -= 1;
        break :blk try allocator.dupe(u8, raw[0..end]);
    };
    errdefer allocator.free(cmdline);

    // Read UID from status
    var uid: u32 = 0;
    if (readProcFile(allocator, "status", pid)) |status| {
        defer allocator.free(status);
        if (parseUidFromStatus(status)) |u| uid = u;
    }

    // Read start time from stat
    var start_time: u64 = 0;
    if (readProcFile(allocator, "stat", pid)) |stat| {
        defer allocator.free(stat);
        if (parseStarttime(stat)) |t| start_time = t;
    }

    return ProcessInfo{
        .pid = pid,
        .name = name,
        .cmdline = cmdline,
        .uid = uid,
        .start_time = start_time,
    };
}

/// Parse a signal specifier (number or name) into a signal number.
/// Accepts 0..64 numeric (covers real-time signals), classic names (with or
/// without the SIG prefix, case-insensitive), and glibc SIGRTMIN[+n]/
/// SIGRTMAX[-n] forms. Returns null for anything out of range or unknown.
pub fn parseSignal(spec: []const u8) ?i32 {
    // Try as number (0..SIGRTMAX)
    if (std.fmt.parseInt(i32, spec, 10)) |num| {
        if (num >= 0 and num <= SIGRTMAX) return num;
        return null;
    } else |_| {}

    // Strip optional SIG prefix
    var name = spec;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) {
        name = name[3..];
    }

    // Real-time signals: RTMIN[+n], RTMAX[-n]
    if (name.len >= 5 and std.ascii.eqlIgnoreCase(name[0..5], "RTMIN")) {
        const rest = name[5..];
        if (rest.len == 0) return SIGRTMIN;
        if (rest[0] == '+') {
            const off = std.fmt.parseInt(i32, rest[1..], 10) catch return null;
            const v = SIGRTMIN + off;
            if (v >= SIGRTMIN and v <= SIGRTMAX) return v;
        }
        return null;
    }
    if (name.len >= 5 and std.ascii.eqlIgnoreCase(name[0..5], "RTMAX")) {
        const rest = name[5..];
        if (rest.len == 0) return SIGRTMAX;
        if (rest[0] == '-') {
            const off = std.fmt.parseInt(i32, rest[1..], 10) catch return null;
            const v = SIGRTMAX - off;
            if (v >= SIGRTMIN and v <= SIGRTMAX) return v;
        }
        return null;
    }

    const sig_names = [_]struct { name: []const u8, num: i32 }{
        .{ .name = "HUP", .num = 1 },
        .{ .name = "INT", .num = 2 },
        .{ .name = "QUIT", .num = 3 },
        .{ .name = "ILL", .num = 4 },
        .{ .name = "TRAP", .num = 5 },
        .{ .name = "ABRT", .num = 6 },
        .{ .name = "BUS", .num = 7 },
        .{ .name = "FPE", .num = 8 },
        .{ .name = "KILL", .num = 9 },
        .{ .name = "USR1", .num = 10 },
        .{ .name = "SEGV", .num = 11 },
        .{ .name = "USR2", .num = 12 },
        .{ .name = "PIPE", .num = 13 },
        .{ .name = "ALRM", .num = 14 },
        .{ .name = "TERM", .num = 15 },
        .{ .name = "STKFLT", .num = 16 },
        .{ .name = "CHLD", .num = 17 },
        .{ .name = "CONT", .num = 18 },
        .{ .name = "STOP", .num = 19 },
        .{ .name = "TSTP", .num = 20 },
        .{ .name = "TTIN", .num = 21 },
        .{ .name = "TTOU", .num = 22 },
        .{ .name = "URG", .num = 23 },
        .{ .name = "XCPU", .num = 24 },
        .{ .name = "XFSZ", .num = 25 },
        .{ .name = "VTALRM", .num = 26 },
        .{ .name = "PROF", .num = 27 },
        .{ .name = "WINCH", .num = 28 },
        .{ .name = "IO", .num = 29 },
        .{ .name = "PWR", .num = 30 },
        .{ .name = "SYS", .num = 31 },
    };

    for (sig_names) |sig| {
        if (std.ascii.eqlIgnoreCase(name, sig.name)) {
            return sig.num;
        }
    }

    return null;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zpkill [OPTIONS] PATTERN
        \\
        \\Send signals to processes matching PATTERN.
        \\PATTERN is matched as a literal substring (or exact name with -x);
        \\regular-expression matching is not yet supported.
        \\
        \\Options:
        \\  -SIGNAL            specify signal (e.g., -9, -KILL)
        \\  -s, --signal SIG   specify signal by name or number
        \\  -f, --full         match against full command line
        \\  -x, --exact        require exact match of process name
        \\  -n, --newest       select most recently started process
        \\  -o, --oldest       select least recently started process
        \\  -u, --uid USER     match only processes owned by USER (name or UID)
        \\  -c, --count        count matching processes, don't signal
        \\  -l, --list         list matching PIDs, don't signal
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Exit status:
        \\   0  One or more processes matched
        \\   1  No processes matched
        \\   2  Syntax or usage error
        \\
        \\Examples:
        \\  zpkill firefox         Kill all firefox processes
        \\  zpkill -9 chrome       Force kill all chrome processes
        \\  zpkill -HUP nginx      Send SIGHUP to nginx (reload)
        \\  zpkill -f "python app" Match full command line
        \\  zpkill -x bash         Only exact "bash" (not bashrc)
        \\  zpkill -n sleep        Kill newest sleep process
        \\  zpkill -u 1000 python  Kill python owned by UID 1000
        \\  zpkill -u alice        Kill all processes owned by alice
        \\  zpkill -l java         List PIDs of java processes
        \\  zpkill -c ssh          Count ssh processes
        \\
    , .{});
}
