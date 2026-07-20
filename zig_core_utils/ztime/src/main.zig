//! ztime - GNU time replacement in pure Zig
//!
//! Measures real (wall clock), user (CPU in user mode), and system (CPU in kernel mode)
//! time for command execution.
//!
//! Output modes:
//!   * default (no flag): bash-builtin `time` style (`real\t0m0.000s`), NOT the GNU
//!     standalone `/usr/bin/time` default one-liner. Kept for backwards compatibility.
//!   * -p / --portable: POSIX `real/user/sys` seconds.
//!   * -v / --verbose:  GNU-verbose multi-line report.
//!   * -f / --format:   GNU format-string specifiers (%e %E %U %S %P %M %c %w ... — see -h).
//!
//! The -f specifiers follow GNU `time`'s documented semantics (info time / man 1 time):
//! %e = elapsed seconds, %E = elapsed [h:]mm:ss.ss, %w = voluntary ctx switches,
//! %c = involuntary ctx switches, %M = max RSS in KB (normalized on Darwin where the
//! kernel reports ru_maxrss in bytes).

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

// Zig 0.16 compatible Timer (std.time.Timer was removed)
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};

// External libc declarations
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn getpagesize() c_int;

// Use the platform-correct rusage / timeval layouts from std.c. The previous
// hand-rolled struct declared `usec` as `isize` (8 bytes); on 64-bit Darwin
// `tv_usec` is a 32-bit `suseconds_t` (c_int) followed by 4 bytes of padding, so an
// 8-byte read straddled usec + padding and could corrupt user/sys time whenever the
// padding was non-zero. std.c.timeval uses the correct `suseconds_t` width per OS.
const rusage = std.c.rusage;
const RUSAGE_CHILDREN: c_int = -1;

/// Read a timeval field as microseconds (i64), coercing whatever platform-specific
/// integer widths sec/usec have (time_t / suseconds_t) into a common type.
fn tvMicros(tv: std.c.timeval) i64 {
    return @as(i64, @intCast(tv.sec)) * 1_000_000 + @as(i64, @intCast(tv.usec));
}

/// Normalize a raw ru_maxrss value to kilobytes. Linux reports ru_maxrss in KB;
/// Darwin (macOS/iOS and relatives) reports it in BYTES, so divide by 1024 there.
fn maxRssKb(raw: isize) isize {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => @divTrunc(raw, 1024),
        else => raw,
    };
}

