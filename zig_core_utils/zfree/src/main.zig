//! zfree - Display amount of free and used memory
//!
//! High-performance free implementation in Zig.
//! Parses /proc/meminfo for memory statistics.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const MemInfo = struct {
    mem_total: u64 = 0,
    mem_free: u64 = 0,
    mem_available: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    s_reclaimable: u64 = 0,
    shmem: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
};

const Config = struct {
    human_readable: bool = false,
    si_units: bool = false,
    show_total: bool = false,
    show_wide: bool = false,
    bytes: bool = false,
    kibi: bool = true,
    mebi: bool = false,
    gibi: bool = false,
    count: u32 = 1,
    interval: u32 = 1,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zfree [OPTIONS]
        \\Display the amount of free and used system memory.
        \\
        \\Options:
        \\  -b, --bytes    Show output in bytes
        \\  -k, --kibi     Show output in kibibytes (default)
        \\  -m, --mebi     Show output in mebibytes
        \\  -g, --gibi     Show output in gibibytes
        \\  -h, --human    Show human-readable output
        \\      --si       Use powers of 1000 not 1024
        \\  -t, --total    Show total for RAM + swap
        \\  -w, --wide     Wide output (separate buffers and cache)
        \\  -s N, --seconds N  Repeat every N seconds
        \\  -c N, --count N    Repeat N times then exit
        \\      --help     Display this help
        \\      --version  Output version information
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zfree " ++ VERSION ++ "\n");
}

fn parseMeminfo() ?MemInfo {
    const fd = libc.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);

    var buf: [4096]u8 = undefined;
    const n = libc.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const data = buf[0..@intCast(n)];

    var info = MemInfo{};

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse "Key:     value kB"
        var parts = std.mem.splitScalar(u8, line, ':');
        const key = parts.next() orelse continue;
        const rest = std.mem.trim(u8, parts.next() orelse continue, " ");

        // Extract numeric value (in kB)
        var val_parts = std.mem.splitScalar(u8, rest, ' ');
        const val_str = val_parts.next() orelse continue;
        const val = std.fmt.parseInt(u64, val_str, 10) catch continue;

        if (std.mem.eql(u8, key, "MemTotal")) {
            info.mem_total = val;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            info.mem_free = val;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            info.mem_available = val;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            info.buffers = val;
        } else if (std.mem.eql(u8, key, "Cached")) {
            info.cached = val;
        } else if (std.mem.eql(u8, key, "SReclaimable")) {
            info.s_reclaimable = val;
        } else if (std.mem.eql(u8, key, "Shmem")) {
            info.shmem = val;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            info.swap_total = val;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            info.swap_free = val;
        }
    }

    return info;
}

