//! zkill - Send signals to processes
//!
//! A Zig implementation of the kill command.
//! Sends the specified signal to the specified processes or process groups.
//!
//! Usage: zkill [-s SIGNAL | -SIGNAL] PID...
//!        zkill -l [SIGNAL]

const std = @import("std");

const VERSION = "1.0.0";

const Signal = struct {
    num: u8,
    name: []const u8,
    desc: []const u8,
};

// Highest numeric signal accepted as a specification. Covers POSIX 1-31 plus
// the Linux real-time range (SIGRTMIN..SIGRTMAX, up to 64). Values in that band
// with no named entry are still passed to kill(2), which validates them for the
// running kernel (EINVAL for an out-of-range number on this platform).
const MAX_SIGNAL: u8 = 64;

// Signal table derived from the *target OS's* signal numbering (std.c.SIG),
// NOT a hardcoded Linux table. The binary calls the native kill(2), so the
// name->number mapping must match the platform the binary runs on: on macOS
// SIGUSR1=30/SIGCONT=19/SIGSTOP=17, on Linux SIGUSR1=10/SIGCONT=18/SIGSTOP=19.
// @typeInfo(std.c.SIG).@"enum".fields yields exactly the real signals (the
// SIG.DFL/IGN/BLOCK/... helpers are pub-const decls, not enum fields).
const signals = blk: {
    @setEvalBranchQuota(10_000);
    const fields = @typeInfo(std.c.SIG).@"enum".fields;
    var arr: [fields.len]Signal = undefined;
    for (fields, 0..) |f, idx| {
        arr[idx] = .{
            .num = @intCast(f.value),
            .name = f.name,
            .desc = signalDesc(f.name),
        };
    }
    const frozen = arr;
    break :blk frozen;
};

fn signalDesc(name: []const u8) []const u8 {
    const table = .{
        .{ "HUP", "Hangup" },
        .{ "INT", "Interrupt" },
        .{ "QUIT", "Quit" },
        .{ "ILL", "Illegal instruction" },
        .{ "TRAP", "Trace/breakpoint trap" },
        .{ "ABRT", "Aborted" },
        .{ "EMT", "Emulator trap" },
        .{ "BUS", "Bus error" },
        .{ "FPE", "Floating point exception" },
        .{ "KILL", "Killed" },
        .{ "USR1", "User defined signal 1" },
        .{ "SEGV", "Segmentation fault" },
        .{ "USR2", "User defined signal 2" },
        .{ "PIPE", "Broken pipe" },
        .{ "ALRM", "Alarm clock" },
        .{ "TERM", "Terminated" },
        .{ "STKFLT", "Stack fault" },
        .{ "CHLD", "Child exited" },
        .{ "CONT", "Continued" },
        .{ "STOP", "Stopped (signal)" },
        .{ "TSTP", "Stopped" },
        .{ "TTIN", "Stopped (tty input)" },
        .{ "TTOU", "Stopped (tty output)" },
        .{ "URG", "Urgent I/O condition" },
        .{ "XCPU", "CPU time limit exceeded" },
        .{ "XFSZ", "File size limit exceeded" },
        .{ "VTALRM", "Virtual timer expired" },
        .{ "PROF", "Profiling timer expired" },
        .{ "WINCH", "Window changed" },
        .{ "IO", "I/O possible" },
        .{ "INFO", "Information request" },
        .{ "PWR", "Power failure" },
        .{ "SYS", "Bad system call" },
        .{ "XFZ", "File size limit exceeded" },
        .{ "LOST", "Resource lost" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return "Unknown signal";
}

// C functions
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

// Stderr writer
const StderrWriter = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = write(2, msg.ptr, msg.len);
    }
};

