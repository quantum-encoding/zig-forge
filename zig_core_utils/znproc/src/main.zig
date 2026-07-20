const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const linux = std.os.linux;

const VERSION =
    \\znproc (zig-forge coreutils) 1.0
    \\GNU nproc-compatible clone. Reimplemented in Zig.
    \\
;

const HELP =
    \\Usage: znproc [OPTION]...
    \\Print the number of processing units available to the current process,
    \\which may be less than the number of online processors
    \\
    \\      --all       print the number of installed processors
    \\      --ignore=N  if possible, exclude N processing units
    \\      --help      display this help and exit
    \\      --version   output version information and exit
    \\
;

/// Read up to `buf.len` bytes of `path` into the caller-owned `buf`.
/// Returns the populated sub-slice of `buf`, or null on any error / empty read.
///
/// The buffer is owned by the caller so the returned slice outlives this call
/// (the previous implementation returned a slice into a function-local stack
/// buffer — a dangling pointer). Reads are looped until EOF so a short read()
/// or a CPU list longer than one read chunk is not silently truncated.
///
/// Only invoked on Linux; the /sys and /proc pseudo-files it reads do not exist
/// elsewhere, and issuing raw Linux syscalls off Linux would SIGSYS-crash.
fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;

    const fd = linux.open(path, .{}, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        const sn: isize = @bitCast(n);
        if (sn < 0) return null; // read error
        if (sn == 0) break; // EOF
        total += @intCast(n);
    }
    if (total == 0) return null;
    return buf[0..total];
}

/// Parse a CPU list like "0-15" or "0,2,4-7" and return the number of CPUs it
/// enumerates. Descending or malformed ranges (end < start) contribute nothing
/// rather than underflowing usize (which panics in safe builds).
fn parseRange(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
        if (i >= s.len) break;
        if (!(s[i] >= '0' and s[i] <= '9')) {
            // Skip a stray non-digit token to avoid an infinite loop.
            i += 1;
            continue;
        }

        var start: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') {
            start = start *| 10 +| (s[i] - '0'); // saturating: never overflow-panic
            i += 1;
        }

        if (i < s.len and s[i] == '-') {
            i += 1;
            var end: usize = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') {
                end = end *| 10 +| (s[i] - '0');
                i += 1;
            }
            if (end >= start) count += end - start + 1;
        } else {
            count += 1;
        }

        if (i < s.len and s[i] == ',') i += 1;
    }

    return count;
}

/// Portable fallback: total logical CPUs the runtime can see. Used off Linux and
/// whenever the Linux /sys and affinity probes come up empty.
fn fallbackCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Number of CPUs currently available to this process (respecting affinity),
/// ignoring the OMP_* overrides. Mirrors gnulib num_processors(NPROC_CURRENT).
fn onlineCpusRaw() usize {
    if (builtin.os.tag == .linux) {
        var fbuf: [1024]u8 = undefined;
        if (readFile("/sys/devices/system/cpu/online", &fbuf)) |content| {
            const count = parseRange(content);
            if (count > 0) return count;
        }

        // sched_getaffinity: count the set bits of the returned CPU mask.
        var mask: [128]u8 = undefined; // up to 1024 CPUs
        const rc = linux.syscall3(.sched_getaffinity, 0, mask.len, @intFromPtr(&mask));
        if (@as(isize, @bitCast(rc)) > 0) {
            var count: usize = 0;
            for (mask[0..@intCast(rc)]) |byte| count += @popCount(byte);
            if (count > 0) return count;
        }
    }

    return fallbackCount();
}

/// Number of installed processors (gnulib num_processors(NPROC_ALL)).
fn allCpusRaw() usize {
    if (builtin.os.tag == .linux) {
        var fbuf: [1024]u8 = undefined;
        if (readFile("/sys/devices/system/cpu/present", &fbuf)) |content| {
            const count = parseRange(content);
            if (count > 0) return count;
        }
    }

    return fallbackCount();
}

