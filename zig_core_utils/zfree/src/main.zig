//! zfree - Display amount of free and used memory
//!
//! High-performance free implementation in Zig.
//! Parses /proc/meminfo for memory statistics.
//!
//! Column semantics and layout are anchored to procps-ng 4.0.6 `free`:
//!   used      = MemTotal - MemAvailable   (fallback: MemTotal - MemFree)
//!   buff/cache = Buffers + Cached + SReclaimable
//!   swap used = SwapTotal - SwapFree
//! Row layout is `%-9s` label + `%11s` first column + ` %11s` per further column.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

pub const MemInfo = struct {
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

pub const Config = struct {
    human_readable: bool = false,
    si_units: bool = false,
    show_total: bool = false,
    show_wide: bool = false,
    bytes: bool = false,
    kibi: bool = true,
    mebi: bool = false,
    gibi: bool = false,
    count: u32 = 1,
    interval_ns: u64 = 1_000_000_000, // default 1 second
    count_set: bool = false,
    seconds_set: bool = false,
};

/// Result of parsing the command line. Kept separate from `main` so it can be
/// unit-tested against documented GNU `free` behavior.
pub const Action = union(enum) {
    run: Config,
    help,
    version,
    /// An unrecognized / malformed option. The payload is the offending token.
    err: []const u8,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

const USAGE =
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
    \\  -s N, --seconds N  Repeat continuously every N seconds (N may be fractional)
    \\  -c N, --count N    Repeat N times then exit
    \\      --help     Display this help
    \\      --version  Output version information
    \\
;

fn printUsage() void {
    // GNU `free` prints --help to stdout and exits 0.
    writeStdout(USAGE);
}

fn printVersion() void {
    // GNU `free` prints --version to stdout and exits 0.
    writeStdout("zfree " ++ VERSION ++ "\n");
}

/// Parse a fractional-seconds interval (e.g. "2", "0.5") into nanoseconds.
/// Returns null on malformed input. Mirrors GNU `free -s` which accepts
/// floating-point second intervals.
pub fn parseSeconds(s: []const u8) ?u64 {
    const secs = std.fmt.parseFloat(f64, s) catch return null;
    if (secs < 0 or std.math.isNan(secs) or std.math.isInf(secs)) return null;
    const ns = secs * 1_000_000_000.0;
    if (ns >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(ns);
}

/// Pure argument parser over an already-split argv (program name excluded).
pub fn parseArgs(args: []const []const u8) Action {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bytes")) {
            cfg.bytes = true;
            cfg.kibi = false;
            cfg.mebi = false;
            cfg.gibi = false;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kibi")) {
            cfg.kibi = true;
            cfg.bytes = false;
            cfg.mebi = false;
            cfg.gibi = false;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mebi")) {
            cfg.mebi = true;
            cfg.kibi = false;
            cfg.bytes = false;
            cfg.gibi = false;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--gibi")) {
            cfg.gibi = true;
            cfg.kibi = false;
            cfg.bytes = false;
            cfg.mebi = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--human")) {
            cfg.human_readable = true;
        } else if (std.mem.eql(u8, arg, "--si")) {
            cfg.si_units = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--total")) {
            cfg.show_total = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wide")) {
            cfg.show_wide = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--seconds")) {
            i += 1;
            if (i >= args.len) return .{ .err = arg };
            cfg.interval_ns = parseSeconds(args[i]) orelse return .{ .err = args[i] };
            cfg.seconds_set = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= args.len) return .{ .err = arg };
            cfg.count = std.fmt.parseInt(u32, args[i], 10) catch return .{ .err = args[i] };
            cfg.count_set = true;
        } else {
            // GNU `free` errors on unknown/invalid options and exits 1.
            return .{ .err = arg };
        }
    }

    // GNU `free -s` repeats continuously until interrupted; `-c` caps the count.
    if (cfg.seconds_set and !cfg.count_set) cfg.count = std.math.maxInt(u32);

    return .{ .run = cfg };
}