// Wait status macros
fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn WEXITSTATUS(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

fn WIFSIGNALED(status: c_int) bool {
    return ((status & 0x7f) + 1) >> 1 > 0;
}

fn WTERMSIG(status: c_int) u8 {
    return @intCast(status & 0x7f);
}

// Output helpers
fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn writeFd(fd: c_int, data: []const u8) void {
    _ = libc.write(fd, data.ptr, data.len);
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStderr(msg);
}

fn printFmtFd(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(fd, msg);
}

// ============================================================================
// Configuration
// ============================================================================

const OutputFormat = enum {
    default,
    verbose,
    portable,
    custom,
};

const Config = struct {
    format: OutputFormat = .default,
    custom_format: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    append_output: bool = false,
    quiet: bool = false,
    command: []const []const u8 = &.{},
};

// ============================================================================
// Timing Result
// ============================================================================

const TimingResult = struct {
    exit_code: i32,
    signal: ?u8 = null,
    real_time_ns: u64,
    user_time_us: i64,
    sys_time_us: i64,
    max_rss_kb: isize,
    minor_faults: isize,
    major_faults: isize,
    voluntary_ctx_switches: isize,
    involuntary_ctx_switches: isize,
    block_input_ops: isize,
    block_output_ops: isize,
    swaps: isize = 0,
    signals: isize = 0,
    msgs_sent: isize = 0,
    msgs_recv: isize = 0,
    shared_text_kb: isize = 0,
    unshared_data_kb: isize = 0,
    unshared_stack_kb: isize = 0,
    page_size: isize = 0,

    fn realTimeSecs(self: TimingResult) f64 {
        return @as(f64, @floatFromInt(self.real_time_ns)) / 1_000_000_000.0;
    }

    fn userTimeSecs(self: TimingResult) f64 {
        return @as(f64, @floatFromInt(self.user_time_us)) / 1_000_000.0;
    }

    fn sysTimeSecs(self: TimingResult) f64 {
        return @as(f64, @floatFromInt(self.sys_time_us)) / 1_000_000.0;
    }

    fn cpuPercent(self: TimingResult) f64 {
        const real_secs = self.realTimeSecs();
        if (real_secs == 0) return 0;
        const cpu_secs = self.userTimeSecs() + self.sysTimeSecs();
        return (cpu_secs / real_secs) * 100.0;
    }
};

// ============================================================================
// Execute and Time Command
// ============================================================================

fn executeAndTime(allocator: std.mem.Allocator, command: []const []const u8, quiet: bool) !TimingResult {
    if (command.len == 0) return error.NoCommand;

    // Build argv for execvp
    var argv_buf = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer argv_buf.deinit(allocator);

    for (command) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv_buf.append(allocator, z.ptr);
    }
    try argv_buf.append(allocator, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.items.ptr);
    const cmd_z = try allocator.dupeZ(u8, command[0]);
    defer allocator.free(cmd_z);

    // Get rusage before fork
    var rusage_before: rusage = undefined;
    _ = std.c.getrusage(RUSAGE_CHILDREN, &rusage_before);

    // Start wall clock timer
    var timer = try Timer.start();

    // Fork
    const pid = fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process
        if (quiet) {
            // Redirect stdout/stderr to /dev/null
            const devnull = libc.open("/dev/null", libc.O{ .ACCMODE = .WRONLY }, @as(libc.mode_t, 0));
            if (devnull >= 0) {
                _ = libc.dup2(devnull, libc.STDOUT_FILENO);
                _ = libc.dup2(devnull, libc.STDERR_FILENO);
                _ = libc.close(devnull);
            }
        }

        // Execute command
        _ = execvp(cmd_z.ptr, argv);

        // If we get here, exec failed
        std.process.exit(127);
    }

    // Parent process - wait for child
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    // Stop wall clock timer
    const elapsed_ns = timer.read();

    // Get rusage after
    var rusage_after: rusage = undefined;
    _ = std.c.getrusage(RUSAGE_CHILDREN, &rusage_after);

    // Calculate delta rusage (microseconds), using platform-correct field widths.
    const user_us = tvMicros(rusage_after.utime) - tvMicros(rusage_before.utime);
    const sys_us = tvMicros(rusage_after.stime) - tvMicros(rusage_before.stime);

    // Parse exit status
    var exit_code: i32 = 0;
    var signal: ?u8 = null;

    if (WIFEXITED(status)) {
        exit_code = @intCast(WEXITSTATUS(status));
    } else if (WIFSIGNALED(status)) {
        signal = WTERMSIG(status);
        exit_code = 128 + @as(i32, @intCast(signal.?));
    }

    return TimingResult{
        .exit_code = exit_code,
        .signal = signal,
        .real_time_ns = elapsed_ns,
        .user_time_us = user_us,
        .sys_time_us = sys_us,
        .max_rss_kb = maxRssKb(rusage_after.maxrss),
        .minor_faults = rusage_after.minflt - rusage_before.minflt,
        .major_faults = rusage_after.majflt - rusage_before.majflt,
        .voluntary_ctx_switches = rusage_after.nvcsw - rusage_before.nvcsw,
        .involuntary_ctx_switches = rusage_after.nivcsw - rusage_before.nivcsw,
        .block_input_ops = rusage_after.inblock - rusage_before.inblock,
        .block_output_ops = rusage_after.oublock - rusage_before.oublock,
        .swaps = rusage_after.nswap - rusage_before.nswap,
        .signals = rusage_after.nsignals - rusage_before.nsignals,
        .msgs_sent = rusage_after.msgsnd - rusage_before.msgsnd,
        .msgs_recv = rusage_after.msgrcv - rusage_before.msgrcv,
        .shared_text_kb = rusage_after.ixrss,
        .unshared_data_kb = rusage_after.idrss,
        .unshared_stack_kb = rusage_after.isrss,
        .page_size = getpagesize(),
    };
}

