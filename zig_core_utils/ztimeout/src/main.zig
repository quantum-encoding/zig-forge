//! ztimeout - High-performance timeout utility in Zig
//!
//! Key advantages over GNU/Rust implementations:
//! - Direct syscalls without libc overhead
//! - Comptime signal name lookup tables
//! - Zero allocations in hot path
//! - Clean signal mask handling

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

// External libc declarations
extern "c" fn fork() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn sigprocmask(how: c_int, set: ?*const sigset_t, oldset: ?*sigset_t) c_int;
extern "c" fn sigemptyset(set: *sigset_t) c_int;
extern "c" fn sigaddset(set: *sigset_t, signum: c_int) c_int;
extern "c" fn nanosleep(req: *const libc.timespec, rem: ?*libc.timespec) c_int;

// Signal set type (platform-specific size)
const sigset_t = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => u32,
    .linux => extern struct { val: [16]u64 },
    else => u64,
};

// Signal mask operations (different on Linux vs macOS)
const SIG_BLOCK: c_int = switch (builtin.os.tag) {
    .linux => 0,
    else => 1,
};
const SIG_UNBLOCK: c_int = switch (builtin.os.tag) {
    .linux => 1,
    else => 2,
};
const SIG_SETMASK: c_int = switch (builtin.os.tag) {
    .linux => 2,
    else => 3,
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

// ============================================================================
// Exit Status Codes (GNU compatible)
// ============================================================================

const ExitStatus = enum(u8) {
    success = 0,
    command_timed_out = 124, // Command timed out
    timeout_failed = 125, // timeout command itself failed
    command_not_invokable = 126, // Command found but couldn't be invoked
    command_not_found = 127, // Command not found
    // 128 + signal = killed by signal (e.g., 137 = 128 + 9 = SIGKILL)

    fn signalExit(sig: u8) u8 {
        return 128 + sig;
    }
};

// ============================================================================
// Signal Constants (cross-platform)
// ============================================================================

const Signal = struct {
    const HUP: c_int = 1;
    const INT: c_int = 2;
    const QUIT: c_int = 3;
    const ILL: c_int = 4;
    const TRAP: c_int = 5;
    const ABRT: c_int = 6;
    const FPE: c_int = 8;
    const KILL: c_int = 9;
    const BUS: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 10,
        else => 7,
    };
    const SEGV: c_int = 11;
    const PIPE: c_int = 13;
    const ALRM: c_int = 14;
    const TERM: c_int = 15;
    const USR1: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 30,
        else => 10,
    };
    const USR2: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 31,
        else => 12,
    };
    const CHLD: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 20,
        else => 17,
    };
    const CONT: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 19,
        else => 18,
    };
    const STOP: c_int = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 17,
        else => 19,
    };
};

/// Signal name lookup table for parsing signal names from arguments
const SignalNames = struct {
    const Entry = struct { name: []const u8, value: c_int };
    const signals = [_]Entry{
        .{ .name = "HUP", .value = Signal.HUP },
        .{ .name = "INT", .value = Signal.INT },
        .{ .name = "QUIT", .value = Signal.QUIT },
        .{ .name = "ILL", .value = Signal.ILL },
        .{ .name = "TRAP", .value = Signal.TRAP },
        .{ .name = "ABRT", .value = Signal.ABRT },
        .{ .name = "FPE", .value = Signal.FPE },
        .{ .name = "KILL", .value = Signal.KILL },
        .{ .name = "BUS", .value = Signal.BUS },
        .{ .name = "SEGV", .value = Signal.SEGV },
        .{ .name = "PIPE", .value = Signal.PIPE },
        .{ .name = "ALRM", .value = Signal.ALRM },
        .{ .name = "TERM", .value = Signal.TERM },
        .{ .name = "USR1", .value = Signal.USR1 },
        .{ .name = "USR2", .value = Signal.USR2 },
        .{ .name = "CHLD", .value = Signal.CHLD },
        .{ .name = "CONT", .value = Signal.CONT },
        .{ .name = "STOP", .value = Signal.STOP },
    };

    /// Parse a signal name (with or without SIG prefix) or number
    pub fn fromName(sig_name: []const u8) ?c_int {
        // Check exact match (e.g., "TERM", "KILL")
        for (signals) |entry| {
            if (std.ascii.eqlIgnoreCase(sig_name, entry.name)) return entry.value;
        }

        // Check with SIG prefix stripped (e.g., "SIGTERM" -> "TERM")
        if (sig_name.len > 3 and std.ascii.eqlIgnoreCase(sig_name[0..3], "SIG")) {
            const stripped = sig_name[3..];
            for (signals) |entry| {
                if (std.ascii.eqlIgnoreCase(stripped, entry.name)) return entry.value;
            }
        }

        // Check if numeric
        const num = std.fmt.parseInt(c_int, sig_name, 10) catch return null;
        if (num >= 1 and num <= 31) {
            return num;
        }
        return null;
    }

    /// Get signal name
    pub fn getName(sig: c_int) []const u8 {
        for (signals) |entry| {
            if (entry.value == sig) return entry.name;
        }
        return "UNKNOWN";
    }
};