// Stdout writer
const StdoutWriter = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = write(1, msg.ptr, msg.len);
    }
};

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

    var signal_num: u8 = @intCast(@intFromEnum(std.c.SIG.TERM)); // Default: SIGTERM
    var pids: std.ArrayListUnmanaged(i32) = .empty;
    defer pids.deinit(allocator);

    var list_mode = false;
    var list_signal: ?[]const u8 = null;
    // Once a signal has been selected (via -s or a bare -SIGNAL), or once "--"
    // has been seen, any further "-N" token is a target (a negative PID is a
    // process group), NOT a new signal spec. GNU/POSIX kill semantics: the
    // signal option is positional and precedes the operands.
    var signal_set = false;
    var opts_done = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!opts_done and std.mem.eql(u8, arg, "--")) {
            // End of options: everything after is a PID / process group.
            opts_done = true;
        } else if (!opts_done and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
            printHelp();
            return;
        } else if (!opts_done and (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version"))) {
            StdoutWriter.print("zkill {s}\n", .{VERSION});
            return;
        } else if (!opts_done and (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list"))) {
            list_mode = true;
            // Consume a following signal argument only when it is present, is
            // non-empty, and does not itself look like an option. The `.len > 0`
            // guard prevents an out-of-bounds index on an empty argument.
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                i += 1;
                list_signal = args[i];
            }
        } else if (!opts_done and (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--table"))) {
            printSignalTable();
            return;
        } else if (!opts_done and (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal"))) {
            if (i + 1 >= args.len) {
                StderrWriter.print("zkill: option requires an argument -- 's'\n", .{});
                std.process.exit(1);
            }
            i += 1;
            signal_num = parseSignal(args[i]) orelse {
                StderrWriter.print("zkill: invalid signal specification: {s}\n", .{args[i]});
                std.process.exit(1);
            };
            signal_set = true;
        } else if (!opts_done and !signal_set and arg.len > 1 and arg[0] == '-') {
            // Bare -SIGNAL or -NUMBER, only valid before a signal is chosen.
            const sig_spec = arg[1..];
            if (parseSignal(sig_spec)) |sig| {
                signal_num = sig;
                signal_set = true;
            } else {
                StderrWriter.print("zkill: invalid signal specification: {s}\n", .{sig_spec});
                std.process.exit(1);
            }
        } else {
            // Parse as PID (may be negative for a process group).
            const pid = std.fmt.parseInt(i32, arg, 10) catch {
                StderrWriter.print("zkill: invalid process id: {s}\n", .{arg});
                std.process.exit(1);
            };
            try pids.append(allocator, pid);
        }
    }

    if (list_mode) {
        if (list_signal) |sig_str| {
            // Convert signal number to name or vice versa
            if (std.fmt.parseInt(u16, sig_str, 10)) |raw| {
                // Number to name. A value > 128 is a wait(2) exit status
                // (128 + signum); decode it the way `kill -l 137` -> KILL does.
                const num: u16 = if (raw > 128) raw - 128 else raw;
                if (getSignalName(num)) |name| {
                    StdoutWriter.print("{s}\n", .{name});
                } else {
                    StderrWriter.print("zkill: unknown signal: {d}\n", .{raw});
                    std.process.exit(1);
                }
            } else |_| {
                // Name to number
                if (parseSignal(sig_str)) |num| {
                    StdoutWriter.print("{d}\n", .{num});
                } else {
                    StderrWriter.print("zkill: unknown signal: {s}\n", .{sig_str});
                    std.process.exit(1);
                }
            }
        } else {
            listSignals();
        }
        return;
    }

    if (pids.items.len == 0) {
        StderrWriter.print("zkill: no process ID specified\n", .{});
        StderrWriter.print("Try 'zkill --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Send signals
    var errors: u32 = 0;
    for (pids.items) |pid| {
        const result = kill(pid, @intCast(signal_num));
        if (result != 0) {
            const errno = std.posix.errno(result);
            const err_msg: []const u8 = switch (errno) {
                .SRCH => "No such process",
                .PERM => "Operation not permitted",
                .INVAL => "Invalid argument",
                else => "Unknown error",
            };
            StderrWriter.print("zkill: ({d}) - {s}\n", .{ pid, err_msg });
            errors += 1;
        }
    }

    if (errors > 0) {
        std.process.exit(1);
    }
}

fn parseSignal(spec: []const u8) ?u8 {
    // Try as number first. 0 is valid (null signal, used to probe a process).
    // Accept the full per-platform range including Linux real-time signals;
    // kill(2) rejects a number the running kernel does not define.
    if (std.fmt.parseInt(u8, spec, 10)) |num| {
        if (num <= MAX_SIGNAL) {
            return num;
        }
        return null;
    } else |_| {}

    // Try as signal name (with or without SIG prefix)
    var name = spec;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) {
        name = name[3..];
    }

    for (signals) |sig| {
        if (std.ascii.eqlIgnoreCase(name, sig.name)) {
            return sig.num;
        }
    }

    return null;
}

fn getSignalName(num: u16) ?[]const u8 {
    for (signals) |sig| {
        if (@as(u16, sig.num) == num) {
            return sig.name;
        }
    }
    return null;
}

fn listSignals() void {
    var col: u32 = 0;
    for (signals) |sig| {
        if (col > 0 and col % 8 == 0) {
            StdoutWriter.print("\n", .{});
        }
        StdoutWriter.print("{d: >2}) SIG{s: <8}", .{ sig.num, sig.name });
        col += 1;
    }
    StdoutWriter.print("\n", .{});
}

fn printSignalTable() void {
    StdoutWriter.print(" Num  Name        Description\n", .{});
    StdoutWriter.print("----  ----------  -------------------------\n", .{});
    for (signals) |sig| {
        StdoutWriter.print("{d: >4}  SIG{s: <7}  {s}\n", .{ sig.num, sig.name, sig.desc });
    }
}

fn printHelp() void {
    StdoutWriter.print(
        \\Usage: zkill [-s SIGNAL | -SIGNAL] PID...
        \\       zkill -l [SIGNAL]
        \\       zkill -L
        \\
        \\Send signals to processes.
        \\
        \\Options:
        \\  -s, --signal SIGNAL  specify signal to send
        \\  -l, --list [SIGNAL]  list signal names, or convert signal to/from name
        \\  -L, --table          list signals in table format with descriptions
        \\  -h, --help           display this help
        \\  -V, --version        display version
        \\
        \\SIGNAL may be a signal name like 'HUP', 'SIGKILL', or a number.
        \\PID may be positive (process) or negative (process group); use '--'
        \\before a negative PID so it is not read as a signal.
        \\Signal numbers are platform-specific; run 'zkill -l' for this system's set.
        \\
        \\Common signals:
        \\  SIGHUP   Hangup
        \\  SIGINT   Interrupt (Ctrl+C)
        \\  SIGKILL  Kill (cannot be caught)
        \\  SIGTERM  Terminate (default)
        \\  SIGSTOP  Stop (cannot be caught)
        \\  SIGCONT  Continue
        \\
        \\Examples:
        \\  zkill 1234           Send SIGTERM to process 1234
        \\  zkill -9 1234        Send SIGKILL to process 1234
        \\  zkill -KILL 1234     Same as above
        \\  zkill -s HUP 1234    Send SIGHUP to process 1234
        \\  zkill -l             List all signals
        \\  zkill -l 9           Show name for signal 9
        \\  zkill -l KILL        Show number for SIGKILL
        \\
    , .{});
}
