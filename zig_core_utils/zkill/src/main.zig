//! zkill - Send signals to processes
//!
//! A Zig implementation of the kill command.
//! Sends the specified signal to the specified processes or process groups.
//!
//! Usage: zkill [-s SIGNAL | -SIGNAL] PID...
//!        zkill -l [SIGNAL]

const std = @import("std");

const VERSION = "1.0.0";

// Signal definitions (Linux x86_64)
const Signal = struct {
    num: u6,
    name: []const u8,
    desc: []const u8,
};

const signals = [_]Signal{
    .{ .num = 1, .name = "HUP", .desc = "Hangup" },
    .{ .num = 2, .name = "INT", .desc = "Interrupt" },
    .{ .num = 3, .name = "QUIT", .desc = "Quit" },
    .{ .num = 4, .name = "ILL", .desc = "Illegal instruction" },
    .{ .num = 5, .name = "TRAP", .desc = "Trace/breakpoint trap" },
    .{ .num = 6, .name = "ABRT", .desc = "Aborted" },
    .{ .num = 7, .name = "BUS", .desc = "Bus error" },
    .{ .num = 8, .name = "FPE", .desc = "Floating point exception" },
    .{ .num = 9, .name = "KILL", .desc = "Killed" },
    .{ .num = 10, .name = "USR1", .desc = "User defined signal 1" },
    .{ .num = 11, .name = "SEGV", .desc = "Segmentation fault" },
    .{ .num = 12, .name = "USR2", .desc = "User defined signal 2" },
    .{ .num = 13, .name = "PIPE", .desc = "Broken pipe" },
    .{ .num = 14, .name = "ALRM", .desc = "Alarm clock" },
    .{ .num = 15, .name = "TERM", .desc = "Terminated" },
    .{ .num = 16, .name = "STKFLT", .desc = "Stack fault" },
    .{ .num = 17, .name = "CHLD", .desc = "Child exited" },
    .{ .num = 18, .name = "CONT", .desc = "Continued" },
    .{ .num = 19, .name = "STOP", .desc = "Stopped (signal)" },
    .{ .num = 20, .name = "TSTP", .desc = "Stopped" },
    .{ .num = 21, .name = "TTIN", .desc = "Stopped (tty input)" },
    .{ .num = 22, .name = "TTOU", .desc = "Stopped (tty output)" },
    .{ .num = 23, .name = "URG", .desc = "Urgent I/O condition" },
    .{ .num = 24, .name = "XCPU", .desc = "CPU time limit exceeded" },
    .{ .num = 25, .name = "XFSZ", .desc = "File size limit exceeded" },
    .{ .num = 26, .name = "VTALRM", .desc = "Virtual timer expired" },
    .{ .num = 27, .name = "PROF", .desc = "Profiling timer expired" },
    .{ .num = 28, .name = "WINCH", .desc = "Window changed" },
    .{ .num = 29, .name = "IO", .desc = "I/O possible" },
    .{ .num = 30, .name = "PWR", .desc = "Power failure" },
    .{ .num = 31, .name = "SYS", .desc = "Bad system call" },
};

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

    var signal_num: u6 = 15; // Default: SIGTERM
    var pids: std.ArrayListUnmanaged(i32) = .empty;
    defer pids.deinit(allocator);

    var list_mode = false;
    var list_signal: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            StdoutWriter.print("zkill {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
            // Check if next arg is a signal number
            if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                list_signal = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--table")) {
            printSignalTable();
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
            if (i + 1 >= args.len) {
                StderrWriter.print("zkill: option requires an argument -- 's'\n", .{});
                std.process.exit(1);
            }
            i += 1;
            signal_num = parseSignal(args[i]) orelse {
                StderrWriter.print("zkill: invalid signal specification: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            // Could be -SIGNAL or -NUMBER
            const sig_spec = arg[1..];
            if (parseSignal(sig_spec)) |sig| {
                signal_num = sig;
            } else {
                StderrWriter.print("zkill: invalid signal specification: {s}\n", .{sig_spec});
                std.process.exit(1);
            }
        } else {
            // Parse as PID
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
            if (std.fmt.parseInt(u6, sig_str, 10)) |num| {
                // Number to name
                if (getSignalName(num)) |name| {
                    StdoutWriter.print("{s}\n", .{name});
                } else {
                    StderrWriter.print("zkill: unknown signal: {d}\n", .{num});
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

fn parseSignal(spec: []const u8) ?u6 {
    // Try as number first
    if (std.fmt.parseInt(u6, spec, 10)) |num| {
        if (num <= 31) { // 0 is valid (null signal for checking process)
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

fn getSignalName(num: u6) ?[]const u8 {
    for (signals) |sig| {
        if (sig.num == num) {
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
        \\PID may be positive (process) or negative (process group).
        \\
        \\Common signals:
        \\   1  SIGHUP      Hangup
        \\   2  SIGINT      Interrupt (Ctrl+C)
        \\   9  SIGKILL     Kill (cannot be caught)
        \\  15  SIGTERM     Terminate (default)
        \\  19  SIGSTOP     Stop (cannot be caught)
        \\  18  SIGCONT     Continue
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