// ============================================================================
// Duration Parsing
// ============================================================================

const Duration = struct {
    seconds: u64,
    nanoseconds: u32 = 0,

    const max_seconds: u64 = std.math.maxInt(i32) / 2; // ~34 years, safe for all platforms

    pub fn parse(str: []const u8) !Duration {
        if (str.len == 0) return error.InvalidDuration;

        // Find where numeric part ends
        var numeric_end: usize = 0;
        var has_dot = false;
        var decimal_start: usize = 0;

        for (str, 0..) |c, i| {
            if (c == '.') {
                if (has_dot) return error.InvalidDuration;
                has_dot = true;
                decimal_start = i + 1;
                numeric_end = i;
            } else if (c >= '0' and c <= '9') {
                if (!has_dot) numeric_end = i + 1;
            } else {
                break;
            }
        }

        const suffix_start = if (has_dot) blk: {
            var i = decimal_start;
            while (i < str.len and str[i] >= '0' and str[i] <= '9') : (i += 1) {}
            break :blk i;
        } else numeric_end;

        const suffix = str[suffix_start..];
        const multiplier: u64 = switch (suffix.len) {
            0 => 1, // seconds (default)
            1 => switch (suffix[0]) {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                'd' => 86400,
                else => return error.InvalidDuration,
            },
            else => return error.InvalidDuration,
        };

        // Parse integer part
        const int_part = std.fmt.parseInt(u64, str[0..numeric_end], 10) catch return error.InvalidDuration;

        // Parse fractional part
        var frac_ns: u64 = 0;
        if (has_dot and suffix_start > decimal_start) {
            const frac_str = str[decimal_start..suffix_start];
            // Convert to nanoseconds (9 decimal places)
            const frac_val = std.fmt.parseInt(u64, frac_str, 10) catch return error.InvalidDuration;
            var scale: u64 = 1;
            for (0..frac_str.len) |_| scale *= 10;
            frac_ns = (frac_val * 1_000_000_000) / scale;
        }

        // Calculate total with overflow protection
        const base_seconds = if (int_part > max_seconds / multiplier)
            max_seconds
        else
            int_part * multiplier;

        const frac_seconds = (frac_ns * multiplier) / 1_000_000_000;
        const remaining_ns: u32 = @intCast((frac_ns * multiplier) % 1_000_000_000);

        const total_seconds = @min(base_seconds + frac_seconds, max_seconds);

        return .{
            .seconds = total_seconds,
            .nanoseconds = remaining_ns,
        };
    }

    pub fn isZero(self: Duration) bool {
        return self.seconds == 0 and self.nanoseconds == 0;
    }

    pub fn toTimespec(self: Duration) libc.timespec {
        return .{
            .sec = @intCast(self.seconds),
            .nsec = @intCast(self.nanoseconds),
        };
    }
};

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    duration: Duration,
    kill_after: ?Duration = null,
    signal: c_int = Signal.TERM,
    foreground: bool = false,
    preserve_status: bool = false,
    verbose: bool = false,
    // Store command as null-terminated strings for exec
    command_argv: [:null]const ?[*:0]const u8 = &.{null},
    command_name: [:0]const u8 = "",
};

// ============================================================================
// Output Helpers
// ============================================================================

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn printError(msg: []const u8) void {
    writeStderr("ztimeout: ");
    writeStderr(msg);
    writeStderr("\n");
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ztimeout: " ++ fmt ++ "\n", args) catch return;
    writeStderr(msg);
}

fn printVerbose(sig_name: []const u8, cmd: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ztimeout: sending signal {s} to command '{s}'\n", .{ sig_name, cmd }) catch return;
    writeStderr(msg);
}