/// gnulib parse_omp_threads: skip leading ASCII whitespace, then parse a
/// leading unsigned decimal (strtoul semantics — stops at the first non-digit,
/// so "2,4,8" yields 2). Returns 0 when there is no positive value, which the
/// caller treats as "unset".
fn parseOmp(v: ?[*:0]const u8) usize {
    const p = v orelse return 0;
    const s = std.mem.span(p);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r' or s[i] == 11 or s[i] == 12)) : (i += 1) {}
    if (i >= s.len or !(s[i] >= '0' and s[i] <= '9')) return 0;
    var value: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        value = value *| 10 +| (s[i] - '0');
    }
    return value; // may be 0 (e.g. "0") -> treated as unset by caller
}

/// Available CPU count with the OpenMP overrides applied, mirroring gnulib
/// num_processors(NPROC_CURRENT_OVERRIDABLE): OMP_NUM_THREADS overrides the
/// measured count, then OMP_THREAD_LIMIT caps it. Only the non-`--all` path.
fn currentOverridable() usize {
    const omp_threads = parseOmp(libc.getenv("OMP_NUM_THREADS"));
    const omp_limit = parseOmp(libc.getenv("OMP_THREAD_LIMIT"));

    var nprocs = onlineCpusRaw();
    if (omp_threads != 0) nprocs = omp_threads;
    if (omp_limit != 0 and nprocs > omp_limit) nprocs = omp_limit;
    if (nprocs < 1) nprocs = 1;
    return nprocs;
}

fn writeNum(n: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch return;
    _ = libc.write(libc.STDOUT_FILENO, s.ptr, s.len);
}

fn writeStr(fd: c_int, s: []const u8) void {
    _ = libc.write(fd, s.ptr, s.len);
}

fn usageError(arg: []const u8, kind: enum { option, operand }) void {
    var buf: [512]u8 = undefined;
    const msg = switch (kind) {
        .option => std.fmt.bufPrint(&buf, "znproc: unrecognized option '{s}'\n", .{arg}),
        .operand => std.fmt.bufPrint(&buf, "znproc: extra operand '{s}'\n", .{arg}),
    } catch return;
    writeStr(libc.STDERR_FILENO, msg);
    writeStr(libc.STDERR_FILENO, "Try 'znproc --help' for more information.\n");
}

/// True if `arg` matches long option `full` exactly or is an unambiguous
/// prefix abbreviation of it (getopt_long semantics). The four options have
/// distinct first letters, so any "--X…" prefix is unambiguous.
fn matchLong(arg: []const u8, full: []const u8) bool {
    if (arg.len < 3 or !std.mem.startsWith(u8, arg, "--")) return false;
    if (arg.len > full.len) return false;
    return std.mem.startsWith(u8, full, arg);
}

/// Handle "--ignore=2" / "--ig=2" long option with an attached =value.
/// Returns the value slice when the part before '=' matches `full` (exactly
/// or as an abbreviation prefix).
fn longWithValue(arg: []const u8, full: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    const name = arg[0..eq];
    if (name.len < 3 or name.len > full.len) return null;
    if (!std.mem.startsWith(u8, full, name)) return null;
    return arg[eq + 1 ..];
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var all = false;
    var ignore: usize = 0;
    var end_of_options = false;

    while (args.next()) |arg| {
        if (end_of_options) {
            usageError(arg, .operand);
            std.process.exit(1);
        }
        if (std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (matchLong(arg, "--help")) {
            writeStr(libc.STDOUT_FILENO, HELP);
            return;
        }
        if (matchLong(arg, "--version")) {
            writeStr(libc.STDOUT_FILENO, VERSION);
            return;
        }
        if (matchLong(arg, "--all")) {
            all = true;
            continue;
        }
        if (longWithValue(arg, "--ignore")) |val| {
            ignore = std.fmt.parseInt(usize, val, 10) catch 0;
            continue;
        }
        if (matchLong(arg, "--ignore")) {
            if (args.next()) |val| {
                ignore = std.fmt.parseInt(usize, val, 10) catch 0;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Unrecognized option: diagnose to stderr and exit 1 (GNU parity).
            usageError(arg, .option);
            std.process.exit(1);
        }
        // Non-option operand: GNU nproc accepts none.
        usageError(arg, .operand);
        std.process.exit(1);
    }

    var count = if (all) allCpusRaw() else currentOverridable();

    // gnulib nproc.c: nproc = nproc <= ignore ? 1 : nproc - ignore
    count = if (count <= ignore) 1 else count - ignore;

    writeNum(count);
}

test {
    _ = @import("gnu_parity_test.zig");
}
