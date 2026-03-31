//! ztime - GNU time replacement in pure Zig
//!
//! Measures real (wall clock), user (CPU in user mode), and system (CPU in kernel mode)
//! time for command execution. Compatible with GNU time output format.

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
extern "c" fn getrusage(who: c_int, usage: *rusage) c_int;

const RUSAGE_CHILDREN: c_int = -1;

// rusage structure (cross-platform)
const timeval = extern struct {
    sec: isize,
    usec: isize,
};

const rusage = extern struct {
    utime: timeval,
    stime: timeval,
    maxrss: isize,
    ixrss: isize,
    idrss: isize,
    isrss: isize,
    minflt: isize,
    majflt: isize,
    nswap: isize,
    inblock: isize,
    oublock: isize,
    msgsnd: isize,
    msgrcv: isize,
    nsignals: isize,
    nvcsw: isize,
    nivcsw: isize,
};

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
    _ = getrusage(RUSAGE_CHILDREN, &rusage_before);

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
    _ = getrusage(RUSAGE_CHILDREN, &rusage_after);

    // Calculate delta rusage
    const user_us = (rusage_after.utime.sec - rusage_before.utime.sec) * 1_000_000 +
        (rusage_after.utime.usec - rusage_before.utime.usec);
    const sys_us = (rusage_after.stime.sec - rusage_before.stime.sec) * 1_000_000 +
        (rusage_after.stime.usec - rusage_before.stime.usec);

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
        .max_rss_kb = rusage_after.maxrss,
        .minor_faults = rusage_after.minflt - rusage_before.minflt,
        .major_faults = rusage_after.majflt - rusage_before.majflt,
        .voluntary_ctx_switches = rusage_after.nvcsw - rusage_before.nvcsw,
        .involuntary_ctx_switches = rusage_after.nivcsw - rusage_before.nivcsw,
        .block_input_ops = rusage_after.inblock - rusage_before.inblock,
        .block_output_ops = rusage_after.oublock - rusage_before.oublock,
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

    printFmtFd(fd, "\tMaximum resident set size (kbytes): {d}\n", .{result.max_rss_kb});
    printFmtFd(fd, "\tMinor (reclaiming a frame) page faults: {d}\n", .{result.minor_faults});
    printFmtFd(fd, "\tMajor (requiring I/O) page faults: {d}\n", .{result.major_faults});
    printFmtFd(fd, "\tVoluntary context switches: {d}\n", .{result.voluntary_ctx_switches});
    printFmtFd(fd, "\tInvoluntary context switches: {d}\n", .{result.involuntary_ctx_switches});
    printFmtFd(fd, "\tFile system inputs: {d}\n", .{result.block_input_ops});
    printFmtFd(fd, "\tFile system outputs: {d}\n", .{result.block_output_ops});
    printFmtFd(fd, "\tExit status: {d}\n", .{result.exit_code});
}

fn printCustomOutput(fd: c_int, result: TimingResult, command: []const []const u8, format: []const u8) void {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const spec = format[i + 1];
            switch (spec) {
                'e', 'E' => {
                    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{result.realTimeSecs()}) catch "";
                    writeFd(fd, s);
                },
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
                'c' => {
                    const s = std.fmt.bufPrint(&buf, "{d}", .{result.voluntary_ctx_switches}) catch "";
                    writeFd(fd, s);
                },
                'w' => {
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
                'C' => {
                    for (command, 0..) |arg, j| {
                        if (j > 0) writeFd(fd, " ");
                        writeFd(fd, arg);
                    }
                },
                '%' => writeFd(fd, "%"),
                'n' => writeFd(fd, "\n"),
                't' => writeFd(fd, "\t"),
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
        \\Format specifiers for -f:
        \\  %e  Elapsed real time (seconds)
        \\  %U  User CPU time (seconds)
        \\  %S  System CPU time (seconds)
        \\  %P  Percent CPU ((U+S)/E)
        \\  %M  Maximum resident set size (KB)
        \\  %F  Major page faults
        \\  %R  Minor page faults
        \\  %c  Voluntary context switches
        \\  %w  Involuntary context switches
        \\  %I  File system inputs
        \\  %O  File system outputs
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