/// Parse the textual contents of /proc/meminfo. Pure: no I/O.
pub fn parseMeminfoData(data: []const u8) MemInfo {
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

/// Read /proc/meminfo fully into `buf`, looping until EOF (a single read() can
/// return a short count, and a large meminfo can exceed one read). Returns the
/// populated slice, or null on open/read failure.
fn readMeminfo(buf: []u8) ?[]const u8 {
    const fd = libc.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = libc.read(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return null;
        if (n == 0) break; // EOF
        total += @intCast(n);
    }
    if (total == 0) return null;
    return buf[0..total];
}

/// Compute the "used" memory column exactly as procps-ng 4.0.6 does:
///   used = MemTotal - MemAvailable
/// with a fallback of MemTotal - MemFree when MemAvailable is absent (older
/// kernels) or exceeds MemTotal (e.g. LXC containers). The saturating subtract
/// guards against underflow — GNU `free` never emits a wrapped/negative used.
pub fn computeMemUsed(info: MemInfo) u64 {
    if (info.mem_available != 0 and info.mem_available <= info.mem_total) {
        return info.mem_total - info.mem_available;
    }
    return info.mem_total -| info.mem_free;
}

/// Format a single memory value (given in KiB) as the *content* of a column,
/// with no field-width padding — the row printer right-justifies it. Non-human
/// fixed-unit output matches procps `scale_size` for -b/-k/-m/-g (non-SI).
pub fn formatValue(kibibytes: u64, cfg: *const Config, buf: []u8) []const u8 {
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
            return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        } else if (val >= 10) {
            return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        } else {
            return std.fmt.bufPrint(buf, "{d:.2}{s}", .{ val, units[unit_idx] }) catch buf[0..0];
        }
    }

    // Fixed unit output.
    if (cfg.bytes) {
        const b = kibibytes * 1024;
        return std.fmt.bufPrint(buf, "{d}", .{b}) catch buf[0..0];
    }

    if (cfg.si_units) {
        // Convert KiB (1024-based) to SI units (1000-based).
        const b = kibibytes * 1024;
        var divisor: u64 = 1000; // SI kilobytes
        if (cfg.mebi) {
            divisor = 1000 * 1000;
        } else if (cfg.gibi) {
            divisor = 1000 * 1000 * 1000;
        }
        return std.fmt.bufPrint(buf, "{d}", .{b / divisor}) catch buf[0..0];
    }

    var divisor: u64 = 1;
    if (cfg.mebi) {
        divisor = 1024;
    } else if (cfg.gibi) {
        divisor = 1024 * 1024;
    }
    // Default: kibi (divisor = 1)

    return std.fmt.bufPrint(buf, "{d}", .{kibibytes / divisor}) catch buf[0..0];
}

/// Write a row label left-justified in a 9-char field (`%-9s`).
fn writeLabel(w: *std.Io.Writer, label: []const u8) std.Io.Writer.Error!void {
    try w.print("{s:<9}", .{label});
}

/// Write one value column: the first column is `%11s`; every subsequent column
/// is ` %11s` (a leading space separator). Matches procps-ng layout exactly.
fn writeCol(w: *std.Io.Writer, content: []const u8, first: bool) std.Io.Writer.Error!void {
    if (!first) try w.writeByte(' ');
    try w.print("{s:>11}", .{content});
}