// ============================================================================
// Output Formatting
// ============================================================================

fn formatTime(secs: f64) struct { mins: u32, secs: f64 } {
    const total_secs = @as(u64, @intFromFloat(@max(0.0, secs)));
    const mins: u32 = @intCast(total_secs / 60);
    const remaining = secs - @as(f64, @floatFromInt(mins * 60));
    return .{ .mins = mins, .secs = remaining };
}

/// GNU `%E`: elapsed real time as `[h:]mm:ss.ss`.
///   < 1 hour  -> `m:ss.ss`  (e.g. 65.0s -> "1:05.00")
///   >= 1 hour -> `h:mm:ss`  (e.g. 3661s -> "1:01:01")
/// Ref: GNU time info manual, "%E" specifier.
fn formatElapsedClock(buf: []u8, secs_in: f64) []const u8 {
    const secs = @max(0.0, secs_in);
    const total: u64 = @intFromFloat(secs);
    const hours = total / 3600;
    if (hours > 0) {
        const mins = (total % 3600) / 60;
        const s = total % 60;
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, s }) catch "";
    }
    const mins = total / 60;
    const s = secs - @as(f64, @floatFromInt(mins * 60));
    return std.fmt.bufPrint(buf, "{d}:{d:0>5.2}", .{ mins, s }) catch "";
}

fn printDefaultOutput(fd: c_int, result: TimingResult) void {
    const real = formatTime(result.realTimeSecs());
    const user = formatTime(result.userTimeSecs());
    const sys = formatTime(result.sysTimeSecs());

    printFmtFd(fd, "\nreal\t{d}m{d:.3}s\n", .{ real.mins, real.secs });
    printFmtFd(fd, "user\t{d}m{d:.3}s\n", .{ user.mins, user.secs });
    printFmtFd(fd, "sys\t{d}m{d:.3}s\n", .{ sys.mins, sys.secs });
}

fn printPortableOutput(fd: c_int, result: TimingResult) void {
    printFmtFd(fd, "real {d:.2}\n", .{result.realTimeSecs()});
    printFmtFd(fd, "user {d:.2}\n", .{result.userTimeSecs()});
    printFmtFd(fd, "sys {d:.2}\n", .{result.sysTimeSecs()});
}