// ============================================================================
// Argument Parsing
// ============================================================================

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{ .duration = undefined };
    var i: usize = 1; // Skip program name
    var positional_count: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--foreground")) {
                config.foreground = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--preserve-status")) {
                config.preserve_status = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                config.verbose = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.startsWith(u8, arg, "--signal")) {
                const sig_str = if (std.mem.eql(u8, arg, "-s")) blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option requires an argument -- 's'");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                } else if (std.mem.startsWith(u8, arg, "--signal="))
                    arg["--signal=".len..]
                else blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--signal' requires an argument");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                };

                config.signal = SignalNames.fromName(sig_str) orelse {
                    printError("invalid signal");
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };
            } else if (std.mem.eql(u8, arg, "-k") or std.mem.startsWith(u8, arg, "--kill-after")) {
                const duration_str = if (std.mem.eql(u8, arg, "-k")) blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option requires an argument -- 'k'");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                } else if (std.mem.startsWith(u8, arg, "--kill-after="))
                    arg["--kill-after=".len..]
                else blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--kill-after' requires an argument");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                };

                config.kill_after = Duration.parse(duration_str) catch {
                    printError("invalid time interval");
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };
            } else if (std.mem.eql(u8, arg, "--")) {
                // End of options
                i += 1;
                break;
            } else {
                printErrorFmt("unrecognized option '{s}'", .{arg});
                std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
            }
        } else {
            // Positional argument
            if (positional_count == 0) {
                config.duration = Duration.parse(arg) catch {
                    printError("invalid time interval");
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };
                positional_count += 1;
            } else {
                // Rest are command and args
                break;
            }
        }
    }

    // Remaining args are the command
    if (i < args.len) {
        const cmd_count = args.len - i;

        // Allocate array for null-terminated string pointers (with null sentinel)
        const argv = try allocator.allocSentinel(?[*:0]const u8, cmd_count, null);

        // Store the command name
        config.command_name = try allocator.dupeZ(u8, args[i]);

        // Convert each argument to a null-terminated string
        for (0..cmd_count) |j| {
            argv[j] = try allocator.dupeZ(u8, args[i + j]);
        }

        config.command_argv = argv;
    }

    if (positional_count == 0) {
        printError("missing operand");
        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
    }

    if (config.command_argv.len == 0) {
        printError("missing operand after duration");
        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
    }

    return config;
}

// ============================================================================
// Signal Mask Management
// ============================================================================

const SignalMask = struct {
    old_mask: sigset_t,

    pub fn block(sigs: []const c_int) SignalMask {
        var set: sigset_t = undefined;
        _ = sigemptyset(&set);
        for (sigs) |sig| {
            _ = sigaddset(&set, sig);
        }

        var old_mask: sigset_t = undefined;
        _ = sigprocmask(SIG_BLOCK, &set, &old_mask);
        return .{ .old_mask = old_mask };
    }

    pub fn restore(self: *const SignalMask) void {
        _ = sigprocmask(SIG_SETMASK, &self.old_mask, null);
    }

    pub fn unblockInChild(sigs: []const c_int) void {
        var set: sigset_t = undefined;
        _ = sigemptyset(&set);
        for (sigs) |sig| {
            _ = sigaddset(&set, sig);
        }
        _ = sigprocmask(SIG_UNBLOCK, &set, null);
    }
};

// ============================================================================
// Process Management
// ============================================================================

fn spawnChild(config: *const Config) !c_int {
    const pid = fork();

    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process

        // Unblock signals that were blocked in parent
        SignalMask.unblockInChild(&.{ Signal.TERM, Signal.CHLD });

        // Create new process group if not foreground
        if (!config.foreground) {
            _ = setpgid(0, 0);
        }

        // Execute command
        _ = execvp(config.command_name.ptr, config.command_argv.ptr);

        // If we get here, exec failed
        // Check errno for the type of error
        const err = std.c.errno(0);
        if (err == .NOENT) {
            std.process.exit(@intFromEnum(ExitStatus.command_not_found));
        } else {
            std.process.exit(@intFromEnum(ExitStatus.command_not_invokable));
        }
    }

    return pid;
}

fn killProcess(pid: c_int, sig: c_int, foreground: bool) void {
    if (foreground) {
        _ = kill(pid, sig);
    } else {
        // Kill process group
        _ = kill(-pid, sig);

        // Send SIGCONT to ensure stopped processes receive the signal
        if (sig != Signal.KILL and sig != Signal.CONT) {
            _ = kill(-pid, Signal.CONT);
        }
    }
}

fn waitForChild(pid: c_int) ?u8 {
    var status: c_int = 0;
    const result = waitpid(pid, &status, 0);
    if (result < 0) return null;

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return ExitStatus.signalExit(WTERMSIG(status));
    }
    return null;
}

// ============================================================================
// Sleep-based waiting (cross-platform)
// ============================================================================

fn doSleep(duration: Duration) void {
    var ts = duration.toTimespec();
    _ = nanosleep(&ts, null);
}

// Check if child has exited (non-blocking)
fn checkChildExited(pid: c_int) ?u8 {
    var status: c_int = 0;
    const WNOHANG: c_int = 1;
    const result = waitpid(pid, &status, WNOHANG);
    if (result > 0) {
        if (WIFEXITED(status)) {
            return WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            return ExitStatus.signalExit(WTERMSIG(status));
        }
    }
    return null;
}

// ============================================================================
// Main Timeout Logic
// ============================================================================

