const std = @import("std");
const posix = std.posix;
const libc = std.c;
const linux = std.os.linux;

fn readFile(path: [*:0]const u8) ?[]const u8 {
    const fd = linux.open(path, .{}, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var buf: [256]u8 = undefined;
    const n = linux.read(@intCast(fd), &buf, buf.len);
    if (@as(isize, @bitCast(n)) <= 0) return null;

    return buf[0..n];
}

fn parseRange(s: []const u8) usize {
    // Parse CPU range like "0-15" or "0,2,4-7"
    var count: usize = 0;
    var i: usize = 0;

    while (i < s.len) {
        // Skip whitespace and newlines
        while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
        if (i >= s.len) break;

        // Parse first number
        var start: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') {
            start = start * 10 + (s[i] - '0');
            i += 1;
        }

        if (i < s.len and s[i] == '-') {
            // Range: start-end
            i += 1;
            var end: usize = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') {
                end = end * 10 + (s[i] - '0');
                i += 1;
            }
            count += end - start + 1;
        } else {
            // Single number
            count += 1;
        }

        // Skip comma
        if (i < s.len and s[i] == ',') i += 1;
    }

    return count;
}

fn getOnlineCpus() usize {
    // Try /sys/devices/system/cpu/online first
    if (readFile("/sys/devices/system/cpu/online")) |content| {
        const count = parseRange(content);
        if (count > 0) return count;
    }

    // Fallback: count processor lines in /proc/cpuinfo
    if (readFile("/proc/cpuinfo")) |_| {
        // This buffer is too small for cpuinfo, use sysconf instead
    }

    // Use sched_getaffinity to count available CPUs
    var mask: [128]u8 = undefined; // 1024 CPUs max
    const rc = linux.syscall3(.sched_getaffinity, 0, mask.len, @intFromPtr(&mask));
    if (@as(isize, @bitCast(rc)) > 0) {
        var count: usize = 0;
        for (mask[0..rc]) |byte| {
            count += @popCount(byte);
        }
        if (count > 0) return count;
    }

    return 1; // Fallback
}

fn getAllCpus() usize {
    // Try /sys/devices/system/cpu/present
    if (readFile("/sys/devices/system/cpu/present")) |content| {
        const count = parseRange(content);
        if (count > 0) return count;
    }

    // Fallback to online count
    return getOnlineCpus();
}

fn writeNum(n: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch return;
    _ = libc.write(libc.STDOUT_FILENO, s.ptr, s.len);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var all = false;
    var ignore: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: znproc [OPTION]...
                \\Print the number of processing units available to the current process,
                \\which may be less than the number of online processors
                \\
                \\      --all       print the number of installed processors
                \\      --ignore=N  if possible, exclude N processing units
                \\      --help      display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.startsWith(u8, arg, "--ignore=")) {
            ignore = std.fmt.parseInt(usize, arg[9..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--ignore")) {
            if (args.next()) |val| {
                ignore = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }
    }

    var count = if (all) getAllCpus() else getOnlineCpus();

    if (ignore > 0 and count > ignore) {
        count -= ignore;
    } else if (ignore > 0) {
        count = 1; // At least 1
    }

    writeNum(count);
}