fn printVerboseOutput(fd: c_int, result: TimingResult, command: []const []const u8) void {
    writeFd(fd, "\n\tCommand being timed: \"");
    for (command, 0..) |arg, i| {
        if (i > 0) writeFd(fd, " ");
        writeFd(fd, arg);
    }
    writeFd(fd, "\"\n");

    const real = formatTime(result.realTimeSecs());

    printFmtFd(fd, "\tUser time (seconds): {d:.2}\n", .{result.userTimeSecs()});
    printFmtFd(fd, "\tSystem time (seconds): {d:.2}\n", .{result.sysTimeSecs()});
    printFmtFd(fd, "\tPercent of CPU this job got: {d:.0}%\n", .{result.cpuPercent()});
    printFmtFd(fd, "\tElapsed (wall clock) time (m:ss): {d}:{d:0>5.2}\n", .{ real.mins, real.secs });

    printFmtFd(fd, "\tAverage shared text size (kbytes): {d}\n", .{result.shared_text_kb});
    printFmtFd(fd, "\tAverage unshared data size (kbytes): {d}\n", .{result.unshared_data_kb});
    printFmtFd(fd, "\tAverage stack size (kbytes): {d}\n", .{result.unshared_stack_kb});
    printFmtFd(fd, "\tAverage total size (kbytes): {d}\n", .{result.shared_text_kb + result.unshared_data_kb + result.unshared_stack_kb});
    printFmtFd(fd, "\tMaximum resident set size (kbytes): {d}\n", .{result.max_rss_kb});
    printFmtFd(fd, "\tAverage resident set size (kbytes): {d}\n", .{result.unshared_data_kb});
    printFmtFd(fd, "\tMajor (requiring I/O) page faults: {d}\n", .{result.major_faults});
    printFmtFd(fd, "\tMinor (reclaiming a frame) page faults: {d}\n", .{result.minor_faults});
    printFmtFd(fd, "\tVoluntary context switches: {d}\n", .{result.voluntary_ctx_switches});
    printFmtFd(fd, "\tInvoluntary context switches: {d}\n", .{result.involuntary_ctx_switches});
    printFmtFd(fd, "\tSwaps: {d}\n", .{result.swaps});
    printFmtFd(fd, "\tFile system inputs: {d}\n", .{result.block_input_ops});
    printFmtFd(fd, "\tFile system outputs: {d}\n", .{result.block_output_ops});
    printFmtFd(fd, "\tSocket messages sent: {d}\n", .{result.msgs_sent});
    printFmtFd(fd, "\tSocket messages received: {d}\n", .{result.msgs_recv});
    printFmtFd(fd, "\tSignals delivered: {d}\n", .{result.signals});
    printFmtFd(fd, "\tPage size (bytes): {d}\n", .{result.page_size});
    printFmtFd(fd, "\tExit status: {d}\n", .{result.exit_code});
}

fn printCustomOutput(fd: c_int, result: TimingResult, command: []const []const u8, format: []const u8) void {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const spec = format[i + 1];
            switch (spec) {
                // %e: elapsed real time in seconds.
                'e' => {
                    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{result.realTimeSecs()}) catch "";
                    writeFd(fd, s);
                },
                // %E: elapsed real time in [h:]mm:ss.ss clock format (distinct from %e).
                'E' => writeFd(fd, formatElapsedClock(&buf, result.realTimeSecs())),
                'U' => {
                    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{result.userTimeSecs()}) catch "";
                    writeFd(fd, s);
                },
                'S' => {
                    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{result.sysTimeSecs()}) catch "";
                    writeFd(fd, s);
                },
                'P' => {
                    const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{result.cpuPercent()}) catch "";
                    writeFd(fd, s);
                },
                'M' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.max_rss_kb}) catch "";
                    writeFd(fd, s);
                },
                'F' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.major_faults}) catch "";
                    writeFd(fd, s);
                },
                'R' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.minor_faults}) catch "";
                    writeFd(fd, s);
                },
                // GNU: %w = voluntary ("waits"), %c = involuntary ctx switches.
                // (These were previously swapped.)
                'w' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.voluntary_ctx_switches}) catch "";
                    writeFd(fd, s);
                },
                'c' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.involuntary_ctx_switches}) catch "";
                    writeFd(fd, s);
                },
                'I' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.block_input_ops}) catch "";
                    writeFd(fd, s);
                },
                'O' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.block_output_ops}) catch "";
                    writeFd(fd, s);
                },
                'x' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.exit_code}) catch "";
                    writeFd(fd, s);
                },
                // %W swaps, %k signals delivered, %r/%s socket msgs recv/sent.
                'W' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.swaps}) catch "";
                    writeFd(fd, s);
                },
                'k' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.signals}) catch "";
                    writeFd(fd, s);
                },
                'r' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.msgs_recv}) catch "";
                    writeFd(fd, s);
                },
                's' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.msgs_sent}) catch "";
                    writeFd(fd, s);
                },
                // Memory averages. Modern kernels leave the ru_i*rss fields at 0, so
                // GNU (and ztime) emit 0 for these — matching real GNU time output.
                'X' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.shared_text_kb}) catch "";
                    writeFd(fd, s);
                },
                'D' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.unshared_data_kb}) catch "";
                    writeFd(fd, s);
                },
                'p' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.unshared_stack_kb}) catch "";
                    writeFd(fd, s);
                },
                't' => {
                    // %t: average resident set size (KB). idrss-derived; 0 on modern kernels.
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.unshared_data_kb}) catch "";
                    writeFd(fd, s);
                },
                'K' => {
                    // %K: average total (text+data+stack) memory (KB).
                    const total = result.shared_text_kb + result.unshared_data_kb + result.unshared_stack_kb;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{total}) catch "";
                    writeFd(fd, s);
                },
                'Z' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.page_size}) catch "";
                    writeFd(fd, s);
                },
                'C' => {
                    for (command, 0..) |arg, j| {
                        if (j > 0) writeFd(fd, " ");
                        writeFd(fd, arg);
                    }
                },
                '%' => writeFd(fd, "%"),
                else => {
                    writeFd(fd, "%");
                    const b: [1]u8 = .{spec};
                    writeFd(fd, &b);
                },
            }
            i += 2;
        } else if (format[i] == '\\' and i + 1 < format.len) {
            const escape = format[i + 1];
            switch (escape) {
                'n' => writeFd(fd, "\n"),
                't' => writeFd(fd, "\t"),
                '\\' => writeFd(fd, "\\"),
                else => {
                    writeFd(fd, "\\");
                    const b: [1]u8 = .{escape};
                    writeFd(fd, &b);
                },
            }
            i += 2;
        } else {
            const b: [1]u8 = .{format[i]};
            writeFd(fd, &b);
            i += 1;
        }
    }
}