fn runTimeout(config: *const Config) u8 {
    // Block SIGCHLD and SIGTERM before spawning child
    const mask = SignalMask.block(&.{ Signal.CHLD, Signal.TERM });
    defer mask.restore();

    // Spawn child process
    const child_pid = spawnChild(config) catch {
        printError("failed to spawn child process");
        return @intFromEnum(ExitStatus.timeout_failed);
    };

    // Handle zero timeout (no timeout mode)
    if (config.duration.isZero()) {
        const status = waitForChild(child_pid);
        return status orelse @intFromEnum(ExitStatus.timeout_failed);
    }

    // Polling approach for timeout - check every 100ms
    const poll_interval = Duration{ .seconds = 0, .nanoseconds = 100_000_000 };
    var remaining_ns: u64 = config.duration.seconds * 1_000_000_000 + config.duration.nanoseconds;
    const poll_ns: u64 = 100_000_000;

    while (remaining_ns > 0) {
        // Check if child has exited
        if (checkChildExited(child_pid)) |status| {
            return status;
        }

        // Sleep for poll interval
        doSleep(poll_interval);

        if (remaining_ns > poll_ns) {
            remaining_ns -= poll_ns;
        } else {
            remaining_ns = 0;
        }
    }

    // Timeout expired - send signal to child
    if (config.verbose) {
        printVerbose(SignalNames.getName(config.signal), config.command_name);
    }

    killProcess(child_pid, config.signal, config.foreground);

    // Track if we sent SIGKILL (for correct exit status)
    var sent_kill = false;

    // Handle kill-after
    if (config.kill_after) |kill_duration| {
        var kill_remaining_ns: u64 = kill_duration.seconds * 1_000_000_000 + kill_duration.nanoseconds;

        while (kill_remaining_ns > 0) {
            if (checkChildExited(child_pid)) |_| {
                break;
            }

            doSleep(poll_interval);

            if (kill_remaining_ns > poll_ns) {
                kill_remaining_ns -= poll_ns;
            } else {
                kill_remaining_ns = 0;
            }
        }

        // If child still running, send SIGKILL
        if (checkChildExited(child_pid) == null) {
            if (config.verbose) {
                printVerbose("KILL", config.command_name);
            }
            killProcess(child_pid, Signal.KILL, config.foreground);
            sent_kill = true;
        }
    }

    // Wait for child to actually exit
    _ = waitForChild(child_pid);

    if (config.preserve_status) {
        // Return 128 + signal we sent (or KILL if escalated)
        const final_sig: u8 = if (sent_kill) @intCast(Signal.KILL) else @intCast(config.signal);
        return ExitStatus.signalExit(final_sig);
    } else if (sent_kill) {
        // If we sent SIGKILL, return 137 (128 + 9)
        return ExitStatus.signalExit(@intCast(Signal.KILL));
    } else {
        return @intFromEnum(ExitStatus.command_timed_out);
    }
}

// ============================================================================
// Help/Version Output
// ============================================================================

fn printHelp() void {
    writeStdout(
        \\Usage: ztimeout [OPTION]... DURATION COMMAND [ARG]...
        \\Start COMMAND, and kill it if still running after DURATION.
        \\
        \\  -f, --foreground       when not running timeout directly from a shell prompt,
        \\                           allow COMMAND to read from the TTY and get TTY signals
        \\  -k, --kill-after=DURATION
        \\                         also send a KILL signal if COMMAND is still running
        \\                           this long after the initial signal was sent
        \\  -p, --preserve-status  exit with the same status as COMMAND,
        \\                           even when the command times out
        \\  -s, --signal=SIGNAL    specify the signal to be sent on timeout;
        \\                           SIGNAL may be a name like 'HUP' or a number
        \\  -v, --verbose          diagnose to standard error any signal sent upon timeout
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\DURATION is a floating point number with an optional suffix:
        \\'s' for seconds (the default), 'm' for minutes, 'h' for hours or 'd' for days.
        \\A duration of 0 disables the associated timeout.
        \\
        \\Exit status:
        \\  124  if COMMAND times out, and --preserve-status is not specified
        \\  125  if the timeout command itself fails
        \\  126  if COMMAND is found but cannot be invoked
        \\  127  if COMMAND cannot be found
        \\  137  if COMMAND is sent the KILL (9) signal (128+9)
        \\  -    the exit status of COMMAND otherwise
        \\
        \\ztimeout - High-performance timeout utility in Zig
        \\
    );
}

fn printVersion() void {
    writeStdout("ztimeout 0.1.0\n");
}

// ============================================================================
// Entry Point
// ============================================================================

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    const config = parseArgs(allocator, init.minimal.args) catch |err| {
        printErrorFmt("argument parsing failed: {}", .{err});
        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
    };

    const exit_code = runTimeout(&config);
    std.process.exit(exit_code);
}
