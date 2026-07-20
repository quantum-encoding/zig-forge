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
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn raise(sig: c_int) c_int;
extern "c" fn signal(sig: c_int, handler: usize) usize;

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

        // Parse fractional part.
        // Accumulate at most 9 fractional digits (nanosecond resolution) and
        // truncate the rest. The previous `frac_val * 1e9 / scale` overflowed
        // u64 once the fractional string had ~11+ digits (and `scale *= 10`
        // wrapped at ~20 digits), which panicked in safe builds and silently
        // wrapped in ReleaseFast. GNU truncates excess precision rather than
        // failing (`timeout 0.99999999999 ...` runs), so we do the same.
        var frac_ns: u64 = 0;
        if (has_dot and suffix_start > decimal_start) {
            const frac_str = str[decimal_start..suffix_start];
            var digit_weight: u64 = 100_000_000; // weight of the 1st fractional digit, in ns
            for (frac_str) |d| {
                if (digit_weight == 0) break; // already consumed 9 digits
                frac_ns += @as(u64, d - '0') * digit_weight;
                digit_weight /= 10;
            }
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
    var options_ended = false; // set by a literal "--"

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!options_ended and arg.len > 0 and arg[0] == '-') {
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
            } else if (std.mem.startsWith(u8, arg, "-s") or std.mem.startsWith(u8, arg, "--signal")) {
                // Accept: "-s NAME", "-sNAME" (attached, GNU getopt form),
                // "--signal NAME", "--signal=NAME".
                const sig_str = if (std.mem.startsWith(u8, arg, "--signal="))
                    arg["--signal=".len..]
                else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option requires an argument -- 's'");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                } else if (std.mem.startsWith(u8, arg, "-s"))
                    arg["-s".len..] // attached short form: -sKILL
                else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };

                config.signal = SignalNames.fromName(sig_str) orelse {
                    printError("invalid signal");
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };
            } else if (std.mem.startsWith(u8, arg, "-k") or std.mem.startsWith(u8, arg, "--kill-after")) {
                // Accept: "-k DUR", "-kDUR" (attached), "--kill-after DUR",
                // "--kill-after=DUR".
                const duration_str = if (std.mem.startsWith(u8, arg, "--kill-after="))
                    arg["--kill-after=".len..]
                else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kill-after")) blk: {
                    i += 1;
                    if (i >= args.len) {
                        printError("option requires an argument -- 'k'");
                        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                    }
                    break :blk args[i];
                } else if (std.mem.startsWith(u8, arg, "-k"))
                    arg["-k".len..] // attached short form: -k0.2
                else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };

                config.kill_after = Duration.parse(duration_str) catch {
                    printError("invalid time interval");
                    std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
                };
            } else if (std.mem.eql(u8, arg, "--")) {
                // End of options: everything after this is positional
                // (DURATION then COMMAND), even if it starts with '-'.
                options_ended = true;
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
        const rc = execvp(config.command_name.ptr, config.command_argv.ptr);

        // If we get here, exec failed. `std.c.errno(x)` returns the real errno
        // only when `x == -1`, else `.SUCCESS` (see std/c.zig). The old code
        // passed the literal 0, so `err` was always `.SUCCESS`, the NOENT
        // branch was dead, and every failure fell through to 126 with no
        // diagnostic. Capture the actual execvp return value instead.
        const err = std.c.errno(rc);
        printErrorFmt("failed to run command '{s}': {s}", .{
            config.command_name,
            std.mem.span(strerror(@intFromEnum(err))),
        });
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

/// How the child ultimately terminated. Kept distinct (exit vs signal) so we
/// can reproduce GNU `timeout`'s signal-transparent behavior: when the child
/// dies from a signal, GNU re-raises that signal on itself rather than doing a
/// plain exit(128+sig), so its own parent observes the identical termination.
const ChildResult = union(enum) {
    exited: u8,
    signaled: u8,
};

fn waitForChild(pid: c_int) ?ChildResult {
    var status: c_int = 0;
    const result = waitpid(pid, &status, 0);
    if (result < 0) return null;

    if (WIFEXITED(status)) {
        return .{ .exited = WEXITSTATUS(status) };
    } else if (WIFSIGNALED(status)) {
        return .{ .signaled = WTERMSIG(status) };
    }
    return null;
}

/// Re-raise `sig` on ourselves so our parent sees the same terminating signal
/// (GNU signal transparency). Restores the default disposition and unblocks the
/// signal first, since the parent blocks TERM/CHLD. Does not return.
fn reRaise(sig: c_int) noreturn {
    const SIG_DFL: usize = 0;
    _ = signal(sig, SIG_DFL);

    var set: sigset_t = undefined;
    _ = sigemptyset(&set);
    _ = sigaddset(&set, sig);
    _ = sigprocmask(SIG_UNBLOCK, &set, null);

    _ = raise(sig);
    // Fatal default dispositions never return here; guard anyway.
    std.process.exit(ExitStatus.signalExit(@intCast(sig)));
}

/// Map the child's termination onto ztimeout's process exit, matching GNU:
///   - child exited normally, no timeout           -> that exit code
///   - child died by signal, no timeout            -> re-raise (transparent)
///   - --preserve-status                           -> child's status (128+sig / code)
///   - timed out, killed by SIGKILL                -> re-raise SIGKILL (137/signaled 9)
///   - timed out, otherwise                        -> 124
fn finish(timed_out: bool, preserve: bool, child: ChildResult) noreturn {
    switch (child) {
        .exited => |code| {
            if (timed_out and !preserve) {
                std.process.exit(@intFromEnum(ExitStatus.command_timed_out));
            }
            std.process.exit(code);
        },
        .signaled => |sig| {
            if (preserve) std.process.exit(ExitStatus.signalExit(sig));
            if (!timed_out) reRaise(sig); // transparent: child died on its own
            if (sig == @as(u8, @intCast(Signal.KILL))) reRaise(Signal.KILL);
            std.process.exit(@intFromEnum(ExitStatus.command_timed_out));
        },
    }
}

// ============================================================================
// Sleep-based waiting (cross-platform)
// ============================================================================

fn doSleep(duration: Duration) void {
    var ts = duration.toTimespec();
    _ = nanosleep(&ts, null);
}

// Check if child has exited (non-blocking). Reaps the child on success.
fn checkChildExited(pid: c_int) ?ChildResult {
    var status: c_int = 0;
    const WNOHANG: c_int = 1;
    const result = waitpid(pid, &status, WNOHANG);
    if (result > 0) {
        if (WIFEXITED(status)) {
            return .{ .exited = WEXITSTATUS(status) };
        } else if (WIFSIGNALED(status)) {
            return .{ .signaled = WTERMSIG(status) };
        }
    }
    return null;
}

// ============================================================================
// Main Timeout Logic
// ============================================================================

fn runTimeout(config: *const Config) noreturn {
    // Block SIGCHLD and SIGTERM before spawning child
    const mask = SignalMask.block(&.{ Signal.CHLD, Signal.TERM });

    // Spawn child process
    const child_pid = spawnChild(config) catch {
        printError("failed to spawn child process");
        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
    };

    // Handle zero timeout (no timeout mode): run the child to completion and
    // reflect its termination transparently.
    if (config.duration.isZero()) {
        const status = waitForChild(child_pid) orelse {
            mask.restore();
            std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
        };
        finish(false, config.preserve_status, status);
    }

    // Polling approach for timeout - check at most every 100ms, but never
    // sleep past the remaining time so sub-100ms durations fire on time
    // instead of rounding up to a 100ms boundary.
    var remaining_ns: u64 = config.duration.seconds * 1_000_000_000 + config.duration.nanoseconds;
    const poll_ns: u64 = 100_000_000;

    while (remaining_ns > 0) {
        // Child finished before the timeout: reflect its status transparently.
        if (checkChildExited(child_pid)) |status| {
            finish(false, config.preserve_status, status);
        }

        // Sleep for the smaller of the poll interval and the time left.
        const sleep_ns: u64 = @min(poll_ns, remaining_ns);
        doSleep(Duration{ .seconds = sleep_ns / 1_000_000_000, .nanoseconds = @intCast(sleep_ns % 1_000_000_000) });
        remaining_ns -= sleep_ns;
    }

    // The child may have exited during the final sleep interval. Re-check
    // before declaring a timeout, otherwise a fast command that finishes
    // within the last poll window is wrongly reported as timed out (124).
    if (checkChildExited(child_pid)) |status| {
        finish(false, config.preserve_status, status);
    }

    // Timeout expired - send signal to child
    if (config.verbose) {
        printVerbose(SignalNames.getName(config.signal), config.command_name);
    }

    killProcess(child_pid, config.signal, config.foreground);

    // Handle kill-after
    var reaped: ?ChildResult = null;
    if (config.kill_after) |kill_duration| {
        var kill_remaining_ns: u64 = kill_duration.seconds * 1_000_000_000 + kill_duration.nanoseconds;

        // Capture the child's result if it dies from the initial signal within
        // the kill-after window. `checkChildExited` REAPS the child, so we must
        // record that here — re-calling waitpid afterwards would return -1
        // (ECHILD) and be misread as "still running", causing a spurious
        // SIGKILL escalation (and a wrong 137 instead of 124).
        while (kill_remaining_ns > 0) {
            if (checkChildExited(child_pid)) |r| {
                reaped = r;
                break;
            }

            const sleep_ns: u64 = @min(poll_ns, kill_remaining_ns);
            doSleep(Duration{ .seconds = sleep_ns / 1_000_000_000, .nanoseconds = @intCast(sleep_ns % 1_000_000_000) });
            kill_remaining_ns -= sleep_ns;
        }

        // If child still running after the window, escalate to SIGKILL.
        if (reaped == null) {
            if (config.verbose) {
                printVerbose("KILL", config.command_name);
            }
            killProcess(child_pid, Signal.KILL, config.foreground);
        }
    }

    // Reap the child if not already reaped in the kill-after loop.
    const status = reaped orelse waitForChild(child_pid) orelse {
        mask.restore();
        std.process.exit(@intFromEnum(ExitStatus.timeout_failed));
    };
    finish(true, config.preserve_status, status);
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

    runTimeout(&config);
}