fn formatSize(kibibytes: u64, cfg: *const Config, buf: []u8) []const u8 {
    if (cfg.human_readable) {
        const base: f64 = if (cfg.si_units) 1000.0 else 1024.0;
        const units = if (cfg.si_units)
            [_][]const u8{ "B", "K", "M", "G", "T", "P" }
        else
            [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti", "Pi" };

        var val: f64 = @floatFromInt(kibibytes);
        val *= 1024.0; // Convert to bytes first
        var unit_idx: usize = 0;

        while (val >= base and unit_idx < units.len - 1) {
            val /= base;
            unit_idx += 1;
        }

        if (val >= 100) {
            return std.fmt.bufPrint(buf, "{d:>6.0}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        } else if (val >= 10) {
            return std.fmt.bufPrint(buf, "{d:>6.1}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        } else {
            return std.fmt.bufPrint(buf, "{d:>6.2}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        }
    }

    // Fixed unit output
    if (cfg.bytes) {
        const bytes = kibibytes * 1024;
        return std.fmt.bufPrint(buf, "{d:>12}", .{bytes}) catch buf[0..0];
    }

    if (cfg.si_units) {
        // Convert kibibytes (1024-based from /proc/meminfo) to SI units (1000-based)
        const bytes = kibibytes * 1024;
        var divisor: u64 = 1000; // Default: SI kilobytes
        if (cfg.mebi) {
            divisor = 1000 * 1000; // SI megabytes
        } else if (cfg.gibi) {
            divisor = 1000 * 1000 * 1000; // SI gigabytes
        }
        const val = bytes / divisor;
        return std.fmt.bufPrint(buf, "{d:>12}", .{val}) catch buf[0..0];
    }

    var divisor: u64 = 1;
    if (cfg.mebi) {
        divisor = 1024;
    } else if (cfg.gibi) {
        divisor = 1024 * 1024;
    }
    // Default: kibi (divisor = 1)

    const val = kibibytes / divisor;
    return std.fmt.bufPrint(buf, "{d:>12}", .{val}) catch buf[0..0];
}

fn printMemory(cfg: *const Config) void {
    const info = parseMeminfo() orelse {
        writeStderr("zfree: cannot read /proc/meminfo\n");
        return;
    };

    // Calculate used memory (same as free command)
    const buff_cache = info.buffers + info.cached + info.s_reclaimable;
    const mem_used = info.mem_total - info.mem_free - buff_cache;
    const shared = info.shmem;
    const swap_used = info.swap_total - info.swap_free;

    var buf: [16]u8 = undefined;

    // Header
    if (cfg.show_wide) {
        writeStdout("               total        used        free      shared     buffers       cache   available\n");
    } else {
        writeStdout("               total        used        free      shared  buff/cache   available\n");
    }

    // Mem line
    writeStdout("Mem:    ");
    writeStdout(formatSize(info.mem_total, cfg, &buf));
    writeStdout(" ");
    writeStdout(formatSize(mem_used, cfg, &buf));
    writeStdout(" ");
    writeStdout(formatSize(info.mem_free, cfg, &buf));
    writeStdout(" ");
    writeStdout(formatSize(shared, cfg, &buf));
    writeStdout(" ");

    if (cfg.show_wide) {
        writeStdout(formatSize(info.buffers, cfg, &buf));
        writeStdout(" ");
        writeStdout(formatSize(info.cached + info.s_reclaimable, cfg, &buf));
    } else {
        writeStdout(formatSize(buff_cache, cfg, &buf));
    }
    writeStdout(" ");
    writeStdout(formatSize(info.mem_available, cfg, &buf));
    writeStdout("\n");

    // Swap line
    writeStdout("Swap:   ");
    writeStdout(formatSize(info.swap_total, cfg, &buf));
    writeStdout(" ");
    writeStdout(formatSize(swap_used, cfg, &buf));
    writeStdout(" ");
    writeStdout(formatSize(info.swap_free, cfg, &buf));
    writeStdout("\n");

    // Total line
    if (cfg.show_total) {
        const total_total = info.mem_total + info.swap_total;
        const total_used = mem_used + swap_used;
        const total_free = info.mem_free + info.swap_free;

        writeStdout("Total:  ");
        writeStdout(formatSize(total_total, cfg, &buf));
        writeStdout(" ");
        writeStdout(formatSize(total_used, cfg, &buf));
        writeStdout(" ");
        writeStdout(formatSize(total_free, cfg, &buf));
        writeStdout("\n");
    }
}

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };

fn sleep_seconds(seconds: u32) void {
    const req = Timespec{ .tv_sec = seconds, .tv_nsec = 0 };
    _ = nanosleep(&req, null);
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bytes")) {
            cfg.bytes = true;
            cfg.kibi = false;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kibi")) {
            cfg.kibi = true;
            cfg.bytes = false;
            cfg.mebi = false;
            cfg.gibi = false;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mebi")) {
            cfg.mebi = true;
            cfg.kibi = false;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--gibi")) {
            cfg.gibi = true;
            cfg.kibi = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--human")) {
            cfg.human_readable = true;
        } else if (std.mem.eql(u8, arg, "--si")) {
            cfg.si_units = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--total")) {
            cfg.show_total = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wide")) {
            cfg.show_wide = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--seconds")) {
            if (args_iter.next()) |val_arg| {
                cfg.interval = std.fmt.parseInt(u32, val_arg, 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            if (args_iter.next()) |val_arg| {
                cfg.count = std.fmt.parseInt(u32, val_arg, 10) catch 1;
            }
        }
    }

    // Main loop
    var iterations: u32 = 0;
    while (iterations < cfg.count) : (iterations += 1) {
        if (iterations > 0) {
            sleep_seconds(cfg.interval);
            writeStdout("\n");
        }
        printMemory(&cfg);
    }
}