// ============================================================================
// Help and Version
// ============================================================================

fn printHelp() void {
    writeStdout(
        \\ztime - GNU time replacement in pure Zig
        \\
        \\Usage: ztime [options] command [arguments...]
        \\
        \\Options:
        \\  -v, --verbose    Verbose output with additional statistics
        \\  -p, --portable   POSIX portable output format
        \\  -f, --format FMT Custom output format string
        \\  -o, --output FILE Write timing to file instead of stderr
        \\  -a, --append     Append to output file (use with -o)
        \\  -q, --quiet      Suppress command output
        \\  -h, --help       Show this help message
        \\  --version        Show version
        \\
        \\Format specifiers for -f (GNU time semantics):
        \\  %e  Elapsed real time (seconds)
        \\  %E  Elapsed real time ([h:]mm:ss.ss)
        \\  %U  User CPU time (seconds)
        \\  %S  System CPU time (seconds)
        \\  %P  Percent CPU ((U+S)/E)
        \\  %M  Maximum resident set size (KB)
        \\  %K  Average total memory (KB)
        \\  %X  Average shared text (KB)
        \\  %D  Average unshared data (KB)
        \\  %p  Average unshared stack (KB)
        \\  %t  Average resident set size (KB)
        \\  %Z  System page size (bytes)
        \\  %F  Major page faults
        \\  %R  Minor page faults
        \\  %w  Voluntary context switches
        \\  %c  Involuntary context switches
        \\  %W  Times swapped out of memory
        \\  %k  Signals delivered
        \\  %I  File system inputs
        \\  %O  File system outputs
        \\  %r  Socket messages received
        \\  %s  Socket messages sent
        \\  %x  Exit status
        \\  %C  Command being timed
        \\  %%  Literal %
        \\  \n  Newline
        \\  \t  Tab
        \\
        \\Examples:
        \\  ztime sleep 1
        \\  ztime -v ./my_program
        \\  ztime -f "Real: %e User: %U Sys: %S\n" command
        \\
    );
}