/// Render the full `free` report for `info`/`cfg` to `w`. Pure: no I/O, so it
/// can be byte-compared against real procps-ng `free` output in tests.
pub fn renderReport(info: MemInfo, cfg: *const Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const buff_cache = info.buffers + info.cached + info.s_reclaimable;
    const mem_used = computeMemUsed(info);
    const shared = info.shmem;
    const swap_used = info.swap_total -| info.swap_free;

    var buf: [64]u8 = undefined;

    // Header
    if (cfg.show_wide) {
        try w.writeAll("               total        used        free      shared     buffers       cache   available\n");
    } else {
        try w.writeAll("               total        used        free      shared  buff/cache   available\n");
    }

    // Mem line
    try writeLabel(w, "Mem:");
    try writeCol(w, formatValue(info.mem_total, cfg, &buf), true);
    try writeCol(w, formatValue(mem_used, cfg, &buf), false);
    try writeCol(w, formatValue(info.mem_free, cfg, &buf), false);
    try writeCol(w, formatValue(shared, cfg, &buf), false);
    if (cfg.show_wide) {
        try writeCol(w, formatValue(info.buffers, cfg, &buf), false);
        try writeCol(w, formatValue(info.cached + info.s_reclaimable, cfg, &buf), false);
    } else {
        try writeCol(w, formatValue(buff_cache, cfg, &buf), false);
    }
    try writeCol(w, formatValue(info.mem_available, cfg, &buf), false);
    try w.writeByte('\n');

    // Swap line
    try writeLabel(w, "Swap:");
    try writeCol(w, formatValue(info.swap_total, cfg, &buf), true);
    try writeCol(w, formatValue(swap_used, cfg, &buf), false);
    try writeCol(w, formatValue(info.swap_free, cfg, &buf), false);
    try w.writeByte('\n');

    // Total line
    if (cfg.show_total) {
        const total_total = info.mem_total + info.swap_total;
        const total_used = mem_used + swap_used;
        const total_free = info.mem_free + info.swap_free;

        try writeLabel(w, "Total:");
        try writeCol(w, formatValue(total_total, cfg, &buf), true);
        try writeCol(w, formatValue(total_used, cfg, &buf), false);
        try writeCol(w, formatValue(total_free, cfg, &buf), false);
        try w.writeByte('\n');
    }
}

fn printMemory(cfg: *const Config) bool {
    var raw: [16384]u8 = undefined;
    const data = readMeminfo(&raw) orelse {
        writeStderr("zfree: cannot read /proc/meminfo\n");
        return false;
    };
    const info = parseMeminfoData(data);

    var out: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    renderReport(info, cfg, &w) catch {
        writeStderr("zfree: output buffer overflow\n");
        return false;
    };
    writeStdout(w.buffered());
    return true;
}

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };

fn sleep_ns(ns: u64) void {
    const req = Timespec{
        .tv_sec = @intCast(ns / 1_000_000_000),
        .tv_nsec = @intCast(ns % 1_000_000_000),
    };
    _ = nanosleep(&req, null);
}

fn reportBadOption(opt: []const u8) void {
    var b: [256]u8 = undefined;
    if (std.mem.startsWith(u8, opt, "--")) {
        const msg = std.fmt.bufPrint(&b, "zfree: unrecognized option '{s}'\n", .{opt}) catch "zfree: unrecognized option\n";
        writeStderr(msg);
    } else if (opt.len >= 2 and opt[0] == '-') {
        const msg = std.fmt.bufPrint(&b, "zfree: invalid option -- '{s}'\n", .{opt[1..]}) catch "zfree: invalid option\n";
        writeStderr(msg);
    } else {
        const msg = std.fmt.bufPrint(&b, "zfree: unrecognized argument '{s}'\n", .{opt}) catch "zfree: unrecognized argument\n";
        writeStderr(msg);
    }
    writeStderr(USAGE);
}

pub fn main(init: std.process.Init) void {
    // Collect argv (excluding the program name) into a fixed slice buffer.
    var argbuf: [128][]const u8 = undefined;
    var argc: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        if (argc >= argbuf.len) break;
        argbuf[argc] = arg;
        argc += 1;
    }

    const action = parseArgs(argbuf[0..argc]);
    const cfg = switch (action) {
        .help => {
            printUsage();
            return;
        },
        .version => {
            printVersion();
            return;
        },
        .err => |opt| {
            reportBadOption(opt);
            std.process.exit(1);
        },
        .run => |c| c,
    };

    // Main loop
    var iterations: u32 = 0;
    while (iterations < cfg.count) : (iterations += 1) {
        if (iterations > 0) {
            sleep_ns(cfg.interval_ns);
            writeStdout("\n");
        }
        if (!printMemory(&cfg)) std.process.exit(1);
    }
}