fn printVersion() void {
    writeStdout("ztime " ++ VERSION ++ "\n");
}

// ============================================================================
// Argument Parsing
// ============================================================================

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config = Config{};
    var cmd_start: ?usize = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and cmd_start == null) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                config.format = .verbose;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--portable")) {
                config.format = .portable;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                config.quiet = true;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--append")) {
                config.append_output = true;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                if (i + 1 >= args.len) {
                    writeStderr("ztime: option requires an argument -- 'f'\n");
                    std.process.exit(1);
                }
                i += 1;
                config.custom_format = args[i];
                config.format = .custom;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                if (i + 1 >= args.len) {
                    writeStderr("ztime: option requires an argument -- 'o'\n");
                    std.process.exit(1);
                }
                i += 1;
                config.output_file = args[i];
            } else if (std.mem.eql(u8, arg, "--")) {
                cmd_start = i + 1;
                break;
            } else {
                printFmt("ztime: unrecognized option '{s}'\n", .{arg});
                std.process.exit(1);
            }
        } else {
            cmd_start = i;
            break;
        }
    }

    const start = cmd_start orelse {
        writeStderr("ztime: no command specified\n");
        writeStderr("Try 'ztime --help' for more information.\n");
        std.process.exit(1);
    };

    if (start >= args.len) {
        writeStderr("ztime: no command specified\n");
        writeStderr("Try 'ztime --help' for more information.\n");
        std.process.exit(1);
    }

    // Copy command slice
    const cmd_slice = args[start..];
    const command = try allocator.alloc([]const u8, cmd_slice.len);
    for (cmd_slice, 0..) |arg, j| {
        command[j] = try allocator.dupe(u8, arg);
    }
    config.command = command;

    return config;
}

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get arguments
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printHelp();
        std.process.exit(0);
    }

    // Parse arguments
    const config = try parseArgs(allocator, args[1..]);
    defer {
        for (config.command) |arg| {
            allocator.free(arg);
        }
        allocator.free(config.command);
    }

    // Execute and time the command
    const result = executeAndTime(allocator, config.command, config.quiet) catch |err| {
        switch (err) {
            error.NoCommand => writeStderr("ztime: no command specified\n"),
            error.ForkFailed => writeStderr("ztime: fork failed\n"),
            else => printFmt("ztime: error: {}\n", .{err}),
        }
        std.process.exit(127);
    };

    // Determine output fd
    var output_fd: c_int = libc.STDERR_FILENO;
    var opened_fd: c_int = -1;

    if (config.output_file) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("ztime: path too long\n");
            std.process.exit(1);
        };

        var flags = libc.O{ .ACCMODE = .WRONLY, .CREAT = true };
        if (config.append_output) {
            flags.APPEND = true;
        } else {
            flags.TRUNC = true;
        }

        opened_fd = libc.open(path_z.ptr, flags, @as(libc.mode_t, 0o644));
        if (opened_fd < 0) {
            printFmt("ztime: cannot open '{s}'\n", .{path});
            std.process.exit(1);
        }
        output_fd = opened_fd;
    }
    defer {
        if (opened_fd >= 0) _ = libc.close(opened_fd);
    }

    // GNU time prints this to the timing stream when the child died from a signal,
    // before the resource summary. Ref: GNU time resuse.c summarize().
    if (result.signal) |sig| {
        printFmtFd(output_fd, "Command terminated by signal {d}\n", .{sig});
    }

    // Print timing output
    switch (config.format) {
        .default => printDefaultOutput(output_fd, result),
        .verbose => printVerboseOutput(output_fd, result, config.command),
        .portable => printPortableOutput(output_fd, result),
        .custom => if (config.custom_format) |fmt| {
            printCustomOutput(output_fd, result, config.command, fmt);
        },
    }

    // Exit with command's exit code
    std.process.exit(@intCast(@as(u32, @bitCast(result.exit_code)) & 0xFF));
}
